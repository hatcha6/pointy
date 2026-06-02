package security

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCertificateAuthoritySignsCSRWithConnectorIdentity(t *testing.T) {
	caCertPath, caKeyPath := writeTestCA(t)
	issuer, err := LoadCertificateAuthority(caCertPath, caKeyPath)
	if err != nil {
		t.Fatal(err)
	}
	request, err := GenerateClientCertificateRequest("malicious-requested-name")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)

	issued, err := issuer.IssueClientCertificateFromCSR(
		request.CSRPem,
		"pointy-connector-installation-1",
		time.Hour,
		now,
	)
	if err != nil {
		t.Fatal(err)
	}

	certificate := parseSingleCertificate(t, issued.CertificatePEM)
	if certificate.Subject.CommonName != "pointy-connector-installation-1" {
		t.Fatalf("issuer must override CSR identity, got %q", certificate.Subject.CommonName)
	}
	if len(certificate.ExtKeyUsage) != 1 || certificate.ExtKeyUsage[0] != x509.ExtKeyUsageClientAuth {
		t.Fatalf("expected client auth EKU, got %#v", certificate.ExtKeyUsage)
	}
	if issued.FingerprintSHA256 != CertificateFingerprintSHA256(certificate.Raw) {
		t.Fatalf("unexpected fingerprint %q", issued.FingerprintSHA256)
	}
	if issued.CACertificatePEM == "" {
		t.Fatal("expected CA certificate PEM")
	}
}

func writeTestCA(t *testing.T) (string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber:          serialOne(),
		Subject:               pkix.Name{CommonName: "Pointy Test Connector CA"},
		NotBefore:             time.Now().Add(-time.Minute),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		IsCA:                  true,
		BasicConstraintsValid: true,
	}
	certDER, err := x509.CreateCertificate(rand.Reader, template, template, key.Public(), key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	certPath := filepath.Join(dir, "ca.crt")
	keyPath := filepath.Join(dir, "ca.key")
	if err := os.WriteFile(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certDER}), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		t.Fatal(err)
	}
	return certPath, keyPath
}

func parseSingleCertificate(t *testing.T, content string) *x509.Certificate {
	t.Helper()
	block, _ := pem.Decode([]byte(content))
	if block == nil {
		t.Fatal("expected PEM certificate")
	}
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	return certificate
}

func serialOne() *big.Int {
	return big.NewInt(1)
}
