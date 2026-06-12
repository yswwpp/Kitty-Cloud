# Kitty Server 部署说明

## 服务器信息

- IP: `10.8.0.122`
- 端口: `8081`
- 应用目录: `/home/yswwpp/deploy/kitty-cloud/current`
- 虚拟环境: `/home/yswwpp/deploy/kitty-cloud/.venv`
- 配置/数据目录: `/home/yswwpp/dev/docker_file_sharing/kitty-server`
- 服务管理: user systemd，服务名 `kitty-server`

## 1. 部署方式

项目根目录的 `deploy.sh` 会把当前工作区同步到服务器应用目录，然后安装依赖并重启
`kitty-server` user systemd 服务：

```bash
./deploy.sh
```

脚本会自动：

1. 创建 `/home/yswwpp/deploy/kitty-cloud/current`
2. 用 `rsync --delete` 同步应用代码
3. 保留 `/home/yswwpp/dev/docker_file_sharing/kitty-server` 中的配置和数据
4. 创建或更新 Python venv
5. 安装 `kitty-server/requirements.txt`
6. 安装 user systemd unit
7. 停止旧 Docker 容器（如果还在运行）
8. 重启服务并执行健康检查

## 2. 配置和数据

生产环境配置文件放在：

```text
/home/yswwpp/dev/docker_file_sharing/kitty-server/
├── .env
├── models.json
└── data/
    └── checkpoints.sqlite
```

`deploy.sh` 只同步应用目录，不会删除或覆盖这个目录。

关键环境变量：

```env
PORT=8081
KITTY_ENV_PATH=/home/yswwpp/dev/docker_file_sharing/kitty-server/.env
MODELS_JSON_PATH=/home/yswwpp/dev/docker_file_sharing/kitty-server/models.json
CHECKPOINT_DB_PATH=/home/yswwpp/dev/docker_file_sharing/kitty-server/data/checkpoints.sqlite
DEFAULT_MODEL=deepseek/deepseek-v4-flash
```

Provider API key、火山 ASR/TTS 凭证也放在同一个 `.env` 中。

## 3. systemd 服务

unit 文件模板在：

```text
kitty-server/deploy/kitty-server.service
```

部署后安装到：

```text
~/.config/systemd/user/kitty-server.service
```

常用命令：

```bash
systemctl --user status kitty-server
systemctl --user restart kitty-server
journalctl --user -u kitty-server -f
```

## 4. 验证部署

```bash
curl http://10.8.0.122:8081/
curl http://10.8.0.122:8081/models
```

预期 `/` 返回：

```json
{
  "name": "Kitty Server",
  "version": "2.0.0",
  "status": "running",
  "agent": "langgraph"
}
```

## 5. 架构图

```text
┌─────────────┐     ┌─────────────────────────┐     ┌─────────────────┐
│  iOS 客户端  │ ──▶ │ Kitty Server            │ ──▶ │   火山引擎 API   │
│ 10.8.0.x    │     │ 10.8.0.122:8081         │     │  ASR / TTS      │
└─────────────┘     │ Host process + systemd  │     └─────────────────┘
                    └───────────┬─────────────┘
                                │
                                ▼
                    ┌─────────────────────────┐
                    │ LangGraph Agent          │
                    │ LLM Provider Gateway     │
                    │ SQLite Checkpoint        │
                    └─────────────────────────┘
```

## 6. 本地开发

```bash
cd kitty-server
source .venv/bin/activate
python main.py
```

本地默认读取 `kitty-server/.env`、`kitty-server/models.json` 和
`./data/checkpoints.sqlite`。需要模拟生产配置时，可以显式设置：

```bash
export KITTY_ENV_PATH=/home/yswwpp/dev/docker_file_sharing/kitty-server/.env
export MODELS_JSON_PATH=/home/yswwpp/dev/docker_file_sharing/kitty-server/models.json
export CHECKPOINT_DB_PATH=/home/yswwpp/dev/docker_file_sharing/kitty-server/data/checkpoints.sqlite
python kitty-server/main.py
```
