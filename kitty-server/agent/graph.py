"""LangGraph StateGraph 定义 + 对外入口。

Phase 1 图：
    START → build_context → agent → END

对外暴露：
- run_chat()：非流式，调用 graph.ainvoke
- run_chat_stream()：流式，手动走 build_context → gateway.chat_stream，不走 graph
  （这样可以直接拿 LLM 的 SSE chunk，避免 LangGraph 事件包装层）
"""
from __future__ import annotations

import os
from typing import Any, AsyncIterator, Dict, List, Optional

from langchain_core.messages import AIMessage, HumanMessage
from langgraph.graph import END, START, StateGraph

from llm.cache import CacheMetrics
from llm.gateway import get_gateway

from .context import build_llm_messages, openai_to_langchain
from .nodes import _LLM_MESSAGES_KEY, agent_node, make_build_context_node
from .state import AgentState


# ── 系统提示词 ──────────────────────────────────────────────────────

VOICE_SYSTEM_PROMPT = """你是一个温馨的助手 Kitty，正在和用户聊天。

## 对话风格

- 像跟好朋友聊天一样，轻松自然
- 用口语化表达，不要用书面语
- 回复简洁，不要长篇大论
- 适当加入自然的过渡词，如"嗯…"、"让我想想…"、"这个问题嘛…"

## 格式要求（非常重要，必须严格遵守）

- 禁止使用任何 Markdown 格式：不要用 **、*、#、-、`、>、| 等符号
- 禁止使用列表：不要用编号列表或项目符号
- 禁止使用 emoji 表情符号
- 纯文本输出：只输出纯文字，不要加任何格式标记

## 示例

用户："今天天气怎么样？"
你："嗯…让我想想。今天天气挺不错的，阳光明媚，适合出去走走。"

用户："帮我查下航班"
你："好的，我来帮你查一下。请问是哪个城市的航班？"

## 禁止事项

- 不要用复杂的句式和专业术语
- 不要像客服机器人一样说"为您服务"
- 不要用 emoji 表情
- 不要用 Markdown（粗体、斜体、列表、标题等）
- 不要用 Markdown（粗体、斜体、列表、标题等）
- 不要用 emoji 表情

记住：你是在跟人聊天，不是在写文章。保持自然、亲切、简洁。"""


def get_default_system_prompt() -> str:
    return VOICE_SYSTEM_PROMPT


# ── 图构建 ──────────────────────────────────────────────────────────

def build_graph(system_prompt: Optional[str] = None) -> StateGraph:
    """构建 LangGraph StateGraph。

    V1（Phase 1）是一条直链：build_context → agent → END
    后续 Phase 会添加 condition edge / tools_node / save_memory_node。
    """
    prompt = system_prompt or VOICE_SYSTEM_PROMPT

    graph = StateGraph(AgentState)

    # 添加节点
    graph.add_node("build_context", make_build_context_node(prompt))
    graph.add_node("agent", agent_node)

    # 边
    graph.add_edge(START, "build_context")
    graph.add_edge("build_context", "agent")
    graph.add_edge("agent", END)

    return graph


# ── Checkpointer ────────────────────────────────────────────────────
# AsyncSqliteSaver.from_conn_string 是 async context manager，
# 用 AsyncExitStack 把它的生命周期挂在进程的 startup/shutdown 上。

_EXIT_STACK = None
_CHECKPOINTER = None
_GRAPH_COMPILED = None


async def startup_agent(system_prompt: Optional[str] = None) -> None:
    """初始化 checkpointer 与 graph，幂等。"""
    global _EXIT_STACK, _CHECKPOINTER, _GRAPH_COMPILED
    if _GRAPH_COMPILED is not None:
        return

    from contextlib import AsyncExitStack
    from langgraph.checkpoint.sqlite.aio import AsyncSqliteSaver

    db_path = os.getenv("CHECKPOINT_DB_PATH", "./data/checkpoints.sqlite")
    db_dir = os.path.dirname(db_path)
    if db_dir and not os.path.exists(db_dir):
        os.makedirs(db_dir, exist_ok=True)

    _EXIT_STACK = AsyncExitStack()
    _CHECKPOINTER = await _EXIT_STACK.enter_async_context(
        AsyncSqliteSaver.from_conn_string(db_path)
    )
    await _CHECKPOINTER.setup()

    raw_graph = build_graph(system_prompt)
    _GRAPH_COMPILED = raw_graph.compile(checkpointer=_CHECKPOINTER)
    print(f"[Agent] checkpoint db: {db_path}")


