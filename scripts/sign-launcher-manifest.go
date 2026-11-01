package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

type updateManifest struct {
	Version       string   `json:"version"`
	PublishedAt   string   `json:"published_at"`
	Notes         string   `json:"notes"`
	AssetURL      string   `json:"asset_url"`
	SHA256        string   `json:"sha256"`
	Size          int64    `json:"size"`
	Signature     string   `json:"signature"`
	Architectures []string `json:"architectures"`
}

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
	keyPath := flag.String("key", "", "PKCS#8 Ed25519 private key PEM")
	publicKey := flag.String("public-key", "", "expected trusted Ed25519 public key in standard base64")
	inputPath := flag.String("input", "", "unsigned manifest JSON")
	outputPath := flag.String("output", "", "signed manifest JSON")
	flag.Parse()
	if *keyPath == "" || *inputPath == "" || *outputPath == "" {
		fatal(errors.New("-key, -input, and -output are required"))
	}

	manifestBytes, err := os.ReadFile(*inputPath)
	if err != nil {
		fatal(fmt.Errorf("read manifest: %w", err))
	}
	var manifest updateManifest
	decoder := json.NewDecoder(bytes.NewReader(manifestBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&manifest); err != nil {
		fatal(fmt.Errorf("decode manifest: %w", err))
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		fatal(errors.New("manifest has trailing JSON"))
	}
	manifest.Signature = ""
	keyBytes, err := os.ReadFile(*keyPath)
	if err != nil {
		fatal(fmt.Errorf("read signing key: %w", err))
	}
	block, _ := pem.Decode(keyBytes)
	if block == nil {
		fatal(errors.New("signing key is not PEM"))
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		fatal(fmt.Errorf("parse signing key: %w", err))
	}
	private, ok := parsed.(ed25519.PrivateKey)
	if !ok {
		fatal(errors.New("signing key is not Ed25519"))
	}
	if *publicKey != "" {
		if err := requireMatchingPublicKey(private, *publicKey); err != nil {
			fatal(err)
		}
	}
	manifest.Signature = base64.StdEncoding.EncodeToString(ed25519.Sign(private, canonical(manifest)))
	output, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		fatal(fmt.Errorf("encode signed manifest: %w", err))
	}
	output = append(output, '\n')
	if err := writeAtomic(*outputPath, output); err != nil {
		fatal(err)
	}
}

func requireMatchingPublicKey(private ed25519.PrivateKey, expected string) error {
	publicKey, err := base64.StdEncoding.DecodeString(expected)
	if err != nil || len(publicKey) != ed25519.PublicKeySize {
		return errors.New("expected release public key is invalid")
	}
	if !bytes.Equal(private.Public().(ed25519.PublicKey), publicKey) {
		return errors.New("signing key does not match launcher trusted public key")
	}
	return nil
}

func canonical(manifest updateManifest) []byte {
	payload := signingPayload{
		Version: manifest.Version, PublishedAt: manifest.PublishedAt, Notes: manifest.Notes,
		AssetURL: manifest.AssetURL, SHA256: manifest.SHA256, Size: manifest.Size,
		Architectures: manifest.Architectures,
	}
	encoded, _ := json.Marshal(payload)
	return encoded
}

func writeAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create output directory: %w", err)
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".launcher-manifest-*.tmp")
	if err != nil {
		return fmt.Errorf("create output file: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o644); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("set output permissions: %w", err)
	}
	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("write output: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("flush output: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close output: %w", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("replace output: %w", err)
	}
	return nil
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
