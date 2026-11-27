package agentmcp

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"pointy/relay/internal/control"
)

// The CLI's routes, behind the admin token:
//
//	GET  /v1/mcp/grants              every grant
//	POST /v1/mcp/grants              mint a static token {name, actor, days}
//	POST /v1/mcp/grants/{id}/revoke  revoke one {actor}
//
// A static token is for clients that can send a header (Claude Code, a
// script); claude.ai uses OAuth instead.

func (s *Server) serveAdminGrants(w http.ResponseWriter, r *http.Request) {
	if !constantTimeBearer(r.Header.Get("Authorization"), s.cfg.AdminToken) {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "admin token required"})
		return
	}
	route := strings.TrimPrefix(r.URL.Path, "/v1/mcp/grants")
	switch {
	case route == "" && r.Method == http.MethodGet:
		grants, err := s.cfg.Store.MCPGrants(r.Context())
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "listing grants failed"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"grants": grants, "resource": s.resource})
	case route == "" && r.Method == http.MethodPost:
		s.handleMintToken(w, r)
	case strings.HasSuffix(route, "/revoke") && r.Method == http.MethodPost:
		id := strings.TrimSuffix(strings.TrimPrefix(route, "/"), "/revoke")
		var request struct {
			Actor string `json:"actor"`
		}
		_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, maxOAuthBody)).Decode(&request)
		actor := firstNonEmpty(request.Actor, r.Header.Get("X-Pointy-Admin-Actor"), "admin")
		grant, err := s.cfg.Store.RevokeMCPGrant(r.Context(), id, actor)
		if errors.Is(err, control.ErrMCPGrantNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "no such live grant"})
			return
		}
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "revoking failed"})
			return
		}
		s.cfg.Operators.Audit(r.Context(), control.ConsoleAuditEvent{
			OperatorID: "admin", OperatorName: actor, Action: "mcp.revoke", Method: http.MethodPost,
			Path: r.URL.Path, Status: http.StatusOK, Body: `{"grant_id":"` + grant.ID + `"}`, IP: s.clientIP(r),
		})
		writeJSON(w, http.StatusOK, map[string]any{"grant": grant})
	default:
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
	}
}

func (s *Server) handleMintToken(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Name  string `json:"name"`
		Actor string `json:"actor"`
		Days  int    `json:"days"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxOAuthBody)).Decode(&request); err != nil ||
		strings.TrimSpace(request.Name) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "name is required"})
		return
	}
	ttl := defaultTokenTTL
	if request.Days > 0 {
		ttl = min(time.Duration(request.Days)*24*time.Hour, maxTokenTTL)
	}
	raw, err := newSecret("st")
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "token generation failed"})
		return
	}
	actor := firstNonEmpty(request.Actor, r.Header.Get("X-Pointy-Admin-Actor"), "admin")
	expires := s.cfg.Now().Add(ttl)
	grant, err := s.cfg.Store.CreateMCPGrant(r.Context(), control.MCPGrant{
		Name: truncate(strings.TrimSpace(request.Name), 80), Kind: control.MCPGrantToken, Scope: Scope,
		GrantedByID: "admin", GrantedBy: actor, AccessHash: hashSecret(raw), AccessExpiresAt: &expires,
	})
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "creating the grant failed"})
		return
	}
	s.cfg.Operators.Audit(r.Context(), control.ConsoleAuditEvent{
		OperatorID: "admin", OperatorName: actor, Action: "mcp.token", Method: http.MethodPost,
		Path: r.URL.Path, Status: http.StatusCreated, Body: `{"grant_id":"` + grant.ID + `"}`, IP: s.clientIP(r),
	})
	s.notify("رمز Claude جديد: "+grant.Name, actor+" minted a read-only MCP token (grant "+grant.ID+").")
	writeJSON(w, http.StatusCreated, map[string]any{"grant": grant, "token": raw, "resource": s.resource})
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value = strings.TrimSpace(value); value != "" {
			return truncate(value, 60)
		}
	}
	return ""
}
