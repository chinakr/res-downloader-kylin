#!/usr/bin/env bash
# 把麒麟原生构建产物打成 .deb，供其他银河麒麟 V10 SP1 / Ubuntu 20.04 (arm64) 机器安装。
#   ./build/kylin/package-deb.sh                # 产出 dist/*.deb
#   ./build/kylin/package-deb.sh --test-install # 额外在 focal 容器里真装一遍，验 postinst/purge
# 全程不需要 root：dpkg-deb 用 --root-owner-group 把包内属主统一写成 root。
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$SRC/bin/res-downloader-linux-arm64"
PKG="res-downloader"
VERSION="${VERSION:-$(sed -n 's/.*"productVersion": *"\([^"]*\)".*/\1/p' "$SRC/wails.json" | head -1)-kylin1}"
ARCH="${ARCH:-$(dpkg --print-architecture 2>/dev/null || echo arm64)}"
STAGE="$SRC/build/kylin/.stage"
DIST="$SRC/dist"
TEST=0; [ "${1:-}" = "--test-install" ] && TEST=1
# RESD_WITH_CA=0 出一个不内置根证书的变体：装完不会往系统信任库加这把
# 全世界共用、私钥公开在仓库里的 CA，需要抓 HTTPS 时再由用户在界面里点"安装证书"。
WITH_CA="${RESD_WITH_CA:-1}"

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

[ -n "$VERSION" ] || { echo "取不到版本号，检查 wails.json 的 productVersion"; exit 1; }
[ -x "$BIN" ] || { echo "找不到产物 $BIN，请先执行 ./build/kylin/build.sh"; exit 1; }
command -v dpkg-deb >/dev/null || { echo "本机没有 dpkg-deb"; exit 1; }

echo "[1/4] 组装 ${PKG} ${VERSION} (${ARCH}) 目录树"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/local/bin" "$STAGE/usr/share/applications" \
         "$STAGE/usr/share/icons/hicolor/256x256/apps"

install -m 755 "$BIN" "$STAGE/usr/local/bin/res-downloader.app"
install -m 644 "$SRC/build/appicon.png" "$STAGE/usr/share/icons/hicolor/256x256/apps/res-downloader.png"

# 随包 CA 直接从 core/app.go 抽，不另存副本，避免和二进制里编译进去的那把对不上：
# 上游把 MITM 根证书硬编码在源码里（公钥+私钥，全网共用同一把，CN=gowas.cn），
# postinst 必须装的正是这一把，浏览器才会认。
# 注意它作为包内文件直接落在 /usr/local/share/ca-certificates，purge 时由 dpkg 自己回收，
# 不需要在 scriptlet 里手写删除逻辑。
CA_PEM="$STAGE/usr/local/share/ca-certificates/res-downloader.crt"
if [ "$WITH_CA" = 1 ]; then
  mkdir -p "$(dirname "$CA_PEM")"
  awk '/PublicCrt:[[:space:]]*\[\]byte\(`/{f=1;sub(/^[^`]*`/,"");print;next}
       f{if(/`\)/){sub(/`\).*/,"");printf "%s",$0;exit} print}' \
       "$SRC/core/app.go" > "$CA_PEM"
  openssl x509 -in "$CA_PEM" -noout >/dev/null 2>&1 \
    && grep -q 'CA:TRUE' <(openssl x509 -in "$CA_PEM" -noout -text) \
    || { echo "抽取失败或不是 CA：core/app.go 里 PublicCrt 结构可能变了，请同步修改这里的 awk 规则"; exit 1; }
  chmod 644 "$CA_PEM"
  echo "  随包 CA: $(openssl x509 -in "$CA_PEM" -noout -enddate)  $(openssl x509 -in "$CA_PEM" -noout -fingerprint -sha256 | cut -d= -f2 | cut -c1-23)…"
else
  echo "  不随包内置根证书（RESD_WITH_CA=0），抓 HTTPS 需在界面里点安装证书"
fi

# 启动包装：UKUI 是 Wayland 会话 + XWayland，WebKitGTK 2.38 的硬件合成路径
# 会让 WebProcess 启动即崩（表现是窗口存在但纯白），必须固定这两个变量。
cat > "$STAGE/usr/local/bin/res-downloader" <<'EOF'
#!/bin/sh
export GDK_BACKEND="${GDK_BACKEND:-x11}"
export WEBKIT_DISABLE_COMPOSITING_MODE="${WEBKIT_DISABLE_COMPOSITING_MODE:-1}"
exec /usr/local/bin/res-downloader.app "$@"
EOF
chmod 755 "$STAGE/usr/local/bin/res-downloader"

cat > "$STAGE/usr/share/applications/res-downloader.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=res-downloader
Name[zh_CN]=资源下载器
GenericName=Resource Downloader
Comment=网络资源嗅探与高速下载（麒麟 V10 原生适配版）
Exec=/usr/local/bin/res-downloader
Icon=/usr/share/icons/hicolor/256x256/apps/res-downloader.png
Terminal=false
Categories=Utility;FileTransfer;
StartupNotify=false
EOF

cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Depends: libwebkit2gtk-4.0-37, libgtk-3-0
Recommends: libnss3-tools, gsettings-desktop-schemas
Maintainer: yewei <yewei@mj-yewei.local>
Homepage: https://github.com/putyy/res-downloader
Description: 网络资源嗅探与高速下载工具（银河麒麟 V10 SP1 原生适配版）
 res-downloader 是一款集网络资源嗅探与高速下载于一体的桌面工具。
 本包为麒麟 V10 SP1 (arm64) 源码重编译的原生适配版：glibc 门槛从 2.34 降到 2.17，
 不依赖 Docker 即可运行；已适配 peony 文件管理器、接管系统代理时备份并还原原设置、
 证书支持免 root 安装到用户 NSS 库，并附带 UKUI 开始菜单项与系统信任库自动导入。
EOF

# dpkg 跑 scriptlet 时已是 root，证书文件本身由包管理，这里只负责刷新系统信任库，
# 正好补上界面里"安装证书"需要交互密码的那一步。
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v update-ca-certificates >/dev/null 2>&1; then
  update-ca-certificates >/var/log/res-downloader-ca.log 2>&1 \
    || echo "warning: 导入系统信任库失败，见 /var/log/res-downloader-ca.log" >&2
else
  echo "warning: 系统无 update-ca-certificates，请手动导入 /usr/local/share/ca-certificates/res-downloader.crt" >&2
fi
command -v update-desktop-database >/dev/null 2>&1 \
  && update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
exit 0
EOF

# 升级(upgrade)时什么都不做；移除/purge 后重建 bundle，把这把 CA 从系统信任里摘掉。
cat > "$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
case "${1:-}" in
  remove|purge)
    command -v update-ca-certificates >/dev/null 2>&1 \
      && update-ca-certificates --fresh >/dev/null 2>&1 || true
    ;;
esac
command -v update-desktop-database >/dev/null 2>&1 \
  && update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
exit 0
EOF

chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"

echo "[2/4] 生成 md5sums"
( cd "$STAGE" && find usr -type f ! -name res-downloader.app -exec md5sum {} \; > DEBIAN/md5sums )

echo "[3/4] dpkg-deb 打包"
mkdir -p "$DIST"
DEB="$DIST/${PKG}_${VERSION}_${ARCH}.deb"
DEB_NAME="$(basename "$DEB")"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB" >/dev/null

echo "[4/4] 校验"
dpkg-deb -I "$DEB" | grep -E 'Package|Version|Architecture|Depends|Description' | head -6
echo "  体积: $(( $(stat -c%s "$DEB") / 1048576 )) MiB"
dpkg-deb -c "$DEB" | awk 'NR>1{print "    " $6}' | head -8

if [ "$TEST" = 1 ]; then
  echo "=== 在 focal 容器内真实安装验证（离线 dpkg，不碰宿主机）==="
  docker run --rm -v "$SRC":/src -w /src res-downloader:devenv bash -c '
    set -e
    dpkg -i ./dist/'"$DEB_NAME"' 2>&1 | tail -3
    echo "--- 状态:"; dpkg -l res-downloader | tail -1
    echo "--- 可执行与桌面项:"
    ls -1 /usr/local/bin/res-downloader /usr/local/bin/res-downloader.app /usr/share/applications/res-downloader.desktop
    sh -n /usr/local/bin/res-downloader && echo "  wrapper 语法 OK"
    echo "--- 依赖完整性(not found 数，0 最好):"; ldd /usr/local/bin/res-downloader.app | grep -c "not found" || true
    echo "--- md5sums 一致性:"
    ( cd / && md5sum -c --quiet /var/lib/dpkg/info/res-downloader.md5sums && echo "  全部一致" )
    if [ -f /usr/local/share/ca-certificates/res-downloader.crt ]; then
      echo "--- CA 落盘，指纹:"; openssl x509 -in /usr/local/share/ca-certificates/res-downloader.crt -noout -fingerprint -sha256
      cp /usr/local/share/ca-certificates/res-downloader.crt /root/ca-check.crt
      echo "--- 决定性检查：系统 bundle / CApath 是否已信任它"
      openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt /usr/local/share/ca-certificates/res-downloader.crt
      openssl verify -CApath /etc/ssl/certs /usr/local/share/ca-certificates/res-downloader.crt
      echo "--- purge 后应同时撤掉包文件与信任:"
      dpkg --purge res-downloader >/dev/null 2>&1
      test -e /usr/local/share/ca-certificates/res-downloader.crt && echo "  包文件残留!" || echo "  包文件已由 dpkg 回收"
      if openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt /root/ca-check.crt >/dev/null 2>&1; then
        echo "  警告：仍被系统信任，postrm 没起作用"
      else
        echo "  已从系统信任库摘除"
      fi
    else
      echo "--- 本包不含 CA（RESD_WITH_CA=0）：确认系统信任库未被改动"
      test -e /usr/local/share/ca-certificates/res-downloader.crt && echo "  意外存在 CA!" || echo "  未写入 CA，符合预期"
      dpkg --purge res-downloader >/dev/null 2>&1
    fi
    echo "--- 卸载后残留检查:"; dpkg -l res-downloader 2>/dev/null | tail -1; ls /usr/local/bin/ 2>/dev/null | grep res-downloader || echo "  /usr/local/bin 已干净"
  '
fi

echo
echo "产物：$DEB"
echo "目标机安装：sudo dpkg -i $(basename "$DEB") && sudo apt -f install"
