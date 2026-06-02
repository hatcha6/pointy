package control

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
)

const (
	ConnectorTokenPrefix = "ptc1"
	AccessTokenPrefix    = "ptr1"
	TicketTokenPrefix    = "ptt1"
)

var (
	ErrInvalidToken = errors.New("invalid relay token")
	ErrWrongPurpose = errors.New("relay token has the wrong purpose")
)

type TokenPurpose string

const (
	TokenPurposeConnector TokenPurpose = "connector"
	TokenPurposeAccess    TokenPurpose = "access"
	TokenPurposeTicket    TokenPurpose = "ticket"
)

type ParsedToken struct {
	Purpose        TokenPurpose
	InstallationID string
	Raw            string
}

func NewInstallationID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf(
		"%08x-%04x-%04x-%04x-%012x",
		b[0:4],
		b[4:6],
		b[6:8],
		b[8:10],
		b[10:16],
	), nil
}

func NewToken(prefix, installationID string) (string, error) {
	secret, err := randomSecret(32)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%s.%s.%s", prefix, installationID, secret), nil
}

func ParseToken(raw string) (ParsedToken, error) {
	token := strings.TrimSpace(raw)
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return ParsedToken{}, ErrInvalidToken
	}

	var purpose TokenPurpose
	switch parts[0] {
	case ConnectorTokenPrefix:
		purpose = TokenPurposeConnector
	case AccessTokenPrefix:
		purpose = TokenPurposeAccess
	case TicketTokenPrefix:
		purpose = TokenPurposeTicket
	default:
		return ParsedToken{}, ErrInvalidToken
	}
	if parts[1] == "" || parts[2] == "" {
		return ParsedToken{}, ErrInvalidToken
	}

	return ParsedToken{
		Purpose:        purpose,
		InstallationID: parts[1],
		Raw:            token,
	}, nil
}

func TokenHash(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func ConstantTimeTokenEqual(raw, hash string) bool {
	candidate := TokenHash(raw)
	return subtle.ConstantTimeCompare([]byte(candidate), []byte(hash)) == 1
}

func randomSecret(size int) (string, error) {
	buf := make([]byte, size)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}
