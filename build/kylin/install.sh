#!/usr/bin/env bash
# 免 root 安装到当前用户：可执行文件 + 启动包装 + UKUI 开始菜单项 + 图标
# 用法：./build/kylin/install.sh  （卸载：./build/kylin/install.sh --uninstall）
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_SRC="$SRC/bin/res-downloader-linux-arm64"
PREFIX="${PREFIX:-$HOME/.local}"
APP=res-downloader
# 真实程序放 libexec 位置、并且可执行名必须是 res-downloader：
# GTK 用可执行文件名当 WM_CLASS，之前叫 res-downloader.app 时 WM_CLASS 变成
# "res-downloader.app"，UKUI 面板关联不上桌面项，表现为任务栏认不出这个窗口。
LIBEXEC="$PREFIX/lib/$APP"
DESKTOP="$PREFIX/share/applications/$APP.desktop"
ICON="$PREFIX/share/icons/hicolor/256x256/apps/$APP.png"

if [ "${1:-}" = "--uninstall" ]; then
  # 走回收站而不是直接删除，误操作还能捞回来。
  # 老版本装在 ~/.local/bin/res-downloader.app，一并列出，否则卸载会留个孤儿二进制。
  for f in "$PREFIX/bin/$APP" "$PREFIX/bin/$APP.app" "$LIBEXEC/$APP" "$DESKTOP" "$ICON"; do
    [ -e "$f" ] || continue
    if command -v gio >/dev/null; then gio trash "$f"; else mv -n "$f" "$HOME/.local/share/Trash/files/" 2>/dev/null || echo "跳过 $f（请手动移除）"; fi
    echo "  移除 $f"
  done
  echo "已卸载启动项与程序；配置与证书数据 ~/.config/res-downloader 保留"
  exit 0
fi

[ -x "$BIN_SRC" ] || { echo "找不到产物 $BIN_SRC，请先执行 ./build/kylin/build.sh"; exit 1; }

mkdir -p "$PREFIX/bin" "$LIBEXEC" "$PREFIX/share/applications" "$(dirname "$ICON")"
install -m 755 "$BIN_SRC" "$LIBEXEC/$APP"
install -m 644 "$SRC/build/appicon.png" "$ICON"

# 启动包装：麒麟 UKUI 是 Wayland + XWayland，WebKitGTK 2.38 的合成器模式
# 在该 GPU 路径上会让 WebProcess 直接崩掉（窗口纯白），必须关掉 compositing。
cat > "$PREFIX/bin/$APP" <<EOF
#!/usr/bin/env bash
export GDK_BACKEND=\${GDK_BACKEND:-x11}
export DISPLAY=\${DISPLAY:-:0}
export WEBKIT_DISABLE_COMPOSITING_MODE=\${WEBKIT_DISABLE_COMPOSITING_MODE:-1}
exec "$LIBEXEC/$APP" "\$@"
EOF
chmod 755 "$PREFIX/bin/$APP"

cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=res-downloader
Name[zh_CN]=资源下载器
GenericName=Resource Downloader
Comment=网络资源嗅探与高速下载
Exec=$PREFIX/bin/$APP
Icon=$ICON
Terminal=false
Categories=Utility;FileTransfer;
StartupNotify=false
StartupWMClass=$APP
EOF

command -v update-desktop-database >/dev/null && update-desktop-database "$PREFIX/share/applications" 2>/dev/null || true
command -v gio >/dev/null && gio set "$DESKTOP" "metadata::trusted" yes 2>/dev/null || true

echo "安装完成："
echo "  命令行：$PREFIX/bin/$APP"
echo "  桌面项：$DESKTOP"
echo "  程序本体：$LIBEXEC/$APP"
echo "如果 $PREFIX/bin 不在 PATH 里：export PATH=\$PATH:$PREFIX/bin"
