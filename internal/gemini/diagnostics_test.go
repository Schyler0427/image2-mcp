package gemini

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func diagnosticForTest(t *testing.T, reason string, body []byte) ([]byte, map[string]any) {
	t.Helper()
	dir := t.TempDir()
	c, err := New("private-key", "https://example.test", "model", dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	_ = c.responseError(reason, body, http.Header{}, 200, dir, "private prompt")
	paths, err := filepath.Glob(filepath.Join(dir, "gemini-response-*.json"))
	if err != nil || len(paths) != 1 {
		t.Fatalf("diagnostics=%v error=%v", paths, err)
	}
	data, err := os.ReadFile(paths[0])
	if err != nil {
		t.Fatal(err)
	}
	var parsed map[string]any
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("invalid diagnostic JSON: %v", err)
	}
	return data, parsed
}

func shapeStats(value any) (nodes, depth, maxMembers int) {
	nodes, depth = 1, 1
	visit := func(item any) {
		n, d, m := shapeStats(item)
		nodes += n
		depth = max(depth, d+1)
		maxMembers = max(maxMembers, m)
	}
	switch v := value.(type) {
	case map[string]any:
		maxMembers = len(v)
		for _, item := range v {
			visit(item)
		}
	case []any:
		maxMembers = len(v)
		for _, item := range v {
			visit(item)
		}
	}
	return
}

func TestDiagnosticBoundsDeepSmallInput(t *testing.T) {
	body := []byte(`{"details":` + strings.Repeat("[", 2200) + "0" + strings.Repeat("]", 2200) + "}")
	data, parsed := diagnosticForTest(t, "no image", body)
	_, depth, _ := shapeStats(parsed["response_structure"])
	t.Logf("input=%d bytes diagnostic=%d bytes shape depth=%d", len(body), len(data), depth)
	if len(data) > 256<<10 || depth > 16 {
		t.Fatalf("unbounded diagnostic: bytes=%d depth=%d", len(data), depth)
	}
	if !strings.Contains(string(data), "truncated") {
		t.Fatal("diagnostic missing truncation marker")
	}
}

func TestDiagnosticBoundsWideContainers(t *testing.T) {
	t.Run("array", func(t *testing.T) {
		data, parsed := diagnosticForTest(t, "no image", []byte(`{"details":[`+strings.Repeat("0,", 4095)+"0]}"))
		_, _, members := shapeStats(parsed["response_structure"])
		if members > 64 || !strings.Contains(string(data), "truncated") {
			t.Fatalf("wide array was not truncated: members=%d bytes=%d", members, len(data))
		}
	})
	t.Run("object", func(t *testing.T) {
		fields := make([]string, 1000)
		for i := range fields {
			fields[i] = fmt.Sprintf(`"private-key-%d":"private prompt"`, i)
		}
		data, parsed := diagnosticForTest(t, "no image", []byte("{"+strings.Join(fields, ",")+"}"))
		_, _, members := shapeStats(parsed["response_structure"])
		if members > 64 || !strings.Contains(string(data), "truncated") {
			t.Fatalf("wide object was not truncated: members=%d bytes=%d", members, len(data))
		}
		if strings.Contains(string(data), "private-key") || strings.Contains(string(data), "private prompt") {
			t.Fatal("wide diagnostic leaked private keys or string values")
		}
	})
}

func TestDiagnosticBoundsTotalShapeNodes(t *testing.T) {
	row := "[" + strings.Repeat("0,", 63) + "0]"
	body := []byte(`{"details":[` + strings.Repeat(row+",", 63) + row + "]}")
	data, parsed := diagnosticForTest(t, "no image", body)
	nodes, _, _ := shapeStats(parsed["response_structure"])
	if nodes > 2048 || !strings.Contains(string(data), "truncated") {
		t.Fatalf("total shape nodes unbounded: nodes=%d bytes=%d", nodes, len(data))
	}
}

func TestDiagnosticFileHasIndependentByteLimit(t *testing.T) {
	data, _ := diagnosticForTest(t, strings.Repeat("internal reason ", 30000), []byte(`{"candidates":[]}`))
	if len(data) > 256<<10 || !strings.Contains(string(data), "truncated") {
		t.Fatalf("diagnostic file byte limit not enforced: bytes=%d", len(data))
	}
}
