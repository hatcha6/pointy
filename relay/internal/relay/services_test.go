package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/ratelimit"
	"pointy/relay/internal/reloadly"
	"pointy/relay/internal/services"
	"pointy/relay/internal/vouchers"
)

// testServiceNames names the few operators and billers these tests sell, the way
// the relay's table does, without depending on the table.
type testServiceNames struct{}

func (testServiceNames) Operator(name, iso, _ string) (string, bool) {
	if iso+"|"+name == "ML|Orange Mali" {
		return "أورنج مالي", true
	}
	return "", false
}

func (testServiceNames) Biller(name, iso string) (string, bool) {
	switch iso + "|" + name {
	case "SN|Woyofal Senegal":
		return "ووياوفال السنغال", true
	case "SN|Facture Sen-Elec Senegal":
		return "فاتورة الكهرباء السنغال", true
	case "NG|Ikeja Electricity Prepaid":
		return "كهرباء إيكيجا (مسبقة الدفع)", true
	case "ML|Canal+ Mali":
		return "كانال بلس مالي", true
	}
	return "", false
}

func (testServiceNames) Plan(string) (string, bool) { return "", false }

// fakeServiceExecutor stands in for Reloadly behind services.Executor: it records
// every order, answers from hooks, and can be read back by order id.
type fakeServiceExecutor struct {
	mu        sync.Mutex
	airtime   []services.AirtimeOrder
	bills     []services.BillOrder
	onAirtime func(services.AirtimeOrder) (services.Result, error)
	onBill    func(services.BillOrder) (services.Result, error)
	lookups   map[string]services.Result
	lookupErr error
	found     map[string][]services.Result
	findErr   error
	lookupN   int
	findN     int
	nextID    int
}

func newFakeServiceExecutor() *fakeServiceExecutor {
	return &fakeServiceExecutor{lookups: map[string]services.Result{}, found: map[string][]services.Result{}, nextID: 7000}
}

func (f *fakeServiceExecutor) next() string {
	f.nextID++
	return strconv.Itoa(f.nextID)
}

func (f *fakeServiceExecutor) Airtime(_ context.Context, order services.AirtimeOrder) (services.Result, error) {
	f.mu.Lock()
	f.airtime = append(f.airtime, order)
	hook := f.onAirtime
	f.mu.Unlock()
	if hook != nil {
		result, err := hook(order)
		f.remember(services.KindAirtime, result)
		return result, err
	}
	id := f.next()
	result := services.Result{
		OrderID: id, Status: vouchers.StatusSucceeded, CostUSD: "9.45298",
		Receipt: map[string]string{
			services.ReceiptTransactionID:     id,
			services.ReceiptOperator:          order.OperatorName,
			services.ReceiptPhone:             order.Phone.E164(),
			services.ReceiptDeliveredAmount:   order.Receive.Amount,
			services.ReceiptDeliveredCurrency: order.Receive.Currency,
			services.ReceiptOperatorReference: "7297929551:OrderConfirmed",
			services.ReceiptOrderAmount:       services.FormatAmount(order.Amount),
			services.ReceiptOrderCurrency:     order.Currency,
		},
	}
	f.remember(services.KindAirtime, result)
	return result, nil
}

func (f *fakeServiceExecutor) Bill(_ context.Context, order services.BillOrder) (services.Result, error) {
	f.mu.Lock()
	f.bills = append(f.bills, order)
	hook := f.onBill
	f.mu.Unlock()
	if hook != nil {
		result, err := hook(order)
		f.remember(services.KindBill, result)
		return result, err
	}
	id := f.next()
	result := services.Result{
		OrderID: id, Status: vouchers.StatusSucceeded, CostUSD: "8.00",
		Receipt: map[string]string{
			services.ReceiptTransactionID:   id,
			services.ReceiptBiller:          order.BillerName,
			services.ReceiptAccount:         order.Account,
			services.ReceiptAmount:          order.Receive.Amount,
			services.ReceiptCurrency:        order.Receive.Currency,
			services.ReceiptToken:           "2737-6032-5315-7183-0856",
			services.ReceiptUnits:           "10.7 kWh",
			services.ReceiptBillerReference: "T_QKTBYLMGPA",
		},
	}
	f.remember(services.KindBill, result)
	return result, nil
}

func (f *fakeServiceExecutor) remember(kind string, result services.Result) {
	if result.OrderID == "" {
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lookups[kind+":"+result.OrderID] = result
}

func (f *fakeServiceExecutor) Lookup(_ context.Context, kind, orderID string) (services.Result, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lookupN++
	if f.lookupErr != nil {
		return services.Result{}, f.lookupErr
	}
	result, ok := f.lookups[kind+":"+orderID]
	if !ok {
		return services.Result{}, fmt.Errorf("no %s order %s", kind, orderID)
	}
	return result, nil
}

func (f *fakeServiceExecutor) FindByClientRef(_ context.Context, kind, clientRef string, _, _ time.Time) ([]services.Result, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.findN++
	if f.findErr != nil {
		return nil, f.findErr
	}
	return append([]services.Result(nil), f.found[kind+":"+clientRef]...), nil
}

func (f *fakeServiceExecutor) airtimeCalls() []services.AirtimeOrder {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]services.AirtimeOrder(nil), f.airtime...)
}

func (f *fakeServiceExecutor) billCalls() []services.BillOrder {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]services.BillOrder(nil), f.bills...)
}

func (f *fakeServiceExecutor) calls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.airtime) + len(f.bills)
}

type serviceLogs struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *serviceLogs) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *serviceLogs) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// servicesStore is what the harness needs of a store: the file store everywhere,
// and a real PostgreSQL when the opt-in database is configured.
type servicesStore interface {
	control.InstallationStore
	control.VoucherStore
	PostWalletEntry(ctx context.Context, posting control.WalletPosting) (control.WalletEntry, bool, error)
	GetWalletAccount(ctx context.Context, installationID, account string) (control.Wallet, error)
	ProvisionInstallation(ctx context.Context, request control.ProvisionInstallationRequest) (control.ProvisionedInstallation, error)
}

type servicesHarness struct {
	t       *testing.T
	server  HTTPServer
	store   servicesStore
	clock   *settingsClock
	exec    *fakeServiceExecutor
	service *services.Service
	logs    *serviceLogs
	shop    control.ProvisionedInstallation
	funded  int
}

// newServicesHarness is a relay that sells top-ups and bills from a fake Reloadly,
// out of the fixture directory, with a shop that has no money yet.
func newServicesHarness(t *testing.T, edit ...func(*services.Config)) *servicesHarness {
	t.Helper()
	clock := &settingsClock{now: time.Date(2026, 10, 8, 10, 0, 0, 0, time.UTC)}
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	return newServicesHarnessOn(t, store, clock, edit...)
}

// newServicesHarnessOn is the same relay over a given store.
func newServicesHarnessOn(t *testing.T, store servicesStore, clock *settingsClock, edit ...func(*services.Config)) *servicesHarness {
	t.Helper()
	exec := newFakeServiceExecutor()
	cfg := services.Config{
		Source:         services.FixtureSource{},
		Reloadly:       exec,
		Namer:          testServiceNames{},
		Now:            clock.Now,
		RequestTimeout: 5 * time.Second,
		SettleWait:     time.Second,
		TargetKey:      []byte("test-target-key"),
	}
	for _, change := range edit {
		change(&cfg)
	}
	service := services.New(cfg)
	logs := &serviceLogs{}
	h := &servicesHarness{
		t: t, store: store, clock: clock, exec: exec, service: service, logs: logs,
		server: HTTPServer{
			Store:      store,
			Hub:        NewHub(),
			Logger:     slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug})),
			Clock:      clock,
			AdminToken: "admin-token",
			// Reloadly is configured, so the voucher balance exists.
			Vouchers:     VoucherConfig{TestMode: true, RequestTimeout: 5 * time.Second},
			Services:     service,
			VoucherCache: &VoucherCatalogCache{},
		},
	}
	provisioned, err := store.ProvisionInstallation(context.Background(), control.ProvisionInstallationRequest{ShopName: "Top-up Shop"})
	if err != nil {
		t.Fatal(err)
	}
	h.shop = provisioned
	return h
}

func (h *servicesHarness) serve(method, target string, headers map[string]string, body []byte) *httptest.ResponseRecorder {
	h.t.Helper()
	request := httptest.NewRequest(method, "http://relay.test"+target, bytes.NewReader(body))
	for key, value := range headers {
		request.Header.Set(key, value)
	}
	recorder := httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	return recorder
}

func svcDecode(t *testing.T, recorder *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var decoded map[string]any
	if raw := recorder.Body.Bytes(); len(raw) > 0 {
		if err := json.Unmarshal(raw, &decoded); err != nil {
			t.Fatalf("response is not JSON (%d): %s", recorder.Code, raw)
		}
	}
	return decoded
}

