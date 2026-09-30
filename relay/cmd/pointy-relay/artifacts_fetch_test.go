package main

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestRunArtifactsUploadURLWaitsForRelayFetch(t *testing.T) {
	restoreClient, restoreInterval := newRelayAdminHTTPClient, artifactFetchPollInterval
	defer func() { newRelayAdminHTTPClient, artifactFetchPollInterval = restoreClient, restoreInterval }()
	artifactFetchPollInterval = 0

	var sent map[string]any
	var calls []string
	polls := 0
	newRelayAdminHTTPClient = func(_ relayAdminHTTPClientOptions) (*http.Client, error) {
		return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			calls = append(calls, r.Method+" "+r.URL.Path)
			body := `{"version":"1.4.0","state":"fetching","bytes_received":0,"bytes_total":-1}`
			status := http.StatusAccepted
			if r.Method == http.MethodPost {
				_ = json.NewDecoder(r.Body).Decode(&sent)
			} else {
				status = http.StatusOK
				polls++
				if polls > 1 {
					body = `{"version":"1.4.0","state":"done","bytes_received":12,"bytes_total":12,` +
						`"artifact":{"version":"1.4.0","sha256":"abc","size":12}}`
				}
			}
			return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body))}, nil
		})}, nil
	}

	out, err := captureStdout(t, func() error {
		return runArtifactsUpload([]string{
			"--control-url", "https://relay.test", "--admin-token", "secret",
			"--version", "1.4.0",
			"--url", "https://github.com/o/r/releases/download/v1.4.0/pointy-onprem-1.4.0.zip",
			"--sha256", "sha256:abc",
			"--header", "Authorization: Bearer gh-token",
		})
	})
	if err != nil {
		t.Fatal(err)
	}
	if calls[0] != "POST /v1/artifacts/1.4.0/fetch" || calls[len(calls)-1] != "GET /v1/artifacts/1.4.0/fetch" {
		t.Fatalf("unexpected calls %v", calls)
	}
	headers, _ := sent["headers"].(map[string]any)
	if !strings.HasSuffix(sent["url"].(string), "pointy-onprem-1.4.0.zip") ||
		sent["sha256"] != "sha256:abc" || headers["Authorization"] != "Bearer gh-token" {
		t.Fatalf("unexpected body %#v", sent)
	}
	if !strings.Contains(out, `"sha256": "abc"`) {
		t.Fatalf("expected the published artifact in output:\n%s", out)
	}
}

func TestRunArtifactsUploadNeedsExactlyOneSource(t *testing.T) {
	for _, args := range [][]string{
		{"--version", "1.4.0"},
		{"--version", "1.4.0", "--bundle", "b.zip", "--url", "https://x/b.zip"},
	} {
		if err := runArtifactsUpload(args); err == nil {
			t.Fatalf("runArtifactsUpload(%v) should fail", args)
		}
	}
}
