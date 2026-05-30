"""AgentState 定义。

Phase 1 不引入工具调用循环，先把 state 字段都定义齐全，给后续 phase 留扩展位。
"""
from __future__ import annotations

from typing import Annotated, Any, Dict, List, TypedDict

from langgraph.graph.message import add_messages


class AgentState(TypedDict, total=False):
    # add_messages：追加而非覆盖
    messages: Annotated[List[Any], add_messages]

    # 业务字段
    user_id: str
    session_id: str
    model: str                  # 用户指定的 model，可空（取默认）

    # 召回的长期记忆（Phase 2）
    recalled_memories: List[str]

    # 工具执行结果（Phase 3）
    tool_results: List[Dict[str, Any]]

    # 最终回复（流式时由外层 generator 累积）
    final_response: str

    # 临时：build_context 节点产出的、给 LLM gateway 的 OpenAI 格式消息列表
    # 由 agent_node 消费；不持久化到外部
    llm_messages: List[Dict[str, Any]]
