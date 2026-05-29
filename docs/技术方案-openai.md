# 基于 LangGraph 的服务端 Agent Runtime 设计方案（生产级）

# 1. 项目定位

目标：

构建一个：

```text
Server-side Agent Runtime
```

支持：

- 多用户
- 长期 Memory
- Tool Calling
- Async Task
- API-first
- Streaming
- 可恢复 Workflow
- 后续支持 MCP / Browser / Code Agent

核心思想：

```text
LangGraph 只负责：
State Machine + Workflow Runtime

你自己掌控：
Memory / Context / Session / Tool / API
```

这是关键。

------

# 2. 为什么选择 LangGraph

因为 LangGraph 的核心设计：

```text
StateGraph
```

非常适合 Agent。

本质：

```text
节点（Node）
+
状态（State）
+
边（Edge）
```

Agent 天然就是：

```text
状态机
```

而不是：

```text
普通聊天
```

------

# 3. 总体架构

```text
                   Frontend / SDK
          --------------------------------
             Web / App / CLI / API
          --------------------------------
                          |
                          v

                    FastAPI Gateway
        --------------------------------------
        Auth / SSE / REST / Rate Limit
        --------------------------------------
                          |
                          v

                  Agent Runtime Layer
    -------------------------------------------------
        Session Manager
        Context Engine
        Memory Orchestrator
        Tool Router
        LangGraph Workflow Runtime
    -------------------------------------------------
            |              |               |
            v              v               v

        LiteLLM         Memory         Task Queue
                        System          Temporal
```

------

# 4. 核心技术栈

| 模块        | 技术       |
| ----------- | ---------- |
| Runtime     | LangGraph  |
| API         | FastAPI    |
| LLM Gateway | LiteLLM    |
| DB          | PostgreSQL |
| Cache       | Redis      |
| Vector DB   | Qdrant     |
| Queue       | Temporal   |
| ORM         | SQLAlchemy |
| Streaming   | SSE        |
| Auth        | JWT        |

------

# 5. LangGraph 在系统中的职责

LangGraph：

只负责：

```text
Workflow Runtime
```

不要：

- 把业务写进 Graph
- 把 Memory 写死进 Node
- 把 Tool 逻辑耦合进去

否则后面会失控。

------

# 6. Runtime 核心设计

------

# 6.1 Graph State

核心状态：

```python
from typing import TypedDict, List, Dict

class AgentState(TypedDict):

    session_id: str

    user_input: str

    messages: List[Dict]

    memories: List[Dict]

    tool_results: List[Dict]

    current_plan: Dict

    task_status: str

    final_response: str
```

注意：

```text
State 不要无限增长
```

否则：

后面 token 会炸。

------

# 7. Workflow 节点设计

------

# 7.1 Context Builder Node

职责：

- 裁剪历史
- Recall Memory
- 注入 Tool Result
- 构建 Prompt

```python
def build_context(state):

    context = context_engine.build(
        session_id=state["session_id"],
        user_input=state["user_input"]
    )

    state["messages"] = context.messages
    state["memories"] = context.memories

    return state
```

这是最核心节点。

------

# 7.2 Planner Node

职责：

- 判断是否需要 Tool
- 是否结束
- 是否创建任务

```python
def planner(state):

    response = llm.invoke(...)

    if response.tool_calls:
        return {
            "next": "tool_executor"
        }

    return {
        "next": "response"
    }
```

V1：

不要复杂 Planner。

------

# 7.3 Tool Executor Node

职责：

- 执行工具
- 处理 Retry
- Timeout
- Error

```python
def tool_executor(state):

    tool_calls = extract_tool_calls()

    results = []

    for call in tool_calls:
        result = tool_router.execute(call)
        results.append(result)

    state["tool_results"] = results

    return state
```

------

# 7.4 Response Node

职责：

- 最终回答
- Streaming

```python
def generate_response(state):

    response = llm.invoke(...)

    state["final_response"] = response

    return state
```

------

# 7.5 Memory Save Node

职责：

- 提取长期记忆
- Importance Scoring
- Embedding

```python
def save_memory(state):

    memory_service.process(
        session_id=state["session_id"],
        messages=state["messages"]
    )

    return state
```

------

# 8. Graph 流程

------

# V1 推荐流程

```text
START
  ↓
build_context
  ↓
planner
  ↓
tool_executor
  ↓
planner
  ↓
response
  ↓
save_memory
  ↓
END
```

本质：

```text
ReAct Loop
```

但：

可恢复。

------

# 9. Graph 定义

```python
from langgraph.graph import StateGraph

workflow = StateGraph(AgentState)

workflow.add_node(
    "build_context",
    build_context
)

workflow.add_node(
    "planner",
    planner
)

workflow.add_node(
    "tool_executor",
    tool_executor
)

workflow.add_node(
    "response",
    generate_response
)

workflow.add_node(
    "save_memory",
    save_memory
)
```

