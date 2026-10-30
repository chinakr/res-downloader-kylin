# 银河麒麟 V10 SP1 (arm64) 原生构建与打包（v4 线）

本分支基线 `upstream/release/v4.0`（head `2d600c5`）。fork 的具体改动与取舍见
**[PATCHES.md](PATCHES.md)**，目标机使用见 **[DEPLOY.md](DEPLOY.md)**；
3.1.3 线的完整记录在 `master` 分支的同名文件里。

## 为什么要自己编

上游 CI 用 `golang:1.25-bookworm`（glibc 2.36）链接，产物要求 `GLIBC_2.34`。
本机是银河麒麟 V10 SP1（底座 Ubuntu 20.04，glibc 2.31），官方 3.1.3 的 arm64 二进制
实测直接报：

```text
/lib/aarch64-linux-gnu/libc.so.6: version `GLIBC_2.34' not found (required by /usr/local/bin/res-downloader)
```

cgo 程序的 glibc 门槛由**构建机的 libc** 决定，与 Go 版本无关。所以在
`ubuntu:20.04`（glibc 2.31，且其 `libwebkit2gtk-4.0-dev` 恰好是 2.38.6，与麒麟已装
运行时同版本）的容器里编译，产物门槛降到 `GLIBC_2.17`，宿主机原生运行、运行期不需要
Docker，也不需要给宿主机装任何 `-dev` 包（本机 sudo 要交互密码）。

## 命令

```bash
./build/kylin/build.sh                    # 镜像 + 前端 + Go；打印包版本与 glibc 门槛
./build/kylin/build.sh --skip-fe          # 只改 Go 时跳过 vite
./build/kylin/build.sh --shell            # 进容器调试
./build/kylin/install.sh                  # 免 root 的用户级安装（含 UKUI 菜单项）
./build/kylin/install.sh --uninstall
./build/kylin/package-deb.sh --test-install   # 打 deb 并在 focal 容器里真装真卸
./build/kylin/test-e2e-in-container.sh        # 两组各一个容器：渲染 / CA / MITM / 卸载
```

镜像叫 `res-downloader:devenv-v4`（Go 1.25.1 + Node 22.14.0，v4 的 `go.mod` 要 go 1.25、
前端 Vite 8 要 Node ≥ 22.12）。产物 `bin/res-downloader-linux-arm64` 约 24 MiB。

## 版本与构建标识

上游 `productVersion`（v4 是 `4.0.0`）保持不动，构建标识为
`4.0.0-kylin1+build<提交数>-<短哈希>[-dirty]`，通过 v4 自带的
`-X res-downloader/internal/app.ReleaseVersion=...` 注入（上游用它保留 prerelease 标识，
见 `internal/app/app.go:23`），所以不必为版本号改任何源码。同一字符串用作 deb 版本，
在「关于」面板、启动日志、`/api/app-info` 三处可见。构建标记在**宿主机**上算：
worktree 的 `.git` 是指回主仓库的文件，容器里看不见。

## 构建踩到的坑（都已固化进脚本）

1. **必须带 `-tags desktop,production`**，否则 `go build` 成功但产物是空壳，运行时只打印
   `Wails applications will not build without the correct build tags`；判据是
   `objdump -p | grep NEEDED` 里没有 `libwebkit2gtk-4.0.so.37`。
2. **`-ldflags` 里别丢掉 `-s -w`**，只写 `-X` 会产出带调试信息的 20+ MiB 二进制。
3. **`-buildvcs=false`**：挂载进来的 `.git` 属主与容器内 root 不一致时 git 拒绝读仓库。
4. **模块缓存卷要挂在 `$GOMODCACHE` 实际指向的路径**（镜像里是 `/root/go/pkg/mod`），
   挂错地方等于每次重下依赖。
5. **容器 root 产出的文件要 chown 回宿主机 uid**（`trap EXIT` 里做，失败也要做）。
6. 前端 `npm run build` 在 v4 里是 `vue-tsc -b && vite build`，类型检查会挡构建；
   脚本调的是 `npm run build`（不跳过检查），改动 Go 时才用 `--skip-fe` 复用已有 dist。

## 打包要点

- 全程不需要 root：`dpkg-deb --build --root-owner-group`。
- 真实二进制放 `/usr/lib/res-downloader/res-downloader`，`/usr/local/bin/res-downloader`
  是注入 `WEBKIT_DISABLE_COMPOSITING_MODE=1` / `GDK_BACKEND=x11` 的启动包装。
  可执行文件名不能加后缀：GTK 拿它当 `WM_CLASS`，UKUI 面板靠 `WM_CLASS` 与桌面项的
  `StartupWMClass` 对应，对不上就认不出运行中的窗口（表现为"非得固定到任务栏"）。
- `Depends` 由产物 `objdump -p` 的 `NEEDED` 经 `SONAME2PKG` 表推导，不手写；出现未映射
  的 soname 会显式告警，避免依赖声明悄悄腐烂。
- **本包不碰系统信任库**：v4 自己生成本机设备 CA（`~/.config/res-downloader/mitm-ca.*`）
  并带管理员授权对话框与旧根清理，postinst 只刷新桌面数据库。实测装包后
  `/usr/local/share/ca-certificates` 里没有 res-downloader.crt。

## 已完成的验证（v4 线）

| 项目 | 结果 |
| --- | --- |
| glibc 门槛 | 产物最高 `GLIBC_2.17`；对照：官方 3.1.3 arm64 产物在本机报 `GLIBC_2.34 not found` |
| 动态依赖 | 本机 `ldd` 0 缺失；`NEEDED` 含 `libwebkit2gtk-4.0.so.37` |
| 前端与类型检查 | Vite 8 + `vue-tsc -b` 在 Node 22.14 下通过 |
| 原生运行（真机 UKUI/XWayland） | 主窗口 1280x800，截图 147,741 字节，灰度均值 0.65/标准差 0.28（非白屏），界面逐项可辨；`WM_CLASS = "res-downloader"` |
| 缺 WebKit 兼容变量时 | 真机 v4 表现为 10 秒启动看门狗到点自行退出并弹错误框（3.1.3 是窗口纯白） |
| MITM | 经代理取本地 HTTP `200 900000B`；HTTPS 走 CONNECT + 用 v4 自生成设备 CA 校验 → `200 ssl_verify=0` |
| Go 单元测试 | `go test ./internal/system/ ./internal/model/` 通过（NSS 导入幂等/误判防护、bundle 指纹比对、投放文件读不到不报错、peony 探测） |
| deb 安装/卸载 | 容器内 `dpkg -i` 成功、`md5sums` 一致、`ldd` 0 缺失、不写系统信任库、`--purge` 无残留 |
| 隐私 | `publish-fork.sh` 预检口径（运行时取本机用户名/主机名）命中 0；无 `dist/`、`bin/`、私钥入库 |
