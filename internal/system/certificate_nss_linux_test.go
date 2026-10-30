//go:build linux

package system

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// 复用 v4 自己的生成逻辑造一张一次性根证书，避免测试里再抄一份 X.509 构造代码
func testCertificate(t *testing.T) []byte {
	t.Helper()
	certPEM, _, err := generateCertificateAuthority()
	if err != nil {
		t.Fatalf("生成测试用根证书失败: %v", err)
	}
	return certPEM
}

func TestInstallUserTrustAndDetect(t *testing.T) {
	if _, err := exec.LookPath("certutil"); err != nil {
		t.Skip("本机没有 certutil（libnss3-tools），跳过 NSS 用例")
	}
	home := t.TempDir()
	t.Setenv("HOME", home)

	cert := testCertificate(t)
	certFile := filepath.Join(home, "mitm-ca.crt")
	if err := os.WriteFile(certFile, cert, 0600); err != nil {
		t.Fatalf("写入测试证书失败: %v", err)
	}
	setup := &Setup{CertFile: certFile}

	if err := setup.installUserTrust(); err != nil {
		t.Fatalf("installUserTrust 失败: %v", err)
	}
	if _, err := os.Stat(filepath.Join(home, ".pki", "nssdb", "cert9.db")); err != nil {
		t.Fatalf("NSS 库没被创建（这是老 bug：只建 ~/.pki 会导致 SEC_ERROR_BAD_DATABASE）: %v", err)
	}
	trusted, err := certificateTrustedInNSS(cert)
	if err != nil {
		t.Fatalf("查询 NSS 库出错: %v", err)
	}
	if !trusted {
		t.Fatal("刚导入的证书在 NSS 库里查不到")
	}
	// 另一张证书不能因为"库里有东西"就被误判为已信任
	other, err := certificateTrustedInNSS(testCertificate(t))
	if err != nil {
		t.Fatalf("查询 NSS 库出错: %v", err)
	}
	if other {
		t.Fatal("无关证书被误判为已信任")
	}
	// 幂等：再装一次不应失败
	if err := setup.installUserTrust(); err != nil {
		t.Fatalf("重复安装应当幂等，却失败: %v", err)
	}
}

func TestBundleFileContainsCertificate(t *testing.T) {
	cert := testCertificate(t)
	dir := t.TempDir()
	bundle := filepath.Join(dir, "ca-bundle.crt")
	if err := os.WriteFile(bundle, append([]byte("junk prefix\n"), cert...), 0644); err != nil {
		t.Fatalf("写入 bundle 失败: %v", err)
	}
	found, err := bundleFileContainsCertificate(bundle, cert)
	if err != nil {
		t.Fatalf("解析 bundle 失败: %v", err)
	}
	if !found {
		t.Fatal("bundle 里明明有这张证书却没匹配上")
	}
	if found, _ = bundleFileContainsCertificate(bundle, testCertificate(t)); found {
		t.Fatal("无关证书被误判为在 bundle 里")
	}
	if _, err := bundleFileContainsCertificate(filepath.Join(dir, "missing.crt"), cert); err == nil {
		t.Fatal("文件不存在时应返回错误，让调用方跳过该候选位置")
	}
}

func TestDropInCertificateIgnoresUnreadableFile(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root 下 mode 000 也能读，无法验证 permission 分支")
	}
	dir := t.TempDir()
	cert := testCertificate(t)
	private := filepath.Join(dir, "res-downloader.crt")
	if err := os.WriteFile(private, cert, 0000); err != nil {
		t.Fatalf("制造读不到的投放文件失败: %v", err)
	}
	// 读不到的投放文件不应让整体检查报错（上游会一路抛到界面弹 permission denied）
	matched, err := dropInCertificateMatchesAny([]string{private}, CurrentCertificateSHA1(cert))
	if err != nil {
		t.Fatalf("投放文件读不到时被当成了错误: %v", err)
	}
	if matched {
		t.Fatal("没读到内容却返回已匹配")
	}
	// 可读且匹配时仍要返回 true
	good := filepath.Join(dir, "good.crt")
	if err := os.WriteFile(good, cert, 0644); err != nil {
		t.Fatalf("写入可读投放文件失败: %v", err)
	}
	matched, err = dropInCertificateMatchesAny([]string{private, good}, CurrentCertificateSHA1(cert))
	if err != nil || !matched {
		t.Fatalf("应跳过读不到的项并匹配到可读的那个: matched=%v err=%v", matched, err)
	}
}
