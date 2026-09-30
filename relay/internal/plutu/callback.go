package plutu

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"net/url"
	"strings"
)

// Param is one query parameter in the order it arrived. Plutu signs the
// parameters in order, so the order is part of the signed message and a
// url.Values map — which forgets it — cannot be used to verify.
type Param struct {
	Key   string
	Value string
}

// SignatureParam is the parameter carrying the signature.
const SignatureParam = "hashed"

// LocalBankCardsSignedFields are the parameters Plutu's own SDK signs on a
// local-bank-card return (plutu-php PlutuLocalBankCards::callbackHandler).
var LocalBankCardsSignedFields = []string{"gateway", "approved", "canceled", "invoice_no", "amount", "transaction_id"}

// ParseQuery splits a raw query string into its parameters, decoded, in
// order. A parameter that appears twice keeps its first position and its last
// value, which is what PHP — and therefore Plutu — does with a repeated key.
func ParseQuery(rawQuery string) ([]Param, error) {
	params := []Param{}
	index := map[string]int{}
	for _, pair := range strings.Split(rawQuery, "&") {
		if pair == "" {
			continue
		}
		rawKey, rawValue, _ := strings.Cut(pair, "=")
		key, err := url.QueryUnescape(rawKey)
		if err != nil {
			return nil, err
		}
		value, err := url.QueryUnescape(rawValue)
		if err != nil {
			return nil, err
		}
		if position, seen := index[key]; seen {
			params[position].Value = value
			continue
		}
		index[key] = len(params)
		params = append(params, Param{Key: key, Value: value})
	}
	return params, nil
}

// Callback is what a return says. Read it only after VerifyCallback.
type Callback struct {
	Gateway       string
	InvoiceNo     string
	Amount        string
	TransactionID string
	// Approved is "approved=1". Plutu sends it only for a completed payment,
	// and its docs insist it be checked for exactly 1.
	Approved bool
	// Canceled is "canceled=1": the payer pressed cancel.
	Canceled bool
}

// ReadCallback extracts the fields the relay acts on.
func ReadCallback(params []Param) Callback {
	value := func(key string) string {
		for _, param := range params {
			if param.Key == key {
				return strings.TrimSpace(param.Value)
			}
		}
		return ""
	}
	return Callback{
		Gateway:       value("gateway"),
		InvoiceNo:     value("invoice_no"),
		Amount:        value("amount"),
		TransactionID: value("transaction_id"),
		Approved:      value("approved") == "1",
		Canceled:      value("canceled") == "1",
	}
}

// VerifyCallback checks the "hashed" signature: an upper-case hex SHA-256 HMAC,
// keyed with the merchant secret, of the parameters PHP-encoded in the order
// they arrived.
//
// Plutu's documentation and its SDK disagree on WHICH parameters are signed —
// "all except hashed" against a fixed list per gateway — so both readings are
// tried. Neither can be satisfied without the secret, so accepting either
// gives a forger nothing.
func VerifyCallback(secretKey string, params []Param, signedFields []string) bool {
	secret := strings.TrimSpace(secretKey)
	if secret == "" {
		return false
	}
	received := ""
	for _, param := range params {
		if param.Key == SignatureParam {
			received = strings.ToUpper(strings.TrimSpace(param.Value))
		}
	}
	if received == "" {
		return false
	}
	allowed := map[string]bool{}
	for _, field := range signedFields {
		allowed[field] = true
	}
	var listed, everything []Param
	for _, param := range params {
		if param.Key == SignatureParam {
			continue
		}
		everything = append(everything, param)
		if allowed[param.Key] {
			listed = append(listed, param)
		}
	}
	for _, candidate := range [][]Param{listed, everything} {
		if hmac.Equal([]byte(Sign(secret, candidate)), []byte(received)) {
			return true
		}
	}
	return false
}

// Sign returns the signature Plutu computes over params. Exposed for tests
// and for replaying a return by hand.
func Sign(secretKey string, params []Param) string {
	mac := hmac.New(sha256.New, []byte(secretKey))
	mac.Write([]byte(BuildQuery(params)))
	return strings.ToUpper(hex.EncodeToString(mac.Sum(nil)))
}

// BuildQuery is PHP's http_build_query over string values: each key and
// value urlencode()d, joined with "&".
func BuildQuery(params []Param) string {
	parts := make([]string, 0, len(params))
	for _, param := range params {
		parts = append(parts, phpURLEncode(param.Key)+"="+phpURLEncode(param.Value))
	}
	return strings.Join(parts, "&")
}

// phpURLEncode is PHP's urlencode(): letters, digits and "-_." stay, a space
// becomes "+", every other byte is %XX in upper case. It differs from Go's
// url.QueryEscape only on "~", which PHP encodes.
func phpURLEncode(value string) string {
	const hexDigits = "0123456789ABCDEF"
	var builder strings.Builder
	for i := 0; i < len(value); i++ {
		c := value[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '-', c == '_', c == '.':
			builder.WriteByte(c)
		case c == ' ':
			builder.WriteByte('+')
		default:
			builder.WriteByte('%')
			builder.WriteByte(hexDigits[c>>4])
			builder.WriteByte(hexDigits[c&15])
		}
	}
	return builder.String()
}
