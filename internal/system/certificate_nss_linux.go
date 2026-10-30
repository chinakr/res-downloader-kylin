//go:build linux

package system

// KYLIN-FORK(begin) 免 root 的证书信任路径
//
// 上游在 Linux 上只走系统信任库：把证书拷进 /usr/local/share/ca-certificates
// 再 sudo update-ca-certificates。在银河麒麟这类环境里，sudo 需要交互密码，
// 而用户未必愿意（或有权）把登录密码交给界面输入框；没有 root 时，
// 「抓取 HTTPS 资源」这条主流程就彻底走不通。
//
// Chromium/Chrome 系浏览器在 Linux 上除了系统 bundle 之外，还会读取当前用户的
// NSS 信任库 ~/.pki/nssdb；curl/Go/Node 读的是合并 bundle。这里补两条免 root 的通路：
//  1. installUserTrust：把本机设备 CA 装进当前用户的 NSS 库（Chromium 系即刻可用）
//  2. certificateTrustedInSystemBundle：直接比对合并 bundle 里的指纹，
//     用于修正「投放文件是 root 750 时 isCertificateInstalled 抛 permission denied」的问题
//
// Firefox 只认自己的证书库，两者都覆盖不到，需要用户手动导入。
// KYLIN-FORK(end)

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// nssTrustNickname 本 fork 写入 NSS 库时使用的条目名。
const nssTrustNickname = "res-downloader-device-ca"

func nssDBPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home directory: %w", err)
	}
	return filepath.Join(home, ".pki", "nssdb"), nil
}

// installUserTrust 把 s.CertFile 指向的设备证书装进当前用户的 NSS 信任库。
// 幂等：同名条目先删再加。
func (s *Setup) installUserTrust() error {
	certutil, err := exec.LookPath("certutil")
	if err != nil {
		return errors.New("certutil not found; install nss-tools (麒麟/Ubuntu: libnss3-tools) to trust the certificate without root")
	}
	raw, err := os.ReadFile(s.CertFile)
	if err != nil {
		return fmt.Errorf("read device certificate: %w", err)
	}
	nssDir, err := nssDBPath()
	if err != nil {
		return err
	}
	// 注意：certutil -N 只会在“已存在的目录”里建库，只建 ~/.pki 会报
	// SEC_ERROR_BAD_DATABASE（老机器上一直“能用”往往是因为库早就存在）。
	if _, statErr := os.Stat(filepath.Join(nssDir, "cert9.db")); errors.Is(statErr, os.ErrNotExist) {
		if err := os.MkdirAll(nssDir, 0700); err != nil {
			return fmt.Errorf("create nss database directory: %w", err)
		}
		if out, err := exec.Command(certutil, "-N", "-d", "sql:"+nssDir, "--empty-password").CombinedOutput(); err != nil {
			return fmt.Errorf("create nss database: %w: %s", err, strings.TrimSpace(string(out)))
		}
	}
	_ = exec.Command(certutil, "-D", "-d", "sql:"+nssDir, "-n", nssTrustNickname).Run()
	if out, err := exec.Command(certutil, "-A", "-d", "sql:"+nssDir,
		"-t", "C,,", "-n", nssTrustNickname, "-i", s.CertFile).CombinedOutput(); err != nil {
		return fmt.Errorf("import certificate into user NSS database: %w: %s", err, strings.TrimSpace(string(out)))
	}
	if trusted, err := certificateTrustedInNSS(raw); err == nil && !trusted {
		return fmt.Errorf("certificate imported but verification failed")
	}
	return nil
}

// certificateTrustedInNSS 判断给定 PEM 是否已作为受信任根存在于用户 NSS 库中。
// certutil -L -a 必须带 nickname，所以先列条目再逐个导出比指纹。
func certificateTrustedInNSS(certificate []byte) (bool, error) {
	certutil, err := exec.LookPath("certutil")
	if err != nil {
		return false, nil // 没装 nss-tools 视为“未信任”，而不是报错
	}
	nssDir, err := nssDBPath()
	if err != nil {
		return false, err
	}
	if _, err := os.Stat(filepath.Join(nssDir, "cert9.db")); err != nil {
		return false, nil
	}
	list, err := exec.Command(certutil, "-L", "-d", "sql:"+nssDir).Output()
	if err != nil {
		return false, nil
	}
	target := CurrentCertificateSHA1(certificate)
	if target == "" {
		return false, errors.New("device certificate is not valid PEM")
	}
	for _, line := range strings.Split(string(list), "\n") {
		nickname := strings.TrimSpace(strings.SplitN(strings.TrimSpace(line), " ", 2)[0])
		if nickname == "" || strings.HasPrefix(nickname, "Certificate") ||
			strings.HasPrefix(nickname, "---") || strings.HasPrefix(nickname, "SSL,") {
			continue
		}
		out, err := exec.Command(certutil, "-L", "-d", "sql:"+nssDir, "-n", nickname, "-a").Output()
		if err != nil {
			continue
		}
		if CurrentCertificateSHA1(out) == target {
			return true, nil
		}
	}
	return false, nil
}

// systemTrustBundles 各发行版合并后的信任链位置
var systemTrustBundles = []string{
	"/etc/ssl/certs/ca-certificates.crt", // Debian/Ubuntu/麒麟
	"/etc/pki/tls/certs/ca-bundle.crt",   // RHEL 系
	"/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
	"/etc/ssl/ca-bundle.pem",
	"/etc/ssl/cert.pem",
}

// certificateTrustedInSystemBundle 直接在合并 bundle 里比对指纹。
// bundle 是世界可读的，因此不受 root 750 投放文件的影响。
func certificateTrustedInSystemBundle(certificate []byte) (bool, error) {
	for _, path := range systemTrustBundles {
		trusted, err := bundleFileContainsCertificate(path, certificate)
		if err != nil {
			continue // 不存在/读不了的候选位置直接跳过
		}
		if trusted {
			return true, nil
		}
	}
	return false, nil
}

// bundleFileContainsCertificate 在一份 PEM 串接文件里查找指定证书（按 SHA-1 指纹）。
func bundleFileContainsCertificate(path string, certificate []byte) (bool, error) {
	target := CurrentCertificateSHA1(certificate)
	if target == "" {
		return false, errors.New("device certificate is not valid PEM")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return false, err
	}
	rest := raw
	for {
		block, remainder := pem.Decode(rest)
		if block == nil {
			return false, nil
		}
		rest = remainder
		if block.Type != "CERTIFICATE" {
			continue
		}
		digest := sha1.Sum(block.Bytes)
		if strings.EqualFold(hex.EncodeToString(digest[:]), target) {
			return true, nil
		}
	}
}