// call is a shop's request, with its installation token.
func (h *servicesHarness) call(method, target string, body any) (int, map[string]any) {
	h.t.Helper()
	var raw []byte
	if body != nil {
		switch typed := body.(type) {
		case string:
			raw = []byte(typed)
		default:
			raw, _ = json.Marshal(body)
		}
	}
	recorder := h.serve(method, target, map[string]string{AccessTokenHeader: h.shop.AccessToken, "Content-Type": "application/json"}, raw)
	return recorder.Code, svcDecode(h.t, recorder)
}

func (h *servicesHarness) admin(method, target string, body string) (int, map[string]any) {
	h.t.Helper()
	recorder := h.serve(method, target, map[string]string{"Authorization": "Bearer admin-token", "Content-Type": "application/json"}, []byte(body))
	return recorder.Code, svcDecode(h.t, recorder)
}

// publishSettings makes the settings document current.
func (h *servicesHarness) publishSettings(document string) {
	h.t.Helper()
	h.clock.advance(time.Second)
	status, body := h.admin(http.MethodPut, "/v1/vouchers/admin/settings", document)
	if status != http.StatusCreated && status != http.StatusOK {
		h.t.Fatalf("publishing settings: %d %v", status, body)
	}
}

// fund puts dinars on the shop's voucher balance.
func (h *servicesHarness) fund(amount string) {
	h.t.Helper()
	h.funded++
	sequence := h.shop.Installation.ID + "-" + strconv.Itoa(h.funded)
	if _, _, err := h.store.PostWalletEntry(context.Background(), control.WalletPosting{
		InstallationID: h.shop.Installation.ID, Kind: control.WalletEntryAdjustment, Amount: "500",
		IdempotencyKey: "fund-" + sequence,
	}); err != nil {
		h.t.Fatal(err)
	}
	status, body := h.call(http.MethodPost, "/v1/wallet/vouchers/allocations", map[string]any{
		"amount": amount, "idempotency_key": "fill-" + sequence, "requested_by": "owner",
	})
	if status != http.StatusCreated {
		h.t.Fatalf("allocation: %d %v", status, body)
	}
}

func (h *servicesHarness) balance() string {
	h.t.Helper()
	wallet, err := h.store.GetWalletAccount(context.Background(), h.shop.Installation.ID, control.WalletAccountVouchers)
	if err != nil {
		h.t.Fatal(err)
	}
	return wallet.Balance
}

func (h *servicesHarness) purchase(key string) control.VoucherPurchase {
	h.t.Helper()
	purchase, found, err := h.store.FindVoucherPurchaseByKey(context.Background(), h.shop.Installation.ID, key)
	if err != nil || !found {
		h.t.Fatalf("purchase %s: found=%v err=%v", key, found, err)
	}
	return purchase
}

// ready is a harness with a published rate and a funded shop.
func readyServicesHarness(t *testing.T, edit ...func(*services.Config)) *servicesHarness {
	t.Helper()
	h := newServicesHarness(t, edit...)
	h.publishSettings(`{"usd_rate": "9.71"}`)
	h.fund("400")
	return h
}

func svcAirtimeBody(key string) map[string]any {
	return map[string]any{
		"kind": "airtime", "operator_id": 289, "country": "ML", "phone": "+223 70 12 34 56",
		"amount": "5000", "amount_currency": "XOF", "idempotency_key": key, "requested_by": "cashier",
	}
}

func svcBillBody(key string) map[string]any {
	return map[string]any{
		"kind": "bill", "biller_id": 26, "country": "SN", "account": "14500000001",
		"amount": "5000", "amount_currency": "XOF", "idempotency_key": key, "requested_by": "cashier",
	}
}

func svcObject(t *testing.T, value any) map[string]any {
	t.Helper()
	object, ok := value.(map[string]any)
	if !ok {
		t.Fatalf("%v is not an object", value)
	}
	return object
}

// ---- directory ----

func TestTheDirectoryIsServedWithAnETag(t *testing.T) {
	h := readyServicesHarness(t)
	recorder := h.serve(http.MethodGet, "/v1/services/directory", map[string]string{AccessTokenHeader: h.shop.AccessToken}, nil)
	if recorder.Code != http.StatusOK {
		t.Fatalf("directory: %d %s", recorder.Code, recorder.Body)
	}
	etag := recorder.Header().Get("ETag")
	body := svcDecode(t, recorder)
	if etag != `"`+body["version"].(string)+`"` || len(body["version"].(string)) != 16 {
		t.Fatalf("etag %s version %v", etag, body["version"])
	}
	if body["configured"] != true || body["priced"] != true || body["currency"] != "LYD" || body["test_mode"] != false {
		t.Fatalf("header: %v", body)
	}
	countries := body["countries"].([]any)
	if len(countries) < 20 {
		t.Fatalf("countries: %d", len(countries))
	}
	first := countries[0].(map[string]any)
	if first["code"] != "NE" || first["popular"] != float64(1) {
		t.Fatalf("popular first: %v", first)
	}
	if recorder.Header().Get("Cache-Control") != "private, no-cache" || recorder.Header().Get("Content-Type") != "application/json" {
		t.Fatalf("headers: %v", recorder.Header())
	}

	// Unchanged: 304 with nothing.
	again := h.serve(http.MethodGet, "/v1/services/directory", map[string]string{AccessTokenHeader: h.shop.AccessToken, "If-None-Match": etag}, nil)
	if again.Code != http.StatusNotModified || again.Body.Len() != 0 {
		t.Fatalf("an unchanged directory is 304: %d", again.Code)
	}
	weak := h.serve(http.MethodGet, "/v1/services/directory", map[string]string{AccessTokenHeader: h.shop.AccessToken, "If-None-Match": `"other", W/` + etag}, nil)
	if weak.Code != http.StatusNotModified {
		t.Fatalf("a list of tags: %d", weak.Code)
	}

	// A new rate is a new version.
	h.publishSettings(`{"usd_rate": "9.80"}`)
	changed := h.serve(http.MethodGet, "/v1/services/directory", map[string]string{AccessTokenHeader: h.shop.AccessToken, "If-None-Match": etag}, nil)
	if changed.Code != http.StatusOK || changed.Header().Get("ETag") == etag {
		t.Fatalf("a new rate must move the version: %d %s", changed.Code, changed.Header().Get("ETag"))
	}
	// So does an order mode.
	h.publishSettings(`{"usd_rate": "9.80", "airtime": {"order_mode": "local"}}`)
	local := h.serve(http.MethodGet, "/v1/services/directory", map[string]string{AccessTokenHeader: h.shop.AccessToken}, nil)
	if local.Header().Get("ETag") == changed.Header().Get("ETag") {
		t.Fatal("the order mode moves prices, so the version")
	}
	if unauthorised := h.serve(http.MethodGet, "/v1/services/directory", nil, nil); unauthorised.Code != http.StatusUnauthorized {
		t.Fatalf("a shop must authenticate: %d", unauthorised.Code)
	}
}

func TestTheDirectoryCarriesTheCatalogsFlags(t *testing.T) {
	h := readyServicesHarness(t)
	status, image := h.adminImage(testPNG(t, 10))
	if status != http.StatusCreated && status != http.StatusOK {
		t.Fatalf("flag upload: %d %v", status, image)
	}
	ref := image["ref"].(string)
	document := `{"categories": [{"key": "c", "name": "ك", "sort": 1}], "countries": [{"code": "ML", "flag": "` + ref + `"}],
	  "brands": [{"key": "b", "name": "ب", "category": "c", "logo": {}, "items": [{"key": "i", "face_value": "10", "face_currency": "LYD",
	    "price": "9.70", "retail_price": "10.00", "supplier": {"key": "test", "id": "1"}}]}]}`
	before := h.serve(http.MethodGet, "/v1/services/directory", map[string]string{AccessTokenHeader: h.shop.AccessToken}, nil)
	if status, body := h.admin(http.MethodPut, "/v1/vouchers/admin/catalog", `{"document": `+document+`, "actor": "ops"}`); status != http.StatusCreated {
		t.Fatalf("catalog: %d %v", status, body)
	}
	after := h.serve(http.MethodGet, "/v1/services/directory", map[string]string{AccessTokenHeader: h.shop.AccessToken}, nil)
	if after.Header().Get("ETag") == before.Header().Get("ETag") {
		t.Fatal("a flag in the catalog is part of the directory")
	}
	for _, entry := range svcDecode(t, after)["countries"].([]any) {
		country := entry.(map[string]any)
		switch country["code"] {
		case "ML":
			if country["flag"] != ref {
				t.Fatalf("mali's flag: %v", country["flag"])
			}
		case "NE":
			if country["flag"] != "" {
				t.Fatalf("a country the catalog has no flag for: %v", country["flag"])
			}
		}
	}
}

func (h *servicesHarness) adminImage(data []byte) (int, map[string]any) {
	h.t.Helper()
	recorder := h.serve(http.MethodPost, "/v1/vouchers/admin/images", map[string]string{"Authorization": "Bearer admin-token", "Content-Type": "image/png"}, data)
	return recorder.Code, svcDecode(h.t, recorder)
}

