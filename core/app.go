package core

import (
	"context"
	"embed"
	"fmt"
	"github.com/vrischmann/userdir"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"res-downloader/core/shared"
	"strconv"
	"time"
)

type App struct {
	ctx         context.Context
	assets      embed.FS
	AppName     string `json:"AppName"`
	Version     string `json:"Version"`
	Build       string `json:"Build"`
	Description string `json:"Description"`
	Copyright   string `json:"Copyright"`
	UserDir     string `json:"-"`
	LockFile    string `json:"-"`
	PublicCrt   []byte `json:"-"`
	PrivateKey  []byte `json:"-"`
	IsProxy     bool   `json:"IsProxy"`
	IsReset     bool   `json:"-"`
}

var (
	appOnce        *App
	globalConfig   *Config
	globalLogger   *Logger
	resourceOnce   *Resource
	systemOnce     *SystemSetup
	proxyOnce      *Proxy
	httpServerOnce *HttpServer
	ruleOnce       *RuleSet
)

// BuildStamp 构建标记，由 build/kylin/build.sh 通过 -ldflags -X 注入，
// 形如 build7-4d86a1b（提交数-短哈希，工作区有未提交改动时追加 -dirty）。
// 产品版本号保持上游的 3.1.3 不动，用它区分同一版本下的不同构建。
var BuildStamp string

func GetApp(assets embed.FS, wjs string) *App {
	if appOnce == nil {
		matches := regexp.MustCompile(`"productVersion":\s*"([\d.]+)"`).FindStringSubmatch(wjs)
		version := "1.0.1"
		if len(matches) > 0 {
			version = matches[1]
		}

		appOnce = &App{
			assets:      assets,
			AppName:     "res-downloader",
			Version:     version,
			Build:       BuildStamp,
			Description: "res-downloader是一款集网络资源嗅探 + 高速下载功能于一体的软件，高颜值、高性能和多样化，提供个人用户下载自己上传到各大平台的网络资源功能！",
			Copyright:   "Copyright © 2023~" + strconv.Itoa(time.Now().Year()),
			IsReset:     false,
			// PublicCrt / PrivateKey 在这里不再放常量：
			// 上游把 MITM 根证书连同私钥硬编码在本文件里（全球共用一把），
			// 现在改由 LoadMachineCA() 加载或生成"每台机器一把"的证书，见 core/certstore.go。
		}
		appOnce.UserDir = filepath.Join(userdir.GetConfigHome(), appOnce.AppName)
		err := os.MkdirAll(appOnce.UserDir, 0750)
		if err != nil {
			fmt.Println("Mkdir UserDir err: ", err.Error())
		}
		appOnce.LockFile = filepath.Join(appOnce.UserDir, "install.lock")
		if err := LoadMachineCA(); err != nil {
			fmt.Println("Load CA err: ", err.Error())
		}
		initLogger()
		initConfig()
		initProxy()
		initResource()
		initHttpServer()
		initSystem()
		initRule()
	}
	return appOnce
}

func (a *App) Startup(ctx context.Context) {
	a.ctx = ctx
	fmt.Println("[ca] 当前根证书来源:", CAScopeLabel())
	warnLegacySharedCA()
	go httpServerOnce.run()
}

func (a *App) OnExit() {
	a.UnsetSystemProxy()
	globalLogger.Close()
	if appOnce.IsReset {
		err := a.ResetApp()
		fmt.Println("err:", err)
	}
}

func (a *App) installCert() (string, error) {
	out, err := systemOnce.installCert()
	if err != nil {
		globalLogger.Esg(err, out)
		return out, err
	} else {
		if err := a.lock(); err != nil {
			globalLogger.Err(err)
		}
	}
	return out, nil
}

func (a *App) OpenSystemProxy() error {
	if a.IsProxy {
		return nil
	}
	err := systemOnce.setProxy()
	if err == nil {
		a.IsProxy = true
		return nil
	}
	return err
}

func (a *App) UnsetSystemProxy() error {
	if !a.IsProxy {
		return nil
	}
	err := systemOnce.unsetProxy()
	if err == nil {
		a.IsProxy = false
		return nil
	}
	return err
}

// isInstall 回答的是"当前这把机器专属 CA 到底有没有被系统信任"。
// 上游只看 install.lock 存不存在，换成每台机器一把证书后这就是假信号：
// 装过旧版本、信任库被清过、或用户导入了别的证书，都会表现为
// "界面显示已安装，但 HTTPS 一条都抓不到"。
func (a *App) isInstall() bool {
	trusted, where := systemOnce.isCertTrusted()
	if trusted {
		if !shared.FileExist(a.LockFile) {
			_ = a.lock()
		}
		fmt.Println("[ca] 根证书已被系统信任:", where)

		return true
	}
	return false
}

func (a *App) lock() error {
	info := "success"
	if fp, err := CAFingerprint(); err == nil {
		info = fmt.Sprintf("installed %s scope=%s sha256=%s", time.Now().Format(time.RFC3339), CAScopeLabel(), fp)
	}
	err := os.WriteFile(a.LockFile, []byte(info), 0644)
	if err != nil {
		return err
	}
	return nil
}

func (a *App) ResetApp() error {
	exePath, err := os.Executable()
	if err != nil {
		return err
	}

	exePath, err = filepath.Abs(exePath)
	if err != nil {
		return err
	}

	_ = os.Remove(filepath.Join(appOnce.UserDir, "install.lock"))
	_ = os.Remove(filepath.Join(appOnce.UserDir, "pass.cache"))
	_ = os.Remove(filepath.Join(appOnce.UserDir, "config.json"))
	_ = os.Remove(filepath.Join(appOnce.UserDir, "cert.crt"))

	cmd := exec.Command(exePath)
	cmd.Start()
	return nil
}
