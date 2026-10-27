# 银河麒麟 V10 SP1 (arm64) 原生运行改造说明

## 问题

上游 `res-downloader` 发布的 Linux arm64 二进制是在 Ubuntu 22.04（glibc 2.35）工具链上
链接出来的，符号表要求 `GLIBC_2.34`。本机是 **银河麒麟桌面 V10 SP1**，底座 Ubuntu 20.04、
**glibc 2.31**，所以官方包直接跑会报 `GLIBC_2.34 not found`，之前只能整个塞进 Docker 里运行。

## 方案

不改运行环境、改构建环境：在 **glibc 2.31 基线的容器（ubuntu:20.04）里编译**，用宿主机的
gcc/链接器同代的 `crt1.o` 和 libc 做 CGO 链接，产物 glibc 门槛降到 **GLIBC_2.17**，
放回麒麟上即可 **原生运行，运行期完全不依赖 Docker**。

选 focal 还有个巧合的好处：它的 `libwebkit2gtk-4.0-dev` 是 **2.38.6**，与麒麟仓库里已装的
运行时 `libwebkit2gtk-4.0-37: 2.38.6-0kylin...` 完全同版本，链接期与运行期 ABI 严丝合缝，
不需要在宿主机装任何 `-dev` 包（也就绕开了本机 sudo 需要交互密码的限制）。

```
./build/kylin/build.sh            # 首次会构建 devenv 镜像，然后前端 + Go 全量构建
./build/kylin/build.sh --skip-fe  # 只改 Go 代码时，跳过 vite 构建
./build/kylin/build.sh --shell    # 进容器调试
./build/kylin/install.sh          # 免 root 装到 ~/.local（含 UKUI 开始菜单项）
./build/kylin/install.sh --uninstall
```

产物：`bin/res-downloader-linux-arm64`（约 16 MiB，已 strip）。

## 构建踩到的坑（都已固化进 `build/kylin/build.sh`）

1. **必须带 `-tags desktop,production`**。Wails v2 的桌面前端代码由构建标签控制，官方
   `wails build` 会自动注入；直接 `go build` 出来的产物是个只会打印
   `Wails applications will not build without the correct build tags` 的空壳，且 `NEEDED`
   里完全没有 `libwebkit2gtk-4.0.so.37`——这是最容易骗过自己的地方：编译成功、体积正常、
   运行只是退出码为 0 的一行错误。
2. **`-buildvcs=false`**。仓库挂载进容器后属主是宿主机 uid，容器内 root 的 git 会以
   "dubious ownership" 拒绝读仓库，Go 报 `error obtaining VCS status: exit status 128`。
3. **容器内 root 会留下 root 属主的产物**，脚本用 `trap EXIT` 无条件 chown 回宿主机用户，
   否则下一次构建会因为权限失败。
4. 前端 `npm run build` 里的 `vue-tsc --noEmit` 对上游 TS 版本很敏感，脚本直接调
   `npx vite build` 跳过类型检查，不影响产物。

## 源码改动

| 文件 | 改动 | 原因 |
| --- | --- | --- |
| `core/shared/utils.go` | `OpenFolder` 的 linux 分支改成按 `PATH` 依次探测 `peony/peony-qt/nautilus/thunar/dolphin/pcmanfm/caja/xdg-open` | 上游只探测后四个，麒麟 UKUI 桌面只有 **peony**，界面上"打开目录/打开保存位置"必失败 |
| `core/system_linux.go` | 接管桌面代理前把 `org.gnome.system.proxy` 的 mode 与 http/https host:port 备份到 `~/.config/res-downloader/gnome_proxy.backup.json`（0600），取消接管时还原；无备份时才退回原来的写死 `none` | 上游 `unsetProxy` 无条件把 mode 置 `none`，会永久抹掉用户原本配的公司代理 |
| `core/system_linux.go` | 新增 `installUserTrust()`，把根证书装进用户级 NSS 库 `~/.pki/nssdb`；系统库需要 root 时，用户库成功即视为安装成功 | 麒麟上 `update-ca-certificates` 要 root，而 Chromium/Chrome、curl(NSS)、Node 都读用户级 NSS，免密即可完成 HTTPS 解密 |
| `build/kylin/*` | 新增构建环境镜像、构建脚本、启动包装、免 root 安装脚本 | 见上 |

## 运行期注意（原生跑相对 Docker 跑的差别）

* **必须 `WEBKIT_DISABLE_COMPOSITING_MODE=1`**。UKUI 是 Wayland 会话 + XWayland，WebKitGTK
  2.38 的硬件合成路径会让 `WebKitWebProcess` 起来就崩，表现是窗口 1280x800 存在、
  截图纯白。启动包装 `install.sh` 生成的 `~/.local/bin/res-downloader` 已内置该变量，
  另外固定 `GDK_BACKEND=x11`。实测不需要 `LIBGL_ALWAYS_SOFTWARE` /
  `WEBKIT_DISABLE_DMABUF_RENDERER`。
