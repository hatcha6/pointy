package security

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"os"
	"strings"
)

type ServerTLSOptions struct {
	CertFile        string
	CertPEM         string
	KeyFile         string
	KeyPEM          string
	ClientCAFile    string
	ClientCAPEM     string
	RequireClientCA bool
	RequestClientCA bool
}

type ClientTLSOptions struct {
	CAFile             string
	CAPEM              string
	CertFile           string
	CertPEM            string
	KeyFile            string
	KeyPEM             string
	ServerName         string
	InsecureSkipVerify bool
}

func ServerTLSConfig(options ServerTLSOptions) (*tls.Config, error) {
	if (strings.TrimSpace(options.CertFile) == "" && strings.TrimSpace(options.CertPEM) == "") ||
		(strings.TrimSpace(options.KeyFile) == "" && strings.TrimSpace(options.KeyPEM) == "") {
		return nil, fmt.Errorf("TLS certificate and key are required")
	}
	certificate, err := serverCertificate(options)
	if err != nil {
		return nil, err
	}

	config := &tls.Config{
		Certificates: []tls.Certificate{certificate},
		MinVersion:   tls.VersionTLS12,
	}
	clientCAFile := strings.TrimSpace(options.ClientCAFile)
	clientCAPEM := strings.TrimSpace(options.ClientCAPEM)
	if options.RequireClientCA || options.RequestClientCA || clientCAFile != "" || clientCAPEM != "" {
		pool, err := certificatePoolFromOptions(clientCAFile, clientCAPEM)
		if err != nil {
			return nil, err
		}
		config.ClientCAs = pool
		if options.RequestClientCA && !options.RequireClientCA {
			config.ClientAuth = tls.VerifyClientCertIfGiven
		} else {
			config.ClientAuth = tls.RequireAndVerifyClientCert
		}
	}
	return config, nil
}

func serverCertificate(options ServerTLSOptions) (tls.Certificate, error) {
	if strings.TrimSpace(options.CertFile) != "" || strings.TrimSpace(options.KeyFile) != "" {
		return tls.LoadX509KeyPair(options.CertFile, options.KeyFile)
	}
	return tls.X509KeyPair(
		[]byte(strings.TrimSpace(options.CertPEM)),
		[]byte(strings.TrimSpace(options.KeyPEM)),
	)
}

func ClientTLSConfig(options ClientTLSOptions) (*tls.Config, error) {
	config := &tls.Config{
		MinVersion:         tls.VersionTLS12,
		ServerName:         strings.TrimSpace(options.ServerName),
		InsecureSkipVerify: options.InsecureSkipVerify,
	}
	if strings.TrimSpace(options.CAFile) != "" || strings.TrimSpace(options.CAPEM) != "" {
		pool, err := certificatePoolFromOptions(options.CAFile, options.CAPEM)
		if err != nil {
			return nil, err
		}
		config.RootCAs = pool
	}
	if strings.TrimSpace(options.CertFile) != "" ||
		strings.TrimSpace(options.KeyFile) != "" ||
		strings.TrimSpace(options.CertPEM) != "" ||
		strings.TrimSpace(options.KeyPEM) != "" {
		if (strings.TrimSpace(options.CertFile) == "" && strings.TrimSpace(options.CertPEM) == "") ||
			(strings.TrimSpace(options.KeyFile) == "" && strings.TrimSpace(options.KeyPEM) == "") {
			return nil, fmt.Errorf("client certificate and key must be provided together")
		}
		certificate, err := clientCertificate(options)
		if err != nil {
			return nil, err
		}
		config.Certificates = []tls.Certificate{certificate}
	}
	return config, nil
}

func clientCertificate(options ClientTLSOptions) (tls.Certificate, error) {
	if strings.TrimSpace(options.CertFile) != "" || strings.TrimSpace(options.KeyFile) != "" {
		return tls.LoadX509KeyPair(options.CertFile, options.KeyFile)
	}
	if strings.TrimSpace(options.CertPEM) != "" || strings.TrimSpace(options.KeyPEM) != "" {
		return tls.X509KeyPair(
			[]byte(strings.TrimSpace(options.CertPEM)),
			[]byte(strings.TrimSpace(options.KeyPEM)),
		)
	}
	return tls.Certificate{}, fmt.Errorf("client certificate and key are required")
}

func certificatePoolFromOptions(path string, content string) (*x509.CertPool, error) {
	if strings.TrimSpace(path) != "" {
		return certificatePool(path)
	}
	if strings.TrimSpace(content) != "" {
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM([]byte(strings.TrimSpace(content))) {
			return nil, fmt.Errorf("no PEM certificates found")
		}
		return pool, nil
	}
	return certificatePool(path)
}

func certificatePool(path string) (*x509.CertPool, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("client CA bundle is required")
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(content) {
		return nil, fmt.Errorf("no PEM certificates found in %s", path)
	}
	return pool, nil
}
