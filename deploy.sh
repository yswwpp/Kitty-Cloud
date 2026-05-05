#!/bin/bash

# Kitty Cloud 部署脚本
# 用法: ./deploy.sh [选项]
#   --skip-push  只部署服务器，不推送本地代码（服务器直接用 git pull）
#   --full       本地 commit + push + 服务器部署

set -e

SSH_KEY=~/.ssh/yswwpp
SSH_HOST=yswwpp@10.8.0.122
SERVER_DIR=/home/yswwpp/dev/project/tools/Kitty-Cloud

echo "🚀 Kitty Cloud 部署脚本"
echo "========================"

# 检查 SSH key 是否存在
if [ ! -f "$SSH_KEY" ]; then
    echo "❌ SSH key 不存在: $SSH_KEY"
    exit 1
fi

# 检查是否有未提交的修改
cd "$(dirname "$0")"
LOCAL_CHANGES=$(git status --porcelain)

if [ -n "$LOCAL_CHANGES" ] && [ "$1" != "--skip-push" ]; then
    echo "📦 本地有未提交的修改:"
    echo "$LOCAL_CHANGES"
    echo ""
    echo "是否要提交并推送？(y/n)"
    read -r answer
    if [ "$answer" = "y" ]; then
        echo "📤 提交本地修改..."
        git add -A
        git commit -m "deploy: 自动部署提交 $(date '+%Y-%m-%d %H:%M')"
        git push
        echo "✅ 本地代码已推送"
    else
        echo "⚠️  本地有修改但未推送，服务器将拉取旧版本"
    fi
fi

echo ""
echo "🔌 连接服务器..."
echo ""

# SSH 登录并执行部署命令
ssh -i "$SSH_KEY" "$SSH_HOST" << 'REMOTE_SCRIPT'
set -e

cd /home/yswwpp/dev/project/tools/Kitty-Cloud

echo "📥 拉取最新代码..."
git pull

echo ""
echo "🔨 重新构建 Docker 镜像..."
cd kitty-server
docker compose build --no-cache

echo ""
echo "🚀 启动服务..."
docker compose up -d

echo ""
echo "📊 服务状态:"
docker compose ps

echo ""
echo "📋 最近日志 (Ctrl+C 退出查看):"
docker compose logs --tail=20

echo ""
echo "✅ 部署完成!"
REMOTE_SCRIPT

echo ""
echo "🎉 全部完成!"