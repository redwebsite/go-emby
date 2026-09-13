# go-emby
TG反馈交流群 https://t.me/+mocElSRiXPM3NWQ1
Go 编写的 STRM 媒体服务端，包含 Web 管理界面、文件浏览、媒体库扫描、NFO/海报读取和 Emby 兼容接口。播放采用跳转方式，客户端直连媒体源；不提供视频转码。后台媒体探测使用 FFmpeg，可能读取部分媒体内容。

本仓库发布 **Linux x64 / amd64 和 ARM64 / aarch64** 镜像：`ghcr.io/sd87671067/go-emby:latest`。镜像内包含编译后的 Go 二进制及嵌入式前端，不含 Go/Node 构建工具、项目源码、生产数据库或生产配置。

**此版本保留授权校验。** `.env.example` 和 Compose 已默认配置授权地址 `https://tl.macacaaca.top`。当前免费开放，仓库不提供授权服务器、授权码或证书。授权未通过时业务接口返回 HTTP 402，健康检查通过不代表授权有效。
目前免费 有好心人可以支付宝口令红包赞助我，TG私聊赞助https://t.me/macaembychannel?direct

## 快速部署

准备 Linux x64 或 ARM64 主机、Docker Engine 和 Docker Compose v2，以及两个自设密码（付费模式还需授权码）。首次部署需要先准备配置，后续启动/更新只需指定的一行命令。

```bash
git clone https://github.com/sd87671067/go-emby.git
cd go-emby
[ -e .env ] || (umask 077; cp .env.example .env)
chmod 600 .env
mkdir -p media secrets
# 分别执行两次，将结果填入下面对应的密码变量
openssl rand -hex 24
openssl rand -hex 24
nano .env
```

详细中文说明见 [ENV_GUIDE.md](ENV_GUIDE.md)。授权地址、小雅地址 `http://172.18.0.1:5678` 和 NanShare 地址 `http://172.18.0.1:8115` 已预填，正常部署无需再改。Docker 拉取镜像本身不会在宿主机创建 `.env`，首次部署由上面的复制命令生成配置。

在 `.env` 填写 `POSTGRES_PASSWORD`、`ADMIN_PASSWORD`、`LICENSE_KEY`（免费模式可留空）；将 `MEDIA_PATH` 设为主机上真实的媒体目录，或将 STRM/NFO/海报文件放入 `./media`。管理员密码至少 12 字符。数据库密码请使用上面生成的十六进制字符串，避免数据库 URL 中的特殊字符转义问题。授权码若含 `$`、`#` 等字符，在 `.env` 中用单引号包围整个值。

如果授权服务使用私有 CA，将证书保存为 `secrets/license-ca.crt`，并设置 `LICENSE_CA_FILE=/run/secrets/license-ca.crt`。容器使用 UID/GID `65532:65532`，确保该用户可读取证书、媒体目录及宿主机 `/etc/machine-id`。正常公共 CA 服务可留空 `LICENSE_CA_FILE`。

配置完成后执行：

```bash
docker compose config --quiet
docker compose pull && docker compose up -d
```

浏览器打开 `http://localhost:8097`；远程访问时将 `localhost` 替换为你的服务器域名。初始管理员用户名为 `admin`，密码是 `.env` 的 `ADMIN_PASSWORD`。此变量仅用于空数据库首次初始化；已有账号的密码请在管理界面修改。客户端和媒体库配置统一使用容器内路径 `/media`。

镜像包需要设为 Public 才能匿名拉取；公共源码仓库与镜像包的可见性是两个独立设置。若出现 `denied`，请先查看本文“维护者发布”部分，不要向普通部署者分发维护者的 GitHub 令牌。

## 环境变量

Compose 自动读取同目录 `.env`，仅将列出的应用变量注入容器。

| 变量 | 用途 |
| --- | --- |
| `IMAGE_TAG` | 默认 `latest`；可改为发布标签或 `sha-...` 固定版本 |
| `HTTP_PORT` | 宿主机端口，默认 `8097` |
| `MEDIA_PATH` | 宿主机媒体目录，默认 `./media`；必须预先存在 |
| `POSTGRES_PASSWORD` | PostgreSQL 密码，必填；已有数据库改密码需同步修改数据库角色密码 |
| `ADMIN_PASSWORD` | 首次初始化管理员密码，至少 12 字符 |
| `LICENSE_SERVER_URL` | 已预填 `https://tl.macacaaca.top`，通常无需修改 |
| `LICENSE_KEY` | 授权码，运行时注入；免费模式可留空 |
| `LICENSE_CA_FILE` | 可选的容器内 CA 文件路径，默认使用系统信任库；不允许跳过 TLS 校验 |
| `PUBLIC_URL` | 客户端可访问的本服务完整 URL，用自己的域名填写 |
| `PUBLIC_PLAYBACK_URL` | 可选的播放入口 URL，默认留空 |
| `BOOTSTRAP_API_KEY` | 可选的首次初始化 API 密钥；自行生成，默认留空 |
| `NANSHARE_URL` | NanShare 服务地址，默认 `http://172.18.0.1:8115` |
| `XIAOYA_URL` | 小雅服务地址，默认 `http://172.18.0.1:5678` |
| `PROBE_PLAYBACK_URL` | 可选的后台媒体探测入口，默认留空 |

