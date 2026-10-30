#!/usr/bin/env bash
# 把 v4 分支的麒麟原生构建产物打成 .deb（免 root）。
#   ./build/kylin/package-deb.sh                # 产出 dist/*.deb
#   ./build/kylin/package-deb.sh --test-install # 额外在 focal 容器里真装真卸
#
# 与 3.1.3 线打包脚本的两点不同：
#  1) 不在 postinst 里生成/安装 CA —— v4 自己会为本机生成设备 CA，并带管理员授权
#     对话框与旧根清理逻辑；本 fork 只补了「拿不到 root 时走用户级 NSS」的代码路径。
#  2) Depends 不再手写，而是从产物的 objdump NEEDED 推导，防止依赖声明腐烂。
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$SRC/bin/res-downloader-linux-arm64"
PKG="res-downloader"
STAGE="$SRC/build/kylin/.stage"
DIST="$SRC/dist"
TEST=0; [ "${1:-}" = "--test-install" ] && TEST=1
# 真实二进制必须叫 res-downloader 并放在 /usr/lib/res-downloader/ 下：GTK 拿可执行
# 文件名当 WM_CLASS，UKUI 面板靠它与桌面项 StartupWMClass 对应，否则任务栏认不出窗口。
BIN_INSTALL_DIR=/usr/lib/res-downloader

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

[ -x "$BIN" ] || { echo "找不到产物 $BIN，请先执行 ./build/kylin/build.sh"; exit 1; }
command -v dpkg-deb >/dev/null || { echo "本机没有 dpkg-deb"; exit 1; }

# ---------- 版本：优先用 build.sh 写好的 bin/.package-version ----------
if [ -n "${VERSION:-}" ]; then
  PKG_VERSION="$VERSION"
elif [ -s "$SRC/bin/.package-version" ]; then
  PKG_VERSION="$(tr -d '[:space:]' < "$SRC/bin/.package-version")"
else
  APP_VER="$(sed -n 's/.*"productVersion": *"\([^"]*\)".*/\1/p' "$SRC/wails.json" | head -1)"
  PKG_VERSION="${APP_VER}-kylin1"
  if [ -s "$SRC/bin/.buildstamp" ]; then
    PKG_VERSION="${PKG_VERSION}+$(tr -d '[:space:]' < "$SRC/bin/.buildstamp")"
  fi
fi
ARCH="${ARCH:-$(dpkg --print-architecture 2>/dev/null || echo arm64)}"
# 打包者身份从本机 git 配置取，不写死个人信息
MAINTAINER="${MAINTAINER:-$(git config user.name 2>/dev/null)}"
MAINTAINER_EMAIL="${MAINTAINER_EMAIL:-$(git config user.email 2>/dev/null)}"
if [ -z "$MAINTAINER" ] || [ -z "$MAINTAINER_EMAIL" ]; then
  MAINTAINER="res-downloader kylin port"; MAINTAINER_EMAIL="unknown@localhost"
fi

# ---------- 依赖：从产物 NEEDED 推导 ----------
echo "[1/4] 从产物 NEEDED 推导依赖"
NEEDED=$(objdump -p "$BIN" | awk '/NEEDED/{print $2}')
declare -A SONAME2PKG=(
  [libwebkit2gtk-4.0.so.37]="libwebkit2gtk-4.0-37"
  [libjavascriptcoregtk-4.0.so.18]="libjavascriptcoregtk-4.0-18"
  [libgtk-3.so.0]="libgtk-3-0"
  [libgdk-3.so.0]="libgtk-3-0"
  [libgdk_pixbuf-2.0.so.0]="libgdk-pixbuf2.0-0"
  [libglib-2.0.so.0]="libglib2.0-0"
  [libgobject-2.0.so.0]="libglib2.0-0"
  [libgio-2.0.so.0]="libglib2.0-0"
  [libgthread-2.0.so.0]="libglib2.0-0"
  [libgmodule-2.0.so.0]="libglib2.0-0"
  [libc.so.6]="libc6"
  [libm.so.6]="libc6"
  [libdl.so.2]="libc6"
  [libpthread.so.0]="libc6"
  [libresolv.so.2]="libc6"
  [librt.so.1]="libc6"
  [libX11.so.6]="libx11-6"
  [libstdc++.so.6]="libstdc++6"
  [libgcc_s.so.1]="libgcc-s1"
)
# 动态加载器本身也由 libc6 提供，单独列一下避免误报"未映射"
for ld in /lib/ld-linux-aarch64.so.1 /lib/ld-linux.so.2 /lib/ld-linux-armhf.so.3; do
  SONAME2PKG["$(basename "$ld")"]="libc6"
done
DEPENDS=""; UNKNOWN=""
for so in $NEEDED; do
  pkg="${SONAME2PKG[$so]:-}"
  if [ -z "$pkg" ]; then UNKNOWN="$UNKNOWN $so"; continue; fi
  # 用逗号紧邻拼接，去重判断才能命中（带空格会让 ",$pkg," 匹配不上）
  case ",$DEPENDS," in *",$pkg,"*) ;; *) DEPENDS="${DEPENDS:+$DEPENDS,}$pkg" ;; esac
done
[ -z "$UNKNOWN" ] || echo "  ⚠ 未映射的 soname（把包名加进 SONAME2PKG 再打包）:$UNKNOWN"
echo "  NEEDED : $(printf '%s' "$NEEDED" | tr '\n' ' ')"
echo "  Depends: ${DEPENDS//,/ }"
for req in libwebkit2gtk-4.0-37 libgtk-3-0; do
  case ",$DEPENDS," in
    *",$req,"*) ;;
    *) echo "  ⚠ 推导出的依赖里没有 $req，产物链接方式可能变了"; exit 1 ;;
  esac
