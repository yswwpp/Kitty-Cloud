# 基于 LangGraph + FastAPI 的服务端智能体（Agent）详细落地实现方案

本项目方案旨在打造一个生产级的“智能体即服务”（Agent As A Service）后端底层架构。它类似于开源的 OpenClaw，但采用了行业内更具控制力和扩展性的 **LangGraph** 作为状态机核心，结合 **FastAPI** 异步高并发 Web 框架，对外为前端产品提供标准、稳定的有记忆任务处理智能体接口。

---

## 一、 系统架构与设计哲学

### 1. 为什么选择 LangGraph？
在处理复杂任务时，传统的 LangChain 或 Sequential（顺序链）容易让大模型在调用工具失败时陷入死循环。LangGraph 将智能体抽象为**有向图（Graph）和状态机（State）**：
* **节点 (Nodes)**：代表大模型决策、工具执行或逻辑处理。
* **边 (Edges)**：定义节点的流向，支持基于大模型输出的条件分支（Conditional Edges）。
* **状态 (State)**：全局共享的上下文，大模型和工具的每次交互都在修改这个状态。

### 2. 记忆（Memory）的双层分层设计
为了让智能体兼具“短期执行任务”和“长期记住用户喜好”的能力，本方案采用分层记忆架构：
* **短中期会话记忆（Session Memory）**：利用 LangGraph 的 `Checkpointer`（检查点机制），将单次对话（Thread）的所有上下文、工具返回结果自动持久化到数据库中，前端只需传入 `session_id` 即可无缝续接对话。
* **跨会话长期记忆（Long-term Profile）**：通过特定的“记忆提取工具”，当大模型发现用户提到个人偏好时（如“我日常用 Python”），自动调用工具将其沉淀到 PostgreSQL 或向量数据库中，在下次新会话启动时作为系统 Prompt 自动加载。

---

## 二、 项目目录结构

```text
agent-backend/
├── requirements.txt         # 核心依赖管理
├── main.py                 # FastAPI 入口与 LangGraph 图核心逻辑
└── README.md               # 本设计方案说明
```

## 三、 环境依赖配置 (`requirements.txt`)

请在本地创建 `requirements.txt` 并写入以下内容：

Plaintext

```
fastapi==0.111.0
uvicorn==0.30.1
langgraph==0.0.60
langchain-core==0.2.10
langchain-openai==0.1.13
pydantic==2.7.4
psycopg==3.1.19
psycopg-binary==3.1.19
```

**安装命令**：

Bash

```
pip install -r requirements.txt
```

## 四、 核心源码实现 (`main.py`)

请创建 `main.py` 文件，并写入以下经过高并发与异步流式优化后的完整代码：

Python

