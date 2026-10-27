#!/usr/bin/env bash
# 把麒麟原生构建产物打成 .deb，供其他银河麒麟 V10 SP1 / Ubuntu 20.04 (arm64) 机器安装。
#   ./build/kylin/package-deb.sh                # 产出 dist/*.deb
#   ./build/kylin/package-deb.sh --test-install # 额外在 focal 容器里真装一遍，验 postinst/purge
# 全程不需要 root：dpkg-deb 用 --root-owner-group 把包内属主统一写成 root。
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$SRC/bin/res-downloader-linux-arm64"
PKG="res-downloader"
# deb 修订号默认 = 上游版本 + kylin3 + 构建标记（bin/.buildstamp，build.sh 写入），
# 如 3.1.3-kylin3+build8-4d86a1b；显式传 VERSION 时完全覆盖。
APP_VER="$(sed -n 's/.*"productVersion": *"\([^"]*\)".*/\1/p' "$SRC/wails.json" | head -1)"
DEF_REV="${APP_VER}-kylin3"
BUILD_STAMP_FILE="$SRC/bin/.buildstamp"
if [ -f "$BUILD_STAMP_FILE" ]; then
  DEF_REV="${DEF_REV}+$(head -c64 "$BUILD_STAMP_FILE" | tr -d '[:space:]')"
fi
VERSION="${VERSION:-$DEF_REV}"
ARCH="${ARCH:-$(dpkg --print-architecture 2>/dev/null || echo arm64)}"
STAGE="$SRC/build/kylin/.stage"
DIST="$SRC/dist"
TEST=0; [ "${1:-}" = "--test-install" ] && TEST=1
# 真实二进制放在 /usr/lib/res-downloader/ 下：GTK 的 WM_CLASS 取自可执行文件名，
# 早先起名 res-downloader.app 会让 WM_CLASS 变成 "res-downloader.app"，
# UKUI 面板按 WM_CLASS 关联 .desktop，对不上就认不出这是已安装应用的窗口。
BIN_INSTALL_DIR=/usr/lib/res-downloader

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

[ -n "$VERSION" ] || { echo "取不到版本号，检查 wails.json 的 productVersion"; exit 1; }
[ -x "$BIN" ] || { echo "找不到产物 $BIN，请先执行 ./build/kylin/build.sh"; exit 1; }
command -v dpkg-deb >/dev/null || { echo "本机没有 dpkg-deb"; exit 1; }

echo "[1/4] 组装 ${PKG} ${VERSION} (${ARCH}) 目录树"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE$BIN_INSTALL_DIR" "$STAGE/usr/local/bin" \
         "$STAGE/usr/share/applications" "$STAGE/usr/share/icons/hicolor/256x256/apps"

install -m 755 "$BIN" "$STAGE$BIN_INSTALL_DIR/res-downloader"
install -m 644 "$SRC/build/appicon.png" "$STAGE/usr/share/icons/hicolor/256x256/apps/res-downloader.png"

# 机器专属 CA 由 postinst 以 root 现场生成：包里不放任何证书内容，
# 也不放符号链接（实测 update-ca-certificates 对符号链接只建 /etc/ssl/certs 下的
# CApath 软链，不会并进 curl/Go/Node 实际读取的合并 bundle，必须真实文件）。
echo "  证书不随包发布，由 postinst 生成这台机器专属的一把"

# 启动包装：UKUI 是 Wayland 会话 + XWayland，WebKitGTK 2.38 的硬件合成路径
# 会让 WebProcess 启动即崩（表现是窗口存在但纯白），必须固定这两个变量。
cat > "$STAGE/usr/local/bin/res-downloader" <<EOF
#!/bin/sh
# 启动包装：除了补环境变量，也保证 WM_CLASS 是 res-downloader
# （GTK 取可执行文件名当类名，真实程序在 $BIN_INSTALL_DIR/res-downloader）
export GDK_BACKEND="\${GDK_BACKEND:-x11}"
export WEBKIT_DISABLE_COMPOSITING_MODE="\${WEBKIT_DISABLE_COMPOSITING_MODE:-1}"
exec $BIN_INSTALL_DIR/res-downloader "\$@"
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
Icon=res-downloader
Terminal=false
Categories=Utility;FileTransfer;
StartupNotify=false
StartupWMClass=res-downloader
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
 不依赖 Docker 即可运行；MITM 根证书改为安装时在本机生成（私钥不落盘到包与仓库），
 不再沿用上游硬编码在源码里、全球共用且私钥公开的那一把；已适配 peony 文件管理器、
 接管系统代理时备份并还原原设置，并附带 UKUI 开始菜单项。
EOF

# 机器专属 CA 在这里现生成：dpkg 执行 postinst 时已是 root，装完即被系统信任，
# 用户不用再去界面里点「安装证书」输密码；私钥只落本机，不进仓库也不进 .deb。
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
CA_DIR=/etc/res-downloader
CERT=$CA_DIR/ca.crt
KEY=$CA_DIR/ca.key
TRUST=/usr/local/share/ca-certificates/res-downloader.crt
APP=/usr/lib/res-downloader/res-downloader

# 已存在就不重新生成：升级/重装保持同一把根，
# 否则用户之前导进手机、别的设备的证书会一夜失效。
if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
  mkdir -p "$CA_DIR"
  # 用 app 自带的 -init-ca 生成，而不是 openssl req -x509：
  # 发行版默认配置会把 basicConstraints 与 -addext 各写一遍，
  # 重复的 critical 扩展让证书链校验必然失败（实测踩过）。
  if "$APP" -init-ca "$CA_DIR" >/var/log/res-downloader-ca.log 2>&1; then
    chmod 755 "$CA_DIR"; chmod 644 "$CERT"; chmod 600 "$KEY"
    echo "已为本机生成专属根证书：$CERT"
  else
    rm -f "$CERT" "$KEY"
    echo "warning: 生成本机 CA 失败，首次启动时 app 会在 ~/.config 自建；详见 /var/log/res-downloader-ca.log" >&2
    exit 0
  fi
fi

# 让桌面用户能读私钥（app 以普通用户运行需要签叶子证书）。
# 用 POSIX ACL 而不是加用户组：不改组成员，也就不需要用户注销重登。
OWNER="${SUDO_USER:-}"
[ -z "$OWNER" ] && OWNER="$(stat -c '%U' /dev/console 2>/dev/null || true)"
if [ -n "$OWNER" ] && [ "$OWNER" != "root" ]; then
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -m "u:$OWNER:r--" "$KEY" 2>/dev/null || true
  else
    chgrp "$OWNER" "$KEY" 2>/dev/null && chmod 640 "$KEY" || true
  fi
fi

# 把公钥拷进信任投放目录（真实文件，不能是符号链接，见上面注释）
mkdir -p /usr/local/share/ca-certificates
cp -f "$CERT" "$TRUST"
chmod 644 "$TRUST"

if command -v update-ca-certificates >/dev/null 2>&1; then
  # 用 --fresh 整体重建：从旧版升上来时，这个投放路径的内容会从
  # 上游共用根换成本机新根，普通刷新不一定会把旧的那条从 bundle 里摘掉。
  update-ca-certificates --fresh >/var/log/res-downloader-ca.log 2>&1 \
    || echo "warning: 导入系统信任库失败，见 /var/log/res-downloader-ca.log" >&2
else
  echo "warning: 系统无 update-ca-certificates，请手动导入 $CERT" >&2
fi

command -v update-desktop-database >/dev/null 2>&1 \
  && update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
exit 0
EOF

# remove/purge 后重建 bundle，把这把根从系统信任里摘掉；
# purge 时连本机私钥一起清掉（明确路径，不用通配符）。
cat > "$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
case "${1:-}" in
  remove|purge)
    # 投放的证书是 postinst 生成的真实文件，不由 dpkg 拥有，得自己收尾
    rm -f /usr/local/share/ca-certificates/res-downloader.crt
    if [ "$1" = "purge" ]; then
      rm -f /etc/res-downloader/ca.crt /etc/res-downloader/ca.key
      rmdir /etc/res-downloader 2>/dev/null || true
      rm -f /var/log/res-downloader-ca.log
    fi
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
( cd "$STAGE" && find usr -type f -exec md5sum {} \; > DEBIAN/md5sums )

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
    ls -1 /usr/local/bin/res-downloader /usr/lib/res-downloader/res-downloader /usr/share/applications/res-downloader.desktop
    sh -n /usr/local/bin/res-downloader && echo "  wrapper 语法 OK"
    grep -q "StartupWMClass=res-downloader" /usr/share/applications/res-downloader.desktop \
      && echo "  StartupWMClass 已对齐(可执行名 res-downloader → WM_CLASS 一致)" || echo "  警告：StartupWMClass 缺失"
    echo "--- 依赖完整性(not found 数，0 最好):"; ldd /usr/lib/res-downloader/res-downloader | grep -c "not found" || true
    echo "--- md5sums 一致性:"
    ( cd / && md5sum -c --quiet /var/lib/dpkg/info/res-downloader.md5sums && echo "  全部一致" )
    echo "--- 机器专属 CA 是否已在安装时生成:"
    FP1=$(openssl x509 -in /etc/res-downloader/ca.crt -noout -fingerprint -sha256 | cut -d= -f2)
    openssl x509 -in /etc/res-downloader/ca.crt -noout -subject -enddate
    echo "--- 私钥权限(应 600):"; stat -c "  %a %U:%G %n" /etc/res-downloader/ca.crt /etc/res-downloader/ca.key
    echo "--- 投放到信任目录的证书(应为真实文件,644):"; ls -l /usr/local/share/ca-certificates/res-downloader.crt
    echo "--- 决定性检查：系统 bundle 是否信任这把新根"
    openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt /etc/res-downloader/ca.crt
    echo "--- 用它能签出可校验的叶子证书吗(等价于 MITM 中间人):"
    cp /etc/res-downloader/ca.crt /tmp/tca.crt; cp /etc/res-downloader/ca.key /tmp/tca.key
    openssl req -new -newkey rsa:2048 -nodes -keyout /tmp/leaf.key -out /tmp/leaf.csr -subj "/CN=example.com" >/dev/null 2>&1
    printf "basicConstraints=CA:FALSE\nsubjectAltName=DNS:example.com\n" >/tmp/leaf.ext
    openssl x509 -req -in /tmp/leaf.csr -CA /tmp/tca.crt -CAkey /tmp/tca.key \
      -CAcreateserial -days 30 -sha256 -extfile /tmp/leaf.ext -out /tmp/leaf.crt >/dev/null 2>&1
    openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt /tmp/leaf.crt && echo "  叶子证书链校验通过"
    echo "--- 升级幂等：重装一次，指纹不应变化(否则用户已导入的设备全部作废)"
    dpkg -i ./dist/'"$DEB_NAME"' >/dev/null 2>&1
    FP2=$(openssl x509 -in /etc/res-downloader/ca.crt -noout -fingerprint -sha256 | cut -d= -f2)
    [ "$FP1" = "$FP2" ] && echo "  仍是同一把根，符合预期" || echo "  警告：CA 被重新生成了"
    echo "--- purge 后证书与信任都应消失:"
    dpkg --purge res-downloader >/dev/null 2>&1
    ls /etc/res-downloader 2>&1 | tail -1
    if openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt /tmp/leaf.crt >/dev/null 2>&1; then
      echo "  警告：仍被系统信任"
    else
      echo "  已从系统信任库摘除"
    fi
    echo "--- 卸载残留:"; dpkg -l res-downloader 2>/dev/null | tail -1
    ls /usr/local/bin/ /usr/lib/res-downloader/ 2>/dev/null | grep res-downloader || echo "  安装路径已干净"
  '
fi

echo
echo "产物：$DEB"
echo "目标机安装：sudo dpkg -i $(basename "$DEB") && sudo apt -f install"