done

echo "[2/4] 组装 ${PKG} ${PKG_VERSION} (${ARCH}) 目录树"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE$BIN_INSTALL_DIR" "$STAGE/usr/local/bin" \
         "$STAGE/usr/share/applications" "$STAGE/usr/share/icons/hicolor/256x256/apps"
install -m 755 "$BIN" "$STAGE$BIN_INSTALL_DIR/res-downloader"
install -m 644 "$SRC/build/appicon.png" "$STAGE/usr/share/icons/hicolor/256x256/apps/res-downloader.png"
echo "  证书不随包发布，也不由本包写系统信任库（v4 自行生成本机设备 CA）"

# 启动包装：UKUI 是 Wayland + XWayland，WebKitGTK 2.38 的硬件合成路径会让 WebProcess
# 启动即崩；v4 还有 10 秒启动看门狗，缺这个变量时程序会自己退出。
cat > "$STAGE/usr/local/bin/res-downloader" <<EOF
#!/bin/sh
# 除了补环境变量，也保证 WM_CLASS 是 res-downloader（真实程序在 $BIN_INSTALL_DIR/）
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
Version: $PKG_VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Depends: $DEPENDS
Recommends: libnss3-tools, gsettings-desktop-schemas
Maintainer: $MAINTAINER <$MAINTAINER_EMAIL>
Homepage: https://github.com/putyy/res-downloader
Description: 网络资源嗅探与高速下载工具（银河麒麟 V10 SP1 原生适配版）
 res-downloader 是一款集网络资源嗅探与高速下载于一体的桌面工具。
 本包为 v4 线在麒麟 V10 SP1 (arm64) 上的原生构建：用 glibc 2.31 基线容器编译，
 产物门槛 GLIBC_2.17，不依赖 Docker 即可运行；已适配 UKUI 桌面（peony 文件管理器、
 Wayland 合成器兼容模式、任务栏 WM_CLASS 关联），并为拿不到 root 的场景补上
 用户级 NSS 证书信任路径。产品版本号与上游一致，构建标识在包版本后缀里。
EOF

# v4 自己管证书（设备 CA + 管理员授权 + 旧根清理），postinst 不碰系统信任库。
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
command -v update-desktop-database >/dev/null 2>&1 \
  && update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
exit 0
EOF
cat > "$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
command -v update-desktop-database >/dev/null 2>&1 \
  && update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"

echo "[3/4] 生成 md5sums 并打包"
( cd "$STAGE" && find usr -type f ! -path 'usr/lib/*' -exec md5sum {} \; > DEBIAN/md5sums )
mkdir -p "$DIST"
DEB="$DIST/${PKG}_${PKG_VERSION}_${ARCH}.deb"
DEB_NAME="$(basename "$DEB")"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB" >/dev/null

echo "[4/4] 校验"
dpkg-deb -f "$DEB" Package Version Architecture Depends | sed 's/^/  /'
echo "  体积: $(( $(stat -c%s "$DEB") / 1048576 )) MiB"
if dpkg-deb --fsys-tarfile "$DEB" | tar -xO ./usr/local/bin/res-downloader | grep -q WEBKIT_DISABLE_COMPOSITING_MODE; then
  echo "  启动包装含 WebKit 兼容变量 ✓"
else
  echo "  ⚠ 启动包装缺 WebKit 兼容变量"; exit 1
fi
if dpkg-deb --fsys-tarfile "$DEB" | tar -xO ./usr/share/applications/res-downloader.desktop | grep -q "StartupWMClass=res-downloader"; then
  echo "  桌面项 StartupWMClass 与可执行名一致 ✓"
else
  echo "  ⚠ 缺 StartupWMClass"; exit 1
fi

if [ "$TEST" = 1 ]; then
  echo "=== 在 focal 容器内真实安装验证（离线 dpkg，不碰宿主机）==="
  docker run --rm -v "$SRC":/src -w /src res-downloader:devenv-v4 bash -c '
    set -e
    dpkg -i ./dist/'"$DEB_NAME"' 2>&1 | tail -3
    echo "--- 状态:"; dpkg -l res-downloader | tail -1
    echo "--- 落盘:"
    ls -1 /usr/local/bin/res-downloader /usr/lib/res-downloader/res-downloader \
          /usr/share/applications/res-downloader.desktop \
          /usr/share/icons/hicolor/256x256/apps/res-downloader.png | sed "s/^/  /"
    sh -n /usr/local/bin/res-downloader && echo "  wrapper 语法 OK"
    echo "--- 依赖完整性(not found 数，0 最好):"; ldd /usr/lib/res-downloader/res-downloader | grep -c "not found" || true
    echo "--- md5sums:"; ( cd / && md5sum -c --quiet /var/lib/dpkg/info/res-downloader.md5sums && echo "  全部一致" )
    echo "--- 本包不应碰系统信任库（下面应为 0）:"
    ls /usr/local/share/ca-certificates/ 2>/dev/null | grep -c res-downloader || true
    echo "--- purge 后应无残留:"; dpkg --purge res-downloader >/dev/null 2>&1
    ls /usr/local/bin/res-downloader /usr/lib/res-downloader 2>&1 | tail -1 | sed "s/^/  /"
  '
fi

echo
echo "产物：$DEB"
echo "目标机安装：sudo dpkg -i $DEB_NAME"
