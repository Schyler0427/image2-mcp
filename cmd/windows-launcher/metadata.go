package main

import (
	"fmt"
	"regexp"
	"strings"
)

// PayloadInfo describes one architecture-specific MCP executable embedded in
// the launcher. The digest is lowercase or uppercase hexadecimal SHA-256.
type PayloadInfo struct {
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

// PayloadManifest is stored with the embedded payloads. Architectures must be
// keyed by the Windows machine architecture names used by the launcher.
type PayloadManifest struct {
	Version       string                 `json:"version"`
	Architectures map[string]PayloadInfo `json:"architectures"`
}

var sha256Pattern = regexp.MustCompile(`^[[:xdigit:]]{64}$`)

// Validate checks the embedded payload manifest before any file is executed.
func (m PayloadManifest) Validate() error {
	if _, err := parseLauncherVersion(m.Version); err != nil {
		return fmt.Errorf("payload manifest version: %w", err)
	}
	if len(m.Architectures) != len(supportedArchitectures) {
		return fmt.Errorf("payload manifest must contain 386, amd64, and arm64 payloads")
	}
	for arch := range m.Architectures {
		if !supportedArchitectures[arch] {
			return fmt.Errorf("unsupported payload architecture %q", arch)
		}
	}
	for arch, payload := range m.Architectures {
		if payload.Size <= 0 {
			return fmt.Errorf("payload %q has invalid size", arch)
		}
		if !sha256Pattern.MatchString(payload.SHA256) {
			return fmt.Errorf("payload %q has invalid sha256", arch)
		}
	}
	return nil
}

func isSupportedArchitecture(arch string) bool {
	return supportedArchitectures[arch]
}

var supportedArchitectures = map[string]bool{
	"386":   true,
	"amd64": true,
	"arm64": true,
}

func normalizeSHA256(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}
