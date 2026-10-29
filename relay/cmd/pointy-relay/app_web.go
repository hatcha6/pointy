package main

import (
	"fmt"
	"log/slog"
	"net/http"
	"strings"

	"pointy/relay/internal/appweb"
	"pointy/relay/internal/webbuild"
)

// defaultAppWebDir is where the relay image keeps the shop app's web build
// (copied from the pointy-app-web image).
const defaultAppWebDir = "/srv/app-web"

// buildAppWeb serves the shop app's web build on hosts, in front of next. No
// hosts leaves next as it is.
func buildAppWeb(next http.Handler, hosts []string, dir string, logger *slog.Logger) (http.Handler, error) {
	if len(hosts) == 0 {
		return next, nil
	}
	handler, err := appweb.Wrap(next, appweb.Config{Hosts: hosts, Files: webbuild.Dir(dir)})
	if err != nil {
		return nil, fmt.Errorf("POINTY_RELAY_APP_WEB_HOSTS is set but the web app cannot be served from %s: %w", dir, err)
	}
	logger.Info("shop app web build served", "hosts", strings.Join(hosts, ","), "dir", dir)
	return handler, nil
}
