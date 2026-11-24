package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"debug/buildinfo"
	"debug/pe"
	"encoding/hex"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"testing/fstest"
)

// Exercise the real go:embed filesystem as well as the in-memory fixtures.
// A nested go.mod below the embed directory causes Go to silently skip that
// entire subtree, which fixture-only extraction tests cannot detect.
func TestCompiledEmbeddedPayloadsAreComplete(t *testing.T) {
	for _, arch := range supportedArchitectureList() {
		if _, err := loadEmbeddedPayload(arch); err != nil {
			t.Fatalf("compiled embedded %s payload is incomplete: %v", arch, err)
		}
	}
}

func TestBuiltLauncherIncludesGeneratedPayloads(t *testing.T) {
	launcherPath := os.Getenv("IMAGE2_BUILT_LAUNCHER")
	if launcherPath == "" {
		t.Skip("run by universal launcher builder after compiling generated assets")
	}
	launcher, err := os.ReadFile(launcherPath)
	if err != nil {
		t.Fatal(err)
	}
	launcherImage, err := pe.NewFile(bytes.NewReader(launcher))
	if err != nil {
		t.Fatalf("launcher is not a Windows executable: %v", err)
	}
	defer launcherImage.Close()
	optional, ok := launcherImage.OptionalHeader.(*pe.OptionalHeader32)
	if !ok || launcherImage.Machine != pe.IMAGE_FILE_MACHINE_I386 || optional.Subsystem != pe.IMAGE_SUBSYSTEM_WINDOWS_GUI {
		t.Fatal("launcher must be a Windows 386 GUI executable")
	}
	machines := map[string]uint16{"386": pe.IMAGE_FILE_MACHINE_I386, "amd64": pe.IMAGE_FILE_MACHINE_AMD64, "arm64": pe.IMAGE_FILE_MACHINE_ARM64}
	for _, arch := range supportedArchitectureList() {
		payload, err := loadEmbeddedPayload(arch)
		if err != nil {
			t.Fatal(err)
		}
		binary := payload.MCPExecutable
		image, err := pe.NewFile(bytes.NewReader(binary))
		if err != nil {
			t.Fatalf("%s payload is not a Windows PE executable: %v", arch, err)
		}
		if image.Machine != machines[arch] {
			t.Fatalf("%s payload machine = %x, want %x", arch, image.Machine, machines[arch])
		}
		_ = image.Close()
		info, err := buildinfo.Read(bytes.NewReader(binary))
		if err != nil || info.Path != "image2-mcp/cmd/image2-mcp" {
			t.Fatalf("%s payload is not a real image2-mcp Go binary: %v", arch, err)
		}
		settings := make(map[string]string)
		for _, setting := range info.Settings {
			settings[setting.Key] = setting.Value
		}
		if settings["GOOS"] != "windows" || settings["GOARCH"] != arch {
			t.Fatalf("%s payload has wrong build settings: %v", arch, settings)
		}
		if !bytes.Contains(binary, []byte("image2-mcp "+payload.Version+" offline-v1")) {
			t.Fatalf("%s payload has no matching version marker", arch)
		}
		if !bytes.Contains(launcher, binary) {
			t.Fatalf("built launcher does not contain the verified %s executable", arch)
		}
	}
}

func fixtureEmbeddedFS(t *testing.T, tamper bool) fs.FS {
	t.Helper()
	binary := []byte("image2-mcp executable fixture")
	hash := sha256.Sum256(binary)
	manifest := PayloadManifest{
		Version: "0.4.4",
		Architectures: map[string]PayloadInfo{
			"386":   {SHA256: hex.EncodeToString(hash[:]), Size: int64(len(binary))},
			"amd64": {SHA256: hex.EncodeToString(hash[:]), Size: int64(len(binary))},
			"arm64": {SHA256: hex.EncodeToString(hash[:]), Size: int64(len(binary))},
		},
	}
	if tamper {
		manifest.Architectures["amd64"] = PayloadInfo{SHA256: strings.Repeat("a", 64), Size: int64(len(binary))}
	}
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		"manifest.json":                               string(raw),
		"version":                                     "0.4.4\n",
		"install-offline.ps1":                         "Write-Output installer\n",
		"scripts/bootstrap-agent-install.ps1":         "Write-Output bootstrap-root\n",
		"scripts/offline-binary.ps1":                  "Write-Output offline-root\n",
		"payload/install.ps1":                         "Write-Output payload\n",
		"payload/go.mod.txt":                          "module fixture\n",
		"payload/LICENSE":                             "fixture\n",
		"payload/install.sh":                          "#!/bin/sh\n",
		"payload/scripts/setup.sh":                    "#!/bin/sh\n",
		"payload/scripts/offline-binary.sh":           "#!/bin/sh\n",
		"payload/scripts/offline-binary.ps1":          "Write-Output offline\n",
		"payload/scripts/run-image2-mcp.sh":           "#!/bin/sh\n",
		"payload/scripts/run-image2-mcp.ps1":          "Write-Output runner\n",
		"payload/scripts/bootstrap-agent-install.sh":  "#!/bin/sh\n",
		"payload/scripts/bootstrap-agent-install.ps1": "Write-Output bootstrap\n",
		"payload/OFFLINE_PACKAGE_MANIFEST":            "fixture manifest\n",
	}
	for _, arch := range supportedArchitectureList() {
		files["payload/windows/"+arch+"/image2-mcp.exe"] = string(binary)
	}
	result := make(fstest.MapFS, len(files))
	for path, value := range files {
		result["assets/"+path] = &fstest.MapFile{Data: []byte(value), Mode: 0o600}
	}
	return result
}

