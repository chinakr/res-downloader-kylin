# KYLIN-FORK 改动清单（v4 线）

分支：`kylin-v4`，基线 `upstream/release/v4.0`（head `2d600c5`）。
产品版本与上游一致（`4.0.0`），构建标识为 `-kylin1+build<提交数>-<短哈希>`，经上游自带的
`-X res-downloader/internal/app.ReleaseVersion` 注入，未为此改动任何源码。

## 保留的 fork 改动（上游至今没有）

| # | 文件 | 改动 | 实测证据 |
| --- | --- | --- | --- |
| 1 | `build/linux/dockerfile.focal`、`build/kylin/*` | 用 glibc 2.31 基线（ubuntu:20.04 + Go 1.25.1 + Node 22.14.0）编译，产出可在麒麟 V10 SP1 原生运行的 arm64 二进制；配套免 root 打 deb、容器内真装真卸、端到端验收脚本 | 产物 `objdump -T` 最高 **`GLIBC_2.17`**；`NEEDED` 含 `libwebkit2gtk-4.0.so.37`；本机 `ldd` 0 缺失。对照：官方 3.1.3 的 arm64 二进制在本机执行报 `version 'GLIBC_2.34' not found`（其 `NEEDED` 同样是 webkit2gtk-4.0，只差基线） |
| 2 | `build/kylin/package-deb.sh` 的启动包装 + `docs/{zh,en}/guide/troubleshooting.md` | 通过 `/usr/local/bin/res-downloader` 包装注入 `WEBKIT_DISABLE_COMPOSITING_MODE=1`、`GDK_BACKEND=x11`，并写进文档 | 真机（麒麟 UKUI + XWayland）：不加该变量时 3.1.3 表现为窗口纯白、**v4 表现为 10 秒启动看门狗到点自行退出并弹错误框**；加了之后主窗口 1280x800、截图 147,741 字节、灰度均值 0.65/标准差 0.28（白屏会是 ≈1/0）。容器 A/B 对照中 A 组未每次都复现（无 WM 的容器环境不稳定），故以真机证据为准 |
| 3 | `internal/system/certificate_nss_linux.go`、`internal/system/platform_linux.go` | 新增免 root 的用户级 NSS 信任路径（`certutil` 装入 `~/.pki/nssdb`），`installCert()` 在系统信任库需要管理员授权时自动降级并如实回报；同时让证书状态检查容忍读不到的投放文件 | `go test ./internal/system/` 通过（含"库不存在时自动建目录"“重复安装幂等”“无关证书不误判”三个用例）。真机验证：`MITM + 设备 CA 校验 example.com → HTTP 200 ssl_verify=0` |
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

`internal/system/platform_linux.go` 的 `isCertificateInstalled()` 原先只放过 `os.ErrNotExist`；
而投放文件 `/usr/local/share/ca-certificates/res-downloader.crt` 常见归属是 `root 750/640`，
普通用户读不到，于是每次启动都会在界面上弹
`verify installed certificate: open …: permission denied`。
本机实测该文件为 `-rwxr-x--- root root`、以普通用户 `head -c1` 退出码 1。
fork 的处理：`dropInCertificateMatchesAny()` 同时容忍 `ErrPermission`，并补两条世界可读来源
（合并 bundle 与用户 NSS 库）作为判定依据。这一条适合单独提 issue/PR。

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
