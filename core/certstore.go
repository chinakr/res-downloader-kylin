package core

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// 本机专属 MITM 根证书。
//
// 上游把根证书和它的私钥一起硬编码在 core/app.go 里（CN=gowas.cn，自签，2124 到期），
// 全球所有安装共用同一把——任何读过公开仓库的人都能对信任了这把根的设备做中间人。
// 这里改成：优先加载 deb 安装时以 root 生成在 /etc/res-downloader 的机器专属证书，
// 拿不到就在用户目录里现生成一把，私钥只落本机、权限 0600。
const (
	SystemCADir     = "/etc/res-downloader"
	caCertFileName  = "ca.crt"
	caKeyFileName   = "ca.key"
	caKeyBits       = 2048
	caValidYears    = 100
	caPrivateKeyPem = "PRIVATE KEY" // PKCS#8，与 tls.X509KeyPair 对齐
)

// CAMount 记录当前生效的 CA 落在哪，便于日志与界面提示
type CAMount struct {
	Scope string // "system" | "user"
	Cert  string
	Key   string
}

var currentCA *CAMount

func userCAPair(userDir string) (string, string) {
	return filepath.Join(userDir, caCertFileName), filepath.Join(userDir, caKeyFileName)
}

// LoadMachineCA 按 system → user → 新生成 的顺序把证书喂给 appOnce。
func LoadMachineCA() error {
	cert, key := filepath.Join(SystemCADir, caCertFileName), filepath.Join(SystemCADir, caKeyFileName)
	if pair, err := readCASystem(cert, key); err == nil {
		currentCA = &CAMount{Scope: "system", Cert: cert, Key: key}
		apply(pair)
		return nil
	} else {
		// 目录里有证书却读不了私钥，多半是权限问题，明确报出来而不是悄悄换一把
		if _, statErr := os.Stat(cert); statErr == nil {
			fmt.Println("[ca] 找到系统级 CA 但不可用，将回退到用户级:", err.Error())
		}
	}

	userCert, userKey := userCAPair(appOnce.UserDir)
	if pair, err := readCASystem(userCert, userKey); err == nil {
		currentCA = &CAMount{Scope: "user", Cert: userCert, Key: userKey}
		apply(pair)
		return nil
	} else if _, statErr := os.Stat(userCert); statErr == nil {
		fmt.Println("[ca] 用户级 CA 不可用，将重新生成:", err.Error())
	}

	pair, err := generateCA(userCert, userKey)
	if err != nil {
		return fmt.Errorf("生成本机 CA 失败: %w", err)
	}
	currentCA = &CAMount{Scope: "user", Cert: userCert, Key: userKey}
	apply(pair)
	fmt.Println("[ca] 已生成本机专属根证书（私钥仅存本机）:", userCert)
	return nil
}

func apply(pair *tls.Certificate) {
	block := pem.Block{Type: "CERTIFICATE", Bytes: pair.Certificate[0]}
	appOnce.PublicCrt = pem.EncodeToMemory(&block)
	kb, err := x509.MarshalPKCS8PrivateKey(pair.PrivateKey)
	if err != nil { // 理论上不会发生：读回来的一定是 PKCS8
		fmt.Println("[ca] 私钥序列化失败:", err.Error())
		return
	}
	appOnce.PrivateKey = pem.EncodeToMemory(&pem.Block{Type: caPrivateKeyPem, Bytes: kb})
}

// readCASystem 读并校验一对 PEM：必须能配成 keypair、必须是 CA、必须还在有效期内
func readCASystem(certPath, keyPath string) (*tls.Certificate, error) {
	certPEM, err := os.ReadFile(certPath)
	if err != nil {
		return nil, err
	}
	keyPEM, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("读私钥失败(%s): %w", keyPath, err)
	}
	// 私钥只应对"要用它的那个用户"可见：属组可读是 postinst 的降级方案（无 setfacl 时），
	// 真正不能接受的是其他用户可读。
	if fi, e := os.Stat(keyPath); e == nil && fi.Mode().Perm()&0o007 != 0 {
		fmt.Printf("[ca] 警告：私钥被其他用户可读 %s (%v)\n", keyPath, fi.Mode().Perm())
	}
	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, fmt.Errorf("证书与私钥不匹配: %w", err)
	}
	leaf, err := x509.ParseCertificate(certPEM2DER(certPEM))
	if err != nil {
		return nil, fmt.Errorf("解析证书失败: %w", err)
	}
	if !leaf.IsCA || leaf.KeyUsage&x509.KeyUsageCertSign == 0 {
		return nil, fmt.Errorf("%s 不可用于签发中间证书（缺 CA:TRUE 或 keyCertSign）", certPath)
	}
	if time.Now().After(leaf.NotAfter) || time.Now().Before(leaf.NotBefore) {
		return nil, fmt.Errorf("%s 不在有效期内", certPath)
	}
	pair.Leaf = leaf
	return &pair, nil
}

