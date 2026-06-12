#!/usr/bin/env bash

# Kitty Cloud host deployment script.
# App files live under /home/yswwpp/deploy; config and data stay outside it.

set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/yswwpp}"
SSH_HOST="${SSH_HOST:-yswwpp@10.8.0.122}"

APP_NAME="kitty-cloud"
SERVICE_NAME="kitty-server"
SERVER_APP_ROOT="/home/yswwpp/deploy/${APP_NAME}"
SERVER_CURRENT_DIR="${SERVER_APP_ROOT}/current"
SERVER_DATA_DIR="/home/yswwpp/dev/docker_file_sharing/kitty-server"
SERVER_VENV="${SERVER_APP_ROOT}/.venv"

LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Kitty Cloud host deployment"
echo "==========================="

if [ ! -f "$SSH_KEY" ]; then
    echo "SSH key not found: $SSH_KEY"
    exit 1
fi

echo "Preparing remote directories..."
ssh -i "$SSH_KEY" "$SSH_HOST" \
    "mkdir -p '$SERVER_CURRENT_DIR' '$SERVER_DATA_DIR/data'"

echo "Syncing application files..."
rsync -az --delete \
    -e "ssh -i $SSH_KEY" \
    --exclude ".git/" \
    --exclude ".ai/" \
    --exclude ".DS_Store" \
    --exclude "__pycache__/" \
    --exclude "*.pyc" \
    --exclude ".pytest_cache/" \
    --exclude "kitty-server/.env" \
    --exclude "kitty-server/.venv/" \
    --exclude "kitty-server/data/" \
    --exclude "kitty-client/DerivedData/" \
    "$LOCAL_DIR/" "$SSH_HOST:$SERVER_CURRENT_DIR/"

echo "Installing and restarting service..."
ssh -i "$SSH_KEY" "$SSH_HOST" bash -s <<REMOTE
set -euo pipefail

APP_ROOT="$SERVER_APP_ROOT"
CURRENT_DIR="$SERVER_CURRENT_DIR"
DATA_DIR="$SERVER_DATA_DIR"
VENV="$SERVER_VENV"
SERVICE="$SERVICE_NAME"

mkdir -p "\$DATA_DIR/data" "\$HOME/.config/systemd/user"

if [ ! -f "\$DATA_DIR/.env" ]; then
    echo "Missing required config: \$DATA_DIR/.env"
    exit 1
fi

if [ ! -f "\$DATA_DIR/models.json" ]; then
    cp "\$CURRENT_DIR/kitty-server/models.json" "\$DATA_DIR/models.json"
    echo "Created initial \$DATA_DIR/models.json from application default."
fi

python3 -m venv "\$VENV"
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
    "\$VENV/bin/python" -m pip install \
    --no-cache-dir \
    --timeout 120 \
    --retries 10 \
    -i https://mirrors.aliyun.com/pypi/simple/ \
    --trusted-host mirrors.aliyun.com \
    -r "\$CURRENT_DIR/kitty-server/requirements.txt"

cp "\$CURRENT_DIR/kitty-server/deploy/kitty-server.service" "\$HOME/.config/systemd/user/\$SERVICE.service"

# Free the port if the legacy Docker deployment is still running.
docker rm -f kitty-server >/dev/null 2>&1 || true
if [ -f "\$DATA_DIR/docker-compose.yml" ]; then
    (cd "\$DATA_DIR" && docker compose down >/dev/null 2>&1) || \
    (cd "\$DATA_DIR" && docker-compose down >/dev/null 2>&1) || true
fi

# Data files may have been created by the legacy root-run Docker container.
sudo -n chown -R "\$(id -un):\$(id -gn)" "\$DATA_DIR/data" 2>/dev/null || true
sudo -n loginctl enable-linger "\$(id -un)" 2>/dev/null || true

systemctl --user daemon-reload
systemctl --user enable "\$SERVICE" >/dev/null
systemctl --user restart "\$SERVICE"

sleep 3
systemctl --user --no-pager --full status "\$SERVICE" | sed -n '1,18p'
curl -fsS http://127.0.0.1:8081/ >/tmp/kitty-server-health.json
cat /tmp/kitty-server-health.json
echo
REMOTE

echo "Deployment complete: http://10.8.0.122:8081/"
