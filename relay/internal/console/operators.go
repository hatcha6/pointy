package console

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"path"
	"regexp"
	"strconv"
	"strings"

	"pointy/relay/internal/control"
)

// forwardPrefixes are the admin API routes the console may reach. The relay's
// other routes (a phone's relayed request, a shop's own token routes) are
// never forwarded, even though the console adds the admin token.
var forwardPrefixes = []string{
	"/v1/status",
	"/v1/metrics",
	"/v1/installations",
	"/v1/enrollment/tokens",
	"/v1/fleet",
	"/v1/alerts",
	"/v1/finance/",
	"/v1/artifacts",
	"/v1/exchange-rates",
	"/v1/holidays",
	"/v1/sms/usage",
	"/v1/sms/messages",
	"/v1/sms/config",
	"/v1/wallet/admin/",
	"/v1/services/admin/",
	"/v1/vouchers/admin/",
}

func forwardable(route string) bool {
	for _, prefix := range forwardPrefixes {
		if strings.HasSuffix(prefix, "/") {
			if strings.HasPrefix(route, prefix) {
				return true
			}
		} else if route == prefix || strings.HasPrefix(route, prefix+"/") {
			return true
		}
	}
	return false
}

// serveOperator routes a signed-in operator's request: the console's own
// routes, or forwarding to the admin API.
func (c *Console) serveOperator(w http.ResponseWriter, r *http.Request, who session, steppedUp bool) {
	route := strings.TrimPrefix(r.URL.Path, apiPrefix)
	// Only canonical paths: a trailing slash, "//" or ".." spelling of a
	// money route must not slip past the step-up rules below.
	if route == "" || path.Clean(route) != route {
		writeError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	if needsStepUp(r.Method, route) && !steppedUp {
		if !artifactUpload.MatchString(route) {
			writeError(w, http.StatusForbidden, "step_up_required", "this action needs a passkey tap")
			return
		}
		if !c.verifyStreamedStepUp(w, r, who, route) {
			return
		}
		steppedUp = true
	}
	switch {
	case strings.HasPrefix(route, "/v1/"):
		c.forward(w, r, who, route, steppedUp)
	case route == "/operators" && r.Method == http.MethodGet:
		c.handleListOperators(w, r, who.IDHash)
	case route == "/operators/invite" && r.Method == http.MethodPost:
		rec := &recorder{ResponseWriter: w}
		body := peekBody(r)
		c.handleInvite(rec, r, who.Operator.Name)
		c.audit(r, who.Operator, "operators.invite", rec.status(), body, steppedUp)
	case strings.HasPrefix(route, "/operators/") && r.Method == http.MethodPost:
		id, action, _ := strings.Cut(strings.TrimPrefix(route, "/operators/"), "/")
		if id == who.Operator.ID {
			writeError(w, http.StatusConflict, "self", "you cannot disable yourself")
			return
		}
		rec := &recorder{ResponseWriter: w}
		c.handleSetOperatorDisabled(rec, r, id, action, who.Operator.Name)
		c.audit(r, who.Operator, "operators."+action, rec.status(), `{"operator_id":`+jsonString(id)+`}`, steppedUp)
	case strings.HasPrefix(route, "/passkeys/") && r.Method == http.MethodDelete:
		c.handleDeletePasskey(w, r, who, strings.TrimPrefix(route, "/passkeys/"), steppedUp)
	case strings.HasPrefix(route, "/sessions/") && r.Method == http.MethodDelete:
		c.handleDeleteSession(w, r, who, strings.TrimPrefix(route, "/sessions/"))
	case route == "/audit" && r.Method == http.MethodGet:
		c.handleAudit(w, r)
	default:
		writeError(w, http.StatusNotFound, "not_found", "not found")
	}
}

// forward runs the request through the relay's admin handlers as the
// signed-in operator.
func (c *Console) forward(w http.ResponseWriter, r *http.Request, who session, route string, steppedUp bool) {
	if !forwardable(route) {
		writeError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	contentType := r.Header.Get("Content-Type")
	writes := r.Method != http.MethodGet && r.Method != http.MethodHead
	inner := r.Clone(r.Context())
	inner.URL.Path = route
	inner.URL.RawPath = ""
	inner.RequestURI = ""
	var body []byte
	if writes && artifactUpload.MatchString(route) {
		// An update bundle runs to hundreds of megabytes: streamed, never
		// held in memory. It carries no actor; the audit names the operator.
		inner.Body = http.MaxBytesReader(w, r.Body, maxBundleBytes)
		inner.ContentLength = r.ContentLength
	} else {
		var err error
		body, err = io.ReadAll(http.MaxBytesReader(w, r.Body, maxForwardedBody))
		if err != nil {
			writeError(w, http.StatusRequestEntityTooLarge, "too_large", "request too large")
			return
		}
		if writes {
			body = withActor(body, contentType, who.Operator.Name)
		}
		inner.Body = io.NopCloser(bytes.NewReader(body))
		inner.ContentLength = int64(len(body))
	}
	// Only what the admin handlers read: never the browser's cookie.
	inner.Header = http.Header{}
	for _, name := range []string{"Content-Type", "Accept", "Range", "If-None-Match"} {
		if value := r.Header.Get(name); value != "" {
			inner.Header.Set(name, value)
		}
	}
	inner.Header.Set("Authorization", "Bearer "+c.cfg.AdminToken)
	inner.Header.Set("X-Pointy-Admin-Actor", who.Operator.Name)

	rec := &recorder{ResponseWriter: w}
	c.cfg.Admin.ServeHTTP(rec, inner)
	switch {
	case writes && body == nil && r.ContentLength > 0:
		c.audit(r, who.Operator, "", rec.status(), `{"binary_bytes":`+strconv.FormatInt(r.ContentLength, 10)+`}`, steppedUp)
	case writes && quietWrite.MatchString(route):
		// A what-if that changes nothing: auditing every keystroke would
		// bury the real changes.
	case writes:
		c.audit(r, who.Operator, "", rec.status(), auditBody(body, contentType), steppedUp)
	case auditedRead.MatchString(route):
		// A shop's own data leaving the relay is worth a line too.
		c.audit(r, who.Operator, "diagnostics.download", rec.status(), "", false)
	}
}

const maxBundleBytes = 4 << 30

var (
	artifactUpload = regexp.MustCompile(`^/v1/artifacts/[^/]+$`)
	auditedRead    = regexp.MustCompile(`^/v1/installations/[^/]+/diagnostics-analytics$`)
	quietWrite     = regexp.MustCompile(`^/v1/vouchers/admin/settings/preview$`)
)

// withActor names the operator in a JSON object body, replacing any actor
// the browser sent: the console decides who did it, not the request.
func withActor(body []byte, contentType string, actor string) []byte {
	if !isJSON(contentType) && len(bytes.TrimSpace(body)) > 0 {
		return body
	}
	fields := map[string]json.RawMessage{}
	if trimmed := bytes.TrimSpace(body); len(trimmed) > 0 {
		if trimmed[0] != '{' || json.Unmarshal(trimmed, &fields) != nil {
			return body
		}
	}
	fields["actor"] = json.RawMessage(jsonString(actor))
	encoded, err := json.Marshal(fields)
	if err != nil {
		return body
	}
	return encoded
}

func isJSON(contentType string) bool {
	media, _, _ := mime.ParseMediaType(contentType)
	return media == "application/json" || media == ""
}

func auditBody(body []byte, contentType string) string {
	if len(body) == 0 {
		return ""
	}
	if !isJSON(contentType) || !json.Valid(body) {
		return `{"binary_bytes":` + strconv.Itoa(len(body)) + `}`
	}
	if len(body) > control.MaxConsoleAuditBody {
		return `{"truncated":true,"bytes":` + strconv.Itoa(len(body)) + `}`
	}
	var decoded any
	if err := json.Unmarshal(body, &decoded); err != nil {
		return `{"unreadable":true}`
	}
	redacted, err := json.Marshal(redactSecrets(decoded))
	if err != nil {
		return `{"unreadable":true}`
	}
	return string(redacted)
}

// secretKeys are request fields the audit log never keeps: a download's
// Authorization header, a token handed to a supplier.
var secretKeys = regexp.MustCompile(`(?i)^(headers|authorization|password|secret|api_key|.*_token|token)$`)

func redactSecrets(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		for key, inner := range typed {
			if secretKeys.MatchString(key) {
				typed[key] = "[redacted]"
			} else {
				typed[key] = redactSecrets(inner)
			}
		}
	case []any:
		for i := range typed {
			typed[i] = redactSecrets(typed[i])
		}
	}
	return value
}

func peekBody(r *http.Request) string {
	body, _ := io.ReadAll(io.LimitReader(r.Body, maxAuthBody))
	r.Body = io.NopCloser(bytes.NewReader(body))
	return string(body)
}

func (c *Console) audit(r *http.Request, operator control.ConsoleOperator, action string, status int, body string, steppedUp bool) {
	route := strings.TrimPrefix(r.URL.Path, apiPrefix)
	if r.URL.RawQuery != "" {
		route += "?" + r.URL.RawQuery
	}
	if _, err := c.cfg.Store.AppendConsoleAudit(r.Context(), control.ConsoleAuditEvent{
		OperatorID:   operator.ID,
		OperatorName: operator.Name,
		Action:       action,
		Method:       r.Method,
		Path:         route,
		Status:       status,
		Body:         body,
		IP:           c.clientIP(r),
		SteppedUp:    steppedUp,
	}); err != nil {
		c.cfg.Logger.Error("console audit write failed", "operator", operator.Name, "path", route, "error", err)
	}
	c.cfg.Logger.Info("console action", "operator", operator.Name, "action", action,
		"method", r.Method, "path", route, "status", status, "stepped_up", steppedUp)
}

// --- operators -------------------------------------------------------------

type operatorView struct {
	control.ConsoleOperator
	Passkeys []passkeyView `json:"passkeys"`
	Sessions []sessionView `json:"sessions"`
}

type passkeyView struct {
	ID         string `json:"id"`
	Label      string `json:"label"`
	CreatedAt  any    `json:"created_at"`
	LastUsedAt any    `json:"last_used_at"`
}

type sessionView struct {
	ID         string `json:"id"`
	CreatedAt  any    `json:"created_at"`
	LastSeenAt any    `json:"last_seen_at"`
	IP         string `json:"ip"`
	UserAgent  string `json:"user_agent"`
	Current    bool   `json:"current"`
}

func (c *Console) handleListOperators(w http.ResponseWriter, r *http.Request, currentSession ...string) {
	ctx := r.Context()
	operators, err := c.cfg.Store.ConsoleOperators(ctx)
	if err != nil {
		c.internalError(w, "console operators listing failed", err)
		return
	}
	passkeys, err := c.cfg.Store.ConsolePasskeys(ctx, "")
	if err != nil {
		c.internalError(w, "console operators listing failed", err)
		return
	}
	sessions, err := c.cfg.Store.ConsoleSessions(ctx, "")
	if err != nil {
		c.internalError(w, "console operators listing failed", err)
		return
	}
	current := ""
	if len(currentSession) > 0 {
		current = currentSession[0]
	}
	views := make([]operatorView, 0, len(operators))
	for _, operator := range operators {
		view := operatorView{ConsoleOperator: operator, Passkeys: []passkeyView{}, Sessions: []sessionView{}}
		for _, passkey := range passkeys {
			if passkey.OperatorID == operator.ID {
				view.Passkeys = append(view.Passkeys, passkeyView{
					ID: passkey.ID, Label: passkey.Label, CreatedAt: passkey.CreatedAt, LastUsedAt: passkey.LastUsedAt,
				})
			}
		}
		for _, s := range sessions {
			if s.OperatorID == operator.ID {
				view.Sessions = append(view.Sessions, sessionView{
					ID: sessionRef(s.IDHash), CreatedAt: s.CreatedAt, LastSeenAt: s.LastSeenAt,
					IP: s.IP, UserAgent: s.UserAgent, Current: s.IDHash == current,
				})
			}
		}
		views = append(views, view)
	}
	writeJSON(w, http.StatusOK, map[string]any{"operators": views})
}

func (c *Console) handleSetOperatorDisabled(w http.ResponseWriter, r *http.Request, id, action, by string) {
	if action != "disable" && action != "enable" {
		writeError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	operator, err := c.cfg.Store.SetConsoleOperatorDisabled(r.Context(), id, action == "disable")
	if errors.Is(err, control.ErrConsoleOperatorNotFound) {
		writeError(w, http.StatusNotFound, "not_found", "operator not found")
		return
	}
	if err != nil {
		c.internalError(w, "console operator update failed", err)
		return
	}
	c.cfg.Logger.Warn("console operator "+action+"d", "operator", operator.Name, "by", by)
	writeJSON(w, http.StatusOK, map[string]any{"operator": operator})
}

func (c *Console) handleDeletePasskey(w http.ResponseWriter, r *http.Request, who session, id string, steppedUp bool) {
	ctx := r.Context()
	passkey, err := c.cfg.Store.ConsolePasskey(ctx, id)
	if errors.Is(err, control.ErrConsolePasskeyNotFound) {
		writeError(w, http.StatusNotFound, "not_found", "passkey not found")
		return
	}
	if err != nil {
		c.internalError(w, "console passkey delete failed", err)
		return
	}
	if passkey.OperatorID == who.Operator.ID {
		own, err := c.cfg.Store.ConsolePasskeys(ctx, who.Operator.ID)
		if err != nil {
			c.internalError(w, "console passkey delete failed", err)
			return
		}
		if len(own) <= 1 {
			writeError(w, http.StatusConflict, "last_passkey", "this is your only passkey; add another device first")
			return
		}
	}
	if err := c.cfg.Store.DeleteConsolePasskey(ctx, id); err != nil {
		c.internalError(w, "console passkey delete failed", err)
		return
	}
	c.audit(r, who.Operator, "passkeys.delete", http.StatusOK,
		`{"operator_id":`+jsonString(passkey.OperatorID)+`,"label":`+jsonString(passkey.Label)+`}`, steppedUp)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (c *Console) handleDeleteSession(w http.ResponseWriter, r *http.Request, who session, ref string) {
	ctx := r.Context()
	sessions, err := c.cfg.Store.ConsoleSessions(ctx, "")
	if err != nil {
		c.internalError(w, "console session delete failed", err)
		return
	}
	for _, s := range sessions {
		if len(ref) == 16 && sessionRef(s.IDHash) == ref {
			if err := c.cfg.Store.DeleteConsoleSession(ctx, s.IDHash); err != nil {
				c.internalError(w, "console session delete failed", err)
				return
			}
			c.audit(r, who.Operator, "sessions.delete", http.StatusOK, `{"operator_id":`+jsonString(s.OperatorID)+`}`, false)
			writeJSON(w, http.StatusOK, map[string]bool{"ok": true, "current": s.IDHash == who.IDHash})
			return
		}
	}
	writeError(w, http.StatusNotFound, "not_found", "session not found")
}

func (c *Console) handleAudit(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	limit, _ := strconv.Atoi(query.Get("limit"))
	events, err := c.cfg.Store.ConsoleAudit(r.Context(), control.ConsoleAuditFilter{
		OperatorID: strings.TrimSpace(query.Get("operator_id")),
		PathPrefix: strings.TrimSpace(query.Get("path_prefix")),
		Query:      strings.TrimSpace(query.Get("q")),
		Limit:      limit,
		BeforeID:   strings.TrimSpace(query.Get("before")),
	})
	if err != nil {
		c.internalError(w, "console audit listing failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": events})
}

// recorder remembers the status the admin handler wrote.
type recorder struct {
	http.ResponseWriter
	code int
}

func (r *recorder) WriteHeader(code int) {
	if r.code == 0 {
		r.code = code
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *recorder) Write(b []byte) (int, error) {
	if r.code == 0 {
		r.code = http.StatusOK
	}
	return r.ResponseWriter.Write(b)
}

func (r *recorder) Flush() {
	if flusher, ok := r.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (r *recorder) status() int {
	if r.code == 0 {
		return http.StatusOK
	}
	return r.code
}
