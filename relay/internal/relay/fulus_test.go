package relay

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/control"
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

func TestParseFulusWebhookRefusesAWithdrawal(t *testing.T) {
	body := []byte(`{"event":"rate.deleted","data":{"currency":"USD","rate":"6.85"}}`)
	if _, err := ParseFulusWebhook(body); err == nil {
		t.Fatal("expected a withdrawal event to be refused")
	}
}

// livePush is one delivery copied verbatim from the relay's log on 2026-09-12,
// the day the feed was first subscribed. Their spec — English and Arabic both —
// documents this event as "rate.created". Their server sends "rate.new".
const livePush = `{"event":"rate.new","timestamp":"2026-09-12T12:50:08+02:00","data":{"currency":"USD","rate":"9.410000","rate_type":"cash","bank_name":null,"created_at":"2026-09-12T12:45:38+02:00"}}`

func TestParseFulusWebhookAcceptsTheEventNameTheirFeedActuallySends(t *testing.T) {
	rate, err := ParseFulusWebhook([]byte(livePush))
	if err != nil {
		t.Fatalf("the event name their live feed sends must parse: %v", err)
	}
	if rate.FromCode != "USD" || rate.ToCode != "LYD" {
		t.Fatalf("expected USD->LYD, got %s->%s", rate.FromCode, rate.ToCode)
	}
	if rate.Instrument != fulusInstrumentCash || rate.BankCode != "" {
		t.Fatalf("expected an unbanked cash rate, got %q/%q", rate.Instrument, rate.BankCode)
	}
	if rate.Rate != "9.410000" {
		t.Fatalf("expected the published digits kept, got %q", rate.Rate)
	}
	// data.created_at, never the top-level delivery timestamp.
	if got := rate.EffectiveAt.Format(time.RFC3339); got != "2026-09-12T10:45:38Z" {
		t.Fatalf("expected the publication instant, got %s", got)
	}
}

func TestParseFulusWebhookAcceptsAnEventNameTheDocsNeverMentioned(t *testing.T) {
	// The allow-list this replaced turned every unanticipated name into silent
	// total data loss. Anything that is not a withdrawal must get through.
	body := []byte(`{"event":"rate.published.v2","data":{"currency":"EUR","rate":"10.908121","rate_type":"cash","created_at":"2026-09-12T12:45:38+02:00"}}`)
	if _, err := ParseFulusWebhook(body); err != nil {
		t.Fatalf("an unrecognised publication event must still be stored: %v", err)
	}
}

func TestParseFulusWebhookCollapsesTheirRetriesOntoOneInstant(t *testing.T) {
	// They deliver each publication three times within two seconds, and every
	// attempt carries a different top-level timestamp. All three must land on
	// the same natural key, or one rate becomes three rows.
	deliveries := []string{
		`{"event":"rate.new","timestamp":"2026-09-12T12:50:08+02:00","data":{"currency":"USD","rate":"9.410000","rate_type":"cash","bank_name":null,"created_at":"2026-09-12T12:45:38+02:00"}}`,
		`{"event":"rate.new","timestamp":"2026-09-12T12:50:09+02:00","data":{"currency":"USD","rate":"9.410000","rate_type":"cash","bank_name":null,"created_at":"2026-09-12T12:45:38+02:00"}}`,
		`{"event":"rate.new","timestamp":"2026-09-12T12:50:10+02:00","data":{"currency":"USD","rate":"9.410000","rate_type":"cash","bank_name":null,"created_at":"2026-09-12T12:45:38+02:00"}}`,
	}
	var first control.ExchangeRate
	for i, body := range deliveries {
		rate, err := ParseFulusWebhook([]byte(body))
		if err != nil {
			t.Fatal(err)
		}
		if i == 0 {
			first = rate
			continue
		}
		if !rate.EffectiveAt.Equal(first.EffectiveAt) || rate.Rate != first.Rate {
			t.Fatalf("retry %d drifted: %s %s vs %s %s", i, rate.EffectiveAt, rate.Rate, first.EffectiveAt, first.Rate)
		}
	}
}

