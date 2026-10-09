package reloadly

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Biller types as Reloadly writes them in Biller.Type.
const (
	BillerElectricity = "ELECTRICITY_BILL_PAYMENT"
	BillerWater       = "WATER_BILL_PAYMENT"
	BillerTV          = "TV_BILL_PAYMENT"
	BillerInternet    = "INTERNET_BILL_PAYMENT"
	BillerToll        = "TOLL_HIGHWAY_BILL_PAYMENT"
)

// Biller is a utility company Reloadly can pay (an electricity distributor, a TV
// operator…). Like operators, billers take amounts in two currencies: the local
// one (LocalTransactionCurrencyCode) when LocalAmountSupported, and the
// account's (InternationalTransactionCurrencyCode, USD) when
// InternationalAmountSupported, related by FX.Rate (local units per account
// unit). Discounts and fees differ per currency: see BillCost.
//
// A FIXED biller sells listed plans: the payment names one by AmountID, and the
// local and international plan lists share their ids.
type Biller struct {
	ID               int64            `json:"id"`
	Name             string           `json:"name"`
	CountryCode      string           `json:"countryCode"`
	CountryName      string           `json:"countryName"`
	Type             string           `json:"type"`
	ServiceType      string           `json:"serviceType"`
	DenominationType DenominationType `json:"denominationType"`
	RequiresInvoice  bool             `json:"requiresInvoice"`
	FX               FX               `json:"fx"`

	LocalAmountSupported            bool           `json:"localAmountSupported"`
	LocalTransactionCurrencyCode    string         `json:"localTransactionCurrencyCode"`
	MinLocalTransactionAmount       Num            `json:"minLocalTransactionAmount"`
	MaxLocalTransactionAmount       Num            `json:"maxLocalTransactionAmount"`
	LocalTransactionFee             Num            `json:"localTransactionFee"`
	LocalTransactionFeePercentage   Num            `json:"localTransactionFeePercentage"`
	LocalTransactionFeeCurrencyCode string         `json:"localTransactionFeeCurrencyCode"`
	LocalDiscountPercentage         Num            `json:"localDiscountPercentage"`
	LocalFixedAmounts               []BillerAmount `json:"localFixedAmounts"`

	InternationalAmountSupported            bool           `json:"internationalAmountSupported"`
	InternationalTransactionCurrencyCode    string         `json:"internationalTransactionCurrencyCode"`
	MinInternationalTransactionAmount       Num            `json:"minInternationalTransactionAmount"`
	MaxInternationalTransactionAmount       Num            `json:"maxInternationalTransactionAmount"`
	InternationalTransactionFee             Num            `json:"internationalTransactionFee"`
	InternationalTransactionFeePercentage   Num            `json:"internationalTransactionFeePercentage"`
	InternationalTransactionFeeCurrencyCode string         `json:"internationalTransactionFeeCurrencyCode"`
	InternationalDiscountPercentage         Num            `json:"internationalDiscountPercentage"`
	InternationalFixedAmounts               []BillerAmount `json:"internationalFixedAmounts"`
}

// BillerAmount is one plan of a FIXED biller.
type BillerAmount struct {
	ID          int64  `json:"id"`
	Amount      Num    `json:"amount"`
	Description string `json:"description"`
}

// UnmarshalJSON also reads the local currency code under the spelling in
// Reloadly's published schema ("localTransactionCurencyCode"); the live API
// writes it correctly.
func (b *Biller) UnmarshalJSON(data []byte) error {
	type plain Biller
	aux := struct {
		*plain
		Misspelled string `json:"localTransactionCurencyCode"`
	}{plain: (*plain)(b)}
	if err := json.Unmarshal(data, &aux); err != nil {
		return err
	}
	if b.LocalTransactionCurrencyCode == "" {
		b.LocalTransactionCurrencyCode = aux.Misspelled
	}
	return nil
}

// PayRequest is one utility payment.
type PayRequest struct {
	BillerID int64
	// SubscriberAccountNumber is the customer's meter, account or card number.
	SubscriberAccountNumber string
	// Amount is in the biller's local currency when UseLocalAmount is set, else in
	// the account currency (USD). A FIXED biller takes its plan's amount in the
	// matching list.
	Amount         Num
	UseLocalAmount bool
	// AmountID names the plan of a FIXED biller.
	AmountID int64
	// ReferenceID is unique to the payment, at most MaxIdentifierLength
	// characters. Reloadly records it on every accepted payment and refuses a
	// second with REFERENCE_ID_ALREADY_USED (even after a REFUNDED one). Of
	// concurrent duplicates one runs and the others get a 500
	// TRANSACTION_CANNOT_BE_PROCESSED_AT_THE_MOMENT.
	ReferenceID string
	// InvoiceID is the invoice of billers that RequireInvoice.
	InvoiceID string
}