func TestExtractEmbeddedPayloadFixtures(t *testing.T) {
	old := embeddedPayloadFS
	defer func() { embeddedPayloadFS = old }()
	embeddedPayloadFS = fixtureEmbeddedFS(t, false)
	for _, arch := range supportedArchitectureList() {
		t.Run(arch, func(t *testing.T) {
			dir := t.TempDir()
			if err := ExtractEmbeddedPayload(arch, dir); err != nil {
				t.Fatalf("ExtractEmbeddedPayload(%q) error = %v", arch, err)
			}
			for _, path := range []string{"install-offline.ps1", "payload/install.ps1", "payload/OFFLINE_PACKAGE_MANIFEST", "payload/dist/image2-mcp.exe"} {
				info, err := os.Lstat(filepath.Join(dir, path))
				if err != nil {
					t.Fatalf("extracted %s: %v", path, err)
				}
				if !info.Mode().IsRegular() || (runtime.GOOS != "windows" && info.Mode().Perm() != 0o600) {
					t.Fatalf("extracted %s mode = %s, want regular 0600", path, info.Mode())
				}
			}
		})
	}
}

func TestExtractEmbeddedPayloadRejectsTamperedManifest(t *testing.T) {
	old := embeddedPayloadFS
	defer func() { embeddedPayloadFS = old }()
	embeddedPayloadFS = fixtureEmbeddedFS(t, true)
	if err := ExtractEmbeddedPayload("386", t.TempDir()); err == nil || !strings.Contains(strings.ToLower(err.Error()), "sha") {
		t.Fatalf("tampered manifest error = %v, want checksum failure", err)
	}
}

func TestEmbeddedPathRejectsTraversal(t *testing.T) {
	for _, path := range []string{"../escape", `..\\escape`, "/absolute", `C:\\absolute`, "payload/../../escape"} {
		if err := validateEmbeddedPath(path); err == nil {
			t.Fatalf("validateEmbeddedPath(%q) unexpectedly succeeded", path)
		}
	}
}

func TestExtractEmbeddedPayloadRejectsSymlinkDestination(t *testing.T) {
	old := embeddedPayloadFS
	defer func() { embeddedPayloadFS = old }()
	embeddedPayloadFS = fixtureEmbeddedFS(t, false)
	root := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "payload")); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	if err := ExtractEmbeddedPayload("386", root); err == nil {
		t.Fatal("symlink destination unexpectedly accepted")
	}
}

func TestInstallEmbeddedWorkspaceCleanup(t *testing.T) {
	old := embeddedPayloadFS
	defer func() { embeddedPayloadFS = old }()
	embeddedPayloadFS = fixtureEmbeddedFS(t, false)
	var workspace string
	runner := func(_ context.Context, dir string, _ InstallerCredentials, _ func(string)) error {
		workspace = dir
		return nil
	}
	if err := installEmbeddedWithRunner(context.Background(), InstallerCredentials{Image2Key: "fixture-key", GeminiKey: "fixture-gemini"}, "386", nil, runner); err != nil {
		t.Fatal(err)
	}
	if workspace == "" {
		t.Fatal("runner did not receive a workspace")
	}
	if _, err := os.Stat(workspace); !os.IsNotExist(err) {
		t.Fatalf("successful install left workspace %q: %v", workspace, err)
	}
	workspace = ""
	runner = func(_ context.Context, dir string, _ InstallerCredentials, _ func(string)) error {
		workspace = dir
		return os.ErrPermission
	}
	if err := installEmbeddedWithRunner(context.Background(), InstallerCredentials{Image2Key: "fixture-key", GeminiKey: "fixture-gemini"}, "386", nil, runner); err == nil {
		t.Fatal("failing install unexpectedly succeeded")
	}
	if workspace == "" {
		t.Fatal("failing runner did not receive a workspace")
	}
	if _, err := os.Stat(workspace); !os.IsNotExist(err) {
		t.Fatalf("failed install left workspace %q: %v", workspace, err)
	}
}

func TestInstallEmbeddedPassesOnlyConfiguredProviderToRunner(t *testing.T) {
	old := embeddedPayloadFS
	defer func() { embeddedPayloadFS = old }()
	embeddedPayloadFS = fixtureEmbeddedFS(t, false)
	for _, test := range []struct {
		name        string
		credentials InstallerCredentials
		want        InstallerCredentials
	}{
		{"image2 only", InstallerCredentials{Image2Key: "image2", GeminiKey: " \t"}, InstallerCredentials{Image2Key: "image2"}},
		{"gemini only", InstallerCredentials{Image2Key: " \t", GeminiKey: "gemini"}, InstallerCredentials{GeminiKey: "gemini"}},
	} {
		t.Run(test.name, func(t *testing.T) {
			called := false
			err := installEmbeddedWithRunner(context.Background(), test.credentials, "386", nil, func(_ context.Context, _ string, credentials InstallerCredentials, _ func(string)) error {
				called = true
				if credentials != test.want {
					t.Fatal("runner received a different provider credential or a whitespace-only key")
				}
				return nil
			})
			if err != nil || !called {
				t.Fatalf("install error = %v, runner called = %t", err, called)
			}
		})
	}
}
