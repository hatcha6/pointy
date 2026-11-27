package agentmcp

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"

	"pointy/relay/internal/control"
)

// The MCP endpoint: Streamable HTTP, answered with plain JSON (no SSE
// stream, no session). Every request carries a grant's bearer token.

// supportedVersions are the protocol revisions this server speaks, newest
// first. An unknown requested version gets the newest.
var supportedVersions = []string{"2025-11-25", "2025-06-18", "2025-03-26"}

const maxRPCBody = 64 << 10

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (s *Server) serveMCP(w http.ResponseWriter, r *http.Request) {
	// DNS rebinding: a browser page elsewhere must not reach the endpoint.
	if origin := r.Header.Get("Origin"); origin != "" && origin != s.origin.String() &&
		!slices.Contains([]string{"https://claude.ai", "https://claude.com"}, origin) {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "origin not allowed"})
		return
	}
	grant, ok := s.authenticate(w, r)
	if !ok {
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	body, err := readLimited(w, r)
	if err != nil {
		writeRPC(w, nil, nil, &rpcError{Code: -32700, Message: "request too large or unreadable"})
		return
	}
	if trimmed := bytes.TrimSpace(body); len(trimmed) > 0 && trimmed[0] == '[' {
		writeRPC(w, nil, nil, &rpcError{Code: -32600, Message: "batches are not supported"})
		return
	}
	var request rpcRequest
	if err := json.Unmarshal(body, &request); err != nil || request.JSONRPC != "2.0" || request.Method == "" {
		writeRPC(w, nil, nil, &rpcError{Code: -32600, Message: "invalid JSON-RPC request"})
		return
	}
	if len(request.ID) == 0 {
		// A notification (initialized, cancelled): nothing to answer.
		w.WriteHeader(http.StatusAccepted)
		return
	}
	switch request.Method {
	case "initialize":
		writeRPC(w, request.ID, s.initializeResult(request.Params), nil)
	case "ping":
		writeRPC(w, request.ID, map[string]any{}, nil)
	case "tools/list":
		writeRPC(w, request.ID, map[string]any{"tools": s.toolList()}, nil)
	case "tools/call":
		result, rpcErr := s.callTool(r, grant, request.Params)
		writeRPC(w, request.ID, result, rpcErr)
	case "resources/list", "prompts/list":
		key := strings.Split(request.Method, "/")[0]
		writeRPC(w, request.ID, map[string]any{key: []any{}}, nil)
	default:
		writeRPC(w, request.ID, nil, &rpcError{Code: -32601, Message: "method not found: " + request.Method})
	}
}

// authenticate resolves the bearer token to a live grant, or answers 401 with
// the metadata pointer claude.ai starts OAuth from.
func (s *Server) authenticate(w http.ResponseWriter, r *http.Request) (control.MCPGrant, bool) {
	challenge := `Bearer resource_metadata="` + s.origin.String() + `/.well-known/oauth-protected-resource` + MCPPath + `", scope="` + Scope + `"`
	raw, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	raw = strings.TrimSpace(raw)
	if !ok || raw == "" {
		w.Header().Set("WWW-Authenticate", challenge)
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return control.MCPGrant{}, false
	}
	if raw == s.cfg.AdminToken {
		// The fleet admin token is never accepted here.
		w.Header().Set("WWW-Authenticate", challenge+`, error="invalid_token"`)
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid_token"})
		return control.MCPGrant{}, false
	}
	grant, err := s.cfg.Store.MCPGrantByAccess(r.Context(), hashSecret(raw))
	if err != nil {
		if !errors.Is(err, control.ErrMCPGrantNotFound) {
			s.cfg.Logger.Error("mcp grant lookup failed", "error", err)
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "temporarily unavailable"})
			return control.MCPGrant{}, false
		}
		w.Header().Set("WWW-Authenticate", challenge+`, error="invalid_token"`)
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid_token"})
		return control.MCPGrant{}, false
	}
	if grant.Scope != Scope {
		w.Header().Set("WWW-Authenticate", challenge+`, error="insufficient_scope"`)
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "insufficient_scope"})
		return control.MCPGrant{}, false
	}
	return grant, true
}

func (s *Server) initializeResult(params json.RawMessage) map[string]any {
	var asked struct {
		ProtocolVersion string `json:"protocolVersion"`
	}
	_ = json.Unmarshal(params, &asked)
	version := supportedVersions[0]
	if slices.Contains(supportedVersions, asked.ProtocolVersion) {
		version = asked.ProtocolVersion
	}
	return map[string]any{
		"protocolVersion": version,
		"capabilities":    map[string]any{"tools": map[string]any{"listChanged": false}},
		"serverInfo": map[string]any{
			"name":    "pointy-relay",
			"title":   "دفتر — نظرة على الأعمال",
			"version": s.cfg.Version,
		},
		"instructions": serverInstructions,
	}
}

const serverInstructions = `Read-only view of the Daftar (Pointy) relay: the company that sells prepaid cards, airtime and bill payments to Libyan shops and to the Daftar Cards consumer app.
Money is in Libyan dinars (LYD, 3 decimals) unless a field says USD. Times are UTC; Libya is UTC+2.
Suppliers: bnplus (BN Plus, dinars), fazer (FazerCards, USD), reloadly (Reloadly, USD), esimaccess (eSIM Access, USD). Dollar suppliers are funded with USDT bought at the parallel-market rate; dollar_rate shows the fulus.ly series and the funding-aware pricing quote.
Daftar Cards app tools (cards_*) cover the consumer app: customers by id, orders, reports, campaigns and its shelf.
Card codes, PINs, tokens and customer contact details are removed from every answer. Nothing here can change anything.`

func (s *Server) toolList() []map[string]any {
	list := make([]map[string]any, 0, len(s.toolOrder))
	for _, name := range s.toolOrder {
		t := s.tools[name]
		list = append(list, map[string]any{
			"name":        name,
			"title":       t.title,
			"description": t.description,
			"inputSchema": t.schema(),
			"annotations": map[string]any{
				"title": t.title, "readOnlyHint": true, "destructiveHint": false,
				"idempotentHint": true, "openWorldHint": false,
			},
		})
	}
	return list
}

func readLimited(w http.ResponseWriter, r *http.Request) ([]byte, error) {
	var buf bytes.Buffer
	_, err := buf.ReadFrom(http.MaxBytesReader(w, r.Body, maxRPCBody))
	return buf.Bytes(), err
}

func writeRPC(w http.ResponseWriter, id json.RawMessage, result any, rpcErr *rpcError) {
	if len(id) == 0 {
		id = json.RawMessage("null")
	}
	response := map[string]any{"jsonrpc": "2.0", "id": id}
	if rpcErr != nil {
		response["error"] = rpcErr
	} else {
		response["result"] = result
	}
	writeJSON(w, http.StatusOK, response)
}
