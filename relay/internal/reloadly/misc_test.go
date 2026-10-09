package reloadly

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestATransportErrorNamesTheProductAndTheOperation(t *testing.T) {
	err := &TransportError{Product: "topups", Op: "make top-up", Err: errors.New("connection reset"), Sent: true}
	if got := err.Error(); got != "reloadly: topups: make top-up: connection reset" {
		t.Fatalf("Error() = %q", got)
	}
	if !errors.Is(error(err), err.Err) {
		t.Fatal("the cause is not unwrapped")
	}
	bare := &TransportError{Op: "x", Err: errors.New("y")}
	if bare.Error() != "reloadly: x: y" {
		t.Fatalf("Error() = %q", bare.Error())
	}
}

func TestRetryAfterAcceptsADate(t *testing.T) {
	at := time.Now().Add(90 * time.Second).UTC().Format(http.TimeFormat)
	if got := parseRetryAfter(at); got < 80*time.Second || got > 91*time.Second {
		t.Fatalf("RetryAfter(%q) = %v", at, got)
	}
	for _, bad := range []string{"", "soon", "-5", "Wed, 21 Oct 2015 07:28:00 GMT"} {
		if got := parseRetryAfter(bad); got != 0 {
			t.Errorf("RetryAfter(%q) = %v", bad, got)
		}
	}
}

func TestNumString(t *testing.T) {
	if Num("0.19785").String() != "0.19785" || Text("x").String() != "x" {
		t.Fatal("String")
	}
}

func TestRedeemCodesAcceptASingleObject(t *testing.T) {
	f := newFake(t)
	f.always("giftcards", ok(`{"cardNumber":"AAAA-BBBB","pinCode":"1234","redemptionUrl":null}`))
	codes, err := f.client().GiftRedeemCodes(context.Background(), 5)
	if err != nil || len(codes) != 1 || codes[0].CardNumber != "AAAA-BBBB" {
		t.Fatalf("codes = %+v, err = %v", codes, err)
	}
	g := newFake(t)
	g.always("giftcards", ok(`[]`))
	if codes, err := g.client().GiftRedeemCodes(context.Background(), 5); err != nil || len(codes) != 0 {
		t.Fatalf("an empty list is no codes yet: %+v, %v", codes, err)
	}
}

func TestFindTopupsWithoutAnIdentifierClipsToTheWindow(t *testing.T) {
	f := newFake(t)
	f.always("topups", ok(fixture(t, "topup_report_page.json")))
	c := f.client()
	at := time.Date(2026, 10, 8, 1, 45, 35, 0, time.UTC)
	rows, err := c.FindTopups(context.Background(), "", at.Add(-time.Minute), at.Add(time.Minute))
	if err != nil || len(rows) != 1 {
		t.Fatalf("rows = %+v, err = %v", rows, err)
	}
	rows, err = c.FindTopups(context.Background(), "", at.Add(time.Second), at.Add(time.Minute))
	if err != nil || len(rows) != 0 {
		t.Fatalf("a window that starts after the top-up must not return it: %+v, %v", rows, err)
	}
	query := parseQueryDecoded(t, f.callsTo("topups")[0].query)
	if query["startDate"] != "2026-10-06 13:44:35" || query["endDate"] != "2026-10-09 13:46:35" {
		t.Fatalf("query = %v", query)
	}
}

func TestBillCostConvertsAFlatFeeByItsCurrency(t *testing.T) {
	biller := billerByID(t, 26) // fee 117.5 XOF locally, 0 USD internationally, rate 470
	local := mustRat(t, "1000")
	for _, test := range []struct {
		label    string
		currency string
		want     string
	}{
		{"fee in the local currency is divided by the rate", "XOF", "2.37766"},
		{"fee in the account currency is not", "USD", "119.62766"},
		{"fee with no currency follows the order (local)", "", "2.37766"},
	} {
		changed := biller
		changed.LocalTransactionFeeCurrencyCode = test.currency
		got, ok := BillCost(changed, local, true)
		sameCost(t, test.label, got, ok, test.want)
	}
	// An international fee named in the local currency is converted too.
	changed := biller
	changed.InternationalTransactionFee = "470"
	changed.InternationalTransactionFeeCurrencyCode = "XOF"
	got, ok := BillCost(changed, mustRat(t, "2.13"), false)
	sameCost(t, "international fee in XOF", got, ok, "2.95960")
}

func TestConfigDefaultsAreApplied(t *testing.T) {
	c, err := New(Config{ClientID: "a", ClientSecret: "b"})
	if err != nil {
		t.Fatal(err)
	}
	if c.timeout != defaultTimeout || c.purchaseTimeout != defaultPurchaseTimeout || c.backoff != defaultRetryBackoff ||
		cap(c.sem) != defaultMaxConcurrent || c.http == nil || c.clock == nil {
		t.Fatalf("defaults = %+v", c)
	}
	// The private HTTP client must never follow a redirect: a POST would become a GET.
	if err := c.http.CheckRedirect(nil, nil); !errors.Is(err, http.ErrUseLastResponse) {
		t.Fatalf("CheckRedirect = %v", err)
	}
	f := newFake(t)
	f.always("topups", reply{status: http.StatusFound, header: map[string]string{"Location": "http://example.invalid/"}})
	_, err = f.client().TopupBalance(context.Background())
	var api *APIError
	if !errors.As(err, &api) || api.Status != http.StatusFound || strings.Contains(api.Error(), "invalid") {
		t.Fatalf("a redirect must be an error, not followed: %v", err)
	}
}