func certPEM2DER(certPEM []byte) []byte {
	if b, _ := pem.Decode(certPEM); b != nil {
		return b.Bytes
	}
	return certPEM
}

// GenerateCAAt 供 deb 的 postinst 以 root 调用（res-downloader.app -init-ca <目录>）：
// 让包安装时生成的证书和 app 自建的是同一份代码、同一组扩展，
// 避免两边形状不一致（openssl req -x509 在发行版默认配置下会把 basicConstraints
// 写两遍，重复的 critical 扩展会让证书链校验直接失败）。
func GenerateCAAt(dir string) (string, string, error) {
	certPath := filepath.Join(dir, caCertFileName)
	keyPath := filepath.Join(dir, caKeyFileName)
	if _, err := readCASystem(certPath, keyPath); err == nil {
		return certPath, keyPath, nil // 已有一把，绝不重新生成
	}
	if _, err := generateCA(certPath, keyPath); err != nil {
		return "", "", err
	}
	return certPath, keyPath, nil
}

// generateCA 生成 RSA-2048 自签根，落到指定路径（私钥 0600）
func generateCA(certPath, keyPath string) (*tls.Certificate, error) {
	key, err := rsa.GenerateKey(rand.Reader, caKeyBits)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, err
	}
	cn := "res-downloader"
	if host, e := os.Hostname(); e == nil && strings.TrimFunc(host, func(r rune) bool { return r > 127 }) != "" {
		cn = "res-downloader@" + strings.TrimFunc(host, func(r rune) bool { return r > 127 })
	}
	tmpl := x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:         cn,
			Organization:       []string{"res-downloader local"},
			OrganizationalUnit: []string{"MITM root"},
		},
		NotBefore:             time.Now().Add(-24 * time.Hour),
		NotAfter:              time.Now().AddDate(caValidYears, 0, 0),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLenZero:        true,
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(certPath), 0750); err != nil {
		return nil, err
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, err
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: caPrivateKeyPem, Bytes: keyDER})
	if err := os.WriteFile(certPath, certPEM, 0644); err != nil {
		return nil, err
	}
	if err := os.WriteFile(keyPath, keyPEM, 0600); err != nil {
		return nil, err
	}
	return readCASystem(certPath, keyPath)
}

// CAPublicPEM 供界面「证书下载」和安装流程使用；始终以当前生效的机器 CA 为准
func CAPublicPEM() []byte {
	if len(appOnce.PublicCrt) > 0 {
		return appOnce.PublicCrt
	}
	return nil
}

func CAScopeLabel() string {
	if currentCA == nil {
		return "unknown"
	}
	if currentCA.Scope == "system" {
		return "系统级 " + SystemCADir
	}
	return "用户级 " + appOnce.UserDir
}

// CAStatus 给 `-ca-status` 诊断入口用：证书在哪、指纹是什么、
// 系统信任链和 NSS 用户库里分别有没有认出它。
func CAStatus() string {
	var b strings.Builder
	fp, err := CAFingerprint()
	fmt.Fprintf(&b, "来源: %s\n", CAScopeLabel())
	if err != nil {
		fmt.Fprintf(&b, "指纹: 取不到(%v)\n", err)
		return b.String()
	}
	fmt.Fprintf(&b, "指纹: %s\n", fp)
	trusted, where := systemOnce.isCertTrusted()
	fmt.Fprintf(&b, "已被系统信任: %v %s\n", trusted, where)
	if hits := FindTrustedRoot(fp); len(hits) > 0 {
		fmt.Fprintf(&b, "  系统信任链命中: %s\n", strings.Join(hits, ", "))
	} else {
		fmt.Fprintf(&b, "  系统信任链命中: 无\n")
	}
	if _, ok := FindInNSSDB(fp); ok {
		fmt.Fprintf(&b, "  NSS 用户库命中: 是\n")
	} else {
		fmt.Fprintf(&b, "  NSS 用户库命中: 无\n")
	}
	if legacy := FindTrustedRoot(LegacySharedCAPrefix); len(legacy) > 0 {
		fmt.Fprintf(&b, "  ⚠ 上游共用根仍在信任链中: %s\n", strings.Join(legacy, ", "))
	}
	return b.String()
}