func TestAnUnconfiguredRelayHasAnEmptyDirectoryAndSellsNothing(t *testing.T) {
	h := readyServicesHarness(t)
	h.server.Services = nil
	status, body := h.call(http.MethodGet, "/v1/services/directory", nil)
	if status != http.StatusOK || body["configured"] != false || len(body["countries"].([]any)) != 0 {
		t.Fatalf("directory: %d %v", status, body)
	}
	for _, route := range []struct {
		method, target string
		body           any
	}{
		{http.MethodPost, "/v1/services/quote", map[string]any{"kind": "airtime", "operator_id": 289, "amount": "5000", "amount_currency": "XOF"}},
		{http.MethodPost, "/v1/services/detect", map[string]any{"country": "ML", "phone": "70123456"}},
		{http.MethodPost, "/v1/services/orders", svcAirtimeBody("nope")},
	} {
		status, body := h.call(route.method, route.target, route.body)
		if status != http.StatusServiceUnavailable || body["code"] != "services_unconfigured" {
			t.Fatalf("%s: %d %v", route.target, status, body)
		}
	}
}

// ---- detection and quotes ----

func TestDetectionTakesTheNumberInTheBodyNeverTheURL(t *testing.T) {
	h := readyServicesHarness(t)
	status, body := h.call(http.MethodPost, "/v1/services/detect", map[string]any{"country": "ML", "phone": "70123456"})
	if status != http.StatusOK {
		t.Fatalf("detect: %d %v", status, body)
	}
	phone := svcObject(t, body["phone"])
	operator := svcObject(t, body["operator"])
	if phone["e164"] != "+22370123456" || phone["national"] != "70123456" || phone["country"] != "ML" ||
		operator["id"] == nil || len(operator["amounts"].([]any)) == 0 {
		t.Fatalf("detection: %v", body)
	}
	// There is no GET variant, with or without the number.
	for _, target := range []string{"/v1/services/detect", "/v1/services/detect?country=ML&phone=70123456"} {
		recorder := h.serve(http.MethodGet, target, map[string]string{AccessTokenHeader: h.shop.AccessToken}, nil)
		if recorder.Code != http.StatusMethodNotAllowed || recorder.Header().Get("Allow") != http.MethodPost {
			t.Fatalf("GET %s: %d %v", target, recorder.Code, recorder.Header())
		}
	}
	if status, body := h.call(http.MethodPost, "/v1/services/detect", map[string]any{"country": "ML", "phone": "12"}); status != http.StatusUnprocessableEntity || body["code"] != "invalid_phone" {
		t.Fatalf("a bad number: %d %v", status, body)
	}
	if status, body := h.call(http.MethodPost, "/v1/services/detect", map[string]any{"country": "SD", "phone": "912345678"}); status != http.StatusNotFound || body["code"] != "operator_not_detected" {
		t.Fatalf("a country with no operator: %d %v", status, body)
	}
	if status, body := h.call(http.MethodPost, "/v1/services/detect", map[string]any{"country": "ML"}); status != http.StatusBadRequest || body["code"] != "invalid_request" {
		t.Fatalf("no number: %d %v", status, body)
	}
	if status, _ := h.call(http.MethodPost, "/v1/services/detect", "not json"); status != http.StatusBadRequest {
		t.Fatalf("not json: %d", status)
	}
	if logged := h.logs.String(); strings.Contains(logged, "70123456") {
		t.Fatalf("the number must not reach the log:\n%s", logged)
	}
}

type fakeServiceDetector struct {
	id  int64
	err error
	got []string
	mu  sync.Mutex
}

func (d *fakeServiceDetector) Detect(_ context.Context, country string, phone services.Phone) (int64, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.got = append(d.got, country+":"+phone.Digits())
	return d.id, d.err
}

func TestDetectionAsksTheSupplierAndRefusesWhatItCannotSell(t *testing.T) {
	detector := &fakeServiceDetector{id: 289}
	h := readyServicesHarness(t, func(cfg *services.Config) { cfg.Detector = detector })
	status, body := h.call(http.MethodPost, "/v1/services/detect", map[string]any{"country": "ML", "phone": "+223 70 12 34 56"})
	if status != http.StatusOK || svcObject(t, body["operator"])["id"] != float64(289) || svcObject(t, body["operator"])["name"] != "أورنج مالي" {
		t.Fatalf("detect: %d %v", status, body)
	}
	if len(detector.got) != 1 || detector.got[0] != "ML:22370123456" {
		t.Fatalf("the supplier is asked country code plus national digits: %v", detector.got)
	}
	// An operator the directory does not sell is not an answer.
	detector.id = 424242
	if status, body := h.call(http.MethodPost, "/v1/services/detect", map[string]any{"country": "ML", "phone": "70123456"}); status != http.StatusNotFound || body["code"] != "operator_not_detected" {
		t.Fatalf("unknown operator: %d %v", status, body)
	}
	detector.err = services.ErrNotDetected
	if status, body := h.call(http.MethodPost, "/v1/services/detect", map[string]any{"country": "ML", "phone": "70123456"}); status != http.StatusNotFound || body["code"] != "operator_not_detected" {
		t.Fatalf("not detected: %d %v", status, body)
	}
	detector.err = fmt.Errorf("reloadly is down: recipient 22370123456 unreachable")
	status, body = h.call(http.MethodPost, "/v1/services/detect", map[string]any{"country": "ML", "phone": "70123456"})
	if status != http.StatusServiceUnavailable || body["code"] != "services_unavailable" {
		t.Fatalf("supplier down: %d %v", status, body)
	}
	if logged := h.logs.String(); strings.Contains(logged, "22370123456") || strings.Contains(logged, "70123456") {
		t.Fatalf("the supplier's sentence echoed the number; the log must not:\n%s", logged)
	}
}

func TestQuotesAreExactAndRefuseWithTheDocumentedCodes(t *testing.T) {
	h := readyServicesHarness(t)
	status, body := h.call(http.MethodPost, "/v1/services/quote", map[string]any{"kind": "airtime", "operator_id": 289, "amount": "5000", "amount_currency": "XOF"})
	if status != http.StatusOK {
		t.Fatalf("quote: %d %v", status, body)
	}
	quote := svcObject(t, body["quote"])
	if quote["kind"] != "airtime" || quote["name"] != "شحن مباشر · أورنج مالي · 5,000 فرنك أفريقي" || quote["approximate"] != false ||
		svcObject(t, quote["receive"])["amount"] != "5000" || svcObject(t, quote["receive"])["currency"] != "XOF" ||
		quote["unit_price"] == "" || quote["retail_price"] == "" {
		t.Fatalf("quote: %v", quote)
	}
	// A number is as good as a string for an amount.
	if status, again := h.call(http.MethodPost, "/v1/services/quote", `{"kind":"airtime","operator_id":289,"amount":5000,"amount_currency":"XOF"}`); status != http.StatusOK ||
		svcObject(t, again["quote"])["unit_price"] != quote["unit_price"] {
		t.Fatalf("a numeric amount: %d %v", status, again)
	}
	for _, c := range []struct {
		name   string
		body   any
		status int
		code   string
	}{
		{"out of range", map[string]any{"kind": "airtime", "operator_id": 289, "amount": "100", "amount_currency": "XOF"}, 422, "amount_out_of_range"},
		{"invalid amount", map[string]any{"kind": "airtime", "operator_id": 289, "amount": "lots", "amount_currency": "XOF"}, 422, "invalid_amount"},
		{"unknown operator", map[string]any{"kind": "airtime", "operator_id": 1, "amount": "5000", "amount_currency": "XOF"}, 404, "unknown_operator"},
		{"unknown biller", map[string]any{"kind": "bill", "biller_id": 99999, "amount": "5000", "amount_currency": "XOF"}, 404, "unknown_biller"},
		{"not offered", map[string]any{"kind": "bill", "biller_id": 27, "amount": "123", "amount_currency": "XOF"}, 422, "amount_not_offered"},
	} {
		status, body := h.call(http.MethodPost, "/v1/services/quote", c.body)
		if status != c.status || body["code"] != c.code {
			t.Fatalf("%s: %d %v", c.name, status, body)
		}
		if c.code == "amount_out_of_range" && (body["min"] != "1967" || body["max"] != "32800") {
			t.Fatalf("the limits: %v", body)
		}
	}
	// No rate: unavailable, with the reason.
	unpriced := newServicesHarness(t)
	status, body = unpriced.call(http.MethodPost, "/v1/services/quote", map[string]any{"kind": "airtime", "operator_id": 289, "amount": "5000", "amount_currency": "XOF"})
	if status != http.StatusConflict || body["code"] != "service_unavailable" || body["reason"] != "rate_unset" {
		t.Fatalf("no rate: %d %v", status, body)
	}
}

// ---- orders ----