type payWire struct {
	SubscriberAccountNumber string   `json:"subscriberAccountNumber"`
	Amount                  Num      `json:"amount"`
	AmountID                int64    `json:"amountId,omitempty"`
	BillerID                int64    `json:"billerId"`
	UseLocalAmount          bool     `json:"useLocalAmount"`
	ReferenceID             string   `json:"referenceId"`
	AdditionalInfo          *payInfo `json:"additionalInfo,omitempty"`
}

type payInfo struct {
	InvoiceID string `json:"invoiceId"`
}

func (r PayRequest) wire() (payWire, error) {
	if r.BillerID <= 0 {
		return payWire{}, fmt.Errorf("%w: a biller id is required", ErrInvalidRequest)
	}
	if strings.TrimSpace(r.SubscriberAccountNumber) == "" {
		return payWire{}, fmt.Errorf("%w: a subscriber account number is required", ErrInvalidRequest)
	}
	if err := requirePositive("amount", r.Amount); err != nil {
		return payWire{}, err
	}
	if err := requireIdentifier("referenceId", r.ReferenceID); err != nil {
		return payWire{}, err
	}
	wire := payWire{
		SubscriberAccountNumber: strings.TrimSpace(r.SubscriberAccountNumber),
		Amount:                  r.Amount,
		AmountID:                r.AmountID,
		BillerID:                r.BillerID,
		UseLocalAmount:          r.UseLocalAmount,
		ReferenceID:             r.ReferenceID,
	}
	if invoice := strings.TrimSpace(r.InvoiceID); invoice != "" {
		wire.AdditionalInfo = &payInfo{InvoiceID: invoice}
	}
	return wire, nil
}

// PayResult is the answer to a payment: it was accepted, and its outcome comes
// later. Status is PROCESSING in practice; the sandbox settles within seconds,
// Reloadly promises a final status by FinalStatusAvailabilityAt (a day after
// submission).
type PayResult struct {
	ID                        int64  `json:"id"`
	Status                    Status `json:"status"`
	ReferenceID               string `json:"referenceId"`
	Code                      string `json:"code"`
	Message                   string `json:"message"`
	SubmittedAt               Time   `json:"submittedAt"`
	FinalStatusAvailabilityAt Time   `json:"finalStatusAvailabilityAt"`
}

// Payment is a utility payment as Reloadly records it: one transaction read, or
// a row of the transaction list. Code and Message describe the state
// (PAYMENT_PROCESSED_SUCCESSFULLY, UNABLE_TO_PROCESS_PAYMENT…).
type Payment struct {
	Code        string             `json:"code"`
	Message     string             `json:"message"`
	Transaction PaymentTransaction `json:"transaction"`
}

// PaymentTransaction is the transaction inside a Payment. Amount is in
// AmountCurrencyCode (local or USD as ordered); Fee and Discount are in the
// account currency; what the account was debited is Balance.Cost, 0 for a
// REFUNDED payment (whose Fee still shows what it would have been).
type PaymentTransaction struct {
	ID                         int64       `json:"id"`
	Status                     Status      `json:"status"`
	ReferenceID                string      `json:"referenceId"`
	Amount                     Num         `json:"amount"`
	AmountCurrencyCode         string      `json:"amountCurrencyCode"`
	DeliveryAmount             Num         `json:"deliveryAmount"`
	DeliveryAmountCurrencyCode string      `json:"deliveryAmountCurrencyCode"`
	Fee                        Num         `json:"fee"`
	FeeCurrencyCode            string      `json:"feeCurrencyCode"`
	Discount                   Num         `json:"discount"`
	DiscountCurrencyCode       string      `json:"discountCurrencyCode"`
	SubmittedAt                Time        `json:"submittedAt"`
	Balance                    BalanceInfo `json:"balanceInfo"`
	Bill                       BillDetails `json:"billDetails"`
}

