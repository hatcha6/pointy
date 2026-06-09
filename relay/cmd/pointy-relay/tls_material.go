package main

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"strings"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/security"
)

const (
	relayHTTPCAMaterialName        = "relay-http-ca"
	relayHTTPServerMaterialName    = "relay-http-server"
	relayConnectorCAMaterialName   = "relay-connector-mtls-ca"
	relayConnectorCertMaterialName = "relay-connector-server"

	defaultGeneratedTLSCATTL           = 10 * 365 * 24 * time.Hour
	defaultGeneratedTLSServerCertTTL   = 397 * 24 * time.Hour
	defaultGeneratedTLSRotationWindow  = 30 * 24 * time.Hour
	defaultConnectorCertRotationWindow = 14 * 24 * time.Hour
)

type relayAutoTLSOptions struct {
	Enabled           bool
	HTTPAddr          string
	HTTPSName         string
	HTTPCertFile      string
	HTTPKeyFile       string
	InsecureHTTP      bool
	ConnectorAddr     string
	ConnectorName     string
	ConnectorCert     string
	ConnectorKey      string
	ConnectorCA       string
	ConnectorCAKey    string
	InsecureConnector bool
	CATTL             time.Duration
	ServerCertTTL     time.Duration
	RotationWindow    time.Duration
}

type relayAutoTLSMaterial struct {
	HTTPServerCertPEM      string
	HTTPServerKeyPEM       string
	ConnectorServerCertPEM string
	ConnectorServerKeyPEM  string
	ConnectorCAPEM         string
	ConnectorCAKeyPEM      string
}

func prepareRelayAutoTLSMaterial(
	ctx context.Context,
	store *control.PostgresStore,
	options relayAutoTLSOptions,
	logger *slog.Logger,
) (relayAutoTLSMaterial, error) {
	var material relayAutoTLSMaterial
	if !options.Enabled {
		return material, nil
	}
	if store == nil {
		return material, fmt.Errorf("PostgreSQL store is required for automatic relay TLS material")
	}
	if options.CATTL <= 0 {
		options.CATTL = defaultGeneratedTLSCATTL
	}
	if options.ServerCertTTL <= 0 {
		options.ServerCertTTL = defaultGeneratedTLSServerCertTTL
	}
	if options.RotationWindow < 0 {
		options.RotationWindow = 0
	}
	if options.RotationWindow == 0 {
		options.RotationWindow = defaultGeneratedTLSRotationWindow
	}

	if !options.InsecureHTTP && certificatePairMissing(options.HTTPCertFile, options.HTTPKeyFile) {
		httpCA, err := store.GetOrCreateCertificateMaterial(
			ctx,
			relayHTTPCAMaterialName,
			0,
			func(now time.Time) (control.CertificateMaterial, error) {
				generated, err := security.GenerateCertificateAuthority(
					"Pointy Relay HTTP TLS CA",
					options.CATTL,
					now,
				)
				if err != nil {
					return control.CertificateMaterial{}, err
				}
				return certificateMaterialFromGenerated(generated), nil
			},
		)
		if err != nil {
			return material, fmt.Errorf("HTTP TLS CA setup failed: %w", err)
		}
		issuer, err := security.LoadCertificateAuthorityPEM(
			httpCA.CertificatePEM,
			httpCA.PrivateKeyPEM,
		)
		if err != nil {
			return material, fmt.Errorf("HTTP TLS CA load failed: %w", err)
		}
		httpServer, err := store.GetOrCreateCertificateMaterial(
			ctx,
			relayHTTPServerMaterialName,
			options.RotationWindow,
			func(now time.Time) (control.CertificateMaterial, error) {
				generated, err := issuer.IssueServerCertificate(
					"Pointy Relay HTTP",
					certificateHosts(options.HTTPSName, options.HTTPAddr),
					options.ServerCertTTL,
					now,
				)
				if err != nil {
					return control.CertificateMaterial{}, err
				}
				return certificateMaterialFromGenerated(generated), nil
			},
		)
		if err != nil {
			return material, fmt.Errorf("HTTP TLS certificate setup failed: %w", err)
		}
		material.HTTPServerCertPEM = httpServer.CertificatePEM
		material.HTTPServerKeyPEM = httpServer.PrivateKeyPEM
		logger.Info("using database-backed HTTP TLS certificate")
	}

	if !options.InsecureConnector && needsConnectorAutoTLS(options) {
		connectorCA, err := store.GetOrCreateCertificateMaterial(
			ctx,
			relayConnectorCAMaterialName,
			0,
			func(now time.Time) (control.CertificateMaterial, error) {
				generated, err := security.GenerateCertificateAuthority(
					"Pointy Relay Connector mTLS CA",
					options.CATTL,
					now,
				)
				if err != nil {
					return control.CertificateMaterial{}, err
				}
				return certificateMaterialFromGenerated(generated), nil
			},
		)
		if err != nil {
			return material, fmt.Errorf("connector mTLS CA setup failed: %w", err)
		}
		issuer, err := security.LoadCertificateAuthorityPEM(
			connectorCA.CertificatePEM,
			connectorCA.PrivateKeyPEM,
		)
		if err != nil {
			return material, fmt.Errorf("connector mTLS CA load failed: %w", err)
		}
		if strings.TrimSpace(options.ConnectorCA) == "" {
			material.ConnectorCAPEM = connectorCA.CertificatePEM
		}
		if strings.TrimSpace(options.ConnectorCAKey) == "" {
			material.ConnectorCAKeyPEM = connectorCA.PrivateKeyPEM
		}
		if certificatePairMissing(options.ConnectorCert, options.ConnectorKey) {
			connectorServer, err := store.GetOrCreateCertificateMaterial(
				ctx,
				relayConnectorCertMaterialName,
				options.RotationWindow,
				func(now time.Time) (control.CertificateMaterial, error) {
					generated, err := issuer.IssueServerCertificate(
						"Pointy Relay Connector",
						certificateHosts(options.ConnectorName, options.ConnectorAddr),
						options.ServerCertTTL,
						now,
					)
					if err != nil {
						return control.CertificateMaterial{}, err
					}
					return certificateMaterialFromGenerated(generated), nil
				},
			)
			if err != nil {
				return material, fmt.Errorf("connector TLS certificate setup failed: %w", err)
			}
			material.ConnectorServerCertPEM = connectorServer.CertificatePEM
			material.ConnectorServerKeyPEM = connectorServer.PrivateKeyPEM
		}
		logger.Info("using database-backed connector mTLS material")
	}

	return material, nil
}

