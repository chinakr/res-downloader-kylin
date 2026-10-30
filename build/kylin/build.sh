#!/usr/bin/env bash
# 在 glibc 2.31 基线容器里编译，产物直接在银河麒麟 V10 SP1 (arm64) 原生运行。
# 用法：
#   ./build/kylin/build.sh              # 前端 + Go 全量构建
#   ./build/kylin/build.sh --skip-fe    # 只重编 Go（复用已有 frontend/dist）
#   ./build/kylin/build.sh --shell      # 进容器调试
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="res-downloader:devenv-v4"
DOCKERFILE="$SRC/build/kylin/Dockerfile.devenv"
OUT="$SRC/bin"
UID_HOST="$(id -u)"
GID_HOST="$(id -g)"
GO_LDFLAGS="-s -w"
# Wails v2 的平台前端代码由构建标签控制，官方 CLI 会自动注入 desktop,production；
# 直接 go build 时若漏掉，产物会是个只会打印
# "Wails applications will not build without the correct build tags" 的空壳。
GO_TAGS="desktop,production"

VER="$(sed -n 's/.*"productVersion": *"\([^"]*\)".*/\1/p' "$SRC/wails.json" | head -1)"

SKIP_FE=0; MODE=build
for a in "$@"; do
  case "$a" in
    --skip-fe) SKIP_FE=1 ;;
    --shell)   MODE=shell ;;
    *) echo "未知参数: $a"; exit 2 ;;
  esac
done

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "[i] 构建环境镜像不存在，先构建 $IMAGE"
  docker build -f "$DOCKERFILE" -t "$IMAGE" "$SRC"
fi

docker volume create resd-gomod >/dev/null
docker volume create resd-npmcache >/dev/null

RUN=(docker run --rm
  -v "$SRC":/src
  -v resd-gomod:/go/pkg/mod
  -v resd-npmcache:/root/.npm
  -w /src -e CGO_ENABLED=1 -e GOPROXY=https://goproxy.cn,direct \
  -e GOMODCACHE=/go/pkg/mod
  "$IMAGE")

# 构建中断也要把容器内 root 产生的文件归还给宿主机用户，否则麒麟上无法再次编辑
cleanup() {
  docker run --rm -v "$SRC":/src "$IMAGE" chown -R "$UID_HOST:$GID_HOST" /src >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [ "$MODE" = shell ]; then
  "${RUN[@]}" bash
  exit 0
fi

echo "[1/3] 前端构建 (vite)"
if [ "$SKIP_FE" = 0 ]; then
  "${RUN[@]}" bash -ec '
    cd frontend
    [ -d node_modules ] || npm install --no-audit --no-fund --loglevel=error
    npx vite build
    ls -la dist | head -5
  '
else
  echo "  跳过（--skip-fe）"
fi

echo "[2/3] Go + CGO(webkit2gtk-4.0) 编译 linux/arm64"
mkdir -p "$OUT"
# 版本策略：上游 productVersion（v4 分支是 4.0.0）保持不动，
#   包版本 = <上游版本>-<KYLIN_REV>+build<提交数>-<短哈希>[-dirty]
# 通过 v4 自带的 -X res-downloader/internal/app.ReleaseVersion 注入（上游本来就用它
# 保留 prerelease 标识，见 internal/app/app.go:23），所以版本号不需要改动任何源码。
# 构建标记在**宿主机**上算：worktree 的 .git 是指回主仓库的文件，容器里看不到它。
KYLIN_REV="${KYLIN_REV:-kylin1}"
STAMP="build$(git -C "$SRC" rev-list --count HEAD 2>/dev/null || echo 0)-$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo no-git)"
git -C "$SRC" diff --quiet 2>/dev/null || STAMP="$STAMP-dirty"
PKG_VER="$VER-$KYLIN_REV+$STAMP"
printf '%s\n' "$STAMP" > "$OUT/.buildstamp"
printf '%s\n' "$PKG_VER" > "$OUT/.package-version"
echo "  包版本: $PKG_VER"
# -buildvcs=false：挂载进来的 .git 属主与容器内 root 不一致，git 会拒绝读仓库。
"${RUN[@]}" bash -ec "
  go mod download
  go build -trimpath -buildvcs=false -tags '$GO_TAGS' -ldflags \"$GO_LDFLAGS -X res-downloader/internal/app.ReleaseVersion=$PKG_VER\" -o bin/res-downloader-linux-arm64 .
"

BIN="$OUT/res-downloader-linux-arm64"
echo "[3/3] 产物检查"
file "$BIN" 2>/dev/null || true
printf '  大小: %s MiB\n' "$(( $(stat -c%s "$BIN") / 1048576 ))"
printf '  版本: %s\n' "$VER"
echo "  最高 glibc 需求:"
objdump -T "$BIN" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -3 | sed 's/^/    /'
echo "完成：$BIN"
