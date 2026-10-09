package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"regexp"
	"strings"
	"testing"
)

func keyedService(t *testing.T, key string) *Service {
	t.Helper()
	service := fixtureService(t, func(cfg *Config) { cfg.TargetKey = []byte(key) })
	return service
}

func TestTheTargetDigestIsKeyedSaltedAndShort(t *testing.T) {
	a, b := keyedService(t, "key-a"), keyedService(t, "key-b")
	digest := a.targetDigest("shop-1", KindAirtime, "22370123456", "", "XOF")
	if !regexp.MustCompile(`^[0-9a-f]{16}$`).MatchString(digest) {
		t.Fatalf("16 hex digits: %q", digest)
	}
	if again := a.targetDigest("shop-1", KindAirtime, "22370123456", "", "xof"); again != digest {
		t.Fatalf("deterministic, and the currency's case does not matter: %s %s", digest, again)
	}
	for name, other := range map[string]string{
		"another shop":     a.targetDigest("shop-2", KindAirtime, "22370123456", "", "XOF"),
		"another number":   a.targetDigest("shop-1", KindAirtime, "22371123456", "", "XOF"),
		"another currency": a.targetDigest("shop-1", KindAirtime, "22370123456", "", "USD"),
		"another kind":     a.targetDigest("shop-1", KindBill, "22370123456", "", "XOF"),
		"an invoice":       a.targetDigest("shop-1", KindAirtime, "22370123456", "2024-1", "XOF"),
		"another key":      b.targetDigest("shop-1", KindAirtime, "22370123456", "", "XOF"),
	} {
		if other == digest {
			t.Errorf("%s leaves the same digest", name)
		}
	}
	// Never a plain hash: the number alone is not enough to make it.
	plain := sha256.Sum256([]byte("22370123456"))
	if strings.HasPrefix(hex.EncodeToString(plain[:]), digest) {
		t.Fatal("the digest is not a plain hash of the number")
	}
	// The field separators cannot be forged by moving a character.
	if a.targetDigest("s", KindBill, "ab", "c", "XOF") == a.targetDigest("s", KindBill, "a", "bc", "XOF") {
		t.Fatal("what is account and what is invoice matters")
	}
	// No key, no digest; and the key id is not the key.
	if New(Config{}).targetDigest("shop-1", KindAirtime, "22370123456", "", "XOF") != "" || New(Config{}).targetKeyID() != "" {
		t.Fatal("without a key there is nothing to keep")
	}
	if a.targetKeyID() == "" || a.targetKeyID() == b.targetKeyID() || strings.Contains(a.targetKeyID(), "key-a") {
		t.Fatalf("key ids: %q %q", a.targetKeyID(), b.targetKeyID())
	}
}

