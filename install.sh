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

if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 权限运行："
    echo
    echo "curl -fsSL https://raw.githubusercontent.com/${REPO}/${BRANCH}/install.sh | sudo bash"
    echo
    exit 1
fi

echo "[1/7] 检查基础工具..."
export DEBIAN_FRONTEND=noninteractive

if ! command -v curl >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl ca-certificates openssl
fi

echo "✓ 基础工具正常"

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

echo
echo "[3/7] 创建安装目录并修复数据目录权限..."

# go-emby 运行镜像固定使用 UID/GID 65532。
# Docker 在 bind mount 源目录不存在时通常会以 root:root 创建目录，
# 这会导致容器无法写入 /app/data 和 /app/backups。
# 安装和升级时都显式创建并修正权限，避免不同实例首次部署后出现 EACCES。
mkdir -p \
    "${INSTALL_DIR}" \
    "${INSTALL_DIR}/secrets" \
    "${INSTALL_DIR}/app-data" \
    "${INSTALL_DIR}/app-backups"

chown -R "${APP_UID}:${APP_GID}" \
    "${INSTALL_DIR}/app-data" \
    "${INSTALL_DIR}/app-backups"

chmod 750 \
    "${INSTALL_DIR}/app-data" \
    "${INSTALL_DIR}/app-backups"

chmod 700 "${INSTALL_DIR}/secrets"

cd "${INSTALL_DIR}"

echo "✓ ${INSTALL_DIR}"
echo "✓ app-data -> ${APP_UID}:${APP_GID}"
echo "✓ app-backups -> ${APP_UID}:${APP_GID}"

echo
echo "[4/7] 下载最新部署配置..."
curl -fL --retry 3 --connect-timeout 10 "${COMPOSE_URL}" -o compose.yaml
echo "✓ compose.yaml"

echo
echo "[5/7] 检查环境配置..."
FIRST_INSTALL="false"

if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
    echo "首次安装，自动创建 .env..."
    curl -fL --retry 3 --connect-timeout 10 "${ENV_URL}" -o .env

    POSTGRES_PASSWORD="$(openssl rand -hex 24)"
    ADMIN_PASSWORD="$(openssl rand -hex 24)"

    if [[ "${POSTGRES_PASSWORD}" == "${ADMIN_PASSWORD}" ]]; then
        ADMIN_PASSWORD="$(openssl rand -hex 24)"
    fi

    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|" .env
    sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${ADMIN_PASSWORD}|" .env

    if grep -q '^HTTP_PORT=' .env; then
        sed -i "s|^HTTP_PORT=.*|HTTP_PORT=${DEFAULT_PORT}|" .env
    else
        printf '\nHTTP_PORT=%s\n' "${DEFAULT_PORT}" >> .env
    fi

    if grep -q '^IMAGE_TAG=' .env; then
        sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=latest|' .env
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

get_env() {
    local KEY="$1"
    sed -n "s/^${KEY}=//p" "${INSTALL_DIR}/.env" \
        | tail -n 1 \
        | sed -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//'
}

POSTGRES_PASSWORD="$(get_env POSTGRES_PASSWORD)"
ADMIN_PASSWORD="$(get_env ADMIN_PASSWORD)"
HTTP_PORT="$(get_env HTTP_PORT)"

if [[ -z "${HTTP_PORT}" ]]; then
    HTTP_PORT="${DEFAULT_PORT}"
fi

if [[ -z "${POSTGRES_PASSWORD}" ]]; then
    echo
    echo "错误：.env 中 POSTGRES_PASSWORD 为空。"
    echo
    exit 1
fi

if [[ -z "${ADMIN_PASSWORD}" ]]; then
    echo
    echo "错误：.env 中 ADMIN_PASSWORD 为空。"
    echo
    exit 1
fi

mkdir -p /vol1/1000/strm

echo
echo "[6/7] 检查 Docker Compose..."
docker compose --env-file .env -f compose.yaml config --quiet
echo "✓ Compose 配置正确"

# ============================================================
# 已有安装：数据库数据与密码一致性检查
# ============================================================

