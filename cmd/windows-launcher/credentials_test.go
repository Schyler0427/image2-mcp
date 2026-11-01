package main

import (
	"strings"
	"testing"
)

func TestInstallerCredentialsAcceptEitherProviderAndKeepTwoStdinLines(t *testing.T) {
	for _, test := range []struct {
		name        string
		credentials InstallerCredentials
		wantStdin   string
	}{
		{"both", InstallerCredentials{Image2Key: "image2-secret", GeminiKey: "gemini-secret"}, "image2-secret\ngemini-secret\n"},
		{"image2 only", InstallerCredentials{Image2Key: "image2-secret"}, "image2-secret\n\n"},
		{"gemini only", InstallerCredentials{GeminiKey: "gemini-secret"}, "\ngemini-secret\n"},
		{"blank image2", InstallerCredentials{Image2Key: " \t\u3000", GeminiKey: "gemini-secret"}, "\ngemini-secret\n"},
		{"blank gemini", InstallerCredentials{Image2Key: "image2-secret", GeminiKey: " \t\u3000"}, "image2-secret\n\n"},
		{"nonblank bytes preserved", InstallerCredentials{Image2Key: " image2-secret ", GeminiKey: " gemini-secret "}, " image2-secret \n gemini-secret \n"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if err := test.credentials.Validate(); err != nil {
				t.Fatal(err)
			}
			if got := test.credentials.Stdin(); got != test.wantStdin {
				t.Fatalf("stdin = %q, want %q", got, test.wantStdin)
			}
		})
	}
}

func TestInstallerCredentialsRejectMissingOrInvalidKeys(t *testing.T) {
	for _, test := range []InstallerCredentials{
		{}, {Image2Key: " \t", GeminiKey: "\u3000 "},
		{Image2Key: "secret\nother", GeminiKey: "gemini"},
		{Image2Key: "image2", GeminiKey: strings.Repeat("x", 1025)},
		{Image2Key: "image2", GeminiKey: "bad\x00key"},
		{Image2Key: "bad\rkey"}, {GeminiKey: "bad\nkey"},
		{Image2Key: "\n", GeminiKey: "gemini"}, {Image2Key: "image2", GeminiKey: "\r"},
		{Image2Key: " \x00 ", GeminiKey: "gemini"},
		{Image2Key: strings.Repeat("密", 342)},
		{Image2Key: "image2", GeminiKey: strings.Repeat(" ", 1025)},
	} {
		if err := test.Validate(); err == nil {
			t.Fatalf("invalid credentials accepted")
		}
	}
}

func TestInstallerCredentialErrorsAreChineseAndNeverIncludeKeys(t *testing.T) {
	for _, test := range []struct {
		credentials InstallerCredentials
		want        string
	}{
		{InstallerCredentials{}, "请至少填写一个 API 密钥（Image2 或 Gemini）"},
		{InstallerCredentials{Image2Key: "secret\nkey"}, "Image2 API 密钥必须为单行，且不超过 1024 字节"},
		{InstallerCredentials{GeminiKey: "secret\x00key"}, "Gemini API 密钥必须为单行，且不超过 1024 字节"},
	} {
		if err := test.credentials.Validate(); err == nil || err.Error() != test.want {
			t.Fatalf("validation error = %v, want %q", err, test.want)
		}
	}
}

func TestInstallerSecretsTreatWhitespaceOnlyKeysAsEmpty(t *testing.T) {
	credentials := InstallerCredentials{Image2Key: " \t", GeminiKey: "gemini-secret"}
	secrets := credentials.Secrets()
	if len(secrets) != 2 || secrets[0] != "" || secrets[1] != "gemini-secret" {
		t.Fatal("secrets did not preserve provider slots or normalize the blank key")
	}
	var output strings.Builder
	writer := newInstallerOutputWriter(secrets, func(value string) { output.WriteString(value) })
	writer.Write([]byte("normal whitespace:  \t gemini-secret\n"))
	if got := output.String(); got != "normal whitespace:  \t [redacted]" {
		t.Fatalf("redacted output = %q", got)
	}
}

func TestInstallerOutputRedactsBothCredentialBoundaries(t *testing.T) {
	credentials := InstallerCredentials{Image2Key: "image2-secret", GeminiKey: "gemini-secret"}
	var output strings.Builder
	writer := newInstallerOutputWriter(credentials.Secrets(), func(value string) { output.WriteString(value) })
	writer.Write([]byte(strings.Repeat("x", maxInstallerPendingBytes) + "image2-"))
	writer.Write([]byte("secret then gemini-"))
	writer.Write([]byte("secret\n"))
	got := output.String()
	for _, secret := range credentials.Secrets() {
		if strings.Contains(got, secret) {
			t.Fatalf("output leaked a credential")
		}
	}
	if strings.Count(got, "[redacted]") != 2 {
		t.Fatalf("redaction markers missing")
	}
}

func TestInstallerOutputRedactsOverlappingCredentials(t *testing.T) {
	var output strings.Builder
	writer := newInstallerOutputWriter([]string{"prefix", "prefix-tail"}, func(value string) { output.WriteString(value) })
	writer.Write([]byte("prefix prefix-tail\n"))
	if output.String() != "[redacted] [redacted]" {
		t.Fatal("overlapping credentials were only partly redacted")
	}
}
