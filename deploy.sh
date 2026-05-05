#!/bin/bash

# Kitty Cloud 部署脚本
# 用法: ./deploy.sh
# 本机和服务器都需要 proxy-on 才能访问 GitHub

set -e

SSH_KEY=~/.ssh/yswwpp
SSH_HOST=yswwpp@10.8.0.122
SERVER_DIR=/home/yswwpp/dev/project/tools/Kitty-Cloud
LOCAL_DIR="$(dirname "$0")"

echo "🚀 Kitty Cloud 部署脚本"
echo "========================"

# 检查 SSH key 是否存在
if [ ! -f "$SSH_KEY" ]; then
    echo "❌ SSH key 不存在: $SSH_KEY"
    exit 1
fi

# 检查本地是否有未提交的修改
cd "$LOCAL_DIR"
LOCAL_CHANGES=$(git status --porcelain)

if [ -n "$LOCAL_CHANGES" ]; then
    echo "📦 本地有未提交的修改:"
    echo "$LOCAL_CHANGES"
    echo ""
    echo "是否要提交并推送？(y/n)"
    read -r answer
    if [ "$answer" = "y" ]; then
        # 检查代理是否开启
        if ! curl -s --connect-timeout 5 https://github.com > /dev/null 2>&1; then
            echo "⚠️  GitHub 无法访问，请先开启代理: proxy-on"
            exit 1
        fi

        echo "📤 提交本地修改..."
        git add -A
        git commit -m "deploy: 自动部署提交 $(date '+%Y-%m-%d %H:%M')"
        git push origin main
        echo "✅ 本地代码已推送"
    fi
fi

echo ""
echo "🔌 连接服务器..."
echo ""

# SSH 登录并执行部署命令
ssh -i "$SSH_KEY" "$SSH_HOST" bash << 'REMOTE_SCRIPT'
set -e

# 开启代理
source ~/.zshrc
proxy-on

cd /home/yswwpp/dev/project/tools/Kitty-Cloud

echo "📥 拉取最新代码..."
git pull origin main

echo ""
echo "🔨 构建 Docker 镜像..."
cd kitty-server
docker build -t kitty-server:latest .

echo ""
echo "🚀 启动服务..."
# 停止并删除旧容器
docker stop kitty-server 2>/dev/null || true
docker rm kitty-server 2>/dev/null || true

# 加载环境变量
source .env

# 启动新容器
docker run -d \
    --name kitty-server \
    -p 8080:8080 \
    --add-host=host.docker.internal:host-gateway \
    --restart unless-stopped \
    -e OPENCLAW_URL \
    -e OPENCLAW_TOKEN \
    -e VOLC_ASR_APP_ID \
    -e VOLC_ASR_TOKEN \
    -e VOLC_ASR_RESOURCE_ID \
    -e VOLC_TTS_APP_ID \
    -e VOLC_TTS_TOKEN \
    -e VOLC_TTS_CLUSTER \
    kitty-server:latest

echo ""
echo "⏳ 等待服务启动..."
sleep 2

echo ""
echo "📊 服务状态:"
docker ps --filter name=kitty-server

echo ""
echo "📋 最近日志:"
docker logs kitty-server --tail=20

echo ""
echo "🧪 测试 API..."
curl -s http://localhost:8080/ && echo ""

echo ""
echo "✅ 部署完成!"
REMOTE_SCRIPT

echo ""
echo "🎉 全部完成!"