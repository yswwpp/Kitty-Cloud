# Kitty-Cloud Agent 自研技术方案

> ✅ **本方案已实施完成（Phase 1）。** 实际实现的技术文档请参阅 [技术文档.md](./技术文档.md)。
>
> 本文档是方案设计稿（v1.0），记录了替换 OpenClaw 的设计决策和规划。部分内容（如 Phase 2/3 工具和记忆）尚未实现，实际实现细节以技术文档为准。

> 基于 LangGraph 替换 OpenClaw，构建项目专属的 Agent Runtime

---

## 一、为什么要替换 OpenClaw？

### 1.1 第一性原理分析

先问根本问题：**Kitty-Cloud 到底需要一个什么样的 Agent？**

```
用户语音输入 → ASR → Agent(理解意图、调用工具、生成回复) → TTS → 语音输出
```

Kitty 是一个**个人语音助手**，核心场景是：
- 自然对话（闲聊、问答）
- 调用工具（查天气、查日程、发通知等）
- 记住用户偏好（长期记忆）

OpenClaw 是一个通用 Agent 框架，它为"所有场景"设计，必然有大量 Kitty 不需要的抽象。用 OpenClaw 的本质问题是：

> **你用一个通用框架，却只用了它 10% 的能力，同时被它 90% 的设计决策所约束。**

### 1.2 替换的核心收益

| 维度 | OpenClaw | 自研 Agent |
|------|----------|-----------|
| 模型切换 | 通过 x-openclaw-model header | 直接调用多 Provider，天然支持 |
| 流式响应 | 代理转发，多一跳延迟 | 直连 LLM，延迟更低 |
| 工具调用 | OpenClaw 的工具系统 | 自己掌控，按需扩展 |
| 记忆管理 | OpenClaw 的 session 机制 | 分层记忆，更精准 |
| 调试排错 | 黑盒 | 全链路可控 |
| 部署依赖 | 额外进程 | 无外部依赖 |

---

## 二、核心架构设计

### 2.1 总体架构

```
                    iOS App (Kitty Client)
                         │
                    HTTPS / SSE
                         │
              ┌──────────┴──────────┐
              │   FastAPI Gateway    │
              │   - /chat (SSE)      │
              │   - /asr (WebSocket) │
              │   - /tts (HTTP)      │
              │   - /models          │
              └──────────┬──────────┘
                         │
              ┌──────────┴──────────┐
              │   Agent Runtime      │
              │   ┌───────────────┐  │
              │   │ Context Engine │  │
              │   ├───────────────┤  │
              │   │ LangGraph      │  │
              │   │ StateGraph     │  │
              │   ├───────────────┤  │
              │   │ Tool Router    │  │
              │   ├───────────────┤  │
              │   │ Memory Manager │  │
              │   └───────────────┘  │
              └──────────┬──────────┘
                         │
              ┌──────────┴──────────┐
              │   LLM Gateway        │
              │   bailian / qianfan  │
              │   / litellm          │
              └──────────┬──────────┘
                         │
              ┌──────────┴──────────┐
              │   SQLite             │
              │   - Checkpoints      │
              │   - Long-term Memory │
              └─────────────────────┘
```

### 2.2 设计原则

1. **LangGraph 只是 Workflow Runtime**，不是 Agent Framework
   - 状态机、条件分支、检查点由 LangGraph 负责
   - 记忆策略、上下文组装、工具路由由我们自己控制
   - 不把业务逻辑写死在 Node 里

2. **渐进式替换**
   - V1：替换 `/chat` 端点，保持 API 兼容
   - V2：增加工具调用能力
   - V3：增加长期记忆

3. **个人项目级别的基础设施**
   - 用 SQLite，不用 PostgreSQL
   - 单进程部署，不引入 Redis / Qdrant / Temporal
   - 代码量控制在可维护范围内

---

## 三、技术选型

