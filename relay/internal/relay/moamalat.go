package relay

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/moamalat"
)

// A shop's copy of its Moamalat merchant token, kept warm by the relay as the
// second keepalive behind the shop's own backend
// (tools/moamalat-capture/TOKEN_CUSTODY_DESIGN.md):
//
//	GET    /v1/moamalat/link       the relay's state of this shop's token
//	PUT    /v1/moamalat/link       {mid, token, token_id}: hold this token
//	DELETE /v1/moamalat/link       drop the copy (unlink, shop-side disable)
//	POST   /v1/moamalat/link/dead  {token_id}: the backend saw this token die
//	GET    /v1/moamalat/admin/links  every shop's keepalive (admin)
//
// The shop routes take the installation token for identity only: keeping a
// token warm costs the company next to nothing, and a lapsed subscription must
// not cost the shop an OTP.

const moamalatMaxTokenBytes = 4096

type moamalatPutRequest struct {
	MID     string `json:"mid"`
	Token   string `json:"token"`
	TokenID string `json:"token_id"`
}

type moamalatDeadRequest struct {
	TokenID string `json:"token_id"`
}

func (s HTTPServer) handleMoamalatRoutes(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	switch {
	case path == "/v1/moamalat/admin/links" && r.Method == http.MethodGet:
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withAdmin(w, r, s.handleMoamalatAdminLinks)
	case !s.RouteMode.allowsPublic():
		writeNotFound(w)
	case path == "/v1/moamalat/link" && r.Method == http.MethodGet:
		s.handleMoamalatLinkGet(w, r)
	case path == "/v1/moamalat/link" && r.Method == http.MethodPut:
		s.handleMoamalatLinkPut(w, r)
	case path == "/v1/moamalat/link" && r.Method == http.MethodDelete:
		s.handleMoamalatLinkDelete(w, r)
	case path == "/v1/moamalat/link/dead" && r.Method == http.MethodPost:
		s.handleMoamalatLinkDead(w, r)
	default:
		writeNotFound(w)
	}
}

func (s HTTPServer) moamalatStore(w http.ResponseWriter) (control.MoamalatStore, bool) {
	store, ok := s.Store.(control.MoamalatStore)
	if !ok || s.MoamalatSealer == nil {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "moamalat keepalive unavailable"})
		return nil, false
	}
	return store, true
}

// moamalatLinkView is everything about a link the relay ever answers: never
// the sealed token.
func moamalatLinkView(link control.MoamalatLink, now time.Time) map[string]any {
	view := map[string]any{
		"linked":       true,
		"mid":          link.MID,
		"token_id":     link.TokenID,
		"state":        link.State,
		"failures":     link.Failures,
		"next_poke_at": link.NextPokeAt,
		"linked_at":    link.LinkedAt,
		"updated_at":   link.UpdatedAt,
	}
	since := link.LastOKAt
	if since.IsZero() {
		since = link.LinkedAt
	}
	if !link.LastOKAt.IsZero() {
		view["last_ok_at"] = link.LastOKAt
	}
	if !link.LastAttemptAt.IsZero() {
		view["last_attempt_at"] = link.LastAttemptAt
	}
	if link.LastError != "" {
		view["last_error"] = link.LastError
	}
	if !link.DiedAt.IsZero() {
		view["died_at"] = link.DiedAt
		view["death_source"] = link.DeathSource
	}
	view["at_risk"] = link.State == control.MoamalatAlive && moamalat.AtRisk(now.Sub(since))
	return view
}

func (s HTTPServer) moamalatSwitchedOff(r *http.Request) bool {
	store, ok := s.Store.(control.IntegrationSwitchStore)
	if !ok {
		return false
	}
	switches, err := store.ListIntegrationSwitches(r.Context())
	if err != nil {
		// Unreadable: refuse to take a token rather than keep one warm
		// against a switch that may be thrown.
		return true
	}
	for _, sw := range switches {
		if sw.Provider == control.MoamalatIntegrationKey && sw.Disabled {
			return true
		}
	}
	return false
}

