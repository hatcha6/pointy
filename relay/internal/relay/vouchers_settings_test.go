package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// settingsClock moves only when told to: it times the store's versions and the
// cache's five seconds alike.
type settingsClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *settingsClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *settingsClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

// countingSettingsStore counts how often the current settings are read.
type countingSettingsStore struct {
	*control.FileStore
	mu    sync.Mutex
	reads int
}

func (s *countingSettingsStore) CurrentVoucherSettings(ctx context.Context) (control.VoucherSettingsRecord, error) {
	s.mu.Lock()
	s.reads++
	s.mu.Unlock()
	return s.FileStore.CurrentVoucherSettings(ctx)
}

func (s *countingSettingsStore) readCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.reads
}

type settingsHarness struct {
	server HTTPServer
	store  *countingSettingsStore
	clock  *settingsClock
}

func newSettingsHarness(t *testing.T) *settingsHarness {
	t.Helper()
	clock := &settingsClock{now: time.Date(2026, 10, 8, 9, 0, 0, 0, time.UTC)}
	file, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	store := &countingSettingsStore{FileStore: file}
	return &settingsHarness{
		store: store,
		clock: clock,
		server: HTTPServer{
			Store:                store,
			Hub:                  NewHub(),
			Logger:               slog.New(slog.NewTextHandler(io.Discard, nil)),
			Clock:                clock,
			AdminToken:           "admin-token",
			Vouchers:             VoucherConfig{TestMode: true},
			VoucherSettingsCache: &VoucherSettingsCache{},
		},
	}
}

