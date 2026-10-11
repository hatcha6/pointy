package vouchers

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
)

// The company's own card stock keeps codes worth money in the relay's
// database. They are sealed before they are stored: AES-256-GCM under a key
// that lives only in the relay's environment (POINTY_RELAY_VOUCHER_STOCK_KEY),
// so a copy of the database or a backup alone gives nobody a usable code. Two
// keys are derived from it: one encrypts, the other fingerprints a code
// (HMAC-SHA256) so the store can refuse the same code twice without ever
// holding it in the clear. Each sealed code is bound to its item, so a code
// moved to another card's row no longer opens.
//
// Lose the key and every code in stock is lost with it: keep it with the other
// relay secrets, and back it up apart from the database.

// StockKeyBytes is the size of the stock key.
const StockKeyBytes = 32

// stockSealVersion prefixes every sealed code, so a later key or scheme can
// sit beside this one.
const stockSealVersion = "v1:"

// ErrStockSealUnreadable: a sealed code that does not open under this key —
// another key sealed it, or it was changed.
var ErrStockSealUnreadable = errors.New("the stock code cannot be opened with this relay's stock key")

// StockSealer seals, opens and fingerprints the codes of the company's stock.
type StockSealer struct {
	aead        cipher.AEAD
	fingerprint []byte
}

// ParseStockKey reads the stock key: 32 random bytes written in base64
// (standard or URL alphabet, padded or not), as `pointy-relay gen-stock-key`
// prints it.
func ParseStockKey(text string) ([]byte, error) {
	text = strings.TrimSpace(text)
	for _, encoding := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if key, err := encoding.DecodeString(text); err == nil {
			if len(key) != StockKeyBytes {
				return nil, fmt.Errorf("the stock key must be %d bytes, got %d (generate one with `pointy-relay gen-stock-key`)", StockKeyBytes, len(key))
			}
			return key, nil
		}
	}
	return nil, errors.New("the stock key is not base64 (generate one with `pointy-relay gen-stock-key`)")
}

// GenerateStockKey is a fresh random stock key, in base64.
func GenerateStockKey() (string, error) {
	key := make([]byte, StockKeyBytes)
	if _, err := rand.Read(key); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(key), nil
}

// NewStockSealer derives the sealing and fingerprint keys from the stock key.
func NewStockSealer(key []byte) (*StockSealer, error) {
	if len(key) != StockKeyBytes {
		return nil, fmt.Errorf("the stock key must be %d bytes", StockKeyBytes)
	}
	derive := func(purpose string) []byte {
		mac := hmac.New(sha256.New, key)
		mac.Write([]byte("pointy-relay voucher stock: " + purpose))
		return mac.Sum(nil)
	}
	block, err := aes.NewCipher(derive("seal"))
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &StockSealer{aead: aead, fingerprint: derive("fingerprint")}, nil
}

func stockAAD(itemKey string) []byte {
	return []byte(stockSealVersion + itemKey)
}

// Seal encrypts a code for an item's row.
func (s *StockSealer) Seal(itemKey, code string) (string, error) {
	nonce := make([]byte, s.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	sealed := s.aead.Seal(nonce, nonce, []byte(code), stockAAD(itemKey))
	return stockSealVersion + base64.RawStdEncoding.EncodeToString(sealed), nil
}

// Open decrypts a code sealed for this item.
func (s *StockSealer) Open(itemKey, sealed string) (string, error) {
	body, ok := strings.CutPrefix(sealed, stockSealVersion)
	if !ok {
		return "", ErrStockSealUnreadable
	}
	raw, err := base64.RawStdEncoding.DecodeString(body)
	if err != nil || len(raw) < s.aead.NonceSize() {
		return "", ErrStockSealUnreadable
	}
	nonce, ciphertext := raw[:s.aead.NonceSize()], raw[s.aead.NonceSize():]
	plain, err := s.aead.Open(nil, nonce, ciphertext, stockAAD(itemKey))
	if err != nil {
		return "", ErrStockSealUnreadable
	}
	return string(plain), nil
}

// Fingerprint identifies a code without revealing it: the same code always
// gives the same fingerprint under one key, whatever its item.
func (s *StockSealer) Fingerprint(code string) string {
	mac := hmac.New(sha256.New, s.fingerprint)
	mac.Write([]byte(code))
	return hex.EncodeToString(mac.Sum(nil))
}

// MaskCode shows a code's last four characters and hides the rest: all the
// operator's console ever shows of it.
func MaskCode(code string) string {
	runes := []rune(code)
	if len(runes) <= 4 {
		return strings.Repeat("•", len(runes))
	}
	return "••••" + string(runes[len(runes)-4:])
}
