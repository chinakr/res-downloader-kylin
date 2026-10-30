# 在别的电脑上安装使用（银河麒麟 / Ubuntu arm64）

## 前提

* CPU 架构 **arm64**；系统是 glibc ≥ 2.17 的 deb 系：麒麟 V10 / V10 SP1、UOS 桌面、Ubuntu 18.04 及以后。
* 已装 `libwebkit2gtk-4.0-37` 与 `libgtk-3-0`——UKUI/桌面版默认自带，装包时不联网也一般不缺。
* 若目标机只有 `webkit2gtk-4.1`（Debian 12+、Ubuntu 23.10+），本包依赖不满足，需要另做一版。

## 安装

```
sudo dpkg -i res-downloader_3.1.3-kylin3_arm64.deb
```

装完做完了三件事：给这台机器生成一把专属根证书（`/etc/res-downloader/ca.crt`，私钥 600
+ 只授权给安装用户读取）、把它导入系统信任库、在开始菜单里加一个「资源下载器」启动项。
**不需要再去界面里点「安装证书」输密码。** 命令行启动是 `/usr/local/bin/res-downloader`。

## 首次使用

1. 打开程序。系统设置里「安装证书」应显示已安装；若显示未安装（例如没用 deb 装、
   或不是安装用户登录），点一次并输入登录密码；没有 root 权限时会退到只影响当前用户的
   NSS 库，Chromium 系浏览器照样能解密。
2. 打开「自动设置系统代理」。程序会先记下你原来的代理设置，关闭抓取时还原，
   不会把公司代理清成"无"。
3. 点「开启抓取」→ 回到浏览器刷新或播放目标页面 → 列表里出现资源 → 下载。

**第一次装完请重启一次浏览器**：信任链有缓存，不重启可能仍提示证书不安全。

## 装完先验证这两条

```
/usr/lib/res-downloader/res-downloader -ca-status
curl -s -o /dev/null -x http://127.0.0.1:8899 -w '%{http_code} %{ssl_verify_result}\n' https://example.com/
```

前者应输出 `已被系统信任: true` 并列出命中位置；后者应是 `200 0`。

## 区分不同的构建

产品版本号固定跟随上游（如 3.1.3），不加后缀；区分靠独立的构建标记，三处可见：

* deb 文件名：`res-downloader_3.1.3-kylin3+build90-1a2b3c4_arm64.deb`
* 程序里：左下角「关于」面板 `Version 3.1.3` 下一行，以及启动日志里的 `build:` 行
* `res-downloader -ca-status` 的 `构建:` 字段

标记格式是 `build<提交数>-<git 短哈希>`，工作区有未提交改动时追加 `-dirty`，
由构建脚本自动生成，不需要手工维护。
如果 `-ca-status` 打印了"上游共用根仍在信任链中"，说明这台机器装过老版本，
用 `build/kylin/migrate-off-shared-ca.sh` 体检并按它打印的命令清理。

## 各浏览器的差别

* **Chromium / Chrome / Edge / 360 等**：跟随系统信任库或当前用户 `~/.pki/nssdb`，装完即用。
* **Firefox**：只认自己那份证书库，需要手动导入——设置 → 隐私与安全 → 证书 → 查看证书 →
  权威 → 导入，文件选 `~/.config/res-downloader/cert.crt`，勾上「信任此 CA 标识的网站」。
* **手机 / 平板**：让设备代理指向这台机器的 8899，再把证书下载到设备上导入。
  注意每台机器的证书都不一样，换一台电脑就要重新导一次。

## 常见问题

* **8899 被占用**：在系统设置里改 `Port`。改完要重启程序（监听端口是启动时绑定的），
  再关一次、开一次「自动设置系统代理」，桌面代理才会指向新端口。
* **窗口一片空白**：说明没通过启动包装运行（裸跑二进制时缺 `WEBKIT_DISABLE_COMPOSITING_MODE=1`，
  UKUI 的 Wayland + XWayland 上 WebProcess 会启动即崩）。用 `/usr/local/bin/res-downloader` 或菜单项启动。
* **同一台机器多个用户**：只有安装用户被授权读私钥。别的用户启动时会自己生成一把
  用户级证书，需要在界面里点一次「安装证书」；想让他们共用整机那把，让管理员执行
  `sudo setfacl -m u:用户名:r-- /etc/res-downloader/ca.key`。
* **从旧版 kylin1 升级**：直接 `sudo dpkg -i` 新版即可——postinst 会用本机证书覆盖
  同一个投放路径并整体重建信任 bundle。
* **命令行找不到程序**：确认 `/usr/local/bin` 在 PATH 里。

## 卸载

```
sudo dpkg --purge res-downloader
```

会删掉本机根证书并把它从系统信任库里摘除。用户数据留在 `~/.config/res-downloader`
（含 `ca.key` 私钥、缓存过的密码、日志），公用机器请务必自行清掉这个目录。

## 任务栏上的图标

安装后任务栏应直接出现「资源下载器」的运行按钮，右键是它自己的窗口菜单。
这里依赖一个约定：真实程序必须叫 `res-downloader` 并放在 `/usr/lib/res-downloader/` 下，
桌面项里 `StartupWMClass=res-downloader` 与之一致——GTK 拿可执行文件名当 `WM_CLASS`，
UKUI 面板靠它把窗口和已安装应用对应起来。自行改动安装路径时请让这两个名字保持一致，
否则运行中的窗口不会被认出来，看起来就像"非得固定在任务栏上才有图标"。
