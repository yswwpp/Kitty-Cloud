# Kitty Server 部署说明

## 服务器信息

- IP: `10.8.0.122`
- 端口: `8081`
- 部署方式: Docker Compose

---

## 1. 部署方式

### 使用 deploy.sh 脚本（推荐）

项目根目录有 `deploy.sh` 脚本，一键部署：

```bash
./deploy.sh
```

脚本会自动：
1. 检查本地未提交的修改，提示提交并推送
2. SSH 到服务器执行 git pull
3. 重建 Docker 容器并启动
4. 显示日志并验证健康检查

### 手动部署

```bash
ssh -i ~/.ssh/yswwpp yswwpp@10.8.0.122 "
  export http_proxy=http://127.0.0.1:7890 &&
  export https_proxy=http://127.0.0.1:7890 &&
  cd /home/yswwpp/dev/project/tools/Kitty-Cloud &&
  git pull origin main &&
  cd kitty-server &&
  docker rm -f kitty-server 2>/dev/null || true &&
  docker-compose build &&
  docker-compose up -d
"
```

---

## 2. 环境配置

### .env 文件

```env
# OpenClaw LLM 服务配置
OPENCLAW_URL=http://host.docker.internal:18789
OPENCLAW_TOKEN=f894296566d6b5365d2dd6ec9b19ecb70555add6cd73b0c7

# 火山引擎 ASR 配置
VOLC_ASR_APP_ID=3214571057
VOLC_ASR_TOKEN=RSi0XcS9HHmyVMcvhie9-yDo_tIxRWE0
VOLC_ASR_RESOURCE_ID=volc.seedasr.sauc.duration

# 火山引擎 TTS 配置
VOLC_TTS_APP_ID=3214571057
VOLC_TTS_TOKEN=RSi0XcS9HHmyVMcvhie9-yDo_tIxRWE0
VOLC_TTS_CLUSTER=volcano_tts
```

**注意**：
- `host.docker.internal` 用于容器访问宿主机上的 OpenClaw（端口 18789）
- `.env` 文件不提交到 Git，包含敏感凭证

---

## 3. Docker 配置

### Dockerfile

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
EXPOSE 8080
CMD ["python", "main.py"]
```

### docker-compose.yml

```yaml
version: "3"
services:
  kitty-server:
    build: .
    container_name: kitty-server
    ports:
      - "8081:8081"
    env_file:
      - .env
    extra_hosts:
      - "host.docker.internal:host-gateway"
    restart: unless-stopped
```

---

## 4. 验证部署

```bash
# 健康检查
curl http://10.8.0.122:8081/

# 预期返回
# {"name": "Kitty Server", "version": "1.0.0", "status": "running"}

# 查看日志
ssh yswwpp@10.8.0.122 "cd /home/yswwpp/dev/project/tools/Kitty-Cloud/kitty-server && docker-compose logs --tail=50"
```

---

## 5. API 接口

| 接口 | 方法 | 说明 |
|------|------|------|
| `/` | GET | 健康检查 |
| `/chat` | POST | 对话（流式/非流式），支持模型切换 |
| `/models` | GET | 获取可用模型列表 |
| `/asr` | POST | 语音识别 |
| `/tts` | POST | 语音合成 |
| `/session/{id}` | GET | 获取会话历史 |
| `/session/{id}` | DELETE | 清空会话 |

### 模型切换

通过 `x-openclaw-model` header 切换底层 LLM：

```bash
curl -X POST http://localhost:8081/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "你好", "history": [], "stream": false, "model": "qianfan/deepseek-v4-flash"}'
```

支持模型：
- `bailian/qwen3.6-plus` - 通义千问（默认）
- `bailian/glm-5` - GLM-5
- `bailian/kimi-k2.5` - Kimi
- `qianfan/deepseek-v4-flash` - DeepSeek
- 更多模型通过 `/models` 接口动态获取

---

## 6. 架构图

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  iOS 客户端  │ ──▶ │ Kitty Server     │ ──▶ │   火山引擎 API   │
│ 10.8.0.x    │     │ 10.8.0.122:8081  │     │  ASR / TTS      │
│ 或模拟器     │     │ Docker           │     └─────────────────┘
└─────────────┘     └──────────────────┘
                          │
                          ▼
                    ┌─────────────────┐
                    │   OpenClaw      │
                    │ localhost:18789 │
                    │ 模型: 可切换     │
                    └─────────────────┘
```

---

## 7. 本地开发

```bash
cd kitty-server
source .venv/bin/activate
python main.py
# 服务运行在 http://localhost:8081
```

模拟器连接 `localhost:8081`，真机连接 `10.8.0.122:8081`。

---

*文档更新时间：2026-05-20*