package relay

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const agentRunsBody = `{"agent_version":"pointy-update-agent/3","runs":[
 {"id":"run-1","kind":"update","trigger":"agent","from_version":"0.9.0","to_version":"0.9.1",
  "strategy":"live","outcome":"succeeded","error":"","started_at":"2026-11-10T08:00:00Z",
  "finished_at":"2026-11-10T08:03:20Z","duration_seconds":200,"downtime_seconds":0,
  "longest_outage_seconds":0,"probe_samples":198,"phases":{"backup":12,"standby_ready":150}},
 {"id":"run-2","kind":"install","trigger":"manual","from_version":"","to_version":"0.9.1",
  "strategy":"restart","outcome":"succeeded","error":"","started_at":"2026-11-10T09:00:00Z",
  "finished_at":"2026-11-10T09:04:00Z","duration_seconds":240,"downtime_seconds":null,
  "longest_outage_seconds":null,"probe_samples":null,"phases":{}},
 {"id":"","kind":"update","outcome":"succeeded","finished_at":"2026-11-10T09:04:00Z"},
 {"id":"run-4","kind":"update","outcome":"succeeded","finished_at":"yesterday"}
]}`

func postAgentRuns(t *testing.T, server HTTPServer, token, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "http://relay/v1/agent/runs", strings.NewReader(body))
	req.Header.Set("X-Pointy-Connector-Token", token)
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	return rec
}

func TestAgentRunsAreRecordedOnceAndListedForTheConsole(t *testing.T) {
	server, provisioned, _ := newUpdateTestServer(t)

	rec := postAgentRuns(t, server, provisioned.ConnectorToken, agentRunsBody)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	var posted struct{ Recorded, Known, Skipped int }
	if err := json.Unmarshal(rec.Body.Bytes(), &posted); err != nil {
		t.Fatal(err)
	}
	// Two good runs; the two malformed ones are skipped, not refused, so the
	// shop's cursor can move past them.
	if posted.Recorded != 2 || posted.Known != 0 || posted.Skipped != 2 {
		t.Fatalf("first post: %+v", posted)
	}

	rec = postAgentRuns(t, server, provisioned.ConnectorToken, agentRunsBody)
	if err := json.Unmarshal(rec.Body.Bytes(), &posted); err != nil {
		t.Fatal(err)
	}
	if rec.Code != http.StatusOK || posted.Recorded != 0 || posted.Known != 2 {
		t.Fatalf("re-send: %d %+v", rec.Code, posted)
	}

	req := httptest.NewRequest(http.MethodGet, "http://relay/v1/fleet/runs", nil)
	req.Header.Set("Authorization", "Bearer admin-token")
	rec = httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("list status %d: %s", rec.Code, rec.Body.String())
	}
	var listed struct {
		Count int `json:"count"`
		Runs  []struct {
			ID              string         `json:"id"`
			InstallationID  string         `json:"installation_id"`
			Kind            string         `json:"kind"`
			AgentVersion    string         `json:"agent_version"`
			DurationSeconds int            `json:"duration_seconds"`
			DowntimeSeconds *int           `json:"downtime_seconds"`
			Phases          map[string]int `json:"phases"`
		} `json:"runs"`
		Summaries []struct {
			InstallationID        string `json:"installation_id"`
			Updates               int    `json:"updates"`
			Succeeded             int    `json:"succeeded"`
			MedianDurationSeconds *int   `json:"median_duration_seconds"`
			TotalDowntimeSeconds  *int   `json:"total_downtime_seconds"`
		} `json:"summaries"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &listed); err != nil {
		t.Fatal(err)
	}
	if listed.Count != 2 || listed.Runs[0].ID != "run-2" || listed.Runs[1].ID != "run-1" {
		t.Fatalf("runs newest first: %s", rec.Body.String())
	}
	install, update := listed.Runs[0], listed.Runs[1]
	if install.DowntimeSeconds != nil {
		t.Fatalf("an unmeasured downtime must stay unmeasured: %v", *install.DowntimeSeconds)
	}
	if update.DowntimeSeconds == nil || *update.DowntimeSeconds != 0 || update.Phases["standby_ready"] != 150 {
		t.Fatalf("update: %+v", update)
	}
	if update.InstallationID != provisioned.Installation.ID || update.AgentVersion != "pointy-update-agent/3" {
		t.Fatalf("update identity: %+v", update)
	}
	if len(listed.Summaries) != 1 {
		t.Fatalf("summaries: %s", rec.Body.String())
	}
	summary := listed.Summaries[0]
	if summary.Updates != 1 || summary.Succeeded != 1 || *summary.MedianDurationSeconds != 200 || *summary.TotalDowntimeSeconds != 0 {
		t.Fatalf("summary: %+v", summary)
	}
}

func TestAgentRunsNeedTheShopsOwnTokenAndTheListNeedsAnAdmin(t *testing.T) {
	server, provisioned, _ := newUpdateTestServer(t)

	if rec := postAgentRuns(t, server, "not-a-token", agentRunsBody); rec.Code != http.StatusUnauthorized {
		t.Fatalf("bad connector token: %d", rec.Code)
	}
	if rec := postAgentRuns(t, server, provisioned.ConnectorToken, "{not json"); rec.Code != http.StatusBadRequest {
		t.Fatalf("bad body: %d", rec.Code)
	}
	tooMany := `{"runs":[` + strings.TrimSuffix(strings.Repeat(`{"id":"x"},`, maxAgentRunsPerPost+1), ",") + `]}`
	if rec := postAgentRuns(t, server, provisioned.ConnectorToken, tooMany); rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("too many: %d", rec.Code)
	}

	req := httptest.NewRequest(http.MethodGet, "http://relay/v1/fleet/runs", nil)
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("list without admin: %d", rec.Code)
	}
	// A shop's own token is not an admin's.
	req = httptest.NewRequest(http.MethodGet, "http://relay/v1/fleet/runs", nil)
	req.Header.Set("X-Pointy-Connector-Token", provisioned.ConnectorToken)
	rec = httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("list with a shop token: %d", rec.Code)
	}
}
