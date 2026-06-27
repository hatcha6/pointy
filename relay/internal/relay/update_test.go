package relay

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"pointy/relay/internal/artifacts"
	"pointy/relay/internal/control"
)

func newUpdateTestServer(t *testing.T) (HTTPServer, control.ProvisionedInstallation, *artifacts.Store) {
	t.Helper()
	store, provisioned := provisionRelayInstallation(t)
	artStore, err := artifacts.New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	server := HTTPServer{
		Store:      store,
		Hub:        NewHub(),
		Artifacts:  artStore,
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken: "admin-token",
	}
	return server, provisioned, artStore
}

func TestAgentManifestRolloutGating(t *testing.T) {
	server, provisioned, art := newUpdateTestServer(t)
	ctx := context.Background()
	if _, err := art.Put("1.4.0", strings.NewReader("bundle-bytes")); err != nil {
		t.Fatal(err)
	}
	updateStore := server.Store.(control.UpdateStore)

	manifest := func() (string, string, bool) {
		req := httptest.NewRequest(http.MethodGet, "http://relay/v1/agent/manifest", nil)
		req.Header.Set("X-Pointy-Connector-Token", provisioned.ConnectorToken)
		rec := httptest.NewRecorder()
		server.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("manifest status %d: %s", rec.Code, rec.Body.String())
		}
		var resp struct {
			Directive       string `json:"directive"`
			AssignedVersion string `json:"assigned_version"`
			Bundle          *struct {
				Path string `json:"path"`
			} `json:"bundle"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
			t.Fatal(err)
		}
		return resp.Directive, resp.AssignedVersion, resp.Bundle != nil && resp.Bundle.Path == "/v1/agent/artifacts/1.4.0"
	}

	// No channel target yet → hold.
	if directive, _, _ := manifest(); directive != "hold" {
		t.Fatalf("expected hold before a target is set, got %q", directive)
	}

	// Rollout all → apply with a bundle descriptor.
	if err := updateStore.UpsertChannelTarget(ctx, control.ChannelTarget{
		Channel: "stable", TargetVersion: "1.4.0", RolloutPhase: control.RolloutAll,
	}); err != nil {
		t.Fatal(err)
	}
	directive, version, bundleOK := manifest()
	if directive != "apply" || version != "1.4.0" || !bundleOK {
		t.Fatalf("expected apply 1.4.0 with bundle, got %q %q bundleOK=%v", directive, version, bundleOK)
	}

	// Paused → hold (kill switch).
	if err := updateStore.UpsertChannelTarget(ctx, control.ChannelTarget{
		Channel: "stable", TargetVersion: "1.4.0", RolloutPhase: control.RolloutPaused,
	}); err != nil {
		t.Fatal(err)
	}
	if directive, _, _ := manifest(); directive != "hold" {
		t.Fatalf("expected hold when paused, got %q", directive)
	}
}

func TestAgentEndpointsRequireConnectorToken(t *testing.T) {
	server, _, _ := newUpdateTestServer(t)
	for _, token := range []string{"", "bogus-token"} {
		req := httptest.NewRequest(http.MethodGet, "http://relay/v1/agent/manifest", nil)
		if token != "" {
			req.Header.Set("X-Pointy-Connector-Token", token)
		}
		rec := httptest.NewRecorder()
		server.ServeHTTP(rec, req)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("token %q: expected 401, got %d", token, rec.Code)
		}
	}
}

func TestAgentArtifactDownload(t *testing.T) {
	server, provisioned, art := newUpdateTestServer(t)
	if _, err := art.Put("1.4.0", strings.NewReader("ZIPDATA")); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "http://relay/v1/agent/artifacts/1.4.0", nil)
	req.Header.Set("X-Pointy-Connector-Token", provisioned.ConnectorToken)
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if rec.Body.String() != "ZIPDATA" {
		t.Fatalf("unexpected bundle body %q", rec.Body.String())
	}
	if rec.Header().Get("X-Pointy-Artifact-SHA256") == "" {
		t.Fatal("expected artifact sha256 header")
	}
}

func TestAgentStatusUpdatesInstallation(t *testing.T) {
	server, provisioned, _ := newUpdateTestServer(t)
	body := `{"current_version":"1.4.0","agent_version":"pointy-agent/1","update_status":"succeeded"}`
	req := httptest.NewRequest(http.MethodPost, "http://relay/v1/agent/status", strings.NewReader(body))
	req.Header.Set("X-Pointy-Connector-Token", provisioned.ConnectorToken)
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	installation, err := server.Store.GetInstallation(context.Background(), provisioned.Installation.ID)
	if err != nil {
		t.Fatal(err)
	}
	if installation.CurrentVersion != "1.4.0" || installation.UpdateStatus != "succeeded" {
		t.Fatalf("agent status not persisted: %+v", installation)
	}
}

func TestAdminSetChannelTargetValidatesArtifactAndAuth(t *testing.T) {
	server, _, art := newUpdateTestServer(t)
	put := func(auth bool) int {
		req := httptest.NewRequest(
			http.MethodPut,
			"http://relay/v1/fleet/channels/stable",
			strings.NewReader(`{"target_version":"2.0.0","rollout_phase":"all"}`),
		)
		if auth {
			req.Header.Set("Authorization", "Bearer admin-token")
		}
		rec := httptest.NewRecorder()
		server.ServeHTTP(rec, req)
		return rec.Code
	}

	if code := put(false); code != http.StatusUnauthorized {
		t.Fatalf("expected 401 without admin token, got %d", code)
	}
	if code := put(true); code != http.StatusBadRequest {
		t.Fatalf("expected 400 before the artifact exists, got %d", code)
	}
	if _, err := art.Put("2.0.0", strings.NewReader("bundle")); err != nil {
		t.Fatal(err)
	}
	if code := put(true); code != http.StatusOK {
		t.Fatalf("expected 200 once the artifact exists, got %d", code)
	}
}

func TestAdminArtifactUploadAndFleetStatus(t *testing.T) {
	server, provisioned, _ := newUpdateTestServer(t)
	ctx := context.Background()

	upload := httptest.NewRequest(
		http.MethodPost,
		"http://relay/v1/artifacts/1.5.0",
		strings.NewReader("bundle-bytes"),
	)
	upload.Header.Set("Authorization", "Bearer admin-token")
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, upload)
	if rec.Code != http.StatusCreated {
		t.Fatalf("upload status %d: %s", rec.Code, rec.Body.String())
	}

	if err := server.Store.(control.UpdateStore).UpsertChannelTarget(ctx, control.ChannelTarget{
		Channel: "stable", TargetVersion: "1.5.0", RolloutPhase: control.RolloutAll,
	}); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "http://relay/v1/fleet", nil)
	req.Header.Set("Authorization", "Bearer admin-token")
	statusRec := httptest.NewRecorder()
	server.ServeHTTP(statusRec, req)
	if statusRec.Code != http.StatusOK {
		t.Fatalf("fleet status %d: %s", statusRec.Code, statusRec.Body.String())
	}
	var resp struct {
		Installations []struct {
			ID              string `json:"id"`
			AssignedVersion string `json:"assigned_version"`
			Directive       string `json:"directive"`
		} `json:"installations"`
	}
	if err := json.Unmarshal(statusRec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, installation := range resp.Installations {
		if installation.ID == provisioned.Installation.ID {
			found = true
			if installation.AssignedVersion != "1.5.0" || installation.Directive != "apply" {
				t.Fatalf("unexpected fleet row: %+v", installation)
			}
		}
	}
	if !found {
		t.Fatal("installation missing from fleet status")
	}
}
