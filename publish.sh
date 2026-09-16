#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# ============================================================
# go-emby production image publisher
#
# Source of truth:
#   /root/go-emby/emby
#
# This script NEVER builds from the public repository source.
# The public GitHub repository only receives the container package in GHCR.
# Source code is sent only to the local BuildKit builder and is not copied
# into the final runtime image.
#
# Published tags:
#   ghcr.io/sd87671067/go-emby:latest
#   ghcr.io/sd87671067/go-emby:YYYY.MM.DD-HHMMSS
#   ghcr.io/sd87671067/go-emby:sha-XXXXXXXXXXXX
#
# Existing GitHub Actions then mirrors latest + dated tag to Docker Hub.
# ============================================================

SOURCE="${SOURCE:-/root/go-emby/emby}"
GITHUB_USER="sd87671067"
IMAGE="ghcr.io/${GITHUB_USER}/go-emby"
BUILDER_NAME="go-emby-release-builder"

fail() {
    echo "错误: $*" >&2
    exit 1
}

[[ -d "${SOURCE}" ]] || fail "源码目录不存在: ${SOURCE}"
[[ -f "${SOURCE}/go.mod" ]] || fail "源码目录缺少 go.mod: ${SOURCE}"
[[ -f "${SOURCE}/main.go" ]] || fail "源码目录缺少 main.go: ${SOURCE}"
[[ -d "${SOURCE}/web" ]] || fail "源码目录缺少 web/: ${SOURCE}"

for cmd in docker git find grep sed awk date; do
    command -v "${cmd}" >/dev/null 2>&1 || fail "缺少命令: ${cmd}"
done

docker info >/dev/null 2>&1 || fail "Docker 未运行或当前用户无权限"
docker buildx version >/dev/null 2>&1 || fail "Docker Buildx 不可用"

cat <<EOF
============================================================
 go-emby 正式源码多架构发布
============================================================

源码目录:
  ${SOURCE}

目标镜像:
  ${IMAGE}

注意:
  - 不从 GitHub 公共源码构建
  - 不 git push 正式源码
  - 最终镜像不包含 Go/Node 工具链和项目源码
  - 最终镜像仅包含编译后的 go-emby 与运行依赖
EOF

# ------------------------------------------------------------
# 1. Verify production source and obtain release identity
# ------------------------------------------------------------

echo
echo "[1/8] 检查正式源码..."

SOURCE_VERSION=""
if [[ -f "${SOURCE}/.source-version" ]]; then
    SOURCE_VERSION="$(tr -d '[:space:]' < "${SOURCE}/.source-version")"
fi

if git -C "${SOURCE}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GIT_COMMIT="$(git -C "${SOURCE}" rev-parse HEAD)"
    DIRTY="$(git -C "${SOURCE}" status --porcelain --untracked-files=normal || true)"
else
    # Production sync intentionally may not carry .git.
    GIT_COMMIT="${SOURCE_VERSION:-production-$(date -u '+%Y%m%d%H%M%S')}"
    DIRTY=""
fi

SHORT_COMMIT="$(printf '%s' "${GIT_COMMIT}" | cut -c1-12)"
[[ -n "${SHORT_COMMIT}" ]] || SHORT_COMMIT="$(date -u '+%Y%m%d%H%M')"

DATE_VERSION="$(date -u '+%Y.%m.%d-%H%M%S')"
BUILD_DATE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [[ -n "${DIRTY}" ]]; then
    echo "检测到正式源码存在未提交修改；这些修改也会进入镜像:"
    printf '%s\n' "${DIRTY}"
fi

echo "✓ 发布版本: ${DATE_VERSION}"
echo "✓ 源码标识: ${GIT_COMMIT}"

# Verify the new frontend layout exists so we do not accidentally publish
# the old public-repository UI again.
for required in \
    web/index.html \
    web/css/base.css \
    web/css/components.css \
    web/js/app.js \
    web/js/components.js; do
    [[ -e "${SOURCE}/${required}" ]] || fail "正式源码缺少 ${required}，拒绝发布旧 UI 镜像"
done

echo "✓ 新版 web/css + web/js 结构存在"

