package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type connectorState struct {
	InstallationID                string     `json:"installation_id"`
	ShopName                      string     `json:"shop_name,omitempty"`
	BackendURL                    string     `json:"backend_url,omitempty"`
	RelayConnectorAddress         string     `json:"relay_connector_address,omitempty"`
	ConnectorToken                string     `json:"connector_token"`
	TLSServerName                 string     `json:"tls_server_name,omitempty"`
	ConnectorCertificatePEM       string     `json:"connector_certificate_pem,omitempty"`
	ConnectorPrivateKeyPEM        string     `json:"connector_private_key_pem,omitempty"`
	ConnectorCACertificatePEM     string     `json:"connector_ca_certificate_pem,omitempty"`
	ConnectorCertificateExpiresAt *time.Time `json:"connector_certificate_expires_at,omitempty"`
	UpdatedAt                     time.Time  `json:"updated_at"`
}

func defaultConnectorStatePath() string {
	if stateHome := strings.TrimSpace(os.Getenv("XDG_STATE_HOME")); stateHome != "" {
		return filepath.Join(stateHome, "pointy", "relay-connector.json")
	}
	home, err := os.UserHomeDir()
	if err != nil || strings.TrimSpace(home) == "" {
		return ""
	}
	return filepath.Join(home, ".pointy", "relay-connector.json")
}

func loadConnectorState(path string) (connectorState, error) {
	if strings.TrimSpace(path) == "" {
		return connectorState{}, nil
	}
	content, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return connectorState{}, nil
	}
	if err != nil {
		return connectorState{}, err
	}
	if len(content) == 0 {
		return connectorState{}, nil
	}
	var state connectorState
	if err := json.Unmarshal(content, &state); err != nil {
		return connectorState{}, err
	}
	return state, nil
}

func saveConnectorState(path string, state connectorState) error {
	if strings.TrimSpace(path) == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	state.UpdatedAt = time.Now().UTC()
	content, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	tmpPath := path + ".tmp"
	if err := os.WriteFile(tmpPath, append(content, '\n'), 0o600); err != nil {
		return err
	}
	if err := os.Chmod(tmpPath, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return err
	}
	return nil
}

func connectorStateHasManagedTLS(state connectorState) bool {
	return strings.TrimSpace(state.ConnectorCertificatePEM) != "" &&
		strings.TrimSpace(state.ConnectorPrivateKeyPEM) != "" &&
		strings.TrimSpace(state.ConnectorCACertificatePEM) != ""
}

func connectorStateError(path string, err error) error {
	if strings.TrimSpace(path) == "" {
		return err
	}
	return fmt.Errorf("connector state %s: %w", path, err)
}
