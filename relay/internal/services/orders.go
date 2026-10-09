package services

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"pointy/relay/internal/vouchers"
)

// Everything an order or a quote needs from the directory: which operator or
// biller, whether the amount is one it sells, what that costs the company and so
// what the shop and its customer pay. None of it calls the supplier; the
// directory is the data.

// QuoteRequest is POST /v1/services/quote.
type QuoteRequest struct {
	Kind       string `json:"kind"`
	OperatorID int64  `json:"operator_id"`
	BillerID   int64  `json:"biller_id"`
	// Amount is a decimal string in AmountCurrency.
	Amount         string `json:"amount"`
	AmountCurrency string `json:"amount_currency"`
	// AmountID names the plan of a fixed biller, 0 when none.
	AmountID int64 `json:"amount_id"`
	// InvoiceID is optional on a quote; when the key is present for a biller that
	// requires an invoice it must not be blank.
	InvoiceID *string `json:"invoice_id"`
	// Country and Phone are optional on an airtime quote (a bill takes no number):
	// the number the top-up is for, as the cashier typed it, in any form
	// ParsePhone reads. The answer then says how the relay read it (Quoted.Phone),
	// so the shop never re-implements the relay's phone rules. Country defaults
	// to the operator's; a quote without a number is valid, as the till quotes its
	// tiles before the number is typed.
	Country string `json:"country"`
	Phone   string `json:"phone"`
}

// OrderRequest is POST /v1/services/orders, less the ledger's own fields.
type OrderRequest struct {
	Kind           string
	OperatorID     int64
	BillerID       int64
	Country        string
	Phone          string
	Account        string
	InvoiceID      string
	Amount         string
	AmountCurrency string
	AmountID       int64
	// InstallationID is the shop placing the order. It is not on the wire: the
	// HTTP layer sets it from the shop's token, and it salts the digest of the
	// order's target, so the same number in two shops leaves two different digests.
	InstallationID string
}

// PreparedOrder is an order that passed every check: what the ledger claims and
// what the supplier is called with.
type PreparedOrder struct {
	Kind     string
	ItemKey  string
	BrandKey string
	// Name is the item as the statement and the quote name it, frozen at purchase.
	Name string
	// Target is the masked number or account.
	Target string
	// Details is the write-once JSON kept with the ledger row: what was ordered,
	// never the full number.
	Details json.RawMessage
	Prices  Prices
	// Receive is what the recipient is credited (airtime) or what is paid to the
	// biller (bills).
	Receive     Money
	Approximate bool
	// SupplierRef is the operator's or biller's id, as text.
	SupplierRef string
	// Airtime or Bill is the supplier call to make, less its ClientRef, which is
	// the purchase's id once the purchase is claimed.
	Airtime *AirtimeOrder
	Bill    *BillOrder
}

// Quoted is a priced quote, and how the order would be placed with the supplier.
type Quoted struct {
	Quote  Quote
	Prices Prices
	Order  OrderInfo
	// Phone is how an airtime quote's number was read; nil when the request
	// carried none.
	Phone *DetectedPhone
}

// OrderInfo is how an amount is ordered from the supplier: the amount and
// currency the supplier receives, whether that is the recipient's own currency,
// and what it debits the company, in dollars.
type OrderInfo struct {
	Amount   *big.Rat
	Currency string
	Local    bool
	Cost     *big.Rat
}

func (p orderPlan) info() OrderInfo {
	return OrderInfo{Amount: p.Amount, Currency: p.Currency, Local: p.Local, Cost: p.Cost}
}

var (
	accountPattern = regexp.MustCompile(`^[A-Za-z0-9._/\-]{3,40}$`)
	invoicePattern = regexp.MustCompile(`^[A-Za-z0-9_/\-]{1,24}$`)
)

// Statement names of the two services, in front of what was bought.
const (
	airtimeTitle = "شحن مباشر"
	billTitle    = "دفع فاتورة"
	nameSep      = " · "
)