| 模块 | 技术 | 理由 |
|------|------|------|
| Agent Runtime | LangGraph `StateGraph` | 成熟的 Graph API，社区资源丰富 |
| Checkpointer | `AsyncSqliteSaver` | 异步 SQLite，单机生产可用 |
| Long-term Store | LangGraph `Store` + SQLite | 官方内置，无需额外向量数据库 |
| LLM 调用 | `httpx` 直接调用 | 项目已有 models.json 多 Provider 体系，可精确控制字节顺序 |
| **主力模型** | **DeepSeek 官方 API** | **支持自动 Prefix Cache，配合本方案可达 95%+ 命中率** |
| Cache 策略 | Context Partitioning + 三不变式 | 参考 DeepSeek-Reasonix 实践 |
| API 框架 | FastAPI（复用） | 不改现有框架 |
| 流式响应 | SSE | 保持与前端兼容 |
| 依赖管理 | pip + requirements.txt | 保持简单 |

### 3.1 为什么选 SQLite 而不是 PostgreSQL？

**第一性原理**：Kitty 是个人助手，单用户（或极少用户），不存在分布式并发写入。SQLite 的优势：

- 零运维：不需要额外进程
- 足够快：单机 WAL 模式下读写性能优秀
- 足够可靠：SQLite 是全世界部署最广的数据库
- 备份简单：一个文件 `cp` 即可

PostgreSQL 的并发控制、连接池、主从复制对 Kitty 来说都是**过度设计**。

### 3.2 为什么不引入向量数据库？

Kitty 的长期记忆量级是"一个用户几年的偏好和对话摘要"，最多几千条。SQLite 的 LIKE 查询 + 简单的关键词匹配完全够用。向量搜索需要额外部署 Qdrant/Milvus/Chroma，增加了运维复杂度，ROI 极低。

等记忆量真的超过万条级别时，再引入 `sqlite-vec` 扩展或在 SQLite 中加一张 embedding 表即可。

---

## 四、目录结构

```
kitty-server/
├── main.py                    # FastAPI 入口（现有，渐进修改）
├── agent/
│   ├── __init__.py
│   ├── graph.py               # LangGraph 图定义
│   ├── state.py               # AgentState 定义
│   ├── nodes.py               # 图节点实现（agent_node, tool_node）
│   ├── context.py             # Context Engine（上下文组装）
│   ├── tools.py               # 工具定义与注册
│   └── memory.py              # 长期记忆管理
├── llm/
│   ├── __init__.py
│   ├── gateway.py             # 多 Provider LLM 调用网关
│   └── models.py              # 模型配置加载
├── models.json                # 模型配置（现有）
├── .env.example               # 环境变量（现有）
├── requirements.txt           # 依赖管理
└── tests/
    ├── test_api.py            # API 测试（现有）
    ├── test_chat.py           # 聊天测试（现有）
    └── test_agent.py          # Agent 单元测试
```

---

## 五、LangGraph 图设计

### 5.1 状态定义

```python
from typing import TypedDict, Annotated, List, Dict, Any
from langgraph.graph.message import add_messages
from langchain_core.messages import BaseMessage

class AgentState(TypedDict):
    # 消息历史，add_messages 自动追加而非覆盖
    messages: Annotated[List[BaseMessage], add_messages]
    # 当前用户 ID
    user_id: str
    # 当前会话 ID（thread_id 已在 config 中，这里用于业务逻辑）
    session_id: str
    # 工具执行结果（本轮）
    tool_results: List[Dict[str, Any]]
    # 召回的长期记忆
    recalled_memories: List[str]
    # 最终回复
    final_response: str
```

### 5.2 节点设计

```
        START
          │
          ▼
   ┌──────────────┐
   │ build_context │  ← 组装系统提示词、召回长期记忆、裁剪历史
   └──────┬───────┘
          │
          ▼
   ┌──────────────┐
   │    agent      │  ← LLM 决策：直接回复 or 调用工具？
   └──────┬───────┘
          │
     ┌────┴────┐
     │ route   │  ← 条件边：有 tool_calls → tools，否则 → response
     └────┬────┘
          │
     ┌────┴──────────┐
     ▼               ▼
┌─────────┐   ┌──────────────┐
│  tools  │   │   response   │
└────┬────┘   └──────┬───────┘
     │               │
     ▼               │
  (回到 agent)        │
                      ▼
              ┌──────────────┐
              │ save_memory  │  ← 提取并存储长期记忆
              └──────┬───────┘
                     │
                     ▼
                   END
```

