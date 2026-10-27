#!/usr/bin/env bash
# 端到端验证：在一个干净的 focal 容器里装 deb、起真 GUI（Xvfb），
# 然后让代理完全只依赖"系统信任链"抓 HTTPS —— 也就是新电脑上装完就用的真实路径。
#   ./build/kylin/test-e2e-in-container.sh [deb 文件名]
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="res-downloader:devenv"
DEB="${1:-$(ls -1t "$SRC"/dist/*_arm64.deb 2>/dev/null | head -1)}"
[ -n "$DEB" ] && [ -f "$DEB" ] || { echo "找不到 deb，先跑 package-deb.sh"; exit 1; }

echo "用包：$(basename "$DEB")"
docker run --rm --shm-size=1g -v "$DEB":/tmp/rd.deb "$IMAGE" bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq xvfb ca-certificates curl acl x11-utils >/dev/null 2>&1
echo "== 安装（以 SUDO_USER=appuser 模拟真实 sudo dpkg -i）"
useradd -m appuser 2>/dev/null || true
useradd -m nosy 2>/dev/null || true
SUDO_USER=appuser dpkg -i /tmp/rd.deb >/tmp/dpkg.log 2>&1 || { cat /tmp/dpkg.log; exit 1; }
ls -l /etc/res-downloader/ | sed "s/^/   /"
echo "   ACL: $(getfacl -p /etc/res-downloader/ca.key 2>/dev/null | grep -E "^user:" | tr "\n" " ")"
echo "   bundle 是否信任它: $(openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt /etc/res-downloader/ca.crt 2>&1 | tail -1)"

echo "== 权限边界（方案 B 的关键前提）"
if su appuser -c "cat /etc/res-downloader/ca.key" >/dev/null 2>&1; then
  echo "   安装用户 appuser 可读私钥：OK"
else
  echo "   appuser 读不到私钥 → 会退回用户级自建（可抓包但每台机器多一步）"
fi
if su nosy -c "cat /etc/res-downloader/ca.key" >/dev/null 2>&1; then
  echo "   ⚠ 同机其他用户 nosy 也能读私钥，隔离没做住"
else
  echo "   同机其他用户 nosy 读不到私钥：OK"
fi

Xvfb :99 -screen 0 1280x800x24 >/tmp/xvfb.log 2>&1 &
sleep 3
echo "== 以普通用户启动 app（真实桌面场景，root 私钥靠 ACL 读）"
su appuser -c "export HOME=/home/appuser DISPLAY=:99 GDK_BACKEND=x11 WEBKIT_DISABLE_COMPOSITING_MODE=1; nohup /usr/local/bin/res-downloader >/tmp/app.log 2>&1 &"
for i in $(seq 1 30); do
  curl -s -m 2 -o /dev/null http://127.0.0.1:8899/api/app-info && break
  sleep 1
done
grep -E "version:|\[ca\]|Service started" /tmp/app.log | sed "s/^/   /"

echo "== 界面是否真渲染（WebProcess 存活）"
pgrep -f WebKitWebProces >/dev/null && echo "   WebProcess 在跑" || { echo "   WebProcess 没起来"; tail -5 /tmp/app.log; }

echo "== WM_CLASS 与桌面项 StartupWMClass 是否对得上（任务栏能否认出去向）"
INST=$(DISPLAY=:99 xprop -name res-downloader WM_CLASS 2>/dev/null | cut -d, -f1 | cut -d= -f2 | tr -d " \"")
echo "   窗口 WM_CLASS 实例名: ${INST:-取不到}"
grep -o "StartupWMClass=.*" /usr/share/applications/res-downloader.desktop | sed "s|^|   桌面项: |"
if [ "$INST" = "res-downloader" ]; then
  echo "   匹配：UKUI 面板会把窗口认成已安装应用，不固定也会有任务栏按钮"
else
  echo "   不匹配：面板认不出这个窗口，表现就是必须手动固定"
fi


echo "== 关键一测：不指定 --cacert，纯靠系统信任链抓 HTTPS（等价于浏览器）"
curl -s -o /dev/null -m 30 -x http://127.0.0.1:8899 -w "   example.com → HTTP %{http_code} ssl_verify=%{ssl_verify_result}\n" https://example.com/ || echo "   失败"
curl -s -o /dev/null -m 30 -x http://127.0.0.1:8899 -w "   www.baidu.com → HTTP %{http_code} ssl_verify=%{ssl_verify_result}\n" https://www.baidu.com/ || echo "   失败"

echo "== 证书状态诊断（-ca-status）"
su appuser -c "export HOME=/home/appuser; /usr/lib/res-downloader/res-downloader -ca-status" 2>&1 | sed "s/^/   /"

echo "== 界面「安装证书」应当直接报已安装（真检测，不是看 lock 文件）"
curl -s -m 10 -X POST http://127.0.0.1:8899/api/install | sed "s/^/   /"; echo
echo "== install.lock 内容"
cat /home/appuser/.config/res-downloader/install.lock 2>/dev/null | sed "s/^/   /"; echo
echo "== 证书下载接口给的是不是本机这把"
curl -s -m 10 http://127.0.0.1:8899/api/cert | openssl x509 -noout -subject | sed "s/^/   /"
openssl x509 -in /etc/res-downloader/ca.crt -noout -subject | sed "s/^/   磁盘: /"
'