// Quote prices one thing, exactly. The amount must be one the operator or
// biller sells; nothing is charged and the supplier is not called.
func (s *Service) Quote(ctx context.Context, in PricingInput, request QuoteRequest) (Quoted, *Refusal) {
	kind := strings.ToLower(strings.TrimSpace(request.Kind))
	if kind != KindAirtime && kind != KindBill {
		return Quoted{}, refuse(http.StatusBadRequest, CodeInvalidRequest, `kind must be "airtime" or "bill"`, nil)
	}
	snap, refusal := s.directoryForSale(ctx)
	if refusal != nil {
		return Quoted{}, refusal
	}
	switch kind {
	case KindAirtime:
		entry, ok := snap.operators[request.OperatorID]
		if !ok {
			return Quoted{}, refuse(http.StatusNotFound, CodeUnknownOperator, "no such operator", nil)
		}
		var detected *DetectedPhone
		if strings.TrimSpace(request.Phone) != "" {
			phone, refusal := readPhone(snap, entry, request.Country, request.Phone)
			if refusal != nil {
				return Quoted{}, refusal
			}
			view := phone.Detected()
			detected = &view
		}
		amount, refusal := entry.resolveAmount(request.Amount, request.AmountCurrency)
		if refusal != nil {
			return Quoted{}, refusal
		}
		priced, plan, refusal := entry.price(in.Settings, amount)
		if refusal != nil {
			return Quoted{}, refusal
		}
		receive := entry.receiveFor(amount)
		return Quoted{
			Phone: detected,
			Quote: Quote{
				Kind:        KindAirtime,
				Name:        entry.statementName(amount),
				UnitPrice:   priced.UnitString(),
				RetailPrice: priced.RetailString(),
				Receive:     Money{Amount: FormatAmount(receive), Currency: entry.receiveCurrency},
				Approximate: entry.approximate,
			},
			Prices: priced,
			Order:  plan.info(),
		}, nil
	default:
		entry, ok := snap.billers[request.BillerID]
		if !ok {
			return Quoted{}, refuse(http.StatusNotFound, CodeUnknownBiller, "no such biller", nil)
		}
		if entry.requiresInvoice && request.InvoiceID != nil {
			if refusal := checkInvoice(*request.InvoiceID); refusal != nil {
				return Quoted{}, refusal
			}
		}
		amount, plan, refusal := entry.resolveAmount(request.Amount, request.AmountCurrency, request.AmountID)
		if refusal != nil {
			return Quoted{}, refusal
		}
		priced, placed, refusal := entry.price(in.Settings, amount)
		if refusal != nil {
			return Quoted{}, refusal
		}
		return Quoted{
			Quote: Quote{
				Kind:        KindBill,
				Name:        entry.statementName(amount, plan),
				UnitPrice:   priced.UnitString(),
				RetailPrice: priced.RetailString(),
				Receive:     Money{Amount: FormatAmount(amount), Currency: entry.currency},
				Approximate: entry.approximate,
			},
			Prices: priced,
			Order:  placed.info(),
		}, nil
	}
}

// PrepareOrder checks an order against the directory and prices it. It refuses
// in the order the wire documents: nothing can be sold unpriced, the operator
// or biller must exist, then the number or account, then the amount.
func (s *Service) PrepareOrder(ctx context.Context, in PricingInput, request OrderRequest) (*PreparedOrder, *Refusal) {
	kind := strings.ToLower(strings.TrimSpace(request.Kind))
	if kind != KindAirtime && kind != KindBill {
		return nil, refuse(http.StatusBadRequest, CodeInvalidRequest, `kind must be "airtime" or "bill"`, nil)
	}
	if !in.Settings.Priced() {
		return nil, refuse(http.StatusServiceUnavailable, CodeServicesUnpriced,
			"no dollar rate is published, so nothing can be priced", nil)
	}
	snap, refusal := s.directoryForSale(ctx)
	if refusal != nil {
		return nil, refusal
	}
	if kind == KindAirtime {
		return s.prepareAirtime(snap, in, request)
	}
	return s.prepareBill(snap, in, request)
}

