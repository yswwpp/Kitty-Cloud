"""Context Engine：组装发送给 LLM 的上下文。

严格遵循技术方案 6.4 / 7.x：
- IMMUTABLE PREFIX 区：system prompt（不含动态时间戳）+ 长期记忆
- APPEND-ONLY LOG 区：对话历史
- VOLATILE SCRATCH 区：暂未使用
"""
from __future__ import annotations

from typing import Any, Dict, List, Optional

from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, SystemMessage

from llm.cache import build_cache_stable_messages, trim_history


# ── Token 预算 ──────────────────────────────────────────────────────
# 注：这里只对历史做粗估截断；system / memories 由调用方控制大小
HISTORY_TOKEN_BUDGET = 20000  # 给历史的字符上限（粗估）


def langchain_to_openai(messages: List[BaseMessage]) -> List[Dict[str, Any]]:
    """LangChain BaseMessage 列表 → OpenAI Chat 格式。"""
    result: List[Dict[str, Any]] = []
    for m in messages:
        if isinstance(m, SystemMessage):
            role = "system"
        elif isinstance(m, HumanMessage):
            role = "user"
        elif isinstance(m, AIMessage):
            role = "assistant"
        else:
            # ToolMessage 等 Phase 3 再处理
            role = getattr(m, "type", "user")
        content = m.content if isinstance(m.content, str) else str(m.content)
        result.append({"role": role, "content": content})
    return result


def openai_to_langchain(messages: List[Dict[str, Any]]) -> List[BaseMessage]:
    """OpenAI Chat 格式 → LangChain BaseMessage（仅用于种入历史）。"""
    result: List[BaseMessage] = []
    for m in messages:
        role = m.get("role", "user")
        content = m.get("content", "")
        if role == "system":
            result.append(SystemMessage(content=content))
        elif role == "assistant":
            result.append(AIMessage(content=content))
        else:
            result.append(HumanMessage(content=content))
    return result


def build_llm_messages(
    system_prompt: str,
    history_messages: List[BaseMessage],
    recalled_memories: Optional[List[str]] = None,
) -> List[Dict[str, Any]]:
    """组装最终送 LLM 的消息列表。

    要点：
    - history_messages 已经包含本轮的 user 消息（LangGraph add_messages 已追加）
    - 不在 system_prompt 中注入时间戳、随机数等可变内容
    - history 从头部裁剪，保持尾部稳定（cache 友好）
    """
    history_openai = langchain_to_openai(history_messages)

    # 历史裁剪：超长时从头部丢
    history_openai = trim_history(history_openai, HISTORY_TOKEN_BUDGET)

    # build_cache_stable_messages 的 history 不含当前 user 消息时由 current_user_msg 追加；
    # 这里 history 末尾已是 user 消息（agent_node 在 add_messages 后调用），
    # 所以 current_user_msg=None
    return build_cache_stable_messages(
        system_prompt=system_prompt,
        memories=recalled_memories,
        history=history_openai,
        current_user_msg=None,
    )
