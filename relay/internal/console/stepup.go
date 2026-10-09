package console

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"hash"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
)

// A step-up is a fresh passkey tap that authorizes exactly one request. The
// browser sends the request it is about to make (method, path, body); the
// relay binds the passkey challenge to the SHA-256 of that request, and on the
// way back runs that request and no other. A grant cannot be replayed (the
// challenge is taken once), moved to another request (the hash), or used by
// another browser (it is tied to the session).

// stepUpRule names a request that needs a passkey tap. Paths are relative to
// /console/api; a * matches one path segment.
type stepUpRule struct {
	method  string
	pattern *regexp.Regexp
}

func rule(method string, path string) stepUpRule {
	quoted := strings.ReplaceAll(regexp.QuoteMeta(path), `\*`, `[^/]+`)
	return stepUpRule{method: method, pattern: regexp.MustCompile("^" + quoted + "$")}
}

// stepUpRules are the money and security actions. Add new money flows
// (cash credits, bank-transfer approvals) here.
var stepUpRules = []stepUpRule{
	// Money: hand-made wallet movements and credits.
	rule(http.MethodPost, "/v1/wallet/admin/entries"),
	rule(http.MethodPost, "/v1/wallet/admin/topups/*/confirm"),
	rule(http.MethodPost, "/v1/wallet/admin/topups/*/reject"),
	// Where shops send their money.
	rule(http.MethodPut, "/v1/wallet/admin/bank-accounts"),
	rule(http.MethodPost, "/v1/vouchers/admin/purchases/*/resolve"),
	// Prices every shop pays.
	rule(http.MethodPut, "/v1/vouchers/admin/catalog"),
	rule(http.MethodPut, "/v1/vouchers/admin/settings"),
	// What every shop installs: a bundle (uploaded, or fetched by the relay
	// from a URL), a channel's version and rollout, one shop's pinned version
	// or channel. An upload carries its tap in headers (verifyStreamedStepUp).
	rule(http.MethodPost, "/v1/artifacts/*"),
	rule(http.MethodPut, "/v1/artifacts/*"),
	rule(http.MethodPost, "/v1/artifacts/*/fetch"),
	rule(http.MethodPut, "/v1/fleet/channels/*"),
	rule(http.MethodPatch, "/v1/installations/*/update"),
	// Credentials: a new shop's tokens, license keys.
	rule(http.MethodPost, "/v1/installations"),
	rule(http.MethodPost, "/v1/enrollment/tokens"),
	// Who can get in.
	rule(http.MethodPost, "/operators/invite"),
	rule(http.MethodPost, "/operators/*/disable"),
	rule(http.MethodPost, "/operators/*/enable"),
	rule(http.MethodDelete, "/passkeys/*"),
}

func needsStepUp(method string, route string) bool {
	for _, r := range stepUpRules {
		if r.method == method && r.pattern.MatchString(route) {
			return true
		}
	}
	return false
}

type stepUpRequest struct {
	Method string `json:"method"`
	Path   string `json:"path"`
	Body   string `json:"body"`
	// BodySHA256 lets the begin call carry a large body's hash instead of
	// the body (a voucher catalog runs to megabytes). The run call always
	// carries the body itself, and it is hashed again there.
	BodySHA256 string `json:"body_sha256,omitempty"`
}

func bodyHash(body string) string {
	sum := sha256.Sum256([]byte(body))
	return hex.EncodeToString(sum[:])
}

// actionHash is what a passkey tap authorizes: one method, path and body.
func actionHash(method, path, bodySHA256 string) string {
	sum := sha256.Sum256([]byte(strings.ToUpper(method) + "\n" + path + "\n" + strings.ToLower(bodySHA256)))
	return hex.EncodeToString(sum[:])
}

func (c *Console) handleStepUpBegin(w http.ResponseWriter, r *http.Request, who session) {
	var request stepUpRequest
	if !decodeBody(w, r, &request) {
		return
	}
	route, ok := stepUpRoute(request.Path)
	if !ok || !needsStepUp(strings.ToUpper(request.Method), route) {
		writeError(w, http.StatusBadRequest, "no_step_up", "this action does not need a passkey tap")
		return
	}
	user, err := c.loadUser(r, who.Operator.ID)
	if err != nil || len(user.credentials) == 0 {
		writeError(w, http.StatusUnauthorized, "signed_out", "sign in again")
		return
	}
	assertion, data, err := c.webAuthn.BeginLogin(user, webauthn.WithUserVerification(protocol.VerificationRequired))
	if err != nil {
		c.internalError(w, "console step-up begin failed", err)
		return
	}
	challengeID, err := c.putCeremonyPayload(r, tokenStepUp, who.Operator.ID, who.IDHash, ceremonyPayload{
		Session: *data,
		Action:  actionHash(request.Method, request.Path, beginBodyHash(request)),
	})
	if err != nil {
		c.internalError(w, "console step-up begin failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"challenge_id": challengeID, "options": assertion})
}

type stepUpRun struct {
	stepUpRequest
	ChallengeID string          `json:"challenge_id"`
	Credential  json.RawMessage `json:"credential"`
}

func (c *Console) handleStepUpRun(w http.ResponseWriter, r *http.Request, who session) {
	var request stepUpRun
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxForwardedBody))
	if err == nil {
		err = json.Unmarshal(body, &request)
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "invalid request body")
		return
	}
	if _, ok := stepUpRoute(request.Path); !ok {
		writeError(w, http.StatusBadRequest, "bad_request", "invalid path")
		return
	}
	if !c.verifyStepUp(w, r, who, request.ChallengeID, request.Credential,
		actionHash(request.Method, request.Path, bodyHash(request.Body))) {
		return
	}
	inner := r.Clone(r.Context())
	inner.Method = strings.ToUpper(request.Method)
	target, _ := url.Parse(apiPrefix + request.Path)
	inner.URL = target
	inner.RequestURI = ""
	inner.Body = io.NopCloser(bytes.NewReader([]byte(request.Body)))
	inner.ContentLength = int64(len(request.Body))
	inner.Header = r.Header.Clone()
	inner.Header.Set("Content-Type", "application/json")
	c.serveOperator(w, inner, who, true)
}

