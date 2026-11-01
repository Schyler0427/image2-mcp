//go:build !windows

package gemini

import (
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestReferenceNamedPipeRejectedBeforeOpen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "not-an-image")
	if err := syscall.Mkfifo(path, 0600); err != nil {
		t.Skipf("named pipes unavailable: %v", err)
	}
	done := make(chan error, 1)
	go func() { _, _, err := readReference(path, maxInputBytes); done <- err }()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("named pipe accepted as reference image")
		}
	case <-time.After(time.Second):
		t.Fatal("reference preflight blocked opening a nonregular file")
	}
}
