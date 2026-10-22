package relay

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/control"
)

// signBundle signs content as release.yml does: Ed25519 over the sha256 hex.
func signBundle(t *testing.T, content string) (string, ed25519.PublicKey) {
	t.Helper()
	public, key, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(content))
	return base64.StdEncoding.EncodeToString(ed25519.Sign(key, []byte(hex.EncodeToString(sum[:])))), public
}

type manifestBundle struct {
	SHA256    string `json:"sha256"`
	Signature string `json:"signature"`
}

func agentManifestBundle(t *testing.T, server HTTPServer, token string) *manifestBundle {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "http://relay/v1/agent/manifest", nil)
	req.Header.Set("X-Pointy-Connector-Token", token)
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("manifest status %d: %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Bundle *manifestBundle `json:"bundle"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Bundle == nil {
		t.Fatalf("manifest has no bundle: %s", rec.Body.String())
	}
	return resp.Bundle
}

func adminRequest(server HTTPServer, method, path, body string, headers map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, "http://relay"+path, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-token")
	for name, value := range headers {
		req.Header.Set(name, value)
	}
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	return rec
}

func TestSignedUploadReachesTheAgentManifest(t *testing.T) {
	server, provisioned, _ := newUpdateTestServer(t)
	const bundle = "PK\x03\x04bundle-bytes"
	signature, public := signBundle(t, bundle)

	if rec := adminRequest(server, http.MethodPost, "/v1/artifacts/1.5.0", bundle,
		map[string]string{"X-Pointy-Artifact-Signature": signature}); rec.Code != http.StatusCreated {
		t.Fatalf("upload status %d: %s", rec.Code, rec.Body.String())
	}
	if err := server.Store.(control.UpdateStore).UpsertChannelTarget(t.Context(), control.ChannelTarget{
		Channel: "stable", TargetVersion: "1.5.0", RolloutPhase: control.RolloutAll,
	}); err != nil {
		t.Fatal(err)
	}

	got := agentManifestBundle(t, server, provisioned.ConnectorToken)
	if got.Signature != signature {
		t.Fatalf("manifest signature = %q, want %q", got.Signature, signature)
	}
	// What update-agent.sh checks: the signature covers the sha256 it is
	// served next to.
	raw, _ := base64.StdEncoding.DecodeString(got.Signature)
	if !ed25519.Verify(public, []byte(got.SHA256), raw) {
		t.Fatal("manifest signature does not verify against the manifest sha256")
	}
}

func TestUnsignedBundleOmitsTheSignature(t *testing.T) {
	server, provisioned, art := newUpdateTestServer(t)
	if _, err := art.Put("1.5.0", strings.NewReader("PK\x03\x04bundle-bytes")); err != nil {
		t.Fatal(err)
	}
	if err := server.Store.(control.UpdateStore).UpsertChannelTarget(t.Context(), control.ChannelTarget{
		Channel: "stable", TargetVersion: "1.5.0", RolloutPhase: control.RolloutAll,
	}); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "http://relay/v1/agent/manifest", nil)
	req.Header.Set("X-Pointy-Connector-Token", provisioned.ConnectorToken)
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	// The agent reads a missing key as "no signature" — never "null" or "".
	if strings.Contains(rec.Body.String(), "signature") {
		t.Fatalf("unsigned manifest mentions a signature: %s", rec.Body.String())
	}
}

func TestUploadWithAMalformedSignatureIsRefused(t *testing.T) {
	server, _, art := newUpdateTestServer(t)
	rec := adminRequest(server, http.MethodPost, "/v1/artifacts/1.5.0", "PK\x03\x04bundle-bytes",
		map[string]string{"X-Pointy-Artifact-Signature": "this is the sha256 file, not the sig"})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if art.Has("1.5.0") {
		t.Fatal("a refused upload was published")
	}
}

