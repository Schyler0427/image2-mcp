//go:build ignore

// Run with: go run macos/tests/fixtures/generate-update-golden.go
// This creates local test vectors; it never reads or retains a release key.
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
)

type signingPayload struct {
	Version       string   `json:"version"`
	PublishedAt   string   `json:"published_at"`
	Notes         string   `json:"notes"`
	AssetURL      string   `json:"asset_url"`
	SHA256        string   `json:"sha256"`
	Size          int64    `json:"size"`
	Architectures []string `json:"architectures"`
}

func main() {
	dir := "macos/tests/fixtures"
	asset := []byte("local fixture dmg\n")
	digest := sha256.Sum256(asset)
	payload := signingPayload{
		Version: "1.2.3", PublishedAt: "2026-10-28T00:00:00Z",
		Notes:    "中文 café 😀 <html> & \"quote\" \\slash\n\r\t\b\f\x00\x1f / \u2028 \u2029",
		AssetURL: "https://api.schyler.top/image2/releases/1.2.3/SchylerAI-Image2-mcp-macOS.dmg",
		SHA256:   hex.EncodeToString(digest[:]), Size: int64(len(asset)),
		Architectures: []string{"arm64", "amd64"},
	}
	canonical, err := json.Marshal(payload)
	must(err)
	public, private, err := ed25519.GenerateKey(rand.Reader)
	must(err)
	manifest := struct {
		signingPayload
		Signature string `json:"signature"`
	}{payload, base64.StdEncoding.EncodeToString(ed25519.Sign(private, canonical))}
	encoded, err := json.MarshalIndent(manifest, "", "  ")
	must(err)
	must(os.WriteFile(filepath.Join(dir, "go-update-canonical.json"), canonical, 0644))
	must(os.WriteFile(filepath.Join(dir, "go-update-manifest.json"), append(encoded, '\n'), 0644))
	must(os.WriteFile(filepath.Join(dir, "go-update-public-key.txt"), []byte(base64.StdEncoding.EncodeToString(public)+"\n"), 0644))
	must(os.WriteFile(filepath.Join(dir, "go-update-asset.dmg.fixture"), asset, 0644))
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}
