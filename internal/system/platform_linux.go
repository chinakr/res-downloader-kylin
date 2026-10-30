//go:build linux

package system

import (
	"bytes"
	"crypto/sha1"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

func (s *Setup) removeLegacyCertificate(fingerprint string) (string, string, error) {
	paths := []string{
		"/usr/local/share/ca-certificates/res-downloader.crt",
		"/etc/ca-certificates/trust-source/anchors/res-downloader.crt",
		"/usr/share/ca-certificates/trust-source/res-downloader.crt",
		"/usr/share/ca-certificates/res-downloader/res-downloader.crt",
	}
	removed := false
	for _, path := range paths {
		raw, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		block, _ := pem.Decode(raw)
		if block == nil {
			continue
		}
		certificate, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			continue
		}
		digest := sha1.Sum(certificate.Raw)
		if !strings.EqualFold(hex.EncodeToString(digest[:]), fingerprint) {
			continue
		}
		if s.Password == "" {
			return "authorizationRequired", "administrator authorization is required to remove the legacy certificate", nil
		}
		if output, err := s.runCommand([]string{"rm", "-f", path}, true); err != nil {
			return "needsManualCleanup", string(output), err
		}
		removed = true
	}
	if !removed {
		return "notFound", "legacy desktop certificate was not installed; remove it manually from any phones that trusted it", nil
	}
	distro, err := s.getLinuxDistro()
	if err != nil {
		return "needsManualCleanup", "", fmt.Errorf("detect distro after legacy certificate removal: %w", err)
	}
	updateCmd := []string{"update-ca-certificates"}
	if distro == "arch" {
		updateCmd = []string{"update-ca-trust", "extract"}
	}
	if distro == "deepin" {
		entryPattern := "^" + s.app.AppName + "/" + s.app.AppName + "\\.crt$"
		if output, err := s.runCommand([]string{"sed", "-i", "\\|" + entryPattern + "|d", "/etc/ca-certificates.conf"}, true); err != nil {
			return "needsManualCleanup", string(output), fmt.Errorf("unregister legacy desktop certificate: %w", err)
		}
	}
	if output, err := s.runCommand(updateCmd, true); err != nil {
		return "needsManualCleanup", string(output), fmt.Errorf("refresh system trust after legacy certificate removal: %w", err)
	}
	for _, path := range paths {
		matches, err := certificateFileMatchesSHA1(path, fingerprint)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return "needsManualCleanup", "", fmt.Errorf("verify legacy certificate file %s: %w", path, err)
		}
		if matches {
			return "needsManualCleanup", "", fmt.Errorf("legacy certificate file %s is still present after cleanup", path)
		}
	}
	return "removed", "legacy desktop certificate removed; certificates installed on phones must be removed manually", nil
}

func (s *Setup) isCertificateInstalled(fingerprint string) (bool, error) {
	paths := []string{
		"/usr/local/share/ca-certificates/res-downloader.crt",
		"/etc/ca-certificates/trust-source/anchors/res-downloader.crt",
		"/usr/share/ca-certificates/trust-source/res-downloader.crt",
		"/usr/share/ca-certificates/res-downloader/res-downloader.crt",
	}
	if matched, err := dropInCertificateMatchesAny(paths, fingerprint); err != nil || matched {
		return matched, err
	}
	// KYLIN-FORK(begin) 再看两个免 root 就能确认的位置：合并 bundle（curl/Go/Node 与
	// 部分浏览器实际读取的信任链）和当前用户的 NSS 库（Chromium 系读取）。
	certificate, readErr := os.ReadFile(s.CertFile)
	if readErr == nil {
		if trusted, err := certificateTrustedInSystemBundle(certificate); err == nil && trusted {
			return true, nil
		}
		if trusted, err := certificateTrustedInNSS(certificate); err == nil && trusted {
			return true, nil
		}
	}
	// KYLIN-FORK(end)
	return false, nil
}

// dropInCertificateMatchesAny 在若干"投放文件"位置里查找指定指纹。
// 只有确实不存在才继续往下找；读不到（root 750/640 的投放文件很常见）或格式异常
// 都不应该让整个证书状态检查失败——上游原先会把 permission denied 一路抛到界面上，
// 弹出 "verify installed certificate: ... permission denied"。
func dropInCertificateMatchesAny(paths []string, fingerprint string) (bool, error) {
	for _, path := range paths {
		matches, err := certificateFileMatchesSHA1(path, fingerprint)
		if errors.Is(err, os.ErrNotExist) || errors.Is(err, os.ErrPermission) { // KYLIN-FORK: 容忍读不到
			continue
		}
		if err != nil {
			return false, err
		}
		if matches {
			return true, nil
		}
	}
	return false, nil
}