func TestAnAirtimeOrderIsChargedBeforeItIsPlacedAndPlacedOnce(t *testing.T) {
	h := readyServicesHarness(t)
	_, quoted := h.call(http.MethodPost, "/v1/services/quote", map[string]any{"kind": "airtime", "operator_id": 289, "amount": "5000", "amount_currency": "XOF"})
	unit := svcObject(t, quoted["quote"])["unit_price"].(string)

	order := svcAirtimeBody("sale-1")
	order["max_unit_price"] = unit
	balanceBefore := h.balance()
	status, body := h.call(http.MethodPost, "/v1/services/orders", order)
	if status != http.StatusCreated {
		t.Fatalf("order: %d %v", status, body)
	}
	purchase := svcObject(t, body["purchase"])
	receipt := svcObject(t, purchase["receipt"])
	if purchase["kind"] != "airtime" || purchase["status"] != "succeeded" || purchase["target"] != "+223•••••456" ||
		purchase["item"] != "airtime:289:5000:XOF" || purchase["brand"] != "airtime" || purchase["quantity"] != float64(1) ||
		purchase["name"] != "شحن مباشر · أورنج مالي · 5,000 فرنك أفريقي" || purchase["held"] != false ||
		purchase["receipt_pending"] != false || purchase["codes_pending"] != false || len(purchase["codes"].([]any)) != 0 {
		t.Fatalf("purchase: %v", purchase)
	}
	if receipt["transaction_id"] != purchase["id"] || receipt["operator"] != "Orange Mali" || receipt["phone"] != "+22370123456" ||
		receipt["delivered_amount"] != "5000" || receipt["delivered_currency"] != "XOF" || receipt["operator_reference"] != "7297929551" ||
		receipt["order_currency"] != "USD" {
		t.Fatalf("receipt: %v", receipt)
	}
	if body["replayed"] != false {
		t.Fatalf("replayed: %v", body["replayed"])
	}
	// The shop was charged the quoted price, and the supplier called once, with the
	// purchase's own id, in dollars.
	charged, _ := new(big.Rat).SetString(unit)
	before, _ := new(big.Rat).SetString(balanceBefore)
	after, _ := new(big.Rat).SetString(h.balance())
	if new(big.Rat).Sub(before, after).Cmp(charged) != 0 {
		t.Fatalf("balance %s -> %s, charged %s", balanceBefore, h.balance(), unit)
	}
	calls := h.exec.airtimeCalls()
	if len(calls) != 1 || calls[0].ClientRef != purchase["id"] || calls[0].Currency != "USD" || calls[0].Local ||
		calls[0].Amount.Cmp(big.NewRat(19901, 2000)) != 0 || calls[0].Phone.E164() != "+22370123456" {
		t.Fatalf("supplier calls: %+v", calls)
	}
	row := h.purchase("sale-1")
	if row.Supplier != "reloadly" || row.SupplierOrderID != "airtime:7001" || row.SupplierCost != "9.45298" || row.SupplierCurrency != "USD" ||
		row.Kind != "airtime" || row.Target != "+223•••••456" || row.TestMode || row.Quantity != 1 || row.SupplierRef != "289" {
		t.Fatalf("ledger row: %+v", row)
	}
	var details map[string]any
	if err := json.Unmarshal(row.Details, &details); err != nil || details["order_mode"] != "usd" || details["order_currency"] != "USD" ||
		details["operator_id"] != float64(289) || details["amount"] != "5000" {
		t.Fatalf("details: %s %v", row.Details, err)
	}
	if strings.Contains(string(row.Details), "70123456") {
		t.Fatalf("the full number is not kept: %s", row.Details)
	}
}

func TestAReplayedOrderIsNotPlacedTwiceAndItsReceiptIsReadBack(t *testing.T) {
	h := readyServicesHarness(t)
	status, first := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("sale-2"))
	if status != http.StatusCreated {
		t.Fatalf("order: %d %v", status, first)
	}
	balance := h.balance()
	lookups := h.exec.lookupN

	status, replay := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("sale-2"))
	if status != http.StatusOK || replay["replayed"] != true || h.exec.calls() != 1 || h.balance() != balance {
		t.Fatalf("replay: %d %v calls=%d", status, replay, h.exec.calls())
	}
	again := svcObject(t, replay["purchase"])
	if again["id"] != svcObject(t, first["purchase"])["id"] || svcObject(t, again["receipt"])["transaction_id"] != again["id"] ||
		again["receipt_pending"] != false || h.exec.lookupN != lookups+1 {
		t.Fatalf("the receipt is re-read from the supplier: %v (lookups %d -> %d)", again, lookups, h.exec.lookupN)
	}

	// Both read paths answer any kind of purchase.
	for _, target := range []string{"/v1/vouchers/purchases/sale-2", "/v1/services/orders/sale-2"} {
		status, read := h.call(http.MethodGet, target, nil)
		purchase := svcObject(t, read["purchase"])
		if status != http.StatusOK || purchase["kind"] != "airtime" || purchase["status"] != "succeeded" ||
			svcObject(t, purchase["receipt"])["delivered_amount"] != "5000" {
			t.Fatalf("GET %s: %d %v", target, status, read)
		}
	}
	if status, _ := h.call(http.MethodGet, "/v1/services/orders/unknown", nil); status != http.StatusNotFound {
		t.Fatalf("an unknown key: %d", status)
	}

	// The supplier cannot be read right now: the order stands, the receipt is to come.
	h.exec.lookupErr = fmt.Errorf("reloadly is slow")
	status, slow := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("sale-2"))
	pending := svcObject(t, slow["purchase"])
	if status != http.StatusAccepted || pending["status"] != "succeeded" || pending["receipt_pending"] != true || len(svcObject(t, pending["receipt"])) != 0 {
		t.Fatalf("receipt pending: %d %v", status, slow)
	}
	status, read := h.call(http.MethodGet, "/v1/vouchers/purchases/sale-2", nil)
	if status != http.StatusOK || svcObject(t, read["purchase"])["receipt_pending"] != true {
		t.Fatalf("read while unreadable: %d %v", status, read)
	}
}

func TestAKeyIsNeverReusedForAnotherThing(t *testing.T) {
	h := readyServicesHarness(t)
	if status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("sale-3")); status != http.StatusCreated {
		t.Fatalf("order: %d %v", status, body)
	}
	cases := map[string]map[string]any{
		"another amount": func() map[string]any { b := svcAirtimeBody("sale-3"); b["amount"] = "6000"; return b }(),
		"another operator": func() map[string]any {
			b := svcAirtimeBody("sale-3")
			b["operator_id"] = 631
			return b
		}(),
		"another kind": svcBillBody("sale-3"),
		"another number": func() map[string]any {
			b := svcAirtimeBody("sale-3")
			b["phone"] = "70 99 99 99"
			return b
		}(),
	}
	for name, body := range cases {
		status, answer := h.call(http.MethodPost, "/v1/services/orders", body)
		if status != http.StatusConflict || answer["code"] != "idempotency_key_reused" {
			t.Fatalf("%s: %d %v", name, status, answer)
		}
	}
	if h.exec.calls() != 1 {
		t.Fatalf("a refused request reaches nobody: %d calls", h.exec.calls())
	}
	// The same thing written another way is the same thing.
	same := svcAirtimeBody("sale-3")
	same["phone"] = "0022370123456"
	same["amount"] = 5000
	if status, answer := h.call(http.MethodPost, "/v1/services/orders", same); status != http.StatusOK || answer["replayed"] != true {
		t.Fatalf("the same order, written differently: %d %v", status, answer)
	}
	// A card purchase cannot take the key of a top-up either.
	status, answer := h.call(http.MethodPost, "/v1/vouchers/purchases", map[string]any{"item": "x", "quantity": 1, "idempotency_key": "sale-3"})
	if status != http.StatusConflict || answer["code"] != "idempotency_key_reused" {
		t.Fatalf("a card on a top-up's key: %d %v", status, answer)
	}
}

func TestAnOrderThatWouldOverdrawIsRefusedWithoutAClaim(t *testing.T) {
	h := newServicesHarness(t)
	h.publishSettings(`{"usd_rate": "9.71"}`)
	h.fund("10")
	status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("poor-1"))
	if status != http.StatusPaymentRequired || body["code"] != "insufficient_balance" || body["balance"] == nil || body["amount"] == nil {
		t.Fatalf("overdraw: %d %v", status, body)
	}
	if h.exec.calls() != 0 {
		t.Fatal("nothing may be bought on money the shop does not have")
	}
	if _, found, _ := h.store.FindVoucherPurchaseByKey(context.Background(), h.shop.Installation.ID, "poor-1"); found {
		t.Fatal("no claim without the money")
	}
}

func TestAPriceThatRoseIsRefusedAndTheShopRequotes(t *testing.T) {
	h := readyServicesHarness(t)
	_, quoted := h.call(http.MethodPost, "/v1/services/quote", map[string]any{"kind": "airtime", "operator_id": 289, "amount": "5000", "amount_currency": "XOF"})
	unit := svcObject(t, quoted["quote"])["unit_price"].(string)
	// The rate moves up after the till quoted.
	h.publishSettings(`{"usd_rate": "10.50"}`)
	order := svcAirtimeBody("sale-4")
	order["max_unit_price"] = unit
	status, body := h.call(http.MethodPost, "/v1/services/orders", order)
	if status != http.StatusConflict || body["code"] != "price_changed" {
		t.Fatalf("price changed: %d %v", status, body)
	}
	current := body["unit_price"].(string)
	if current == unit || len(current) < 4 || current[len(current)-3] != '.' {
		t.Fatalf("the price now: %v (was %s)", body["unit_price"], unit)
	}
	if h.exec.calls() != 0 {
		t.Fatal("a refused price reaches nobody")
	}
	// Quoted again, it is charged.
	order["max_unit_price"] = current
	if status, body := h.call(http.MethodPost, "/v1/services/orders", order); status != http.StatusCreated {
		t.Fatalf("requoted: %d %v", status, body)
	}
}

