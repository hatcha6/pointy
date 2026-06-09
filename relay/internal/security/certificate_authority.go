package security

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"sort"
	"strings"
	"time"
)

type PEMCertificate struct {
	CertificatePEM string
	PrivateKeyPEM  string
	ExpiresAt      time.Time
}

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
	return LoadCertificateAuthorityPEM(string(certPEM), string(keyPEM))
}

func LoadCertificateAuthorityPEM(certPEM string, keyPEM string) (*CertificateAuthority, error) {
	certPEM = strings.TrimSpace(certPEM)
	keyPEM = strings.TrimSpace(keyPEM)
	if certPEM == "" || keyPEM == "" {
		return nil, fmt.Errorf("certificate authority certificate and key are required")
	}
	certificate, err := parseCertificate([]byte(certPEM))
	if err != nil {
		return nil, err
	}
	if !certificate.IsCA {
		return nil, fmt.Errorf("connector certificate issuer must be a CA certificate")
	}
	privateKey, err := parseSigner([]byte(keyPEM))
	if err != nil {
		return nil, err
	}
	return &CertificateAuthority{
		certificate:    certificate,
		privateKey:     privateKey,
		certificatePEM: certPEM,
	}, nil
}

func GenerateCertificateAuthority(commonName string, ttl time.Duration, now time.Time) (PEMCertificate, error) {
	if ttl <= 0 {
		ttl = 10 * 365 * 24 * time.Hour
	}
	commonName = strings.TrimSpace(commonName)
	if commonName == "" {
		commonName = "Pointy Relay Certificate Authority"
	}
	now = now.UTC()
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return PEMCertificate{}, err
	}
	serialNumber, err := randomSerialNumber()
	if err != nil {
		return PEMCertificate{}, err
	}
	template := &x509.Certificate{
		SerialNumber: serialNumber,
		Subject: pkix.Name{
			CommonName:   commonName,
			Organization: []string{"Pointy"},
		},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(ttl),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		IsCA:                  true,
		BasicConstraintsValid: true,
	}
	certDER, err := x509.CreateCertificate(rand.Reader, template, template, privateKey.Public(), privateKey)
	if err != nil {
		return PEMCertificate{}, err
	}
	keyPEM, err := privateKeyPEM(privateKey)
	if err != nil {
		return PEMCertificate{}, err
	}
	return PEMCertificate{
		CertificatePEM: certificatePEM(certDER),
		PrivateKeyPEM:  keyPEM,
		ExpiresAt:      template.NotAfter,
	}, nil
}

func (ca *CertificateAuthority) IssueServerCertificate(
	commonName string,
	hosts []string,
	ttl time.Duration,
	now time.Time,
) (PEMCertificate, error) {
	if ca == nil {
		return PEMCertificate{}, fmt.Errorf("certificate authority is not configured")
	}
	if ttl <= 0 {
		ttl = 397 * 24 * time.Hour
	}
	commonName = strings.TrimSpace(commonName)
	dnsNames, ipAddresses := certificateHostNames(hosts)
	if commonName == "" {
		if len(dnsNames) > 0 {
			commonName = dnsNames[0]
		} else if len(ipAddresses) > 0 {
			commonName = ipAddresses[0].String()
		} else {
			commonName = "Pointy Relay"
		}
	}
	now = now.UTC()
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return PEMCertificate{}, err
	}
	serialNumber, err := randomSerialNumber()
	if err != nil {
		return PEMCertificate{}, err
	}
	notAfter, err := issuedCertificateNotAfter(ca.certificate, ttl, now)
	if err != nil {
		return PEMCertificate{}, err
	}
	template := &x509.Certificate{
		SerialNumber: serialNumber,
		Subject: pkix.Name{
			CommonName:   commonName,
			Organization: []string{"Pointy"},
		},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:              dnsNames,
		IPAddresses:           ipAddresses,
		BasicConstraintsValid: true,
	}
	certDER, err := x509.CreateCertificate(
		rand.Reader,
		template,
		ca.certificate,
		privateKey.Public(),
		ca.privateKey,
	)
	if err != nil {
		return PEMCertificate{}, err
	}
	keyPEM, err := privateKeyPEM(privateKey)
	if err != nil {
		return PEMCertificate{}, err
	}
	return PEMCertificate{
		CertificatePEM: certificatePEM(certDER),
		PrivateKeyPEM:  keyPEM,
		ExpiresAt:      template.NotAfter,
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
	notAfter, err := issuedCertificateNotAfter(ca.certificate, ttl, now)
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
		NotAfter:              notAfter,
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
		CertificatePEM:    certificatePEM(certDER),
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

func issuedCertificateNotAfter(
	issuer *x509.Certificate,
	ttl time.Duration,
	now time.Time,
) (time.Time, error) {
	notAfter := now.UTC().Add(ttl)
	issuerNotAfter := issuer.NotAfter.UTC()
	if issuerNotAfter.Before(notAfter) {
		notAfter = issuerNotAfter
	}
	if !notAfter.After(now.UTC()) {
		return time.Time{}, fmt.Errorf("certificate authority is expired")
	}
	return notAfter, nil
}

func certificateHostNames(hosts []string) ([]string, []net.IP) {
	seen := map[string]bool{}
	var dnsNames []string
	var ipAddresses []net.IP
	for _, host := range hosts {
		host = strings.Trim(strings.TrimSpace(host), "[]")
		if host == "" || seen[host] {
			continue
		}
		seen[host] = true
		if ip := net.ParseIP(host); ip != nil {
			ipAddresses = append(ipAddresses, ip)
			continue
		}
		dnsNames = append(dnsNames, host)
	}
	sort.Strings(dnsNames)
	sort.Slice(ipAddresses, func(i, j int) bool {
		return ipAddresses[i].String() < ipAddresses[j].String()
	})
	return dnsNames, ipAddresses
}

func certificatePEM(certDER []byte) string {
	return string(pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: certDER,
	}))
}

func privateKeyPEM(privateKey crypto.PrivateKey) (string, error) {
	keyDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return "", err
	}
	return string(pem.EncodeToMemory(&pem.Block{
		Type:  "PRIVATE KEY",
		Bytes: keyDER,
	})), nil
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