func (s *Service) prepareAirtime(snap *snapshot, in PricingInput, request OrderRequest) (*PreparedOrder, *Refusal) {
	entry, ok := snap.operators[request.OperatorID]
	if !ok {
		return nil, refuse(http.StatusNotFound, CodeUnknownOperator, "no such operator", nil)
	}
	phone, refusal := readPhone(snap, entry, request.Country, request.Phone)
	if refusal != nil {
		return nil, refusal
	}
	amount, refusal := entry.resolveAmount(request.Amount, request.AmountCurrency)
	if refusal != nil {
		return nil, refusal
	}
	priced, plan, refusal := entry.price(in.Settings, amount)
	if refusal != nil {
		return nil, refusal
	}
	receive := entry.receiveFor(amount)
	details, _ := json.Marshal(airtimeDetails{
		OperatorID:      entry.id,
		Operator:        entry.nameAR,
		OperatorEN:      entry.nameEN,
		Country:         entry.country,
		Amount:          FormatAmount(amount),
		Currency:        entry.currency,
		Receive:         FormatAmount(receive),
		ReceiveCurrency: entry.receiveCurrency,
		Local:           entry.local,
		Approximate:     entry.approximate,
		OrderMode:       plan.mode(),
		OrderAmount:     FormatAmount(plan.Amount),
		OrderCurrency:   plan.Currency,
		BufferPercent:   bufferText(plan.Buffer),
		USDRate:         rateText(in.Settings),
		USDRateSource:   rateSource(in.Settings),
		ServiceFeeLYD:   vouchers.FormatDinars(in.Settings.ServiceFee(KindAirtime)),
		Dial:            snap.countries[entry.country].dial,
		TargetKeyID:     s.targetKeyID(),
		TargetDigest:    s.targetDigest(request.InstallationID, KindAirtime, phone.Digits(), "", entry.currency),
	})
	return &PreparedOrder{
		Kind:        KindAirtime,
		ItemKey:     OrderItemKey(KindAirtime, entry.id, amount, entry.currency, 0),
		BrandKey:    KindAirtime,
		Name:        entry.statementName(amount),
		Target:      phone.Masked(),
		Details:     details,
		Prices:      priced,
		Receive:     Money{Amount: FormatAmount(receive), Currency: entry.receiveCurrency},
		Approximate: entry.approximate,
		SupplierRef: strconv.FormatInt(entry.id, 10),
		Airtime: &AirtimeOrder{
			OperatorID:   entry.id,
			OperatorName: entry.nameEN,
			Phone:        phone,
			Amount:       plan.Amount,
			Currency:     plan.Currency,
			Local:        plan.Local,
			Receive:      Money{Amount: FormatAmount(receive), Currency: entry.receiveCurrency},
		},
	}, nil
}

