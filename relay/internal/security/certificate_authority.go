package security

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"strings"
	"time"
)

type IssuedCertificate struct {
	CertificatePEM    string    `json:"certificate_pem"`
	CACertificatePEM  string    `json:"ca_certificate_pem"`
	FingerprintSHA256 string    `json:"fingerprint_sha256"`
	SerialNumber      string    `json:"serial_number"`
	ExpiresAt         time.Time `json:"expires_at"`
}

type CertificateAuthority struct {
	certificate    *x509.Certificate
	privateKey     crypto.Signer
	certificatePEM string
}

func LoadCertificateAuthority(certFile string, keyFile string) (*CertificateAuthority, error) {
	certPEM, err := os.ReadFile(strings.TrimSpace(certFile))
	if err != nil {
		return nil, err
	}
	keyPEM, err := os.ReadFile(strings.TrimSpace(keyFile))
	if err != nil {
		return nil, err
	}
	certificate, err := parseCertificate(certPEM)
	if err != nil {
		return nil, err
	}
	if !certificate.IsCA {
		return nil, fmt.Errorf("connector certificate issuer must be a CA certificate")
	}
	privateKey, err := parseSigner(keyPEM)
	if err != nil {
		return nil, err
	}
	return &CertificateAuthority{
		certificate:    certificate,
		privateKey:     privateKey,
		certificatePEM: string(certPEM),
	}, nil
}

func (ca *CertificateAuthority) IssueClientCertificateFromCSR(
	csrPEM string,
	commonName string,
	ttl time.Duration,
	now time.Time,
) (IssuedCertificate, error) {
	if ca == nil {
		return IssuedCertificate{}, fmt.Errorf("certificate authority is not configured")
	}
	csr, err := parseCertificateRequest([]byte(strings.TrimSpace(csrPEM)))
	if err != nil {
		return IssuedCertificate{}, err
	}
	if err := csr.CheckSignature(); err != nil {
		return IssuedCertificate{}, fmt.Errorf("CSR signature is invalid: %w", err)
	}
	if ttl <= 0 {
		ttl = 90 * 24 * time.Hour
	}
	now = now.UTC()
	serialNumber, err := randomSerialNumber()
	if err != nil {
		return IssuedCertificate{}, err
	}
	template := &x509.Certificate{
		SerialNumber: serialNumber,
		Subject: pkix.Name{
			CommonName:   strings.TrimSpace(commonName),
			Organization: []string{"Pointy"},
		},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(ttl),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
		BasicConstraintsValid: true,
	}
	certDER, err := x509.CreateCertificate(
		rand.Reader,
		template,
		ca.certificate,
		csr.PublicKey,
		ca.privateKey,
	)
	if err != nil {
		return IssuedCertificate{}, err
	}
	return IssuedCertificate{
		CertificatePEM: string(pem.EncodeToMemory(&pem.Block{
			Type:  "CERTIFICATE",
			Bytes: certDER,
		})),
		CACertificatePEM:  ca.certificatePEM,
		FingerprintSHA256: CertificateFingerprintSHA256(certDER),
		SerialNumber:      serialNumber.Text(16),
		ExpiresAt:         template.NotAfter,
	}, nil
}

func CertificateFingerprintSHA256(rawDER []byte) string {
	sum := sha256.Sum256(rawDER)
	return hex.EncodeToString(sum[:])
}

func parseCertificateRequest(content []byte) (*x509.CertificateRequest, error) {
	for {
		block, rest := pem.Decode(content)
		if block == nil {
			break
		}
		content = rest
		if block.Type != "CERTIFICATE REQUEST" && block.Type != "NEW CERTIFICATE REQUEST" {
			continue
		}
		return x509.ParseCertificateRequest(block.Bytes)
	}
	return nil, fmt.Errorf("no PEM certificate request found")
}

func parseCertificate(content []byte) (*x509.Certificate, error) {
	for {
		block, rest := pem.Decode(content)
		if block == nil {
			break
		}
		content = rest
		if block.Type != "CERTIFICATE" {
			continue
		}
		return x509.ParseCertificate(block.Bytes)
	}
	return nil, fmt.Errorf("no PEM certificate found")
}

func parseSigner(content []byte) (crypto.Signer, error) {
	for {
		block, rest := pem.Decode(content)
		if block == nil {
			break
		}
		content = rest
		var parsed any
		var err error
		switch block.Type {
		case "PRIVATE KEY":
			parsed, err = x509.ParsePKCS8PrivateKey(block.Bytes)
		case "RSA PRIVATE KEY":
			parsed, err = x509.ParsePKCS1PrivateKey(block.Bytes)
		case "EC PRIVATE KEY":
			parsed, err = x509.ParseECPrivateKey(block.Bytes)
		default:
			continue
		}
		if err != nil {
			return nil, err
		}
		switch key := parsed.(type) {
		case crypto.Signer:
			return key, nil
		case *rsa.PrivateKey:
			return key, nil
		}
		return nil, fmt.Errorf("private key is not usable for signing")
	}
	return nil, fmt.Errorf("no PEM private key found")
}

func randomSerialNumber() (*big.Int, error) {
	limit := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(rand.Reader, limit)
	if err != nil {
		return nil, err
	}
	if serial.Sign() == 0 {
		return big.NewInt(1), nil
	}
	return serial, nil
}
