package relay

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"pointy/relay/internal/fazer"
)

// FazerCards signs each webhook delivery with an HMAC secret ("whsec_…") that
// the relay reads over the API with the company's key: it is never set by
// hand, and a rotated one is read again. FazerCards' spec says neither which
// header carries the signature nor what is signed, so the relay recognises
// the usual ways: Standard Webhooks («webhook-id», «webhook-timestamp»,
// «webhook-signature: v1,<base64>», as Svix sends them, whose secrets are
// also «whsec_»), Stripe's «t=…,v1=<hex>», and a plain HMAC of the body in a
// «…Signature» header, in hex or base64.
//
// Until one delivery has verified, a delivery that does not is still taken
// (it is only a nudge: see vouchers_fazer_webhook.go) and logged with its
// headers' names and its signature's shape, never its value. Once one has,
// the relay knows FazerCards signs, and refuses any delivery that does not
// verify.

const (
	// fazerSecretFor is how long the secret read is reused; a delivery that
	// does not verify reads it again (it may have been rotated), at most this
	// often.
	fazerSecretFor     = 10 * time.Minute
	fazerSecretRecheck = time.Minute
	fazerSecretBudget  = 3 * time.Second
	// fazerSignatureAge is how old a signed timestamp may be: an older
	// delivery is a replay.
	fazerSignatureAge = 5 * time.Minute
)

// FazerSigning is the relay's hold on FazerCards' webhook secret and on how
// FazerCards' deliveries have been seen to be signed.
type FazerSigning struct {
	mu     sync.Mutex
	secret string
	readAt time.Time
	// scheme is how a delivery last verified: once set, every delivery must.
	scheme string
}

// fazerSignatureResult is what checking one delivery's signature came to.
type fazerSignatureResult struct {
	// Scheme is how it verified; empty when it did not.
	Scheme string
	// Enforced: a delivery has verified before, so this one must.
	Enforced bool
	// NoSecret: the secret could not be read, so nothing could be checked.
	NoSecret bool
	// Shape describes the signature headers for the log, never their values.
	Shape string
}

// checkFazerSignature verifies a delivery against the account's secret,
// reading the secret again once if the first one does not fit.
func (s HTTPServer) checkFazerSignature(ctx context.Context, header http.Header, body []byte) fazerSignatureResult {
	signing, client := s.Vouchers.FazerSigning, s.Vouchers.Fazer
	if signing == nil || client == nil {
		return fazerSignatureResult{NoSecret: true}
	}
	now := s.clock().Now()
	secret, fresh := signing.secretNow(ctx, client, now, false)
	result := fazerSignatureResult{Shape: fazerSignatureShape(header)}
	if secret == "" {
		result.NoSecret = true
		return result
	}
	result.Scheme = verifyFazerSignature(secret, header, body, now)
	if result.Scheme == "" && !fresh {
		if again, reread := signing.secretNow(ctx, client, now, true); reread && again != secret {
			result.Scheme = verifyFazerSignature(again, header, body, now)
		}
	}
	signing.mu.Lock()
	defer signing.mu.Unlock()
	result.Enforced = signing.scheme != ""
	if result.Scheme != "" {
		signing.scheme = result.Scheme
	}
	return result
}

// secretNow is the secret, read again when it is old or when force says so
// (at most once a fazerSecretRecheck). fresh reports that it was just read.
func (f *FazerSigning) secretNow(ctx context.Context, client *fazer.Client, now time.Time, force bool) (secret string, fresh bool) {
	f.mu.Lock()
	age := now.Sub(f.readAt)
	if f.secret != "" && age < fazerSecretFor && (!force || age < fazerSecretRecheck) {
		secret := f.secret
		f.mu.Unlock()
		return secret, false
	}
	f.mu.Unlock()
	callCtx, cancel := context.WithTimeout(ctx, fazerSecretBudget)
	defer cancel()
	read, err := client.WebhookSecret(callCtx)
	f.mu.Lock()
	defer f.mu.Unlock()
	if err != nil || read == "" {
		// The last one known stands rather than none.
		return f.secret, false
	}
	f.secret, f.readAt = read, now
	return read, true
}

// verifyFazerSignature is how a delivery's signature verifies under secret,
// or empty when it does not under any way the relay knows.
func verifyFazerSignature(secret string, header http.Header, body []byte, now time.Time) string {
	keys := fazerSigningKeys(secret)
	type signed struct {
		label   string
		content []byte
		at      string // the signed timestamp, when there is one
	}
	var contents []signed
	// Standard Webhooks (Svix): id.timestamp.body.
	for _, prefix := range []string{"webhook-", "svix-"} {
		id, at := header.Get(prefix+"id"), header.Get(prefix+"timestamp")
		if id != "" && at != "" {
			contents = append(contents, signed{prefix + "id.timestamp.body", []byte(id + "." + at + "." + string(body)), at})
		}
	}
	// Stripe: t.body, the timestamp in the signature header itself.
	for _, value := range fazerSignatureValues(header) {
		for _, part := range strings.Split(value, ",") {
			if at, ok := strings.CutPrefix(strings.TrimSpace(part), "t="); ok {
				contents = append(contents, signed{"t.body", []byte(at + "." + string(body)), at})
			}
		}
	}
	// A timestamp header of its own: timestamp.body.
	for name, values := range header {
		if strings.Contains(strings.ToLower(name), "timestamp") && len(values) > 0 {
			contents = append(contents, signed{"timestamp.body", []byte(values[0] + "." + string(body)), values[0]})
		}
	}
	contents = append(contents, signed{"body", body, ""})

	signatures := fazerSignatureCandidates(header)
	if len(signatures) == 0 {
		return ""
	}
	for _, content := range contents {
		if content.at != "" && !fazerFreshTimestamp(content.at, now) {
			continue
		}
		for _, key := range keys {
			mac := hmac.New(sha256.New, key.bytes)
			mac.Write(content.content)
			sum := mac.Sum(nil)
			for _, candidate := range signatures {
				if hmac.Equal(sum, candidate.bytes) {
					return candidate.header + ": " + candidate.encoding + " HMAC-SHA256 of " + content.label + " (key " + key.label + ")"
				}
			}
		}
	}
	return ""
}

