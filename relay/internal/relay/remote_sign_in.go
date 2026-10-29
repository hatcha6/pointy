package relay

import (
	"context"
	"net/http"
	"strings"

	"pointy/relay/internal/control"
)

// The sign-in route: how a device that holds no ticket yet — the web app on
// an iPhone, a phone that never joined the shop's Wi-Fi — reaches a shop with
// nothing but its installation ID. It names the shop in
// X-Pointy-Relay-Installation instead of carrying a ticket, and reaches only
// the few paths a sign-in needs. Once a manager has signed in, pairing hands
// the device a ticket and it carries on like any paired till.
//
// The installation ID is an address, not a secret: it is inside every relay
// token and on the shop's subscription page. The shop's own password is the
// credential, so the shop decides (its allow_remote_sign_in switch, off by
// default) and the backend judges every request, which arrives marked
// X-Pointy-Relay-Sign-In: 1. The relay's part is to open no more than these
// paths, only for a paid installation, and to bound how often anyone may try.
const (
	SignInInstallationHeader = "X-Pointy-Relay-Installation"
	SignInRouteHeader        = "X-Pointy-Relay-Sign-In"
)

// remoteSignInPaths are the only backend paths the sign-in route reaches.
var remoteSignInPaths = map[string]bool{
	// Whether the shop takes sign-ins from the internet, and its name.
	"/api/relay/remote-sign-in/": true,
	// What the app asks before anyone signs in: who is signed in (nobody),
	// and whether the shop still needs its first owner (read only — creating
	// one is not on this list).
	"/api/auth/me/":      true,
	"/api/setup/status/": true,
	"/api/auth/login/":   true,
	"/api/auth/logout/":  true,
	// A signed-in manager's first ticket.
	"/api/relay/pairing/": true,
}

// signInTarget reads a sign-in route request: the installation it names and
// the backend path it asks for. A request carrying a ticket is not one.
func signInTarget(r *http.Request) (string, string, bool) {
	if strings.TrimSpace(r.Header.Get(AccessTokenHeader)) != "" {
		return "", "", false
	}
	installationID := strings.TrimSpace(r.Header.Get(SignInInstallationHeader))
	if installationID == "" || !strings.HasPrefix(r.URL.Path, "/api/") {
		return "", "", false
	}
	return installationID, r.URL.Path, true
}

// handleRemoteSignIn relays one sign-in route request, when its path is one
// a sign-in needs and the caller has not tried too often.
func (s HTTPServer) handleRemoteSignIn(
	w http.ResponseWriter,
	r *http.Request,
	installationID string,
	targetPath string,
	allowNodeProxy bool,
) {
	if !remoteSignInPaths[targetPath] {
		writeNotFound(w)
		return
	}
	if limited, _, _ := s.enforceRateLimit(
		w, r, "remote_sign_in",
		"remote-sign-in:"+installationID,
		s.RemoteSignInRateLimit,
	); limited {
		return
	}
	if limited, _, _ := s.enforceRateLimit(
		w, r, "remote_sign_in_client",
		"remote-sign-in-client:"+installationID+":"+s.customerClientIP(r),
		s.RemoteSignInClientRateLimit,
	); limited {
		return
	}
	s.handleRelayWithOptions(w, r, "", targetPath, relayOptions{
		AllowNodeProxy:       allowNodeProxy,
		SignInInstallationID: installationID,
	})
}

// validateSignInInstallation is the sign-in route's stand-in for a ticket:
// the installation must exist and have relay access paid for. Both failures
// answer alike, so the route tells nobody which IDs exist.
func (s HTTPServer) validateSignInInstallation(
	ctx context.Context,
	installationID string,
) (control.Installation, error) {
	installation, err := s.Store.GetInstallation(ctx, installationID)
	if err != nil {
		return control.Installation{}, control.ErrInvalidToken
	}
	if !installation.RelayActive(s.clock().Now()) {
		return control.Installation{}, control.ErrInvalidToken
	}
	return installation, nil
}