* "自动设置系统代理"在原生环境是真生效的（容器里改不动宿主的 gsettings）。抓取结束后
  会还原原始设置，不会再把代理清成 `none`。
* Firefox 用自己的证书库，仍需在 `设置 → 隐私 → 证书 → 导入` 手动导入
  `~/.config/res-downloader/cert.crt`；Chromium 系内核浏览器读 NSS 用户库，装完即用。
* 旧的 `res-downloader:kd` 镜像（Docker 运行版）已经不需要了，数据目录两者共用
  `~/.config/res-downloader`。

## 打成 deb 安装包

```
./build/kylin/package-deb.sh                  # → dist/res-downloader_<版本>_arm64.deb
./build/kylin/package-deb.sh --test-install   # 顺手在 focal 容器里 dpkg -i/purge 真跑一遍
RESD_WITH_CA=0 ./build/kylin/package-deb.sh   # 出"不内置根证书"的保守变体
VERSION=3.1.3-kylin2 ./build/kylin/package-deb.sh
```

全程不需要 root：`dpkg-deb --build --root-owner-group` 会把包内属主统一记成 root。
包内容 = `/usr/local/bin/res-downloader.app`（二进制）+ 同名启动包装（内置 WebKit 必需环境变量）
+ UKUI 桌面项 + 图标 + `/usr/local/share/ca-certificates/res-downloader.crt`；
`postinst` 只跑 `update-ca-certificates`，证书文件本身归 dpkg 管，purge 时自动回收，
`postrm` 再 `--fresh` 重建系统 bundle。依赖声明 `libwebkit2gtk-4.0-37, libgtk-3-0`，
Recommends `libnss3-tools`（用户级 NSS 兜底要用）与 `gsettings-desktop-schemas`（接管桌面代理要用）。

随包 CA 是在打包时**从 `core/app.go` 现场抽取**的（`PublicCrt` 字段），不在仓库里另存副本，
避免和二进制里编译进去的那把对不上——对不上就会出现"证书装了但浏览器不认"的诡异现象。

目标机安装：`sudo dpkg -i dist/res-downloader_3.1.3-kylin1_arm64.deb && sudo apt -f install`。
适用面：glibc ≥ 2.17 且带 webkit2gtk-4.0 的 deb 系 arm64 系统（麒麟 V10/SP1、UOS、
Ubuntu 18.04 及以后）。目标机若只有 `webkit2gtk-4.1`（如 Debian 12+/Ubuntu 23.10+），
需要把依赖和编译容器换成 4.1，或改用 AppImage。

### ⚠️ 关于这把 CA 的安全事实

上游把 MITM 用的根证书**和它的私钥**一起硬编码在 `core/app.go` 里（`PublicCrt` + `PrivateKey`，
`CN=gowas.cn`，自签，有效期到 2124 年），全球所有 res-downloader 装的都是同一把。
也就是说：任何读过这个公开仓库的人都能拿到私钥，任何信任了这把根的系统/浏览器都可能被其
中间人。装 deb 时把 CA 写进系统信任库，等于把这份信任授予了全网共用的根。

这是上游的设计，不是本仓库引入的，但打包分发前你需要知道边界在哪：

* `RESD_WITH_CA=1`（默认）：装完即可抓 HTTPS，体验最顺，适合内网/自己人用的机器。
* `RESD_WITH_CA=0`：安装不动信任库，需要抓包时由用户在界面里点「安装证书」
  （我们已给它加了免 root 的用户级 NSS 兜底），适合发给不可控的对象。

更彻底的做法是**每台机器一把自己的 CA**：首次启动检测 `~/.config/res-downloader/` 下没有
CA 就用本机密钥对现生成一份，`postinst` 改成交互式/延迟导入。这需要改动 `core/app.go`
与 `core/proxy.go` 的取证书路径，属于独立的一档改造，尚未做。

## 已完成的验证

| 项目 | 结果 |
| --- | --- |
| glibc 门槛 | 产物最高只引用 `GLIBC_2.17`（宿主要求 ≤ 2.31） |
| 动态依赖 | `ldd` 在麒麟上 0 个 `not found`，`NEEDED` 含 `libwebkit2gtk-4.0.so.37` 等 |
| 窗口渲染 | 主界面（开启抓取 / 列表 / 侧边菜单 / 底部链接）完整渲染，非白屏 |
| MITM 解密 | 经 `127.0.0.1:8899` 代理取 HTTPS 资源返回 200，明文响应可解 |
| 系统代理 | `/api/proxy-open` → mode=`manual` port=8899 且生成备份；`/api/proxy-unset` → 还原为原 `none` 并删除备份 |
| 打开目录 | `/api/open-folder` 成功拉起 peony |
| deb 安装（容器内 dpkg -i） | 依赖解析通过、`postinst` 后 `openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt` 返回 OK、md5sums 全一致 |
| deb 卸载（容器内 dpkg --purge） | 包文件由 dpkg 回收，`postrm` 重建 bundle 后该 CA 不再被信任 |
| 包内二进制 | 与 `bin/res-downloader-linux-arm64` sha256 逐字节一致，`ldd` 无缺失 |
