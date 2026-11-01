package main

import (
	"context"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// The build scripts replace this directory with the generated Windows MCP
// payloads immediately before compiling the launcher.
//
//go:embed assets
var embeddedAssets embed.FS

// embeddedPayloadFS is a variable so extraction can be exercised with a
// fixture filesystem without changing the production go:embed data.
var embeddedPayloadFS fs.FS = embeddedAssets

const (
	embeddedManifestPath = "assets/manifest.json"
	embeddedVersionPath  = "assets/version"
	embeddedInstaller    = "assets/install-offline.ps1"
	embeddedRootScripts  = "assets/scripts"
	embeddedPayloadRoot  = "assets/payload"
	maxEmbeddedManifest  = 16 << 10
	maxEmbeddedFile      = 128 << 20
)

var embeddedPayloadFiles = []string{
	"install.sh",
	"install.ps1",
	"go.mod",
	"LICENSE",
	"scripts/setup.sh",
	"scripts/offline-binary.sh",
	"scripts/offline-binary.ps1",
	"scripts/run-image2-mcp.sh",
	"scripts/run-image2-mcp.ps1",
	"scripts/bootstrap-agent-install.sh",
	"scripts/bootstrap-agent-install.ps1",
}

var embeddedRootFiles = []string{
	"install-offline.ps1",
	"scripts/bootstrap-agent-install.ps1",
	"scripts/offline-binary.ps1",
}

// EmbeddedPayload is the verified payload selected for one native Windows
// architecture. Files contains paths relative to the offline package root.
type EmbeddedPayload struct {
	Architecture  string
	Version       string
	Manifest      PayloadManifest
	MCPExecutable []byte
	Files         map[string][]byte
}

func supportedArchitectureList() []string {
	return []string{"386", "amd64", "arm64"}
}

func validateEmbeddedPath(value string) error {
	if value == "" || strings.IndexByte(value, 0) >= 0 || strings.HasPrefix(value, "/") || strings.HasPrefix(value, `\`) {
		return errors.New("embedded path is invalid")
	}
	if len(value) >= 2 && value[1] == ':' {
		return errors.New("embedded path is invalid")
	}
	for _, part := range strings.FieldsFunc(value, func(r rune) bool { return r == '/' || r == '\\' }) {
		if part == ".." || part == "." || part == "" {
			return errors.New("embedded path is invalid")
		}
	}
	clean := path.Clean(strings.ReplaceAll(value, `\`, "/"))
	if clean != value || strings.HasPrefix(clean, "../") || clean == ".." {
		return errors.New("embedded path is invalid")
	}
	return nil
}

func readEmbeddedFile(name string, limit int64) ([]byte, error) {
	if err := validateEmbeddedPath(name); err != nil {
		return nil, err
	}
	info, err := fs.Stat(embeddedPayloadFS, name)
	if err != nil {
		return nil, fmt.Errorf("embedded asset %s is missing", filepath.Base(name))
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return nil, fmt.Errorf("embedded asset %s is not a regular file", filepath.Base(name))
	}
	if info.Size() < 0 || info.Size() > limit {
		return nil, fmt.Errorf("embedded asset %s is too large", filepath.Base(name))
	}
	file, err := embeddedPayloadFS.Open(name)
	if err != nil {
		return nil, errors.New("open embedded asset failed")
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, errors.New("read embedded asset failed")
	}
	if int64(len(data)) != info.Size() || int64(len(data)) > limit {
		return nil, errors.New("embedded asset size changed")
	}
	return data, nil
}

func loadEmbeddedPayload(arch string) (EmbeddedPayload, error) {
	if !isSupportedArchitecture(arch) {
		return EmbeddedPayload{}, fmt.Errorf("unsupported Windows architecture %q", arch)
	}
	manifestBytes, err := readEmbeddedFile(embeddedManifestPath, maxEmbeddedManifest)
	if err != nil {
		return EmbeddedPayload{}, err
	}
	var manifest PayloadManifest
	decoder := json.NewDecoder(strings.NewReader(string(manifestBytes)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&manifest); err != nil {
		return EmbeddedPayload{}, errors.New("embedded payload manifest is invalid")
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return EmbeddedPayload{}, errors.New("embedded payload manifest has trailing data")
	}
	if err := manifest.Validate(); err != nil {
		return EmbeddedPayload{}, fmt.Errorf("embedded payload manifest: %w", err)
	}
	versionBytes, err := readEmbeddedFile(embeddedVersionPath, 128)
	if err != nil {
		return EmbeddedPayload{}, err
	}
	if strings.TrimSpace(string(versionBytes)) != manifest.Version {
		return EmbeddedPayload{}, errors.New("embedded payload version marker does not match manifest")
	}

	files := make(map[string][]byte, len(embeddedPayloadFiles))
	var total int64
	for _, relative := range embeddedPayloadFiles {
		assetName := relative
		if relative == "go.mod" {
			// A real go.mod creates a nested module that go:embed excludes.
			// Keep it as data in the archive and restore its installer name.
			assetName = "go.mod.txt"
		}
		data, err := readEmbeddedFile(embeddedPayloadRoot+"/"+assetName, maxEmbeddedFile)
		if err != nil {
			return EmbeddedPayload{}, err
		}
		total += int64(len(data))
		if total > maxEmbeddedFile {
			return EmbeddedPayload{}, errors.New("embedded payload is too large")
		}
		files["payload/"+relative] = data
	}
	for _, relative := range embeddedRootFiles {
		data, err := readEmbeddedFile(embeddedRootScripts+"/"+strings.TrimPrefix(relative, "scripts/"), maxEmbeddedFile)
		if relative == "install-offline.ps1" {
			data, err = readEmbeddedFile(embeddedInstaller, maxEmbeddedFile)
		}
		if err != nil {
			return EmbeddedPayload{}, err
		}
		files[relative] = data
	}

	for _, candidate := range supportedArchitectureList() {
		binary, err := readEmbeddedFile(embeddedPayloadRoot+"/windows/"+candidate+"/image2-mcp.exe", maxEmbeddedFile)
		if err != nil {
			return EmbeddedPayload{}, err
		}
		payload := manifest.Architectures[candidate]
		hash := sha256.Sum256(binary)
		if int64(len(binary)) != payload.Size || !strings.EqualFold(hex.EncodeToString(hash[:]), normalizeSHA256(payload.SHA256)) {
			return EmbeddedPayload{}, fmt.Errorf("embedded payload %s SHA-256 or size does not match manifest", candidate)
		}
		if candidate == arch {
			files["payload/dist/image2-mcp.exe"] = binary
		}
	}
	return EmbeddedPayload{Architecture: arch, Version: manifest.Version, Manifest: manifest, MCPExecutable: files["payload/dist/image2-mcp.exe"], Files: files}, nil
}

func rejectUnsafePath(root, relative string) error {
	if err := validateEmbeddedPath(relative); err != nil {
		return err
	}
	rootInfo, err := os.Lstat(root)
	if err != nil {
		return errors.New("payload destination is unavailable")
	}
	if !rootInfo.IsDir() || rootInfo.Mode()&os.ModeSymlink != 0 || isReparsePath(root) {
		return errors.New("payload destination is not a regular directory")
	}
	current := root
	for _, part := range strings.Split(relative, "/") {
		current = filepath.Join(current, part)
		info, err := os.Lstat(current)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return errors.New("payload destination path is unavailable")
		}
		if info.Mode()&os.ModeSymlink != 0 || isReparsePath(current) {
			return errors.New("payload destination contains a symlink")
		}
		if info.IsDir() && part != filepath.Base(relative) {
			continue
		}
	}
	return nil
}

func writeEmbeddedFile(root, relative string, data []byte) error {
	if err := rejectUnsafePath(root, relative); err != nil {
		return err
	}
	parent := filepath.Dir(filepath.Join(root, filepath.FromSlash(relative)))
	if err := os.MkdirAll(parent, 0o700); err != nil {
		return errors.New("create payload directory failed")
	}
	if err := rejectUnsafePath(root, relative); err != nil {
		return err
	}
	file, err := os.OpenFile(filepath.Join(root, filepath.FromSlash(relative)), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return errors.New("create payload file failed")
	}
	defer file.Close()
	if _, err := file.Write(data); err != nil {
		return errors.New("write payload file failed")
	}
	if err := file.Sync(); err != nil {
		return errors.New("flush payload file failed")
	}
	return file.Chmod(0o600)
}

func offlinePackageManifest(payload EmbeddedPayload) []byte {
	var builder strings.Builder
	builder.WriteString("IMAGE2_MCP_OFFLINE 1\nversion ")
	builder.WriteString(payload.Version)
	builder.WriteString("\nplatform windows ")
	builder.WriteString(payload.Architecture)
	builder.WriteByte('\n')
	for _, relative := range append(append([]string(nil), embeddedPayloadFiles...), "dist/image2-mcp.exe") {
		data := payload.Files["payload/"+relative]
		hash := sha256.Sum256(data)
		fmt.Fprintf(&builder, "file %s %d %s\n", hex.EncodeToString(hash[:]), len(data), relative)
	}
	return []byte(builder.String())
}

// ExtractEmbeddedPayload verifies every generated payload before creating any
// output file. The selected binary is emitted at the path expected by the
// existing offline bootstrap transaction.
func ExtractEmbeddedPayload(arch, dir string) error {
	if !isSupportedArchitecture(arch) {
		return fmt.Errorf("unsupported Windows architecture %q", arch)
	}
	if dir == "" {
		return errors.New("payload destination is required")
	}
	info, err := os.Lstat(dir)
	if err != nil {
		if !os.IsNotExist(err) {
			return errors.New("payload destination is unavailable")
		}
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return errors.New("create payload destination failed")
		}
		info, err = os.Lstat(dir)
		if err != nil {
			return errors.New("payload destination is unavailable")
		}
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("payload destination is not a regular directory")
	}
	payload, err := loadEmbeddedPayload(arch)
	if err != nil {
		return err
	}
	for relative, data := range payload.Files {
		if err := writeEmbeddedFile(dir, relative, data); err != nil {
			return err
		}
	}
	if err := writeEmbeddedFile(dir, "payload/OFFLINE_PACKAGE_MANIFEST", offlinePackageManifest(payload)); err != nil {
		return err
	}
	if err := writeEmbeddedFile(dir, "OFFLINE_PACKAGE_VERSION", []byte(payload.Version+"\n")); err != nil {
		return err
	}
	return nil
}

type embeddedInstallerRunner func(context.Context, string, InstallerCredentials, func(string)) error

func installEmbeddedWithRunner(ctx context.Context, credentials InstallerCredentials, arch string, status func(string), runner embeddedInstallerRunner) error {
	if err := credentials.Validate(); err != nil {
		return err
	}
	credentials = credentials.normalized()
	if runner == nil {
		return errors.New("embedded installer is unavailable")
	}
	workspace, err := os.MkdirTemp("", ".image2-mcp-launcher-*")
	if err != nil {
		return errors.New("create launcher workspace failed")
	}
	defer os.RemoveAll(workspace)
	if err := ExtractEmbeddedPayload(arch, workspace); err != nil {
		return err
	}
	return runner(ctx, workspace, credentials, status)
}
