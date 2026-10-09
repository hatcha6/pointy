package main

import (
	"errors"
	"log/slog"
	"net/http"

	"pointy/relay/internal/console"
	"pointy/relay/internal/control"
	"pointy/relay/internal/ratelimit"
)

type consoleSettings struct {
	Origin            string
	AdminToken        string
	Store             control.InstallationStore
	RateLimiter       ratelimit.Limiter
	TrustForwardedFor bool
	// RequireAdminClientCertificate is the private-network mode where every
	// admin call needs an mTLS client certificate; the console's forwarded
	// calls carry none, so the two cannot be combined.
	RequireAdminClientCertificate bool
	Logger                        *slog.Logger
}

// buildConsole wraps the handler that serves admin routes (the admin
// listener's when there is one, else the public one) with the operator
// console.
func buildConsole(settings consoleSettings, adminHandler http.Handler, publicHandler http.Handler) (http.Handler, error) {
	if settings.RequireAdminClientCertificate {
		return nil, errors.New("console: cannot run with admin client certificates required; unset POINTY_RELAY_CONSOLE_ORIGIN or the client certificate requirement")
	}
	store, ok := settings.Store.(control.ConsoleStore)
	if !ok {
		return nil, errors.New("console: this relay's store does not support the operator console")
	}
	inner := publicHandler
	if adminHandler != nil {
		inner = adminHandler
	}
	wrapped, err := console.New(console.Config{
		Origin:            settings.Origin,
		AdminToken:        settings.AdminToken,
		Store:             store,
		Admin:             inner,
		RateLimiter:       settings.RateLimiter,
		TrustForwardedFor: settings.TrustForwardedFor,
		Logger:            settings.Logger,
	})
	if err != nil {
		return nil, err
	}
	settings.Logger.Info("operator console enabled", "origin", settings.Origin)
	return wrapped, nil
}
