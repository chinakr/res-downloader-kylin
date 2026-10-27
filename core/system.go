package core

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type SystemSetup struct {
	CertFile  string
	CacheFile string
	Password  string
	aesCipher *AESCipher
}

func initSystem() *SystemSetup {
	if systemOnce == nil {
		systemOnce = &SystemSetup{
			aesCipher: NewAESCipher(localCipherKey()),
			CertFile:  filepath.Join(appOnce.UserDir, "cert.crt"),
			CacheFile: filepath.Join(appOnce.UserDir, "pass.cache"),
		}
		systemOnce.checkPasswordFile()
	}
	return systemOnce
}

// localCipherKey 替换上游硬编码的那把全局 AES 密钥。
// 原实现用源码里写死的 "resd48w2d7er95627d447c490a8f02ff" 把用户的 sudo 密码加密后
// 存进 pass.cache 保留一个月——密钥公开在仓库里，任何人拿到别人的缓存文件都能解出明文密码。
// 现在每台机器随机生成一把，只存本机 0600。
func localCipherKey() string {
	keyFile := filepath.Join(appOnce.UserDir, ".secret")
	if b, err := os.ReadFile(keyFile); err == nil {
		if k := strings.TrimSpace(string(b)); len(k) == 32 {
			return k
		}
	}
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		fmt.Println("生成本机密钥失败，退化为进程内随机串:", err.Error())
		return hex.EncodeToString([]byte(fmt.Sprintf("%d", time.Now().UnixNano())))[:32]
	}
	key := hex.EncodeToString(buf)
	if err := os.WriteFile(keyFile, []byte(key), 0600); err != nil {
		fmt.Println("写本机密钥缓存失败:", err.Error())
	}
	return key
}

// initCert 把当前生效的机器 CA 落到用户目录，供界面「证书下载」与安装流程取用。
// 内容不一致时（换了新证书、或从旧版升级上来）要重写，
// 否则安装证书那一步会把上一世代的旧根再拷一遍进信任库。
func (s *SystemSetup) initCert() ([]byte, error) {
	content, err := os.ReadFile(s.CertFile)
	if err == nil && bytes.Equal(content, appOnce.PublicCrt) {
		return content, nil
	}
	if err = os.WriteFile(s.CertFile, appOnce.PublicCrt, 0640); err != nil {
		return nil, err
	}
	return appOnce.PublicCrt, nil
}

func (s *SystemSetup) SetPassword(password string, isCache bool) {
	s.Password = password
	if isCache {
		encrypted, err := s.aesCipher.Encrypt(password)
		if err == nil {
			err1 := os.WriteFile(s.CacheFile, []byte(encrypted), 0600)
			if err1 != nil {
				fmt.Println("Failed to write password: ", err1.Error())
			}
		} else {
			fmt.Println("Failed to Encrypt password: ", err.Error())
		}
	}
}

func (s *SystemSetup) checkPasswordFile() {
	fileInfo, err := os.Stat(s.CacheFile)
	if err != nil {
		return
	}

	lastModified := fileInfo.ModTime()
	oneMonthAgo := time.Now().AddDate(0, -1, 0)
	if lastModified.Before(oneMonthAgo) {
		os.Remove(s.CacheFile)
		return
	}

	content, err := os.ReadFile(s.CacheFile)
	if err != nil {
		return
	}

	password, err := s.aesCipher.Decrypt(string(content))
	if err != nil {
		// 换过本机密钥后旧缓存解不开，直接作废，别留着误导
		os.Remove(s.CacheFile)
		return
	}
	s.Password = password
}
