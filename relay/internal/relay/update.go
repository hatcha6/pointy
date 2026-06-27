package relay

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"pointy/relay/internal/artifacts"
	"pointy/relay/internal/control"
)

const connectorTokenHeaderName = "X-Pointy-Connector-Token"

// withConnectorToken authenticates an on-prem update-agent request by its
// connector token (the same secret the connector tunnel handshake uses, which
// the agent reads from the connector-state volume) and hands the resolved
// installation to the handler. Connector-token validation deliberately does not
// gate on the subscription, so we can still update a shop whose subscription has
// lapsed.
func (s HTTPServer) withConnectorToken(
	w http.ResponseWriter,
	r *http.Request,
	handler func(http.ResponseWriter, *http.Request, control.Installation),
) {
	token := strings.TrimSpace(r.Header.Get(connectorTokenHeaderName))
	if token == "" {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "connector token required"})
		return
	}
	installation, err := s.Store.ValidateConnectorToken(r.Context(), token)
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "connector token rejected"})
		return
	}
	handler(w, r, installation)
}

func (s HTTPServer) updateStore(w http.ResponseWriter) (control.UpdateStore, bool) {
	store, ok := s.Store.(control.UpdateStore)
	if !ok {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "update store unavailable"})
		return nil, false
	}
	return store, true
}

func (s HTTPServer) requireArtifactStore(w http.ResponseWriter) (*artifacts.Store, bool) {
	if s.Artifacts == nil {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "artifact store unavailable"})
		return nil, false
	}
	return s.Artifacts, true
}

// artifactPresent reports whether a usable bundle exists for a version.
func (s HTTPServer) artifactPresent(version string) bool {
	return s.Artifacts != nil && s.Artifacts.Has(version)
}

type bundleDescriptor struct {
	Version string `json:"version"`
	SHA256  string `json:"sha256"`
	Size    int64  `json:"size"`
	Path    string `json:"path"`
}

type agentManifestResponse struct {
	InstallationID  string            `json:"installation_id"`
	Channel         string            `json:"channel"`
	CurrentVersion  string            `json:"current_version"`
	AssignedVersion string            `json:"assigned_version"`
	Directive       string            `json:"directive"` // apply | hold
	Bundle          *bundleDescriptor `json:"bundle,omitempty"`
}

// handleAgentManifest tells an installation which version it should run. The
// rollout gate (pin > channel target + phase) is computed here so the agent stays
// dumb: it only obeys directive/assigned_version.
func (s HTTPServer) handleAgentManifest(
	w http.ResponseWriter,
	r *http.Request,
	installation control.Installation,
) {
	store, ok := s.updateStore(w)
	if !ok {
		return
	}
	target := control.ChannelTarget{}
	if installation.PinnedVersion == "" {
		found, has, err := store.GetChannelTarget(r.Context(), installation.UpdateChannel)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "manifest lookup failed"})
			return
		}
		if has {
			target = found
		}
	}
	version, directive := control.AssignedUpdate(installation, target, s.artifactPresent)

	resp := agentManifestResponse{
		InstallationID:  installation.ID,
		Channel:         control.NormalizeChannel(installation.UpdateChannel),
		CurrentVersion:  installation.CurrentVersion,
		AssignedVersion: version,
		Directive:       directive,
	}
	if directive == "apply" && s.Artifacts != nil {
		if meta, found, err := s.Artifacts.Get(version); err == nil && found {
			resp.Bundle = &bundleDescriptor{
				Version: meta.Version,
				SHA256:  meta.SHA256,
				Size:    meta.Size,
				Path:    "/v1/agent/artifacts/" + meta.Version,
			}
		}
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleAgentArtifact streams a bundle to the agent. http.ServeContent gives
// Range/resume support for free, which matters on flaky shop links.
func (s HTTPServer) handleAgentArtifact(
	w http.ResponseWriter,
	r *http.Request,
	_ control.Installation,
) {
	store, ok := s.requireArtifactStore(w)
	if !ok {
		return
	}
	version := strings.TrimPrefix(r.URL.Path, "/v1/agent/artifacts/")
	if version == "" || strings.Contains(version, "/") {
		writeNotFound(w)
		return
	}
	file, meta, err := store.Open(version)
	if errors.Is(err, artifacts.ErrNotFound) {
		writeNotFound(w)
		return
	}
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "artifact open failed"})
		return
	}
	defer file.Close()
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("X-Pointy-Artifact-SHA256", meta.SHA256)
	w.Header().Set("ETag", `"`+meta.SHA256+`"`)
	http.ServeContent(w, r, "bundle.zip", meta.CreatedAt, file)
}