```
import os
from typing import Annotated, List, Dict, Any, TypedDict
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

# LangGraph 核心组件
from langgraph.graph import StateGraph, START, END
from langgraph.graph.message import add_messages
from langgraph.checkpoint.memory import MemorySaver

# LangChain 组件
from langchain_openai import ChatOpenAI
from langchain_core.messages import BaseMessage, HumanMessage, AIMessage, SystemMessage
from langchain_core.tools import tool

app = FastAPI(title="Enterprise Agent As A Service")

# 允许前端跨域访问（CORS）
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # 生产环境请限制为前端域名
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# -------------------------------------------------------------
# 1. 定义业务工具核心 (Tools)
# -------------------------------------------------------------
@tool
def fetch_user_profile(user_id: str) -> str:
    """当大模型需要获取用户的背景信息、偏好、习惯或基本资料时调用此工具。"""
    # 模拟企业数据库查询，生产环境可对接 MySQL/PostgreSQL
    if user_id == "user_123":
        return "用户特征：倾向于看极简的结论，技术栈是 Python/Vue，常驻城市是新加坡。"
    return "未找到该用户的特定个性化偏好偏好。"

@tool
def process_business_task(task_details: str) -> str:
    """当用户要求处理特定任务（如发送业务通知、记录日程、投递后台任务队列）时调用。"""
    # 真实的业务异步任务分发逻辑可以写在这里
    return f"[系统通知] 任务 '{task_details}' 已成功投递至生产环境后台异步队列处理。"

# 将工具放入注册表，供图节点和 LLM 绑定使用
tools = [fetch_user_profile, process_business_task]
tools_map = {t.name: t for t in tools}

# -------------------------------------------------------------
# 2. 定义 LangGraph 状态机与处理节点
# -------------------------------------------------------------
class AgentState(TypedDict):
    # add_messages 是关键：它指示 LangGraph 自动追加对话历史，而非覆盖原有列表
    messages: Annotated[List[BaseMessage], add_messages]
    user_id: str

# 初始化底层大模型驱动（完美兼容 DeepSeek、OpenAI、Claude 等中转接口）
llm = ChatOpenAI(
    model="gpt-4o-mini",  # 生产推荐使用符合性价比的规格
    api_key=os.getenv("OPENAI_API_KEY"),
    base_url=os.getenv("OPENAI_API_BASE")  # 可替换为中转站或国内大模型端点
).bind_tools(tools)

def agent_node(state: AgentState):
    """LLM 决策层：分析上下文，判断应当直接回复还是调用工具。"""
    messages = state["messages"]
    user_id = state["user_id"]
    
    # 全局系统注入提示词，让 Agent 具备用户身份和长期记忆感知
    system_prompt = SystemMessage(content=(
        f"你是一个拥有持久化长短期记忆的商业智能体。当前为您服务的用户 ID 为: {user_id}。\n"
        "如果你不知道用户的喜好或背景，在多轮对话开始时，请优先调用 'fetch_user_profile' 工具查询用户画像。"
    ))
    
    response = llm.invoke([system_prompt] + messages)
    return {"messages": [response]}

def tool_node(state: AgentState):
    """工具执行层：拦截大模型的 tool_calls 并在服务端本地安全执行。"""
    messages = state["messages"]
    last_message = messages[-1]
    
    tool_outputs = []
    # 循环处理大模型单次生成中提出的所有并发工具调用请求
    for tool_call in last_message.tool_calls:
        tool_obj = tools_map[tool_call["name"]]
        args = tool_call["args"]
        
        # 自动化安全机制：若工具定义中需要 user_id，强制从 Session 状态中注入，防止前端篡改
        if "user_id" in tool_obj.args:
            args["user_id"] = state["user_id"]
            
        output = tool_obj.invoke(args)
        tool_outputs.append({
            "role": "tool",
            "content": str(output),
            "tool_call_id": tool_call["id"],
            "name": tool_call["name"]
        })
    return {"messages": tool_outputs}

def should_continue(state: AgentState):
    """动态路由决策器：判断图下一步的流向。"""
    messages = state["messages"]
    last_message = messages[-1]
    
    # 检查大模型返回的数据中是否携带有工具调用请求
    if hasattr(last_message, "tool_calls") and last_message.tool_calls:
        return "tools"
    return END

# -------------------------------------------------------------
# 3. 编排并编译 LangGraph 工作流
# -------------------------------------------------------------
workflow = StateGraph(AgentState)

# 注册节点
workflow.add_node("agent", agent_node)
workflow.add_node("tools", tool_node)

# 设定图起点
workflow.add_edge(START, "agent")

# 条件分支设定：执行完 agent 后进行逻辑判断
workflow.add_conditional_edges(
    "agent",
    should_continue,
    {
        "tools": "tools",
        END: END
    }
)

# 工具执行完毕后，必须重新回到 agent 决策节点，让大模型总结工具返回的数据
workflow.add_edge("tools", "agent")

# 引入记忆检查点（开发期使用内存型 MemorySaver，生产环境请用 PostgresSaver）
memory_saver = MemorySaver()
agent_executor = workflow.compile(checkpointer=memory_saver)

# -------------------------------------------------------------
# 4. 开放给前端产品的 API 路由封装
# -------------------------------------------------------------
class ChatRequest(BaseModel):
    user_id: str
    session_id: str  # 会话隔离 ID，对应前端的 Conversation ID
    message: str

@app.post("/api/v1/chat")
async def chat_endpoint(request: ChatRequest):
    """标准阻塞接口：一次性返回 Agent 的最终回答，适用于非流式场景。"""
    try:
        # 通过 thread_id 实现多会话之间记忆的深度隔离
        config = {"configurable": {"thread_id": request.session_id}}
        
        input_state = {
            "messages": [HumanMessage(content=request.message)],
            "user_id": request.user_id
        }
        
        final_state = await agent_executor.ainvoke(input_state, config=config)
        last_ai_message = final_state["messages"][-1]
        
        return {
            "status": "success",
            "response": last_ai_message.content,
            "session_id": request.session_id
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/v1/chat/stream")
async def chat_stream_endpoint(request: ChatRequest):
    """生产级流式响应接口 (Server-Sent Events)：让前端产品实现丝滑的逐字打印效果。"""
    config = {"configurable": {"thread_id": request.session_id}}
    input_state = {
        "messages": [HumanMessage(content=request.message)], 
        "user_id": request.user_id
    }
    
    async def event_generator():
        # astream_events 可精准捕获智能体内部状态机每一步发出的事件
        async for event in agent_executor.astream_events(input_state, config, version="v2"):
            kind = event["event"]
            
            # 过滤出大模型真正输出文本 Token 的底层事件
            if kind == "on_chat_model_stream":
                content = event["data"]["chunk"].content
                if content:
                    # 遵循标准 SSE 协议格式：data: 内容 \n\n
                    yield f"data: {content}\n\n"
                    
    return StreamingResponse(event_generator(), media_type="text/event-stream")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
```

