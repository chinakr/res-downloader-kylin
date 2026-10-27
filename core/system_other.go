//go:build !linux

package core

import (
	"res-downloader/core/shared"
)

// 非 Linux 平台维持上游原有语义：以 install.lock 为准。
// 真正的信任链比对只在 Linux（麒麟）侧实现，见 system_linux.go。
func (s *SystemSetup) isCertTrusted() (bool, string) {
	return shared.FileExist(appOnce.LockFile), "install.lock"
}

func warnLegacySharedCA() {}
