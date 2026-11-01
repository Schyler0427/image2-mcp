package main

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// MaxUpdateSize limits the downloaded launcher before it is retained on disk.
const MaxUpdateSize int64 = 256 << 20

// UpdateManifest is the signed JSON document published for a launcher release.
type UpdateManifest struct {
	Version       string   `json:"version"`
	PublishedAt   string   `json:"published_at"`
	Notes         string   `json:"notes"`
	AssetURL      string   `json:"asset_url"`
	SHA256        string   `json:"sha256"`
	Size          int64    `json:"size"`
	Signature     string   `json:"signature"`
	Architectures []string `json:"architectures"`
}

// UpdateInfo is the verified subset used by the downloader and handoff code.
type UpdateInfo struct {
	Version       string
	PublishedAt   string
	Notes         string
	AssetURL      string
	SHA256        string
	Size          int64
	Signature     string
	Architectures []string
	Available     bool
}

type updateManifestSigningPayload struct {
	Version       string   `json:"version"`
	PublishedAt   string   `json:"published_at"`
	Notes         string   `json:"notes"`
	AssetURL      string   `json:"asset_url"`
	SHA256        string   `json:"sha256"`
	Size          int64    `json:"size"`
	Architectures []string `json:"architectures"`
}

func canonicalUpdateManifest(manifest UpdateManifest) []byte {
	payload := updateManifestSigningPayload{
		Version:       manifest.Version,
		PublishedAt:   manifest.PublishedAt,
		Notes:         manifest.Notes,
		AssetURL:      manifest.AssetURL,
		SHA256:        manifest.SHA256,
		Size:          manifest.Size,
		Architectures: manifest.Architectures,
	}
	encoded, _ := json.Marshal(payload)
	return encoded
}

// VerifyUpdateManifest verifies the production update host and trusted key.
func VerifyUpdateManifest(raw []byte, publicKey ed25519.PublicKey, current string) (UpdateInfo, error) {
	return verifyUpdateManifestForHost(raw, publicKey, current, UpdateManifestHost)
}

// verifyUpdateManifestForHost is kept internal so tests can use a local TLS
// server without weakening the production fixed-host policy.
func verifyUpdateManifestForHost(raw []byte, publicKey ed25519.PublicKey, current, expectedHost string) (UpdateInfo, error) {
	var manifest UpdateManifest
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&manifest); err != nil {
		return UpdateInfo{}, fmt.Errorf("invalid update manifest: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return UpdateInfo{}, errors.New("invalid update manifest: trailing data")
	}
	if len(publicKey) != ed25519.PublicKeySize {
		return UpdateInfo{}, errors.New("invalid update manifest public key")
	}
	if !ed25519.Verify(publicKey, canonicalUpdateManifest(manifest), decodeSignature(manifest.Signature)) {
		return UpdateInfo{}, errors.New("invalid update manifest signature")
	}
	version, err := parseLauncherVersion(manifest.Version)
	if err != nil {
		return UpdateInfo{}, fmt.Errorf("invalid update manifest version: %w", err)
	}
	currentVersion, err := parseLauncherVersion(current)
	if err != nil {
		return UpdateInfo{}, fmt.Errorf("invalid current launcher version: %w", err)
	}
	if manifest.PublishedAt == "" {
		return UpdateInfo{}, errors.New("update manifest published_at is required")
	}
	if _, err := time.Parse(time.RFC3339, manifest.PublishedAt); err != nil {
		return UpdateInfo{}, fmt.Errorf("invalid published_at: %w", err)
	}
	assetURL, err := validateUpdateURL(manifest.AssetURL, expectedHost)
	if err != nil {
		return UpdateInfo{}, err
	}
	if manifest.Size <= 0 || manifest.Size > MaxUpdateSize {
		return UpdateInfo{}, fmt.Errorf("update asset size %d exceeds allowed size", manifest.Size)
	}
	if !sha256Pattern.MatchString(manifest.SHA256) {
		return UpdateInfo{}, errors.New("invalid update asset sha256")
	}
	if len(manifest.Architectures) == 0 {
		return UpdateInfo{}, errors.New("update manifest architectures are required")
	}
	seen := make(map[string]struct{}, len(manifest.Architectures))
	for _, arch := range manifest.Architectures {
		if !isSupportedArchitecture(arch) {
			return UpdateInfo{}, fmt.Errorf("unsupported update architecture %q", arch)
		}
		if _, exists := seen[arch]; exists {
			return UpdateInfo{}, fmt.Errorf("duplicate update architecture %q", arch)
		}
		seen[arch] = struct{}{}
	}
	if compareLauncherVersions(version, currentVersion) < 0 {
		return UpdateInfo{}, fmt.Errorf("update version %s is older than current version", manifest.Version)
	}
	return UpdateInfo{
		Version:       manifest.Version,
		PublishedAt:   manifest.PublishedAt,
		Notes:         manifest.Notes,
		AssetURL:      assetURL.String(),
		SHA256:        normalizeSHA256(manifest.SHA256),
		Size:          manifest.Size,
		Signature:     manifest.Signature,
		Architectures: append([]string(nil), manifest.Architectures...),
		Available:     compareLauncherVersions(version, currentVersion) > 0,
	}, nil
}

func decodeSignature(value string) []byte {
	signature, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		signature, _ = base64.RawStdEncoding.DecodeString(value)
	}
	return signature
}

func validateUpdateURL(raw, expectedHost string) (*url.URL, error) {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || parsed.Fragment != "" {
		return nil, errors.New("update asset URL must use HTTPS")
	}
	if !hostMatches(parsed, expectedHost) {
		return nil, errors.New("update asset URL host is not trusted")
	}
	return parsed, nil
}