func (s HTTPServer) handleMoamalatLinkGet(w http.ResponseWriter, r *http.Request) {
	store, ok := s.moamalatStore(w)
	if !ok {
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	link, err := store.GetMoamalatLink(r.Context(), installation.ID)
	if errors.Is(err, control.ErrNotFound) {
		writeJSON(w, http.StatusOK, map[string]any{"linked": false})
		return
	}
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, moamalatLinkView(link, s.clock().Now()))
}

func (s HTTPServer) handleMoamalatLinkPut(w http.ResponseWriter, r *http.Request) {
	store, ok := s.moamalatStore(w)
	if !ok {
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	if s.moamalatSwitchedOff(r) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "switched_off"})
		return
	}
	var request moamalatPutRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<14)).Decode(&request); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	token := strings.TrimSpace(request.Token)
	if token == "" || len(token) > moamalatMaxTokenBytes || strings.Count(token, ".") != 2 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "token must be a bearer JWT"})
		return
	}
	mid := strings.TrimSpace(request.MID)
	sealed, err := s.MoamalatSealer.Seal(installation.ID, mid, token)
	if err != nil {
		s.logger().Error("moamalat token seal failed", "installation_id", installation.ID, "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "seal failed"})
		return
	}
	link, err := store.PutMoamalatLink(r.Context(), control.MoamalatLink{
		InstallationID: installation.ID,
		MID:            mid,
		TokenID:        request.TokenID,
		SealedToken:    sealed,
	})
	if errors.Is(err, control.ErrInvalidMoamalatLink) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "mid and token_id are required"})
		return
	}
	if err != nil {
		writeStoreError(w, err)
		return
	}
	// A fresh token ends whatever the old one was alerted for.
	s.releaseMoamalatAlerts(installation.ID)
	s.logger().Info("moamalat token linked", "installation_id", installation.ID, "token_id", link.TokenID)
	writeJSON(w, http.StatusOK, moamalatLinkView(link, s.clock().Now()))
}

func (s HTTPServer) handleMoamalatLinkDelete(w http.ResponseWriter, r *http.Request) {
	store, ok := s.Store.(control.MoamalatStore)
	if !ok {
		// Nothing held, nothing to delete.
		writeJSON(w, http.StatusOK, map[string]any{"deleted": false})
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	deleted, err := store.DeleteMoamalatLink(r.Context(), installation.ID)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	s.releaseMoamalatAlerts(installation.ID)
	if deleted {
		s.logger().Info("moamalat token copy deleted", "installation_id", installation.ID)
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": deleted})
}

func (s HTTPServer) handleMoamalatLinkDead(w http.ResponseWriter, r *http.Request) {
	store, ok := s.Store.(control.MoamalatStore)
	if !ok {
		writeJSON(w, http.StatusOK, map[string]any{"applied": false})
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	var request moamalatDeadRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<12)).Decode(&request); err != nil || strings.TrimSpace(request.TokenID) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "token_id is required"})
		return
	}
	link, applied, err := store.MarkMoamalatDead(r.Context(), installation.ID, strings.TrimSpace(request.TokenID), "backend")
	if err != nil {
		writeStoreError(w, err)
		return
	}
	if applied {
		s.logger().Warn("moamalat token reported dead by the shop", "installation_id", installation.ID, "token_id", link.TokenID)
		s.alertMoamalatReauth(installation.ID, link)
	}
	writeJSON(w, http.StatusOK, map[string]any{"applied": applied})
}

func (s HTTPServer) handleMoamalatAdminLinks(w http.ResponseWriter, r *http.Request) {
	store, ok := s.Store.(control.MoamalatStore)
	if !ok {
		writeJSON(w, http.StatusOK, map[string]any{"links": []any{}, "available": false})
		return
	}
	links, err := store.ListMoamalatLinks(r.Context())
	if err != nil {
		writeStoreError(w, err)
		return
	}
	now := s.clock().Now()
	out := make([]map[string]any, 0, len(links))
	for _, link := range links {
		view := moamalatLinkView(link, now)
		view["installation_id"] = link.InstallationID
		if installation, err := s.Store.GetInstallation(r.Context(), link.InstallationID); err == nil {
			view["shop_name"] = installation.ShopName
		}
		out = append(out, view)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"links":        out,
		"available":    s.MoamalatSealer != nil,
		"switched_off": s.moamalatSwitchedOff(r),
	})
}
