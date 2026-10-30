#!/usr/bin/env bash
# 本机没有 git 可执行文件（麒麟上装 git 要 root 交互密码），
# 这里用同一个 devenv 容器代跑 git，全局配置放在持久卷里，
# 之后照常 git add / commit / diff / log 都不受影响。
#   ./build/kylin/git.sh status
#   ./build/kylin/git.sh log --oneline -5
#   ./build/kylin/git.sh diff -- core/system_linux.go
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="res-downloader:devenv"
UID_HOST="$(id -u)"; GID_HOST="$(id -g)"

[ $# -gt 0 ] || { echo "用法: $0 <git 子命令> [参数...]"; exit 2; }

docker volume create resd-gitcfg >/dev/null

TTY_FLAG=()
[ -t 1 ] && TTY_FLAG=(-t)

docker run --rm -i "${TTY_FLAG[@]}" \
  -v "$SRC":/src \
  -v resd-gitcfg:/root/.config/git \
  -w /src \
  "$IMAGE" bash -s -- "$@" <<'EOS'
set -e
git config --global --add safe.directory '*' >/dev/null 2>&1 || true
git "$@"
chown -R "$(stat -c '%u:%g' /src)" /src/.git >/dev/null 2>&1 || true
EOS