func (s *Service) prepareBill(snap *snapshot, in PricingInput, request OrderRequest) (*PreparedOrder, *Refusal) {
	entry, ok := snap.billers[request.BillerID]
	if !ok {
		return nil, refuse(http.StatusNotFound, CodeUnknownBiller, "no such biller", nil)
	}
	if country := strings.ToUpper(strings.TrimSpace(request.Country)); country != "" && country != entry.country {
		return nil, refuseUnprocessable(CodeInvalidAccount, "the biller is not in "+country)
	}
	account := compactAccount(request.Account)
	if !accountPattern.MatchString(account) {
		return nil, refuseUnprocessable(CodeInvalidAccount, "an account is 3 to 40 letters, digits, dots, dashes or slashes")
	}
	invoice := ""
	if entry.requiresInvoice {
		invoice = strings.TrimSpace(request.InvoiceID)
		if invoice == "" {
			return nil, refuseUnprocessable(CodeInvoiceRequired, "this biller needs the invoice number")
		}
		if refusal := checkInvoice(invoice); refusal != nil {
			return nil, refusal
		}
	}
	amount, plan, refusal := entry.resolveAmount(request.Amount, request.AmountCurrency, request.AmountID)
	if refusal != nil {
		return nil, refusal
	}
	priced, plan2, refusal := entry.price(in.Settings, amount)
	if refusal != nil {
		return nil, refusal
	}
	var amountID int64
	if plan != nil {
		amountID = plan.id
	}
	details, _ := json.Marshal(billDetails{
		BillerID:      entry.id,
		Biller:        entry.nameAR,
		BillerEN:      entry.nameEN,
		Type:          entry.typ,
		Service:       entry.service,
		Country:       entry.country,
		Amount:        FormatAmount(amount),
		Currency:      entry.currency,
		Local:         entry.local,
		AmountID:      amountID,
		HasInvoice:    invoice != "",
		OrderMode:     plan2.mode(),
		OrderAmount:   FormatAmount(plan2.Amount),
		OrderCurrency: plan2.Currency,
		BufferPercent: bufferText(plan2.Buffer),
		USDRate:       rateText(in.Settings),
		USDRateSource: rateSource(in.Settings),
		ServiceFeeLYD: vouchers.FormatDinars(in.Settings.ServiceFee(KindBill)),
		TargetKeyID:   s.targetKeyID(),
		TargetDigest:  s.targetDigest(request.InstallationID, KindBill, account, invoice, entry.currency),
	})
	return &PreparedOrder{
		Kind:        KindBill,
		ItemKey:     OrderItemKey(KindBill, entry.id, amount, entry.currency, amountID),
		BrandKey:    KindBill,
		Name:        entry.statementName(amount, plan),
		Target:      MaskAccount(account),
		Details:     details,
		Prices:      priced,
		Receive:     Money{Amount: FormatAmount(amount), Currency: entry.currency},
		Approximate: entry.approximate,
		SupplierRef: strconv.FormatInt(entry.id, 10),
		Bill: &BillOrder{
			BillerID:   entry.id,
			BillerName: entry.nameEN,
			Account:    account,
			InvoiceID:  invoice,
			Amount:     plan2.Amount,
			Currency:   plan2.Currency,
			Local:      plan2.Local,
			Receive:    Money{Amount: FormatAmount(amount), Currency: entry.currency},
			AmountID:   amountID,
			Type:       entry.typ,
			Service:    entry.service,
		},
	}, nil
}

// readPhone reads a number typed for an operator's country (the country named
// in the request, when it names one, must be that country).
func readPhone(snap *snapshot, entry *operatorEntry, country, typed string) (Phone, *Refusal) {
	if country = strings.ToUpper(strings.TrimSpace(country)); country != "" && country != entry.country {
		return Phone{}, refuseUnprocessable(CodeInvalidPhone, "the operator is not in "+country)
	}
	phone, err := ParsePhone(typed, entry.country, snap.countries[entry.country].dial)
	if err != nil {
		return Phone{}, refuseUnprocessable(CodeInvalidPhone, err.Error())
	}
	return phone, nil
}

// Secrets are the values of an order that must never be kept or logged in full
// (the number, the account, the invoice), in every form a supplier might echo
// them: Redact hides them in any sentence.
func (p *PreparedOrder) Secrets() []string {
	var out []string
	if p.Airtime != nil {
		out = append(out, p.Airtime.Phone.Digits(), p.Airtime.Phone.National, p.Airtime.Phone.E164())
	}
	if p.Bill != nil {
		out = append(out, p.Bill.Account, p.Bill.InvoiceID)
	}
	return out
}

