package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type signedManifestFixture struct {
	manifest  UpdateManifest
	publicKey ed25519.PublicKey
}

func newSignedManifestFixture(t *testing.T, assetURL string, version string) signedManifestFixture {
	t.Helper()
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate signing key: %v", err)
	}
	manifest := UpdateManifest{
		Version:       version,
		PublishedAt:   "2026-10-27T00:00:00Z",
		Notes:         "security fixes",
		AssetURL:      assetURL,
		SHA256:        strings.Repeat("a", sha256.Size*2),
		Size:          1,
		Architectures: []string{"386", "amd64", "arm64"},
	}
	manifest.Signature = base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, canonicalUpdateManifest(manifest)))
	return signedManifestFixture{manifest: manifest, publicKey: publicKey}
}

func mustManifestJSON(t *testing.T, manifest UpdateManifest) []byte {
	t.Helper()
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatalf("marshal manifest: %v", err)
	}
	return raw
}

func TestVerifyUpdateManifestAcceptsValidSignature(t *testing.T) {
	fixture := newSignedManifestFixture(t, "https://updates.example.test/releases/1.2.3/SchylerAI-Image2-mcp.exe", "1.2.3")

	got, err := verifyUpdateManifestForHost(mustManifestJSON(t, fixture.manifest), fixture.publicKey, "1.2.2", "updates.example.test")
	if err != nil {
		t.Fatalf("VerifyUpdateManifest() error = %v", err)
	}
	if !got.Available || got.Version != "1.2.3" || got.AssetURL != fixture.manifest.AssetURL {
		t.Fatalf("update info = %#v", got)
	}
}

func TestVerifyUpdateManifestEqualVersionIsNoUpdate(t *testing.T) {
	fixture := newSignedManifestFixture(t, "https://updates.example.test/releases/1.2.3/update.exe", "1.2.3")

	got, err := verifyUpdateManifestForHost(mustManifestJSON(t, fixture.manifest), fixture.publicKey, "1.2.3", "updates.example.test")
	if err != nil {
		t.Fatalf("VerifyUpdateManifest() error = %v", err)
	}
	if got.Available {
		t.Fatalf("equal version marked available: %#v", got)
	}
}

func TestVerifyUpdateManifestRejectsInvalidInputs(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*UpdateManifest)
		input  []byte
		want   string
	}{
		{name: "malformed json", input: []byte(`{"version":`), want: "manifest"},
		{name: "malformed version", mutate: func(m *UpdateManifest) { m.Version = "1.2" }, want: "version"},
		{name: "downgrade", mutate: func(m *UpdateManifest) { m.Version = "1.2.1" }, want: "older"},
		{name: "http url", mutate: func(m *UpdateManifest) { m.AssetURL = "http://updates.example.test/update.exe" }, want: "https"},
		{name: "wrong host", mutate: func(m *UpdateManifest) { m.AssetURL = "https://evil.example.test/update.exe" }, want: "host"},
		{name: "oversized", mutate: func(m *UpdateManifest) { m.Size = MaxUpdateSize + 1 }, want: "size"},
		{name: "unsupported architecture", mutate: func(m *UpdateManifest) { m.Architectures = []string{"mips64"} }, want: "architecture"},
		{name: "bad signature", mutate: func(m *UpdateManifest) { m.Signature = base64.StdEncoding.EncodeToString([]byte("bad")) }, want: "signature"},
		{name: "hash", mutate: func(m *UpdateManifest) { m.SHA256 = "short" }, want: "sha256"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var raw []byte
			var key ed25519.PublicKey
			if tt.input != nil {
				raw = tt.input
			} else {
				fixture := newSignedManifestFixture(t, "https://updates.example.test/update.exe", "1.2.3")
				if tt.mutate != nil {
					tt.mutate(&fixture.manifest)
				}
				key = fixture.publicKey
				if tt.name != "bad signature" {
					publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
					if err != nil {
						t.Fatal(err)
					}
					key = publicKey
					fixture.manifest.Signature = base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, canonicalUpdateManifest(fixture.manifest)))
				}
				raw = mustManifestJSON(t, fixture.manifest)
			}
			_, err := verifyUpdateManifestForHost(raw, key, "1.2.2", "updates.example.test")
			if err == nil || !strings.Contains(strings.ToLower(err.Error()), tt.want) {
				t.Fatalf("error = %v, want substring %q", err, tt.want)
			}
		})
	}
}

func TestVerifyUpdateManifestRejectsCredentialURL(t *testing.T) {
	fixture := newSignedManifestFixture(t, "https://user:secret@updates.example.test/update.exe", "1.2.3")
	_, err := verifyUpdateManifestForHost(mustManifestJSON(t, fixture.manifest), fixture.publicKey, "1.2.2", "updates.example.test")
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "url") {
		t.Fatalf("error = %v, want credential URL rejection", err)
	}
	if strings.Contains(err.Error(), "secret") {
		t.Fatalf("error leaked URL credentials: %v", err)
	}
}

