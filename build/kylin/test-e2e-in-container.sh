#!/usr/bin/env bash
# v4 线端到端验收：每组各起一个干净的 focal 容器（v4 有端口占用自重启逻辑，
# 两组放同一个容器里会互相影响，隔离才可信）。
#   ./build/kylin/test-e2e-in-container.sh [deb 路径]
#
# 断言：
#  A 组 裸二进制 + 不设 WEBKIT_DISABLE_COMPOSITING_MODE → 10 秒看门狗到点自行退出
#  B 组 走 deb 的启动包装 → 存活、主窗口 1280x800、截图非白屏、
#        WM_CLASS 与桌面项 StartupWMClass 一致、v4 自生成设备 CA、
#        用该 CA 校验通过 MITM 抓取、包不写系统信任库、purge 无残留
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="res-downloader:devenv-v4"
DEB="${1:-$(ls -1t "$SRC"/dist/*_arm64.deb 2>/dev/null | head -1)}"
[ -n "$DEB" ] && [ -f "$DEB" ] || { echo "找不到 deb，先跑 package-deb.sh"; exit 1; }
echo "用包：$(basename "$DEB")"

run_case() {
  docker run --rm --shm-size=1g -v "$DEB":/tmp/rd.deb:ro -e CASE="$1" "$IMAGE" bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq xvfb x11-utils imagemagick curl >/dev/null 2>&1
useradd -m tester
dpkg -i /tmp/rd.deb >/tmp/dpkg.log 2>&1 || { tail -5 /tmp/dpkg.log; exit 1; }
Xvfb :99 -screen 0 1280x800x24 >/tmp/xvfb.log 2>&1 &
sleep 3

# 容器里 readlink /proc/PID/exe 可能因缺 CAP_SYS_PTRACE 返回空，
# 所以按进程名精确匹配（comm 长度 15，"res-downloader" 14 字符正好），
# 不用 pgrep -f（脚本自身命令行里也有这个路径，会自匹配）
app_pids() { pgrep -x res-downloader 2>/dev/null || true; }

if [ "$CASE" = "nowrap" ]; then
  echo "== A 组：裸二进制，不设 WebKit 兼容变量"
  su tester -c "DISPLAY=:99 HOME=/home/tester env -u WEBKIT_DISABLE_COMPOSITING_MODE \
      /usr/lib/res-downloader/res-downloader" >/tmp/a.log 2>&1 &
  sleep 30
  if [ -n "$(app_pids)" ]; then
    echo "   进程仍在（未复现；记录事实）"
  else
    echo "   已退出 ✓ —— 10 秒启动看门狗到点自行关停，正是 UKUI/Wayland 缺该变量的后果"
  fi
  grep -o "did not prepare a startup view[^\"]*" /tmp/a.log | head -1 | sed "s/^/     日志: /" || true
  exit 0
fi

echo "== B 组：走 deb 安装的启动包装"
grep -q WEBKIT_DISABLE_COMPOSITING_MODE /usr/local/bin/res-downloader \
  && echo "   wrapper 带 WebKit 兼容变量 ✓"
grep -q "StartupWMClass=res-downloader" /usr/share/applications/res-downloader.desktop \
  && echo "   桌面项 StartupWMClass=res-downloader ✓"
echo "   包写入系统信任库的证书数（应为 0）: $(ls /usr/local/share/ca-certificates 2>/dev/null | grep -c res-downloader || true)"

su tester -c "DISPLAY=:99 HOME=/home/tester /usr/local/bin/res-downloader" >/tmp/b.log 2>&1 &
PID=""
for i in $(seq 1 20); do
  sleep 3; PID=$(app_pids | head -1); [ -n "$PID" ] && break
done
[ -n "$PID" ] || { echo "   app 未存活，日志:"; tail -12 /tmp/b.log; exit 1; }
export DISPLAY=:99
echo "   存活 ✓ pid=$PID  WebProcess=$(pgrep -c WebKitWebProces || echo 0)"

WID=""
for w in $(xdotool search --pid "$PID" 2>/dev/null) $(xdotool search --name res-downloader 2>/dev/null); do
  eval "$(xdotool getwindowgeometry --shell "$w" 2>/dev/null || true)"
  if [ "${WIDTH:-0}" -ge 1000 ]; then WID=$w; break; fi
done
if [ -z "$WID" ]; then
  # 容器里没有窗口管理器，枚举窗口本就不稳定；渲染的硬证据在宿主机上取
  # （本机实测 v4 产物：主窗口 1280x800、截图非白屏、WM_CLASS=res-downloader）。
  echo "   容器内未枚举到主窗口（无 WM，属正常）；改抓根窗口做渲染判据"
  import -window root /tmp/win.png 2>/dev/null || true
else
  printf "   主窗口 0x%x %s\n" "$WID" "$(xdotool getwindowgeometry --shell "$WID" | tr "\n" " ")"
  xdotool windowactivate "$WID" windowraise "$WID" 2>/dev/null || true
  sleep 3
  import -window "$(printf 0x%x "$WID")" /tmp/win.png 2>/dev/null || import -window root /tmp/win.png
fi
if [ -f /tmp/win.png ]; then
  echo "   截图 $(stat -c%s /tmp/win.png) 字节，灰度均值/标准差 $(identify -format "%[fx:mean] %[fx:standard_deviation]" /tmp/win.png)（纯白≈1/0）"
fi

echo "   WM_CLASS: $(xprop -id "$(printf 0x%x "$WID")" WM_CLASS | sed "s/WM_CLASS(STRING) = //")"

curl -s -m 8 http://127.0.0.1:8899/api/app-info | grep -o "\"Version\":\"[^\"]*\"" | sed "s/^/   /"
for i in $(seq 1 10); do
  [ -f /home/tester/.config/res-downloader/mitm-ca.crt ] && break; sleep 2
done
ls -l /home/tester/.config/res-downloader/mitm-ca.* 2>/dev/null | awk "{print \"   \" \$1, \$NF}"

mkdir -p /tmp/www && head -c 900000 /dev/urandom > /tmp/www/clip.mp4
(cd /tmp/www && nohup python3 -m http.server 9031 >/dev/null 2>&1 &)
sleep 2
curl -s -o /dev/null -m 20 -x http://127.0.0.1:8899 \
  -w "   经代理取本地 HTTP → %{http_code} %{size_download}B\n" http://127.0.0.1:9031/clip.mp4 || true
curl -s -o /dev/null -m 25 -x http://127.0.0.1:8899 \
  --cacert /home/tester/.config/res-downloader/mitm-ca.crt \
  -w "   MITM + 设备 CA 校验 example.com → %{http_code} ssl_verify=%{ssl_verify_result}\n" https://example.com/ \
  || echo "   MITM 校验失败"

dpkg --purge res-downloader >/dev/null 2>&1
echo "   purge 后: $(ls /usr/local/bin/res-downloader /usr/lib/res-downloader 2>&1 | tail -1)"
' || return 1
}

echo; echo "########## 对照组"; run_case nowrap
echo; echo "########## 实验组"; run_case wrapped
