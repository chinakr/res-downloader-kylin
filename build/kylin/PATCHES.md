# KYLIN-FORK 改动清单（v4 线）

分支：`kylin-v4`，基线 `upstream/release/v4.0`（head `2d600c5`）。
产品版本与上游一致（`4.0.0`），构建标识为 `-kylin1+build<提交数>-<短哈希>`，经上游自带的
`-X res-downloader/internal/app.ReleaseVersion` 注入，未为此改动任何源码。

## 保留的 fork 改动（上游至今没有）

| # | 文件 | 改动 | 实测证据 |
| --- | --- | --- | --- |
| 1 | `build/linux/dockerfile.focal`、`build/kylin/*` | 用 glibc 2.31 基线（ubuntu:20.04 + Go 1.25.1 + Node 22.14.0）编译，产出可在麒麟 V10 SP1 原生运行的 arm64 二进制；配套免 root 打 deb、容器内真装真卸、端到端验收脚本 | 产物 `objdump -T` 最高 **`GLIBC_2.17`**；`NEEDED` 含 `libwebkit2gtk-4.0.so.37`；本机 `ldd` 0 缺失。对照：官方 3.1.3 的 arm64 二进制在本机执行报 `version 'GLIBC_2.34' not found`（其 `NEEDED` 同样是 webkit2gtk-4.0，只差基线） |
| 2 | `build/kylin/package-deb.sh` 的启动包装 + `docs/{zh,en}/guide/troubleshooting.md` | 通过 `/usr/local/bin/res-downloader` 包装注入 `WEBKIT_DISABLE_COMPOSITING_MODE=1`、`GDK_BACKEND=x11`，并写进文档 | 真机（麒麟 UKUI + XWayland）：不加该变量时 3.1.3 表现为窗口纯白、**v4 表现为 10 秒启动看门狗到点自行退出并弹错误框**；加了之后主窗口 1280x800、截图 147,741 字节、灰度均值 0.65/标准差 0.28（白屏会是 ≈1/0）。容器 A/B 对照中 A 组未每次都复现（无 WM 的容器环境不稳定），故以真机证据为准 |
| 3 | `internal/system/certificate_nss_linux.go`、`internal/system/platform_linux.go` | `installCert` **同时**写系统信任库与当前用户 NSS 库（`certutil` 装 `~/.pki/nssdb`）；拿不到 root 时只写 NSS 并如实回报，不假装成功 | 见下一节缺陷 1：Chromium 系只看 nssdb，只写系统库会让浏览器整机不可用（对照实验 129,382 B → 793,847 B） |
| 4 | `internal/model/utils.go` | `OpenFolder()`（打开文件所在位置）按 `PATH` 探测 `peony/peony-qt/nautilus/thunar/dolphin/pcmanfm/caja/xdg-open`，与同文件 `OpenDirectory` 风格一致；顺带去掉原实现最外层重复 `cmd.Start()` | `go test ./internal/model/` 通过：PATH 里只有 `peony` 替身时调用成功并留下标记；无任何文件管理器时返回明确错误。上游 v4 的 `OpenDirectory` 已把 `xdg-open` 放首位，但 `OpenFolder` 仍只列 nautilus/thunar/dolphin/pcmanfm |
| 5 | `build/kylin/package-deb.sh` 的依赖推导 + 桌面项 | `Depends` 由产物 `objdump -p` 的 `NEEDED` 推导（`SONAME2PKG` 表），不再手写；桌面项写 `StartupWMClass=res-downloader`，真实二进制放 `/usr/lib/res-downloader/res-downloader` | 实测推导出 `libc6, libwebkit2gtk-4.0-37, libgtk-3-0, libgdk-pixbuf2.0-0, libglib2.0-0, libjavascriptcoregtk-4.0-18`；真机 `xprop` 显示 `WM_CLASS = "res-downloader", "Res-downloader"`（此前起名 `res-downloader.app` 时是 `"res-downloader.app"`，UKUI 面板因此认不出窗口） |

## 已经冗余、不再保留的 fork 改动

对照 v4 后确认上游已实现（或实现得更完整），本分支**没有**再带这些：

| 3.1.3 线上的 fork 改动 | v4 里的对应实现 |
| --- | --- |
| 机器专属 CA（`core/certstore.go`） | `internal/system/certificate.go` 的 `InitializeCertificateAuthority` / `generateCertificateAuthority`，生成 `mitm-ca.crt`/`mitm-ca.key`（`CN = res-downloader Device CA`），私钥 `0600`；UI 文案已写明"仅为本设备生成、私钥只保存在本机" |
| 删除上游硬编码的共用根与私钥 | 同上（v4 源码里已搜不到 `BEGIN PRIVATE KEY`）；并用 `legacyCertificateSHA1 = F0A43AE8…70:80`（与 3.1.3 内嵌根的 SHA-1 逐位相同）+ `removeLegacyCertificate` 自动清理旧根 |
| `isInstall()` 真检测 | `CurrentCertificateStatus` / `isCertificateInstalled` / `certificate-migration-v1.json` |
| sudo 密码不再用固定 AES 密钥缓存 | `pass.cache` 已列入遗留文件清理；UI 明确"密码仅用于本次操作，不会保存" |
| 接管系统代理前备份、结束时还原 | #400（We1chan，10-27 合入 v4）：`proxy_state.go` + `proxy_linux.go` + `proxy_state_test.go`，三平台共用保存/归属检查/恢复 |
| deb 里 postinst 生成 CA 并写系统信任库 | 交给 v4 自己的证书流程，本包 postinst 只刷新桌面数据库（实测装包不往 `/usr/local/share/ca-certificates` 写任何东西） |

