"""LangGraph 节点实现。

Phase 1 只实现：
- build_context_node：把 state.messages 组装成发给 LLM 的消息列表（写入 state）
- agent_node：调用 LLM，把回复作为 AIMessage 追加进 state.messages

Phase 2/3 会再加 save_memory_node、tools_node、condition route 等。
"""
from __future__ import annotations

from typing import Any, Dict

from langchain_core.messages import AIMessage

from llm.gateway import get_gateway

from .context import build_llm_messages
from .state import AgentState


# 本轮组装好的 LLM messages，临时挂在 state 里，给 agent_node 用
_LLM_MESSAGES_KEY = "llm_messages"


def make_build_context_node(system_prompt: str):
    """工厂：根据 system_prompt 生成 build_context 节点函数。"""

    async def build_context_node(state: AgentState) -> Dict[str, Any]:
        messages = state.get("messages", [])
        recalled = state.get("recalled_memories", [])
        llm_messages = build_llm_messages(system_prompt, messages, recalled)
        # 用 dict 返回是 LangGraph 的标准：仅更新这一个 key
        return {_LLM_MESSAGES_KEY: llm_messages}

    return build_context_node


async def agent_node(state: AgentState) -> Dict[str, Any]:
    """调用 LLM，非流式拿完整回复，追加到 messages。

    注意：本节点仅用于非流式 `ainvoke` 路径。
    流式路径走外层 `run_chat_stream`，绕过 graph 自己取 token——这样能拿到原生 SSE 分片，
    避免 langchain 包装层在中间额外组帧。
    """
    gateway = get_gateway()
    llm_messages = state.get(_LLM_MESSAGES_KEY, [])
    model = state.get("model") or None

    result = await gateway.chat_sync(messages=llm_messages, model=model)
    reply_text = result.get("content", "") or ""

    return {
        "messages": [AIMessage(content=reply_text)],
        "final_response": reply_text,
    }