if [[ "${FIRST_INSTALL}" != "true" ]]; then
    echo
    echo "检查已有 PostgreSQL 数据..."

    CURRENT_DB_DATA="false"
    LEGACY_VOLUME=""

    if [[ -f "${INSTALL_DIR}/postgres-data/PG_VERSION" ]] || \
       [[ -d "${INSTALL_DIR}/postgres-data/base" ]]; then
        CURRENT_DB_DATA="true"
        echo "✓ 检测到当前目录 PostgreSQL 数据：${INSTALL_DIR}/postgres-data"
    fi

    LEGACY_VOLUME="$(
        docker volume ls -q \
            --filter 'label=com.docker.compose.project=go-emby' \
            --filter 'label=com.docker.compose.volume=postgres-data' \
            2>/dev/null | head -n 1 || true
    )"

    if [[ -z "${LEGACY_VOLUME}" ]] && docker volume inspect go-emby_postgres-data >/dev/null 2>&1; then
        LEGACY_VOLUME="go-emby_postgres-data"
    fi

    if [[ -n "${LEGACY_VOLUME}" && "${CURRENT_DB_DATA}" != "true" ]]; then
        echo
        echo "错误：检测到旧 PostgreSQL Docker 数据卷，但当前 ./postgres-data 目录还没有数据库数据。"
        echo
        echo "旧数据卷：${LEGACY_VOLUME}"
        echo "新数据目录：${INSTALL_DIR}/postgres-data"
        echo
        echo "为避免误创建新的空数据库，本次安装已停止。"
        echo "请先把旧数据库迁移到 ./postgres-data，或确认不需要旧数据后再删除旧数据卷。"
        echo
        exit 1
    fi

    if [[ "${CURRENT_DB_DATA}" == "true" ]]; then
        echo "启动 PostgreSQL 进行密码校验..."

        docker compose --env-file .env -f compose.yaml up -d postgres >/dev/null

        DB_READY="false"
        for i in $(seq 1 30); do
            STATUS="$(docker compose -f compose.yaml ps --format json postgres 2>/dev/null | grep -o '"Health":"[^"]*"' | head -n 1 || true)"
            if [[ "${STATUS}" == *'healthy'* ]]; then
                DB_READY="true"
                break
            fi
            sleep 2
        done

        if [[ "${DB_READY}" != "true" ]]; then
            echo
            echo "错误：PostgreSQL 未能正常启动，无法验证数据库密码。"
            echo "请检查："
            echo "  cd ${INSTALL_DIR} && docker compose logs --tail=100 postgres"
            echo
            exit 1
        fi

        if ! docker compose --env-file .env -f compose.yaml exec -T \
            -e "PGPASSWORD=${POSTGRES_PASSWORD}" \
            postgres \
            psql -h 127.0.0.1 -U emby -d emby -Atqc 'SELECT 1' \
            >/dev/null 2>&1; then

            echo
            echo "============================================================"
            echo "错误：数据库密码不匹配"
            echo "============================================================"
            echo
            echo "检测到已有 PostgreSQL 数据，但 .env 中的 POSTGRES_PASSWORD"
            echo "无法登录现有数据库用户 emby。"
            echo
            echo "这通常表示："
            echo "  1. .env 曾被重新生成或手工修改；或"
            echo "  2. 数据库是使用另一个旧密码初始化的。"
            echo
            echo "为保护现有数据，本次安装/升级已停止，不会删除数据库。"
            echo
            echo "请恢复原来的 POSTGRES_PASSWORD，或在 PostgreSQL 中同步修改 emby 用户密码。"
            echo "数据库目录：${INSTALL_DIR}/postgres-data"
            echo
            exit 1
        fi

        echo "✓ PostgreSQL 数据库密码与 .env 一致"
    else
        echo "✓ 未检测到已有 PostgreSQL 数据，将按当前 .env 初始化新数据库"
    fi
fi

echo
echo "[7/7] 拉取 GitHub Container Registry 最新镜像并启动..."
echo

docker compose --env-file .env -f compose.yaml pull
docker compose --env-file .env -f compose.yaml up -d --remove-orphans

echo
echo "等待 go-emby 启动..."
READY="false"

for i in $(seq 1 60); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${HTTP_PORT}/health" >/dev/null 2>&1; then
        READY="true"
        break
    fi

    APP_STATE="$(docker compose -f compose.yaml ps --format json go-emby 2>/dev/null || true)"
    if echo "${APP_STATE}" | grep -Eq '"State":"(restarting|exited|dead)"'; then
        echo
        echo "错误：go-emby 容器启动失败或正在反复重启。"
        echo
        docker compose -f compose.yaml logs --tail=50 go-emby || true
        echo
        exit 1
    fi

    sleep 2
done

PUBLIC_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"

if [[ -z "${PUBLIC_IP}" ]]; then
    PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

if [[ -z "${PUBLIC_IP}" ]]; then
    PUBLIC_IP="服务器IP"
fi

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
    echo "  ⚠ 容器已启动，但健康检查暂未通过"
    echo "  可执行：cd ${INSTALL_DIR} && docker compose logs --tail=100 go-emby"
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
