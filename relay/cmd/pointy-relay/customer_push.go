package main

import (
	"fmt"
	"log/slog"
	"os"
	"strings"

	"pointy/relay/internal/fcm"
	relayserver "pointy/relay/internal/relay"
)

// buildCustomerPush reads POINTY_RELAY_FCM_SERVICE_ACCOUNT: the key's JSON
// itself (a secret store's value) or a path to the file. Empty sends no
// notifications; a key that is there but unreadable stops the relay, so a
// broken secret is seen at deploy rather than at the first send.
func buildCustomerPush(raw string, logger *slog.Logger) (relayserver.CustomerPusher, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	credentials := []byte(raw)
	if !strings.HasPrefix(raw, "{") {
		file, err := os.ReadFile(raw)
		if err != nil {
			return nil, fmt.Errorf("POINTY_RELAY_FCM_SERVICE_ACCOUNT: %w", err)
		}
		credentials = file
	}
	client, err := fcm.New(credentials, nil)
	if err != nil {
		return nil, fmt.Errorf("POINTY_RELAY_FCM_SERVICE_ACCOUNT: %w", err)
	}
	logger.Info("card app notifications configured", "firebase_project", client.ProjectID())
	return client, nil
}
