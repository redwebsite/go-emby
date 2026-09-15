# go-emby

Go 编写的 Emby服务端，包含 Web 管理界面、文件浏览、媒体库扫描、NFO/海报读取和 Emby 兼容接口。播放采用跳转方式，客户端直连媒体源，不提供视频转码。

支持 **Linux x64 / amd64** 和 **ARM64 / aarch64**。

## 一键部署

服务器需要提前安装 Docker Engine 和 Docker Compose v2。

```bash
curl -fsSL https://raw.githubusercontent.com/sd87671067/go-emby/main/install.sh | bash
```

安装完成后浏览器访问：

```text
http://服务器IP:8097
```

安装脚本会引导完成所需配置。请妥善保存管理员密码、数据库密码和授权信息。

> 不要执行 `docker compose down -v`，否则可能删除 PostgreSQL 数据卷。

## 说明书

详细配置、环境变量及使用说明：

[ENV_GUIDE.md](ENV_GUIDE.md)

## 更新方式

进入部署目录后执行：

```bash
docker compose pull && docker compose up -d
```

更新只需要拉取新镜像并重新创建应用容器，已有 `.env`、媒体目录和 PostgreSQL 数据卷会继续保留。

查看运行状态：

```bash
docker compose ps
```

查看 go-emby 日志：

```bash
docker compose logs --tail=100 go-emby
```

## 授权模式

本项目保留授权校验。

默认授权服务地址：

```text
https://tl.macacaaca.top
```

当前提供免费模式，`LICENSE_KEY` 可按实际授权方式配置；授权相关配置请参考 [ENV_GUIDE.md](ENV_GUIDE.md)。

主机机器标识会用于授权设备绑定，迁移服务器后可能需要重新授权。

## 交流群

TG 反馈交流群：

https://t.me/+mocElSRiXPM3NWQ1

## 赞助

项目目前为爱发电维护。赞助可以帮助加快更新和维护速度。

支付宝口令红包等赞助方式可通过 TG 私聊联系：

https://t.me/macaembychannel?direct