# Reject obvious runtime secrets/database content from the build context.
for bad in \
    .env \
    postgres-data \
    app-data \
    app-backups \
    data \
    backups \
    secrets; do
    if [[ -e "${SOURCE}/${bad}" ]]; then
        echo "提示: 检测到运行目录 ${bad}，将通过临时安全构建上下文排除"
    fi
done

# ------------------------------------------------------------
# 2. Create a clean release build context
# ------------------------------------------------------------

echo
echo "[2/8] 创建安全发布上下文..."

TMP="$(mktemp -d /tmp/go-emby-release.XXXXXX)"
CONTEXT="${TMP}/context"
DOCKERFILE="${TMP}/Dockerfile.release"
mkdir -p "${CONTEXT}"

cleanup() {
    unset GITHUB_TOKEN || true
    rm -rf "${TMP}" || true
}
trap cleanup EXIT

command -v rsync >/dev/null 2>&1 || fail "缺少 rsync；请先 apt install -y rsync"

rsync -a \
    --delete \
    --exclude='.git/' \
    --exclude='.github/' \
    --exclude='.env' \
    --exclude='.env.*' \
    --exclude='postgres-data/' \
    --exclude='app-data/' \
    --exclude='app-backups/' \
    --exclude='data/' \
    --exclude='backups/' \
    --exclude='media/' \
    --exclude='secrets/' \
    --exclude='secret/' \
    --exclude='credentials/' \
    --exclude='node_modules/' \
    --exclude='.cache/' \
    --exclude='tmp/' \
    --exclude='temp/' \
    --exclude='*.db' \
    --exclude='*.sqlite' \
    --exclude='*.sqlite3' \
    --exclude='*.dump' \
    --exclude='*.sql.gz' \
    --exclude='*.pem' \
    --exclude='*.key' \
    --exclude='*.p12' \
    --exclude='*.pfx' \
    --exclude='*.log' \
    --exclude='*.pid' \
    --exclude='*.sock' \
    --exclude='compose.prod-local.yaml' \
    --exclude='.source-version' \
    "${SOURCE}/" "${CONTEXT}/"

# The current UI is embedded directly by Go. No Vue/Node build stage is
# permitted here; that prevents the removed legacy file-ui from reappearing.
[[ ! -d "${CONTEXT}/file-ui" ]] || fail "发现旧 file-ui，拒绝发布；正式源码应已删除 Vue 文件管理"

# ------------------------------------------------------------
# 3. Generate deterministic multi-stage Dockerfile
# ------------------------------------------------------------

echo
echo "[3/8] 生成多阶段发布 Dockerfile..."

cat >"${DOCKERFILE}" <<'DOCKERFILE_EOF'
# syntax=docker/dockerfile:1.7

FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS compiler
WORKDIR /src

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .

ARG TARGETOS
ARG TARGETARCH
ARG SOURCE_REVISION
ARG BUILD_DATE

# Release compilation. trimpath + buildvcs=false + stripped symbols reduce
# build-path/source metadata in the resulting binary. Web assets are embedded
# into this binary by go:embed and therefore no source tree is needed at runtime.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build \
      -mod=readonly \
      -trimpath \
      -buildvcs=false \
      -ldflags="-s -w -buildid=" \
      -o /out/go-emby .

# Intermediate artifact stage. Only the compiled executable crosses this line.
FROM scratch AS artifact
COPY --from=compiler /out/go-emby /go-emby

FROM postgres:17-bookworm AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates wget ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /app/data /app/backups /media /run/secrets \
    && chown -R 65532:65532 /app /media

ARG SOURCE_REVISION
ARG BUILD_DATE
LABEL org.opencontainers.image.title="go-emby" \
      org.opencontainers.image.source="https://github.com/sd87671067/go-emby" \
      org.opencontainers.image.revision="${SOURCE_REVISION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.description="Go STRM media server - compiled production release"

WORKDIR /app
COPY --from=artifact /go-emby /app/go-emby

ENV LISTEN=:8097 \
    MEDIA_INFO_ROOT=/app/data \
    FILE_MANAGER_ROOT=/media

USER 65532:65532
EXPOSE 8097
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 \
    CMD wget -q -O /dev/null http://127.0.0.1:8097/health || exit 1
ENTRYPOINT ["/app/go-emby"]
DOCKERFILE_EOF

