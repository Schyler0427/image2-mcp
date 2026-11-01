//go:build windows

package main

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"golang.org/x/sys/windows"
)

var errUpdateLaunched = errors.New("launcher update started")

func applyLauncherUpdate(ctx context.Context, info UpdateInfo, nativeArch string) error {
	if !info.Available {
		return errors.New("no launcher update is available")
	}
	if !isSupportedArchitecture(nativeArch) {
		return errors.New("native Windows architecture is unsupported")
	}
	supported := false
	for _, arch := range info.Architectures {
		if arch == nativeArch {
			supported = true
			break
		}
	}
	if !supported {
		return errors.New("launcher update does not support this Windows architecture")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	base, err := os.UserCacheDir()
	if err != nil || strings.TrimSpace(base) == "" {
		return errors.New("launcher update directory is unavailable")
	}
	dir := filepath.Join(base, "SchylerAI", "Image2", "updates")
	path, err := DownloadVerifiedUpdate(ctx, info, launcherUpdateDownloadHTTPClient, dir)
	if err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	command := exec.Command(path)
	command.Env = updateChildEnvironment()
	command.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    false,
		CreationFlags: windows.CREATE_NEW_PROCESS_GROUP,
	}
	if err := command.Start(); err != nil {
		return errors.New("start downloaded launcher failed")
	}
	return errUpdateLaunched
}

func updateChildEnvironment() []string {
	entries := os.Environ()
	filtered := make([]string, 0, len(entries))
	for _, entry := range entries {
		name, _, ok := strings.Cut(entry, "=")
		if !ok {
			continue
		}
		lower := strings.ToLower(name)
		if strings.Contains(lower, "api_key") || strings.Contains(lower, "image_base_url") || strings.Contains(lower, "image_model") {
			continue
		}
		filtered = append(filtered, entry)
	}
	return filtered
}
