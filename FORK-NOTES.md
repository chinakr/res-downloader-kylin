# 关于本仓库（非官方适配分支）

上游项目：**[putyy/res-downloader](https://github.com/putyy/res-downloader)**（Apache-2.0）。
本分支是为 **银河麒麟桌面 V10 SP1（arm64）** 做的原生运行适配，上游作者未审阅或背书本分支。

* 分支：`kylin-v4`，基线 `upstream/release/v4.0`（head `2d600c5`）
* 逐文件改动清单、实测证据与"哪些改动因上游已实现而不再保留"：[build/kylin/PATCHES.md](build/kylin/PATCHES.md)
* 目标机安装使用：[build/kylin/DEPLOY.md](build/kylin/DEPLOY.md)
* 构建链与踩坑记录：[build/kylin/README.md](build/kylin/README.md)
* 3.1.3 线（含机器专属 CA 的过渡实现）：本仓库 `master` 分支

## 授权与限制

* 代码遵循上游 Apache License 2.0，`LICENSE` 原样保留、未修改；本分支的改动同样以该许可证提供。
* 上游 README 声明「本软件仅供学习与研究用途，禁止用于任何商业或违法用途」，本分支一并适用；
  如需商用请先向上游作者取得书面授权。上游免责声明原文未改动。

## 与上游的关系

产品身份（deb 包名、可执行名 `res-downloader`、`AppName`、`~/.config/res-downloader`、
`StartupWMClass`）与上游保持一致，fork 标识只体现在目录名、仓库名与包版本后缀
（`4.0.0-kylin1+build<提交数>-<短哈希>`）。跟进上游：
`git fetch upstream --tags && git rebase upstream/release/v4.0`，然后按
`build/kylin/README.md` 里的四条验证重跑一遍。
