#!/bin/bash

# Kitty Cloud 部署脚本
# 用法: ./deploy.sh

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

ssh -i "$SSH_KEY" "$SSH_HOST" "cd $SERVER_DIR && git pull origin main && cd kitty-server && docker rm -f kitty-server 2>/dev/null || true && docker-compose build && docker-compose up -d && sleep 2 && docker-compose logs --tail=30 && curl -s http://localhost:8080/"

echo ""
echo "✅ 部署完成!"