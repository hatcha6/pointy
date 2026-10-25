package dafa

// Local bank cards, without Dafa's page.
//
// Dafa's "local bank cards" method is Moamalat's LightBox wrapped twice: the
// page at payment_page_url (localbankcards.dafa.ly) fetches a session Dafa
// has already signed with the company's Moamalat merchant secret, hands it to
// Moamalat's script, and posts Moamalat's receipt back for Dafa to confirm.
// The relay does the two Dafa steps itself, so the card app can collect the
// card in its own form and talk to Moamalat directly
// (tools/moamalat-capture/PAYFORM_SELF_HOSTED.md §6a, "Option A").
//
// These endpoints are the ones Dafa's own page calls. They are not in Dafa's
// API docs and take no API key: a payment's id is the only handle, the same
// as the page's address. The relay never sends X-API-Key there, and it still
// believes only GET /payments/{id} with its own key: a confirm here is a
// nudge, like the webhook.
//
// Read from the page's script (2026-10-25):
//   - GET  {gateway}/{payment id}/data answers the session: MID, TID,
//     AmountTrxn (dirhams), TrxDateTime, SecureHash, a MerchantReference of
//     "<payment id>-<unix seconds>" minted on every read, Environment
//     ("test" or not), IsConfirmed.
//   - POST {gateway}/{merchant reference}/confirm takes Moamalat's
//     completeCallback object as it is and answers {is_confirmed}. The page
//     retries it, then polls it with an empty body for half an hour; Dafa
//     also confirms on its own "within minutes" when the page never does.

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// DefaultCardGatewayURL is where Dafa's card page reads sessions from.
const DefaultCardGatewayURL = "https://tyrian-ant.sadeem-factory.com/api/v1/payment-gateways/moamalat"

// CardSession is a Moamalat checkout Dafa signed for one payment.
type CardSession struct {
	MID               string
	TID               string
	MerchantReference string
	// TrxDateTime is yyyyMMddHHmm, the time the hash was made with.
	TrxDateTime string
	SecureHash  string
	// Amount is in dirhams, Moamalat's unit (1 dinar = 1000).
	Amount int64
	// Test says the session is on Moamalat's test gateway.
	Test      bool
	Confirmed bool
}

// CardReceipt is Moamalat's completeCallback object, which Dafa's confirm
// takes as it is. Moamalat signs it; Dafa holds the key that checks it.
type CardReceipt struct {
	TxnDate            string `json:"TxnDate"`
	SystemReference    string `json:"SystemReference"`
	NetworkReference   string `json:"NetworkReference"`
	MerchantReference  string `json:"MerchantReference"`
	Amount             string `json:"Amount"`
	Currency           string `json:"Currency"`
	PaidThrough        string `json:"PaidThrough"`
	PayerAccount       string `json:"PayerAccount"`
	PayerName          string `json:"PayerName"`
	ProviderSchemeName string `json:"ProviderSchemeName"`
	SecureHash         string `json:"SecureHash"`
}

// CardGatewayConfig is how the relay reaches Dafa's card gateway.
type CardGatewayConfig struct {
	BaseURL    string
	HTTPClient *http.Client
	Timeout    time.Duration
}

// CardGateway talks to the endpoints behind Dafa's card page.
type CardGateway struct {
	baseURL string
	http    *http.Client
	timeout time.Duration
}

// NewCardGateway builds the client. Like New, it never follows a redirect.
func NewCardGateway(config CardGatewayConfig) *CardGateway {
	baseURL := strings.TrimRight(strings.TrimSpace(config.BaseURL), "/")
	if baseURL == "" {
		baseURL = DefaultCardGatewayURL
	}
	timeout := config.Timeout
	if timeout <= 0 {
		timeout = defaultTimeout
	}
	var httpClient http.Client
	if config.HTTPClient != nil {
		httpClient = *config.HTTPClient
	} else {
		httpClient = http.Client{Timeout: timeout}
	}
	httpClient.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return &CardGateway{baseURL: baseURL, http: &httpClient, timeout: timeout}
}