func (h *settingsHarness) call(t *testing.T, method, target string, body []byte, authorized bool) (int, map[string]any) {
	t.Helper()
	request := httptest.NewRequest(method, "http://relay.test"+target, bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	if authorized {
		request.Header.Set("Authorization", "Bearer admin-token")
	}
	recorder := httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	var decoded map[string]any
	if raw := recorder.Body.Bytes(); len(raw) > 0 {
		if err := json.Unmarshal(raw, &decoded); err != nil {
			t.Fatalf("%s %s: not JSON (%d): %s", method, target, recorder.Code, raw)
		}
	}
	return recorder.Code, decoded
}

func (h *settingsHarness) admin(t *testing.T, method, target string, body string) (int, map[string]any) {
	t.Helper()
	return h.call(t, method, "/v1/vouchers/admin"+target, []byte(body), true)
}

func asMap(t *testing.T, value any) map[string]any {
	t.Helper()
	out, ok := value.(map[string]any)
	if !ok {
		t.Fatalf("%v is not an object", value)
	}
	return out
}

func asStrings(t *testing.T, value any) []string {
	t.Helper()
	list, ok := value.([]any)
	if !ok {
		t.Fatalf("%v is not a list", value)
	}
	out := make([]string, 0, len(list))
	for _, item := range list {
		out = append(out, item.(string))
	}
	return out
}

func TestVoucherSettingsAdminRouteNeedsTheAdminToken(t *testing.T) {
	h := newSettingsHarness(t)
	for _, route := range []struct{ method, target string }{
		{http.MethodGet, "/v1/vouchers/admin/settings"},
		{http.MethodPut, "/v1/vouchers/admin/settings"},
		{http.MethodGet, "/v1/vouchers/admin/settings/history"},
	} {
		if status, body := h.call(t, route.method, route.target, []byte(`{"usd_rate":"9.71"}`), false); status != http.StatusUnauthorized {
			t.Fatalf("%s %s without a token: %d %v", route.method, route.target, status, body)
		}
	}
	if _, err := h.store.FileStore.CurrentVoucherSettings(context.Background()); err == nil {
		t.Fatal("an unauthorized publish must store nothing")
	}
	// Other methods are not routes.
	if status, _ := h.admin(t, http.MethodDelete, "/settings", ``); status != http.StatusNotFound {
		t.Fatalf("DELETE: %d", status)
	}
	if status, _ := h.admin(t, http.MethodPost, "/settings/history", ``); status != http.StatusNotFound {
		t.Fatalf("POST history: %d", status)
	}
}

func TestVoucherSettingsAdminRouteLifecycle(t *testing.T) {
	h := newSettingsHarness(t)

	// Before the first version: the demo defaults, plainly not stored.
	status, body := h.admin(t, http.MethodGet, "/settings", ``)
	if status != http.StatusOK || body["stored"] != false || body["priced"] != false || body["record"] != nil {
		t.Fatalf("before the first version: %d %v", status, body)
	}
	defaults := asMap(t, body["settings"])
	if margin := asMap(t, defaults["margin"]); margin["round_step"] != "0.25" || margin["min_shop_margin"] != "0.10" ||
		margin["fixed_lyd"] != "0.50" || margin["shop_share_percent"] != "35" || defaults["funding_percent"] != "0" ||
		defaults["usd_rate_source"] != "fulus" {
		t.Fatalf("defaults: %v", defaults)
	}
	if _, set := defaults["usd_rate"]; set {
		t.Fatalf("there is no dollar rate by default: %v", defaults)
	}
	if got := asStrings(t, defaults["popular"]); len(got) != 20 || got[0] != "NE" {
		t.Fatalf("default popular: %v", got)
	}
	if got := asStrings(t, body["demo_defaults"]); len(got) != 8 {
		t.Fatalf("every knob is a demo default: %v", got)
	}
	status, body = h.admin(t, http.MethodGet, "/settings/history", ``)
	if status != http.StatusOK || len(body["history"].([]any)) != 0 {
		t.Fatalf("empty history: %d %v", status, body)
	}

	// The first version: only the rate is decided.
	h.clock.advance(time.Minute)
	status, body = h.admin(t, http.MethodPut, "/settings", `{"usd_rate":"9.71","note":"first rates","actor":"ops"}`)
	if status != http.StatusCreated || body["unchanged"] != false || body["stored"] != true || body["priced"] != true {
		t.Fatalf("publish: %d %v", status, body)
	}
	first := asMap(t, body["record"])
	if first["note"] != "first rates" || first["actor"] != "ops" || first["id"] == "" || len(first["sha256"].(string)) != 64 {
		t.Fatalf("record: %v", first)
	}
	if _, hasDocument := first["document"]; hasDocument {
		t.Fatalf("the record carries no document: %v", first)
	}
	settings := asMap(t, body["settings"])
	if settings["usd_rate"] != "9.71" || asMap(t, settings["margin"])["round_step"] != "0.25" {
		t.Fatalf("the published settings are written out in full: %v", settings)
	}
	if got := asStrings(t, body["demo_defaults"]); len(got) != 8 {
		t.Fatalf("a rate alone decides no other knob: %v", got)
	}

	// What the relay now reads is what was published.
	status, body = h.admin(t, http.MethodGet, "/settings", ``)
	if status != http.StatusOK || body["stored"] != true || asMap(t, body["record"])["id"] != first["id"] ||
		asMap(t, body["settings"])["usd_rate"] != "9.71" {
		t.Fatalf("read back: %d %v", status, body)
	}

	// The same settings again — however they are spelled — are not a new version.
	h.clock.advance(time.Minute)
	status, body = h.admin(t, http.MethodPut, "/settings", `{"note":"again","popular":[],"usd_rate":" 9.71 ","funding_percent":"0","retail_step":"0.25"}`)
	if status != http.StatusOK || body["unchanged"] != true || asMap(t, body["record"])["id"] != first["id"] {
		t.Fatalf("unchanged: %d %v", status, body)
	}
	if _, body = h.admin(t, http.MethodGet, "/settings/history", ``); len(body["history"].([]any)) != 1 {
		t.Fatalf("an unchanged publish adds no version: %v", body)
	}
	// Nor is a different spelling of the same numbers.
	status, body = h.admin(t, http.MethodPut, "/settings", `{"usd_rate":"9.710","funding_percent":"0.0","airtime":{"shop_markup_percent":"2.00"},"min_shop_margin":"0.1"}`)
	if status != http.StatusOK || body["unchanged"] != true {
		t.Fatalf("0.1 is 0.10: %d %v", status, body)
	}

	// A change is a new version, current at once.
	h.clock.advance(time.Minute)
	status, body = h.admin(t, http.MethodPut, "/settings",
		`{"usd_rate":"9.80","airtime":{"shop_markup_percent":"3"},"retail_step":"0.5","popular":["ml"," ne"],"note":"second"}`)
	if status != http.StatusCreated || body["unchanged"] != false {
		t.Fatalf("second publish: %d %v", status, body)
	}
	second := asMap(t, body["record"])
	if second["id"] == first["id"] {
		t.Fatal("a change is a new version")
	}
	decided := asStrings(t, body["demo_defaults"])
	for _, path := range decided {
		if path == "margin" || path == "popular" {
			t.Fatalf("%s was decided but is still reported as a demo default: %v", path, decided)
		}
	}
	if len(decided) != 6 {
		t.Fatalf("six knobs are still the demonstration values: %v", decided)
	}
	settings = asMap(t, body["settings"])
	if got := asStrings(t, settings["popular"]); len(got) != 2 || got[0] != "ML" || got[1] != "NE" {
		t.Fatalf("popular is normalized: %v", got)
	}
	if airtime := asMap(t, settings["airtime"]); airtime["shop_markup_percent"] != nil || asMap(t, airtime["margin"])["shop_share_percent"] != "45.454545" {
		t.Fatalf("a part of a block keeps the default of the rest: %v", airtime)
	}

	// The history: newest first, no documents.
	status, body = h.admin(t, http.MethodGet, "/settings/history", ``)
	history := body["history"].([]any)
	if status != http.StatusOK || len(history) != 2 || asMap(t, history[0])["id"] != second["id"] || asMap(t, history[1])["id"] != first["id"] {
		t.Fatalf("history: %d %v", status, body)
	}
	for _, entry := range history {
		if _, hasDocument := asMap(t, entry)["document"]; hasDocument {
			t.Fatalf("the history carries no documents: %v", entry)
		}
	}
	if _, body = h.admin(t, http.MethodGet, "/settings/history?limit=1", ``); len(body["history"].([]any)) != 1 {
		t.Fatalf("limit: %v", body)
	}

	// And the pricing the relay does with them follows.
	loaded, stored, err := h.server.currentVoucherSettings(context.Background(), h.store)
	if err != nil || !stored || loaded.USDRate != "9.80" || loaded.Margin.RoundStep != "0.5" || loaded.Airtime.Margin == nil {
		t.Fatalf("currentVoucherSettings: %+v stored=%v err=%v", loaded, stored, err)
	}
}

func TestVoucherSettingsAdminRouteRefusesWhatItCannotRead(t *testing.T) {
	h := newSettingsHarness(t)
	cases := []struct {
		name         string
		body         string
		status       int
		code         string
		wantProblems []string
	}{
		{"not JSON", `usd_rate=9.71`, http.StatusBadRequest, "invalid_request", nil},
		{"an array", `[]`, http.StatusBadRequest, "invalid_request", nil},
		{"null", `null`, http.StatusBadRequest, "invalid_request", nil},
		{"empty", ``, http.StatusBadRequest, "invalid_request", nil},
		{"a misspelt field", `{"retial_step":"0.5"}`, http.StatusUnprocessableEntity, "invalid_settings", nil},
		{"the catalog's envelope", `{"settings":{"usd_rate":"9.71"}}`, http.StatusUnprocessableEntity, "invalid_settings", nil},
		{"a number for a string", `{"usd_rate":9.71}`, http.StatusUnprocessableEntity, "invalid_settings", nil},
		{"a note that is not text", `{"note":5}`, http.StatusUnprocessableEntity, "invalid_settings", nil},
		{"an actor that is not text", `{"actor":["x"]}`, http.StatusUnprocessableEntity, "invalid_settings", nil},
		{
			"every problem at once",
			`{"usd_rate":"0","funding_percent":"-1","retail_step":"0.001","popular":["NE","QQ"],"airtime":{"shop_markup_percent":"x"}}`,
			http.StatusUnprocessableEntity, "invalid_settings",
			[]string{"usd_rate", "funding_percent", "retail_step", "popular[1]", "airtime.shop_markup_percent"},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			status, body := h.admin(t, http.MethodPut, "/settings", c.body)
			if status != c.status || body["code"] != c.code {
				t.Fatalf("got %d %v, want %d %s", status, body, c.status, c.code)
			}
			if c.wantProblems == nil {
				return
			}
			problems, _ := body["problems"].([]any)
			got := map[string]bool{}
			for _, problem := range problems {
				got[asMap(t, problem)["path"].(string)] = true
			}
			for _, path := range c.wantProblems {
				if !got[path] {
					t.Errorf("no problem reported for %s: %v", path, body["problems"])
				}
			}
			if len(problems) != len(c.wantProblems) {
				t.Errorf("want %d problems, got %v", len(c.wantProblems), body["problems"])
			}
		})
	}
	// Too big.
	huge := `{"note":"` + strings.Repeat("x", maxVoucherSettingsBytes) + `"}`
	if status, body := h.admin(t, http.MethodPut, "/settings", huge); status != http.StatusRequestEntityTooLarge {
		t.Fatalf("a huge body: %d %v", status, body)
	}
	// Nothing was stored by any of it.
	if _, err := h.store.FileStore.CurrentVoucherSettings(context.Background()); err == nil {
		t.Fatal("a refused publish must store nothing")
	}
	if _, body := h.admin(t, http.MethodGet, "/settings", ``); body["stored"] != false {
		t.Fatalf("nothing is stored: %v", body)
	}
}