func TestNothingIsSoldWithoutADollarRate(t *testing.T) {
	h := newServicesHarness(t)
	h.fund("100")
	status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("unpriced"))
	if status != http.StatusServiceUnavailable || body["code"] != "services_unpriced" {
		t.Fatalf("unpriced: %d %v", status, body)
	}
	if h.exec.calls() != 0 {
		t.Fatal("never priced by guess")
	}
}

func TestOrderValidationRefusals(t *testing.T) {
	h := readyServicesHarness(t)
	set := func(base map[string]any, key string, value any) map[string]any {
		out := map[string]any{}
		for k, v := range base {
			out[k] = v
		}
		if value == nil {
			delete(out, key)
		} else {
			out[key] = value
		}
		return out
	}
	cases := []struct {
		name   string
		body   map[string]any
		status int
		code   string
	}{
		{"no key", set(svcAirtimeBody("k"), "idempotency_key", nil), 400, "invalid_request"},
		{"a long key", set(svcAirtimeBody("k"), "idempotency_key", strings.Repeat("k", 101)), 400, "invalid_request"},
		{"no kind", set(svcAirtimeBody("k1"), "kind", nil), 400, "invalid_request"},
		{"no currency", set(svcAirtimeBody("k2"), "amount_currency", nil), 400, "invalid_request"},
		{"a bad max price", set(svcAirtimeBody("k3"), "max_unit_price", "free"), 400, "invalid_request"},
		{"a bad phone", set(svcAirtimeBody("k4"), "phone", "123"), 422, "invalid_phone"},
		{"another country's number", set(svcAirtimeBody("k5"), "phone", "+234 803 123 4567"), 422, "invalid_phone"},
		{"an unknown operator", set(svcAirtimeBody("k6"), "operator_id", 99999), 404, "unknown_operator"},
		{"a bad amount", set(svcAirtimeBody("k7"), "amount", "-5"), 422, "invalid_amount"},
		{"an amount out of range", set(svcAirtimeBody("k8"), "amount", "50"), 422, "amount_out_of_range"},
		{"a bad account", set(svcBillBody("k9"), "account", "1"), 422, "invalid_account"},
		{"an unknown biller", set(svcBillBody("k10"), "biller_id", 12345), 404, "unknown_biller"},
		{"a missing invoice", set(set(svcBillBody("k11"), "biller_id", 23), "amount", "5000"), 422, "invoice_required"},
		{"a bad invoice", set(set(set(svcBillBody("k12"), "biller_id", 23), "invoice_id", "no way!"), "amount", "5000"), 422, "invalid_invoice"},
	}
	for _, c := range cases {
		status, body := h.call(http.MethodPost, "/v1/services/orders", c.body)
		if status != c.status || body["code"] != c.code {
			t.Fatalf("%s: %d %v", c.name, status, body)
		}
	}
	if h.exec.calls() != 0 {
		t.Fatal("a refused order reaches nobody")
	}
	if status, _ := h.call(http.MethodPost, "/v1/services/orders", "not json"); status != http.StatusBadRequest {
		t.Fatalf("not json: %d", status)
	}
	big := `{"kind":"airtime","idempotency_key":"x","phone":"` + strings.Repeat("7", 20000) + `"}`
	if status, _ := h.call(http.MethodPost, "/v1/services/orders", big); status != http.StatusBadRequest {
		t.Fatalf("a huge body: %d", status)
	}
}

func TestADefiniteRefusalIsRefundedAtOnce(t *testing.T) {
	for _, c := range []struct {
		name string
		err  error
		code string
	}{
		{"the company's account has no money", &vouchers.Failure{Code: vouchers.FailureCredit, Detail: "insufficient balance", Definite: true}, "unavailable"},
		{"the credentials are refused", &vouchers.Failure{Code: vouchers.FailureUnauthorized, Detail: "unauthorized", Definite: true}, "unavailable"},
		{"the operator is off", &vouchers.Failure{Code: vouchers.FailureOutOfStock, Detail: "operator unavailable", Definite: true}, "out_of_stock"},
		{"the supplier cannot be reached", &vouchers.Failure{Code: vouchers.FailureUnreachable, Detail: "connection refused", Definite: true}, "unavailable"},
		{"the supplier refuses the number", &vouchers.Failure{Code: vouchers.FailureRefused, Detail: "invalid recipient", Definite: true}, "refused"},
	} {
		t.Run(c.name, func(t *testing.T) {
			h := readyServicesHarness(t)
			h.exec.onAirtime = func(services.AirtimeOrder) (services.Result, error) { return services.Result{}, c.err }
			before := h.balance()
			status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("refused-1"))
			purchase := svcObject(t, body["purchase"])
			if status != http.StatusBadGateway || body["code"] != c.code || purchase["status"] != "failed" || purchase["held"] != false ||
				purchase["kind"] != "airtime" || h.balance() != before {
				t.Fatalf("%d %v balance %s -> %s", status, body, before, h.balance())
			}
			// Asked again, it is the same refusal and nothing is placed again.
			status, replay := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("refused-1"))
			if status != http.StatusBadGateway || replay["replayed"] != true || h.exec.calls() != 1 {
				t.Fatalf("replay of a refusal: %d %v calls=%d", status, replay, h.exec.calls())
			}
		})
	}
}

func TestAnUncertainFailureHoldsThePriceUntilTheSupplierSays(t *testing.T) {
	h := readyServicesHarness(t)
	h.exec.onAirtime = func(services.AirtimeOrder) (services.Result, error) {
		return services.Result{}, &vouchers.Failure{Code: vouchers.FailureUnknown, Detail: "timeout after sending recipient 22370123456"}
	}
	before := h.balance()
	status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("held-1"))
	purchase := svcObject(t, body["purchase"])
	if status != http.StatusAccepted || purchase["status"] != "pending" || purchase["held"] != true || h.balance() == before {
		t.Fatalf("held: %d %v", status, body)
	}
	if strings.Contains(fmt.Sprint(body), "22370123456") || strings.Contains(h.logs.String(), "22370123456") {
		t.Fatal("a number echoed by the supplier must not be kept or logged")
	}
	held := h.balance()
	id := purchase["id"].(string)

	reconciler := &VoucherReconciler{Server: h.server, Store: h.store}
	// Not in Reloadly's records yet: not believed straight away.
	reconciler.Round(context.Background())
	if h.balance() != held || h.exec.findN == 0 {
		t.Fatalf("absence is not believed at once: balance %s, finds %d", h.balance(), h.exec.findN)
	}
	// Found with the purchase's own id: the order was placed, the charge stands.
	h.exec.found["airtime:"+id] = []services.Result{{OrderID: "8123", Status: vouchers.StatusSucceeded, CostUSD: "9.45298",
		Receipt: map[string]string{services.ReceiptTransactionID: "8123", services.ReceiptDeliveredAmount: "5000"}}}
	h.exec.lookups["airtime:8123"] = h.exec.found["airtime:"+id][0]
	reconciler.Round(context.Background())
	settled := h.purchase("held-1")
	if settled.Status != "succeeded" || settled.HeldSince != nil || settled.SupplierOrderID != "airtime:8123" || settled.SupplierCost != "9.45298" || h.balance() != held {
		t.Fatalf("found: %+v balance %s", settled, h.balance())
	}
	status, replay := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("held-1"))
	if status != http.StatusOK || svcObject(t, svcObject(t, replay["purchase"])["receipt"])["transaction_id"] != svcObject(t, replay["purchase"])["id"] {
		t.Fatalf("replay after the reconciler: %d %v", status, replay)
	}
}

