// Package reloadlyfake is a stand-in for Reloadly's token service and gift card
// API, for tests. It serves the endpoints the relay uses, keeps the orders it
// takes, prices them with the same formulas as the real thing, and can be told
// to fail the way the real one does (an answer lost after the order was taken,
// an unreadable code list, a balance too small).
//
// It is test support: the relay binary never imports it.
package reloadlyfake

import (
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/reloadly"
)

// Product is a gift card product as Reloadly lists it, for the fields a price
// needs. Everything is denominated in USD unless Currency and Rate say
// otherwise.
type Product struct {
	ID    int64
	Name  string
	Brand string
	// Denomination is "FIXED" (Fixed lists the face values) or "RANGE" (Min and
	// Max bound them).
	Denomination string
	Fixed        []string
	Min, Max     string
	// Currency and Rate: the card's own currency and how many dollars one unit
	// of it costs ("1" for dollars, which is the default).
	Currency string
	Rate     string
	// Fee is the flat fee in dollars, Percent the percentage fee and Discount
	// the discount, both in percent of the price in dollars.
	Fee, Percent, Discount string
	// Status is ACTIVE unless set.
	Status string
}

// Order is an order the fake took.
type Order struct {
	ID               int64
	CustomIdentifier string
	ProductID        int64
	Quantity         int
	UnitPrice        string
	Status           string
	Cost             string
	CreatedAt        time.Time
}

// Call is one request the fake saw (the token service's included).
type Call struct {
	Method string
	Path   string
	Query  string
	Body   string
}

// Reply is a scripted answer to an order request.
type Reply struct {
	Status int
	Body   string
	// Take makes the fake record the order as well as send this answer: the
	// order exists at "Reloadly", the shop's relay just never heard of it.
	Take bool
}

// Fake is the stand-in server.
type Fake struct {
	t   testing.TB
	srv *httptest.Server

	mu       sync.Mutex
	products []Product
	raw      []json.RawMessage
	orders   []*Order
	nextID   int64
	balance  *big.Rat
	script   []Reply
	calls    []Call
	status   string
	noCodes  bool
	noFunds  bool
	now      time.Time
}

// New starts a fake with no products and a balance of 1000 dollars.
func New(t testing.TB) *Fake {
	t.Helper()
	f := &Fake{
		t:       t,
		balance: big.NewRat(1000, 1),
		nextID:  79000,
		status:  "SUCCESSFUL",
		now:     time.Date(2026, 10, 8, 10, 0, 0, 0, time.UTC),
	}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

// URL is the fake's address: the token service and the gift card API are both
// served from it.
func (f *Fake) URL() string { return f.srv.URL }

// Config is a client configuration that talks to the fake.
func (f *Fake) Config() reloadly.Config {
	return reloadly.Config{
		ClientID:     "fake-id",
		ClientSecret: "fake-secret",
		AuthURL:      f.srv.URL,
		GiftcardsURL: f.srv.URL,
		TopupsURL:    f.srv.URL,
		UtilitiesURL: f.srv.URL,
		RetryBackoff: time.Millisecond,
	}
}

// Client is a client that talks to the fake.
func (f *Fake) Client() *reloadly.Client {
	f.t.Helper()
	client, err := reloadly.New(f.Config())
	if err != nil {
		f.t.Fatal(err)
	}
	return client
}

// AddProduct lists a product.
func (f *Fake) AddProduct(product Product) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.products = append(f.products, product)
}

// AddRawProducts lists products exactly as Reloadly wrote them (a fixture).
func (f *Fake) AddRawProducts(rows ...json.RawMessage) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.raw = append(f.raw, rows...)
}

// RemoveProduct stops listing a product.
func (f *Fake) RemoveProduct(id int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	kept := f.products[:0]
	for _, product := range f.products {
		if product.ID != id {
			kept = append(kept, product)
		}
	}
	f.products = kept
}

// SetBalance sets the account's dollars.
func (f *Fake) SetBalance(dollars string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	value, ok := new(big.Rat).SetString(dollars)
	if !ok {
		f.t.Fatalf("balance %q", dollars)
	}
	f.balance = value
}

// FailBalance makes the balance read answer 500 until it is called with false.
func (f *Fake) FailBalance(failing bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.noFunds = failing
}

// SetOrderStatus is the status new orders get (SUCCESSFUL by default).
func (f *Fake) SetOrderStatus(status string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.status = status
}

// SetOrderStatusOf moves an order to a status, as Reloadly does once it settles.
func (f *Fake) SetOrderStatusOf(id int64, status string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, order := range f.orders {
		if order.ID == id {
			order.Status = status
			return
		}
	}
	f.t.Fatalf("no order %d", id)
}

// HideCodes makes the code list unreadable (404) until it is called with false.
func (f *Fake) HideCodes(hidden bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.noCodes = hidden
}

