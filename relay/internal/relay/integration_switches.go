package relay

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"pointy/relay/internal/control"
)

// The fleet's integration switches: the operator turns one provider
// integration off (or back on) for every shop at once, and each shop's backend
// reads the result off its own status read (GET /v1/installations/{id}, the
// field "integrations_disabled"), then stops talking to that provider.
//
//	GET /v1/fleet/integrations             every switch, and the disabled keys
//	PUT /v1/fleet/integrations/{provider}  {"disabled": true, "reason": "…"}
//
// Both are admin-only. The status read is the installation's own, so a shop
// learns of the switch on its next sync without any new credential.

type setIntegrationSwitchRequest struct {
	Disabled *bool  `json:"disabled"`
	Reason   string `json:"reason"`
	Actor    string `json:"actor"`
}

func (s HTTPServer) integrationSwitchStore(w http.ResponseWriter) (control.IntegrationSwitchStore, bool) {
	store, ok := s.Store.(control.IntegrationSwitchStore)
	if !ok {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "integration switches unavailable"})
		return nil, false
	}
	return store, true
}

func (s HTTPServer) handleListIntegrationSwitches(w http.ResponseWriter, r *http.Request) {
	store, ok := s.integrationSwitchStore(w)
	if !ok {
		return
	}
	switches, err := store.ListIntegrationSwitches(r.Context())
	if err != nil {
		writeStoreError(w, err)
		return
	}
	if switches == nil {
		switches = []control.IntegrationSwitch{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"integrations": switches,
		"disabled":     control.DisabledIntegrations(switches),
	})
}

func (s HTTPServer) handleSetIntegrationSwitch(w http.ResponseWriter, r *http.Request) {
	store, ok := s.integrationSwitchStore(w)
	if !ok {
		return
	}
	provider, valid := control.NormalizeIntegrationKey(
		strings.TrimPrefix(r.URL.Path, "/v1/fleet/integrations/"),
	)
	if !valid {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid provider key"})
		return
	}
	var request setIntegrationSwitchRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&request); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	if request.Disabled == nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "disabled is required"})
		return
	}
	stored, err := store.SetIntegrationSwitch(r.Context(), control.IntegrationSwitch{
		Provider: provider,
		Disabled: *request.Disabled,
		Reason:   adminReason(r, request.Reason),
		Actor:    adminActor(r, request.Actor),
	})
	if errors.Is(err, control.ErrInvalidIntegrationKey) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid provider key"})
		return
	}
	if err != nil {
		writeStoreError(w, err)
		return
	}
	s.logger().Warn(
		"integration switch changed",
		"provider", stored.Provider,
		"disabled", stored.Disabled,
		"actor", stored.Actor,
		"reason", stored.Reason,
	)
	writeJSON(w, http.StatusOK, stored)
}

// withDisabledIntegrations adds the fleet's switched-off provider keys to an
// installation's status read.
//
// A failed read leaves the field OUT rather than empty: to a backend an empty
// list means "every provider may run", which would switch a stopped provider
// back on in every shop because of a database hiccup. Absent means "no news",
// and the backend keeps what it last heard.
func (s HTTPServer) withDisabledIntegrations(r *http.Request, payload map[string]any) map[string]any {
	store, ok := s.Store.(control.IntegrationSwitchStore)
	if !ok {
		return payload
	}
	switches, err := store.ListIntegrationSwitches(r.Context())
	if err != nil {
		s.logger().Error("integration switches unreadable; status read sent without them", "error", err)
		return payload
	}
	payload["integrations_disabled"] = control.DisabledIntegrations(switches)
	return payload
}
