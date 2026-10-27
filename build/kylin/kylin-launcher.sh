#!/usr/bin/env bash
# res-downloader 银河麒麟 V10 SP1 启动包装
# 背景：麒麟 UKUI 桌面跑在 Wayland + XWayland 上，且板载 GPU 的 EGL/DMABUF 路径
# 与 WebKitGTK 2.38 的合成器模式不兼容，直接启动会出现
# "WebProcess 起来又立刻挂掉 / 窗口纯白" 的现象。
export GDK_BACKEND=${GDK_BACKEND:-x11}
export DISPLAY=${DISPLAY:-:0}
export WEBKIT_DISABLE_COMPOSITING_MODE=${WEBKIT_DISABLE_COMPOSITING_MODE:-1}
BIN="${RES_DOWNLOADER_BIN:-/home/yewei/workspace/res-downloader/bin/res-downloader-linux-arm64}"
exec "$BIN" "$@"