func TestAdminArtifactSignatureEndpoint(t *testing.T) {
	server, provisioned, art := newUpdateTestServer(t)
	const bundle = "PK\x03\x04bundle-bytes"
	signature, _ := signBundle(t, bundle)
	body := `{"signature":"` + signature + `"}`

	if rec := adminRequest(server, http.MethodPut, "/v1/artifacts/1.5.0/signature", body, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("signing a missing bundle: %d", rec.Code)
	}
	unauth := httptest.NewRequest(http.MethodPut, "http://relay/v1/artifacts/1.5.0/signature", strings.NewReader(body))
	unauthRec := httptest.NewRecorder()
	server.ServeHTTP(unauthRec, unauth)
	if unauthRec.Code != http.StatusUnauthorized {
		t.Fatalf("signing without the admin token: %d", unauthRec.Code)
	}

	if _, err := art.Put("1.5.0", strings.NewReader(bundle)); err != nil {
		t.Fatal(err)
	}
	if rec := adminRequest(server, http.MethodPut, "/v1/artifacts/1.5.0/signature", `{"signature":"bad"}`, nil); rec.Code != http.StatusBadRequest {
		t.Fatalf("malformed signature: %d", rec.Code)
	}
	if rec := adminRequest(server, http.MethodPut, "/v1/artifacts/1.5.0/signature", `{}`, nil); rec.Code != http.StatusBadRequest {
		t.Fatalf("empty signature on PUT must not silently remove one: %d", rec.Code)
	}
	if rec := adminRequest(server, http.MethodPut, "/v1/artifacts/1.5.0/signature", body, nil); rec.Code != http.StatusOK {
		t.Fatalf("sign status %d: %s", rec.Code, rec.Body.String())
	}
	if err := server.Store.(control.UpdateStore).UpsertChannelTarget(t.Context(), control.ChannelTarget{
		Channel: "stable", TargetVersion: "1.5.0", RolloutPhase: control.RolloutAll,
	}); err != nil {
		t.Fatal(err)
	}
	if got := agentManifestBundle(t, server, provisioned.ConnectorToken); got.Signature != signature {
		t.Fatalf("manifest signature after sign = %q", got.Signature)
	}

	if rec := adminRequest(server, http.MethodDelete, "/v1/artifacts/1.5.0/signature", "", nil); rec.Code != http.StatusOK {
		t.Fatalf("remove status %d: %s", rec.Code, rec.Body.String())
	}
	if got := agentManifestBundle(t, server, provisioned.ConnectorToken); got.Signature != "" {
		t.Fatalf("manifest still signed after remove: %q", got.Signature)
	}
}

func TestAdminArtifactFetchCarriesTheSignature(t *testing.T) {
	server, _, art := newUpdateTestServer(t)
	const bundle = "PK\x03\x04bundle-bytes"
	signature, _ := signBundle(t, bundle)
	host := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(bundle))
	}))
	defer host.Close()

	if rec := adminRequest(server, http.MethodPost, "/v1/artifacts/1.5.0/fetch",
		`{"url":"`+host.URL+`/b.zip","signature":"bad"}`, nil); rec.Code != http.StatusBadRequest {
		t.Fatalf("malformed signature on fetch: %d %s", rec.Code, rec.Body.String())
	}
	if rec := adminRequest(server, http.MethodPost, "/v1/artifacts/1.5.0/fetch",
		`{"url":"`+host.URL+`/b.zip","signature":"`+signature+`"}`, nil); rec.Code != http.StatusAccepted {
		t.Fatalf("fetch status %d: %s", rec.Code, rec.Body.String())
	}
	deadline := time.Now().Add(5 * time.Second)
	for !art.Has("1.5.0") {
		if time.Now().After(deadline) {
			t.Fatal("fetch never published")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if meta, _, _ := art.Get("1.5.0"); meta.Signature != signature {
		t.Fatalf("fetched bundle signature = %q", meta.Signature)
	}
}