// airtimeDetails and billDetails are the write-once JSON of a ledger row.
type airtimeDetails struct {
	OperatorID      int64  `json:"operator_id"`
	Operator        string `json:"operator"`
	OperatorEN      string `json:"operator_en"`
	Country         string `json:"country"`
	Amount          string `json:"amount"`
	Currency        string `json:"currency"`
	Receive         string `json:"receive"`
	ReceiveCurrency string `json:"receive_currency"`
	Local           bool   `json:"local"`
	Approximate     bool   `json:"approximate"`
	// OrderMode, OrderAmount and OrderCurrency say how the order was placed with
	// Reloadly (usd or local, and for how much), so a statement is auditable.
	OrderMode     string `json:"order_mode"`
	OrderAmount   string `json:"order_amount"`
	OrderCurrency string `json:"order_currency"`
	BufferPercent string `json:"buffer_percent,omitempty"`
	// USDRate and USDRateSource are the dinars-per-dollar rate the sale was
	// priced at and where it came from (fulus or manual).
	USDRate       string `json:"usd_rate,omitempty"`
	USDRateSource string `json:"usd_rate_source,omitempty"`
	// ServiceFeeLYD is the flat service fee in the price, in dinars.
	ServiceFeeLYD string `json:"service_fee_lyd,omitempty"`
	// Dial are the calling codes the number was read with, and TargetDigest is a
	// keyed digest of the whole number (see Service.targetDigest): a replay of the
	// order is told from a different order that shares the masked number by
	// reading the number the same way and comparing digests, without the ledger
	// ever holding the number. TargetKeyID says which key made it.
	Dial         []string `json:"dial,omitempty"`
	TargetKeyID  string   `json:"target_kid,omitempty"`
	TargetDigest string   `json:"target_digest,omitempty"`
}

type billDetails struct {
	BillerID   int64  `json:"biller_id"`
	Biller     string `json:"biller"`
	BillerEN   string `json:"biller_en"`
	Type       string `json:"type"`
	Service    string `json:"service"`
	Country    string `json:"country"`
	Amount     string `json:"amount"`
	Currency   string `json:"currency"`
	Local      bool   `json:"local"`
	AmountID   int64  `json:"amount_id,omitempty"`
	HasInvoice bool   `json:"has_invoice"`
	// OrderMode, OrderAmount and OrderCurrency: see airtimeDetails.
	OrderMode     string `json:"order_mode"`
	OrderAmount   string `json:"order_amount"`
	OrderCurrency string `json:"order_currency"`
	BufferPercent string `json:"buffer_percent,omitempty"`
	USDRate       string `json:"usd_rate,omitempty"`
	USDRateSource string `json:"usd_rate_source,omitempty"`
	ServiceFeeLYD string `json:"service_fee_lyd,omitempty"`
	// TargetKeyID and TargetDigest: see airtimeDetails (the account and, when the
	// biller needs one, the invoice number).
	TargetKeyID  string `json:"target_kid,omitempty"`
	TargetDigest string `json:"target_digest,omitempty"`
}

// OrderItemKey is the ledger's item key of an order: airtime:<operator>:<amount>:<CUR>,
// bill:<biller>:<amount>:<CUR>, with the plan's id after it for a fixed biller.
func OrderItemKey(kind string, id int64, amount *big.Rat, currency string, amountID int64) string {
	key := fmt.Sprintf("%s:%d:%s:%s", kind, id, FormatAmount(amount), strings.ToUpper(strings.TrimSpace(currency)))
	if amountID > 0 {
		key += ":" + strconv.FormatInt(amountID, 10)
	}
	return key
}

