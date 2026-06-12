# 🐱 Kitty Cloud

个人专属 7×24 小时语音 Agent 系统。

## 架构 v4.0

```
iOS App ──→ kitty-server (FastAPI) ──→ LangGraph Agent ──→ LLM (DeepSeek/百炼/千帆/LiteLLM)
    │              │                                                    │
    │              ├── /asr  → 火山引擎 ASR (WebSocket)                  │
    │              ├── /tts  → 火山引擎 TTS (HTTP)                       │
    │              ├── /chat → Agent Runtime (SSE 流式)                  │
    │              └── /models → models.json (5min 缓存)                │
    │                                                                   │
    └── SQLite Checkpoint ← 持久化会话历史 ←────────────────────────────┘
```

**核心特性**：
- ✅ LangGraph Agent 替换 OpenClaw，直连 LLM，延迟更低
- ✅ Cache-First 调用策略，DeepSeek KV Cache 命中率 80%+
- ✅ 多 Provider 支持（DeepSeek / 百炼 / 千帆 / LiteLLM），模型热切换
- ✅ SQLite Checkpoint 持久化，重启不丢会话
- ✅ 宿主机 systemd 部署，程序与配置/数据分离

## 项目结构

```
Kitty-Cloud/
├── kitty-server/                 # Python 服务端
│   ├── main.py                   # FastAPI 入口
│   ├── agent/                    # LangGraph Agent 模块
│   │   ├── state.py              #   AgentState 定义
│   │   ├── context.py            #   Context Engine（三区划分）
│   │   ├── nodes.py              #   LangGraph 节点
│   │   └── graph.py              #   图定义 + 运行入口
│   ├── llm/                      # LLM 调用模块
│   │   ├── gateway.py            #   多 Provider 网关
│   │   └── cache.py              #   Cache 策略 + 命中率统计
│   ├── models.json               # 模型配置
│   ├── deploy/                   # systemd 部署配置
│   └── Dockerfile                # legacy Docker 配置
│
├── kitty-client/                 # iOS 客户端 (Swift + SwiftUI)
│
└── docs/                         # 文档
    ├── 技术文档.md                # ⭐ 完整技术文档（v4.0）
    └── ...
```

## 快速开始

### 服务端部署

```bash
# 1. 配置外部数据目录
cd /home/yswwpp/dev/docker_file_sharing/kitty-server
# 编辑 .env（API key、DEFAULT_MODEL 等）
# 编辑 models.json（模型配置）

# 2. 启动
cd /home/yswwpp/dev/project/tools/Kitty-Cloud
./deploy.sh

# 3. 验证
curl http://127.0.0.1:8081/
curl http://127.0.0.1:8081/models
```

生产环境程序部署到 `/home/yswwpp/deploy/kitty-cloud/current`，Python 虚拟环境在
`/home/yswwpp/deploy/kitty-cloud/.venv`。`.env`、`models.json` 和 checkpoint
数据库保留在 `/home/yswwpp/dev/docker_file_sharing/kitty-server`，更新程序不会覆盖数据。

### iOS 客户端

```bash
cd kitty-client
open Kitty.xcworkspace
# 在 Xcode 中配置服务器地址，然后运行
```

## 文档

| 文档 | 说明 |
|------|------|
| [技术文档.md](docs/技术文档.md) | ⭐ 完整技术文档（架构、API、部署、设计决策） |
| [技术方案-LangGraph-Agent-Final.md](docs/技术方案-LangGraph-Agent-Final.md) | LangGraph 替换方案设计稿（已实施） |
| [技术方案.md](docs/技术方案.md) | v3.x 架构方案（已归档） |

## 凭证配置

| 凭证 | 来源 | 配置位置 |
|------|------|---------|
| DeepSeek API Key | DeepSeek 控制台 | `.env` → `DEEPSEEK_API_KEY` |
| 百炼 API Key | 阿里云控制台 | `.env` → `BAILIAN_API_KEY` |
| 千帆 API Key | 百度智能云 | `.env` → `QIANFAN_API_KEY` |
| LiteLLM API Key | LiteLLM Proxy | `.env` → `LITELLM_API_KEY` |
| 火山引擎 ASR Token | 火山引擎控制台 | `.env` → `VOLC_ASR_TOKEN` |
| 火山引擎 TTS Token | 火山引擎控制台 | `.env` → `VOLC_TTS_TOKEN` |
