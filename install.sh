#!/usr/bin/env bash
set -Eeuo pipefail

REPO="sd87671067/go-emby"
BRANCH="main"

INSTALL_DIR="/opt/go-emby"

COMPOSE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/compose.yaml"
ENV_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/.env.example"

DEFAULT_PORT="8097"

echo
echo "============================================"
echo "           go-emby 一键安装"
echo "============================================"
echo


# ============================================================
# 必须 root
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 权限运行："
    echo
    echo "curl -fsSL https://raw.githubusercontent.com/${REPO}/${BRANCH}/install.sh | sudo bash"
    echo
    exit 1
fi


# ============================================================
# 安装基础工具
# ============================================================

echo "[1/7] 检查基础工具..."

export DEBIAN_FRONTEND=noninteractive

if ! command -v curl >/dev/null 2>&1 ||
   ! command -v openssl >/dev/null 2>&1; then

    apt-get update

    apt-get install -y \
        curl \
        ca-certificates \
        openssl

fi

echo "✓ 基础工具正常"


# ============================================================
# Docker
# ============================================================

echo
echo "[2/7] 检查 Docker..."

if ! command -v docker >/dev/null 2>&1; then

    echo "未检测到 Docker，开始自动安装..."

    curl -fsSL https://get.docker.com | sh

fi

systemctl enable --now docker >/dev/null 2>&1 || true

if ! docker compose version >/dev/null 2>&1; then

    echo "未检测到 Docker Compose Plugin..."

    apt-get update

    apt-get install -y docker-compose-plugin

fi

echo "✓ Docker:"
docker --version

echo "✓ Docker Compose:"
docker compose version


# ============================================================
# 创建安装目录
# ============================================================

echo
echo "[3/7] 创建安装目录..."

mkdir -p "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/secrets"

chmod 700 "${INSTALL_DIR}/secrets"

cd "${INSTALL_DIR}"

echo "✓ ${INSTALL_DIR}"


# ============================================================
# 下载 compose.yaml
# ============================================================

echo
echo "[4/7] 下载最新部署配置..."

curl -fL \
    --retry 3 \
    --connect-timeout 10 \
    "${COMPOSE_URL}" \
    -o compose.yaml

echo "✓ compose.yaml"


# ============================================================
# 创建 .env
# ============================================================

echo
echo "[5/7] 检查环境配置..."

FIRST_INSTALL="false"

if [[ ! -f "${INSTALL_DIR}/.env" ]]; then

    echo "首次安装，自动创建 .env..."

    curl -fL \
        --retry 3 \
        --connect-timeout 10 \
        "${ENV_URL}" \
        -o .env

    POSTGRES_PASSWORD="$(openssl rand -hex 24)"
    ADMIN_PASSWORD="$(openssl rand -hex 24)"

    # 极低概率相同，再生成一次
    if [[ "${POSTGRES_PASSWORD}" == "${ADMIN_PASSWORD}" ]]; then
        ADMIN_PASSWORD="$(openssl rand -hex 24)"
    fi

    sed -i \
        "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|" \
        .env

    sed -i \
        "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${ADMIN_PASSWORD}|" \
        .env

    # 保证默认端口
    if grep -q '^HTTP_PORT=' .env; then

        sed -i \
            "s|^HTTP_PORT=.*|HTTP_PORT=${DEFAULT_PORT}|" \
            .env

    else

        printf '\nHTTP_PORT=%s\n' "${DEFAULT_PORT}" >> .env

    fi

    # Docker Hub 最新版
    if grep -q '^IMAGE_TAG=' .env; then

        sed -i \
            's|^IMAGE_TAG=.*|IMAGE_TAG=latest|' \
            .env

    else

        printf '\nIMAGE_TAG=latest\n' >> .env

    fi

    chmod 600 .env

    FIRST_INSTALL="true"

    echo "✓ 已生成随机数据库密码"
    echo "✓ 已生成随机管理员密码"

else

    echo "检测到已有 .env"
    echo "✓ 保留现有密码，不覆盖"

    chmod 600 .env

fi


# ============================================================
# 读取 .env 中需要显示的值
# ============================================================