func certificateMaterialFromGenerated(
	generated security.PEMCertificate,
) control.CertificateMaterial {
	expiresAt := generated.ExpiresAt.UTC()
	return control.CertificateMaterial{
		CertificatePEM: generated.CertificatePEM,
		PrivateKeyPEM:  generated.PrivateKeyPEM,
		ExpiresAt:      &expiresAt,
	}
}

func needsConnectorAutoTLS(options relayAutoTLSOptions) bool {
	return certificatePairMissing(options.ConnectorCert, options.ConnectorKey) ||
		strings.TrimSpace(options.ConnectorCA) == "" ||
		strings.TrimSpace(options.ConnectorCAKey) == ""
}

func certificatePairMissing(cert string, key string) bool {
	return strings.TrimSpace(cert) == "" && strings.TrimSpace(key) == ""
}

func certificatePairPartial(cert string, key string) bool {
	return (strings.TrimSpace(cert) == "") != (strings.TrimSpace(key) == "")
}

func certificateHosts(serverName string, listenAddr string) []string {
	var hosts []string
	if host := normalizedCertificateHost(serverName); host != "" {
		hosts = append(hosts, host)
	}
	if host := listenAddressCertificateHost(listenAddr); host != "" {
		hosts = append(hosts, host)
	}
	if len(hosts) == 0 {
		hosts = append(hosts, "localhost", "127.0.0.1", "::1")
	}
	return hosts
}

func hasUsableCertificateHost(serverName string, listenAddr string) bool {
	if normalizedCertificateHost(serverName) != "" {
		return true
	}
	return listenAddressCertificateHost(listenAddr) != ""
}

func normalizedCertificateHost(value string) string {
	value = strings.Trim(strings.TrimSpace(value), "[]")
	if value == "" || isWildcardHost(value) {
		return ""
	}
	return value
}

func listenAddressCertificateHost(addr string) string {
	host := strings.TrimSpace(addr)
	if host == "" {
		return ""
	}
	if splitHost, _, err := net.SplitHostPort(host); err == nil {
		host = splitHost
	}
	return normalizedCertificateHost(host)
}

func isWildcardHost(host string) bool {
	return host == "" || host == "0.0.0.0" || host == "::" || host == "*"
}