### 5.3 关键设计决策

**为什么 agent → tools → agent 是一个循环？**

这是经典的 ReAct 模式。工具执行完毕后，LLM 需要看到工具返回结果，然后决定：
- 信息够了，生成最终回复
- 还需要调用另一个工具
- 工具结果不理想，换个方式重试

这个循环是 Agent 智能的核心。

**递归上限保护**：

```python
config = {
    "configurable": {"thread_id": session_id},
    "recursion_limit": 10  # 最多 10 轮 agent-tool 循环
}
```

**为什么 context 节点独立？**

Context 组装是 Agent 质量的决定性因素——不是 Prompt Engineering，是 Context Engineering。独立出来便于：
- 按 Token Budget 裁剪历史
- 注入长期记忆
- 注入工具描述
- 未来 A/B 测试不同上下文策略

---

## 六、LLM 网关设计

### 6.1 为什么不用 LiteLLM？

LiteLLM 是一个优秀的 LLM 代理，但它是一个**独立服务**。Kitty 已经有 `models.json` 定义了多 Provider，且每个 Provider 的 API 协议已知（OpenAI 兼容 或 Anthropic 兼容）。直接用 `httpx` 调用：

- 不引入新的服务依赖
- 延迟更低（少一跳网络）
- 代码量很小（~200 行）
- **可以精确控制消息拼接顺序，最大化 KV Cache 命中率**（详见 6.4 节）

### 6.2 网关接口

```python
from typing import AsyncIterator, Dict, Any

class LLMGateway:
    """统一的 LLM 调用网关，支持多 Provider"""

    async def chat(
        self,
        model: str,           # "bailian/qwen3.6-plus"
        messages: list[dict],
        tools: list[dict] | None = None,
        stream: bool = True,
    ) -> AsyncIterator[Dict[str, Any]]:
        """流式调用 LLM，返回 SSE chunk 迭代器"""
        ...

    async def chat_sync(
        self,
        model: str,
        messages: list[dict],
        tools: list[dict] | None = None,
    ) -> dict:
        """非流式调用 LLM，返回完整响应"""
        ...
```

核心逻辑：
1. 解析 model ID → 找到对应 Provider 配置
2. 根据 Provider 的 `api` 类型（`openai-completions` / `anthropic-messages`）选择请求格式
3. 从环境变量读取 API Key
4. 发起 HTTP 请求，返回流/非流结果

### 6.3 模型选择策略

```
优先级：用户指定 model > 会话默认 model > 环境变量 DEFAULT_MODEL > 第一个可用模型
```

### 6.4 Cache-First LLM 调用策略

