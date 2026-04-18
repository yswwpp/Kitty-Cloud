# Kitty Server 部署说明

## 服务器信息

- IP: `10.8.0.122`
- 端口: `8080`

---

## 1. 环境准备

### 安装 Python 3.11+

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install python3.11 python3.11-venv python3-pip -y

# CentOS/RHEL
sudo dnf install python3.11 python3.11-pip -y
```

### 安装 uv（推荐）

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.bashrc
```

---

## 2. 部署代码

### 创建项目目录

```bash
mkdir -p /opt/kitty-server
cd /opt/kitty-server
```

### 上传代码

将 `main.py` 上传到服务器：

```bash
# 本地执行
scp main.py user@10.8.0.122:/opt/kitty-server/
```

或直接在服务器创建文件。

---

## 3. 创建虚拟环境

```bash
cd /opt/kitty-server
uv venv
source .venv/bin/activate
```

---

## 4. 安装依赖

```bash
uv pip install fastapi uvicorn httpx websockets
```

或创建 `requirements.txt`：

```
fastapi>=0.109.0
uvicorn>=0.27.0
httpx>=0.26.0
websockets>=12.0
```

然后安装：

```bash
uv pip install -r requirements.txt
```

---

## 5. 配置环境变量

创建 `.env` 文件或直接设置环境变量：

```bash
# OpenClaw 配置
export OPENCLAW_URL="http://localhost:18789"  # OpenClaw 服务地址
export OPENCLAW_TOKEN="your_openclaw_token"

# 火山引擎 ASR 配置
export VOLC_ASR_APP_ID="3214571057"
export VOLC_ASR_TOKEN="your_asr_token"
export VOLC_ASR_RESOURCE_ID="volc.seedasr.sauc.duration"

# 火山引擎 TTS 配置
export VOLC_TTS_APP_ID="3214571057"
export VOLC_TTS_TOKEN="your_tts_token"
export VOLC_TTS_CLUSTER="volcano_tts"
```

---

## 6. 启动服务

### 测试启动

```bash
cd /opt/kitty-server
source .venv/bin/activate
python main.py
```

服务将在 `http://0.0.0.0:8080` 启动。

### 生产环境（使用 systemd）

创建服务文件 `/etc/systemd/system/kitty-server.service`：

```ini
[Unit]
Description=Kitty Voice Assistant Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/kitty-server
Environment="PATH=/opt/kitty-server/.venv/bin"
Environment="OPENCLAW_URL=http://localhost:18789"
Environment="OPENCLAW_TOKEN=your_openclaw_token"
Environment="VOLC_ASR_APP_ID=3214571057"
Environment="VOLC_ASR_TOKEN=your_asr_token"
Environment="VOLC_ASR_RESOURCE_ID=volc.seedasr.sauc.duration"
Environment="VOLC_TTS_APP_ID=3214571057"
Environment="VOLC_TTS_TOKEN=your_tts_token"
Environment="VOLC_TTS_CLUSTER=volcano_tts"
ExecStart=/opt/kitty-server/.venv/bin/python main.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

启动服务：

```bash
sudo systemctl daemon-reload
sudo systemctl enable kitty-server
sudo systemctl start kitty-server
sudo systemctl status kitty-server
```

---

## 7. 验证部署

```bash
# 健康检查
curl http://10.8.0.122:8080/

# 预期返回
# {"name": "Kitty Server", "version": "1.0.0", "status": "running"}
```

---

## 8. 防火墙配置

确保端口 8080 开放：

```bash
# Ubuntu/Debian (ufw)
sudo ufw allow 8080/tcp

# CentOS/RHEL (firewalld)
sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --reload
```

---

## 9. 日志查看

```bash
# systemd 日志
sudo journalctl -u kitty-server -f

# 或直接运行时的输出
```

---

## 10. 常见问题

### 端口被占用

```bash
# 查看端口占用
sudo lsof -i :8080
# 或
sudo netstat -tlnp | grep 8080
```

### 连接火山引擎失败

检查网络和 Token 是否正确：

```bash
# 测试 ASR 连接
curl -v wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream
```

### OpenClaw 连接失败

确保 OpenClaw 服务在运行：

```bash
curl http://localhost:18789/
```

---

## 架构图

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  iOS 客户端  │ ──▶ │ Kitty Server     │ ──▶ │   火山引擎 API   │
│ 10.8.0.x    │     │ 10.8.0.122:8080  │     │  ASR / TTS      │
└─────────────┘     └──────────────────┘     └─────────────────┘
                          │
                          ▼
                    ┌─────────────────┐
                    │   OpenClaw      │
                    │ localhost:18789 │
                    └─────────────────┘
```

---

*文档更新时间：2026-04-18*
