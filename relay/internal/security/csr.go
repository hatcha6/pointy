package security

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"strings"
)

type GeneratedCertificateRequest struct {
	PrivateKeyPEM string
	CSRPem        string
}

func GenerateClientCertificateRequest(commonName string) (GeneratedCertificateRequest, error) {
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return GeneratedCertificateRequest{}, err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return GeneratedCertificateRequest{}, err
	}
	template := &x509.CertificateRequest{
		Subject: pkix.Name{
			CommonName: strings.TrimSpace(commonName),
		},
	}
	csrDER, err := x509.CreateCertificateRequest(rand.Reader, template, privateKey)
	if err != nil {
		return GeneratedCertificateRequest{}, err
	}
	return GeneratedCertificateRequest{
		PrivateKeyPEM: string(pem.EncodeToMemory(&pem.Block{
			Type:  "PRIVATE KEY",
			Bytes: keyDER,
		})),
		CSRPem: string(pem.EncodeToMemory(&pem.Block{
			Type:  "CERTIFICATE REQUEST",
			Bytes: csrDER,
		})),
	}, nil
}