> 参考 [DeepSeek-Reasonix](https://github.com/esengine/DeepSeek-Reasonix) 项目的 KV Cache 优化实践。

DeepSeek 官方 API 支持自动前缀缓存（Prefix Cache），但它的匹配规则是**严格的字节前缀匹配**——当前请求与前一次请求的前缀字节必须完全一致才能命中缓存。大多数 Agent 实现每轮都会重排消息、改写内容或注入时间戳，导致实际缓存命中率极低。

Reasonix 项目的实测数据：**435M input tokens，99.82% cache hit，成本从 ~$61 降至 ~$12**。

我们的 LLM 网关必须从架构层面保证字节前缀稳定。

#### 6.4.1 核心原则：Cache 是架构不变量，不是开关

```
Cache stability isn't a feature you turn on;
it's an invariant the loop is designed around.
```

这意味着：消息拼接顺序、system prompt 格式、工具描述序列化——所有层级的决策都以维持字节级稳定为目标。

#### 6.4.2 上下文三区划分（Context Partitioning）

将发送给 LLM 的消息列表划分为三个区域：

```
┌─────────────────────────────────────────────┐
│  IMMUTABLE PREFIX（不可变前缀区）             │
│  - system prompt                            │
│  - tool_specs（工具描述 JSON）               │
│  - 长期记忆（用户偏好、知识摘要）             │
│                                             │
│  特性：会话开始时计算一次，哈希固定，永不修改   │
│  → 这部分是 Cache 命中的核心保障              │
├─────────────────────────────────────────────┤
│  APPEND-ONLY LOG（只追加日志区）              │
│  - user₁ → assistant₁ → tool₁ → assistant₂  │
│  - user₂ → assistant₃ → ...                 │
│                                             │
│  特性：只允许追加，不允许修改/插入/删除已有条目  │
│  → 上一轮的完整字节序在下一轮完整保留          │
│  → DeepSeek 可以一路匹配到上次追加的末尾       │
│  → 仅最后一轮新增内容触发 cache miss           │
├─────────────────────────────────────────────┤
│  VOLATILE SCRATCH（挥发性草稿区）             │
│  - 推理链中间状态                             │
│  - 临时计划、未完成的 JSON                     │
│                                             │
│  特性：绝不发送给 LLM API                     │
│  → 草稿区的"脏数据"不会污染字节前缀           │
│  → 需要持久化的信息经蒸馏后才进入 Log 区       │
└─────────────────────────────────────────────┘
```

#### 6.4.3 三条 Cache 不变式

| # | 不变式 | 字节级影响 |
|---|--------|----------|
| 1 | **Prefix 计算一次、哈希、固定** | API 调用的前 N 字节在会话内完全一致，DeepSeek 服务端识别为缓存命中 |
| 2 | **Log 仅追加、不重写** | 上一轮的完整字节序在下一轮完整保留，只有尾部新增内容 miss |
| 3 | **Scratch 经蒸馏后才入 Log** | 防止格式错误、未完成 JSON 等脏数据破坏 Log 区字节一致性 |

#### 6.4.4 具体实现：消息拼接顺序

这是最关键的细节。每次调用 LLM API 时，消息列表必须严格按照以下顺序拼接：

```python
def build_cache_stable_messages(
    system_prompt: str,       # 固定，不包含动态内容
    tool_specs: list[dict],   # 固定顺序的工具描述
    memories: list[str],      # 固定顺序的长期记忆
    history: list[dict],      # 只追加的对话历史
    current_user_msg: str,    # 当前用户消息
) -> list[dict]:
    """
    构建字节级稳定的消息列表，最大化 DeepSeek KV Cache 命中率。
    
    拼接顺序（一旦确定，整个会话期间不可改变）：
    [system] → [tool_specs] → [memories] → [history...] → [current_user_msg]
    
    每次调用时，前面的部分完全不变，只有尾部增长。
    """
    messages = []

    # ── Zone 1: IMMUTABLE PREFIX ──
    # 1. System prompt（严格固定，不注入动态时间戳等可变内容）
    messages.append({"role": "system", "content": system_prompt})

    # 2. Tool specs（按注册顺序排列，会话期间工具集不变）
    #    作为 system 消息的补充，或通过 tools 参数传递
    #    关键：tools 参数的 JSON 序列化顺序必须稳定

    # 3. 长期记忆（排序后拼接，确保顺序稳定）
    for mem in sorted(memories):
        messages.append({"role": "system", "content": f"[记忆] {mem}"})

    # ── Zone 2: APPEND-ONLY LOG ──
    # 4. 对话历史（原样追加，绝不修改已有条目）
    messages.extend(history)

    # 5. 当前用户消息
    messages.append({"role": "user", "content": current_user_msg})

    return messages
```

#### 6.4.5 常见的 Cache 杀手及规避

| Cache 杀手 | 典型做法 | 本方案规避 |
|-----------|---------|----------|
| System prompt 中注入当前时间 | `"现在是 2026-05-30 14:23:51"` | 时间信息通过 `get_current_time` 工具获取，不写入 prefix |
| 每轮重排消息顺序 | 按 relevance 排序历史 | 严格按时间顺序追加，不重排 |
| 工具描述动态增减 | 只注入本轮需要的工具 | 会话期间工具集固定不变 |
| 历史消息被改写/摘要替换 | 超长时压缩旧消息 | 只追加不修改；超长时从头部截断（保持尾部稳定） |
| Tool result 包含随机内容 | UUID、timestamp 等 | Tool handler 输出确定性内容 |
| JSON 序列化顺序不一致 | dict 迭代顺序不确定 | 使用 `json.dumps(sort_keys=True)` |

#### 6.4.6 历史裁剪策略（Cache 友好）

当对话历史超过 Token Budget 时，从**头部截断**而非摘要替换：

```python
def trim_history(history: list[dict], max_tokens: int) -> list[dict]:
    """
    Cache 友好的历史裁剪：从头部丢弃旧消息。
    
    为什么不从尾部截断？
    - 尾部是最近的消息，语义价值最高
    - 尾部是上一轮 cache 命中的后缀，丢弃会破坏字节前缀
    
    为什么不用摘要替换？
    - 替换会改变中间字节，导致从替换点往后全部 cache miss
    - 截断只影响头部，尾部保持不变，cache 从截断点之后仍然命中
    """
    while estimate_tokens(history) > max_tokens and len(history) > 2:
        # 成对删除最早的 user+assistant 轮次
        history = history[2:]
    return history
```

注意：头部截断会导致 prefix 区后面的字节偏移变化，DeepSeek 的严格前缀匹配仍然会 miss。但这是不可避免的权衡——截断是稀有操作（长会话才触发），且 miss 只影响一轮，下一轮又稳定了。

#### 6.4.7 Cache 命中率监控

在 LLM 网关中记录每次调用的 cache 命中情况：

```python
@dataclass
class CacheMetrics:
    prompt_cache_hit_tokens: int = 0
    prompt_cache_miss_tokens: int = 0

    @property
    def hit_rate(self) -> float:
        total = self.prompt_cache_hit_tokens + self.prompt_cache_miss_tokens
        return self.prompt_cache_hit_tokens / total if total > 0 else 0.0

# DeepSeek API 响应的 usage 字段中包含：
# "prompt_cache_hit_tokens": 12345,
# "prompt_cache_miss_tokens": 678
```

在服务端日志中输出命中率，用于调优。

#### 6.4.8 多 Provider Cache 兼容性

| Provider | Prefix Cache 支持 | 备注 |
|----------|------------------|------|
| DeepSeek 官方 | ✅ 自动前缀缓存 | 严格字节匹配，本方案主要优化目标 |
| 百炼（通义） | ✅ 支持 context caching | 需要显式创建 cache，策略略有不同 |
| 千帆 | ⚠️ 部分模型支持 | 按模型不同 |
| LiteLLM 代理 | ⚠️ 取决于后端 | 透传后端能力 |

**策略**：所有 Provider 统一采用三区划分 + 三条不变式。即使某些 Provider 不支持 prefix cache，这种结构化组织也不会产生负面影响，反而在支持 cache 的 Provider 上自动获得高命中率。

---

## 七、Context Engine（上下文引擎）

这是整个 Agent 质量的**核心**。

### 7.1 职责

```
Context Engine
├── 系统提示词组装（角色、规则、当前时间等）
├── 长期记忆注入（用户偏好、历史摘要）
├── 对话历史裁剪（Token Budget 管理）
├── 工具描述注入
└── 最终 Prompt 构建
```

### 7.2 Token Budget 策略

```python
# Token 预算分配
BUDGET = 32000  # 根据模型上下文窗口调整
SYSTEM_PROMPT = 2000   # 系统提示词
MEMORIES = 1000        # 长期记忆
TOOLS = 2000           # 工具描述
HISTORY = BUDGET - SYSTEM_PROMPT - MEMORIES - TOOLS - 4000  # 剩余给对话历史
# 4000 预留给当前回复
```

历史裁剪策略：**从头部截断，保持尾部稳定**（详见 6.4.6 节，Cache 友好）。

> ⚠️ **不要使用"摘要替换"策略**。摘要会改变中间字节，导致从替换点往后全部 cache miss。头部截断虽然也会破坏前缀，但只影响触发截断的那一轮，下一轮 cache 又会重新稳定。

### 7.3 系统提示词

复用现有的 `VOICE_SYSTEM_PROMPT`（语音对话风格），在此基础上增加：

```
## 工具使用
你可以调用工具来获取信息或执行操作。
- 当需要实时数据时，主动调用工具
- 工具返回结果后，用口语化的方式转述给用户
- 不要告诉用户"我正在调用工具"，直接呈现结果

## 记忆
- 你拥有长期记忆能力，会记住用户的重要偏好和信息
- 对话中提到用户的喜好、习惯、个人信息时，这些会被自动记录
```

---

## 八、Memory 系统

### 8.1 双层记忆架构

| 层级 | 存储 | 生命周期 | 内容 |
|------|------|---------|------|
| 短期 | LangGraph Checkpointer (SQLite) | 跨轮对话 | 完整消息历史、工具调用结果 |
| 长期 | LangGraph Store (SQLite) | 跨会话 | 用户偏好、重要信息摘要 |

### 8.2 短期记忆（Checkpointer）

LangGraph 的 Checkpointer 在每次 `ainvoke` 时自动：
1. 保存当前状态快照到 SQLite
2. 下次同一 `thread_id` 调用时自动恢复状态
3. 支持 `recursion_limit` 中断保护

**前端不需要任何改动**——只需继续传 `session_id` 作为 `thread_id`。

### 8.3 长期记忆（Store）

在 `save_memory` 节点中，用一个 LLM 调用分析本轮对话：

```
输入：本轮 user/assistant 消息
输出：JSON
{
  "has_new_info": true/false,
  "memories": [
    {"type": "preference", "content": "用户偏好简洁回复，不喜欢长篇大论"},
    {"type": "fact", "content": "用户常驻城市：深圳"}
  ]
}
```

存储到 LangGraph Store 中。下次 `build_context` 时自动召回相关记忆注入系统提示词。

### 8.4 为什么不用 Mem0？

Mem0 是一个很好的记忆管理库，但它：
- 依赖外部向量数据库
- 增加了依赖复杂度
- 对于单用户场景过度设计

LangGraph 内置的 Store 已经提供了 CRUD + 搜索能力，对于 Kitty 的量级完全足够。

---

## 九、Tool System

### 9.1 V1 工具列表

| 工具 | 描述 | 优先级 |
|------|------|--------|
| `search_memory` | 搜索用户的长期记忆 | P0 |
| `get_current_time` | 获取当前时间 | P1 |
| `fetch_user_profile` | 获取用户档案信息 | P1 |
| `web_search` | 网络搜索（可选） | P2 |

### 9.2 工具接口

```python
from typing import Callable, Dict, Any
from dataclasses import dataclass

@dataclass
class Tool:
    name: str
    description: str
    parameters: Dict[str, Any]  # JSON Schema
    handler: Callable          # async def handler(**kwargs) -> str

# 工具注册表
tool_registry: Dict[str, Tool] = {}

def register_tool(tool: Tool):
    tool_registry[tool.name] = tool

def get_tool_schemas() -> list[dict]:
    """生成 OpenAI Function Calling 格式的工具列表"""
    return [
        {
            "type": "function",
            "function": {
                "name": t.name,
                "description": t.description,
                "parameters": t.parameters,
            }
        }
        for t in tool_registry.values()
    ]
```

### 9.3 工具执行安全

```python
async def execute_tool(name: str, args: dict, state: AgentState) -> str:
    tool = tool_registry[name]
    # 安全检查：注入 session 级别的参数，防止前端篡改
    if "user_id" in tool.parameters.get("properties", {}):
        args.setdefault("user_id", state["user_id"])
    # 超时保护
    try:
        result = await asyncio.wait_for(tool.handler(**args), timeout=30)
        return str(result)
    except asyncio.TimeoutError:
        return f"工具 {name} 执行超时"
```

---

## 十、API 兼容性设计

### 10.1 保持现有 API 不变

```python
class ChatRequest(BaseModel):
    message: str
    session_id: Optional[str] = "default"
    history: list = []
    model: Optional[str] = None
    stream: Optional[bool] = True

@app.post("/chat")
async def chat(req: ChatRequest):
    # 之前：转发给 OpenClaw
    # 现在：调用 LangGraph Agent
    ...
```

前端 iOS 代码**零改动**。

### 10.2 流式响应格式兼容

继续使用 SSE 格式：
```
data: {"choices":[{"delta":{"content":"你好"}}]}\n\n
data: [DONE]\n\n
```

### 10.3 非流式响应格式兼容

```json
{
  "role": "assistant",
  "content": "回复内容"
}
```

---

## 十一、流式响应实现

### 11.1 核心挑战

LangGraph 的 `astream_events` 可以捕获每个节点的输出事件。但需要注意：

1. 只在 `on_chat_model_stream` 事件中提取 token
2. 过滤掉工具调用过程中的内部 token
3. 确保 `[DONE]` 标志正确发送

### 11.2 实现

```python
async def event_generator():
    async for event in graph.astream_events(input_state, config, version="v2"):
        kind = event["event"]
        if kind == "on_chat_model_stream":
            content = event["data"]["chunk"].content
            if content:
                yield f"data: {json.dumps({'choices': [{'delta': {'content': content}}]})}\n\n"
    yield "data: [DONE]\n\n"
```

---

## 十二、依赖管理

### 12.1 requirements.txt

```
# Web Framework
fastapi==0.115.0
uvicorn[standard]==0.34.0

# LangGraph Agent Runtime
langgraph>=0.3.0,<0.4.0
langgraph-checkpoint-sqlite>=3.0.1   # 注意：3.0.1 修复了 SQL 注入 CVE
langchain-core>=0.3.0
langchain-openai>=0.3.0

# LLM HTTP Client
httpx>=0.28.0

# PDF Processing (已有)
pdfplumber>=0.11.0

# WebSocket (已有，ASR)
websockets>=14.0

# Data Validation (已有)
pydantic>=2.0.0
```

### 12.2 关键版本约束说明

- `langgraph-checkpoint-sqlite >= 3.0.1`：修复了 CVE-2025-67644 SQL 注入漏洞
- `langgraph >= 0.3.0`：稳定版本，支持 StateGraph + Store
- 不引入 `langgraph-checkpoint-postgres`（个人项目不需要）

---

## 十三、开发阶段规划

### Phase 1：核心替换（1-2 天）

**目标**：`/chat` 端点从 OpenClaw 切换到 LangGraph，其他一切不变。

- [ ] 创建 `agent/` 模块目录结构
- [ ] 在 `models.json` 中新增 DeepSeek 官方 Provider 配置
- [ ] 实现 `llm/gateway.py`（多 Provider LLM 调用 + DeepSeek 适配）
- [ ] 实现 `llm/cache.py`（**字节级稳定的消息拼接** + cache 命中率统计）
- [ ] 实现 `agent/state.py`（AgentState 定义）
- [ ] 实现 `agent/graph.py`（LangGraph 图定义）
- [ ] 实现 `agent/nodes.py`（agent_node + response 节点）
- [ ] 实现 `agent/context.py`（三区划分：Immutable Prefix / Append-Only Log / Volatile Scratch）
- [ ] 修改 `main.py` 的 `/chat` 端点，调用 Agent
- [ ] 验证流式 + 非流式响应正常
- [ ] 验证模型切换正常
- [ ] **验证 DeepSeek Cache 命中率达到 80%+（多轮对话场景）**

**验证标准**：
1. iOS App 聊天功能完全正常，行为与之前一致
2. 服务端日志输出每次调用的 cache 命中率
3. 同一会话连续 5 轮对话，从第 2 轮开始 cache 命中率应 > 80%

### Phase 2：Memory（1 天）

**目标**：会话记忆持久化 + 长期记忆。

- [ ] 集成 `AsyncSqliteSaver` 作为 Checkpointer
- [ ] 实现 `agent/memory.py`（长期记忆提取 + 存储）
- [ ] 实现 `save_memory` 节点
- [ ] `build_context` 节点中注入长期记忆
- [ ] 测试跨会话记忆召回

**验证标准**：重启服务后会话不丢失；新会话中能回忆起之前提到的用户偏好。

### Phase 3：Tools（1 天）

**目标**：Agent 可以调用工具。

- [ ] 实现 `agent/tools.py`（工具注册 + 执行）
- [ ] 实现 `tool_node`
- [ ] 实现条件路由（agent → tools → agent 循环）
- [ ] 添加 `get_current_time`、`search_memory` 工具
- [ ] 流式响应中增加工具调用状态事件

**验证标准**：问"现在几点"，Agent 调用工具后正确回答。

### Phase 4：增强（按需）

- [ ] 支持图片输入（多模态）
- [ ] 支持 MCP 工具协议
- [ ] 用户档案系统
- [ ] Token 用量统计

---

## 十四、风险与缓解

| 风险 | 影响 | 缓解措施 |
|------|------|---------|
| LangGraph 版本 API 变化 | 升级困难 | 锁定 minor 版本，Phase 1 完成后写测试 |
| LLM 不支持 Function Calling | 工具调用失败 | 网关层检测模型能力，不支持的不注入 tools |
| SQLite 并发写入冲突 | 请求失败 | WAL 模式 + 单用户场景下概率极低 |
| Checkpoint 数据膨胀 | 磁盘占满 | 定期清理 7 天前的旧 checkpoint |
| 流式响应中断 | 用户体验差 | `recursion_limit` 截断 + 错误事件通知前端 |

---

## 十五、与三份参考文档的差异说明

| 设计决策 | Gemini 文档 | DeepSeek 文档 | OpenAI 文档 | **本方案** |
|---------|------------|--------------|------------|----------|
| LangGraph API | StateGraph | StateGraph | StateGraph | **StateGraph**（相同） |
| Checkpointer | MemorySaver | SqliteSaver | PostgresSaver | **AsyncSqliteSaver**（最贴近实际） |
| 长期记忆 | 手动工具 | Mem0 | Qdrant + Embedding | **LangGraph Store + SQLite**（更轻量） |
| LLM 调用 | ChatOpenAI | ChatOpenAI | LiteLLM 服务 | **httpx 直连**（无额外服务） |
| 任务队列 | 无 | 无 | Temporal | **无**（V1 不需要） |
| 基础设施 | 无数据库 | SQLite | PostgreSQL + Redis + Qdrant + Temporal | **SQLite**（个人项目最优解） |
| 代码组织 | 单文件 main.py | 单文件 | 模块化 | **模块化 agent/** |
| 节点设计 | agent + tools 2 节点 | 未详述 | 5 节点（context/planner/tool/response/memory） | **5 节点但简化 planner** |

**核心差异**：三份文档都倾向于"企业级"架构，本方案坚定走"个人项目级"路线——用最少的组件解决最核心的问题。

---

## 十六、总结

这个方案的核心思想可以归纳为两句话：

> **LangGraph 只是 Workflow Runtime。真正的壁垒在 Context Engine + Memory Strategy + State Management，而这些只有自己掌控代码才能做好。**
>
> **Cache 不是一个开关，而是整个 Loop 的架构不变量。** 当 LLM 网关的消息拼接顺序从一开始就为字节级稳定而设计时，DeepSeek 官方 API 的 95%+ Cache 命中率就是免费送的——成本降到 1/5，延迟降到 1/3。

V1 只做一件事：把 `/chat` 端点从 `httpx.post(OpenClaw)` 替换为 `graph.ainvoke()`，配合 Cache-First 的消息拼接策略。其他一切不变。这是最小可行替换，风险最低，验证最快。

后续的 Memory、Tools 都是增量叠加，每一步都有明确的验收标准，不会出现"重构到一半发现走不下去"的情况。

---

*方案版本：v1.0 | 日期：2026-05-29*
