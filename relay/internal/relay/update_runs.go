package relay

import (
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"pointy/relay/internal/control"
)

// What each update cost each shop.
//
//	POST /v1/agent/runs   (connector token) the shop's update agent hands over
//	                      the runs the relay has not had: {"runs": [...]}
//	GET  /v1/fleet/runs   (admin) the newest runs fleet-wide, or one shop's with
//	                      ?installation_id=, plus one summary per shop
//
// The agent moves its cursor past everything it posted once this answers 200,
// so a run the relay cannot accept is counted and skipped, never refused: one
// malformed record must not hold every later run of that shop back for good.

const maxAgentRunsPerPost = 100

type agentRunsRequest struct {
	AgentVersion string           `json:"agent_version"`
	Runs         []agentRunRecord `json:"runs"`
}

// agentRunRecord is the line the update engine writes. Times arrive as text and
// numbers may be null; both are checked here, not trusted to decode.
type agentRunRecord struct {
	ID                   string         `json:"id"`
	Kind                 string         `json:"kind"`
	Trigger              string         `json:"trigger"`
	FromVersion          string         `json:"from_version"`
	ToVersion            string         `json:"to_version"`
	Strategy             string         `json:"strategy"`
	Outcome              string         `json:"outcome"`
	Error                string         `json:"error"`
	StartedAt            string         `json:"started_at"`
	FinishedAt           string         `json:"finished_at"`
	DurationSeconds      int            `json:"duration_seconds"`
	DowntimeSeconds      *int           `json:"downtime_seconds"`
	LongestOutageSeconds *int           `json:"longest_outage_seconds"`
	ProbeSamples         *int           `json:"probe_samples"`
	Phases               map[string]int `json:"phases"`
}

func (s HTTPServer) updateRunStore(w http.ResponseWriter) (control.UpdateRunStore, bool) {
	store, ok := s.Store.(control.UpdateRunStore)
	if !ok {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "update runs unavailable"})
		return nil, false
	}
	return store, true
}

func (s HTTPServer) handleAgentRuns(
	w http.ResponseWriter,
	r *http.Request,
	installation control.Installation,
) {
	store, ok := s.updateRunStore(w)
	if !ok {
		return
	}
	var req agentRunsRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	if len(req.Runs) > maxAgentRunsPerPost {
		writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "too many runs in one request"})
		return
	}
	now := time.Now()
	runs := make([]control.UpdateRun, 0, len(req.Runs))
	skipped := 0
	for _, record := range req.Runs {
		finishedAt, _ := time.Parse(time.RFC3339, strings.TrimSpace(record.FinishedAt))
		startedAt, _ := time.Parse(time.RFC3339, strings.TrimSpace(record.StartedAt))
		run, err := control.NormalizeUpdateRun(control.UpdateRun{
			ID:                   record.ID,
			InstallationID:       installation.ID,
			Kind:                 record.Kind,
			Trigger:              record.Trigger,
			FromVersion:          record.FromVersion,
			ToVersion:            record.ToVersion,
			Strategy:             record.Strategy,
			Outcome:              record.Outcome,
			Error:                record.Error,
			AgentVersion:         req.AgentVersion,
			StartedAt:            startedAt,
			FinishedAt:           finishedAt,
			DurationSeconds:      record.DurationSeconds,
			DowntimeSeconds:      record.DowntimeSeconds,
			LongestOutageSeconds: record.LongestOutageSeconds,
			ProbeSamples:         record.ProbeSamples,
			Phases:               record.Phases,
		}, now)
		if err != nil {
			skipped++
			continue
		}
		runs = append(runs, run)
	}
	added, err := store.RecordUpdateRuns(r.Context(), installation.ID, runs)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"recorded": added,
		"known":    len(runs) - added,
		"skipped":  skipped,
	})
}

type fleetRunView struct {
	control.UpdateRun
	ShopName string `json:"shop_name,omitempty"`
}

type fleetRunSummaryView struct {
	control.UpdateRunSummary
	ShopName string `json:"shop_name,omitempty"`
}

func (s HTTPServer) handleFleetRuns(w http.ResponseWriter, r *http.Request) {
	store, ok := s.updateRunStore(w)
	if !ok {
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	runs, err := store.ListUpdateRuns(r.Context(), control.UpdateRunFilter{
		InstallationID: strings.TrimSpace(r.URL.Query().Get("installation_id")),
		Limit:          limit,
	})
	if err != nil {
		writeStoreError(w, err)
		return
	}
	// Names are a nicety: a store that cannot list shops still shows the runs.
	names := map[string]string{}
	if adminStore, ok := s.Store.(control.AdminSubscriptionStore); ok {
		if installations, err := adminStore.ListInstallations(r.Context(), control.InstallationFilter{}); err == nil {
			for _, installation := range installations {
				names[installation.ID] = installation.ShopName
			}
		}
	}
	views := make([]fleetRunView, 0, len(runs))
	for _, run := range runs {
		views = append(views, fleetRunView{UpdateRun: run, ShopName: names[run.InstallationID]})
	}
	summaries := control.SummarizeUpdateRuns(runs)
	summaryViews := make([]fleetRunSummaryView, 0, len(summaries))
	for _, summary := range summaries {
		summaryViews = append(summaryViews, fleetRunSummaryView{
			UpdateRunSummary: summary,
			ShopName:         names[summary.InstallationID],
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"runs":      views,
		"summaries": summaryViews,
		"count":     len(views),
	})
}
