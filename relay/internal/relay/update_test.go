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
	"time"

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

func TestAdminPinNeedsAnUploadedBundle(t *testing.T) {
	server, provisioned, art := newUpdateTestServer(t)
	patch := func(body string) (int, string) {
		req := httptest.NewRequest(http.MethodPatch, "http://relay/v1/installations/"+provisioned.Installation.ID+"/update", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer admin-token")
		rec := httptest.NewRecorder()
		server.ServeHTTP(rec, req)
		return rec.Code, rec.Body.String()
	}
	// A typo must not freeze the shop: refused, and nothing else in the
	// request (the channel) is applied either.
	if code, body := patch(`{"channel":"beta","pinned_version":"0.8.l"}`); code != http.StatusBadRequest || !strings.Contains(body, "no_artifact") {
		t.Fatalf("pin without a bundle: %d %s", code, body)
	}
	installation, err := server.Store.GetInstallation(context.Background(), provisioned.Installation.ID)
	if err != nil || installation.PinnedVersion != "" || control.NormalizeChannel(installation.UpdateChannel) != "stable" {
		t.Fatalf("a refused request changed the shop: %+v %v", installation, err)
	}
	if _, err := art.Put("0.8.1", strings.NewReader("bundle")); err != nil {
		t.Fatal(err)
	}
	if code, body := patch(`{"pinned_version":"0.8.1"}`); code != http.StatusOK {
		t.Fatalf("pin with a bundle: %d %s", code, body)
	}
	// Unpinning never needs a bundle.
	if code, body := patch(`{"pinned_version":""}`); code != http.StatusOK {
		t.Fatalf("unpin: %d %s", code, body)
	}
}

func TestAdminArtifactList(t *testing.T) {
	server, _, art := newUpdateTestServer(t)
	for _, v := range []string{"0.7.9", "0.8.0"} {
		if _, err := art.Put(v, strings.NewReader("bundle-"+v)); err != nil {
			t.Fatal(err)
		}
	}
	req := httptest.NewRequest(http.MethodGet, "http://relay/v1/artifacts", nil)
	req.Header.Set("Authorization", "Bearer admin-token")
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	var body struct {
		Bundles []artifacts.Meta `json:"bundles"`
		Fetches []any            `json:"fetches"`
	}
	if rec.Code != http.StatusOK || json.Unmarshal(rec.Body.Bytes(), &body) != nil || len(body.Bundles) != 2 || body.Fetches == nil {
		t.Fatalf("list %d %s", rec.Code, rec.Body.String())
	}
	unauth := httptest.NewRequest(http.MethodGet, "http://relay/v1/artifacts", nil)
	rec = httptest.NewRecorder()
	server.ServeHTTP(rec, unauth)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("the list is admin-only: %d", rec.Code)
	}
}

func TestInstallationListPresenceIsOptIn(t *testing.T) {
	server, provisioned, _ := newUpdateTestServer(t)
	list := func(query string) map[string]any {
		req := httptest.NewRequest(http.MethodGet, "http://relay/v1/installations"+query, nil)
		req.Header.Set("Authorization", "Bearer admin-token")
		rec := httptest.NewRecorder()
		server.ServeHTTP(rec, req)
		var body struct {
			Installations []map[string]any `json:"installations"`
		}
		if rec.Code != http.StatusOK || json.Unmarshal(rec.Body.Bytes(), &body) != nil || len(body.Installations) != 1 {
			t.Fatalf("list %d %s", rec.Code, rec.Body.String())
		}
		return body.Installations[0]
	}
	if _, asked := list("")["connector_online"]; asked {
		t.Fatal("presence costs a lookup per shop; it is only sent when asked for")
	}
	shop := list("?presence=1")
	if shop["id"] != provisioned.Installation.ID || shop["connector_online"] != false {
		t.Fatalf("presence %v", shop)
	}
}

// frozenClock pins the relay's clock: an install window is a function of it.
type frozenClock struct{ at time.Time }

func (c frozenClock) Now() time.Time { return c.at }

