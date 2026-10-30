//go:build linux

package model

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// KYLIN-FORK 测试：麒麟/UOS 的 UKUI 桌面只有 peony，
// 原先只探测 nautilus/thunar/dolphin/pcmanfm 时"打开文件所在位置"必然失败。
func TestOpenFolderFindsPeony(t *testing.T) {
	bin := t.TempDir()
	marker := filepath.Join(t.TempDir(), "peony-started")
	shim := "#!/bin/sh\ntouch \"" + marker + "\" \"$1\"\n"
	if err := os.WriteFile(filepath.Join(bin, "peony"), []byte(shim), 0755); err != nil {
		t.Fatalf("造 peony 替身失败: %v", err)
	}
	// 保留系统路径，否则替身脚本自己找不到 touch
	t.Setenv("PATH", bin+":/usr/local/bin:/usr/bin:/bin")

	if err := OpenFolder("/tmp/some-file.mp4"); err != nil {
		t.Fatalf("PATH 里只有 peony 时应当成功，实际: %v", err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(marker); err == nil {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("peony 被调用时应留下标记文件，但没有看到")
}

func TestOpenFolderReportsNoFileManager(t *testing.T) {
	t.Setenv("PATH", t.TempDir()) // 一个可执行文件都没有
	err := OpenFolder("/tmp/some-file.mp4")
	if err == nil {
		t.Fatal("没有任何文件管理器时应返回错误，而不是静默成功")
	}
	if !strings.Contains(err.Error(), "file manager") && !strings.Contains(err.Error(), "executable file not found") {
		t.Fatalf("错误信息不够明确，实际: %v", err)
	}
}