// BillDetails says what was paid. PinDetails carries the prepaid token of
// PREPAID electricity (null in the sandbox).
type BillDetails struct {
	Type              string         `json:"type"`
	BillerID          int64          `json:"billerId"`
	BillerName        string         `json:"billerName"`
	BillerCountryCode string         `json:"billerCountryCode"`
	BillerReferenceID Text           `json:"billerReferenceId"`
	ServiceType       string         `json:"serviceType"`
	CompletedAt       Time           `json:"completedAt"`
	Subscriber        BillSubscriber `json:"subscriberDetails"`
	PinDetails        BillPin        `json:"pinDetails"`
}

// BillSubscriber is the customer the payment went to.
type BillSubscriber struct {
	InvoiceID     Text `json:"invoiceId"`
	AccountNumber Text `json:"accountNumber"`
}

// BillPin is the prepaid token a PREPAID biller hands back, with its notes.
type BillPin struct {
	Token Text `json:"token"`
	Info1 Text `json:"info1"`
	Info2 Text `json:"info2"`
	Info3 Text `json:"info3"`
}

// Billers reads every biller (all pages).
func (c *Client) Billers(ctx context.Context) ([]Biller, error) {
	r := c.get(c.utilities, "list billers", "/billers", nil)
	return listAll(ctx, c, r, func(b *Biller) string { return idKey(b.ID) })
}

// Pay pays a utility bill.
//
// It makes exactly ONE attempt and never retries: Reloadly's duplicate check on
// ReferenceID would not stop a retry that overlaps a slow first attempt. A
// failure is returned as it is; Definite says whether nothing can have been
// paid, and anything else must be read back with FindPayments before the money
// is given back. A successful call only means the payment was accepted: it is
// PROCESSING until Payment says otherwise, and may end FAILED or REFUNDED, which
// costs nothing (Status.Unsuccessful).
func (c *Client) Pay(ctx context.Context, req PayRequest) (PayResult, error) {
	wire, err := req.wire()
	if err != nil {
		return PayResult{}, err
	}
	r := c.post(c.utilities, "pay bill", "/pay", wire)
	raw, err := c.do(ctx, r)
	if err != nil {
		return PayResult{}, err
	}
	var result PayResult
	if err := decode(r, raw, &result); err != nil {
		return PayResult{}, err
	}
	if result.ID == 0 {
		return PayResult{}, &TransportError{
			Product: r.product.name, Op: r.op, Err: errors.New("answer without an id"), Sent: true,
		}
	}
	return result, nil
}

// Payment reads one payment by its Reloadly id: its state, what it cost and, for
// prepaid billers, the token.
func (c *Client) Payment(ctx context.Context, id int64) (Payment, error) {
	if id <= 0 {
		return Payment{}, fmt.Errorf("%w: a payment id is required", ErrInvalidRequest)
	}
	r := c.get(c.utilities, "read payment", "/transactions/"+strconv.FormatInt(id, 10), nil)
	raw, err := c.do(ctx, r)
	if err != nil {
		return Payment{}, err
	}
	var payment Payment
	if err := decode(r, raw, &payment); err != nil {
		return Payment{}, err
	}
	return payment, nil
}

// FindPayments looks payments up by the referenceId they were placed with,
// which is how a payment whose answer was lost is found. It returns every match,
// oldest first. A payment Reloadly rejected leaves no record.
//
// from and to bound the search and may be zero; see FindGiftTransactions.
func (c *Client) FindPayments(ctx context.Context, referenceID string, from, to time.Time) ([]Payment, error) {
	query := url.Values{}
	referenceID = strings.TrimSpace(referenceID)
	if referenceID != "" {
		query.Set("referenceId", referenceID)
	}
	addWindow(query, from, to)
	r := c.get(c.utilities, "find payments", "/transactions", query)
	rows, err := listAll(ctx, c, r, func(p *Payment) string { return idKey(p.Transaction.ID) })
	if err != nil {
		return nil, err
	}
	if referenceID != "" {
		return rows, nil
	}
	kept := rows[:0]
	for _, row := range rows {
		if inWindow(row.Transaction.SubmittedAt.Time, from, to) {
			kept = append(kept, row)
		}
	}
	return kept, nil
}

// UtilityBalance reads the company's balance as the utility service sees it
// (the same USD account as the other two).
func (c *Client) UtilityBalance(ctx context.Context) (Balance, error) {
	return c.balance(ctx, c.utilities)
}
