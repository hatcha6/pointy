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
	KeyFile         string
	ClientCAFile    string
	RequireClientCA bool
	RequestClientCA bool
}

type ClientTLSOptions struct {
	CAFile             string
	CertFile           string
	KeyFile            string
	ServerName         string
	InsecureSkipVerify bool
}

func ServerTLSConfig(options ServerTLSOptions) (*tls.Config, error) {
	if strings.TrimSpace(options.CertFile) == "" || strings.TrimSpace(options.KeyFile) == "" {
		return nil, fmt.Errorf("TLS certificate and key are required")
	}
	certificate, err := tls.LoadX509KeyPair(options.CertFile, options.KeyFile)
	if err != nil {
		return nil, err
	}

	config := &tls.Config{
		Certificates: []tls.Certificate{certificate},
		MinVersion:   tls.VersionTLS12,
	}
	clientCAFile := strings.TrimSpace(options.ClientCAFile)
	if options.RequireClientCA || options.RequestClientCA || clientCAFile != "" {
		pool, err := certificatePool(clientCAFile)
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

func ClientTLSConfig(options ClientTLSOptions) (*tls.Config, error) {
	config := &tls.Config{
		MinVersion:         tls.VersionTLS12,
		ServerName:         strings.TrimSpace(options.ServerName),
		InsecureSkipVerify: options.InsecureSkipVerify,
	}
	if strings.TrimSpace(options.CAFile) != "" {
		pool, err := certificatePool(options.CAFile)
		if err != nil {
			return nil, err
		}
		config.RootCAs = pool
	}
	if strings.TrimSpace(options.CertFile) != "" || strings.TrimSpace(options.KeyFile) != "" {
		if strings.TrimSpace(options.CertFile) == "" || strings.TrimSpace(options.KeyFile) == "" {
			return nil, fmt.Errorf("client certificate and key must be provided together")
		}
		certificate, err := tls.LoadX509KeyPair(options.CertFile, options.KeyFile)
		if err != nil {
			return nil, err
		}
		config.Certificates = []tls.Certificate{certificate}
	}
	return config, nil
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
