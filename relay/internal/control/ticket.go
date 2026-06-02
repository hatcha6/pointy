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
	InstallationID   string    `json:"installation_id"`
	DeviceID         string    `json:"device_id,omitempty"`
	DeviceName       string    `json:"device_name,omitempty"`
	Token            string    `json:"token"`
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
	ConsumeRefreshToken(ctx context.Context, rawToken string, now time.Time) (RelayRefreshToken, error)
}