func TestParseFulusWebhookKeepsABankPushOnItsSlug(t *testing.T) {
	body := []byte(`{"event":"rate.new","data":{"currency":"USD","rate":"9.55","rate_type":"bank","bank_name":"ncb","created_at":"2026-09-12T12:45:38+02:00"}}`)
	rate, err := ParseFulusWebhook(body)
	if err != nil {
		t.Fatal(err)
	}
	if rate.Instrument != fulusInstrumentBank || rate.BankCode != "ncb" {
		t.Fatalf("expected bank/ncb, got %q/%q", rate.Instrument, rate.BankCode)
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
	if _, err := client.FetchCurrentRate(t.Context(), "USD"); err != errFulusNotConfigured {
		t.Fatalf("expected errFulusNotConfigured, got %v", err)
	}
}

func TestParseFulusWebhookAcceptsTheRESTTimestampField(t *testing.T) {
	// Their REST shapes stamp the instant in "timestamp" while the webhook doc
	// shows "created_at". A push carrying the REST spelling is the same rate.
	body := []byte(`{"event":"rate.created","data":{"currency":"USD","rate":"6.85","rate_type":"cash","timestamp":"2026-08-31T14:30:00+02:00"}}`)
	rate, err := ParseFulusWebhook(body)
	if err != nil {
		t.Fatal(err)
	}
	if rate.EffectiveAt.IsZero() || rate.Rate != "6.85" {
		t.Fatalf("expected a usable rate, got %+v", rate)
	}
}

func TestParseFulusWebhookAcceptsAnUpdatedRate(t *testing.T) {
	// A correction is a new rate at a new instant, so an update stores exactly
	// like a creation. A deletion still must not remove a rate a document froze.
	body := []byte(`{"event":"rate.updated","data":{"currency":"USD","rate":"6.90","rate_type":"cash","created_at":"2026-08-31T15:00:00Z"}}`)
	if _, err := ParseFulusWebhook(body); err != nil {
		t.Fatal(err)
	}
	deletion := []byte(`{"event":"rate.deleted","data":{"currency":"USD","rate":"6.90","created_at":"2026-08-31T15:00:00Z"}}`)
	if _, err := ParseFulusWebhook(deletion); err == nil {
		t.Fatal("expected a deletion event to be refused")
	}
}

func TestParseFulusWebhookNamesWhatWasUnusable(t *testing.T) {
	body := []byte(`{"event":"rate.created","data":{"currency":"USD","rate":"6.85","rate_type":"cash"}}`)
	_, err := ParseFulusWebhook(body)
	if err == nil {
		t.Fatal("expected a rejection")
	}
	if !strings.Contains(err.Error(), "no usable timestamp") {
		t.Fatalf("expected the reason to name the field, got %v", err)
	}
}

func TestWebhookBankRateKeysOnTheSlug(t *testing.T) {
	// Their webhook puts the slug in bank_name ("ncb"), while REST puts the
	// display name there and the slug in "bank". Both must key the same row.
	push := []byte(`{"event":"rate.created","data":{"currency":"USD","rate":"8.15","rate_type":"bank","bank_name":"ncb","created_at":"2026-08-31T14:23:45+02:00"}}`)
	fromWebhook, err := ParseFulusWebhook(push)
	if err != nil {
		t.Fatal(err)
	}
	rest := fulusRate{
		Currency:  "USD",
		Rate:      "8.15",
		RateType:  "bank",
		Bank:      "ncb",
		BankName:  "National Commercial Bank",
		Timestamp: "2026-08-31T14:23:45+02:00",
	}
	fromREST, ok := rest.toExchangeRate()
	if !ok {
		t.Fatal("expected the REST row to convert")
	}
	if fromWebhook.BankCode != "ncb" || fromREST.BankCode != "ncb" {
		t.Fatalf(
			"both paths must key on the slug, got webhook=%q rest=%q",
			fromWebhook.BankCode, fromREST.BankCode,
		)
	}
	if fromWebhook.EffectiveAt != fromREST.EffectiveAt {
		t.Fatal("the same publication must land on the same instant")
	}
}

func fulusWebhookTestServer(t *testing.T) HTTPServer {
	t.Helper()
	store, _ := provisionRelayInstallation(t)
	return HTTPServer{
		Store:  store,
		Hub:    NewHub(),
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		Fulus:  FulusConfig{WebhookSecret: "s3cret"},
	}
}

func postFulusWebhook(t *testing.T, server HTTPServer, body string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(
		http.MethodPost, "http://relay.test/v1/exchange-rates/webhook", strings.NewReader(body),
	)
	request.Header.Set("X-Webhook-Signature", signBody("s3cret", []byte(body)))
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	return recorder
}

func TestHTTPFulusWebhookStoresTheirLivePush(t *testing.T) {
	recorder := postFulusWebhook(t, fulusWebhookTestServer(t), livePush)
	if recorder.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d: %s", recorder.Code, recorder.Body.String())
	}
}

func TestHTTPFulusWebhookAnswers200ToAPushItCannotUse(t *testing.T) {
	// A 4xx is read as "this endpoint is broken": the provider retries three
	// times in under two seconds and counts every one against the endpoint,
	// and endpoints that keep failing get disabled. A push we cannot parse is
	// permanent, not transient — it is acknowledged, logged, and dropped.
	body := `{"event":"rate.new","data":{"currency":"USD","rate":"0","rate_type":"cash","created_at":"2026-09-12T12:45:38+02:00"}}`
	recorder := postFulusWebhook(t, fulusWebhookTestServer(t), body)
	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200 for an unusable push, got %d", recorder.Code)
	}
	if !strings.Contains(recorder.Body.String(), "ignored") {
		t.Fatalf("expected the reason in the body, got %s", recorder.Body.String())
	}
}

func TestHTTPFulusWebhookStillRefusesABadSignature(t *testing.T) {
	// Acknowledging unusable payloads must not soften the auth boundary: an
	// unauthenticated writer here could reprice every shop in the fleet.
	request := httptest.NewRequest(
		http.MethodPost, "http://relay.test/v1/exchange-rates/webhook", strings.NewReader(livePush),
	)
	request.Header.Set("X-Webhook-Signature", "sha256=deadbeef")
	recorder := httptest.NewRecorder()
	fulusWebhookTestServer(t).ServeHTTP(recorder, request)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for a bad signature, got %d", recorder.Code)
	}
}
