#!/usr/bin/env bash
set -Eeuo pipefail

REPO="sd87671067/go-emby"
BRANCH="main"
INSTALL_DIR="/opt/go-emby"
COMPOSE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/compose.yaml"
ENV_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/.env.example"
DEFAULT_PORT="8097"
APP_UID="65532"
APP_GID="65532"

echo
echo "============================================"
echo "           go-emby 一键安装"
echo "============================================"
echo