// ItemKeyOf is the item key an order request would be booked under, from the
// request alone: a replayed request is compared with the row its key already
// names, whether or not the directory still lists the operator.
func ItemKeyOf(request OrderRequest) (string, *Refusal) {
	kind := strings.ToLower(strings.TrimSpace(request.Kind))
	amount, ok := ParseAmount(request.Amount)
	if !ok {
		return "", refuseUnprocessable(CodeInvalidAmount, "the amount is not a positive decimal number")
	}
	currency := strings.ToUpper(strings.TrimSpace(request.AmountCurrency))
	if len(currency) != 3 {
		return "", refuse(http.StatusBadRequest, CodeInvalidRequest, "amount_currency is required", nil)
	}
	switch kind {
	case KindAirtime:
		if request.OperatorID <= 0 {
			return "", refuse(http.StatusBadRequest, CodeInvalidRequest, "operator_id is required", nil)
		}
		return OrderItemKey(KindAirtime, request.OperatorID, amount, currency, 0), nil
	case KindBill:
		if request.BillerID <= 0 {
			return "", refuse(http.StatusBadRequest, CodeInvalidRequest, "biller_id is required", nil)
		}
		return OrderItemKey(KindBill, request.BillerID, amount, currency, max(request.AmountID, 0)), nil
	}
	return "", refuse(http.StatusBadRequest, CodeInvalidRequest, `kind must be "airtime" or "bill"`, nil)
}

// SameItem reports whether an item key built from a request alone (ItemKeyOf)
// names the same thing as the key of the ledger row the request's idempotency key
// already has. The row carries the plan its amount RESOLVED to ("bill:27:10000:XOF:3");
// a request that named the plan by its amount alone does not ("bill:27:10000:XOF"),
// and one that sent a plan id for a range biller (which has none) is as good as
// one that did not. Everything else (the kind, the operator or biller, the amount,
// its currency, a plan named on both sides) must be equal.
func SameItem(stored, requested string) bool {
	if stored == requested {
		return true
	}
	a, b := strings.Split(stored, ":"), strings.Split(requested, ":")
	if len(a) < 4 || len(a) > 5 || len(b) < 4 || len(b) > 5 || a[0] != KindBill {
		return false
	}
	for i := 0; i < 4; i++ {
		if a[i] != b[i] {
			return false
		}
	}
	return len(a) == 4 || len(b) == 4 || a[4] == b[4]
}

// MaskedTarget is the masked number or account an order request names, when it
// can be told without asking the supplier; false when it cannot (the operator is
// no longer listed, or the number does not parse).
func (s *Service) MaskedTarget(request OrderRequest) (string, bool) {
	if s == nil {
		return "", false
	}
	if strings.ToLower(strings.TrimSpace(request.Kind)) == KindBill {
		account := compactAccount(request.Account)
		return MaskAccount(account), accountPattern.MatchString(account)
	}
	s.mu.RLock()
	snap := s.snap
	s.mu.RUnlock()
	if snap == nil {
		return "", false
	}
	entry, ok := snap.operators[request.OperatorID]
	if !ok {
		return "", false
	}
	// Recognising a number is not validating it (see parsePhone).
	phone, err := parsePhone(request.Phone, entry.country, snap.countries[entry.country].dial, false)
	if err != nil {
		return "", false
	}
	return phone.Masked(), true
}

// compactAccount removes the spaces a person types into an account number.
func compactAccount(account string) string {
	return strings.Map(func(r rune) rune {
		if r == ' ' || r == '\t' || r == 0x00a0 {
			return -1
		}
		return r
	}, strings.TrimSpace(account))
}

func checkInvoice(invoice string) *Refusal {
	invoice = strings.TrimSpace(invoice)
	if invoice == "" {
		return refuseUnprocessable(CodeInvoiceRequired, "this biller needs the invoice number")
	}
	if !invoicePattern.MatchString(invoice) {
		return refuseUnprocessable(CodeInvalidInvoice, "an invoice number is 1 to 24 letters, digits, dashes, underscores or slashes")
	}
	return nil
}

