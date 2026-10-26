package main

import (
	"fmt"
	"log/slog"
	"net/http"
	"slices"
	"strings"

	"pointy/relay/internal/cardsweb"
)

// defaultCardsWebDir is where the relay image keeps the card app's web build
// (copied from the pointy-cards-web image).
const defaultCardsWebDir = "/srv/cards-web"

// buildCardsWeb serves the card app's web build on hosts, in front of next.
// No hosts leaves next as it is.
func buildCardsWeb(next http.Handler, hosts []string, dir string, logger *slog.Logger) (http.Handler, error) {
	if len(hosts) == 0 {
		return next, nil
	}
	handler, err := cardsweb.Wrap(next, cardsweb.Config{Hosts: hosts, Files: cardsweb.Dir(dir)})
	if err != nil {
		return nil, fmt.Errorf("POINTY_RELAY_CARDS_WEB_HOSTS is set but the web app cannot be served from %s: %w", dir, err)
	}
	logger.Info("card app web build served", "hosts", strings.Join(hosts, ","), "dir", dir)
	return handler, nil
}

// withCardsWebOrigins adds each web app host's https origin to the customer
// routes' allowed origins: the page the relay serves may call the relay.
func withCardsWebOrigins(origins string, hosts []string) string {
	list := strings.Split(origins, ",")
	for _, host := range hosts {
		origin := "https://" + strings.ToLower(host)
		if !slices.ContainsFunc(list, func(o string) bool {
			return strings.EqualFold(strings.TrimRight(strings.TrimSpace(o), "/"), origin)
		}) {
			list = append(list, origin)
		}
	}
	return strings.Trim(strings.Join(list, ","), ",")
}
