package airalo

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha512"
	"encoding/hex"
	"encoding/json"
	"strings"
)

// SignatureHeader carries the HMAC-SHA512 of a webhook's body.
const SignatureHeader = "airalo-signature"

// VerifySignature checks a delivery against the account's secret. Airalo's docs
// sign the JSON text of the payload; the body as sent is that text, and its
// compact form is tried too, the way their own examples re-encode it.
func VerifySignature(secret string, body []byte, signature string) bool {
	signature = strings.ToLower(strings.TrimSpace(signature))
	if secret == "" || signature == "" {
		return false
	}
	want, err := hex.DecodeString(signature)
	if err != nil {
		return false
	}
	if hmac.Equal(sign(secret, body), want) {
		return true
	}
	var compact bytes.Buffer
	if json.Compact(&compact, body) != nil {
		return false
	}
	return hmac.Equal(sign(secret, compact.Bytes()), want)
}

func sign(secret string, body []byte) []byte {
	mac := hmac.New(sha512.New, []byte(secret))
	mac.Write(body)
	return mac.Sum(nil)
}

// Sign is a delivery's signature, as Airalo computes it (tests, and the local
// simulator).
func Sign(secret string, body []byte) string { return hex.EncodeToString(sign(secret, body)) }

// Low-data levels Airalo sends.
const (
	Level75    = "75%"
	Level90    = "90%"
	Level3Days = "3days"
	Level1Day  = "1days"
)

// Event is one webhook delivery of the low-data or credit-limit kind.
type Event struct {
	// A low-data alert.
	Level               string `json:"level"`
	PackageName         string `json:"package_name"`
	RemainingPercentage Number `json:"remaining_percentage"`
	ICCID               string `json:"iccid"`
	// A credit-limit alert.
	Message   string `json:"message"`
	Remaining Number `json:"remaining"`
}

// IsLowData tells a low-data alert from a credit-limit one.
func (e Event) IsLowData() bool { return e.ICCID != "" && e.Level != "" }
