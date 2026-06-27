package main

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestParseRollout(t *testing.T) {
	cases := []struct {
		rollout     string
		canary      string
		wantPhase   string
		wantPercent int
		wantCanary  []string
		wantErr     bool
	}{
		{rollout: "all", wantPhase: "all"},
		{rollout: "paused", wantPhase: "paused"},
		{rollout: "", wantPhase: "paused"},
		{rollout: "canary", canary: "i1, i2", wantPhase: "canary", wantCanary: []string{"i1", "i2"}},
		{rollout: "canary", wantErr: true},
		{rollout: "50", wantPhase: "percent", wantPercent: 50},
		{rollout: "25%", wantPhase: "percent", wantPercent: 25},
		{rollout: "150", wantErr: true},
		{rollout: "nonsense", wantErr: true},
	}
	for _, tc := range cases {
		phase, percent, canary, err := parseRollout(tc.rollout, tc.canary)
		if tc.wantErr {
			if err == nil {
				t.Fatalf("rollout %q: expected error", tc.rollout)
			}
			continue
		}
		if err != nil {
			t.Fatalf("rollout %q: %v", tc.rollout, err)
		}
		if phase != tc.wantPhase || percent != tc.wantPercent {
			t.Fatalf("rollout %q: got %q/%d, want %q/%d", tc.rollout, phase, percent, tc.wantPhase, tc.wantPercent)
		}
		if strings.Join(canary, ",") != strings.Join(tc.wantCanary, ",") {
			t.Fatalf("rollout %q: canary %v, want %v", tc.rollout, canary, tc.wantCanary)
		}
	}
}

func TestRunFleetSetVersionSendsChannelTarget(t *testing.T) {
	restore := newRelayAdminHTTPClient
	defer func() { newRelayAdminHTTPClient = restore }()
	var method, path, auth string
	var sent map[string]any
	newRelayAdminHTTPClient = func(_ relayAdminHTTPClientOptions) (*http.Client, error) {
		return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			method = r.Method
			path = r.URL.Path
			auth = r.Header.Get("Authorization")
			_ = json.NewDecoder(r.Body).Decode(&sent)
			body := `{"channel":"stable","target_version":"1.4.0","rollout_phase":"all","rollout_percent":0}`
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(strings.NewReader(body)),
				Header:     http.Header{"Content-Type": []string{"application/json"}},
			}, nil
		})}, nil
	}

	out, err := captureStdout(t, func() error {
		return runFleetSetVersion([]string{
			"1.4.0",
			"--control-url", "https://relay.test",
			"--admin-token", "secret",
			"--rollout", "all",
		})
	})
	if err != nil {
		t.Fatal(err)
	}
	if method != http.MethodPut {
		t.Fatalf("expected PUT, got %s", method)
	}
	if path != "/v1/fleet/channels/stable" {
		t.Fatalf("unexpected path %q", path)
	}
	if auth != "Bearer secret" {
		t.Fatalf("unexpected auth %q", auth)
	}
	if sent["target_version"] != "1.4.0" || sent["rollout_phase"] != "all" {
		t.Fatalf("unexpected body %#v", sent)
	}
	if !strings.Contains(out, "1.4.0") || !strings.Contains(out, "all") {
		t.Fatalf("summary missing content:\n%s", out)
	}
}

func TestRunFleetPinSendsPatch(t *testing.T) {
	restore := newRelayAdminHTTPClient
	defer func() { newRelayAdminHTTPClient = restore }()
	var method, path string
	var sent map[string]any
	newRelayAdminHTTPClient = func(_ relayAdminHTTPClientOptions) (*http.Client, error) {
		return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			method = r.Method
			path = r.URL.Path
			_ = json.NewDecoder(r.Body).Decode(&sent)
			body := `{"installation_id":"inst_1","update_channel":"stable","pinned_version":"1.3.0"}`
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(strings.NewReader(body)),
				Header:     http.Header{"Content-Type": []string{"application/json"}},
			}, nil
		})}, nil
	}

	_, err := captureStdout(t, func() error {
		return runFleetPin([]string{
			"inst_1", "1.3.0",
			"--control-url", "https://relay.test",
			"--admin-token", "secret",
		})
	})
	if err != nil {
		t.Fatal(err)
	}
	if method != http.MethodPatch {
		t.Fatalf("expected PATCH, got %s", method)
	}
	if path != "/v1/installations/inst_1/update" {
		t.Fatalf("unexpected path %q", path)
	}
	if sent["pinned_version"] != "1.3.0" {
		t.Fatalf("unexpected body %#v", sent)
	}
}

func TestRunFleetSetVersionRejectsBadRollout(t *testing.T) {
	err := runFleetSetVersion([]string{
		"1.4.0", "--admin-token", "secret", "--rollout", "nonsense",
	})
	if err == nil {
		t.Fatal("expected an error for an invalid --rollout")
	}
}
