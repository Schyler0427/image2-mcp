package main

import (
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

const maxUpdateManifestSize int64 = 128 << 10

var launcherUpdateHTTPClient = &http.Client{Timeout: 20 * time.Second}
var launcherUpdateDownloadHTTPClient = &http.Client{Timeout: 5 * time.Minute}

// CheckLatestUpdate fetches only the signed launcher manifest. It does not
// read, send, or otherwise depend on the Image2 API key.
func CheckLatestUpdate(ctx context.Context, current string) (UpdateInfo, error) {
	return fetchUpdateManifest(ctx, UpdateManifestURL, UpdatePublicKey, current, launcherUpdateHTTPClient, UpdateManifestHost)
}

func fetchUpdateManifest(ctx context.Context, endpoint string, publicKey ed25519.PublicKey, current string, client *http.Client, expectedHost string) (UpdateInfo, error) {
	if endpoint == "" {
		return UpdateInfo{}, errors.New("update manifest endpoint is required")
	}
	if _, err := validateUpdateURL(endpoint, expectedHost); err != nil {
		return UpdateInfo{}, errors.New("update manifest endpoint is not trusted")
	}
	if client == nil {
		client = http.DefaultClient
	}
	clientCopy := *client
	clientCopy.CheckRedirect = func(*http.Request, []*http.Request) error {
		return errors.New("redirects are not allowed for update manifest")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return UpdateInfo{}, errors.New("create update manifest request failed")
	}
	response, err := clientCopy.Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return UpdateInfo{}, ctx.Err()
		}
		return UpdateInfo{}, errors.New("fetch update manifest failed")
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return UpdateInfo{}, fmt.Errorf("update manifest returned HTTP status %d", response.StatusCode)
	}
	if response.ContentLength > maxUpdateManifestSize {
		return UpdateInfo{}, errors.New("update manifest is too large")
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, maxUpdateManifestSize+1))
	if err != nil {
		if ctx.Err() != nil {
			return UpdateInfo{}, ctx.Err()
		}
		return UpdateInfo{}, errors.New("read update manifest failed")
	}
	if int64(len(raw)) > maxUpdateManifestSize {
		return UpdateInfo{}, errors.New("update manifest is too large")
	}
	return verifyUpdateManifestForHost(raw, publicKey, current, expectedHost)
}

func embeddedVersion() (string, error) {
	data, err := readEmbeddedFile(embeddedVersionPath, 128)
	if err != nil {
		return "", err
	}
	version := strings.TrimSpace(string(data))
	if _, err := parseLauncherVersion(version); err != nil {
		return "", fmt.Errorf("embedded launcher version: %w", err)
	}
	return version, nil
}