## 发现的上游 v4 缺陷（已在 fork 内规避）

### 1. 只写系统信任库 → Chromium 系内核整机不可用

`installCert()` 上游只写 `/usr/local/share/ca-certificates` 再 `update-ca-certificates`。
真机实测（麒麟 V10 SP1 + `chromium-browser`）：Chromium **只读 `~/.pki/nssdb`，不读合并
bundle**，开启抓取后浏览器所有 HTTPS 都是 `net::ERR_CERT_AUTHORITY_INVALID`，表现就是
"一开抓取网络断了、什么都抓不到"；curl 读 bundle 所以照常通过 —— 这也是为什么只用 curl
的 e2e 会一路绿灯、把这个 bug 漏掉。

对照实验（同一 app、同一时刻，无头 Chromium 抓 `https://www.baidu.com/` 的 DOM 大小）：

| 条件 | DOM | 结果 |
| --- | --- | --- |
| 走代理，仅系统 bundle 有该根 | 129,382 B | `ERR_CERT_AUTHORITY_INVALID`，"百度" 0 次 |
| 走代理，bundle 与用户 NSS 库都有 | **793,847 B** | 无错误，"百度" 10 次 |
| 不走代理（基线） | 793,884 B | 正常 |

fork 的修法：`installCert()` **同时**写系统信任库与当前用户 NSS 库，四种结果组合分别如实
反馈；拿不到 root 时不假装成功。微信内置浏览器、Edge、360 同内核，同样受益。

### 2. 证书状态检测遇到读不到的投放文件就报错

`internal/system/platform_linux.go` 的 `isCertificateInstalled()` 原先只放过 `os.ErrNotExist`；
而投放文件 `/usr/local/share/ca-certificates/res-downloader.crt` 常见归属是 `root 750/640`，
普通用户读不到，于是每次启动都会在界面上弹
`verify installed certificate: open …: permission denied`。
本机实测该文件为 `-rwxr-x--- root root`、以普通用户 `head -c1` 退出码 1。
fork 的处理：`dropInCertificateMatchesAny()` 同时容忍 `ErrPermission`，并补两条世界可读来源
（合并 bundle 与用户 NSS 库）作为判定依据。这两条都适合单独提 issue/PR。

## 构建产物必须内嵌官方插件（否则视频号不可用）

v4 把微信/视频号解析移出了主仓库：`wails.json` 的 `plugins` 指向
`https://github.com/putyy/resd-plugin-wechat`，`internal/plugin/bundled/` 与 `plugins/`
都被 `.gitignore` 排除，`internal/plugin/bundled.go` 用 `//go:embed bundled` 内嵌，
CI 是先 `download-artifact: bundled-plugins` 再构建。
**没有这一步的自建产物就没有微信插件**，实测症状是"视频号下载不了"，
而且更糟：代理照旧接管微信域名却没有解析能力，用户侧表现为"一开抓取视频号播放不了"。

`build/kylin/build.sh` 已把这一步做成强制门禁（`RESD_PLUGINS=download|local|skip`，
默认 `download` 自动 `git clone` 最新插件源码再 `go run ./cmd/bundleplugins`）：
插件数不足直接失败退出，不再可能产出"没有插件的包"。负测试实测：临时移走
`internal/plugin/bundled/resd-plugin-wechat` 并用 `local` 模式构建 →
`✗ 插件内嵌失败：需要 1 个、实际 0 个，拒绝产出不含插件的包`（退出码 1）。
内嵌成功的判据也验过：新产物 `strings` 命中 `official.wechat`/`resd-plugin-wechat`/
`decrypt.wasm`，而修好前的包这三项都是 0。

插件目录里带自己的 `LICENSE`（Apache-2.0），随 deb 一起分发，无需额外授权动作。
用户也可以在应用「插件管理」里导入 release 的 `plugin.zip`，效果等价，只是不随包分发。

## 复现这些结论

```bash
./build/kylin/build.sh                      # 容器内编译，打印 glibc 门槛与包版本
./build/kylin/package-deb.sh --test-install # focal 容器里 dpkg -i / 校验 / purge
./build/kylin/test-e2e-in-container.sh      # 两组各一个容器：渲染、CA、MITM、卸载
docker run --rm -v $PWD:/src -w /src res-downloader:devenv-v4 go test ./internal/system/ ./internal/model/
```

## 跟进上游

`git fetch upstream --tags && git rebase upstream/release/v4.0`，然后重跑上面四条验证。
上游 4.0 正式版发布后，本清单里"保留的 fork 改动"应缩减为 #1、#2、#3、#5（若届时上游
仍未处理对应问题），#4 视 `OpenFolder` 是否已扩展探测而定。