func hostMatches(parsed *url.URL, expectedHost string) bool {
	if expectedHost == "" {
		return false
	}
	if strings.EqualFold(parsed.Host, expectedHost) {
		return true
	}
	return !strings.Contains(expectedHost, ":") && parsed.Port() == "" && strings.EqualFold(parsed.Hostname(), expectedHost)
}

// DownloadVerifiedUpdate downloads one verified executable to dir and returns
// its atomically retained path. No response body or URL is included in errors.
func DownloadVerifiedUpdate(ctx context.Context, info UpdateInfo, client *http.Client, dir string) (string, error) {
	return downloadVerifiedUpdateForHost(ctx, info, client, dir, UpdateManifestHost)
}

func downloadVerifiedUpdateForHost(ctx context.Context, info UpdateInfo, client *http.Client, dir, expectedHost string) (string, error) {
	if _, err := parseLauncherVersion(info.Version); err != nil {
		return "", fmt.Errorf("invalid update version: %w", err)
	}
	assetURL, err := validateUpdateURL(info.AssetURL, expectedHost)
	if err != nil {
		return "", err
	}
	if info.Size <= 0 || info.Size > MaxUpdateSize {
		return "", errors.New("update asset size exceeds allowed size")
	}
	if !sha256Pattern.MatchString(info.SHA256) {
		return "", errors.New("invalid update asset sha256")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("create update directory: %w", err)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, assetURL.String(), nil)
	if err != nil {
		return "", errors.New("create update request failed")
	}
	if client == nil {
		client = http.DefaultClient
	}
	clientCopy := *client
	clientCopy.CheckRedirect = func(*http.Request, []*http.Request) error {
		return errors.New("redirects are not allowed for update downloads")
	}
	response, err := clientCopy.Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		if strings.Contains(strings.ToLower(err.Error()), "redirect") {
			return "", errors.New("redirects are not allowed for update downloads")
		}
		return "", errors.New("download update failed")
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return "", fmt.Errorf("download update returned HTTP status %d", response.StatusCode)
	}
	if response.ContentLength > MaxUpdateSize || (response.ContentLength >= 0 && response.ContentLength != info.Size) {
		return "", errors.New("downloaded update size does not match manifest")
	}
	temporary, err := os.CreateTemp(dir, ".launcher-update-*.tmp")
	if err != nil {
		return "", fmt.Errorf("create temporary update file: %w", err)
	}
	temporaryPath := temporary.Name()
	removeTemporary := true
	defer func() {
		_ = temporary.Close()
		if removeTemporary {
			_ = os.Remove(temporaryPath)
		}
	}()
	hasher := sha256.New()
	limited := io.LimitReader(response.Body, MaxUpdateSize+1)
	count, err := io.Copy(io.MultiWriter(temporary, hasher), limited)
	if err != nil {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		return "", errors.New("read update download failed")
	}
	if count > MaxUpdateSize || count != info.Size {
		return "", errors.New("downloaded update size does not match manifest")
	}
	if !strings.EqualFold(hex.EncodeToString(hasher.Sum(nil)), normalizeSHA256(info.SHA256)) {
		return "", errors.New("downloaded update sha256 does not match manifest")
	}
	if err := temporary.Sync(); err != nil {
		return "", errors.New("flush downloaded update failed")
	}
	if err := temporary.Close(); err != nil {
		return "", errors.New("close downloaded update failed")
	}
	finalPath := filepath.Join(dir, "SchylerAI-Image2-mcp-"+info.Version+".exe")
	if existing, err := os.Open(finalPath); err == nil {
		hasher := sha256.New()
		count, readErr := io.Copy(hasher, io.LimitReader(existing, MaxUpdateSize+1))
		_ = existing.Close()
		if readErr == nil && count == info.Size && strings.EqualFold(hex.EncodeToString(hasher.Sum(nil)), normalizeSHA256(info.SHA256)) {
			return finalPath, nil
		}
		return "", errors.New("verified update already exists with different contents")
	} else if !os.IsNotExist(err) {
		return "", errors.New("inspect existing verified update failed")
	}
	if err := os.Rename(temporaryPath, finalPath); err != nil {
		return "", errors.New("retain verified update failed")
	}
	removeTemporary = false
	return finalPath, nil
}

type launcherVersion struct {
	major uint64
	minor uint64
	patch uint64
}

func parseLauncherVersion(value string) (launcherVersion, error) {
	parts := strings.Split(value, ".")
	if len(parts) != 3 {
		return launcherVersion{}, errors.New("version must be MAJOR.MINOR.PATCH")
	}
	result := launcherVersion{}
	values := []*uint64{&result.major, &result.minor, &result.patch}
	for index, part := range parts {
		if part == "" || (len(part) > 1 && part[0] == '0') {
			return launcherVersion{}, errors.New("version must be MAJOR.MINOR.PATCH")
		}
		parsed, err := strconv.ParseUint(part, 10, 64)
		if err != nil {
			return launcherVersion{}, errors.New("version must be MAJOR.MINOR.PATCH")
		}
		*values[index] = parsed
	}
	return result, nil
}

func compareLauncherVersions(left, right launcherVersion) int {
	for _, pair := range [][2]uint64{{left.major, right.major}, {left.minor, right.minor}, {left.patch, right.patch}} {
		if pair[0] < pair[1] {
			return -1
		}
		if pair[0] > pair[1] {
			return 1
		}
	}
	return 0
}
