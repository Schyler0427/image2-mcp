package main

import (
	"context"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode"
)

func TestWin32ControlsUseChineseLabelsAndExplainOptionalKeys(t *testing.T) {
	file, err := parser.ParseFile(token.NewFileSet(), "gui_windows.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	optionalLabels := 0
	hasAtLeastOneHint := false
	ast.Inspect(file, func(node ast.Node) bool {
		call, ok := node.(*ast.CallExpr)
		if !ok {
			return true
		}
		selector, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || selector.Sel.Name != "createControl" || len(call.Args) < 2 {
			return true
		}
		label, ok := call.Args[1].(*ast.BasicLit)
		if !ok || label.Kind != token.STRING {
			return true
		}
		text, err := strconv.Unquote(label.Value)
		if err != nil || text == "" {
			return true
		}
		if !strings.ContainsFunc(text, func(value rune) bool { return unicode.Is(unicode.Han, value) }) {
			t.Errorf("control text has no Chinese label: %q", text)
		}
		if strings.Contains(text, "选填") {
			optionalLabels++
		}
		if strings.Contains(text, "至少填写一个") {
			hasAtLeastOneHint = true
		}
		return true
	})
	if optionalLabels != 2 || !hasAtLeastOneHint {
		t.Fatalf("optional field labels = %d, at-least-one hint = %t", optionalLabels, hasAtLeastOneHint)
	}
}

func TestLauncherInstallerStatusIsChineseWithoutRawDiagnostics(t *testing.T) {
	for _, test := range []struct{ input, want string }{
		{"Preparing installation...", "正在准备安装…"},
		{"Installing platform binary...", "正在安装平台程序…"},
		{"Verifying local installation...", "正在验证本地安装…"},
		{"Verification: OK", "本地安装验证通过。"},
		{"Retained transaction evidence: C:\\private\\secret", "已保留安装事务记录，供排查问题。"},
		{"arbitrary PowerShell exception with a secret", "正在安装，请稍候…"},
	} {
		if got := launcherInstallerStatus(test.input); got != test.want {
			t.Fatalf("installer status = %q, want %q", got, test.want)
		}
	}
}

func TestLauncherOperationErrorsAreChineseAndHideUnknownDiagnostics(t *testing.T) {
	for _, test := range []struct {
		err  error
		want string
	}{
		{context.Canceled, "操作已取消。"},
		{context.DeadlineExceeded, "操作超时，请重试。"},
		{errors.New(installerFailureMessage(23)), "安装失败（退出代码 23）"},
		{errors.New("启动安装程序失败"), "启动安装程序失败"},
		{errors.New("diagnostic with private-token"), "操作失败，请重试。"},
	} {
		if got := launcherOperationError(test.err); got != test.want {
			t.Fatalf("operation error = %q, want %q", got, test.want)
		}
	}
}

func TestArchitectureFromProcessorArchitecture(t *testing.T) {
	tests := []struct {
		name   string
		value  uint16
		want   string
		wantOK bool
	}{
		{name: "x86", value: 0, want: "386", wantOK: true},
		{name: "amd64", value: 9, want: "amd64", wantOK: true},
		{name: "arm64", value: 12, want: "arm64", wantOK: true},
		{name: "unknown", value: 0xffff, wantOK: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := architectureFromProcessorArchitecture(tt.value)
			if (err == nil) != tt.wantOK {
				t.Fatalf("architectureFromProcessorArchitecture(%d) error = %v, want success %t", tt.value, err, tt.wantOK)
			}
			if err == nil && got != tt.want {
				t.Fatalf("architectureFromProcessorArchitecture(%d) = %q, want %q", tt.value, got, tt.want)
			}
		})
	}
}

func TestRedactInstallerOutputRemovesSecret(t *testing.T) {
	secret := "sk-image2-test-secret"
	output := "installer accepted " + secret + " and wrote configuration"
	redacted := redactInstallerOutput(output, secret)
	if strings.Contains(redacted, secret) {
		t.Fatalf("redacted output contains secret: %q", redacted)
	}
	if !strings.Contains(redacted, "[redacted]") {
		t.Fatalf("redacted output = %q, want marker", redacted)
	}
}

func TestInstallerFailureMessageIncludesExitCodeWithoutDiagnostics(t *testing.T) {
	got := installerFailureMessage(17)
	if got != "安装失败（退出代码 17）" {
		t.Fatalf("installerFailureMessage() = %q", got)
	}
}

func TestInstallerOutputWriterCallbackMayReenter(t *testing.T) {
	var writer *installerOutputWriter
	var once sync.Once
	done := make(chan struct{})
	writer = newInstallerOutputWriter([]string{"secret"}, func(string) {
		once.Do(func() {
			writer.Flush()
			close(done)
		})
	})
	if _, err := writer.Write([]byte("first\n")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("callback deadlocked while re-entering Flush")
	}
}

func TestInstallerOutputWriterRedactsBoundaryWithoutLeak(t *testing.T) {
	secret := "secret-key"
	var output strings.Builder
	writer := newInstallerOutputWriter([]string{secret}, func(value string) { _, _ = output.WriteString(value) })
	large := strings.Repeat("x", maxInstallerPendingBytes)
	if _, err := writer.Write([]byte(large + "secret")); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte("-key\n")); err != nil {
		t.Fatal(err)
	}
	writer.Flush()
	if strings.Contains(output.String(), secret) {
		t.Fatalf("output leaked boundary secret: %q", output.String())
	}
}
