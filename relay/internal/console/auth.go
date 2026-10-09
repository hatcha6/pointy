package console

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"

	"pointy/relay/internal/control"
	"pointy/relay/internal/ratelimit"
)

const (
	tokenInvite   = "invite"
	tokenLogin    = "login"
	tokenRegister = "register"
	tokenStepUp   = "stepup"

	// ceremonyTTL is how long a passkey prompt may stay open.
	ceremonyTTL = 3 * time.Minute
	// DefaultInviteTTL is how long an invite link works.
	DefaultInviteTTL = 24 * time.Hour
	maxInviteTTL     = 7 * 24 * time.Hour
)

var (
	signInPolicy = ratelimit.Policy{Limit: 30, Window: 5 * time.Minute}
	invitePolicy = ratelimit.Policy{Limit: 20, Window: 15 * time.Minute}
)

// operatorUser adapts an operator and their passkeys to the WebAuthn library.
type operatorUser struct {
	operator    control.ConsoleOperator
	credentials []webauthn.Credential
}

func (u operatorUser) WebAuthnID() []byte                         { return []byte(u.operator.ID) }
func (u operatorUser) WebAuthnName() string                       { return u.operator.Name }
func (u operatorUser) WebAuthnDisplayName() string                { return u.operator.Name }
func (u operatorUser) WebAuthnCredentials() []webauthn.Credential { return u.credentials }

func (c *Console) loadUser(r *http.Request, operatorID string) (operatorUser, error) {
	ctx := r.Context()
	operator, err := c.cfg.Store.ConsoleOperator(ctx, operatorID)
	if err != nil {
		return operatorUser{}, err
	}
	if !operator.Active() {
		return operatorUser{}, control.ErrConsoleOperatorNotFound
	}
	passkeys, err := c.cfg.Store.ConsolePasskeys(ctx, operator.ID)
	if err != nil {
		return operatorUser{}, err
	}
	user := operatorUser{operator: operator}
	for _, passkey := range passkeys {
		var credential webauthn.Credential
		if err := json.Unmarshal(passkey.Credential, &credential); err != nil {
			return operatorUser{}, err
		}
		user.credentials = append(user.credentials, credential)
	}
	return user, nil
}

func (c *Console) serveAuth(w http.ResponseWriter, r *http.Request, route string) {
	switch {
	case route == "/me" && r.Method == http.MethodGet:
		c.handleMe(w, r)
	case route == "/login/begin" && r.Method == http.MethodPost:
		c.handleLoginBegin(w, r)
	case route == "/login/finish" && r.Method == http.MethodPost:
		c.handleLoginFinish(w, r)
	case route == "/logout" && r.Method == http.MethodPost:
		c.handleLogout(w, r)
	case route == "/invite/begin" && r.Method == http.MethodPost:
		c.handleInviteBegin(w, r)
	case route == "/invite/finish" && r.Method == http.MethodPost:
		c.handleInviteFinish(w, r)
	default:
		writeError(w, http.StatusNotFound, "not_found", "not found")
	}
}

func (c *Console) handleMe(w http.ResponseWriter, r *http.Request) {
	who, err := c.currentSession(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "signed_out", "sign in")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"operator": map[string]any{"id": who.Operator.ID, "name": who.Operator.Name},
		"session": map[string]any{
			"id":         sessionRef(who.IDHash),
			"created_at": who.CreatedAt,
			"expires_at": who.ExpiresAt,
			"max_age_at": who.CreatedAt.Add(c.cfg.MaxAge),
		},
		"idle_timeout_seconds": int(c.cfg.IdleTimeout.Seconds()),
	})
}