// directoryForSale is the directory a quote or an order may be priced from: the
// snapshot, unless the supplier has not been read successfully for too long to
// trust its prices (the dollar rate and commissions move).
func (s *Service) directoryForSale(ctx context.Context) (*snapshot, *Refusal) {
	snap, refusal := s.directoryFor(ctx)
	if refusal != nil {
		return nil, refusal
	}
	if s.isStale() {
		if s.Every("stale", time.Minute) {
			s.logger().Error("the services directory is too old to sell from; quotes and orders are refused until the supplier is read again",
				"stale_after", s.staleAfter().String())
		}
		return nil, refuseUnavailable(ReasonStale)
	}
	return snap, nil
}

// directoryFor is the directory snapshot, or the refusal that says it is not
// there.
func (s *Service) directoryFor(ctx context.Context) (*snapshot, *Refusal) {
	if !s.Configured() {
		return nil, refuse(http.StatusServiceUnavailable, CodeServicesUnconfigured, "this relay sells no top-up or bill payments", nil)
	}
	snap, err := s.current(ctx)
	if err != nil {
		s.logger().Warn("the services directory is not available", "error", err)
		return nil, refuseUnavailable(ReasonDirectoryUnavailable)
	}
	return snap, nil
}

// --- amounts ---

// resolveAmount reads an amount for an operator and checks the operator sells it.
func (e *operatorEntry) resolveAmount(raw, currency string) (*big.Rat, *Refusal) {
	amount, ok := ParseAmount(raw)
	if !ok {
		return nil, refuseUnprocessable(CodeInvalidAmount, "the amount is not a positive decimal number")
	}
	if currency = strings.ToUpper(strings.TrimSpace(currency)); currency != "" && currency != e.currency {
		return nil, refuseUnprocessable(CodeInvalidAmount, "this operator takes amounts in "+e.currency)
	}
	if e.fixed {
		// What the operator lists is what it sells, in whatever decimals it lists it.
		if !e.listed(amount) {
			return nil, refuseUnprocessable(CodeAmountNotOffered, "this operator does not sell that amount")
		}
		return amount, nil
	}
	if !amountFitsCurrency(amount, e.currency) {
		return nil, refuseDecimals(e.currency)
	}
	if amount.Cmp(e.min) < 0 || amount.Cmp(e.max) > 0 {
		return nil, refuse(http.StatusUnprocessableEntity, CodeAmountOutOfRange, "the amount is outside what this operator takes",
			map[string]any{"min": FormatAmount(e.min), "max": FormatAmount(e.max)})
	}
	if !e.accepts(amount) {
		return nil, refuseUnprocessable(CodeAmountNotOffered, "this operator does not sell that amount")
	}
	return amount, nil
}

func (e *operatorEntry) listed(amount *big.Rat) bool {
	for _, t := range e.tiles {
		if sameAmount(t.amount, amount) {
			return true
		}
	}
	return false
}

// receiveFor is what the recipient is credited for an amount.
func (e *operatorEntry) receiveFor(amount *big.Rat) *big.Rat {
	for _, t := range e.tiles {
		if sameAmount(t.amount, amount) {
			return t.receive
		}
	}
	if e.local || !e.approximate {
		return amount
	}
	if mapped, ok := mappedReceive(e.raw, amount); ok {
		return mapped
	}
	return roundDecimals(new(big.Rat).Mul(amount, positiveRat(e.raw.FX.Rate)), 2)
}

// price is what an amount of the operator costs the shop and its customer, and
// how it is ordered from Reloadly.
func (e *operatorEntry) price(settings vouchers.Settings, amount *big.Rat) (Prices, orderPlan, *Refusal) {
	plan, ok := e.plan(settings, amount)
	if !ok {
		return Prices{}, orderPlan{}, refuseUnavailable(ReasonCostUnknown)
	}
	prices, refusal := pricedOrRefusal(settings, KindAirtime, plan.Cost)
	return prices, plan, refusal
}

func (e *operatorEntry) statementName(amount *big.Rat) string {
	return airtimeTitle + nameSep + e.nameAR + nameSep + FormatAmountGrouped(amount) + " " + CurrencyName(e.currency)
}

