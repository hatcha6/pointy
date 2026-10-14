package moamalat

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
)

// A Moamalat token is a full merchant-portal session for as long as it is kept
// warm, so the relay never stores one in the clear. It is sealed exactly like
// the company's voucher stock (internal/vouchers/stock_seal.go): AES-256-GCM
// under a key that lives only in the relay's environment
// (POINTY_RELAY_MOAMALAT_TOKEN_KEY), its own key so neither secret opens the
// other's rows. Each sealed token is bound to its shop and merchant id, so a
// sealed value copied onto another shop's row does not open.
//
// Lose the key and every shop must re-link (one OTP each) — nothing else is
// lost. Keep it with the other relay secrets, backed up apart from the
// database.

// KeyBytes is the size of the token key.
const KeyBytes = 32

const sealVersion = "v1:"

// ErrSealUnreadable is a sealed token that does not open under this key.
var ErrSealUnreadable = errors.New("the moamalat token cannot be opened with this relay's key")

// Sealer seals and opens shops' tokens.
type Sealer struct {
	aead cipher.AEAD
}

// ParseKey reads the token key: 32 random bytes in base64, as
// `pointy-relay gen-moamalat-key` prints it.
func ParseKey(text string) ([]byte, error) {
	text = strings.TrimSpace(text)
	for _, encoding := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if key, err := encoding.DecodeString(text); err == nil {
			if len(key) != KeyBytes {
				return nil, fmt.Errorf("the moamalat token key must be %d bytes, got %d (generate one with `pointy-relay gen-moamalat-key`)", KeyBytes, len(key))
			}
			return key, nil
		}
	}
	return nil, errors.New("the moamalat token key is not base64 (generate one with `pointy-relay gen-moamalat-key`)")
}

// GenerateKey is a fresh random token key, in base64.
func GenerateKey() (string, error) {
	key := make([]byte, KeyBytes)
	if _, err := rand.Read(key); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(key), nil
}

// NewSealer derives the sealing key from the token key.
func NewSealer(key []byte) (*Sealer, error) {
	if len(key) != KeyBytes {
		return nil, fmt.Errorf("the moamalat token key must be %d bytes", KeyBytes)
	}
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte("pointy-relay moamalat token: seal"))
	block, err := aes.NewCipher(mac.Sum(nil))
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &Sealer{aead: aead}, nil
}

func aad(installationID, mid string) []byte {
	return []byte(sealVersion + installationID + "\x00" + mid)
}

// Seal encrypts a shop's token.
func (s *Sealer) Seal(installationID, mid, token string) (string, error) {
	nonce := make([]byte, s.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	sealed := s.aead.Seal(nonce, nonce, []byte(token), aad(installationID, mid))
	return sealVersion + base64.RawStdEncoding.EncodeToString(sealed), nil
}

// Open decrypts a token sealed for this shop and merchant id.
func (s *Sealer) Open(installationID, mid, sealed string) (string, error) {
	body, ok := strings.CutPrefix(sealed, sealVersion)
	if !ok {
		return "", ErrSealUnreadable
	}
	raw, err := base64.RawStdEncoding.DecodeString(body)
	if err != nil || len(raw) < s.aead.NonceSize() {
		return "", ErrSealUnreadable
	}
	nonce, ciphertext := raw[:s.aead.NonceSize()], raw[s.aead.NonceSize():]
	plain, err := s.aead.Open(nil, nonce, ciphertext, aad(installationID, mid))
	if err != nil {
		return "", ErrSealUnreadable
	}
	return string(plain), nil
}