func TestDownloadVerifiedUpdateAcceptsExpectedAsset(t *testing.T) {
	payload := []byte("verified launcher")
	hash := sha256.Sum256(payload)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/update.exe" {
			t.Fatalf("request path = %q", r.URL.Path)
		}
		_, _ = w.Write(payload)
	}))
	defer server.Close()
	info := UpdateInfo{Version: "1.2.3", AssetURL: server.URL + "/update.exe", SHA256: hex.EncodeToString(hash[:]), Size: int64(len(payload))}
	dir := t.TempDir()
	client := server.Client()
	path, err := downloadVerifiedUpdateForHost(context.Background(), info, client, dir, strings.TrimPrefix(server.URL, "https://"))
	if err != nil {
		t.Fatalf("DownloadVerifiedUpdate() error = %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read retained update: %v", err)
	}
	if string(got) != string(payload) || filepath.Ext(path) != ".exe" {
		t.Fatalf("retained update = %q at %q", got, path)
	}
	second, err := downloadVerifiedUpdateForHost(context.Background(), info, client, dir, strings.TrimPrefix(server.URL, "https://"))
	if err != nil || second != path {
		t.Fatalf("reusing verified update = %q, %v; want %q", second, err, path)
	}
}

func TestDownloadVerifiedUpdateRejectsRedirect(t *testing.T) {
	payload := []byte("redirected launcher")
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/update.exe" {
			http.Redirect(w, r, "/other.exe", http.StatusFound)
			return
		}
		_, _ = w.Write(payload)
	}))
	defer server.Close()
	hash := sha256.Sum256(payload)
	_, err := downloadVerifiedUpdateForHost(context.Background(), UpdateInfo{Version: "1.2.3", AssetURL: server.URL + "/update.exe", SHA256: hex.EncodeToString(hash[:]), Size: int64(len(payload))}, server.Client(), t.TempDir(), strings.TrimPrefix(server.URL, "https://"))
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "redirect") {
		t.Fatalf("error = %v, want redirect rejection", err)
	}
}

func TestDownloadVerifiedUpdateRejectsSizeAndHashMismatch(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "wrong payload")
	}))
	defer server.Close()
	tests := []struct {
		name string
		info UpdateInfo
		want string
	}{
		{name: "size", info: UpdateInfo{Version: "1.2.3", AssetURL: server.URL + "/update.exe", SHA256: strings.Repeat("a", 64), Size: 100}, want: "size"},
		{name: "hash", info: UpdateInfo{Version: "1.2.3", AssetURL: server.URL + "/update.exe", SHA256: strings.Repeat("a", 64), Size: int64(len("wrong payload"))}, want: "sha256"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := downloadVerifiedUpdateForHost(context.Background(), tt.info, server.Client(), t.TempDir(), strings.TrimPrefix(server.URL, "https://"))
			if err == nil || !strings.Contains(strings.ToLower(err.Error()), tt.want) {
				t.Fatalf("error = %v, want substring %q", err, tt.want)
			}
		})
	}
}

func TestDownloadVerifiedUpdateHonorsCancellation(t *testing.T) {
	started := make(chan struct{})
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-r.Context().Done()
	}))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := downloadVerifiedUpdateForHost(ctx, UpdateInfo{Version: "1.2.3", AssetURL: server.URL + "/update.exe", SHA256: strings.Repeat("a", 64), Size: 1}, server.Client(), t.TempDir(), strings.TrimPrefix(server.URL, "https://"))
		done <- err
	}()
	select {
	case <-started:
		cancel()
	case <-time.After(2 * time.Second):
		t.Fatal("download did not start")
	}
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("error = %v, want context.Canceled", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("canceled download did not return")
	}
}

func TestDownloadVerifiedUpdateRejectsInsecureOrCrossHostURL(t *testing.T) {
	for _, url := range []string{"http://updates.example.test/update.exe", "https://evil.example.test/update.exe"} {
		_, err := downloadVerifiedUpdateForHost(context.Background(), UpdateInfo{Version: "1.2.3", AssetURL: url, SHA256: strings.Repeat("a", 64), Size: 1}, http.DefaultClient, t.TempDir(), "updates.example.test")
		if err == nil {
			t.Fatalf("URL %q unexpectedly accepted", url)
		}
	}
}

func TestDownloadVerifiedUpdateRejectsOversizedResponse(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "10")
		_, _ = io.WriteString(w, "tiny")
	}))
	defer server.Close()
	_, err := downloadVerifiedUpdateForHost(context.Background(), UpdateInfo{Version: "1.2.3", AssetURL: server.URL + "/update.exe", SHA256: strings.Repeat("a", 64), Size: MaxUpdateSize + 1}, server.Client(), t.TempDir(), strings.TrimPrefix(server.URL, "https://"))
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "size") {
		t.Fatalf("error = %v, want oversized rejection", err)
	}
}

func TestProductionUpdateKeyIsNotThePublishedRFC8032TestVector(t *testing.T) {
	knownPublicKey, err := base64.StdEncoding.DecodeString("11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=")
	if err != nil {
		t.Fatal(err)
	}
	if string(UpdatePublicKey) == string(knownPublicKey) {
		t.Fatal("production update key is a publicly known RFC 8032 test vector")
	}
	if got := hex.EncodeToString(UpdatePublicKey); got != "868640cc1344b63e30f803156d858244a6293b26e2dd8d1e9207e40c13642152" {
		t.Fatalf("unexpected production update key fingerprint: %s", got)
	}
}