get_env() {

    local KEY="$1"

    sed -n \
        "s/^${KEY}=//p" \
        "${INSTALL_DIR}/.env" \
        | tail -n 1 \
        | sed \
            -e "s/^'//" \
            -e "s/'$//" \
            -e 's/^"//' \
            -e 's/"$//'
}


ADMIN_PASSWORD="$(get_env ADMIN_PASSWORD)"
HTTP_PORT="$(get_env HTTP_PORT)"

if [[ -z "${HTTP_PORT}" ]]; then
    HTTP_PORT="${DEFAULT_PORT}"
fi


if [[ -z "${ADMIN_PASSWORD}" ]]; then

    echo
    echo "错误：.env 中 ADMIN_PASSWORD 为空。"
    echo

    exit 1
fi


# ============================================================
# 检查默认媒体目录
# ============================================================

#
# compose.yaml 当前默认：
#
# /vol1/1000/strm:/media:ro
#
# 如果目录不存在，Docker Compose 会启动失败。
#
# 为了首次安装可以直接启动，这里自动创建。
#

mkdir -p /vol1/1000/strm


# ============================================================
# 验证 Compose
# ============================================================

echo
echo "[6/7] 检查 Docker Compose..."

docker compose \
    --env-file .env \
    -f compose.yaml \
    config \
    --quiet

echo "✓ Compose 配置正确"


# ============================================================
# Pull + UP
# ============================================================

echo
echo "[7/7] 拉取 Docker Hub 镜像并启动..."
echo

docker compose \
    --env-file .env \
    -f compose.yaml \
    pull

docker compose \
    --env-file .env \
    -f compose.yaml \
    up \
    -d \
    --remove-orphans


# ============================================================
# 等待服务
# ============================================================

echo
echo "等待 go-emby 启动..."

READY="false"

for i in $(seq 1 60); do

    if curl \
        -fsS \
        --max-time 2 \
        "http://127.0.0.1:${HTTP_PORT}/health" \
        >/dev/null 2>&1; then

        READY="true"
        break

    fi

    sleep 2

done


# ============================================================
# 获取公网 IP
# ============================================================

PUBLIC_IP="$(
    curl \
        -4 \
        -fsS \
        --max-time 5 \
        https://api.ipify.org \
        2>/dev/null || true
)"


# 公网 IP 获取失败则使用本地 IP
if [[ -z "${PUBLIC_IP}" ]]; then

    PUBLIC_IP="$(
        hostname -I \
            2>/dev/null \
            | awk '{print $1}'
    )"

fi


if [[ -z "${PUBLIC_IP}" ]]; then
    PUBLIC_IP="服务器IP"
fi


# ============================================================
# 显示结果
# ============================================================

echo
echo
echo "============================================"
echo "          go-emby 安装完成"
echo "============================================"
echo

if [[ "${READY}" == "true" ]]; then

    echo "服务状态："
    echo "  ✓ 正常运行"

else

    echo "服务状态："
    echo "  ⚠ 容器已经启动，但健康检查暂未通过"

fi

echo
echo "访问地址："
echo
echo "  http://${PUBLIC_IP}:${HTTP_PORT}"
echo

echo "管理员账号："
echo
echo "  admin"
echo

echo "管理员密码："
echo
echo "  ${ADMIN_PASSWORD}"
echo

echo "安装目录："
echo
echo "  ${INSTALL_DIR}"
echo

echo "配置文件："
echo
echo "  ${INSTALL_DIR}/.env"
echo

if [[ "${FIRST_INSTALL}" == "true" ]]; then

    echo "提示："
    echo "  请保存上面的管理员密码。"
    echo "  数据库密码已安全保存在 ${INSTALL_DIR}/.env"

else

    echo "提示："
    echo "  检测到已有安装，原管理员密码和数据库密码均未修改。"

fi

echo
echo "常用命令："
echo
echo "  cd ${INSTALL_DIR}"
echo "  docker compose ps"
echo "  docker compose logs -f go-emby"
echo "  docker compose pull"
echo "  docker compose up -d"
echo
echo "============================================"