// Script queues answers to the next order requests, one each, in order.
func (f *Fake) Script(replies ...Reply) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.script = append(f.script, replies...)
}

// Orders are the orders the fake took, oldest first.
func (f *Fake) Orders() []Order {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]Order, 0, len(f.orders))
	for _, order := range f.orders {
		out = append(out, *order)
	}
	return out
}

// Calls are the requests the fake saw, oldest first.
func (f *Fake) Calls() []Call {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]Call(nil), f.calls...)
}

// CallsTo counts the requests with this method and path prefix.
func (f *Fake) CallsTo(method, pathPrefix string) int {
	n := 0
	for _, call := range f.Calls() {
		if call.Method == method && strings.HasPrefix(call.Path, pathPrefix) {
			n++
		}
	}
	return n
}

// Balance is the account's dollars now.
func (f *Fake) Balance() *big.Rat {
	f.mu.Lock()
	defer f.mu.Unlock()
	return new(big.Rat).Set(f.balance)
}

func (f *Fake) serve(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	f.mu.Lock()
	f.calls = append(f.calls, Call{Method: r.Method, Path: r.URL.Path, Query: r.URL.RawQuery, Body: string(body)})
	f.mu.Unlock()

	if r.URL.Path == "/oauth/token" {
		write(w, http.StatusOK, `{"access_token":"fake-token","scope":"x","expires_in":3600,"token_type":"Bearer"}`)
		return
	}
	if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
		write(w, http.StatusUnauthorized, errorBody("Invalid token", "INVALID_TOKEN", r.URL.Path))
		return
	}
	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/accounts/balance":
		f.serveBalance(w)
	case r.Method == http.MethodGet && r.URL.Path == "/products":
		f.serveProducts(w, r)
	case r.Method == http.MethodPost && r.URL.Path == "/orders":
		f.serveOrder(w, r, body)
	case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/cards") && strings.HasPrefix(r.URL.Path, "/orders/transactions/"):
		f.serveCodes(w, r)
	case r.Method == http.MethodGet && r.URL.Path == "/reports/transactions":
		f.serveReport(w, r)
	case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/reports/transactions/"):
		f.serveTransaction(w, r)
	default:
		write(w, http.StatusNotFound, fmt.Sprintf(`{"timestamp":"2026-10-08T10:00:00.000+00:00","status":404,"error":"Not Found","path":%q}`, r.URL.Path))
	}
}

func write(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, body)
}

func errorBody(message, code, path string) string {
	return fmt.Sprintf(`{"timeStamp":"2026-10-08 10:00:00","message":%q,"path":%q,"errorCode":%q,"infoLink":null,"details":[]}`, message, path, code)
}

func (f *Fake) serveBalance(w http.ResponseWriter) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.noFunds {
		write(w, http.StatusInternalServerError, `{"timestamp":"2026-10-08T10:00:00.000+00:00","status":500,"error":"Internal Server Error","path":"/accounts/balance"}`)
		return
	}
	write(w, http.StatusOK, fmt.Sprintf(
		`{"balance":%s,"frozenBalance":0,"currencyCode":"USD","currencyName":"US Dollar","lowBalanceThreshold":null,"maxLowBalanceThreshold":null,"updatedAt":"2026-10-08 10:00:00"}`,
		f.balance.FloatString(5)))
}

func (f *Fake) serveProducts(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	rows := append([]json.RawMessage(nil), f.raw...)
	for _, product := range f.products {
		rows = append(rows, json.RawMessage(product.wire()))
	}
	f.mu.Unlock()
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	size, _ := strconv.Atoi(r.URL.Query().Get("size"))
	if page < 1 {
		page = 1
	}
	if size < 1 {
		size = 200
	}
	totalPages := max(1, (len(rows)+size-1)/size)
	start, end := min((page-1)*size, len(rows)), min(page*size, len(rows))
	chunk := make([]string, 0, end-start)
	for _, row := range rows[start:end] {
		chunk = append(chunk, string(row))
	}
	write(w, http.StatusOK, fmt.Sprintf(`{"content":[%s],"totalPages":%d,"totalElements":%d,"number":%d,"last":%t}`,
		strings.Join(chunk, ","), totalPages, len(rows), page-1, page >= totalPages))
}