func TestCurrentVoucherSettingsBeforeAnyIsPublished(t *testing.T) {
	h := newSettingsHarness(t)
	settings, stored, err := h.server.currentVoucherSettings(context.Background(), h.store)
	if err != nil || stored {
		t.Fatalf("stored=%v err=%v", stored, err)
	}
	if settings.Priced() || settings.Margin.FixedLYD != "0.50" || settings.Margin.RoundStep != "0.25" || len(settings.Popular) != 20 {
		t.Fatalf("the demo defaults, unpriced: %+v", settings)
	}
	if _, ok := settings.USDToLYD(nil); ok {
		t.Fatal("nothing converts without a rate")
	}
}

func TestCurrentVoucherSettingsIsCachedForFiveSeconds(t *testing.T) {
	h := newSettingsHarness(t)
	ctx := context.Background()
	publish := func(rate string) {
		t.Helper()
		raw, sum, err := vouchers.EncodeSettings(vouchers.Settings{USDRate: rate})
		if err != nil {
			t.Fatal(err)
		}
		h.clock.advance(time.Second)
		if _, err := h.store.FileStore.PublishVoucherSettings(ctx, control.VoucherSettingsRecord{SHA256: sum, Document: raw}); err != nil {
			t.Fatal(err)
		}
	}
	read := func() vouchers.Settings {
		t.Helper()
		settings, _, err := h.server.currentVoucherSettings(ctx, h.store)
		if err != nil {
			t.Fatal(err)
		}
		return settings
	}

	publish("9.71")
	if got := read(); got.USDRate != "9.71" || h.store.readCount() != 1 {
		t.Fatalf("first read: %+v reads=%d", got, h.store.readCount())
	}
	for i := 0; i < 5; i++ {
		read()
	}
	if h.store.readCount() != 1 {
		t.Fatalf("within five seconds the store is not asked again: %d reads", h.store.readCount())
	}

	// Another node publishes: this one notices when its five seconds are up.
	publish("9.99")
	if got := read(); got.USDRate != "9.71" {
		t.Fatalf("a node trusts what it knew until its time is up: %+v", got)
	}
	h.clock.advance(voucherSettingsTTL)
	if got := read(); got.USDRate != "9.99" || h.store.readCount() != 2 {
		t.Fatalf("after five seconds: %+v reads=%d", got, h.store.readCount())
	}

	// Publishing through this node's own admin route is seen at once.
	if status, body := h.admin(t, http.MethodPut, "/settings", `{"usd_rate":"10.25"}`); status != http.StatusCreated {
		t.Fatalf("publish: %d %v", status, body)
	}
	if got := read(); got.USDRate != "10.25" {
		t.Fatalf("a publish here is current here at once: %+v", got)
	}

	// The cache hands out copies: a caller changing its list changes nothing.
	mine := read()
	mine.Popular[0] = "ZZ"
	mine.USDRate = "1"
	if again := read(); again.Popular[0] != "NE" || again.USDRate != "10.25" {
		t.Fatalf("the cache must not share its settings: %+v", again)
	}

	// The same document published again (a rollback) is not parsed anew, but its
	// version is reported.
	publish("10.25")
	h.clock.advance(voucherSettingsTTL)
	loaded, err := h.server.loadVoucherSettings(ctx, h.store)
	if err != nil || loaded.settings.USDRate != "10.25" || !loaded.stored || loaded.record.ID == "" || len(loaded.record.Document) != 0 {
		t.Fatalf("rollback: %+v err=%v", loaded, err)
	}
}

