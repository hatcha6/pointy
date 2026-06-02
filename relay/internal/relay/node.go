package relay

import (
	"os"
	"strings"

	"pointy/relay/internal/control"
)

func NewNodeID() (string, error) {
	id, err := control.NewInstallationID()
	if err != nil {
		return "", err
	}
	hostname, _ := os.Hostname()
	hostname = strings.TrimSpace(hostname)
	if hostname == "" {
		return "relay-" + id, nil
	}
	return hostname + "-" + id, nil
}

func newConnectionID() (string, error) {
	return control.NewInstallationID()
}