func TestSameTargetReadsTheRowAndNothingElse(t *testing.T) {
	service := keyedService(t, "key-a")
	in := pricing(t, "9.71")
	ctx := context.Background()
	prepare := func(request OrderRequest) json.RawMessage {
		request.InstallationID = "shop-1"
		prepared, refusal := service.PrepareOrder(ctx, in, request)
		if refusal != nil {
			t.Fatal(refusal)
		}
		return prepared.Details
	}
	airtime := OrderRequest{Kind: "airtime", OperatorID: 289, Phone: "70123456", Amount: "5000", AmountCurrency: "XOF"}
	details := prepare(airtime)
	for _, bad := range []string{"70123456", "22370123456", "+22370123456"} {
		// The number never reaches the details, in any of its forms (the country's
		// calling code is public and is kept).
		if strings.Contains(string(details), bad) {
			t.Fatalf("%q is in the details: %s", bad, details)
		}
	}
	for _, c := range []struct {
		name         string
		request      func(OrderRequest) OrderRequest
		same, known  bool
		installation string
	}{
		{"the same request", func(r OrderRequest) OrderRequest { return r }, true, true, "shop-1"},
		{"the number in another form", func(r OrderRequest) OrderRequest { r.Phone = "00223 70 12 34 56"; return r }, true, true, "shop-1"},
		{"the number with a trunk zero", func(r OrderRequest) OrderRequest { r.Phone = "070123456"; return r }, true, true, "shop-1"},
		{"the currency in lower case", func(r OrderRequest) OrderRequest { r.AmountCurrency = "xof"; return r }, true, true, "shop-1"},
		{"another number with the same mask", func(r OrderRequest) OrderRequest { r.Phone = "71123456"; return r }, false, true, "shop-1"},
		{"no number", func(r OrderRequest) OrderRequest { r.Phone = ""; return r }, false, true, "shop-1"},
		{"another shop", func(r OrderRequest) OrderRequest { return r }, false, true, "shop-2"},
	} {
		t.Run(c.name, func(t *testing.T) {
			same, known := service.SameTarget(c.installation, details, c.request(airtime))
			if same != c.same || known != c.known {
				t.Fatalf("same %v known %v, want %v %v", same, known, c.same, c.known)
			}
		})
	}

	// A row the service cannot check says so: it never calls it a different order.
	legacy := json.RawMessage(`{"operator_id":289,"country":"ML","amount":"5000"}`)
	if same, known := service.SameTarget("shop-1", legacy, airtime); known || same {
		t.Fatalf("a row without a digest: %v %v", same, known)
	}
	if same, known := keyedService(t, "key-b").SameTarget("shop-1", details, airtime); known || same {
		t.Fatalf("a row made with another key: %v %v", same, known)
	}
	if same, known := New(Config{}).SameTarget("shop-1", details, airtime); known || same {
		t.Fatalf("a service with no key: %v %v", same, known)
	}
	for _, garbage := range []json.RawMessage{nil, json.RawMessage(`not json`), json.RawMessage(`[]`)} {
		if _, known := service.SameTarget("shop-1", garbage, airtime); known {
			t.Fatalf("garbage details %q", garbage)
		}
	}

	// A bill: the account, and the invoice only when the biller takes one.
	bill := OrderRequest{Kind: "bill", BillerID: 26, Account: "14500000001", Amount: "5000", AmountCurrency: "XOF"}
	billDetails := prepare(bill)
	if same, known := service.SameTarget("shop-1", billDetails, OrderRequest{Kind: "bill", Account: "145 000 000 01", AmountCurrency: "XOF", InvoiceID: "ignored"}); !same || !known {
		t.Fatalf("spaces and a stray invoice: %v %v", same, known)
	}
	if same, known := service.SameTarget("shop-1", billDetails, OrderRequest{Kind: "bill", Account: "14599999001", AmountCurrency: "XOF"}); same || !known {
		t.Fatalf("another account: %v %v", same, known)
	}
	invoice := OrderRequest{Kind: "bill", BillerID: 23, Account: "123456789", InvoiceID: "2024-118833", Amount: "5000", AmountCurrency: "XOF"}
	invoiceDetails := prepare(invoice)
	if strings.Contains(string(invoiceDetails), "2024-118833") || strings.Contains(string(invoiceDetails), "123456789") {
		t.Fatalf("neither the account nor the invoice is kept: %s", invoiceDetails)
	}
	for name, c := range map[string]struct {
		edit func(OrderRequest) OrderRequest
		same bool
	}{
		"the same":         {func(r OrderRequest) OrderRequest { return r }, true},
		"another invoice":  {func(r OrderRequest) OrderRequest { r.InvoiceID = "2024-118834"; return r }, false},
		"no invoice":       {func(r OrderRequest) OrderRequest { r.InvoiceID = ""; return r }, false},
		"another account":  {func(r OrderRequest) OrderRequest { r.Account = "923456789"; return r }, false},
		"a spaced invoice": {func(r OrderRequest) OrderRequest { r.InvoiceID = " 2024-118833 "; return r }, true},
	} {
		same, known := service.SameTarget("shop-1", invoiceDetails, c.edit(invoice))
		if same != c.same || !known {
			t.Errorf("%s: same %v known %v", name, same, known)
		}
	}
}