func TestAgentManifestInstallWindowAndStrategy(t *testing.T) {
	server, provisioned, art := newUpdateTestServer(t)
	if _, err := art.Put("1.4.0", strings.NewReader("bundle-bytes")); err != nil {
		t.Fatal(err)
	}
	noon := time.Date(2026, 11, 16, 12, 0, 0, 0, control.FleetLocation)
	server.Clock = frozenClock{at: noon}

	// Launched the way the console does it: restart, from 23:00, not before the 17th.
	put := httptest.NewRequest(http.MethodPut, "http://relay/v1/fleet/channels/stable", strings.NewReader(
		`{"target_version":"1.4.0","rollout_phase":"all","strategy":"restart","install_hour":23,"install_date":"2026-11-17"}`))
	put.Header.Set("Authorization", "Bearer admin-token")
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, put)
	if rec.Code != http.StatusOK {
		t.Fatalf("set target: %d %s", rec.Code, rec.Body.String())
	}
	var stored control.ChannelTarget
	if err := json.Unmarshal(rec.Body.Bytes(), &stored); err != nil {
		t.Fatal(err)
	}
	if stored.Strategy != "restart" || stored.InstallHour == nil || *stored.InstallHour != 23 || stored.InstallDate != "2026-11-17" {
		t.Fatalf("the schedule was not stored: %+v", stored)
	}

	type manifest struct {
		Directive       string     `json:"directive"`
		AssignedVersion string     `json:"assigned_version"`
		Strategy        string     `json:"strategy"`
		ScheduledFor    *time.Time `json:"scheduled_for"`
		Bundle          *struct {
			Path string `json:"path"`
		} `json:"bundle"`
	}
	ask := func(protocol string) manifest {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, "http://relay/v1/agent/manifest", nil)
		req.Header.Set("X-Pointy-Connector-Token", provisioned.ConnectorToken)
		if protocol != "" {
			req.Header.Set("X-Pointy-Agent-Protocol", protocol)
		}
		rec := httptest.NewRecorder()
		server.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("manifest status %d: %s", rec.Code, rec.Body.String())
		}
		var resp manifest
		if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
			t.Fatal(err)
		}
		return resp
	}

	opens := time.Date(2026, 11, 17, 23, 0, 0, 0, control.FleetLocation)
	// An agent from before schedules must see nothing it could act on early.
	if old := ask(""); old.Directive != "hold" || old.Bundle != nil {
		t.Fatalf("an older agent must be held with no bundle: %+v", old)
	}
	current := ask("2")
	if current.Directive != "download" || current.Bundle == nil || current.ScheduledFor == nil || !current.ScheduledFor.Equal(opens) {
		t.Fatalf("a scheduling agent should download and wait until %s: %+v", opens, current)
	}

	// The first night's hour is before the date: still closed.
	server.Clock = frozenClock{at: time.Date(2026, 11, 16, 23, 30, 0, 0, control.FleetLocation)}
	if got := ask("2"); got.Directive != "download" {
		t.Fatalf("the hour before the date must not open the window: %+v", got)
	}

	server.Clock = frozenClock{at: opens.Add(20 * time.Minute)}
	for _, protocol := range []string{"", "2"} {
		got := ask(protocol)
		if got.Directive != "apply" || got.Strategy != "restart" || got.Bundle == nil || got.ScheduledFor != nil {
			t.Fatalf("inside the window (protocol %q) the agent applies: %+v", protocol, got)
		}
	}

	// The fleet view says who is waiting, and for when.
	server.Clock = frozenClock{at: noon}
	fleetReq := httptest.NewRequest(http.MethodGet, "http://relay/v1/fleet", nil)
	fleetReq.Header.Set("Authorization", "Bearer admin-token")
	rec = httptest.NewRecorder()
	server.ServeHTTP(rec, fleetReq)
	var fleet struct {
		Installations []struct {
			AssignedVersion string     `json:"assigned_version"`
			Directive       string     `json:"directive"`
			ScheduledFor    *time.Time `json:"scheduled_for"`
			LegacyAgent     bool       `json:"legacy_agent"`
		} `json:"installations"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &fleet); err != nil {
		t.Fatal(err)
	}
	if len(fleet.Installations) != 1 {
		t.Fatalf("fleet: %s", rec.Body.String())
	}
	row := fleet.Installations[0]
	if row.AssignedVersion != "1.4.0" || row.Directive != "hold" || !row.LegacyAgent || row.ScheduledFor == nil || !row.ScheduledFor.Equal(opens) {
		t.Fatalf("fleet row: %+v", row)
	}
}

func TestAdminSetChannelTargetWithoutScheduleInstallsAtOnce(t *testing.T) {
	server, provisioned, art := newUpdateTestServer(t)
	if _, err := art.Put("1.4.0", strings.NewReader("bundle-bytes")); err != nil {
		t.Fatal(err)
	}
	send := func(body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPut, "http://relay/v1/fleet/channels/stable", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer admin-token")
		rec := httptest.NewRecorder()
		server.ServeHTTP(rec, req)
		return rec
	}
	for _, bad := range []string{
		`{"target_version":"1.4.0","rollout_phase":"all","strategy":"rolling"}`,
		`{"target_version":"1.4.0","rollout_phase":"all","install_hour":24}`,
		`{"target_version":"1.4.0","rollout_phase":"all","install_date":"tomorrow"}`,
	} {
		if rec := send(bad); rec.Code != http.StatusBadRequest {
			t.Fatalf("%s: got %d", bad, rec.Code)
		}
	}
	// The body a console or CLI from before the schedule sends.
	if rec := send(`{"target_version":"1.4.0","rollout_phase":"all","rollout_percent":0,"canary_ids":[]}`); rec.Code != http.StatusOK {
		t.Fatalf("legacy body: %d %s", rec.Code, rec.Body.String())
	}
	req := httptest.NewRequest(http.MethodGet, "http://relay/v1/agent/manifest", nil)
	req.Header.Set("X-Pointy-Connector-Token", provisioned.ConnectorToken)
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	if !strings.Contains(rec.Body.String(), `"directive":"apply"`) || strings.Contains(rec.Body.String(), "strategy") {
		t.Fatalf("an unscheduled target must read exactly as before: %s", rec.Body.String())
	}
}