type cardSessionBody struct {
	MID               json.RawMessage `json:"MID"`
	TID               json.RawMessage `json:"TID"`
	MerchantReference string          `json:"MerchantReference"`
	TrxDateTime       string          `json:"TrxDateTime"`
	SecureHash        string          `json:"SecureHash"`
	AmountTrxn        json.Number     `json:"AmountTrxn"`
	Environment       string          `json:"Environment"`
	IsConfirmed       bool            `json:"IsConfirmed"`
}

// Session reads the signed checkout for a payment. Each read mints a new
// merchant reference.
func (g *CardGateway) Session(ctx context.Context, paymentID string) (CardSession, error) {
	id := strings.TrimSpace(paymentID)
	if id == "" || strings.Contains(id, "/") {
		return CardSession{}, &APIError{Status: http.StatusBadRequest, Message: "no payment id to read a card session for"}
	}
	body, err := g.call(ctx, http.MethodGet, "/"+url.PathEscape(id)+"/data", nil)
	if err != nil {
		return CardSession{}, err
	}
	var decoded cardSessionBody
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	if err := decoder.Decode(&decoded); err != nil {
		return CardSession{}, &APIError{Status: http.StatusOK, Message: "unreadable card session: " + err.Error()}
	}
	amount, err := decoded.AmountTrxn.Int64()
	session := CardSession{
		MID:               rawText(decoded.MID),
		TID:               rawText(decoded.TID),
		MerchantReference: strings.TrimSpace(decoded.MerchantReference),
		TrxDateTime:       strings.TrimSpace(decoded.TrxDateTime),
		SecureHash:        strings.TrimSpace(decoded.SecureHash),
		Amount:            amount,
		Test:              strings.EqualFold(strings.TrimSpace(decoded.Environment), "test"),
		Confirmed:         decoded.IsConfirmed,
	}
	if session.Confirmed {
		return session, nil
	}
	if err != nil || amount <= 0 || session.MID == "" || session.TID == "" || len(session.TrxDateTime) != 12 ||
		len(session.SecureHash) != 64 || !strings.HasPrefix(session.MerchantReference, id+"-") {
		return CardSession{}, &APIError{Status: http.StatusOK, Message: "incomplete card session"}
	}
	return session, nil
}

// Complete hands Moamalat's receipt to Dafa, which checks its signature and
// marks the payment paid. confirmed is Dafa's answer; the relay still reads
// the payment back before it believes it.
func (g *CardGateway) Complete(ctx context.Context, receipt CardReceipt) (confirmed bool, err error) {
	reference := strings.TrimSpace(receipt.MerchantReference)
	if reference == "" || strings.Contains(reference, "/") {
		return false, &APIError{Status: http.StatusBadRequest, Message: "no merchant reference to confirm"}
	}
	body, err := g.call(ctx, http.MethodPost, "/"+url.PathEscape(reference)+"/confirm", receipt)
	if err != nil {
		return false, err
	}
	var decoded struct {
		IsConfirmed bool `json:"is_confirmed"`
	}
	if err := json.Unmarshal(body, &decoded); err != nil {
		return false, &APIError{Status: http.StatusOK, Message: "unreadable confirm answer: " + err.Error()}
	}
	return decoded.IsConfirmed, nil
}

func (g *CardGateway) call(ctx context.Context, method, path string, payload any) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, g.timeout)
	defer cancel()
	var reader io.Reader
	if payload != nil {
		encoded, err := json.Marshal(payload)
		if err != nil {
			return nil, &TransportError{Err: err}
		}
		reader = bytes.NewReader(encoded)
	}
	request, err := http.NewRequestWithContext(ctx, method, g.baseURL+path, reader)
	if err != nil {
		return nil, &TransportError{Err: err}
	}
	if payload != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	request.Header.Set("Accept", "application/json")
	response, err := g.http.Do(request)
	if err != nil {
		return nil, &TransportError{Err: err}
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes))
	if err != nil {
		return nil, &TransportError{Err: err}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, decodeAPIError(response.StatusCode, body)
	}
	return body, nil
}

// rawText reads a field the page treats as text but may come as a number.
func rawText(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return strings.TrimSpace(text)
	}
	return strings.TrimSpace(string(raw))
}
