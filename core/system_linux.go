//go:build linux

package core

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

func (s *SystemSetup) getLinuxDistro() (string, error) {
	data, err := os.ReadFile("/etc/os-release")
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "ID=") {
			return strings.Trim(strings.TrimPrefix(line, "ID="), "\""), nil
		}
	}
	return "", fmt.Errorf("could not determine linux distribution")
}

func (s *SystemSetup) runCommand(args []string, sudo bool) ([]byte, error) {
	if len(args) == 0 {
		return nil, fmt.Errorf("no command provided")
	}

	var cmd *exec.Cmd
	if s.Password != "" && sudo {
		cmd = exec.Command("sudo", append([]string{"-S"}, args...)...)
		cmd.Stdin = bytes.NewReader([]byte(s.Password + "\n"))
	} else {
		cmd = exec.Command(args[0], args[1:]...)
	}

	output, err := cmd.CombinedOutput()
	return output, err
}

// proxyBackupFile 记录接管桌面代理之前的原始设置。
// 上游实现关闭嗅探时把 mode 直接写死成 none，如果用户本来配了公司代理就会永久丢失，
// 这里改为首次接管前备份、取消接管时还原。
func (s *SystemSetup) proxyBackupFile() string {
	return filepath.Join(appOnce.UserDir, "gnome_proxy.backup.json")
}

type gnomeProxyState struct {
	Mode      string `json:"mode"`
	HttpHost  string `json:"http_host"`
	HttpPort  int    `json:"http_port"`
	HttpsHost string `json:"https_host"`
	HttpsPort int    `json:"https_port"`
}

func (s *SystemSetup) gsettingsString(schema, key string) string {
	out, err := exec.Command("gsettings", "get", schema, key).Output()
	if err != nil {
		return ""
	}
	return strings.Trim(strings.TrimSpace(string(out)), "'\"")
}

func (s *SystemSetup) gsettingsInt(schema, key string) int {
	out, err := exec.Command("gsettings", "get", schema, key).Output()
	if err != nil {
		return 0
	}
	n, _ := strconv.Atoi(strings.TrimSpace(string(out)))
	return n
}

func (s *SystemSetup) backupGnomeProxy() {
	path := s.proxyBackupFile()
	if _, err := os.Stat(path); err == nil {
		return // 已有备份，说明是重复接管，不覆盖首次原始值
	}
	state := gnomeProxyState{
		Mode:      s.gsettingsString("org.gnome.system.proxy", "mode"),
		HttpHost:  s.gsettingsString("org.gnome.system.proxy.http", "host"),
		HttpPort:  s.gsettingsInt("org.gnome.system.proxy.http", "port"),
		HttpsHost: s.gsettingsString("org.gnome.system.proxy.https", "host"),
		HttpsPort: s.gsettingsInt("org.gnome.system.proxy.https", "port"),
	}
	if state.Mode == "" {
		return // 没有 gsettings（非 GNOME/UKUI 桌面）时不做备份
	}
	if data, err := json.Marshal(state); err == nil {
		os.WriteFile(path, data, 0600)
	}
}

func (s *SystemSetup) restoreGnomeProxy() bool {
	path := s.proxyBackupFile()
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var state gnomeProxyState
	if err := json.Unmarshal(data, &state); err != nil {
		os.Remove(path)
		return false
	}
	commands := [][]string{
		{"gsettings", "set", "org.gnome.system.proxy", "mode", state.Mode},
		{"gsettings", "set", "org.gnome.system.proxy.http", "host", state.HttpHost},
		{"gsettings", "set", "org.gnome.system.proxy.http", "port", strconv.Itoa(state.HttpPort)},
		{"gsettings", "set", "org.gnome.system.proxy.https", "host", state.HttpsHost},
		{"gsettings", "set", "org.gnome.system.proxy.https", "port", strconv.Itoa(state.HttpsPort)},
	}
	restored := false
	for _, cmd := range commands {
		if _, err := s.runCommand(cmd, false); err == nil {
			restored = true
		}
	}
	if restored {
		os.Remove(path)
	}
	return restored
}

func (s *SystemSetup) setProxy() error {
	s.backupGnomeProxy()

	commands := [][]string{
		{"gsettings", "set", "org.gnome.system.proxy", "mode", "manual"},
		{"gsettings", "set", "org.gnome.system.proxy.http", "host", "127.0.0.1"},
		{"gsettings", "set", "org.gnome.system.proxy.http", "port", globalConfig.Port},
		{"gsettings", "set", "org.gnome.system.proxy.https", "host", "127.0.0.1"},
		{"gsettings", "set", "org.gnome.system.proxy.https", "port", globalConfig.Port},
	}

	isSuccess := false
	var errs strings.Builder

	for _, cmd := range commands {
		if output, err := s.runCommand(cmd, false); err != nil {
			errs.WriteString(fmt.Sprintf("cmd: %v\noutput: %s\nerr: %s\n", cmd, output, err))
		} else {
			isSuccess = true
		}
	}

	if isSuccess {
		return nil
	}

	return fmt.Errorf("failed to set proxy:\n%s", errs.String())
}