// wire writes the product the way Reloadly does.
func (p Product) wire() string {
	currency, rate := p.Currency, p.Rate
	if currency == "" {
		currency = "USD"
	}
	if rate == "" {
		rate = "1"
	}
	status := p.Status
	if status == "" {
		status = "ACTIVE"
	}
	number := func(value, fallback string) string {
		if strings.TrimSpace(value) == "" {
			return fallback
		}
		return value
	}
	denomination := p.Denomination
	if denomination == "" {
		denomination = "FIXED"
	}
	var minRecipient, maxRecipient, minSender, maxSender = "null", "null", "null", "null"
	var fixed, fixedSender, fixedMap = "[]", "null", "null"
	if denomination == "RANGE" {
		minRecipient, maxRecipient = p.Min, p.Max
		minSender, maxSender = p.Min, p.Max
		if currency != "USD" {
			minSender = scaled(p.Min, rate)
			maxSender = scaled(p.Max, rate)
		}
	} else {
		fixed = "[" + strings.Join(p.Fixed, ",") + "]"
		senders := make([]string, 0, len(p.Fixed))
		pairs := make([]string, 0, len(p.Fixed))
		for _, face := range p.Fixed {
			sender := face
			if currency != "USD" {
				sender = scaled(face, rate)
			}
			senders = append(senders, sender)
			pairs = append(pairs, fmt.Sprintf("%q:%s", face, sender))
		}
		fixedSender = "[" + strings.Join(senders, ",") + "]"
		fixedMap = "{" + strings.Join(pairs, ",") + "}"
	}
	return fmt.Sprintf(`{"productId":%d,"productName":%q,"global":false,"status":%q,"supportsPreOrder":false,`+
		`"senderFee":%s,"senderFeePercentage":%s,"discountPercentage":%s,"denominationType":%q,`+
		`"recipientCurrencyCode":%q,"minRecipientDenomination":%s,"maxRecipientDenomination":%s,`+
		`"senderCurrencyCode":"USD","minSenderDenomination":%s,"maxSenderDenomination":%s,`+
		`"fixedRecipientDenominations":%s,"fixedSenderDenominations":%s,"fixedRecipientToSenderDenominationsMap":%s,`+
		`"metadata":{},"logoUrls":["https://cdn.example/logo.png"],"brand":{"brandId":1,"brandName":%q},`+
		`"category":{"id":1,"name":"Gaming"},"country":{"isoName":"US","name":"United States","flagUrl":""},`+
		`"redeemInstruction":{"concise":"Redeem online","verbose":"Redeem online"},"additionalRequirements":{"userIdRequired":false},`+
		`"recipientCurrencyToSenderCurrencyExchangeRate":%s}`,
		p.ID, p.Name, status,
		number(p.Fee, "0"), number(p.Percent, "0"), number(p.Discount, "0"), denomination,
		currency, minRecipient, maxRecipient, minSender, maxSender,
		fixed, fixedSender, fixedMap, p.Brand, rate)
}

// scaled is value x rate to cents, for a product priced in another currency.
func scaled(value, rate string) string {
	v, _ := new(big.Rat).SetString(value)
	r, _ := new(big.Rat).SetString(rate)
	return new(big.Rat).Mul(v, r).FloatString(2)
}

func (f *Fake) product(id int64) (Product, bool) {
	for _, product := range f.products {
		if product.ID == id {
			return product, true
		}
	}
	return Product{}, false
}

// reloadlyProduct decodes a product the way the relay's client does.
func (p Product) reloadlyProduct() (reloadly.GiftProduct, error) {
	var out reloadly.GiftProduct
	err := json.Unmarshal([]byte(p.wire()), &out)
	return out, err
}

func (f *Fake) serveOrder(w http.ResponseWriter, r *http.Request, body []byte) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var request struct {
		ProductID        int64           `json:"productId"`
		Quantity         int             `json:"quantity"`
		UnitPrice        json.RawMessage `json:"unitPrice"`
		CustomIdentifier string          `json:"customIdentifier"`
		SenderName       string          `json:"senderName"`
	}
	if err := json.Unmarshal(body, &request); err != nil {
		write(w, http.StatusBadRequest, errorBody("Invalid body", "INVALID_INPUT_PROVIDED", r.URL.Path))
		return
	}
	var scripted *Reply
	if len(f.script) > 0 {
		scripted, f.script = &f.script[0], f.script[1:]
		if !scripted.Take {
			write(w, scripted.Status, scripted.Body)
			return
		}
	}
	for _, order := range f.orders {
		if strings.EqualFold(order.CustomIdentifier, request.CustomIdentifier) {
			write(w, http.StatusBadRequest, errorBody("Custom identifier "+request.CustomIdentifier+" has already been used", "CUSTOM_IDENTIFIER_ALREADY_USED", r.URL.Path))
			return
		}
	}
	product, ok := f.product(request.ProductID)
	if !ok || request.Quantity < 1 || strings.TrimSpace(request.SenderName) == "" || strings.TrimSpace(request.CustomIdentifier) == "" {
		write(w, http.StatusBadRequest, errorBody("Invalid product or fields", "INVALID_INPUT_PROVIDED", r.URL.Path))
		return
	}
	amount, ok := new(big.Rat).SetString(strings.Trim(string(request.UnitPrice), `"`))
	wire, err := product.reloadlyProduct()
	if err != nil || !ok {
		write(w, http.StatusBadRequest, errorBody("Invalid amount", "INVALID_INPUT_PROVIDED", r.URL.Path))
		return
	}
	cost, ok := reloadly.GiftOrderCost(wire, amount, request.Quantity)
	if !ok {
		write(w, http.StatusBadRequest, errorBody("Invalid unit price for this product", "INVALID_INPUT_PROVIDED", r.URL.Path))
		return
	}
	if cost.Cmp(f.balance) > 0 {
		write(w, http.StatusBadRequest, errorBody("Insufficient balance", "INSUFFICIENT_BALANCE", r.URL.Path))
		return
	}
	f.nextID++
	order := &Order{
		ID: f.nextID, CustomIdentifier: request.CustomIdentifier, ProductID: product.ID, Quantity: request.Quantity,
		UnitPrice: amount.FloatString(2), Status: f.status, Cost: cost.FloatString(5), CreatedAt: f.now,
	}
	f.orders = append(f.orders, order)
	if order.Status != "FAILED" && order.Status != "REFUNDED" {
		f.balance.Sub(f.balance, cost)
	}
	if scripted != nil { // taken, but the answer is a scripted one
		write(w, scripted.Status, scripted.Body)
		return
	}
	write(w, http.StatusOK, f.transactionJSON(order))
}

