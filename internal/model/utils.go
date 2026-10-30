package model

import (
	"crypto/md5"
	"encoding/hex"
	"errors"
	"fmt"
	"golang.org/x/net/publicsuffix"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	sysRuntime "runtime"
	"strings"
	"time"
)

func Md5(data string) string {
	hashNew := md5.New()
	hashNew.Write([]byte(data))
	hash := hashNew.Sum(nil)
	return hex.EncodeToString(hash)
}

func FormatSize(size float64) string {
	if size > 1048576 {
		return fmt.Sprintf("%.2fMB", float64(size)/1048576)
	}
	if size > 1024 {
		return fmt.Sprintf("%.2fKB", float64(size)/1024)
	}
	return fmt.Sprintf("%.0fb", size)
}

func GetTopLevelDomain(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err == nil && u.Host != "" {
		rawURL = u.Host
	}
	domain, err := publicsuffix.EffectiveTLDPlusOne(rawURL)
	if err != nil {
		return rawURL
	}
	return domain
}

func FileExist(file string) bool {
	info, err := os.Stat(file)
	if err != nil {
		return false
	}
	return !info.IsDir()
}

func CreateDirIfNotExist(dir string) error {
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		return os.MkdirAll(dir, 0750)
	}
	return nil
}

func IsDevelopment() bool {
	return os.Getenv("APP_ENV") == "development"
}

func GetFileNameFromURL(rawUrl string) string {
	parsedURL, err := url.Parse(rawUrl)
	if err != nil {
		return ""
	}

	fileName := path.Base(parsedURL.Path)
	if fileName == "" || fileName == "/" {
		return ""
	}

	if decoded, err := url.QueryUnescape(fileName); err == nil {
		fileName = decoded
	}

	re := regexp.MustCompile(`[<>:"/\\|?*]`)
	fileName = re.ReplaceAllString(fileName, "_")

	fileName = strings.TrimRightFunc(fileName, func(r rune) bool {
		return r == '.' || r == ' '
	})

	const maxFileNameLen = 255
	runes := []rune(fileName)
	if len(runes) > maxFileNameLen {
		ext := path.Ext(fileName)
		name := strings.TrimSuffix(fileName, ext)

		runes = []rune(name)
		if len(runes) > maxFileNameLen-len(ext) {
			runes = runes[:maxFileNameLen-len(ext)]
		}
		name = string(runes)
		fileName = name + ext
	}

	return fileName
}

func GetCurrentDateTimeFormatted() string {
	now := time.Now()
	return fmt.Sprintf("%04d%02d%02d%02d%02d%02d",
		now.Year(),
		now.Month(),
		now.Day(),
		now.Hour(),
		now.Minute(),
		now.Second())
}

func GetUniqueFileName(filePath string) string {
	if !FileExist(filePath) {
		return filePath
	}

	ext := filepath.Ext(filePath)
	baseName := strings.TrimSuffix(filePath, ext)
	count := 1

	for {
		newFileName := fmt.Sprintf("%s(%d)%s", baseName, count, ext)
		if !FileExist(newFileName) {
			return newFileName
		}
		count++
	}
}

func OpenFolder(filePath string) error {
	var cmd *exec.Cmd
	var commands [][]string
	var lastErr error

	switch sysRuntime.GOOS {
	case "darwin":
		cmd = exec.Command("open", "-R", filePath)
	case "windows":
		cmd = exec.Command("explorer", "/select,", filePath)
	case "linux":
		// KYLIN-FORK(begin) 打开文件所在位置：原先只试 nautilus/thunar/dolphin/pcmanfm，
		// 银河麒麟与 UOS 的 UKUI 桌面只有 peony，Deepin 用 deepin-file-manager/caja，
		// 结果这四个在这类机器上一个都找不到，"打开保存位置"必然失败。
		// 这里改成与同文件 OpenDirectory 一致的风格：按 PATH 实际存在的顺序尝试，
		// 最后兜底 xdg-open。顺带修掉原实现在最外层 return cmd.Start() 处
		// 把已经 Start 成功的命令再启动一次的问题。
		commands = [][]string{
			{"peony", filePath},
			{"peony-qt", filePath},
			{"nautilus", filePath},
			{"thunar", filePath},
			{"dolphin", filePath},
			{"pcmanfm", filePath},
			{"caja", filePath},
			{"xdg-open", filePath},
		}
		for _, command := range commands {
			if _, lookErr := exec.LookPath(command[0]); lookErr != nil {
				lastErr = lookErr
				continue
			}
			if err := exec.Command(command[0], command[1:]...).Start(); err != nil {
				lastErr = err
				continue
			}
			return nil
		}
		if lastErr != nil {
			return lastErr
		}
		return errors.New("no file manager or xdg-open found on this system")
		// KYLIN-FORK(end)
	default:
		return errors.New("unsupported platform")
	}

	if cmd == nil { // 只在 darwin/windows 分支里被赋值；防御性判断，避免空指针
		return errors.New("no command prepared for this platform")
	}
	return cmd.Start()
}

func OpenDirectory(directoryPath string) error {
	info, err := os.Stat(directoryPath)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("not a directory: %s", directoryPath)
	}

	var commands [][]string
	switch sysRuntime.GOOS {
	case "darwin":
		commands = [][]string{{"open", directoryPath}}
	case "windows":
		commands = [][]string{{"explorer", directoryPath}}
	case "linux":
		commands = [][]string{
			{"xdg-open", directoryPath},
			{"nautilus", directoryPath},
			{"thunar", directoryPath},
			{"dolphin", directoryPath},
			{"pcmanfm", directoryPath},
		}
	default:
		return errors.New("unsupported platform")
	}

	var lastErr error
	for _, command := range commands {
		if err := exec.Command(command[0], command[1:]...).Start(); err == nil {
			return nil
		} else {
			lastErr = err
		}
	}
	return lastErr
}
