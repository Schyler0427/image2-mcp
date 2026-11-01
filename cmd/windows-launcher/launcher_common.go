package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"sync"
)

const (
	processorArchitectureX86   uint16 = 0
	processorArchitectureARM   uint16 = 5
	processorArchitectureAMD64 uint16 = 9
	processorArchitectureARM64 uint16 = 12
)

// LauncherCallbacks keeps the Win32 shell independent from payload extraction
// and signed update handoff. Task 3/4 provide these callbacks from main.
type LauncherCallbacks struct {
	Install     func(context.Context, InstallerCredentials, func(string)) error
	CheckUpdate func(context.Context) (UpdateInfo, error)
	ApplyUpdate func(context.Context, UpdateInfo) error
}

func architectureFromProcessorArchitecture(value uint16) (string, error) {
	switch value {
	case processorArchitectureX86:
		return "386", nil
	case processorArchitectureAMD64:
		return "amd64", nil
	case processorArchitectureARM64:
		return "arm64", nil
	default:
		return "", fmt.Errorf("unsupported native Windows processor architecture %d", value)
	}
}

func redactInstallerOutput(output, secret string) string {
	if secret == "" {
		return output
	}
	return strings.ReplaceAll(output, secret, "[redacted]")
}

func installerFailureMessage(exitCode int) string {
	return fmt.Sprintf("安装失败（退出代码 %d）", exitCode)
}

const maxInstallerPendingBytes = 1024 * 1024

// installerOutputWriter keeps pipe writes bounded and redacts secrets across
// arbitrary write boundaries. It never calls onOutput while holding mu, so a
// callback may safely re-enter Flush or Write.
type installerOutputWriter struct {
	mu       sync.Mutex
	secrets  []string
	redactor *strings.Replacer
	pending  string
	onOutput func(string)
}

func newInstallerOutputWriter(secrets []string, onOutput func(string)) *installerOutputWriter {
	if onOutput == nil {
		onOutput = func(string) {}
	}
	secrets = append([]string(nil), secrets...)
	sort.SliceStable(secrets, func(left, right int) bool { return len(secrets[left]) > len(secrets[right]) })
	replacements := make([]string, 0, 2*len(secrets))
	for _, secret := range secrets {
		if secret != "" {
			replacements = append(replacements, secret, "[redacted]")
		}
	}
	return &installerOutputWriter{secrets: secrets, redactor: strings.NewReplacer(replacements...), onOutput: onOutput}
}

func (writer *installerOutputWriter) Write(data []byte) (int, error) {
	writer.mu.Lock()
	writer.pending += string(data)
	values := writer.takeCompleteLinesLocked()
	writer.mu.Unlock()
	writer.emitAll(values)
	return len(data), nil
}

func (writer *installerOutputWriter) Flush() {
	// Pending output has no newline boundary. Dropping it keeps cancellation
	// teardown independent of an arbitrary callback's behavior.
	writer.Discard()
}

// Discard drops pending output without invoking a callback. It is used after
// cancellation or os/exec's WaitDelay expires to keep teardown bounded.
func (writer *installerOutputWriter) Discard() {
	writer.mu.Lock()
	writer.pending = ""
	writer.mu.Unlock()
}

func (writer *installerOutputWriter) takeCompleteLinesLocked() []string {
	values := make([]string, 0, 1)
	for {
		index := strings.IndexByte(writer.pending, '\n')
		if index < 0 {
			break
		}
		line := strings.TrimSuffix(writer.pending[:index], "\r")
		writer.pending = writer.pending[index+1:]
		values = append(values, line)
	}
	if len(writer.pending) >= maxInstallerPendingBytes {
		cut := writer.safePendingCutLocked()
		if cut > 0 {
			values = append(values, writer.pending[:cut])
			writer.pending = writer.pending[cut:]
		}
	}
	return values
}

func (writer *installerOutputWriter) safePendingCutLocked() int {
	keep := 0
	for _, secret := range writer.secrets {
		if len(secret) > keep {
			keep = len(secret)
		}
	}
	if keep < 1 {
		keep = 1
	}
	if keep >= len(writer.pending) {
		return 0
	}
	cut := len(writer.pending) - keep
	// Do not split a suffix that could be the beginning of the secret. The
	// retained overlap is then joined with future writes before redaction.
	for cut > 0 {
		overlap := 0
		for _, secret := range writer.secrets {
			if n := longestSecretPrefixSuffix(writer.pending[:cut], secret); n > overlap {
				overlap = n
			}
		}
		if overlap == 0 {
			break
		}
		cut -= overlap
	}
	return cut
}

func longestSecretPrefixSuffix(value, secret string) int {
	limit := len(secret) - 1
	if limit > len(value) {
		limit = len(value)
	}
	for size := limit; size > 0; size-- {
		if strings.HasSuffix(value, secret[:size]) {
			return size
		}
	}
	return 0
}

func (writer *installerOutputWriter) emitAll(values []string) {
	for _, value := range values {
		value = writer.redactor.Replace(value)
		if value != "" {
			writer.onOutput(value)
		}
	}
}

var _ io.Writer = (*installerOutputWriter)(nil)

var errInstallerCallbacksUnavailable = errors.New("launcher installer is unavailable")
