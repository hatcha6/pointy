package main

import (
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"pointy/relay/internal/agentmcp"
	"pointy/relay/internal/alerts"
	"pointy/relay/internal/console"
	"pointy/relay/internal/control"
	"pointy/relay/internal/ratelimit"
)

type mcpSettings struct {
	Origin            string
	AdminToken        string
	Store             control.InstallationStore
	RateLimiter       ratelimit.Limiter
	TrustForwardedFor bool
	RedirectURIs      string
	Alerts            *alerts.Ntfy
	Logger            *slog.Logger
}

// buildMCP wraps the console with the Claude connector. Tools read the admin
// handler (inner); everything else goes on to the console. A store without
// MCP grants (the file store) leaves the connector off with a warning rather
// than failing the start.
func buildMCP(settings mcpSettings, inner http.Handler, consoleHandler http.Handler) (http.Handler, error) {
	operators, ok := consoleHandler.(*console.Console)
	if !ok {
		return nil, errors.New("mcp: the operator console is required")
	}
	store, ok := settings.Store.(control.MCPGrantStore)
	if !ok {
		settings.Logger.Warn("Claude connector off: this relay's store does not support MCP grants (Postgres is required)")
		return consoleHandler, nil
	}
	var extra []string
	for _, uri := range strings.Split(settings.RedirectURIs, ",") {
		if uri = strings.TrimSpace(uri); uri != "" {
			extra = append(extra, uri)
		}
	}
	var notify func(title, body string)
	if settings.Alerts != nil {
		notify = func(title, body string) {
			settings.Alerts.Send(alerts.Message{Title: title, Body: body, Priority: alerts.PriorityHigh, Tags: []string{"robot"}})
		}
	}
	server, err := agentmcp.New(agentmcp.Config{
		Origin:            settings.Origin,
		AdminToken:        settings.AdminToken,
		Admin:             inner,
		Next:              consoleHandler,
		Store:             store,
		Operators:         operators,
		RateLimiter:       settings.RateLimiter,
		ExtraRedirectURIs: extra,
		Notify:            notify,
		TrustForwardedFor: settings.TrustForwardedFor,
		Version:           version,
		Logger:            settings.Logger,
	})
	if err != nil {
		return nil, err
	}
	settings.Logger.Info("Claude connector enabled", "url", server.Resource())
	return server, nil
}