func (f *Fake) transactionJSON(order *Order) string {
	product, _ := f.product(order.ProductID)
	cost := order.Cost
	if order.Status == "FAILED" || order.Status == "REFUNDED" {
		cost = "0.00000"
	}
	return fmt.Sprintf(`{"transactionId":%d,"amount":%s,"discount":0.00,"currencyCode":"USD","fee":1.00,"smsFee":0.00,"totalFee":1.00,`+
		`"preOrdered":false,"recipientEmail":null,"recipientPhone":null,"customIdentifier":%q,"status":%q,`+
		`"transactionCreatedTime":%q,"product":{"productId":%d,"productName":%q,"countryCode":"US","quantity":%d,`+
		`"unitPrice":%s,"totalPrice":%s,"currencyCode":"USD","brand":{"brandId":1,"brandName":%q}},`+
		`"balanceInfo":{"oldBalance":1000.00000,"newBalance":990.00000,"cost":%s,"currencyCode":"USD","currencyName":"US Dollar","updatedAt":"2026-10-08 10:00:00"}}`,
		order.ID, cost, order.CustomIdentifier, order.Status, order.CreatedAt.Format("2006-01-02 15:04:05"),
		product.ID, product.Name, order.Quantity, order.UnitPrice, order.UnitPrice, product.Brand, cost)
}

func (f *Fake) order(id int64) *Order {
	for _, order := range f.orders {
		if order.ID == id {
			return order
		}
	}
	return nil
}

func transactionID(path, prefix, suffix string) int64 {
	id, _ := strconv.ParseInt(strings.TrimSuffix(strings.TrimPrefix(path, prefix), suffix), 10, 64)
	return id
}

func (f *Fake) serveCodes(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	order := f.order(transactionID(r.URL.Path, "/orders/transactions/", "/cards"))
	if order == nil || order.Status != "SUCCESSFUL" || f.noCodes {
		write(w, http.StatusNotFound, errorBody("Transaction not found or its cards are not ready", "TRANSACTION_NOT_FOUND", r.URL.Path))
		return
	}
	cards := make([]string, 0, order.Quantity)
	for i := 1; i <= order.Quantity; i++ {
		cards = append(cards, fmt.Sprintf(`{"cardNumber":"FAKE-%d-%d","pinCode":null,"redemptionUrl":null}`, order.ID, i))
	}
	write(w, http.StatusOK, "["+strings.Join(cards, ",")+"]")
}

func (f *Fake) serveTransaction(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	order := f.order(transactionID(r.URL.Path, "/reports/transactions/", ""))
	if order == nil {
		write(w, http.StatusNotFound, errorBody("Transaction not found", "TRANSACTION_NOT_FOUND", r.URL.Path))
		return
	}
	write(w, http.StatusOK, f.transactionJSON(order))
}

func (f *Fake) serveReport(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	identifier := r.URL.Query().Get("customIdentifier")
	var rows []string
	for _, order := range f.orders {
		if identifier == "" || strings.EqualFold(order.CustomIdentifier, identifier) {
			rows = append(rows, f.transactionJSON(order))
		}
	}
	write(w, http.StatusOK, fmt.Sprintf(`{"content":[%s],"totalPages":1,"totalElements":%d,"number":0,"last":true}`, strings.Join(rows, ","), len(rows)))
}
