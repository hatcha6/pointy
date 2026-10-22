package main

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testSignature = "c2lnbmF0dXJl"

func writeTestFile(t *testing.T, name, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// recordAdminRequests answers every admin call with body and records them.
func recordAdminRequests(t *testing.T, status int, body string) *[]*http.Request {
	t.Helper()
	restore := newRelayAdminHTTPClient
	t.Cleanup(func() { newRelayAdminHTTPClient = restore })
	var seen []*http.Request
	newRelayAdminHTTPClient = func(_ relayAdminHTTPClientOptions) (*http.Client, error) {
		return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			var payload []byte
			if r.Body != nil {
				payload, _ = io.ReadAll(r.Body)
			}
			clone := r.Clone(r.Context())
			clone.Body = io.NopCloser(strings.NewReader(string(payload)))
			seen = append(seen, clone)
			return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body))}, nil
		})}, nil
	}
	return &seen
}

func TestRunArtifactsUploadSendsTheSignatureWithTheBundle(t *testing.T) {
	seen := recordAdminRequests(t, http.StatusCreated, `{"version":"1.4.0"}`)
	bundle := writeTestFile(t, "pointy-update-1.4.0.zip", "PK\x03\x04bytes")
	// base64 -w0 writes no newline, but a copied file may have one.
	sig := writeTestFile(t, "pointy-update-1.4.0.zip.sig", testSignature+"\n")

	out, err := captureStdout(t, func() error {
		return runArtifactsUpload([]string{
			"--control-url", "https://relay.test", "--admin-token", "secret",
			"--version", "1.4.0", "--bundle", bundle, "--signature", sig,
		})
	})
	if err != nil {
		t.Fatal(err)
	}
	req := (*seen)[0]
	if req.URL.Path != "/v1/artifacts/1.4.0" || req.Header.Get("X-Pointy-Artifact-Signature") != testSignature {
		t.Fatalf("upload %s with signature header %q", req.URL.Path, req.Header.Get("X-Pointy-Artifact-Signature"))
	}
	if !strings.Contains(out, "Uploaded signed bundle") {
		t.Fatalf("output does not say it was signed:\n%s", out)
	}
}

func TestRunArtifactsUploadWithoutSignatureSaysUnsigned(t *testing.T) {
	seen := recordAdminRequests(t, http.StatusCreated, `{"version":"1.4.0"}`)
	bundle := writeTestFile(t, "pointy-update-1.4.0.zip", "PK\x03\x04bytes")
	out, err := captureStdout(t, func() error {
		return runArtifactsUpload([]string{
			"--control-url", "https://relay.test", "--admin-token", "secret",
			"--version", "1.4.0", "--bundle", bundle,
		})
	})
	if err != nil {
		t.Fatal(err)
	}
	if (*seen)[0].Header.Get("X-Pointy-Artifact-Signature") != "" || !strings.Contains(out, "UNSIGNED") {
		t.Fatalf("unsigned upload: header %q, output:\n%s", (*seen)[0].Header.Get("X-Pointy-Artifact-Signature"), out)
	}
}

func TestRunArtifactsUploadURLSendsTheSignature(t *testing.T) {
	seen := recordAdminRequests(t, http.StatusAccepted, `{"version":"1.4.0","state":"fetching"}`)
	sig := writeTestFile(t, "b.zip.sig", testSignature)
	if _, err := captureStdout(t, func() error {
		return runArtifactsUpload([]string{
			"--control-url", "https://relay.test", "--admin-token", "secret",
			"--version", "1.4.0", "--url", "https://files.test/b.zip", "--signature", sig, "--no-wait",
		})
	}); err != nil {
		t.Fatal(err)
	}
	var body map[string]any
	payload, _ := io.ReadAll((*seen)[0].Body)
	if err := json.Unmarshal(payload, &body); err != nil {
		t.Fatal(err)
	}
	if body["signature"] != testSignature {
		t.Fatalf("fetch body %v", body)
	}
}

func TestRunArtifactsUploadRefusesAMissingSignatureFile(t *testing.T) {
	seen := recordAdminRequests(t, http.StatusCreated, `{}`)
	bundle := writeTestFile(t, "b.zip", "PK\x03\x04bytes")
	err := runArtifactsUpload([]string{
		"--control-url", "https://relay.test", "--admin-token", "secret",
		"--version", "1.4.0", "--bundle", bundle, "--signature", filepath.Join(t.TempDir(), "missing.sig"),
	})
	if err == nil || len(*seen) != 0 {
		t.Fatalf("err = %v, requests = %d: a typo'd .sig path must stop before uploading", err, len(*seen))
	}
}

func TestRunArtifactsSign(t *testing.T) {
	seen := recordAdminRequests(t, http.StatusOK, `{"version":"1.4.0"}`)
	sig := writeTestFile(t, "b.zip.sig", testSignature)
	base := []string{"--control-url", "https://relay.test", "--admin-token", "secret", "--version", "1.4.0"}

	if _, err := captureStdout(t, func() error { return runArtifactsSign(append(base, "--signature", sig)) }); err != nil {
		t.Fatal(err)
	}
	if _, err := captureStdout(t, func() error { return runArtifactsSign(append(base, "--remove")) }); err != nil {
		t.Fatal(err)
	}
	put, del := (*seen)[0], (*seen)[1]
	payload, _ := io.ReadAll(put.Body)
	if put.Method != http.MethodPut || put.URL.Path != "/v1/artifacts/1.4.0/signature" ||
		!strings.Contains(string(payload), `"signature":"`+testSignature+`"`) {
		t.Fatalf("sign request %s %s %s", put.Method, put.URL.Path, payload)
	}
	if del.Method != http.MethodDelete || del.URL.Path != "/v1/artifacts/1.4.0/signature" {
		t.Fatalf("remove request %s %s", del.Method, del.URL.Path)
	}

	for _, args := range [][]string{base, append(append([]string{}, base...), "--signature", sig, "--remove")} {
		if err := runArtifactsSign(args); err == nil {
			t.Fatalf("runArtifactsSign(%v) should need exactly one of --signature/--remove", args)
		}
	}
}
