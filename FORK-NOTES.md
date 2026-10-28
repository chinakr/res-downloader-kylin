# 关于本仓库（非官方适配分支）

本仓库是 **[putyy/res-downloader](https://github.com/putyy/res-downloader)** 的 fork，
为 **银河麒麟桌面 V10 SP1（Kylin V10 SP1，arm64/aarch64）** 做的原生运行适配与安全性改造。
上游作者并未审阅、认可或背书本分支的任何改动。

* 上游项目：https://github.com/putyy/res-downloader
* 上游许可证：Apache License 2.0（`LICENSE` 原样保留，未修改）
* 本分支基线：上游 `master` 分支 `3.1.3`，产品版本号保持与上游一致，不另起版本号；
  区分具体构建靠独立的构建标记 `build<提交数>-<短哈希>`（见下文"如何确认自己装的是哪次构建"）

## 为什么要 fork

1. **官方 Linux arm64 产物在本机跑不起来。** 上游 CI 使用 Debian 12 基底的
   `golang:*-bookworm`（glibc 2.36）链接，产物要求 `GLIBC_2.34`；麒麟 V10 SP1 的
   底座是 Ubuntu 20.04（glibc 2.31），直接执行报 `GLIBC_2.34 not found`。
2. **上游把 MITM 根证书连同私钥硬编码在源码里**（`core/app.go`，`CN=gowas.cn`，自签，
   全球所有安装共用一把）。私钥随公开仓库分发，意味着任何读过该仓库的人都能对
   信任了这把根的设备做中间人。
3. 若干处桌面集成在麒麟上不工作（文件管理器、系统代理、启动项、Wayland 渲染）。

## 本分支改了什么（Apache-2.0 §4(b) 要求的变更说明）

| 文件 | 变更 | 原因 |
| --- | --- | --- |
| `core/certstore.go` | 新增。机器专属根证书的加载/生成、按指纹比对系统信任库与 NSS 用户库、`GenerateCAAt()` | 替换源码里硬编码的共用根 |
| `core/app.go` | 删除硬编码的 `PublicCrt` 与 `PrivateKey` 字面量；`isInstall()` 改为真检测；新增 `BuildStamp` / `App.Build` | 不再内置公开私钥的根；`install.lock` 判定在换成本机证书后会变成假信号 |
| `core/system.go` | `initCert()` 内容与当前证书不一致时重写；`pass.cache` 的 AES 密钥由源码内固定值改为本机随机密钥 | 避免升级后把上一世代的旧根再拷进信任库；固定密钥公开在仓库里，缓存的 sudo 密码等于明文 |
| `core/system_linux.go` | 接管桌面代理前备份并还原 `org.gnome.system.proxy` 原设置；新增用户级 NSS 信任库安装（免 root）；修正 NSS 检测方式 | 上游 `unsetProxy` 会把用户原有代理写死成 `none`；麒麟上 `update-ca-certificates` 需要 root |
| `core/shared/utils.go` | `OpenFolder` 的 Linux 分支按 `PATH` 探测 `peony/peony-qt/nautilus/thunar/dolphin/pcmanfm/caja/xdg-open` | 麒麟 UKUI 桌面只有 `peony`，上游只探测后四个，"打开目录"必失败 |
| `core/system_other.go` | 新增。非 Linux 平台保留上游原有语义 | 跨平台编译不回归 |
| `main.go` | 新增两个不弹窗的 CLI 入口：`-init-ca <目录>`（供 deb 的 postinst 调用）、`-ca-status`（证书状态自查） | 让安装脚本和用户都不必依赖 GUI 检查证书 |
| `frontend/src/components/Footer.vue`、`frontend/src/types/app.d.ts` | 在 `Version` 下方显示构建标记 | 便于确认现场装的是哪次构建 |
| `build/kylin/*` | 全部新增：构建环境镜像、构建脚本、免 root 的用户级安装、deb 打包、容器内端到端测试、旧共用根迁移检查脚本、部署说明 | 见 `build/kylin/README.md` |
| `build/linux/Debian/DEBIAN/.control` 等上游打包模板 | 未修改（本分支的打包走 `build/kylin/package-deb.sh`） | — |

**上游代码的其余部分保持原样。** 本分支只做适配与安全改造，没有新增功能。

## 安全性说明（用之前请读）

* 本工具的工作原理是本地 HTTPS 中间人（MITM）代理：它必须让系统或浏览器信任一把根证书，
  才能解密并抓取 HTTPS 资源。这类能力天然高风险，请只在**你自己拥有和有权测试的设备**上使用。
* 本分支已改为**每台机器生成自己的一把根证书**，私钥不进入仓库、不进入 `.deb`、
  权限 `0600` 并通过 POSIX ACL 仅授权给安装用户。卸载（`dpkg --purge`）会把这把根
  从系统信任库中撤除。
* 从旧版本（含上游版本）升级过来的机器上，那把全球共用的旧根**不会自动消失**，
  需要手工清理：`build/kylin/migrate-off-shared-ca.sh`。
* 本分支的 deb 在安装阶段会以 root 写入系统信任库。若你要把软件分发给**不可控的对象**，
  请只发源码，让对方自行构建并自行决定是否信任。
* **不要**把本仓库的构建产物称为上游的官方发布物。

## 授权与商用限制

* 代码许可遵循上游的 Apache License 2.0，`LICENSE` 文件未改动，本分支的修改部分同样以该许可证提供。
* 上游 `README.md` 中额外声明：「本软件仅供学习与研究用途，禁止用于任何商业或违法用途。」
  该声明与本分支一并适用。**如需商用，请先向上游作者取得书面授权**，本分支不授予任何超出上游许可的权利。
* 上游 `README.md` 的免责声明原文保留，未做修改。

## 构建与部署

* 构建环境、踩坑记录与验证结果：`build/kylin/README.md`
* 目标机安装使用：`build/kylin/DEPLOY.md`

## 如何确认自己装的是哪次构建

产品版本号与上游保持一致（当前 `3.1.3`），区分构建靠独立的标记，三处可见：

```
deb 文件名            res-downloader_3.1.3-kylin3+build90-4722bb9_arm64.deb
程序内「关于」面板     Version 3.1.3 / build90-4722bb9
命令行                res-downloader -ca-status   →  构建: build90-4722bb9
```

标记格式为 `build<提交数>-<git 短哈希>`，工作区有未提交改动时追加 `-dirty`。

## 与上游的关系维护

本分支不自动跟进上游更新。同步上游的做法：把上游加为 `upstream` remote，
`git fetch upstream && git rebase upstream/master`（本地提交数很少，rebase 冲突面小），
然后在容器里重跑 `build/kylin/build.sh` 与 `build/kylin/package-deb.sh --test-install` 验证。
