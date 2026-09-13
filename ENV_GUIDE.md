# .env 中文填写说明

首次部署时，把仓库的 `.env.example` 复制成同目录的 `.env`。授权地址、小雅地址和 NanShare 地址已经填好，普通客户只需填写密码设置和授权码；免费模式下授权码可以不填。模板中的注释均为中文。

## 1. 获取配置

```bash
git clone https://github.com/sd87671067/go-emby.git
cd go-emby
[ -e .env ] || (umask 077; cp .env.example .env)
chmod 600 .env
mkdir -p media secrets
nano .env
```

Docker 的 `pull` 命令只下载镜像，不会生成宿主机 `.env`。上面的复制步骤会生成已预填地址的配置；已有配置不会被覆盖。更新仓库后，已有用户可以按需手动修改三个地址，不要覆盖自己的密码。

## 2. 客户需要填写的项目

| 变量 | 填写说明 |
| --- | --- |
| `POSTGRES_PASSWORD` | 必填，数据库密码。建议执行 `openssl rand -hex 24` 生成，只使用十六进制字符，避免数据库连接地址的特殊字符转义问题。 |
| `ADMIN_PASSWORD` | 必填，初始管理员 `admin` 的密码，至少 12 个字符；建议单独生成，与数据库密码不同。 |
| `LICENSE_KEY` | 付费模式填写有效授权码；授权服务开启免费模式时留空即可。 |

例如，免费模式保留 `LICENSE_KEY=`；付费模式填写 `LICENSE_KEY='你的授权码'`。填写时不要把示例文字当作真实密码或授权码。包含 `$`、`#` 或空格的值请使用英文单引号包围。

是否免费由授权服务决定，留空授权码本身不会切换模式，也不会跳过授权校验。免费模式仍需能连接授权服务。

## 3. 已填好的地址

```dotenv
# 授权服务地址，通常不需要修改
LICENSE_SERVER_URL=https://tl.macacaaca.top
# 小雅服务地址
XIAOYA_URL=http://172.18.0.1:5678
# NanShare 服务地址
NANSHARE_URL=http://172.18.0.1:8115
```

环境变量区分大小写，必须使用上面的大写名称，不要改为 `xiaoya_url` 或 `NanShare_url`。Compose 对这三个变量同时设置了默认值，未配置或留空时仍使用上面的地址。修改 `.env` 后执行 `docker compose up -d`，让 Compose 重建配置发生变化的容器。

`172.18.0.1` 是内网地址，客户主机需要确保 go-emby 容器能访问该地址的 5678 和 8115 端口。如果客户 Docker 网络或上游服务地址不同，请改成容器实际可访问的小雅和 NanShare 地址。预填地址不会自动安装这两个服务。

## 4. 启动与访问

默认媒体目录为当前仓库下的 `./media`，将 STRM、NFO、海报等文件放入其中；已有其他媒体目录时，才需要修改 `MEDIA_PATH`。容器内统一使用 `/media`，媒体文件需要允许 UID/GID `65532:65532` 读取。

```bash
docker compose config --quiet
docker compose pull && docker compose up -d
docker compose ps
```

浏览器访问 `http://你的服务器地址:8097`，用户名 `admin`，密码为首次初始化时设置的 `ADMIN_PASSWORD`。配置准备好之后，拉取并启动只需上面的 `docker compose pull && docker compose up -d` 一行命令。

## 5. 其他可选设置

| 变量 | 默认值与说明 |
| --- | --- |
| `IMAGE_TAG` | `latest`，需要固定版本时再修改。 |
| `HTTP_PORT` | `8097`，宿主机端口冲突时修改。 |
| `MEDIA_PATH` | `./media`，宿主机媒体目录，必须提前存在。 |
| `LICENSE_CA_FILE` | 留空，使用系统信任的公共证书；私有 CA 场景将证书放入 `secrets/license-ca.crt`，填写 `/run/secrets/license-ca.crt`。 |
| `PUBLIC_URL` | 留空，按需填写客户端可访问的本服务完整地址。 |
| `PUBLIC_PLAYBACK_URL` | 留空，按需配置对外播放入口。 |
| `BOOTSTRAP_API_KEY` | 留空，按需配置首次初始化的接口密钥。 |
| `PROBE_PLAYBACK_URL` | 留空，按需配置后台媒体探测入口。 |

## 6. 已有部署注意事项

`ADMIN_PASSWORD` 只用于空数据库首次初始化，后续修改管理员密码请使用管理界面。已有 PostgreSQL 数据库不能只修改 `.env` 的 `POSTGRES_PASSWORD`，还需同步修改数据库角色密码。升级时保留 `.env`、媒体、证书和数据卷，不要执行会删除数据卷的 `docker compose down -v`。

不要公开自己的 `.env`。仓库只提供不含客户密码和授权码的模板。本次配置与文档调整不修改程序、播放逻辑、接口或授权机制。
