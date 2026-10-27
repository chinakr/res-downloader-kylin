package main

import (
	"context"
	"embed"
	"fmt"
	"github.com/wailsapp/wails/v2/pkg/menu"
	"github.com/wailsapp/wails/v2/pkg/options/linux"
	"github.com/wailsapp/wails/v2/pkg/options/mac"
	"github.com/wailsapp/wails/v2/pkg/options/windows"
	"log"
	"os"
	"res-downloader/core"
	"runtime"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
)

//go:embed all:frontend/dist
var assets embed.FS

//go:embed build/appicon.png
var icon []byte

//go:embed wails.json
var wailsJson string

func main() {
	// 纯 CLI 入口：deb 的 postinst 以 root 调 `-init-ca <目录>` 生成本机专属根证书，
	// 必须在任何 GUI/窗口初始化之前返回。
	if len(os.Args) > 2 && os.Args[1] == "-init-ca" {
		certPath, keyPath, err := core.GenerateCAAt(os.Args[2])
		if err != nil {
			fmt.Fprintln(os.Stderr, "init-ca failed:", err.Error())
			os.Exit(1)
		}
		fmt.Println("generated:", certPath, keyPath)
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "-ca-status" {
		// 只查询不弹窗：证书落在哪、系统信不信、有没有残留的旧共用根
		core.GetApp(assets, wailsJson)
		fmt.Print(core.CAStatus())
		return
	}

	// Create an instance of the app structure
	app := core.GetApp(assets, wailsJson)
	bind := core.NewBind()
	isMac := runtime.GOOS == "darwin"
	// menu
	appMenu := menu.NewMenu()
	if isMac {
		appMenu.Append(menu.AppMenu())
		appMenu.Append(menu.EditMenu())
		appMenu.Append(menu.WindowMenu())
	}

	// Create application with options
	err := wails.Run(&options.App{
		Title:                    app.AppName,
		Width:                    1280,
		MinWidth:                 960,
		Height:                   800,
		MinHeight:                600,
		Frameless:                !isMac,
		Menu:                     appMenu,
		EnableDefaultContextMenu: true,
		AssetServer: &assetserver.Options{
			Assets:     assets,
			Middleware: core.Middleware,
		},
		BackgroundColour: &options.RGBA{R: 27, G: 38, B: 54, A: 1},
		OnStartup: func(ctx context.Context) {
			logo := `
	 _ __    ___   ___            __| |   ___   __      __  _ __   | |   ___     __ _     __| |   ___   _ __
	| '__|  / _ \ / __|  _____   / _· |  / _ \  \ \ /\ / / | '_ \  | |  / _ \   / _· |   / _· |  / _ \ | ·__|
	| |    |  __/ \__ \ |_____| | (_| | | (_) |  \ V  V /  | | | | | | | (_) | | (_| |  | (_| | |  __/ | |
	|_|     \___| |___/          \__,_|  \___/    \_/\_/   |_| |_| |_|  \___/   \__ ,_|  \__,_|  \___| |_|`

			log.Println(logo)
			fmt.Println("version:", app.Version)
			if app.Build != "" {
				fmt.Println("build:", app.Build)
			}
			fmt.Println("lockfile:", app.LockFile)
			app.Startup(ctx)
		},
		OnShutdown: func(ctx context.Context) {
			app.OnExit()
		},
		Bind: []interface{}{
			bind,
		},
		Mac: &mac.Options{
			TitleBar: mac.TitleBarHiddenInset(),
			About: &mac.AboutInfo{
				Title:   fmt.Sprintf("%s %s", app.AppName, app.Version),
				Message: app.Description + app.Copyright,
				Icon:    icon,
			},
			WebviewIsTransparent: false,
			WindowIsTranslucent:  false,
		},
		Windows: &windows.Options{
			WebviewIsTransparent:              false,
			WindowIsTranslucent:               false,
			DisableFramelessWindowDecorations: false,
		},
		Linux: &linux.Options{
			ProgramName:         app.AppName,
			Icon:                icon,
			WebviewGpuPolicy:    linux.WebviewGpuPolicyOnDemand,
			WindowIsTranslucent: true,
		},
	})

	if err != nil {
		println("Error:", err.Error())
	}
}
