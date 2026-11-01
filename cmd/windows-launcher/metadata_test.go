package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPayloadManifestJSONRoundTrip(t *testing.T) {
	want := PayloadManifest{
		Version: "0.3.3",
		Architectures: map[string]PayloadInfo{
			"386":   {SHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", Size: 11},
			"amd64": {SHA256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", Size: 22},
			"arm64": {SHA256: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", Size: 33},
		},
	}

	raw, err := json.Marshal(want)
	if err != nil {
		t.Fatalf("marshal payload manifest: %v", err)
	}
	var got PayloadManifest
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("unmarshal payload manifest: %v", err)
	}
	if got.Version != want.Version || len(got.Architectures) != 3 {
		t.Fatalf("round trip = %#v, want %#v", got, want)
	}
	for arch, wantPayload := range want.Architectures {
		if got.Architectures[arch] != wantPayload {
			t.Errorf("payload[%q] = %#v, want %#v", arch, got.Architectures[arch], wantPayload)
		}
	}
}

func TestPayloadManifestValidate(t *testing.T) {
	valid := PayloadManifest{
		Version: "0.3.3",
		Architectures: map[string]PayloadInfo{
			"386":   {SHA256: strings.Repeat("a", 64), Size: 1},
			"amd64": {SHA256: strings.Repeat("b", 64), Size: 2},
			"arm64": {SHA256: strings.Repeat("c", 64), Size: 3},
		},
	}
	if err := valid.Validate(); err != nil {
		t.Fatalf("valid manifest rejected: %v", err)
	}
	for name, mutate := range map[string]func(*PayloadManifest){
		"missing architecture": func(m *PayloadManifest) { delete(m.Architectures, "arm64") },
		"unsupported architecture": func(m *PayloadManifest) {
			m.Architectures["mips64"] = PayloadInfo{SHA256: strings.Repeat("d", 64), Size: 1}
		},
		"bad size": func(m *PayloadManifest) {
			value := m.Architectures["386"]
			value.Size = 0
			m.Architectures["386"] = value
		},
		"bad hash": func(m *PayloadManifest) {
			value := m.Architectures["386"]
			value.SHA256 = "bad"
			m.Architectures["386"] = value
		},
		"bad version": func(m *PayloadManifest) { m.Version = "0.3" },
	} {
		t.Run(name, func(t *testing.T) {
			candidate := valid
			candidate.Architectures = make(map[string]PayloadInfo, len(valid.Architectures))
			for arch, payload := range valid.Architectures {
				candidate.Architectures[arch] = payload
			}
			mutate(&candidate)
			if err := candidate.Validate(); err == nil {
				t.Fatalf("invalid manifest unexpectedly accepted")
			}
		})
	}
}