func TestAnOrderTheSupplierNeverSawIsRefundedAfterTheWindow(t *testing.T) {
	// A top-up answers its final state on the call, or errors: one Reloadly does
	// not list a quarter of an hour later never happened. (A bill is waited for a
	// day: TestABillTheSupplierDoesNotListIsWaitedForADay.)
	h := readyServicesHarness(t)
	h.exec.onAirtime = func(services.AirtimeOrder) (services.Result, error) {
		return services.Result{}, &vouchers.Failure{Code: vouchers.FailureUnknown, Detail: "connection reset"}
	}
	before := h.balance()
	status, _ := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("lost-1"))
	if status != http.StatusAccepted {
		t.Fatalf("held: %d", status)
	}
	reconciler := &VoucherReconciler{Server: h.server, Store: h.store}
	reconciler.Round(context.Background())
	if purchase := h.purchase("lost-1"); purchase.Status != "pending" {
		t.Fatalf("not yet: %+v", purchase)
	}
	h.clock.advance(20 * time.Minute)
	reconciler.Round(context.Background())
	purchase := h.purchase("lost-1")
	if purchase.Status != "failed" || h.balance() != before || purchase.HeldSince != nil {
		t.Fatalf("absent after the window: refunded: %+v balance %s want %s", purchase, h.balance(), before)
	}
	// The history could not be read: nobody is refunded by guess.
	h2 := readyServicesHarness(t)
	h2.exec.onBill = func(services.BillOrder) (services.Result, error) {
		return services.Result{}, &vouchers.Failure{Code: vouchers.FailureUnknown, Detail: "connection reset"}
	}
	h2.exec.findErr = fmt.Errorf("reloadly is down")
	h2.call(http.MethodPost, "/v1/services/orders", svcBillBody("lost-2"))
	h2.clock.advance(72 * time.Hour)
	(&VoucherReconciler{Server: h2.server, Store: h2.store}).Round(context.Background())
	if purchase := h2.purchase("lost-2"); purchase.Status != "pending" || purchase.HeldSince == nil {
		t.Fatalf("unreadable stays held: %+v", purchase)
	}
	if !strings.Contains(h2.logs.String(), "still unresolved") {
		t.Fatalf("after two days it asks for a person:\n%s", h2.logs.String())
	}
}

func TestABillAcceptedButNotFinishedStaysHeldUntilReloadlySaysSo(t *testing.T) {
	h := readyServicesHarness(t)
	h.exec.onBill = func(order services.BillOrder) (services.Result, error) {
		return services.Result{OrderID: "36", Status: vouchers.StatusPending, Message: "The payment is being processed"}, nil
	}
	before := h.balance()
	status, body := h.call(http.MethodPost, "/v1/services/orders", svcBillBody("bill-1"))
	purchase := svcObject(t, body["purchase"])
	if status != http.StatusAccepted || purchase["status"] != "pending" || purchase["held"] != true || purchase["kind"] != "bill" ||
		purchase["receipt_pending"] != true || h.balance() == before {
		t.Fatalf("accepted: %d %v", status, body)
	}
	row := h.purchase("bill-1")
	if row.SupplierOrderID != "bill:36" || row.HeldSince == nil {
		t.Fatalf("the order Reloadly named is kept: %+v", row)
	}
	held := h.balance()
	reconciler := &VoucherReconciler{Server: h.server, Store: h.store}

	// Still processing a day later: not refunded.
	h.clock.advance(23 * time.Hour)
	reconciler.Round(context.Background())
	if h.exec.lookups["bill:36"].Status != vouchers.StatusPending {
		h.exec.lookups["bill:36"] = services.Result{OrderID: "36", Status: vouchers.StatusPending}
	}
	reconciler.Round(context.Background())
	if purchase := h.purchase("bill-1"); purchase.Status != "pending" || h.balance() != held {
		t.Fatalf("a bill may stay processing for a day: %+v balance %s", purchase, h.balance())
	}
	// Reloadly finishes it: paid, with the token.
	h.exec.lookups["bill:36"] = services.Result{OrderID: "36", Status: vouchers.StatusSucceeded, CostUSD: "7.9",
		Receipt: map[string]string{"transaction_id": "36", "token": "2737-6032-5315-7183-0856", "units": "10.7 kWh"}}
	reconciler.Round(context.Background())
	if purchase := h.purchase("bill-1"); purchase.Status != "succeeded" || purchase.SupplierCost != "7.9" || h.balance() != held {
		t.Fatalf("paid: %+v", purchase)
	}
	status, read := h.call(http.MethodGet, "/v1/services/orders/bill-1", nil)
	receipt := svcObject(t, svcObject(t, read["purchase"])["receipt"])
	if status != http.StatusOK || receipt["token"] != "2737-6032-5315-7183-0856" || receipt["units"] != "10.7 kWh" {
		t.Fatalf("the token is read back: %d %v", status, read)
	}

	// Another bill that Reloadly refunds: the price comes back.
	h2 := readyServicesHarness(t)
	h2.exec.onBill = h.exec.onBill
	start := h2.balance()
	h2.call(http.MethodPost, "/v1/services/orders", svcBillBody("bill-2"))
	h2.exec.lookups["bill:36"] = services.Result{OrderID: "36", Status: vouchers.StatusFailed, Message: "UNABLE_TO_PROCESS_PAYMENT"}
	(&VoucherReconciler{Server: h2.server, Store: h2.store}).Round(context.Background())
	refunded := h2.purchase("bill-2")
	if refunded.Status != "failed" || h2.balance() != start || refunded.HeldSince != nil {
		t.Fatalf("refunded by Reloadly: %+v balance %s want %s", refunded, h2.balance(), start)
	}
}

func TestABillOrderCarriesTheInvoiceAndThePlan(t *testing.T) {
	h := readyServicesHarness(t)
	// A biller that needs the invoice number.
	order := map[string]any{
		"kind": "bill", "biller_id": 23, "country": "SN", "account": "123456789", "invoice_id": "2024-118833",
		"amount": "5000", "amount_currency": "XOF", "idempotency_key": "inv-1", "requested_by": "cashier",
	}
	status, body := h.call(http.MethodPost, "/v1/services/orders", order)
	if status != http.StatusCreated {
		t.Fatalf("invoice: %d %v", status, body)
	}
	calls := h.exec.billCalls()
	if len(calls) != 1 || calls[0].InvoiceID != "2024-118833" || calls[0].Account != "123456789" || !calls[0].Local || calls[0].Currency != "XOF" ||
		calls[0].Amount.Cmp(big.NewRat(5000, 1)) != 0 {
		t.Fatalf("an invoice is paid exactly, in the local currency: %+v", calls)
	}
	row := h.purchase("inv-1")
	if row.Target != "••••••789" || strings.Contains(string(row.Details), "118833") || !strings.Contains(string(row.Details), `"has_invoice":true`) {
		t.Fatalf("masked target and details: %q %s", row.Target, row.Details)
	}

	// A fixed plan.
	_, directory := h.call(http.MethodGet, "/v1/services/directory", nil)
	var plan map[string]any
	for _, entry := range directory["countries"].([]any) {
		country := entry.(map[string]any)
		if country["code"] == "ML" {
			for _, biller := range country["bills"].(map[string]any)["billers"].([]any) {
				if biller.(map[string]any)["id"] == float64(27) {
					plan = biller.(map[string]any)["plans"].([]any)[0].(map[string]any)
				}
			}
		}
	}
	if plan == nil {
		t.Fatal("canal+ has plans")
	}
	status, body = h.call(http.MethodPost, "/v1/services/orders", map[string]any{
		"kind": "bill", "biller_id": 27, "country": "ML", "account": "12345678", "amount": plan["amount"], "amount_currency": "XOF",
		"amount_id": plan["id"], "idempotency_key": "plan-1", "max_unit_price": plan["unit_price"],
	})
	if status != http.StatusCreated {
		t.Fatalf("plan: %d %v", status, body)
	}
	if calls := h.exec.billCalls(); calls[len(calls)-1].AmountID != int64(plan["id"].(float64)) {
		t.Fatalf("the plan's id goes to the supplier: %+v", calls)
	}
}

func TestTwoRequestsWithOneKeyPlaceOneOrder(t *testing.T) {
	h := readyServicesHarness(t)
	entered := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	h.exec.onAirtime = func(order services.AirtimeOrder) (services.Result, error) {
		once.Do(func() { close(entered) })
		<-release
		return services.Result{OrderID: "9100", Status: vouchers.StatusSucceeded, CostUSD: "9.4",
			Receipt: map[string]string{"transaction_id": "9100", "delivered_amount": "5000", "delivered_currency": "XOF"}}, nil
	}
	type answer struct {
		status int
		body   map[string]any
	}
	first := make(chan answer, 1)
	go func() {
		status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("race-1"))
		first <- answer{status, body}
	}()
	<-entered
	// The supplier is being called right now: the same key is told so, not placed again.
	recorder := h.serve(http.MethodPost, "/v1/services/orders", map[string]string{AccessTokenHeader: h.shop.AccessToken}, svcJSON(t, svcAirtimeBody("race-1")))
	if recorder.Code != http.StatusConflict || svcDecode(t, recorder)["code"] != "in_flight" || recorder.Header().Get("Retry-After") == "" {
		t.Fatalf("in flight: %d %s", recorder.Code, recorder.Body)
	}
	close(release)
	got := <-first
	if got.status != http.StatusCreated || h.exec.calls() != 1 {
		t.Fatalf("first: %d %v calls=%d", got.status, got.body, h.exec.calls())
	}
}

func TestParallelOrdersWithOneKeyReachTheSupplierOnce(t *testing.T) {
	h := readyServicesHarness(t)
	var wg sync.WaitGroup
	statuses := make([]int, 8)
	for i := range statuses {
		wg.Add(1)
		go func() {
			defer wg.Done()
			recorder := h.serve(http.MethodPost, "/v1/services/orders", map[string]string{AccessTokenHeader: h.shop.AccessToken}, svcJSON(t, svcAirtimeBody("par-1")))
			statuses[i] = recorder.Code
		}()
	}
	wg.Wait()
	if h.exec.calls() != 1 {
		t.Fatalf("one key, one supplier call: %d (%v)", h.exec.calls(), statuses)
	}
	created := 0
	for _, status := range statuses {
		switch status {
		case http.StatusCreated:
			created++
		case http.StatusOK, http.StatusConflict:
		default:
			t.Fatalf("unexpected status %d in %v", status, statuses)
		}
	}
	if created != 1 {
		t.Fatalf("exactly one request carries the order out: %v", statuses)
	}
}