async def shutdown_agent() -> None:
    """关闭 sqlite 连接。"""
    global _EXIT_STACK, _CHECKPOINTER, _GRAPH_COMPILED
    if _EXIT_STACK is not None:
        try:
            await _EXIT_STACK.aclose()
        except Exception as e:
            print(f"[Agent] shutdown 异常: {e}")
    _EXIT_STACK = None
    _CHECKPOINTER = None
    _GRAPH_COMPILED = None


async def _get_compiled_graph(system_prompt: Optional[str] = None):
    """获取已编译的 graph，未初始化则懒加载。"""
    if _GRAPH_COMPILED is None:
        await startup_agent(system_prompt)
    return _GRAPH_COMPILED


# ── 非流式入口 ─────────────────────────────────────────────────────

async def run_chat(
    message: str,
    session_id: str = "default",
    model: Optional[str] = None,
    history: Optional[List[Dict[str, Any]]] = None,
    system_prompt: Optional[str] = None,
) -> Dict[str, Any]:
    """非流式聊天，返回 {role, content, metrics}。"""
    graph = await _get_compiled_graph(system_prompt)

    # 种入历史
    existing_messages = openai_to_langchain(history) if history else []
    # 追加当前用户消息
    existing_messages.append(HumanMessage(content=message))

    input_state: AgentState = {
        "messages": existing_messages,
        "user_id": "default_user",
        "session_id": session_id,
        "model": model or "",
        "recalled_memories": [],
        "tool_results": [],
        "final_response": "",
    }

    config = {
        "configurable": {"thread_id": session_id},
        "recursion_limit": 10,
    }

    result = await graph.ainvoke(input_state, config)

    # 从 graph 结果提取回复
    # result["messages"] 末尾应包含 AIMessage
    ai_msgs = [m for m in result.get("messages", []) if isinstance(m, AIMessage)]
    reply = ai_msgs[-1].content if ai_msgs else result.get("final_response", "")

    return {
        "role": "assistant",
        "content": reply,
    }


# ── 流式入口 ───────────────────────────────────────────────────────

async def run_chat_stream(
    message: str,
    session_id: str = "default",
    model: Optional[str] = None,
    history: Optional[List[Dict[str, Any]]] = None,
    system_prompt: Optional[str] = None,
) -> AsyncIterator[Dict[str, Any]]:
    """流式聊天，yield OpenAI 兼容的 SSE chunk。

    每个 yield 是一个 dict：
        {"type": "delta", "content": "..."}
        {"type": "done", "metrics": {...}}

    调用方负责包装为 SSE 格式。
    """
    prompt = system_prompt or VOICE_SYSTEM_PROMPT

    # 1) 组装 context（复用 context engine）
    existing_messages = openai_to_langchain(history) if history else []
    existing_messages.append(HumanMessage(content=message))

    llm_messages = build_llm_messages(prompt, existing_messages)

    # 2) 流式调用 LLM gateway
    gateway = get_gateway()
    full_response = ""
    async for chunk in gateway.chat_stream(messages=llm_messages, model=model):
        if chunk["type"] == "delta":
            full_response += chunk["content"]
            yield chunk
        elif chunk["type"] == "done":
            yield chunk
        elif chunk["type"] == "error":
            yield chunk

    # 3) 用 graph 做一次非流式 invoke 来保存 checkpoint
    #    为了节省 token，直接把完整回复写入 state，不让 LLM 再答一次
    try:
        graph = await _get_compiled_graph(system_prompt)
        # 构造一个 state，其中 messages 已包含 user + assistant 完整消息
        checkpoint_messages = list(existing_messages) + [AIMessage(content=full_response)]
        checkpoint_state: AgentState = {
            "messages": checkpoint_messages,
            "user_id": "default_user",
            "session_id": session_id,
            "model": model or "",
            "recalled_memories": [],
            "tool_results": [],
            "final_response": full_response,
        }
        config = {
            "configurable": {"thread_id": session_id},
            "recursion_limit": 10,
        }
        # 用 graph.update_state 手动写 checkpoint，跳过 LLM 调用
        await graph.aupdate_state(config, checkpoint_state, as_node="agent")
    except Exception as e:
        # checkpoint 保存失败不应影响回复
        print(f"[Agent] checkpoint 保存失败: {e}")