# Safety checks: the final stage must never copy the source tree.
grep -q '^FROM scratch AS artifact' "${DOCKERFILE}" || fail "缺少 artifact 阶段"
grep -q '^COPY --from=artifact /go-emby /app/go-emby' "${DOCKERFILE}" || fail "runtime 未只复制最终二进制"
if grep -Eq '^COPY[[:space:]]+\.[[:space:]]' "${DOCKERFILE}"; then
    # COPY . . is allowed only in compiler stage, never runtime. Verify line order.
    RUNTIME_LINE="$(grep -n '^FROM postgres:17-bookworm AS runtime' "${DOCKERFILE}" | cut -d: -f1)"
    BAD_RUNTIME_COPY="$(tail -n +"${RUNTIME_LINE}" "${DOCKERFILE}" | grep -nE '^COPY[[:space:]]+\.[[:space:]]' || true)"
    [[ -z "${BAD_RUNTIME_COPY}" ]] || fail "runtime 阶段存在源码 COPY"
fi

echo "✓ compiler -> artifact -> runtime 三阶段"
echo "✓ runtime 仅复制 /go-emby"

# ------------------------------------------------------------
# 4. Read GitHub PAT
# ------------------------------------------------------------

echo
echo "[4/8] 登录 GHCR..."
read -rsp "请输入 GitHub PAT（需要 write:packages）: " GITHUB_TOKEN
echo
[[ -n "${GITHUB_TOKEN}" ]] || fail "GitHub PAT 不能为空"

printf '%s' "${GITHUB_TOKEN}" | docker login ghcr.io \
    --username "${GITHUB_USER}" \
    --password-stdin
unset GITHUB_TOKEN

# ------------------------------------------------------------
# 5. Buildx
# ------------------------------------------------------------

echo
echo "[5/8] 初始化多架构 Buildx..."

if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
    docker buildx create \
        --name "${BUILDER_NAME}" \
        --driver docker-container \
        --use >/dev/null
else
    docker buildx use "${BUILDER_NAME}"
fi

docker buildx inspect --bootstrap >/dev/null

echo "✓ Builder: ${BUILDER_NAME}"

# ------------------------------------------------------------
# 6. Build + push
# ------------------------------------------------------------

echo
echo "[6/8] 编译 amd64 + arm64 并推送 GHCR..."

TAGS=(
    --tag "${IMAGE}:latest"
    --tag "${IMAGE}:${DATE_VERSION}"
    --tag "${IMAGE}:sha-${SHORT_COMMIT}"
)

docker buildx build \
    --file "${DOCKERFILE}" \
    --platform linux/amd64,linux/arm64 \
    --build-arg "SOURCE_REVISION=${GIT_COMMIT}" \
    --build-arg "BUILD_DATE=${BUILD_DATE}" \
    "${TAGS[@]}" \
    --provenance=mode=min \
    --sbom=false \
    --push \
    "${CONTEXT}"

echo "✓ GHCR 推送完成"

# ------------------------------------------------------------
# 7. Verify manifests
# ------------------------------------------------------------

echo
echo "[7/8] 验证 GHCR manifest..."

docker buildx imagetools inspect "${IMAGE}:latest" >/dev/null
docker buildx imagetools inspect "${IMAGE}:${DATE_VERSION}" >/dev/null

echo "✓ latest manifest 正常"
echo "✓ ${DATE_VERSION} manifest 正常"

# ------------------------------------------------------------
# 8. Final report
# ------------------------------------------------------------

echo
echo "[8/8] 发布完成"
echo
echo "============================================================"
echo " GHCR 发布成功"
echo "============================================================"
echo
echo "正式源码来源:"
echo "  ${SOURCE}"
echo
echo "镜像:"
echo "  ${IMAGE}:latest"
echo "  ${IMAGE}:${DATE_VERSION}"
echo "  ${IMAGE}:sha-${SHORT_COMMIT}"
echo
echo "最终运行镜像不包含:"
echo "  *.go / 项目源码目录"
echo "  Go/Node 编译工具链"
echo "  .env / secrets"
echo "  PostgreSQL 生产数据"
echo "  data / backups / media"
echo
echo "现有 GitHub Actions 会把 latest + 日期版本自动同步到:"
echo "  docker.io/macaemby/go-emby"
echo "============================================================"