主机机器标识只读挂载到 `/run/license-machine-id`，程序将其哈希后用于授权设备绑定，不写入镜像或仓库。迁移到新主机可能需要重新授权。直接运行二进制时可使用 `LICENSE_MACHINE_ID_FILE` 指定该文件。

## 数据与权限

- `postgres-data`：PostgreSQL 数据，容器之间通过内部网络连接，默认不映射数据库端口。
- `app-data`：媒体信息缓存；`app-backups`：应用自动生成的 PostgreSQL 备份。
- 媒体目录默认**只读挂载**，支持浏览、扫描与播放；不要在生产环境执行 `docker compose down -v`，该命令会删除命名卷。
- 原项目的文件删除/重命名需要可写媒体挂载及单独部署的宿主机占用检查服务（Unix socket，变量 `FILE_BUSY_SOCKET`）。当前通用 Compose 不部署该宿主机服务，文件变更操作会被拒绝。请勿仅移除只读选项便假定可以安全删除文件。
- 自行配置反向代理与 HTTPS；证书、真实地址和第三方服务凭据均保留在部署主机。

## 更新、检查和备份

```bash
# 更新时保留 .env、secrets 和数据卷
docker compose pull && docker compose up -d
# 查看状态与近期日志（分享日志前自行脱敏）
docker compose ps
docker compose logs --tail=100 go-emby
curl --fail http://localhost:8097/health
curl --fail http://localhost:8097/license/status
# 更新前备份数据库到宿主机
mkdir -p backups
docker compose exec -T postgres pg_dump -U emby -d emby -Fc > "backups/emby-$(date +%Y%m%d-%H%M%S).dump"
```

HTTP 402：检查授权状态、授权服务可达性、机器绑定及 CA 配置。`x509` 错误：检查 CA 文件、服务证书及域名是否匹配。`permission denied`：检查 UID 65532 的目录访问权限。数据库启动失败：查看 PostgreSQL 日志；修改 `.env` 不会自动更改已初始化数据库的密码。端口冲突：修改 `HTTP_PORT`。

应用每天尝试生成数据库备份，保留最近 14 份；请额外将数据库备份、`.env`、授权证书和必要缓存保存到私有备份位置。数据库恢复属于覆盖性操作，应先停止应用并针对目标数据库制定恢复方案。

## 从源码构建

Dockerfile 使用前端构建、Go 编译、运行时三个主要阶段。Go 采用 `CGO_ENABLED=0`、`-trimpath` 和剥离符号编译，前端静态资源嵌入二进制；运行镜像只复制编译产物，并提供 `ffmpeg/ffprobe` 和 PostgreSQL 17 备份工具。构建过程不需要生产 `.env`、授权码或 CA。

```bash
docker build --platform linux/amd64 -t go-emby:local .
# 导出当前目标架构二进制到 dist/go-emby；ARM64 改为 linux/arm64
docker buildx build --platform linux/amd64 --target binary --output type=local,dest=dist .
```

原生开发需要 Go 1.26、Node.js 22 和 PostgreSQL 17。先在 `file-ui` 运行 `npm ci && npm run build`，再在仓库根目录运行 `go test ./...`。完整数据库集成测试必须设置指向**专用测试数据库**的 `TEST_DATABASE_URL`，未设置时相关测试会跳过。CI 会启动独立数据库执行完整测试。

## 维护者发布

推送 `main` 会先审计已跟踪文件、构建前端并执行测试，再通过 GitHub Actions 发布 amd64 和 arm64 多架构镜像到 GHCR，标签为 `latest` 和 `sha-...`。推送 `v*` 标签可生成对应版本镜像。工作流使用 GitHub 自动提供的 `GITHUB_TOKEN`，无需把个人访问令牌写入源码或 Actions 配置。

首次发布后，在 [go-emby 镜像设置](https://github.com/users/sd87671067/packages/container/go-emby/settings) 中确认 Visibility 为 **Public**。GitHub 默认将新镜像包设为私有，首次公开可能需要维护者在网页完成；具体见 [GitHub 容器仓库说明](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)。必须用未登录 GHCR 的环境验证 `docker compose pull`，成功后才能宣称已支持匿名一键拉取。

`.gitignore` 排除环境文件、证书、密钥、数据和备份；`.dockerignore` 采用构建输入白名单。提交前运行：

```bash
python3 scripts/check-public.py
```

该检查会拒绝常见令牌、私钥标记、公开 IP 字面量及敏感文件类型，但不能替代人工审查。测试中保留的回环、文档示例和通用 Docker 内网地址不是生产服务器信息。不要提交生产配置、用户数据、数据库转储、调试报告或既有生产二进制。
