package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"strings"
	"testing"
)

func TestUpdateManifestCanonicalGoldenVector(t *testing.T) {
	manifest := UpdateManifest{
		Version:       "1.2.3",
		PublishedAt:   "2026-10-27T00:00:00Z",
		Notes:         "golden",
		AssetURL:      "https://api.schyler.top/image2/releases/1.2.3/SchylerAI-Image2-mcp.exe",
		SHA256:        strings.Repeat("a", 64),
		Size:          123,
		Architectures: []string{"386", "amd64", "arm64"},
	}
	wantCanonical := []byte(`{"version":"1.2.3","published_at":"2026-10-27T00:00:00Z","notes":"golden","asset_url":"https://api.schyler.top/image2/releases/1.2.3/SchylerAI-Image2-mcp.exe","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":123,"architectures":["386","amd64","arm64"]}`)
	if got := canonicalUpdateManifest(manifest); string(got) != string(wantCanonical) {
		t.Fatalf("canonical payload = %s, want %s", got, wantCanonical)
	}
	publicKeyRaw, err := base64.StdEncoding.DecodeString("A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=")
	if err != nil {
		t.Fatal(err)
	}
	signature, err := base64.StdEncoding.DecodeString("GMUyPkTHD4uwQNnULdhHHtO4V4Vv1FrRXHqkgzI4mGf6807BHQmG3Yb5WWSlNwqXb5GDZClRmCwOPOdV/qu7Bg==")
	if err != nil {
		t.Fatal(err)
	}
	if !ed25519.Verify(ed25519.PublicKey(publicKeyRaw), wantCanonical, signature) {
		t.Fatal("golden signature does not verify canonical payload")
	}
}
