package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestFetchUpdateManifestDoesNotSendAPIKey(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	var server *httptest.Server
	server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for _, header := range []string{"Authorization", "X-API-Key", "X-OpenAI-API-Key"} {
			if value := r.Header.Get(header); value != "" {
				t.Fatalf("request sent %s header", header)
			}
		}
		manifest := UpdateManifest{
			Version:       "1.2.3",
			PublishedAt:   "2026-10-27T00:00:00Z",
			Notes:         "update",
			AssetURL:      server.URL + "/launcher.exe",
			SHA256:        strings.Repeat("a", 64),
			Size:          1,
			Architectures: []string{"386", "amd64", "arm64"},
		}
		manifest.Signature = base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, canonicalUpdateManifest(manifest)))
		_ = json.NewEncoder(w).Encode(manifest)
	}))
	defer server.Close()

	info, err := fetchUpdateManifest(context.Background(), server.URL, publicKey, "1.2.2", server.Client(), strings.TrimPrefix(server.URL, "https://"))
	if err != nil {
		t.Fatalf("fetchUpdateManifest() error = %v", err)
	}
	if !info.Available || info.Version != "1.2.3" {
		t.Fatalf("unexpected update info: %#v", info)
	}
}

func TestFetchUpdateManifestRejectsOversizedBody(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(strings.Repeat("x", int(maxUpdateManifestSize)+1)))
	}))
	defer server.Close()
	_, err := fetchUpdateManifest(context.Background(), server.URL, make(ed25519.PublicKey, ed25519.PublicKeySize), "1.2.2", server.Client(), strings.TrimPrefix(server.URL, "https://"))
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "too large") {
		t.Fatalf("error = %v, want oversized manifest rejection", err)
	}
}