func (s *SystemSetup) unsetProxy() error {
	// 优先还原接管前的原始设置；没有备份时退回上游行为（置为 none）
	if s.restoreGnomeProxy() {
		return nil
	}
	cmd := []string{"gsettings", "set", "org.gnome.system.proxy", "mode", "none"}
	output, err := s.runCommand(cmd, false)
	if err != nil {
		return fmt.Errorf("failed to unset proxy: %s\noutput: %s", err.Error(), string(output))
	}
	return nil
}

// installUserTrust 把根证书装进当前用户的 NSS 信任库（~/.pki/nssdb）。
// 系统信任库需要 root，而 Chromium/Chrome、curl(NSS)、Node(部分发行版) 都会读取
// 用户级 NSS 库，这样在麒麟这类 sudo 需要交互密码的环境里也能解密 HTTPS 流量。
func (s *SystemSetup) installUserTrust() error {
	certutil, err := exec.LookPath("certutil")
	if err != nil {
		return fmt.Errorf("certutil not found (install nss-tools/nss-tls): %w", err)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	nssDir := filepath.Join(home, ".pki", "nssdb")
	dbPath := filepath.Join(nssDir, "cert9.db")
	if _, err := os.Stat(dbPath); err != nil {
		if err := os.MkdirAll(filepath.Join(home, ".pki"), 0755); err != nil {
			return err
		}
		out, err := exec.Command(certutil, "-N", "-d", "sql:"+nssDir, "--empty-password").CombinedOutput()
		if err != nil {
			return fmt.Errorf("create nss db failed: %s\n%s", err.Error(), out)
		}
	}
	nickname := appOnce.AppName + "-root"
	// 先删同名旧条目，避免重复导入报错
	_ = exec.Command(certutil, "-D", "-d", "sql:"+nssDir, "-n", nickname).Run()
	out, err := exec.Command(certutil, "-A", "-d", "sql:"+nssDir, "-t", "C,,", "-n", nickname, "-i", s.CertFile).CombinedOutput()
	if err != nil {
		return fmt.Errorf("import to user nss db failed: %s\n%s", err.Error(), out)
	}
	return nil
}

func (s *SystemSetup) installCert() (string, error) {
	_, err := s.initCert()
	if err != nil {
		return "", err
	}

	distro, err := s.getLinuxDistro()
	if err != nil {
		return "", fmt.Errorf("detect distro failed: %w", err)
	}

	certName := appOnce.AppName + ".crt"
	var certPath string
	var updateCmd = []string{"update-ca-certificates"}

	switch distro {
	case "deepin":
		certDir := "/usr/share/ca-certificates/" + appOnce.AppName
		certPath = certDir + "/" + certName
		s.runCommand([]string{"mkdir", "-p", certDir}, true)
	case "arch":
		certPath = "/usr/share/ca-certificates/trust-source/" + certName
		updateCmd = []string{"update-ca-trust"}
	default:
		certPath = "/usr/local/share/ca-certificates/" + certName
	}

	var outs, errs strings.Builder
	isSuccess := false

	if output, err := s.runCommand([]string{"cp", "-f", s.CertFile, certPath}, true); err != nil {
		errs.WriteString(fmt.Sprintf("copy cert failed: %s\n%s\n", err.Error(), output))
	} else {
		isSuccess = true
		outs.Write(output)
	}

	if distro == "deepin" {
		confPath := "/etc/ca-certificates.conf"
		checkCmd := []string{"grep", "-qxF", certName, confPath}
		if _, err := s.runCommand(checkCmd, true); err != nil {
			echoCmd := []string{"bash", "-c", fmt.Sprintf("echo '%s/%s' >> %s", appOnce.AppName, certName, confPath)}
			if output, err := s.runCommand(echoCmd, true); err != nil {
				errs.WriteString(fmt.Sprintf("append conf failed: %s\n%s\n", err.Error(), output))
			} else {
				isSuccess = true
				outs.Write(output)
			}
		}
	}

	if output, err := s.runCommand(updateCmd, true); err != nil {
		errs.WriteString(fmt.Sprintf("update failed: %s\n%s\n", err.Error(), output))
	} else {
		isSuccess = true
		outs.Write(output)
	}

	// 系统信任库需要 root；用户级 NSS 库不需要，两者互为兜底
	userTrustErr := s.installUserTrust()
	if userTrustErr != nil {
		fmt.Println("install cert to user nss db failed:", userTrustErr.Error())
	}

	if isSuccess {
		return "", nil
	}

	if userTrustErr == nil {
		// 系统库没写成，但用户库已生效，浏览器侧 HTTPS 解密已经可用
		return outs.String(), nil
	}

	return outs.String(), fmt.Errorf("certificate installation failed:\n%s\nuser trust fallback: %s",
		errs.String(), userTrustErr.Error())
}