// verifyStepUp takes the challenge and checks the passkey's answer was given
// for this session, this operator and exactly this action. It writes the
// refusal itself.
func (c *Console) verifyStepUp(
	w http.ResponseWriter,
	r *http.Request,
	who session,
	challengeID string,
	credentialJSON []byte,
	action string,
) bool {
	payload, token, ok := c.takeCeremonyPayload(w, r, tokenStepUp, challengeID)
	if !ok {
		return false
	}
	if token.OperatorID != who.Operator.ID || token.Subject != who.IDHash || payload.Action != action {
		c.cfg.Logger.Warn("console step-up did not match its request", "operator", who.Operator.Name)
		writeError(w, http.StatusForbidden, "step_up_mismatch", "the passkey tap was for a different action")
		return false
	}
	parsed, err := protocol.ParseCredentialRequestResponseBytes(credentialJSON)
	if err != nil {
		writeError(w, http.StatusBadRequest, "passkey_rejected", "the passkey answer could not be read")
		return false
	}
	user, err := c.loadUser(r, who.Operator.ID)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "signed_out", "sign in again")
		return false
	}
	credential, err := c.webAuthn.ValidateLogin(user, payload.Session, parsed)
	if err != nil {
		c.cfg.Logger.Warn("console step-up refused", "operator", who.Operator.Name, "error", err)
		writeError(w, http.StatusUnauthorized, "passkey_rejected", "the passkey tap was not accepted")
		return false
	}
	return c.recordPasskeyUse(w, r, credential)
}

// A streamed upload (an update bundle runs to gigabytes) cannot travel inside
// the step-up's JSON. Its tap rides in headers instead, bound to the body's
// SHA-256, and the body is hashed on its way through: a body that does not
// hash to what was tapped fails mid-stream, so it is never published.
const (
	headerStepUpChallenge  = "X-Pointy-Step-Up-Challenge"
	headerStepUpCredential = "X-Pointy-Step-Up-Credential"
	headerBodySHA256       = "X-Pointy-Body-SHA256"
)

var sha256HexPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

// verifyStreamedStepUp checks a streamed request's tap and, on success,
// wraps its body so the bytes must hash to what the operator authorized.
func (c *Console) verifyStreamedStepUp(w http.ResponseWriter, r *http.Request, who session, route string) bool {
	challengeID := strings.TrimSpace(r.Header.Get(headerStepUpChallenge))
	encoded := strings.TrimSpace(r.Header.Get(headerStepUpCredential))
	sum := strings.ToLower(strings.TrimSpace(r.Header.Get(headerBodySHA256)))
	if challengeID == "" || encoded == "" || !sha256HexPattern.MatchString(sum) {
		writeError(w, http.StatusForbidden, "step_up_required", "this action needs a passkey tap")
		return false
	}
	credential, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(encoded, "="))
	if err != nil {
		writeError(w, http.StatusBadRequest, "passkey_rejected", "the passkey answer could not be read")
		return false
	}
	if !c.verifyStepUp(w, r, who, challengeID, credential, actionHash(r.Method, route, sum)) {
		return false
	}
	r.Body = &hashCheckReader{body: r.Body, hash: sha256.New(), expected: sum}
	return true
}

// hashCheckReader passes a body through and fails at its end when the bytes
// were not the ones a passkey tap authorized.
type hashCheckReader struct {
	body     io.ReadCloser
	hash     hash.Hash
	expected string
}

var errBodyMismatch = errors.New("the uploaded bytes are not the ones the passkey tap authorized")

func (h *hashCheckReader) Read(p []byte) (int, error) {
	n, err := h.body.Read(p)
	h.hash.Write(p[:n])
	if errors.Is(err, io.EOF) && hex.EncodeToString(h.hash.Sum(nil)) != h.expected {
		return n, errBodyMismatch
	}
	return n, err
}

func (h *hashCheckReader) Close() error { return h.body.Close() }

// stepUpRoute checks a path given in a step-up is a plain console API path.
func stepUpRoute(path string) (string, bool) {
	parsed, err := url.Parse(path)
	if err != nil || parsed.Scheme != "" || parsed.Host != "" || !strings.HasPrefix(parsed.Path, "/") ||
		strings.Contains(parsed.Path, "..") {
		return "", false
	}
	return parsed.Path, true
}

func beginBodyHash(request stepUpRequest) string {
	if sum := strings.TrimSpace(request.BodySHA256); sum != "" {
		return sum
	}
	return bodyHash(request.Body)
}
