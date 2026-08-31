package relay

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"testing"
	"time"
)

func signBody(secret string, body []byte) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write(body)
	return hex.EncodeToString(mac.Sum(nil))
}

const samplePush = `{"event":"rate.created","data":{"currency":"USD","rate":"6.85","rate_type":"cash","bank_name":null,"created_at":"2026-08-31T14:30:00+02:00"}}`

func TestVerifyFulusWebhookAcceptsAGenuineSignature(t *testing.T) {
	body := []byte(samplePush)
	if !VerifyFulusWebhook("s3cret", body, signBody("s3cret", body)) {
		t.Fatal("expected a valid signature to verify")
	}
}

func TestVerifyFulusWebhookAcceptsThePrefixedForm(t *testing.T) {
	body := []byte(samplePush)
	if !VerifyFulusWebhook("s3cret", body, "sha256="+signBody("s3cret", body)) {
		t.Fatal("expected a sha256-prefixed signature to verify")
	}
}

func TestVerifyFulusWebhookRejectsATamperedBody(t *testing.T) {
	signature := signBody("s3cret", []byte(samplePush))
	tampered := []byte(`{"event":"rate.created","data":{"currency":"USD","rate":"9.99"}}`)
	if VerifyFulusWebhook("s3cret", tampered, signature) {
		t.Fatal("expected a tampered body to be rejected")
	}
}

func TestVerifyFulusWebhookRejectsWhenNoSecretIsConfigured(t *testing.T) {
	// "No secret" must never mean "any signature is fine": anyone who could
	// write here could reprice every shop in the fleet.
	body := []byte(samplePush)
	if VerifyFulusWebhook("", body, signBody("", body)) {
		t.Fatal("expected an unconfigured secret to reject every push")
	}
}

func TestVerifyFulusWebhookRejectsAnEmptySignature(t *testing.T) {
	if VerifyFulusWebhook("s3cret", []byte(samplePush), "") {
		t.Fatal("expected a missing signature to be rejected")
	}
}

func TestParseFulusWebhookMapsACashRate(t *testing.T) {
	rate, err := ParseFulusWebhook([]byte(samplePush))
	if err != nil {
		t.Fatal(err)
	}
	if rate.FromCode != "USD" || rate.ToCode != "LYD" {
		t.Fatalf("expected USD->LYD, got %s->%s", rate.FromCode, rate.ToCode)
	}
	if rate.Rate != "6.85" {
		t.Fatalf("expected the published rate verbatim, got %q", rate.Rate)
	}
	if rate.Instrument != "cash" || rate.BankCode != "" {
		t.Fatalf("expected a cash rate with no bank, got %q/%q", rate.Instrument, rate.BankCode)
	}
	want := time.Date(2026, 8, 31, 12, 30, 0, 0, time.UTC)
	if !rate.EffectiveAt.Equal(want) {
		t.Fatalf("expected %v, got %v", want, rate.EffectiveAt)
	}
}

func TestParseFulusWebhookMapsABankRateToItsBank(t *testing.T) {
	body := []byte(`{"event":"rate.created","data":{"currency":"USD","rate":"6.90","rate_type":"bank","bank_name":"NCB","created_at":"2026-08-31T14:30:00+02:00"}}`)
	rate, err := ParseFulusWebhook(body)
	if err != nil {
		t.Fatal(err)
	}
	if rate.Instrument != "bank" || rate.BankCode != "ncb" {
		t.Fatalf("expected bank/ncb, got %q/%q", rate.Instrument, rate.BankCode)
	}
}

func TestParseFulusWebhookKeepsTheRateAsText(t *testing.T) {
	// Passing a rate through float64 would round a published number before it
	// ever reached a shop, which is exactly what the frozen-rate rule forbids.
	body := []byte(`{"event":"rate.created","data":{"currency":"TRY","rate":"0.20416667","rate_type":"cash","created_at":"2026-08-31T14:30:00Z"}}`)
	rate, err := ParseFulusWebhook(body)
	if err != nil {
		t.Fatal(err)
	}
	if rate.Rate != "0.20416667" {
		t.Fatalf("expected the rate preserved exactly, got %q", rate.Rate)
	}
}

func TestParseFulusWebhookRejectsAnUnknownEvent(t *testing.T) {
	body := []byte(`{"event":"rate.deleted","data":{"currency":"USD","rate":"6.85"}}`)
	if _, err := ParseFulusWebhook(body); err == nil {
		t.Fatal("expected an unsupported event to be refused")
	}
}

func TestParseFulusWebhookRejectsTheQuoteCurrencyAsItsOwnRate(t *testing.T) {
	body := []byte(`{"event":"rate.created","data":{"currency":"LYD","rate":"1","rate_type":"cash","created_at":"2026-08-31T14:30:00Z"}}`)
	if _, err := ParseFulusWebhook(body); err == nil {
		t.Fatal("expected a LYD->LYD rate to be refused")
	}
}

func TestParseFulusWebhookRejectsAZeroRate(t *testing.T) {
	body := []byte(`{"event":"rate.created","data":{"currency":"USD","rate":"0","rate_type":"cash","created_at":"2026-08-31T14:30:00Z"}}`)
	if _, err := ParseFulusWebhook(body); err == nil {
		t.Fatal("expected a zero rate to be refused")
	}
}

func TestParseFulusWebhookRejectsAMissingTimestamp(t *testing.T) {
	// Without an instant a rate cannot be resolved on-or-before anything.
	body := []byte(`{"event":"rate.created","data":{"currency":"USD","rate":"6.85","rate_type":"cash"}}`)
	if _, err := ParseFulusWebhook(body); err == nil {
		t.Fatal("expected a rate with no timestamp to be refused")
	}
}

func TestFulusClientRefusesToPollWithoutTheFleetToken(t *testing.T) {
	client := NewFulusClient(FulusConfig{})
	if _, err := client.FetchCurrentRates(t.Context()); err != errFulusNotConfigured {
		t.Fatalf("expected errFulusNotConfigured, got %v", err)
	}
}
