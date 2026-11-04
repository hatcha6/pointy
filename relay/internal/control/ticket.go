package control

import (
	"context"
	"errors"
	"time"
)

var (
	ErrRelayTicketNotFound       = errors.New("relay ticket not found")
	ErrRelayRefreshTokenNotFound = errors.New("relay refresh token not found")
	// ErrTicketNotAfterPassed is a ticket asked to end before it begins.
	ErrTicketNotAfterPassed = errors.New("relay ticket not_after has passed")
)

type RelayTicketRequest struct {
	DeviceID   string `json:"device_id,omitempty"`
	DeviceName string `json:"device_name,omitempty"`
	// NotAfter bounds the ticket and its refresh token — and, because a
	// refresh carries it on, every ticket the device is given after: a
	// sign-in from outside the shop ends when its session does.
	NotAfter *time.Time `json:"not_after,omitempty"`
	// ChainStartedAt is when the device was paired, carried from refresh to
	// refresh so that revoking the device reaches every ticket since. Set by
	// the relay, never by a caller.
	ChainStartedAt time.Time `json:"-"`
}

type IssuedRelayTicket struct {
	InstallationID string `json:"installation_id"`
	DeviceID       string `json:"device_id,omitempty"`
	DeviceName     string `json:"device_name,omitempty"`
	Token          string `json:"token"`
	// IssuedAt is the relay's own clock at issue. A device compares it with
	// its clock at receipt to learn how far the two disagree, and schedules
	// its refresh off the ticket's real lifetime instead of off an absolute
	// expiry that a clock running ahead reads as already past.
	IssuedAt         time.Time `json:"issued_at"`
	ExpiresAt        time.Time `json:"expires_at"`
	RefreshToken     string    `json:"refresh_token"`
	RefreshExpiresAt time.Time `json:"refresh_expires_at"`
}

type RelayTicket struct {
	InstallationID string    `json:"installation_id"`
	DeviceID       string    `json:"device_id,omitempty"`
	DeviceName     string    `json:"device_name,omitempty"`
	TokenHash      string    `json:"token_hash"`
	IssuedAt       time.Time `json:"issued_at"`
	ExpiresAt      time.Time `json:"expires_at"`
}

type RelayRefreshToken struct {
	InstallationID string     `json:"installation_id"`
	DeviceID       string     `json:"device_id,omitempty"`
	DeviceName     string     `json:"device_name,omitempty"`
	TokenHash      string     `json:"token_hash"`
	IssuedAt       time.Time  `json:"issued_at"`
	ExpiresAt      time.Time  `json:"expires_at"`
	NotAfter       *time.Time `json:"not_after,omitempty"`
	ChainStartedAt time.Time  `json:"chain_started_at,omitzero"`
}

// ChainStart is when the device this token belongs to was paired. A token
// written before chains were kept answers its own issue time.
func (r RelayRefreshToken) ChainStart() time.Time {
	if r.ChainStartedAt.IsZero() {
		return r.IssuedAt
	}
	return r.ChainStartedAt
}

// NextRequest is what a refresh of this token asks for: the same device,
// bounded and chained as the pairing was.
func (r RelayRefreshToken) NextRequest() RelayTicketRequest {
	return RelayTicketRequest{
		DeviceID:       r.DeviceID,
		DeviceName:     r.DeviceName,
		NotAfter:       r.NotAfter,
		ChainStartedAt: r.ChainStart(),
	}
}

// TicketLifetimes are when a ticket issued at now for request, and its
// refresh token, expire: their TTLs, cut short by the request's NotAfter.
func TicketLifetimes(
	now time.Time,
	request RelayTicketRequest,
	ticketTTL time.Duration,
	refreshTTL time.Duration,
) (time.Time, time.Time, error) {
	ticketExpiresAt := now.Add(ticketTTL)
	refreshExpiresAt := now.Add(refreshTTL)
	if request.NotAfter != nil {
		notAfter := *request.NotAfter
		if !notAfter.After(now) {
			return time.Time{}, time.Time{}, ErrTicketNotAfterPassed
		}
		if notAfter.Before(ticketExpiresAt) {
			ticketExpiresAt = notAfter
		}
		if notAfter.Before(refreshExpiresAt) {
			refreshExpiresAt = notAfter
		}
	}
	return ticketExpiresAt, refreshExpiresAt, nil
}

type RelayTicketService interface {
	IssueTicket(
		ctx context.Context,
		installation Installation,
		request RelayTicketRequest,
		ticketTTL time.Duration,
		refreshTTL time.Duration,
	) (IssuedRelayTicket, error)
	ValidateTicket(ctx context.Context, rawToken string, now time.Time) (RelayTicket, error)
	// PeekRefreshToken reads a refresh token without spending it, for the
	// checks that have to come before the spend: a lapsed subscription is
	// answered with the token left in place, so the device can come back on
	// its own once the subscription is restored.
	PeekRefreshToken(ctx context.Context, rawToken string, now time.Time) (RelayRefreshToken, error)
	ConsumeRefreshToken(ctx context.Context, rawToken string, now time.Time) (RelayRefreshToken, error)
	// RevokeDevice drops every live ticket and refresh token of one device,
	// and refuses any refresh token of a chain paired before now, for
	// keepFor (the longest any of them could still live).
	RevokeDevice(ctx context.Context, installationID, deviceID string, now time.Time, keepFor time.Duration) error
}
