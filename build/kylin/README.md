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
| `build/kylin/*` | 新增构建环境镜像、构建脚本、启动包装、免 root 安装、打包与 e2e 脚本；deb 里可执行改放 `/usr/lib/res-downloader/res-downloader` 并给桌面项加 `StartupWMClass` | 可执行文件名会被 GTK 当作 `WM_CLASS`，原名 `res-downloader.app` 让 UKUI 面板认不出窗口（表现为任务栏要点固定才有图标） |
| `core/certstore.go`（新增） | 机器专属 CA 的加载/生成、指纹比对式信任检测、`-init-ca`/`-ca-status` 支撑 | 见「CA 已改为每台机器一把」 |
| `core/app.go` | 删掉硬编码的共用根证书与私钥；`isInstall()` 改为真检测；`lock()` 记录 scope+指纹 | 共用根的私钥是公开的；旧 `isInstall` 只看 lock 文件 |
| `core/system.go` | `initCert()` 内容与当前 CA 不一致时重写；`pass.cache` 改用本机随机密钥 | 否则升级后会把上一世代的旧根再拷进信任库；固定 AES 密钥写在源码里等于明文缓存 |
| `main.go` / `core/app.go` | 两个不弹窗 CLI 入口 `-init-ca <目录>` / `-ca-status`；新增 `core.BuildStamp`（ldflags 注入）与 `App.Build` 字段，启动日志、/api/app-info、关于面板均显示 | 构建标记 = `build<提交数>-<短哈希>[-dirty]`，产品版本号保持上游 3.1.3 不动，用独立字段区分同一版本下的不同构建 |

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
./build/kylin/package-deb.sh --test-install   # 在 focal 容器里 dpkg -i / 重装 / purge 真跑一遍
./build/kylin/test-e2e-in-container.sh        # 装包 + Xvfb 起真界面 + 只靠系统信任链抓 HTTPS
VERSION=3.1.3-kylin3 ./build/kylin/package-deb.sh
```

全程不需要 root：`dpkg-deb --build --root-owner-group` 把包内属主统一记成 root。
包里是 `/usr/lib/res-downloader/res-downloader`（二进制）+ `/usr/local/bin/res-downloader`
启动包装（内置 WebKit 必需环境变量）+ UKUI 桌面项（带 `StartupWMClass=res-downloader`）+ 图标；
**证书内容不在包里**。可执行文件名不能加 `.app` 之类的后缀：GTK 拿它当 `WM_CLASS`，
UKUI 面板靠 `WM_CLASS` 与桌面项对应，对不上就认不出运行中的窗口（表现为"非得固定到任务栏"）。
依赖 `libwebkit2gtk-4.0-37, libgtk-3-0`，Recommends `libnss3-tools`（NSS 兜底）、
`gsettings-desktop-schemas`（接管桌面代理）。

目标机安装：`sudo dpkg -i dist/res-downloader_3.1.3-kylin3_arm64.deb`。
适用面：glibc ≥ 2.17 且带 webkit2gtk-4.0 的 deb 系 arm64（麒麟 V10/SP1、UOS、Ubuntu 18.04+）。
只有 `webkit2gtk-4.1` 的系统（Debian 12+/Ubuntu 23.10+）需要换依赖与编译容器重做一版。

## CA 已改为「每台机器一把」（方案 B）

上游把 MITM 根证书**连同私钥**硬编码在 `core/app.go`（`CN=gowas.cn`，自签到 2124 年），
全球共用一把——任何读过公开仓库的人都能对信任它的设备做中间人。本 fork 已改掉：

* `core/certstore.go`：加载顺序 `/etc/res-downloader/ca.{crt,key}` → `~/.config/res-downloader/ca.{crt,key}`
  → 都没有就在用户目录现生成（RSA-2048，`CA:TRUE`+`keyCertSign`，100 年，私钥 0600）。
  `appOnce.PublicCrt/PrivateKey` 由它注入，所以 `proxy.go` 的签发、`/api/cert` 的证书下载、
  界面安装流程全部自动跟随，不需要各自改。
* `main.go` 增加两个不弹窗的 CLI 入口：`res-downloader -init-ca <目录>`（postinst 用）、
  `-ca-status`（自查：证书在哪、系统信不信、有没有残留旧根）。
* `postinst` 以 root 调 `-init-ca /etc/res-downloader` 生成并投放到
  `/usr/local/share/ca-certificates/res-downloader.crt`，再用 `update-ca-certificates --fresh`
  重建 bundle，所以**装完包就能抓 HTTPS，不需要再去界面点「安装证书」输密码**。
  私钥 `600 root:root` + POSIX ACL 授权给安装用户（`setfacl -m u:$SUDO_USER:r--`）：
  不改组成员、不需要注销重登；没有 `setfacl` 时降级成 `chgrp + 640`。
  升级/重装时已存在的 CA 不会被重新生成，否则用户先前导进手机/其他设备的证书会一夜失效。
* `isInstall()` 不再只看 `install.lock`：改为拿当前证书指纹去系统 bundle、
  `/etc/ssl/certs/` 单文件、`~/.pki/nssdb` 里比对，真信了才算已安装。
  这条是本方案的硬要求——共用 CA 时代"文件在≈以前装过"侥幸成立，换成本机证书后它就是假信号。
* 拿不到 root（不是安装用户、或没给密码）时，界面「安装证书」会退到用户级 NSS 兜底，
  只是需要用户点一次。
* `~/.config/res-downloader/install.lock` 现在写入 `scope` 与证书指纹，便于排查装歪了的情况。
* 顺带修掉：`pass.cache` 里 sudo 密码的加密密钥由「硬编码在源码里的全局固定值」
  改成本机随机（`~/.config/res-downloader/.secret`，0600）。**旧缓存会解不开**，
  表现为需要重输一次密码，这是有意为之。

### 这一版踩到的三个坑（都写进了代码注释）

1. **别用 `openssl req -x509 -addext` 生成 CA**：发行版默认配置的 `v3_ca` 已经带
   `basicConstraints`，`-addext` 会再加一遍，重复的 critical 扩展让证书链校验一律失败
   （`openssl verify` 只报 `unable to get local issuer certificate`，很难联想到扩展重复）。
   现在改成让 app 自己的 Go 代码生成，扩展形状只有一份定义。
2. **`/usr/local/share/ca-certificates/` 里放符号链接没用**：`update-ca-certificates`
   只会为它建 `/etc/ssl/certs/<hash>.0` 的 CApath 链接，不会并进合并 bundle，
   而 curl/Go/Node 读的是 bundle。必须是真实文件。
3. **`certutil -L -a` 必须带 nickname**，否则报 `nickname is required to dump cert`，
   读不到任何 PEM；NSS 检测只能先列条目再逐个导出比指纹。
   另外 `certutil -N` 要求目标目录已存在，只建 `~/.pki` 不够（本机旧库早就在，掩盖过这个 bug）。

### 从旧版迁移

`./build/kylin/migrate-off-shared-ca.sh`（体检，只读）／`--apply`（额外清掉用户 NSS 库里的旧根，免 root）。
它会指出旧共用根在 bundle、投放目录、NSS 库里的具体位置，并把需要 root 的命令打印出来让你自己执行。
在这台麒麟上，**装上新版 deb 本身就是迁移**：postinst 会用本机 CA 覆盖同一个投放路径并 `--fresh` 重建。
手机/其他设备上手工导入过旧证书的，要各自删一次，然后重启浏览器（NSS 会缓存信任链）。

## 已完成的验证

| 项目 | 结果 |
| --- | --- |
| glibc 门槛 | 产物最高只引用 `GLIBC_2.17`（宿主要求 ≤ 2.31） |
| 动态依赖 | `ldd` 在麒麟上 0 个 `not found`，`NEEDED` 含 `libwebkit2gtk-4.0.so.37` 等 |
| 窗口渲染 | 主界面（开启抓取 / 列表 / 侧边菜单 / 底部链接）完整渲染，非白屏 |
| MITM 解密 | 经 `127.0.0.1:8899` 代理取 HTTPS 资源返回 200，明文响应可解 |
| 系统代理 | `/api/proxy-open` → mode=`manual` port=8899 且生成备份；`/api/proxy-unset` → 还原为原 `none` 并删除备份 |
| 打开目录 | `/api/open-folder` 成功拉起 peony |
| deb 安装（容器内 dpkg -i） | 依赖解析通过、postinst 生成的机器 CA 被 `openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt` 认可、md5sums 全一致 |
| deb 升级幂等 | 连续 `dpkg -i` 两次，机器 CA 指纹不变（不会作废用户已导入的设备证书） |
| deb 卸载（容器内 dpkg --purge） | `/etc/res-downloader` 与投放文件清空，重建 bundle 后该 CA 不再被信任 |
| 权限边界 | 私钥 `600 root:root` + ACL `user:<安装用户>:r--`；安装用户可读、同机其他用户读不到（容器内双用户实测） |
| 容器内 e2e（`test-e2e-in-container.sh`） | 普通用户起真 GUI（Xvfb）→ 日志 `来源: 系统级 /etc/res-downloader` → 不指定 `--cacert` 纯靠系统信任链抓 example.com 与 baidu 均 `HTTP 200 ssl_verify=0` |
| 无 root 时的兜底路径 | 用户级 CA 自建（私钥 0600）→ 界面点安装走 NSS 成功 → 重启进程后 `-ca-status` 仍识别为已信任 |
| 任务栏关联 | 容器内实测窗口 `WM_CLASS="res-downloader"` 与桌面项 `StartupWMClass` 一致（改名前是 `res-downloader.app`，面板认不出） |
| 旧共用根 | 二进制与源码里均已无该证书/私钥片段（`strings` 逐条比对为 0 命中） |
| 包内二进制 | 与 `bin/res-downloader-linux-arm64` sha256 逐字节一致，`ldd` 无缺失 |