func TestCurrentVoucherSettingsWithoutACacheReadsEveryTime(t *testing.T) {
	h := newSettingsHarness(t)
	h.server.VoucherSettingsCache = nil
	if status, body := h.admin(t, http.MethodPut, "/settings", `{"usd_rate":"9.71"}`); status != http.StatusCreated {
		t.Fatalf("publish: %d %v", status, body)
	}
	before := h.store.readCount()
	for i := 0; i < 3; i++ {
		if settings, stored, err := h.server.currentVoucherSettings(context.Background(), h.store); err != nil || !stored || settings.USDRate != "9.71" {
			t.Fatalf("read %d: %+v stored=%v err=%v", i, settings, stored, err)
		}
	}
	if got := h.store.readCount() - before; got != 3 {
		t.Fatalf("a nil cache asks the store every time: %d reads", got)
	}
}

func TestCurrentVoucherSettingsRefusesAStoredDocumentItCannotRead(t *testing.T) {
	h := newSettingsHarness(t)
	// Settings the typed reader rejects can only get here by a hand-edited store;
	// pricing must fail, never guess.
	if _, err := h.store.FileStore.PublishVoucherSettings(context.Background(), control.VoucherSettingsRecord{
		SHA256: "x", Document: json.RawMessage(`{"retail_step":"0"}`),
	}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := h.server.currentVoucherSettings(context.Background(), h.store); err == nil || !strings.Contains(err.Error(), "do not parse") {
		t.Fatalf("err = %v", err)
	}
	if status, body := h.admin(t, http.MethodGet, "/settings", ``); status != http.StatusInternalServerError {
		t.Fatalf("the admin view says so too: %d %v", status, body)
	}
}

func TestVoucherAdminPurchasesCanBeListedByKind(t *testing.T) {
	h := newSettingsHarness(t)
	ctx := context.Background()
	provisioned, err := h.store.FileStore.ProvisionInstallation(ctx, control.ProvisionInstallationRequest{ShopName: "Kinds Shop"})
	if err != nil {
		t.Fatal(err)
	}
	id := provisioned.Installation.ID
	if _, _, err := h.store.PostWalletEntry(ctx, control.WalletPosting{
		InstallationID: id, Kind: control.WalletEntryAdjustment, Amount: "100", IdempotencyKey: "fund",
	}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := h.store.TransferWalletFunds(ctx, control.WalletTransfer{
		InstallationID: id, From: control.WalletAccountMain, To: control.WalletAccountVouchers, Amount: "50", IdempotencyKey: "fill",
	}); err != nil {
		t.Fatal(err)
	}
	for key, kind := range map[string]string{"c": "", "a": control.VoucherKindAirtime, "b": control.VoucherKindBill} {
		if _, _, err := h.store.BeginVoucherPurchase(ctx, control.VoucherPurchase{
			InstallationID: id, IdempotencyKey: key, Kind: kind, ItemKey: "item-" + key, Quantity: 1,
			UnitPrice: "1.00", Supplier: "test", Target: "+223•••••456",
		}); err != nil {
			t.Fatal(err)
		}
	}
	list := func(query string) []any {
		t.Helper()
		status, body := h.admin(t, http.MethodGet, "/purchases"+query, ``)
		if status != http.StatusOK {
			t.Fatalf("%s: %d %v", query, status, body)
		}
		return body["purchases"].([]any)
	}
	if got := list(""); len(got) != 3 {
		t.Fatalf("all: %d", len(got))
	}
	for kind, want := range map[string]int{"card": 1, "airtime": 1, "bill": 1} {
		rows := list("?kind=" + kind)
		if len(rows) != want || asMap(t, rows[0])["kind"] != kind {
			t.Fatalf("kind=%s: %v", kind, rows)
		}
	}
	rows := list("?kind=airtime")
	if asMap(t, rows[0])["target"] != "+223•••••456" {
		t.Fatalf("the listing shows the masked target: %v", rows[0])
	}
	if status, body := h.admin(t, http.MethodGet, "/purchases?kind=gift", ``); status != http.StatusBadRequest {
		t.Fatalf("an unknown kind: %d %v", status, body)
	}
}

func TestVoucherSettingsPreviewPricesADraftWithoutPublishing(t *testing.T) {
	h := newSettingsHarness(t)
	draft := `{"usd_rate":"7","usd_rate_source":"manual","funding_percent":"2","airtime":{"service_fee_lyd":"0.5"}}`
	status, body := h.admin(t, http.MethodPost, "/settings/preview",
		`{"settings":`+draft+`,"samples":[{"kind":"card","cost":"10","currency":"USD"},{"kind":"airtime","cost":"20","currency":"LYD"},{"kind":"card","cost":"x","currency":"LYD"}]}`)
	if status != http.StatusOK || body["valid"] != true {
		t.Fatalf("preview %d %v", status, body)
	}
	settings, err := vouchers.ParseSettings([]byte(draft))
	if err != nil {
		t.Fatal(err)
	}
	samples := body["samples"].([]any)
	card := asMap(t, samples[0])
	costLYD, _ := settings.USDToLYD(big.NewRat(10, 1))
	want, _ := settings.ServicePrices("card", costLYD)
	if card["cost_lyd"] != "71.400" || card["shop_pays"] != control.FormatWalletAmount(want.ShopPays) || card["retail"] != control.FormatWalletAmount(want.Retail) {
		t.Fatalf("card %v want shop %s retail %s", card, want.ShopPays.FloatString(3), want.Retail.FloatString(3))
	}
	if airtime := asMap(t, samples[1]); airtime["fee"] != "0.500" {
		t.Fatalf("airtime fee %v", airtime)
	}
	if bad := asMap(t, samples[2]); bad["problem"] != "cost" {
		t.Fatalf("bad cost %v", bad)
	}
	if rate := asMap(t, body["rate"]); rate["source"] != "manual" || rate["rate"] != "7.0000" {
		t.Fatalf("rate %v", rate)
	}
	// A draft that does not read is said, not refused.
	if status, body := h.admin(t, http.MethodPost, "/settings/preview", `{"settings":{"retial_step":"1"}}`); status != http.StatusOK || body["valid"] != false {
		t.Fatalf("bad draft %d %v", status, body)
	}
	if _, err := h.store.FileStore.CurrentVoucherSettings(context.Background()); err == nil {
		t.Fatal("a preview must publish nothing")
	}
}
