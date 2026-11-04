package relay

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/fazer"
	"pointy/relay/internal/vouchers"
)

// fazerLookups is FazerCards behind the supplier interface, recording the
// orders it is asked about.
type fazerLookups struct {
	*fakeSupplier
	mu    sync.Mutex
	asked []string
}

func (f *fazerLookups) Key() string { return vouchers.SupplierFazer }

func (f *fazerLookups) Lookup(_ context.Context, _ vouchers.Ref, orderID string) (vouchers.Purchase, error) {
	f.mu.Lock()
	f.asked = append(f.asked, orderID)
	f.mu.Unlock()
	return vouchers.Purchase{OrderID: orderID, Status: vouchers.StatusPending}, nil
}

func TestTheFazerWebhookReadsHeldOrdersBack(t *testing.T) {
	h := newVoucherHarness(t)
	webhook := func(target, body string) int {
		t.Helper()
		return h.request(t, h.server, http.MethodPost, target, map[string]string{"Content-Type": "application/json"}, []byte(body)).Code
	}
	if code := webhook(fazerWebhookPath+"?token=x", `{}`); code != http.StatusNotFound {
		t.Fatalf("without FazerCards the webhook is not there: %d", code)
	}

	supplier := &fazerLookups{fakeSupplier: newFakeSupplier()}
	h.server.Vouchers.Suppliers[vouchers.SupplierFazer] = supplier
	h.server.Vouchers.Fazer = fazer.New(fazer.Config{BaseURL: "http://fazer.invalid", APIKey: "fc_test"})
	h.server.Vouchers.FazerWebhookToken = FazerWebhookToken("fc_test")
	spy := &awaitingSpy{FileStore: h.store}
	h.server.Store = spy
	held := h.now
	row := func(id, supplier, orderID string) control.VoucherPurchase {
		return control.VoucherPurchase{
			ID: id, Kind: control.VoucherKindCard, Quantity: 1, Supplier: supplier, SupplierOrderID: orderID,
			Status: control.VoucherPurchasePending, HeldSince: &held, CreatedAt: h.now, UpdatedAt: h.now,
		}
	}
	spy.setRows(
		row("vp-1", vouchers.SupplierFazer, "ord-1"),
		row("vp-2", vouchers.SupplierBNPlus, "451"),
		row("vp-3", vouchers.SupplierFazer, ""),
		row("vp-4", vouchers.SupplierFazer, "ord-4"),
	)

	if code := webhook(fazerWebhookPath+"?token=wrong", `{}`); code != http.StatusUnauthorized {
		t.Fatalf("a wrong token: %d", code)
	}
	if len(supplier.asked) != 0 {
		t.Fatalf("a wrong token asked FazerCards: %v", supplier.asked)
	}
	recorder := h.request(t, h.server, http.MethodPost, fazerWebhookPath+"?token="+FazerWebhookToken("fc_test"),
		map[string]string{"Content-Type": "application/json"},
		[]byte(`{"event":"order.completed","data":{"order":{"id":"ord-4"}}}`))
	if recorder.Code != http.StatusOK {
		t.Fatalf("delivery: %d %s", recorder.Code, recorder.Body)
	}
	// Only FazerCards' held purchases that have an order there, the one the
	// delivery names first; nothing in the payload is believed.
	if strings.Join(supplier.asked, ",") != "ord-4,ord-1" {
		t.Fatalf("asked about %v", supplier.asked)
	}
	var answer map[string]any
	_ = json.Unmarshal(recorder.Body.Bytes(), &answer)
	if answer["checked"] != float64(2) || answer["settled"] != float64(0) {
		t.Fatalf("answer %v", answer)
	}
}

func TestFazerWebhookSummary(t *testing.T) {
	for body, want := range map[string][2]string{
		`{"event":"order.completed","data":{"order":{"id":"ord-1"}}}`: {"order.completed", "ord-1"},
		`{"type":"order.refunded","order_id":"ord-2"}`:                {"order.refunded", "ord-2"},
		`{"event":"order.updated","order":{"id":"ord-3"}}`:            {"order.updated", "ord-3"},
		`{"event":"webhook.test"}`:                                    {"webhook.test", ""},
		`not json`:                                                    {"", ""},
	} {
		event, order := fazerWebhookSummary([]byte(body))
		if event != want[0] || order != want[1] {
			t.Errorf("%s: %q %q", body, event, order)
		}
	}
}

