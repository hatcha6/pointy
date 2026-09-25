package control

import (
	"context"
	"errors"
	"time"
)

var (
	ErrRelayTicketNotFound       = errors.New("relay ticket not found")
	ErrRelayRefreshTokenNotFound = errors.New("relay refresh token not found")
)

type RelayTicketRequest struct {
	DeviceID   string `json:"device_id,omitempty"`
	DeviceName string `json:"device_name,omitempty"`
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
	InstallationID string    `json:"installation_id"`
	DeviceID       string    `json:"device_id,omitempty"`
	DeviceName     string    `json:"device_name,omitempty"`
	TokenHash      string    `json:"token_hash"`
	IssuedAt       time.Time `json:"issued_at"`
	ExpiresAt      time.Time `json:"expires_at"`
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
}