type agentStatusRequest struct {
	CurrentVersion string `json:"current_version"`
	AgentVersion   string `json:"agent_version"`
	UpdateStatus   string `json:"update_status"`
	UpdateError    string `json:"update_error"`
}

func (s HTTPServer) handleAgentStatus(
	w http.ResponseWriter,
	r *http.Request,
	installation control.Installation,
) {
	store, ok := s.updateStore(w)
	if !ok {
		return
	}
	var req agentStatusRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	updated, err := store.ReportAgentStatus(r.Context(), installation.ID, control.AgentStatus{
		CurrentVersion: req.CurrentVersion,
		AgentVersion:   req.AgentVersion,
		UpdateStatus:   req.UpdateStatus,
		UpdateError:    req.UpdateError,
	})
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"installation_id": updated.ID,
		"current_version": updated.CurrentVersion,
		"update_status":   updated.UpdateStatus,
	})
}

type fleetInstallationView struct {
	ID              string     `json:"id"`
	ShopName        string     `json:"shop_name,omitempty"`
	Channel         string     `json:"channel"`
	CurrentVersion  string     `json:"current_version,omitempty"`
	AssignedVersion string     `json:"assigned_version,omitempty"`
	Directive       string     `json:"directive"`
	PinnedVersion   string     `json:"pinned_version,omitempty"`
	UpdateStatus    string     `json:"update_status,omitempty"`
	UpdateError     string     `json:"update_error,omitempty"`
	AgentVersion    string     `json:"agent_version,omitempty"`
	AgentLastSeenAt *time.Time `json:"agent_last_seen_at,omitempty"`
	LastUpdateAt    *time.Time `json:"last_update_at,omitempty"`
}

func (s HTTPServer) handleFleetStatus(w http.ResponseWriter, r *http.Request) {
	store, ok := s.updateStore(w)
	if !ok {
		return
	}
	adminStore, ok := s.Store.(control.AdminSubscriptionStore)
	if !ok {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "installation store unavailable"})
		return
	}
	installations, err := adminStore.ListInstallations(r.Context(), control.InstallationFilter{
		Query: strings.TrimSpace(r.URL.Query().Get("query")),
	})
	if err != nil {
		writeStoreError(w, err)
		return
	}
	targetList, err := store.ListChannelTargets(r.Context())
	if err != nil {
		writeStoreError(w, err)
		return
	}
	targets := make(map[string]control.ChannelTarget, len(targetList))
	for _, target := range targetList {
		targets[target.Channel] = target
	}

	views := make([]fleetInstallationView, 0, len(installations))
	for _, installation := range installations {
		channel := control.NormalizeChannel(installation.UpdateChannel)
		version, directive := control.AssignedUpdate(installation, targets[channel], s.artifactPresent)
		views = append(views, fleetInstallationView{
			ID:              installation.ID,
			ShopName:        installation.ShopName,
			Channel:         channel,
			CurrentVersion:  installation.CurrentVersion,
			AssignedVersion: version,
			Directive:       directive,
			PinnedVersion:   installation.PinnedVersion,
			UpdateStatus:    installation.UpdateStatus,
			UpdateError:     installation.UpdateError,
			AgentVersion:    installation.AgentVersion,
			AgentLastSeenAt: installation.AgentLastSeenAt,
			LastUpdateAt:    installation.LastUpdateAt,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"installations": views,
		"channels":      targetList,
		"count":         len(views),
	})
}

