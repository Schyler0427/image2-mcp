package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"strings"
	"testing"
)

func TestPublisherCanonicalGolden(t *testing.T) {
	manifest := updateManifest{
		Version: "1.2.3", PublishedAt: "2026-10-27T00:00:00Z", Notes: "golden",
		AssetURL: "https://api.schyler.top/image2/releases/1.2.3/SchylerAI-Image2-mcp.exe",
		SHA256:   strings.Repeat("a", 64), Size: 123, Architectures: []string{"386", "amd64", "arm64"},
		Signature: "not-in-signing-payload",
	}
	want := `{"version":"1.2.3","published_at":"2026-10-27T00:00:00Z","notes":"golden","asset_url":"https://api.schyler.top/image2/releases/1.2.3/SchylerAI-Image2-mcp.exe","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":123,"architectures":["386","amd64","arm64"]}`
	if got := string(canonical(manifest)); got != want {
		t.Fatalf("publisher canonical payload = %s, want %s", got, want)
	}
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i)
	}
	key := ed25519.NewKeyFromSeed(seed)
	wantSignature := "GMUyPkTHD4uwQNnULdhHHtO4V4Vv1FrRXHqkgzI4mGf6807BHQmG3Yb5WWSlNwqXb5GDZClRmCwOPOdV/qu7Bg=="
	if got := base64.StdEncoding.EncodeToString(ed25519.Sign(key, canonical(manifest))); got != wantSignature {
		t.Fatalf("publisher signature = %s, want golden signature", got)
	}
}

func TestPublisherRequiresMatchingTrustedKey(t *testing.T) {
	key := ed25519.NewKeyFromSeed(make([]byte, ed25519.SeedSize))
	public := base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey))
	if err := requireMatchingPublicKey(key, public); err != nil {
		t.Fatalf("matching key rejected: %v", err)
	}
	for _, wrong := range []string{"invalid", base64.StdEncoding.EncodeToString(make([]byte, ed25519.PublicKeySize))} {
		if err := requireMatchingPublicKey(key, wrong); err == nil {
			t.Fatal("invalid or mismatched release key accepted")
		}
	}
}