// resolveAmount reads an amount for a biller, and the plan of a fixed one.
func (b *billerEntry) resolveAmount(raw, currency string, amountID int64) (*big.Rat, *planEntry, *Refusal) {
	amount, ok := ParseAmount(raw)
	if !ok {
		return nil, nil, refuseUnprocessable(CodeInvalidAmount, "the amount is not a positive decimal number")
	}
	if currency = strings.ToUpper(strings.TrimSpace(currency)); currency != "" && currency != b.currency {
		return nil, nil, refuseUnprocessable(CodeInvalidAmount, "this biller takes amounts in "+b.currency)
	}
	if b.fixed {
		var found *planEntry
		for i := range b.plans {
			plan := &b.plans[i]
			if !sameAmount(plan.amount, amount) || (amountID > 0 && plan.id != amountID) {
				continue
			}
			if found != nil {
				return nil, nil, refuseUnprocessable(CodeAmountNotOffered, "several plans cost that amount: name the plan")
			}
			found = plan
		}
		if found == nil {
			return nil, nil, refuseUnprocessable(CodeAmountNotOffered, "this biller has no plan at that amount")
		}
		return amount, found, nil
	}
	if amountID > 0 {
		return nil, nil, refuseUnprocessable(CodeAmountNotOffered, "this biller has no plans")
	}
	if !amountFitsCurrency(amount, b.currency) {
		return nil, nil, refuseDecimals(b.currency)
	}
	if amount.Cmp(b.min) < 0 || amount.Cmp(b.max) > 0 {
		return nil, nil, refuse(http.StatusUnprocessableEntity, CodeAmountOutOfRange, "the amount is outside what this biller takes",
			map[string]any{"min": FormatAmount(b.min), "max": FormatAmount(b.max)})
	}
	return amount, nil, nil
}

func (b *billerEntry) price(settings vouchers.Settings, amount *big.Rat) (Prices, orderPlan, *Refusal) {
	plan, ok := b.plan(settings, amount)
	if !ok {
		return Prices{}, orderPlan{}, refuseUnavailable(ReasonCostUnknown)
	}
	prices, refusal := pricedOrRefusal(settings, KindBill, plan.Cost)
	return prices, plan, refusal
}

// bufferText writes a buffer percentage for the ledger, "" when there is none.
func bufferText(buffer *big.Rat) string {
	if buffer == nil {
		return ""
	}
	return FormatAmount(buffer)
}

func (b *billerEntry) statementName(amount *big.Rat, plan *planEntry) string {
	name := billTitle + " " + BillTypeAR(b.typ) + nameSep + b.nameAR
	if plan != nil && plan.descAR != "" {
		name += nameSep + plan.descAR
	}
	return name + nameSep + FormatAmountGrouped(amount) + " " + CurrencyName(b.currency)
}

// pricedOrRefusal prices a cost, or says why it cannot be: no dollar rate, or a
// cost the catalog row does not allow to be worked out.
func pricedOrRefusal(settings vouchers.Settings, kind string, cost *big.Rat) (Prices, *Refusal) {
	if cost == nil {
		return Prices{}, refuseUnavailable(ReasonCostUnknown)
	}
	prices, err := PriceCost(settings, kind, cost)
	switch {
	case errors.Is(err, ErrRateUnset):
		return Prices{}, refuseUnavailable(ReasonRateUnset)
	case err != nil:
		return Prices{}, refuseUnavailable(ReasonCostUnknown)
	}
	return prices, nil
}

// rateText and rateSource name the dollar rate a sale was priced at.
func rateText(settings vouchers.Settings) string {
	rate, _ := settings.EffectiveUSDRate()
	if rate == nil {
		return ""
	}
	return strings.TrimRight(strings.TrimRight(rate.FloatString(6), "0"), ".")
}

func rateSource(settings vouchers.Settings) string {
	_, source := settings.EffectiveUSDRate()
	return source
}
