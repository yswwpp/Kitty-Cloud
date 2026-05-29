# LangGraph + Mem0 智能体后端详细实现方案

## 项目简介
基于 LangGraph 和 Mem0 构建的生产级智能体后端，支持：
- 工具调用（可扩展）
- 双重记忆：LangGraph Checkpointer（短期会话）+ Mem0（长期个性化记忆）
- FastAPI 接口，供前端产品调用

---

## 一、项目初始化

### 1. 创建虚拟环境并安装依赖

```bash
mkdir langgraph-agent-service
cd langgraph-agent-service
python -m venv .venv
source .venv/bin/activate  # Linux/macOS
# .venv\Scripts\activate   # Windows

pip install --upgrade pip
pip install "langgraph>=0.2" langchain langchain-openai mem0ai fastapi uvicorn python-dotenv "langgraph-checkpoint-sqlite"