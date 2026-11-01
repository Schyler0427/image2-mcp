package main

import (
	"errors"
	"strings"
)

// InstallerCredentials keeps provider credentials separate through redirected stdin.
type InstallerCredentials struct {
	Image2Key string
	GeminiKey string
}

func (credentials InstallerCredentials) Validate() error {
	for _, value := range []struct{ name, key string }{{"Image2", credentials.Image2Key}, {"Gemini", credentials.GeminiKey}} {
		if len(value.key) > 1024 || strings.ContainsAny(value.key, "\r\n\x00") {
			return errors.New(value.name + " API 密钥必须为单行，且不超过 1024 字节")
		}
	}
	if credentials.normalized() == (InstallerCredentials{}) {
		return errors.New("请至少填写一个 API 密钥（Image2 或 Gemini）")
	}
	return nil
}

func (credentials InstallerCredentials) normalized() InstallerCredentials {
	if strings.TrimSpace(credentials.Image2Key) == "" {
		credentials.Image2Key = ""
	}
	if strings.TrimSpace(credentials.GeminiKey) == "" {
		credentials.GeminiKey = ""
	}
	return credentials
}

func (credentials InstallerCredentials) Stdin() string {
	credentials = credentials.normalized()
	return credentials.Image2Key + "\n" + credentials.GeminiKey + "\n"
}

func (credentials InstallerCredentials) Secrets() []string {
	credentials = credentials.normalized()
	return []string{credentials.Image2Key, credentials.GeminiKey}
}