------

# 10. 条件边

```python
workflow.add_conditional_edges(
    "planner",
    route_next_step,
    {
        "tool_executor": "tool_executor",
        "response": "response"
    }
)
```

------

# 11. 为什么 LangGraph 很适合你

因为它天然支持：

| 能力           | LangGraph |
| -------------- | --------- |
| Checkpoint     | ✅         |
| Resume         | ✅         |
| Streaming      | ✅         |
| State Machine  | ✅         |
| DAG            | ✅         |
| Human-in-loop  | ✅         |
| Async Workflow | ✅         |

------

# 12. Session 管理

LangGraph：

不要负责 Session。

你自己做。

------

# Session 数据结构

```python
class Session:

    session_id: str

    user_id: str

    active_graph_run: str

    metadata: dict
```

存储：

```text
Postgres
```

------

# 13. Memory 系统

------

# 短期记忆

位置：

```text
Redis
```

内容：

- 最近消息
- Tool Result
- 当前 Graph 状态

------

# 长期记忆

位置：

```text
Postgres + Qdrant
```

内容：

- 用户偏好
- 历史任务
- Knowledge Summary

------

# Recall 流程

```text
User Input
    ↓
Embedding
    ↓
Qdrant Search
    ↓
Re-ranking
    ↓
Inject Context
```

------

# 14. Tool System

------

# Tool Interface

```python
class Tool:

    name: str

    description: str

    schema: dict

    async def execute(self, args):
        pass
```

------

# Tool 分类

| 类型         | 示例          |
| ------------ | ------------- |
| Internal     | memory_search |
| MCP          | filesystem    |
| Browser      | playwright    |
| External API | weather       |
| Workflow     | send_email    |
| Code         | python        |

------

# 15. Tool Router

```python
class ToolRouter:

    async def execute(
        self,
        tool_name,
        args
    ):
        pass
```

必须：

- timeout
- retry
- audit log

------

# 16. Context Engine（最重要）

真正核心。

不是：

```text
Prompt Engineering
```

而是：

```text
Context Engineering
```

------

# Context Engine 负责：

- 历史裁剪
- Tool 注入
- Memory Recall
- Prompt 组装
- Token 控制

------

# Token Budget 示例

```python
MAX_CONTEXT = 32000

history = trim_history()

memories = top_k_memories()

tool_results = latest_tools()
```

------

# 17. Streaming 设计

推荐：

```text
SSE
```

事件：

```text
token
tool_start
tool_end
task_update
memory_saved
```

------

# 18. Async Task 系统

LangGraph：

不要负责长任务。

推荐：

```text
Temporal
```

负责：

- retry
- long-running
- scheduled
- distributed workflow

------

# 19. 为什么要 Temporal

因为：

Agent 天生就是：

```text
长生命周期状态机
```

Temporal 非常适合。

------

# 20. 数据库设计

------

# sessions

```sql
id
user_id
title
created_at
```

------

# messages

```sql
id
session_id
role
content
token_count
created_at
```

------

# graph_runs

```sql
id
session_id
status
current_node
state_snapshot
```

------

# memories

```sql
id
user_id
content
embedding_id
importance
```

------

# tasks

```sql
id
status
result
retry_count
```

------

# 21. API 设计

------

# 创建 Session

```http
POST /v1/sessions
```

------

# Chat

```http
POST /v1/chat
```

支持：

- stream
- tool
- async_task

------

# SSE

```http
GET /v1/stream/{run_id}
```

------

# Task

```http
GET /v1/tasks/{id}
```

------

# 22. Observability

必须做。

------

# Logs

```text
structured logs
```

------

# Metrics

- token usage
- tool latency
- graph duration
- memory hit rate

------

# Trace

推荐：

```text
OpenTelemetry
```

------

# 23. 部署结构

```text
nginx
  ↓
fastapi
  ↓
langgraph runtime
  ↓
postgres
redis
qdrant
temporal
litellm
```

------

# 24. V1 功能边界（非常重要）

V1：

只做：

```text
Chat
+
Memory
+
Tool
+
Task
+
Streaming
```

不要做：

- Multi-agent
- Self-reflection
- Autonomous planning
- Recursive agents

------

# 25. 推荐开发顺序

------

# 第一阶段

实现：

- chat
- graph
- tool calling

------

# 第二阶段

实现：

- memory
- recall
- context engine

------

# 第三阶段

实现：

- task queue
- async workflow

------

# 第四阶段

实现：

- MCP
- browser
- code tools

------

# 26. 最重要的一句话

LangGraph：

不要当成：

```text
Agent Framework
```

而要当成：

```text
Workflow Runtime
```

真正核心：

仍然是：

```text
Context Engine
+
Memory Strategy
+
State Management
```

这些才是你未来真正的壁垒。