func svcJSON(t *testing.T, value any) []byte {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestTestModeSellsFakeReceiptsFromNobody(t *testing.T) {
	h := newServicesHarness(t, func(cfg *services.Config) {
		cfg.TestMode = true
		cfg.Reloadly = nil
	})
	h.publishSettings(`{"usd_rate": "9.71"}`)
	h.fund("200")
	status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("test-1"))
	purchase := svcObject(t, body["purchase"])
	receipt := svcObject(t, purchase["receipt"])
	if status != http.StatusCreated || purchase["test_mode"] != true || receipt["operator_reference"] == nil ||
		!strings.HasPrefix(receipt["operator_reference"].(string), "TEST-") || receipt["phone"] != "+22370123456" {
		t.Fatalf("test order: %d %v", status, body)
	}
	row := h.purchase("test-1")
	if row.Supplier != "test" || !row.TestMode || !strings.HasPrefix(row.SupplierOrderID, "airtime:") {
		t.Fatalf("row: %+v", row)
	}
	status, replay := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("test-1"))
	if status != http.StatusOK || svcObject(t, svcObject(t, replay["purchase"])["receipt"])["transaction_id"] != receipt["transaction_id"] {
		t.Fatalf("a replay reads the same fake receipt: %d %v", status, replay)
	}
	// A bill hands back a fake token.
	status, body = h.call(http.MethodPost, "/v1/services/orders", svcBillBody("test-2"))
	if status != http.StatusCreated || !strings.HasPrefix(svcObject(t, svcObject(t, body["purchase"])["receipt"])["token"].(string), "TEST-") {
		t.Fatalf("test bill: %d %v", status, body)
	}
	// The directory says so.
	_, directory := h.call(http.MethodGet, "/v1/services/directory", nil)
	if directory["test_mode"] != true || directory["configured"] != true {
		t.Fatalf("directory: %v", directory["test_mode"])
	}
}

func TestTheFullNumberNeverLeavesTheRequest(t *testing.T) {
	h := readyServicesHarness(t)
	h.exec.onAirtime = func(order services.AirtimeOrder) (services.Result, error) {
		return services.Result{}, &vouchers.Failure{Code: vouchers.FailureRefused, Definite: true,
			Detail: "Invalid recipient phone " + order.Phone.Digits() + " for the operator"}
	}
	h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("leak-1"))
	// The bill's failure echoes the account, in a way no digit rule could catch.
	h.exec.onBill = func(order services.BillOrder) (services.Result, error) {
		return services.Result{}, &vouchers.Failure{Code: vouchers.FailureRefused, Definite: true, Detail: "unknown meter " + order.Account}
	}
	h.call(http.MethodPost, "/v1/services/orders", svcBillBody("leak-2"))
	for _, secret := range []string{"70123456", "22370123456", "14500000001"} {
		if strings.Contains(h.logs.String(), secret) {
			t.Fatalf("%s reached the log:\n%s", secret, h.logs.String())
		}
	}
	for _, key := range []string{"leak-1", "leak-2"} {
		row := h.purchase(key)
		raw, _ := json.Marshal(row)
		for _, secret := range []string{"70123456", "22370123456", "14500000001"} {
			if strings.Contains(string(raw), secret) {
				t.Fatalf("%s reached the ledger row of %s: %s", secret, key, raw)
			}
		}
	}
}

// ---- the operator ----

func TestTheOperatorSeesTheServices(t *testing.T) {
	h := readyServicesHarness(t)
	// Every admin route needs the admin token.
	for _, target := range []string{"/v1/services/admin/config", "/v1/services/admin/directory", "/v1/services/admin/names", "/v1/services/admin/balance"} {
		if recorder := h.serve(http.MethodGet, target, nil, nil); recorder.Code != http.StatusUnauthorized {
			t.Fatalf("%s without a token: %d", target, recorder.Code)
		}
		if recorder := h.serve(http.MethodGet, target, map[string]string{AccessTokenHeader: h.shop.AccessToken}, nil); recorder.Code != http.StatusUnauthorized {
			t.Fatalf("%s with a shop token: %d", target, recorder.Code)
		}
	}
	status, config := h.admin(http.MethodGet, "/v1/services/admin/config", "")
	stats := svcObject(t, config["stats"])
	if status != http.StatusOK || stats["configured"] != true || stats["supplier"] != "reloadly" {
		t.Fatalf("config: %d %v", status, config)
	}
	status, directory := h.admin(http.MethodGet, "/v1/services/admin/directory?country=ML,SD&refresh=1", "")
	view := svcObject(t, directory["directory"])
	if status != http.StatusOK || len(view["countries"].([]any)) != 1 || view["countries"].([]any)[0].(map[string]any)["code"] != "ML" ||
		len(view["unsupported"].([]any)) != 1 {
		t.Fatalf("filtered directory: %d %v", status, directory)
	}
	status, names := h.admin(http.MethodGet, "/v1/services/admin/names?missing=1", "")
	missing := names["missing"].([]any)
	if status != http.StatusOK || len(missing) == 0 || svcObject(t, missing[0])["kind"] == nil {
		t.Fatalf("names: %d %v", status, names)
	}
	status, quote := h.admin(http.MethodPost, "/v1/services/admin/quote", `{"kind":"airtime","operator_id":289,"amount":"5000","amount_currency":"XOF"}`)
	if status != http.StatusOK || quote["order_in_dollars"] != true || quote["order_currency"] != "USD" || quote["order_amount"] != "9.9505" ||
		svcObject(t, quote["quote"])["unit_price"] == nil {
		t.Fatalf("admin quote: %d %v", status, quote)
	}
	if status, body := h.admin(http.MethodGet, "/v1/services/admin/balance", ""); status != http.StatusServiceUnavailable || body["code"] != "services_unconfigured" {
		t.Fatalf("no balance reader: %d %v", status, body)
	}
}

func TestPurchasesListCarriesTheKindAndTheMaskedTarget(t *testing.T) {
	h := readyServicesHarness(t)
	h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("list-1"))
	h.call(http.MethodPost, "/v1/services/orders", svcBillBody("list-2"))
	status, body := h.admin(http.MethodGet, "/v1/vouchers/admin/purchases?kind=airtime", "")
	rows := body["purchases"].([]any)
	if status != http.StatusOK || len(rows) != 1 || svcObject(t, rows[0])["target"] != "+223•••••456" || svcObject(t, rows[0])["kind"] != "airtime" {
		t.Fatalf("airtime rows: %d %v", status, body)
	}
	status, body = h.admin(http.MethodGet, "/v1/vouchers/admin/purchases?kind=bill", "")
	if rows = body["purchases"].([]any); status != http.StatusOK || len(rows) != 1 || svcObject(t, rows[0])["kind"] != "bill" {
		t.Fatalf("bill rows: %d %v", status, body)
	}
	// The operator can have the supplier asked about an order now.
	id := h.purchase("list-1").ID
	status, checked := h.admin(http.MethodPost, "/v1/vouchers/admin/purchases/"+id+"/check", "{}")
	if status != http.StatusOK || checked["verdict"] != "settled" {
		t.Fatalf("check: %d %v", status, checked)
	}
}

// ---- a relay that cannot reach its supplier ----

type failingServiceSource struct{ err error }

func (s failingServiceSource) Load(context.Context) (services.Raw, error) {
	return services.Raw{}, s.err
}

func TestTheDirectoryIsUnavailableWhileTheSupplierCannotBeRead(t *testing.T) {
	h := readyServicesHarness(t, func(cfg *services.Config) { cfg.Source = failingServiceSource{err: fmt.Errorf("reloadly is down")} })
	recorder := h.serve(http.MethodGet, "/v1/services/directory", map[string]string{AccessTokenHeader: h.shop.AccessToken}, nil)
	if recorder.Code != http.StatusServiceUnavailable || svcDecode(t, recorder)["code"] != "services_unavailable" || recorder.Header().Get("Retry-After") == "" {
		t.Fatalf("directory: %d %s", recorder.Code, recorder.Body)
	}
	status, body := h.call(http.MethodPost, "/v1/services/quote", map[string]any{"kind": "airtime", "operator_id": 289, "amount": "5000", "amount_currency": "XOF"})
	if status != http.StatusConflict || body["code"] != "service_unavailable" || body["reason"] != "directory_unavailable" {
		t.Fatalf("quote: %d %v", status, body)
	}
	status, body = h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("down-1"))
	if status != http.StatusConflict || body["code"] != "service_unavailable" {
		t.Fatalf("order: %d %v", status, body)
	}
	if h.exec.calls() != 0 {
		t.Fatal("nothing is sold from a directory nobody could read")
	}
	if _, found, _ := h.store.FindVoucherPurchaseByKey(context.Background(), h.shop.Installation.ID, "down-1"); found {
		t.Fatal("and nothing is charged for it")
	}
}