## 五、 前端产品对接规范示例 (JavaScript)

前端产品在调用服务端的 `/api/v1/chat/stream` 流式接口时，由于它是 `POST` 请求，无法直接使用传统的浏览器 `EventSource`，应当使用 `fetch` 的读取器（Reader）来优雅处理：

JavaScript

```
async function startAgentChat(userId, sessionId, userMessage) {
    const response = await fetch("[http://127.0.0.1:8000/api/v1/chat/stream](http://127.0.0.1:8000/api/v1/chat/stream)", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            user_id: userId,
            session_id: sessionId,
            message: userMessage
        })
    });

    const reader = response.body.getReader();
    const decoder = new TextDecoder("utf-8");
    let buffer = "";

    while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n\n");
        buffer = lines.pop(); // 保留不完整的一行

        for (const line of lines) {
            if (line.startsWith("data: ")) {
                const token = line.replace("data: ", "");
                // 【业务逻辑】：在这里将获得的 token 追加到前端 UI 的对话框中，实现打字机效果
                process.stdout.write(token); 
            }
        }
    }
}
```

## 六、 生产环境避坑与高并发演进路线

1. **记忆落盘（强烈推荐）**：

   当前代码使用 `MemorySaver()`（运行于服务器内存中）。一旦服务器重启，所有会话记忆都会丢失。在生产环境中，请将其替换为官方提供的 PostgreSQL 持久化适配器：

   Python

   ```
   from langgraph.checkpoint.postgres import PostgresSaver
   # 通过 psycopg 连接池初始化 PostgresSaver 即可，其他核心逻辑完全无需修改
   ```

2. **死循环硬截断**：

   为了防止大模型在调用工具失败时不断重试，导致用户的 API 账单暴涨，可以在 FastAPI 调用时在 `config` 字典中增加 `"recursion_limit": 10` 参数。一旦状态机在图中循环运行超过 10 步，LangGraph 会自动强制抛出异常截断，确保系统安全。

3. **人工介入审批（Human-In-The-Loop）**：

   在编译图时，可以使用 `agent_executor = workflow.compile(checkpointer=memory_saver, interrupt_before=["tools"])`。

   这样一来，当大模型做出涉及“删除、扣款、发送敏感任务”的决定时，状态机会自动挂起，FastAPI 会向前端返回“等待人工确认”状态。用户在前端界面点击“确认”或“驳回”后，后端通过 `.resume()` 唤醒原节点继续执行，从底层架构上完美避免 AI 失控。