func (s *Setup) uninstallCertificate(fingerprint string) (string, error) {
	paths := []string{
		"/usr/local/share/ca-certificates/res-downloader.crt",
		"/etc/ca-certificates/trust-source/anchors/res-downloader.crt",
		"/usr/share/ca-certificates/trust-source/res-downloader.crt",
		"/usr/share/ca-certificates/res-downloader/res-downloader.crt",
	}
	var output strings.Builder
	removed := false
	for _, path := range paths {
		matches, err := certificateFileMatchesSHA1(path, fingerprint)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return output.String(), err
		}
		if !matches {
			continue
		}
		result, err := s.runCommand([]string{"rm", "-f", path}, true)
		output.Write(result)
		if err != nil {
			return output.String(), fmt.Errorf("remove current device certificate: %w", err)
		}
		removed = true
	}
	if !removed {
		return output.String(), nil
	}

	distro, err := s.getLinuxDistro()
	if err != nil {
		return output.String(), fmt.Errorf("detect distro after certificate removal: %w", err)
	}
	updateCmd := []string{"update-ca-certificates"}
	if distro == "arch" {
		updateCmd = []string{"update-ca-trust", "extract"}
	}
	if distro == "deepin" {
		entryPattern := "^" + s.app.AppName + "/" + s.app.AppName + "\\.crt$"
		result, err := s.runCommand([]string{"sed", "-i", "\\|" + entryPattern + "|d", "/etc/ca-certificates.conf"}, true)
		output.Write(result)
		if err != nil {
			return output.String(), fmt.Errorf("unregister current device certificate: %w", err)
		}
	}
	result, err := s.runCommand(updateCmd, true)
	output.Write(result)
	if err != nil {
		return output.String(), fmt.Errorf("update system certificate trust after removal: %w", err)
	}
	return output.String(), nil
}

func (s *Setup) getLinuxDistro() (string, error) {
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

func (s *Setup) runCommand(args []string, sudo bool) ([]byte, error) {
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

func (s *Setup) setProxy() error {
	port := s.config.Snapshot().Port
	value := linuxProxy{"false", "'127.0.0.1'", port, "'127.0.0.1'", port, "'manual'"}
	store := linuxProxyStore{run: func(args []string) ([]byte, error) { return s.runCommand(args, false) }}
	return s.proxyState.set(store, []proxyChange{{key: "system", own: value}})
}

func (s *Setup) unsetProxy() error {
	store := linuxProxyStore{run: func(args []string) ([]byte, error) { return s.runCommand(args, false) }}
	return s.proxyState.unset(store)
}

func (s *Setup) installCert() (string, error) {
	_, err := s.initCert()
	if err != nil {
		return "", err
	}

	distro, err := s.getLinuxDistro()
	if err != nil {
		return "", fmt.Errorf("detect distro failed: %w", err)
	}

	certName := s.app.AppName + ".crt"
	var certPath string
	updateCmd := []string{"update-ca-certificates"}

	switch distro {
	case "deepin":
		certDir := "/usr/share/ca-certificates/" + s.app.AppName
		certPath = certDir + "/" + certName
		if output, err := s.runCommand([]string{"mkdir", "-p", certDir}, true); err != nil {
			return string(output), fmt.Errorf("create certificate directory: %w", err)
		}
	case "arch":
		certPath = "/etc/ca-certificates/trust-source/anchors/" + certName
		updateCmd = []string{"update-ca-trust", "extract"}
	default:
		certPath = "/usr/local/share/ca-certificates/" + certName
	}

	// KYLIN-FORK(begin) 系统信任库这条走不通时（没有 root，或不愿把登录密码交给界面输入框），
	// 退到当前用户的 NSS 库：Chromium/Chrome 系浏览器读它，抓 HTTPS 立刻可用。
	// 系统 bundle 那半边仍然缺失，所以把实际情况如实写进返回值供界面提示，
	// 而不是假装成功。
	systemOutput, systemErr := s.installCertInSystemTrust(certPath, certName, updateCmd)
	if systemErr == nil {
		return "", nil
	}
	nssErr := s.installUserTrust()
	if nssErr != nil {
		return systemOutput, fmt.Errorf("%w；写入当前用户信任库也失败了: %v", systemErr, nssErr)
	}
	return fmt.Sprintf("系统信任库需要管理员授权（%v）；已改为信任到当前用户，"+
		"Chromium/Chrome 系浏览器可以抓取 HTTPS，Firefox 仍需手动导入证书。", systemErr), nil
	// KYLIN-FORK(end)
}

// installCertInSystemTrust 上游原有的系统信任库安装流程，抽出来便于在失败时降级。
func (s *Setup) installCertInSystemTrust(certPath, certName string, updateCmd []string) (string, error) {
	if output, err := s.runCommand([]string{"cp", "-f", s.CertFile, certPath}, true); err != nil {
		return string(output), fmt.Errorf("copy certificate: %w", err)
	}
	if distro, _ := s.getLinuxDistro(); distro == "deepin" {
		confPath := "/etc/ca-certificates.conf"
		confEntry := s.app.AppName + "/" + certName
		checkCmd := []string{"grep", "-qxF", confEntry, confPath}
		if _, err := s.runCommand(checkCmd, true); err != nil {
			echoCmd := []string{"bash", "-c", fmt.Sprintf("echo '%s' >> %s", confEntry, confPath)}
			if output, err := s.runCommand(echoCmd, true); err != nil {
				return string(output), fmt.Errorf("register certificate: %w", err)
			}
		}
	}
	if output, err := s.runCommand(updateCmd, true); err != nil {
		return string(output), fmt.Errorf("update system certificate trust: %w", err)
	}
	return "", nil
}