func TestAServiceOrderIsStillReadableByARelayWithoutServices(t *testing.T) {
	h := readyServicesHarness(t)
	if status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("orphan-1")); status != http.StatusCreated {
		t.Fatalf("order: %d %v", status, body)
	}
	// The relay is restarted without Reloadly configured: the row is still read.
	h.server.Services = nil
	status, read := h.call(http.MethodGet, "/v1/vouchers/purchases/orphan-1", nil)
	purchase := svcObject(t, read["purchase"])
	if status != http.StatusOK || purchase["kind"] != "airtime" || purchase["status"] != "succeeded" || purchase["receipt_pending"] != true ||
		purchase["target"] != "+223•••••456" {
		t.Fatalf("read: %d %v", status, read)
	}
	// And an open one is left alone by a reconciler that has no supplier to ask.
	h2 := readyServicesHarness(t)
	h2.exec.onAirtime = func(services.AirtimeOrder) (services.Result, error) {
		return services.Result{}, &vouchers.Failure{Code: vouchers.FailureUnknown, Detail: "timeout"}
	}
	h2.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("orphan-2"))
	h2.server.Services = nil
	(&VoucherReconciler{Server: h2.server, Store: h2.store}).Round(context.Background())
	if purchase := h2.purchase("orphan-2"); purchase.Status != "pending" || purchase.HeldSince == nil {
		t.Fatalf("held until a supplier can be asked: %+v", purchase)
	}
	// Replaying a request against such a relay says the service is not sold.
	if status, body := h2.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("orphan-2")); status != http.StatusServiceUnavailable || body["code"] != "services_unconfigured" {
		t.Fatalf("replay without services: %d %v", status, body)
	}
}

func TestACardPurchaseStillCarriesItsKindAndNoTarget(t *testing.T) {
	// The purchase payload names its kind for every purchase; a card has no target.
	payload := voucherPurchasePayload(control.VoucherPurchase{ID: "p", IdempotencyKey: "k", ItemKey: "itunes-us-10", Status: "succeeded"}, nil, false)
	if payload["kind"] != "card" || payload["target"] != "" {
		t.Fatalf("payload: %v", payload)
	}
	service := servicePurchasePayload(control.VoucherPurchase{ID: "p", Kind: "bill", Target: "••••280", Status: "pending"}, nil, true)
	if service["kind"] != "bill" || service["target"] != "••••280" || service["receipt_pending"] != true ||
		len(service["receipt"].(map[string]string)) != 0 || service["codes_pending"] != false {
		t.Fatalf("service payload: %v", service)
	}
}

func TestServiceOrdersAreRateLimitedPerShopAndReplaysAreNot(t *testing.T) {
	h := readyServicesHarness(t)
	h.server.RateLimiter = ratelimit.NewMemoryLimiter(h.clock.Now)
	h.server.Vouchers.RateLimit = ratelimit.Policy{Limit: 2, Window: time.Minute}
	for i := 0; i < 2; i++ {
		order := svcAirtimeBody("rate-" + strconv.Itoa(i))
		if status, body := h.call(http.MethodPost, "/v1/services/orders", order); status != http.StatusCreated {
			t.Fatalf("order %d: %d %v", i, status, body)
		}
	}
	recorder := h.serve(http.MethodPost, "/v1/services/orders", map[string]string{AccessTokenHeader: h.shop.AccessToken}, svcJSON(t, svcAirtimeBody("rate-2")))
	if recorder.Code != http.StatusTooManyRequests || svcDecode(t, recorder)["code"] != "rate_limited" || recorder.Header().Get("Retry-After") == "" {
		t.Fatalf("a third order in the window: %d %s", recorder.Code, recorder.Body)
	}
	if h.exec.calls() != 2 {
		t.Fatalf("a limited order reaches nobody: %d calls", h.exec.calls())
	}
	// A replay of an order already placed is never limited: the shop lost its answer.
	if status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("rate-0")); status != http.StatusOK || body["replayed"] != true {
		t.Fatalf("replay under the limit: %d %v", status, body)
	}
	h.clock.advance(2 * time.Minute)
	if status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("rate-2")); status != http.StatusCreated {
		t.Fatalf("after the window: %d %v", status, body)
	}
}

// ---- what the directory leaves out on purpose ----

// israelSource is the fixture with Israel added: Reloadly sells there, the
// relay has no Arabic name for the country.
type israelSource struct{}

func (israelSource) Load(ctx context.Context) (services.Raw, error) {
	raw, err := services.FixtureSource{}.Load(ctx)
	if err != nil {
		return raw, err
	}
	for _, operator := range raw.Operators {
		if operator.Key() == 289 {
			copied := operator
			copied.ID, copied.OperatorID, copied.Name = 1161, 1161, "Cellcom Israel"
			copied.Country.ISOName, copied.Country.Name = "IL", "Israel"
			raw.Operators = append(raw.Operators, copied)
			break
		}
	}
	raw.Countries = append(raw.Countries, reloadly.TopupCountry{ISOName: "IL", Name: "Israel", CurrencyCode: "ILS", CallingCodes: []string{"+972"}})
	return raw, nil
}

func TestAnUnnamedCountryAndAHiddenPlanAreNeverSold(t *testing.T) {
	h := readyServicesHarness(t, func(cfg *services.Config) { cfg.Source = israelSource{} })
	recorder := h.serve(http.MethodGet, "/v1/services/directory", map[string]string{AccessTokenHeader: h.shop.AccessToken}, nil)
	if recorder.Code != http.StatusOK {
		t.Fatalf("directory: %d %s", recorder.Code, recorder.Body)
	}
	body := recorder.Body.String()
	if strings.Contains(body, `"code":"IL"`) || strings.Contains(body, "Israel") {
		t.Fatal("Israel is not in the directory the shops read")
	}
	if strings.Contains(strings.ToLower(body), "charme") {
		t.Fatal("the adult-content plans are not in the directory the shops read")
	}

	// Neither can be reached by an order that names them.
	status, refused := h.call(http.MethodPost, "/v1/services/orders", map[string]any{
		"kind": "airtime", "operator_id": 1161, "country": "IL", "phone": "0501234567",
		"amount": "5000", "amount_currency": "ILS", "idempotency_key": "il-1", "requested_by": "cashier",
	})
	if status != http.StatusNotFound || refused["code"] != "unknown_operator" {
		t.Fatalf("an Israeli operator: %d %v", status, refused)
	}
	status, refused = h.call(http.MethodPost, "/v1/services/orders", map[string]any{
		"kind": "bill", "biller_id": 27, "country": "ML", "account": "12345678", "amount_id": 1,
		"amount": "11000", "amount_currency": "XOF", "idempotency_key": "charme-1", "requested_by": "cashier",
	})
	if status != http.StatusUnprocessableEntity || refused["code"] != "amount_not_offered" {
		t.Fatalf("a hidden plan: %d %v", status, refused)
	}
	if h.exec.calls() != 0 {
		t.Fatal("the supplier was never asked")
	}
	for _, key := range []string{"il-1", "charme-1"} {
		if _, found, _ := h.store.FindVoucherPurchaseByKey(context.Background(), h.shop.Installation.ID, key); found {
			t.Fatalf("%s: nothing is charged for what is not sold", key)
		}
	}
	// A plan next to the hidden one is sold as usual.
	status, ok := h.call(http.MethodPost, "/v1/services/orders", map[string]any{
		"kind": "bill", "biller_id": 27, "country": "ML", "account": "12345678", "amount_id": 3,
		"amount": "10000", "amount_currency": "XOF", "idempotency_key": "canal-3", "requested_by": "cashier",
	})
	if status != http.StatusCreated {
		t.Fatalf("a plan that is offered: %d %v", status, ok)
	}
	// The operator sees what was left out.
	status, config := h.admin(http.MethodGet, "/v1/services/admin/config", "")
	if status != http.StatusOK {
		t.Fatalf("admin config: %d %v", status, config)
	}
	build := svcObject(t, svcObject(t, config["stats"])["build"])
	dropped, _ := build["dropped_countries"].([]any)
	if len(dropped) != 1 || svcObject(t, dropped[0])["code"] != "IL" || build["hidden_plans"] != float64(8) {
		t.Fatalf("what the operator is told: %v", build)
	}
}

func TestTheServiceFeeAndTheRateAreRecordedInThePurchaseDetails(t *testing.T) {
	h := readyServicesHarness(t)
	if status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("fee-1")); status != http.StatusCreated {
		t.Fatalf("%d %v", status, body)
	}
	var details map[string]any
	if err := json.Unmarshal(h.purchase("fee-1").Details, &details); err != nil {
		t.Fatal(err)
	}
	if details["service_fee_lyd"] != "2.00" || details["usd_rate"] == nil || details["usd_rate_source"] != "manual" {
		t.Fatalf("details: %v", details)
	}
}
