# 在别的电脑上安装使用（银河麒麟 / Ubuntu arm64，v4 线）

## 前提

* CPU 架构 **arm64**；系统是 glibc ≥ 2.17 的 deb 系：麒麟 V10 / V10 SP1、UOS 桌面、Ubuntu 18.04 及以后。
* 已装 `libwebkit2gtk-4.0-37` 与 `libgtk-3-0`——UKUI/桌面版默认自带。
* 若目标机只有 `webkit2gtk-4.1`（Debian 12+、Ubuntu 23.10+），本包依赖不满足，需要另做一版。
* 建议装 `libnss3-tools`（提供 `certutil`）：拿不到管理员密码时靠它把证书信任到当前用户。

## 安装

```
sudo dpkg -i res-downloader_4.0.0-kylin1+build<…>_arm64.deb
```

包做的事：把真实二进制装到 `/usr/lib/res-downloader/res-downloader`，在
`/usr/local/bin/res-downloader` 放一个注入 WebKit 兼容环境变量的启动包装，加一个
UKUI 开始菜单项（`StartupWMClass` 已对齐）。**包不写系统信任库、不含任何证书**——
证书由 v4 自己在首次需要时为本机生成，并在界面里请你授权。

**微信/视频号插件已内嵌在包里**（来自 `putyy/resd-plugin-wechat`，Apache-2.0，
含其 `LICENSE`、`main.js`、`plugin.json`、`decrypt.wasm`），装完不需要再去「插件管理」
手工导入。构建脚本对这一步做了强制门禁：拉不到插件就直接失败，不会产出一个
"能装但视频号抓不到"的包。

## 首次使用

1. 从菜单或 `/usr/local/bin/res-downloader` 启动（**不要**直接跑
   `/usr/lib/res-downloader/res-downloader`，那样没有环境变量，UKUI 的 Wayland 会话下
   会因为启动看门狗超时自行退出）。
2. 界面提示「安装抓取证书」时二选一：
   * 输入本机登录密码 → 证书写入系统信任库（curl/Go/Node 与多数浏览器都认）；
   * 不想给密码就点「暂不安装」，再用命令行把证书信任到当前用户（只需 `libnss3-tools`）：
     ```
     certutil -N -d sql:$HOME/.pki/nssdb --empty-password
     certutil -A -d sql:$HOME/.pki/nssdb -t "C,," -n res-downloader-device-ca \
       -i ~/.config/res-downloader/mitm-ca.crt
     ```
     这样 Chromium、Chrome、Edge 系即可解密 HTTPS；Firefox 与命令行工具不覆盖。
3. 打开「自动设置系统代理」→ 点「开启抓取」→ 回浏览器刷新目标页面 → 列表出资源 → 下载。

**换过证书后重启浏览器**，信任链有缓存。

## 装完先验证

```
curl -s -m 8 http://127.0.0.1:8899/api/app-info | grep -o '"Version":"[^"]*"'
curl -s -o /dev/null -m 25 -x http://127.0.0.1:8899 \
  --cacert ~/.config/res-downloader/mitm-ca.crt \
  -w '%{http_code} ssl_verify=%{ssl_verify_result}\n' https://example.com/
```

第二条应输出 `200 0`（`0` 表示证书链校验通过）。若用了系统信任库，可去掉 `--cacert` 再试一次，
结果仍应是 `200 0`。

## 区分不同的构建

上游产品版本号保持原样（v4 线是 `4.0.0`），区分构建靠包版本后缀
`-kylin1+build<提交数>-<git 短哈希>[-dirty]`，三处可见：deb 文件名、「关于」面板的版本行、
启动日志与 `/api/app-info` 的 `Version` 字段。工作区有未提交改动时会带 `-dirty`。

## 各浏览器的差别

* **Chromium / Chrome / Edge / 360 等**：读系统信任库或当前用户 `~/.pki/nssdb`。
* **Firefox**：两处都不读，必须手动导入——设置 → 隐私与安全 → 证书 → 查看证书 → 权威 →
  导入，文件选 `~/.config/res-downloader/mitm-ca.crt`，勾「信任此 CA 标识的网站」。
* **手机 / 平板**：设备代理指向这台机器的 8899，再把上面那个证书文件导入设备。
  每台机器的证书不同，换机器要重新导一次。

## 常见问题

* **启动后弹一个小错误框然后退出**：多半是绕过了启动包装。用 `/usr/local/bin/res-downloader`
  或菜单项启动；手工启动时先 `export WEBKIT_DISABLE_COMPOSITING_MODE=1 GDK_BACKEND=x11`。
* **界面弹 `verify installed certificate: … permission denied`**：`/usr/local/share/ca-certificates/res-downloader.crt`
  归属通常是 `root 750/640`，普通用户读不到。本分支已修（检测时容忍读不到的投放文件，
  并改从合并 bundle 与 NSS 库判定）；官方版本仍会出现这个提示。
* **8899 被占用**：在系统设置里改端口，改完重启程序，再开关一次自动代理。
* **从 3.1.3 版（含上游官方版本）升上来**：老的那把全球共用根不会自动消失，
  用 `./build/kylin/migrate-off-shared-ca.sh` 体检，它会列出 bundle、投放目录、NSS 库里的
  具体位置，并把需要 root 的命令打印出来给你执行（`--apply` 可免 root 清掉用户 NSS 库那条）。
* **同一台机器多个用户**：每个用户自己的 `~/.config/res-downloader/mitm-ca.*` 各自一把，
  互不影响；谁要用浏览器抓包，谁就要为自己的用户做一次信任（界面输密码或上面的 certutil）。

## 卸载

```
sudo dpkg --purge res-downloader
```

删掉程序、菜单项与图标。**证书不在包的管辖之内**：请在应用内撤销，或手工清理
`~/.config/res-downloader/`（含设备 CA 私钥 `mitm-ca.key`）与系统信任库中的投放文件：

```
sudo rm -f /usr/local/share/ca-certificates/res-downloader.crt && sudo update-ca-certificates --fresh
```

公用机器务必清掉 `~/.config/res-downloader`，否则私钥留在机上。

## 任务栏上的图标

安装后任务栏应直接出现「资源下载器」的运行按钮。这里依赖一个约定：真实程序必须叫
`res-downloader` 并放在 `/usr/lib/res-downloader/` 下，桌面项 `StartupWMClass` 与之一致——
GTK 拿可执行文件名当 `WM_CLASS`，UKUI 面板靠它把窗口和已安装应用对应起来。自行改动安装
路径时请保持这两个名字一致，否则运行中的窗口不会被认出来，看起来就像"非得固定在任务栏上
才有图标"。