// handleLoginBegin starts a usernameless sign-in: the browser offers every
// passkey it holds for this site, and the passkey says who the operator is.
func (c *Console) handleLoginBegin(w http.ResponseWriter, r *http.Request) {
	if !c.allow(r, "login", signInPolicy) {
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many attempts; wait a few minutes")
		return
	}
	assertion, data, err := c.webAuthn.BeginDiscoverableLogin(
		webauthn.WithUserVerification(protocol.VerificationRequired))
	if err != nil {
		c.internalError(w, "console login begin failed", err)
		return
	}
	challengeID, err := c.putCeremony(r, tokenLogin, "", "", data)
	if err != nil {
		c.internalError(w, "console login begin failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"challenge_id": challengeID, "options": assertion})
}

type ceremonyFinish struct {
	ChallengeID string          `json:"challenge_id"`
	Credential  json.RawMessage `json:"credential"`
	Label       string          `json:"label"`
	Token       string          `json:"token"`
}

func (c *Console) handleLoginFinish(w http.ResponseWriter, r *http.Request) {
	if !c.allow(r, "login", signInPolicy) {
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many attempts; wait a few minutes")
		return
	}
	var request ceremonyFinish
	if !decodeBody(w, r, &request) {
		return
	}
	_, data, ok := c.takeCeremony(w, r, tokenLogin, request.ChallengeID)
	if !ok {
		return
	}
	parsed, err := protocol.ParseCredentialRequestResponseBytes(request.Credential)
	if err != nil {
		writeError(w, http.StatusBadRequest, "passkey_rejected", "the passkey answer could not be read")
		return
	}
	var user operatorUser
	handler := func(_, userHandle []byte) (webauthn.User, error) {
		loaded, err := c.loadUser(r, string(userHandle))
		user = loaded
		return loaded, err
	}
	_, credential, err := c.webAuthn.ValidatePasskeyLogin(handler, data, parsed)
	if err != nil {
		c.cfg.Logger.Warn("console sign-in refused", "ip", c.clientIP(r), "error", err)
		writeError(w, http.StatusUnauthorized, "passkey_rejected", "this passkey is not allowed in")
		return
	}
	if !c.recordPasskeyUse(w, r, credential) {
		return
	}
	if err := c.startSession(r.Context(), w, r, user.operator); err != nil {
		c.internalError(w, "console session start failed", err)
		return
	}
	c.audit(r, user.operator, "auth.login", http.StatusOK, "", false)
	writeJSON(w, http.StatusOK, map[string]any{"operator": map[string]any{"id": user.operator.ID, "name": user.operator.Name}})
}

// recordPasskeyUse stores the new signature counter, refusing a passkey whose
// counter went backwards: a sign the key may have been cloned.
func (c *Console) recordPasskeyUse(w http.ResponseWriter, r *http.Request, credential *webauthn.Credential) bool {
	if credential.Authenticator.CloneWarning {
		c.cfg.Logger.Error("console passkey counter went backwards; refusing it",
			"passkey", encodeID(credential.ID), "ip", c.clientIP(r))
		writeError(w, http.StatusUnauthorized, "passkey_cloned", "this passkey looks copied; it was refused")
		return false
	}
	encoded, err := json.Marshal(credential)
	if err != nil {
		c.internalError(w, "console passkey encode failed", err)
		return false
	}
	if err := c.cfg.Store.TouchConsolePasskey(r.Context(), encodeID(credential.ID), encoded); err != nil {
		c.internalError(w, "console passkey update failed", err)
		return false
	}
	return true
}

func (c *Console) handleLogout(w http.ResponseWriter, r *http.Request) {
	if who, err := c.currentSession(r); err == nil {
		_ = c.cfg.Store.DeleteConsoleSession(r.Context(), who.IDHash)
		c.audit(r, who.Operator, "auth.logout", http.StatusOK, "", false)
	}
	c.clearCookie(w)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// --- invites ---------------------------------------------------------------

type inviteRequest struct {
	Name     string `json:"name"`
	TTLHours int    `json:"ttl_hours"`
}

// handleInvite makes a one-time link that registers a passkey: for a new
// operator, or another device of an existing one. The token rides in the
// link's #fragment so it never reaches a server log.
func (c *Console) handleInvite(w http.ResponseWriter, r *http.Request, createdBy string) {
	var request inviteRequest
	if !decodeBody(w, r, &request) {
		return
	}
	ctx := r.Context()
	operator, err := c.cfg.Store.ConsoleOperatorByName(ctx, request.Name)
	created := false
	if errors.Is(err, control.ErrConsoleOperatorNotFound) {
		operator, err = c.cfg.Store.CreateConsoleOperator(ctx, request.Name, createdBy)
		created = true
	}
	switch {
	case errors.Is(err, control.ErrConsoleOperatorName):
		writeError(w, http.StatusBadRequest, "invalid_name", err.Error())
		return
	case err != nil:
		c.internalError(w, "console invite failed", err)
		return
	}
	if !operator.Active() {
		writeError(w, http.StatusConflict, "operator_disabled", "this operator is disabled; enable them first")
		return
	}
	ttl := DefaultInviteTTL
	if request.TTLHours > 0 {
		ttl = min(time.Duration(request.TTLHours)*time.Hour, maxInviteTTL)
	}
	value, err := randomToken()
	if err != nil {
		c.internalError(w, "console invite failed", err)
		return
	}
	expiresAt := c.cfg.Now().Add(ttl)
	if err := c.cfg.Store.PutConsoleToken(ctx, control.ConsoleToken{
		Hash: hashToken(value), Kind: tokenInvite, OperatorID: operator.ID, Subject: createdBy, ExpiresAt: expiresAt,
	}); err != nil {
		c.internalError(w, "console invite failed", err)
		return
	}
	c.cfg.Logger.Warn("console invite issued", "operator", operator.Name, "new", created, "by", createdBy)
	writeJSON(w, http.StatusCreated, map[string]any{
		"operator":   operator,
		"created":    created,
		"link":       c.origin.String() + Prefix + "/invite#" + value,
		"expires_at": expiresAt,
	})
}

// handleInviteBegin opens the passkey prompt for an invite. The invite is
// only spent when the passkey is saved, so a cancelled prompt can be retried.
func (c *Console) handleInviteBegin(w http.ResponseWriter, r *http.Request) {
	if !c.allow(r, "invite", invitePolicy) {
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many attempts; wait a few minutes")
		return
	}
	var request ceremonyFinish
	if !decodeBody(w, r, &request) {
		return
	}
	ctx := r.Context()
	inviteHash := hashToken(strings.TrimSpace(request.Token))
	invite, err := c.cfg.Store.TakeConsoleToken(ctx, tokenInvite, inviteHash)
	if err != nil {
		writeError(w, http.StatusGone, "invite_invalid", "this invite link was used or has expired")
		return
	}
	// Put it back: taking it was only the atomic way to read it.
	if err := c.cfg.Store.PutConsoleToken(ctx, invite); err != nil {
		c.internalError(w, "console invite begin failed", err)
		return
	}
	user, err := c.loadUser(r, invite.OperatorID)
	if err != nil {
		writeError(w, http.StatusGone, "invite_invalid", "this invite is for a disabled operator")
		return
	}
	exclusions := make([]protocol.CredentialDescriptor, 0, len(user.credentials))
	for _, credential := range user.credentials {
		exclusions = append(exclusions, credential.Descriptor())
	}
	creation, data, err := c.webAuthn.BeginRegistration(user,
		webauthn.WithAuthenticatorSelection(protocol.AuthenticatorSelection{
			ResidentKey:        protocol.ResidentKeyRequirementRequired,
			RequireResidentKey: protocol.ResidentKeyRequired(),
			UserVerification:   protocol.VerificationRequired,
		}),
		webauthn.WithExclusions(exclusions),
	)
	if err != nil {
		c.internalError(w, "console invite begin failed", err)
		return
	}
	challengeID, err := c.putCeremony(r, tokenRegister, user.operator.ID, inviteHash, data)
	if err != nil {
		c.internalError(w, "console invite begin failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"challenge_id":   challengeID,
		"options":        creation,
		"operator_name":  user.operator.Name,
		"existing_count": len(user.credentials),
		"expires_at":     invite.ExpiresAt,
	})
}

func (c *Console) handleInviteFinish(w http.ResponseWriter, r *http.Request) {
	if !c.allow(r, "invite", invitePolicy) {
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many attempts; wait a few minutes")
		return
	}
	var request ceremonyFinish
	if !decodeBody(w, r, &request) {
		return
	}
	token, data, ok := c.takeCeremony(w, r, tokenRegister, request.ChallengeID)
	if !ok {
		return
	}
	ctx := r.Context()
	parsed, err := protocol.ParseCredentialCreationResponseBytes(request.Credential)
	if err != nil {
		writeError(w, http.StatusBadRequest, "passkey_rejected", "the passkey answer could not be read")
		return
	}
	user, err := c.loadUser(r, token.OperatorID)
	if err != nil {
		writeError(w, http.StatusGone, "invite_invalid", "this invite is for a disabled operator")
		return
	}
	credential, err := c.webAuthn.CreateCredential(user, data, parsed)
	if err != nil {
		c.cfg.Logger.Warn("console passkey registration refused", "operator", user.operator.Name, "error", err)
		writeError(w, http.StatusBadRequest, "passkey_rejected", "the passkey could not be registered")
		return
	}
	// Spend the invite now; a second browser racing the same link loses here.
	if _, err := c.cfg.Store.TakeConsoleToken(ctx, tokenInvite, token.Subject); err != nil {
		writeError(w, http.StatusGone, "invite_invalid", "this invite link was used or has expired")
		return
	}
	encoded, err := json.Marshal(credential)
	if err != nil {
		c.internalError(w, "console passkey encode failed", err)
		return
	}
	label := strings.TrimSpace(request.Label)
	if label == "" {
		label = "جهاز"
	}
	if err := c.cfg.Store.AddConsolePasskey(ctx, control.ConsolePasskey{
		ID: encodeID(credential.ID), OperatorID: user.operator.ID, Label: label, Credential: encoded,
	}); err != nil {
		c.internalError(w, "console passkey save failed", err)
		return
	}
	if err := c.startSession(ctx, w, r, user.operator); err != nil {
		c.internalError(w, "console session start failed", err)
		return
	}
	c.audit(r, user.operator, "auth.passkey_added", http.StatusOK, `{"label":`+jsonString(label)+`}`, false)
	writeJSON(w, http.StatusOK, map[string]any{"operator": map[string]any{"id": user.operator.ID, "name": user.operator.Name}})
}

// --- ceremonies ------------------------------------------------------------

func (c *Console) putCeremony(r *http.Request, kind, operatorID, subject string, data *webauthn.SessionData) (string, error) {
	return c.putCeremonyPayload(r, kind, operatorID, subject, ceremonyPayload{Session: *data})
}

type ceremonyPayload struct {
	Session webauthn.SessionData `json:"session"`
	// Action is the SHA-256 of the request a step-up authorizes.
	Action string `json:"action,omitempty"`
}

func (c *Console) putCeremonyPayload(r *http.Request, kind, operatorID, subject string, payload ceremonyPayload) (string, error) {
	id, err := randomToken()
	if err != nil {
		return "", err
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	return id, c.cfg.Store.PutConsoleToken(r.Context(), control.ConsoleToken{
		Hash: hashToken(id), Kind: kind, OperatorID: operatorID, Subject: subject,
		Payload: string(encoded), ExpiresAt: c.cfg.Now().Add(ceremonyTTL),
	})
}

func (c *Console) takeCeremony(w http.ResponseWriter, r *http.Request, kind, id string) (control.ConsoleToken, webauthn.SessionData, bool) {
	payload, token, ok := c.takeCeremonyPayload(w, r, kind, id)
	return token, payload.Session, ok
}

func (c *Console) takeCeremonyPayload(w http.ResponseWriter, r *http.Request, kind, id string) (ceremonyPayload, control.ConsoleToken, bool) {
	token, err := c.cfg.Store.TakeConsoleToken(r.Context(), kind, hashToken(strings.TrimSpace(id)))
	if err != nil {
		writeError(w, http.StatusGone, "challenge_expired", "the passkey prompt expired; try again")
		return ceremonyPayload{}, control.ConsoleToken{}, false
	}
	var payload ceremonyPayload
	if err := json.Unmarshal([]byte(token.Payload), &payload); err != nil {
		c.internalError(w, "console ceremony decode failed", err)
		return ceremonyPayload{}, control.ConsoleToken{}, false
	}
	return payload, token, true
}

// --- helpers ---------------------------------------------------------------

func (c *Console) internalError(w http.ResponseWriter, message string, err error) {
	c.cfg.Logger.Error(message, "error", err)
	writeError(w, http.StatusInternalServerError, "internal", "something went wrong; try again")
}

func decodeBody(w http.ResponseWriter, r *http.Request, into any) bool {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxAuthBody))
	if err == nil && len(body) > 0 {
		err = json.Unmarshal(body, into)
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "invalid request body")
		return false
	}
	return true
}

func randomToken() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b[:]), nil
}

func encodeID(id []byte) string { return base64.RawURLEncoding.EncodeToString(id) }

// sessionRef is the short, non-secret name of a session shown in the UI.
func sessionRef(idHash string) string {
	if len(idHash) > 16 {
		return idHash[:16]
	}
	return idHash
}

func jsonString(value string) string {
	encoded, _ := json.Marshal(value)
	return string(encoded)
}