// LegacySharedCAPrefix 是上游硬编码那把共用根的指纹（CN=gowas.cn，私钥公开在仓库里）。
// 保留它是为了在迁移时把还躺在信任库里的旧根揪出来，不是继续信任它。
const LegacySharedCAPrefix = "6E7F9E6BF34F9843853285E0CB7399FA264F834AA1DA0F2EBBE0234546F97DA0"

// trustBundlePaths 各发行版合并后的信任链位置
var trustBundlePaths = []string{
	"/etc/ssl/certs/ca-certificates.crt", // Debian/Ubuntu/麒麟
	"/etc/pki/tls/certs/ca-bundle.crt",   // RHEL 系
	"/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
	"/etc/ssl/ca-bundle.pem", // openSUSE
	"/etc/ssl/cert.pem",
}

// CAFingerprint 当前生效 CA 的 SHA-256 指纹（大写十六进制，无冒号）
func CAFingerprint() (string, error) {
	b, _ := pem.Decode(appOnce.PublicCrt)
	if b == nil {
		return "", fmt.Errorf("当前 CA 不是合法 PEM")
	}
	sum := sha256.Sum256(b.Bytes)
	return strings.ToUpper(hex.EncodeToString(sum[:])), nil
}

// FindTrustedRoot 在系统信任链里找指定指纹的根，返回它出现的位置
func FindTrustedRoot(fingerprint string) []string {
	fingerprint = strings.ToUpper(fingerprint)
	var hits []string
	seen := map[string]bool{}

	bundles := append([]string{}, trustBundlePaths...)
	if local, err := filepath.Glob("/usr/local/share/ca-certificates/*.crt"); err == nil {
		bundles = append(bundles, local...)
	}
	for _, f := range bundles {
		seen[f] = true
		if match, err := certInFile(f, fingerprint); err == nil && match {
			hits = append(hits, f)
		}
	}
	// openssl CApath 目录式查询走的是这里的单文件软链，Go/许多库会用它
	if entries, err := os.ReadDir("/etc/ssl/certs"); err == nil {
		for _, e := range entries {
			name := e.Name()
			if !strings.HasSuffix(name, ".pem") && !strings.HasSuffix(name, ".crt") {
				continue
			}
			p := filepath.Join("/etc/ssl/certs", name)
			if _, dup := seen[p]; dup {
				continue
			}
			if match, err := certInFile(p, fingerprint); err == nil && match {
				hits = append(hits, p)
				break
			}
		}
	}
	return hits
}

func certInFile(path, fingerprint string) (bool, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return false, err
	}
	for {
		b, rest := pem.Decode(data)
		if b == nil {
			return false, nil
		}
		data = rest
		if b.Type != "CERTIFICATE" {
			continue
		}
		sum := sha256.Sum256(b.Bytes)
		if strings.ToUpper(hex.EncodeToString(sum[:])) == fingerprint {
			return true, nil
		}
	}
}

// FindInNSSDB 查当前用户的 NSS 信任库（Chromium 系浏览器读这里），需要 nss-tools 的 certutil。
// 注意 `certutil -L -a` 必须带 nickname（否则会报 "nickname is required to dump cert"），
// 所以只能先列出条目再逐个导出比对。
func FindInNSSDB(fingerprint string) (string, bool) {
	fingerprint = strings.ToUpper(fingerprint)
	home, err := os.UserHomeDir()
	if err != nil {
		return "", false
	}
	db := filepath.Join(home, ".pki", "nssdb")
	if _, err := os.Stat(filepath.Join(db, "cert9.db")); err != nil {
		return "", false
	}
	certutil, err := exec.LookPath("certutil")
	if err != nil {
		return "", false
	}
	listOut, err := exec.Command(certutil, "-L", "-d", "sql:"+db).Output()
	if err != nil {
		return "", false
	}
	for _, line := range strings.Split(string(listOut), "\n") {
		nick := strings.TrimSpace(line)
		if nick == "" || strings.HasPrefix(nick, "Certificate Nickname") ||
			strings.HasPrefix(nick, "SSL,") || strings.HasPrefix(nick, "---") {
			continue
		}
		nick = strings.Trim(strings.Fields(nick)[0], "\"")
		if nick == "" {
			continue
		}
		pemOut, err := exec.Command(certutil, "-L", "-d", "sql:"+db, "-n", nick, "-a").Output()
		if err != nil {
			continue
		}
		for {
			b, rest := pem.Decode(pemOut)
			if b == nil {
				break
			}
			pemOut = rest
			if b.Type != "CERTIFICATE" {
				continue
			}
			sum := sha256.Sum256(b.Bytes)
			if strings.ToUpper(hex.EncodeToString(sum[:])) == fingerprint {
				return db, true
			}
		}
	}
	return db, false
}