type fazerKey struct {
	label string
	bytes []byte
}

// fazerSigningKeys are the ways the secret may be the HMAC key: as it is
// written, without its «whsec_», and that part decoded (base64 for Standard
// Webhooks, or hex).
func fazerSigningKeys(secret string) []fazerKey {
	keys := []fazerKey{{"as written", []byte(secret)}}
	rest, prefixed := strings.CutPrefix(secret, "whsec_")
	if !prefixed {
		return keys
	}
	keys = append(keys, fazerKey{"without whsec_", []byte(rest)})
	if decoded, err := base64.StdEncoding.DecodeString(rest); err == nil {
		keys = append(keys, fazerKey{"base64 after whsec_", decoded})
	} else if decoded, err := base64.RawStdEncoding.DecodeString(rest); err == nil {
		keys = append(keys, fazerKey{"base64 after whsec_", decoded})
	}
	if decoded, err := hex.DecodeString(rest); err == nil {
		keys = append(keys, fazerKey{"hex after whsec_", decoded})
	}
	return keys
}

// fazerSignatureValues are the values of every header that may carry a
// signature.
func fazerSignatureValues(header http.Header) []string {
	var values []string
	for name, all := range header {
		if lower := strings.ToLower(name); strings.Contains(lower, "signature") || strings.Contains(lower, "hmac") {
			values = append(values, all...)
		}
	}
	return values
}

type fazerSignatureCandidate struct {
	header   string
	encoding string
	bytes    []byte
}

// fazerSignatureCandidates reads each signature a delivery carries, whatever
// its wrapping («v1,…» space separated, «t=…,v1=…», «sha256=…»), in hex or
// base64.
func fazerSignatureCandidates(header http.Header) []fazerSignatureCandidate {
	var out []fazerSignatureCandidate
	for name, values := range header {
		lower := strings.ToLower(name)
		if !strings.Contains(lower, "signature") && !strings.Contains(lower, "hmac") {
			continue
		}
		for _, value := range values {
			for _, token := range strings.FieldsFunc(value, func(r rune) bool { return r == ' ' || r == ',' }) {
				token = strings.TrimSpace(token)
				for _, prefix := range []string{"v1=", "sha256=", "v0=", "s="} {
					token = strings.TrimPrefix(token, prefix)
				}
				if token == "" || token == "v1" || strings.HasPrefix(token, "t=") {
					continue
				}
				if decoded, err := hex.DecodeString(token); err == nil {
					out = append(out, fazerSignatureCandidate{lower, "hex", decoded})
				}
				for _, encoding := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
					if decoded, err := encoding.DecodeString(token); err == nil && len(decoded) == sha256.Size {
						out = append(out, fazerSignatureCandidate{lower, "base64", decoded})
						break
					}
				}
			}
		}
	}
	return out
}

// fazerFreshTimestamp reports whether a signed timestamp (Unix seconds or
// milliseconds) is recent enough not to be a replay.
func fazerFreshTimestamp(raw string, now time.Time) bool {
	value, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if err != nil {
		return false
	}
	at := time.Unix(value, 0)
	if value > 1e12 {
		at = time.UnixMilli(value)
	}
	age := now.Sub(at)
	return age < fazerSignatureAge && age > -fazerSignatureAge
}

// fazerSignatureShape describes a delivery's signature headers for the log:
// their names, and each value's length and wrapping, never the value.
func fazerSignatureShape(header http.Header) string {
	var parts []string
	for name, values := range header {
		lower := strings.ToLower(name)
		if !strings.Contains(lower, "signature") && !strings.Contains(lower, "hmac") &&
			!strings.Contains(lower, "timestamp") && lower != "webhook-id" && lower != "svix-id" {
			continue
		}
		for _, value := range values {
			wrapping := "plain"
			switch {
			case strings.HasPrefix(value, "v1,"):
				wrapping = "v1,"
			case strings.Contains(value, "t=") && strings.Contains(value, "v1="):
				wrapping = "t=,v1="
			case strings.HasPrefix(value, "sha256="):
				wrapping = "sha256="
			}
			parts = append(parts, lower+" ("+strconv.Itoa(len(value))+" chars, "+wrapping+")")
		}
	}
	if len(parts) == 0 {
		return "no signature header"
	}
	return strings.Join(parts, "; ")
}
