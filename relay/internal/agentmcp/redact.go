package agentmcp

import (
	"strings"
)

// redact removes what must never reach a model, whatever an admin handler
// answers: card codes and PINs, serials and eSIM activation data, tokens,
// keys and secrets, and people's contact details. It works on field names, so
// a field added to a handler later is covered by the same rules; values that
// look like relay tokens are blanked wherever they appear.

const redacted = "[redacted]"

// redactedFields are dropped outright (lower-case JSON names).
var redactedFields = map[string]bool{
	// card material
	"code": true, "codes": true, "pin": true, "pins": true, "serial": true, "serials": true,
	"serial_number": true, "card_number": true, "card_code": true, "voucher_code": true,
	"redeem_code": true, "redemption_code": true, "qr": true, "qr_code": true, "qrcode": true,
	// eSIM activation
	"iccid": true, "lpa": true, "activation_code": true, "smdp_address": true, "matching_id": true,
	"ac": true, "esim_qr": true,
	// credentials
	"token": true, "tokens": true, "password": true, "secret": true, "api_key": true, "apikey": true,
	"authorization": true, "cookie": true, "signature": true, "webhook_url": true, "topic": true,
	"idempotency_key": true, "license_key": true, "setup_token": true, "private_key": true,
	"credential": true, "credentials": true, "otp": true,
	// people
	"phone": true, "phone_number": true, "mobile": true, "email": true, "address": true,
	"iban": true, "account_number": true, "national_id": true, "birth_date": true,
	"target": true, "player_id": true, "username": true,
	"ip": true, "user_agent": true, "receipt": true, "details": true,
}

// redactedSuffixes catch the rest of the families.
var redactedSuffixes = []string{
	"_token", "_tokens", "_secret", "_password", "_pin", "_key", "_code_hash", "_hash",
	"_phone", "_email", "_iban", "_otp", "_credential", "_cookie", "_serial", "_fingerprint",
}

// keptFields end in a redacted suffix but are safe and useful.
var keptFields = map[string]bool{
	"error_code": true, "bank_code": true, "currency_code": true, "country_code": true, "operator_code": true,
	"status_code": true, "reason_code": true, "item_key": true, "brand_key": true, "sha256": true,
}

func redactField(name string) bool {
	lower := strings.ToLower(name)
	if keptFields[lower] {
		return false
	}
	if redactedFields[lower] {
		return true
	}
	if strings.Contains(lower, "secret") || strings.Contains(lower, "password") {
		return true
	}
	for _, suffix := range redactedSuffixes {
		if strings.HasSuffix(lower, suffix) {
			return true
		}
	}
	return false
}

// tokenPrefixes are the relay's own credentials (control/token.go) and ours.
var tokenPrefixes = []string{"ptc1.", "ptr1.", "ptt1.", "ptrf1.", "pte1.", tokenPrefix, "Bearer "}

// errorCode lets a handler's error code through ("code": "supplier_unconfigured"):
// lower-case words joined by underscores, which no card code looks like.
func errorCode(key string, value any) bool {
	text, ok := value.(string)
	if !ok || strings.ToLower(key) != "code" || len(text) < 3 || len(text) > 48 || !strings.Contains(text, "_") {
		return false
	}
	for _, r := range text {
		if (r < 'a' || r > 'z') && r != '_' {
			return false
		}
	}
	return true
}

func redact(value any) any {
	switch v := value.(type) {
	case map[string]any:
		out := make(map[string]any, len(v))
		for key, item := range v {
			if redactField(key) && !errorCode(key, item) {
				if item != nil && item != "" {
					out[key] = redacted
				}
				continue
			}
			out[key] = redact(item)
		}
		return out
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = redact(item)
		}
		return out
	case string:
		for _, prefix := range tokenPrefixes {
			if strings.HasPrefix(v, prefix) {
				return redacted
			}
		}
		return v
	default:
		return value
	}
}