type setChannelTargetRequest struct {
	TargetVersion  string   `json:"target_version"`
	RolloutPhase   string   `json:"rollout_phase"`
	RolloutPercent int      `json:"rollout_percent"`
	CanaryIDs      []string `json:"canary_ids"`
}

func (s HTTPServer) handleSetChannelTarget(w http.ResponseWriter, r *http.Request) {
	store, ok := s.updateStore(w)
	if !ok {
		return
	}
	channel := strings.TrimPrefix(r.URL.Path, "/v1/fleet/channels/")
	if channel == "" || strings.Contains(channel, "/") {
		writeNotFound(w)
		return
	}
	var req setChannelTargetRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	phase := strings.TrimSpace(req.RolloutPhase)
	switch phase {
	case control.RolloutPaused, control.RolloutCanary, control.RolloutPercent, control.RolloutAll:
	case "":
		phase = control.RolloutPaused
	default:
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid rollout_phase"})
		return
	}
	if req.RolloutPercent < 0 || req.RolloutPercent > 100 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "rollout_percent must be 0-100"})
		return
	}
	targetVersion := strings.TrimSpace(req.TargetVersion)
	if targetVersion != "" && !s.artifactPresent(targetVersion) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "no artifact uploaded for that version"})
		return
	}
	if err := store.UpsertChannelTarget(r.Context(), control.ChannelTarget{
		Channel:        channel,
		TargetVersion:  targetVersion,
		RolloutPhase:   phase,
		RolloutPercent: req.RolloutPercent,
		CanaryIDs:      req.CanaryIDs,
	}); err != nil {
		writeStoreError(w, err)
		return
	}
	stored, _, err := store.GetChannelTarget(r.Context(), channel)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, stored)
}

// handleAdminArtifact uploads (POST/PUT) or inspects (GET) a bundle for a version.
func (s HTTPServer) handleAdminArtifact(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireArtifactStore(w)
	if !ok {
		return
	}
	version := strings.TrimPrefix(r.URL.Path, "/v1/artifacts/")
	if version == "" || strings.Contains(version, "/") {
		writeNotFound(w)
		return
	}
	switch r.Method {
	case http.MethodPost, http.MethodPut:
		meta, err := store.Put(version, r.Body)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusCreated, meta)
	case http.MethodGet:
		meta, found, err := store.Get(version)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "artifact lookup failed"})
			return
		}
		if !found {
			writeNotFound(w)
			return
		}
		writeJSON(w, http.StatusOK, meta)
	default:
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
	}
}

type installationUpdateConfigRequest struct {
	Channel       *string `json:"channel,omitempty"`
	PinnedVersion *string `json:"pinned_version,omitempty"`
}

func (s HTTPServer) handleInstallationUpdateConfig(w http.ResponseWriter, r *http.Request, id string) {
	store, ok := s.updateStore(w)
	if !ok {
		return
	}
	var req installationUpdateConfigRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	installation, err := s.Store.GetInstallation(r.Context(), id)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	changed := false
	if req.Channel != nil {
		installation, err = store.SetInstallationChannel(r.Context(), id, *req.Channel)
		if err != nil {
			writeStoreError(w, err)
			return
		}
		changed = true
	}
	if req.PinnedVersion != nil {
		installation, err = store.PinInstallationVersion(r.Context(), id, *req.PinnedVersion)
		if err != nil {
			writeStoreError(w, err)
			return
		}
		changed = true
	}
	if !changed {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "nothing to update"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"installation_id": installation.ID,
		"update_channel":  control.NormalizeChannel(installation.UpdateChannel),
		"pinned_version":  installation.PinnedVersion,
	})
}