func TestTheOperatorPointsTheFazerWebhookHere(t *testing.T) {
	h := newVoucherHarness(t)
	var (
		mu     sync.Mutex
		stored map[string]any
	)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch {
		case r.URL.Path == "/api/v2/account/webhook" && r.Method == http.MethodGet:
			if stored == nil {
				_, _ = io.WriteString(w, `{"ok":true,"webhook":null}`)
				return
			}
			body, _ := json.Marshal(map[string]any{"ok": true, "webhook": map[string]any{
				"url": stored["url"], "secret": "whsec_never_shown", "enabled": stored["enabled"],
				"consecutive_failures": 0, "last_success_at": "2026-11-03T19:00:00.000Z",
				"last_failure_at": nil, "last_failure_reason": nil, "created_at": "x", "updated_at": "x",
			}})
			_, _ = w.Write(body)
		case r.URL.Path == "/api/v2/account/webhook" && r.Method == http.MethodPut:
			_ = json.NewDecoder(r.Body).Decode(&stored)
			_, _ = io.WriteString(w, `{"ok":true}`)
		case r.URL.Path == "/api/v2/account/webhook/test" && r.Method == http.MethodPost:
			_, _ = io.WriteString(w, `{"ok":true,"status":200,"error":null}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	h.server.Vouchers.Fazer = fazer.New(fazer.Config{BaseURL: server.URL, APIKey: "fc_test"})
	h.server.Vouchers.FazerWebhookToken = FazerWebhookToken("fc_test")

	status, body := h.admin(t, http.MethodGet, "/v1/vouchers/admin/fazer/webhook", "", nil)
	if status != http.StatusOK || body["set"] != false {
		t.Fatalf("unset: %d %v", status, body)
	}
	// The test relay is reached over plain http at relay.test: nothing
	// FazerCards could post to.
	if status, _ := h.admin(t, http.MethodPost, "/v1/vouchers/admin/fazer/webhook", "", nil); status != http.StatusConflict {
		t.Fatalf("no public address: %d", status)
	}

	h.server.Wallet.PublicURL = "https://relay.dftr.ly"
	status, body = h.admin(t, http.MethodPost, "/v1/vouchers/admin/fazer/webhook", "", nil)
	if status != http.StatusOK {
		t.Fatalf("register: %d %v", status, body)
	}
	mu.Lock()
	registered, _ := stored["url"].(string)
	enabled := stored["enabled"]
	mu.Unlock()
	if registered != "https://relay.dftr.ly"+fazerWebhookPath+"?token="+FazerWebhookToken("fc_test") || enabled != true {
		t.Fatalf("registered %q enabled %v", registered, enabled)
	}
	test, _ := body["test"].(map[string]any)
	if body["set"] != true || body["ours"] != true || body["enabled"] != true || test["delivered"] != true || test["status"] != float64(200) {
		t.Fatalf("after: %v", body)
	}
	raw, _ := json.Marshal(body)
	if strings.Contains(string(raw), FazerWebhookToken("fc_test")) || strings.Contains(string(raw), "whsec") {
		t.Fatalf("the token or the secret was shown: %s", raw)
	}
}

// fakeFazerSecret is FazerCards' webhook settings, answering the secret.
type fakeFazerSecret struct {
	mu     sync.Mutex
	secret string
	reads  int
}

func (f *fakeFazerSecret) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if r.URL.Path != "/api/v2/account/webhook" {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	f.reads++
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "webhook": map[string]any{
		"url": "https://my.dftr.ly" + fazerWebhookPath, "secret": f.secret, "enabled": true}})
}

func (f *fakeFazerSecret) set(secret string) {
	f.mu.Lock()
	f.secret = secret
	f.mu.Unlock()
}

// standardSignature signs a delivery the Standard Webhooks way (Svix):
// base64 HMAC-SHA256 of id.timestamp.body, with the secret's base64 key.
func standardSignature(t *testing.T, secret, id string, at time.Time, body string) map[string]string {
	t.Helper()
	key, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(secret, "whsec_"))
	if err != nil {
		t.Fatal(err)
	}
	stamp := strconv.FormatInt(at.Unix(), 10)
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(id + "." + stamp + "." + body))
	return map[string]string{
		"Content-Type":      "application/json",
		"Webhook-Id":        id,
		"Webhook-Timestamp": stamp,
		"Webhook-Signature": "v1," + base64.StdEncoding.EncodeToString(mac.Sum(nil)),
	}
}

func TestTheFazerWebhookChecksItsSignature(t *testing.T) {
	h := newVoucherHarness(t)
	fake := &fakeFazerSecret{secret: "whsec_" + base64.StdEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef"))}
	api := httptest.NewServer(http.HandlerFunc(fake.serve))
	t.Cleanup(api.Close)
	h.server.Vouchers.Suppliers[vouchers.SupplierFazer] = &fazerLookups{fakeSupplier: newFakeSupplier()}
	h.server.Vouchers.Fazer = fazer.New(fazer.Config{BaseURL: api.URL, APIKey: "fc_test"})
	h.server.Vouchers.FazerWebhookToken = FazerWebhookToken("fc_test")
	h.server.Vouchers.FazerSigning = &FazerSigning{}
	target := fazerWebhookPath + "?token=" + FazerWebhookToken("fc_test")
	const body = `{"event":"order.completed","data":{"order":{"id":"ord-4"}}}`
	deliver := func(headers map[string]string) int {
		t.Helper()
		return h.request(t, h.server, http.MethodPost, target, headers, []byte(body)).Code
	}
	plain := map[string]string{"Content-Type": "application/json"}

	// Until one has verified, an unsigned delivery is still taken: it is
	// only a nudge, and FazerCards' way of signing is not documented.
	if code := deliver(plain); code != http.StatusOK {
		t.Fatalf("an unsigned delivery before any verified: %d", code)
	}
	if code := deliver(standardSignature(t, fake.secret, "msg_1", h.now, body)); code != http.StatusOK {
		t.Fatalf("a signed delivery: %d", code)
	}
	// Now FazerCards is known to sign: anything that does not verify is not it.
	if code := deliver(plain); code != http.StatusUnauthorized {
		t.Fatalf("an unsigned delivery after a signed one: %d", code)
	}
	forged := standardSignature(t, "whsec_"+base64.StdEncoding.EncodeToString([]byte("not-the-secret-not-the-secret-!!")), "msg_2", h.now, body)
	if code := deliver(forged); code != http.StatusUnauthorized {
		t.Fatalf("a forged signature: %d", code)
	}
	if code := deliver(standardSignature(t, fake.secret, "msg_3", h.now.Add(-10*time.Minute), body)); code != http.StatusUnauthorized {
		t.Fatalf("a replayed delivery: %d", code)
	}
	// A secret rotated at FazerCards is read again.
	reads := fake.reads
	rotated := "whsec_" + base64.StdEncoding.EncodeToString([]byte("fedcba9876543210fedcba9876543210"))
	fake.set(rotated)
	later := h.now.Add(2 * time.Minute)
	h.server.Clock = testClock{now: later}
	if code := deliver(standardSignature(t, rotated, "msg_4", later, body)); code != http.StatusOK {
		t.Fatalf("a delivery signed with a rotated secret: %d", code)
	}
	if fake.reads != reads+1 {
		t.Fatalf("the secret was read %d times for the rotation", fake.reads-reads)
	}
}

func TestFazerSignatureSchemes(t *testing.T) {
	now := time.Date(2026, 11, 3, 20, 0, 0, 0, time.UTC)
	secret := "whsec_" + strings.Repeat("ab", 32)
	body := []byte(`{"event":"webhook.test"}`)
	hexOf := func(key, content string) string {
		mac := hmac.New(sha256.New, []byte(key))
		mac.Write([]byte(content))
		return hex.EncodeToString(mac.Sum(nil))
	}
	stamp := strconv.FormatInt(now.Unix(), 10)
	for name, header := range map[string]http.Header{
		"stripe":        {"X-Fazer-Signature": {"t=" + stamp + ",v1=" + hexOf(secret, stamp+"."+string(body))}},
		"plain":         {"X-Signature": {"sha256=" + hexOf(secret, string(body))}},
		"no prefix key": {"X-Webhook-Signature": {hexOf(strings.TrimPrefix(secret, "whsec_"), string(body))}},
	} {
		if scheme := verifyFazerSignature(secret, header, body, now); scheme == "" {
			t.Errorf("%s: did not verify", name)
		}
	}
	if scheme := verifyFazerSignature(secret, http.Header{"X-Signature": {hexOf("other", string(body))}}, body, now); scheme != "" {
		t.Errorf("a wrong key verified as %q", scheme)
	}
	if shape := fazerSignatureShape(http.Header{"X-Signature": {"sha256=" + hexOf(secret, string(body))}}); strings.Contains(shape, hexOf(secret, string(body))) {
		t.Errorf("the log shape shows the signature: %s", shape)
	}
}
