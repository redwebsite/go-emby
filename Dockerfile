# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM node:22-bookworm-slim AS frontend
WORKDIR /ui
COPY file-ui/package.json file-ui/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY file-ui/ ./
RUN npm run build

FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY *.go ./
COPY internal/ ./internal/
COPY web/index.html ./web/index.html
COPY --from=frontend /web/files ./web/files
ARG TARGETOS
ARG TARGETARCH
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -mod=readonly -trimpath -buildvcs=false -ldflags="-s -w" -o /out/go-emby .

FROM scratch AS binary
COPY --from=build /out/go-emby /go-emby

FROM postgres:17-bookworm AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates wget ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /app/data /app/backups /media /run/secrets \
    && chown -R 65532:65532 /app /media
LABEL org.opencontainers.image.title="go-emby" \
      org.opencontainers.image.source="https://github.com/sd87671067/go-emby" \
      org.opencontainers.image.description="Go STRM media server"
WORKDIR /app
COPY --from=build /out/go-emby /app/go-emby
ENV LISTEN=:8097 MEDIA_INFO_ROOT=/app/data FILE_MANAGER_ROOT=/media
USER 65532:65532
EXPOSE 8097
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 CMD wget -q -O /dev/null http://127.0.0.1:8097/health || exit 1
ENTRYPOINT ["/app/go-emby"]
