package reloadly

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"
)

func validGiftOrder() GiftOrderRequest {
	return GiftOrderRequest{ProductID: 10316, Quantity: 1, UnitPrice: "5", CustomIdentifier: "ptest-1", SenderName: "Pointy"}
}

func giftByID(t *testing.T, id int64) GiftProduct {
	t.Helper()
	for _, product := range fixtureRows[GiftProduct](t, "giftcards_products.json") {
		if product.ID == id {
			return product
		}
	}
	t.Fatalf("gift product %d is not in the fixture", id)
	return GiftProduct{}
}

func TestProductsDecodeEveryShape(t *testing.T) {
	f := newFake(t)
	f.always("giftcards", ok(fixture(t, "giftcards_products.json")))
	products, err := f.client().Products(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(products) != 13 {
		t.Fatalf("products = %d", len(products))
	}
	byID := map[int64]GiftProduct{}
	for _, product := range products {
		byID[product.ID] = product
	}
	lobster := byID[10316]
	if lobster.Name != "Red Lobster" || lobster.DenominationType != Fixed || lobster.SenderFee != "1.0" ||
		lobster.SenderFeePercentage != "0.00" || lobster.RecipientCurrencyCode != "USD" || lobster.SenderCurrencyCode != "USD" ||
		lobster.Country.ISOName != "US" || lobster.Brand.Name != "Red Lobster" || lobster.Category.Name == "" {
		t.Fatalf("Red Lobster = %+v", lobster)
	}
	if len(lobster.FixedRecipientDenominations) != 8 || lobster.FixedRecipientToSender["5.00"] != "5.00" {
		t.Fatalf("Red Lobster denominations = %v / %v", lobster.FixedRecipientDenominations, lobster.FixedRecipientToSender)
	}
	amazon := byID[5]
	if amazon.DenominationType != Range || amazon.MinRecipientDenomination != "5.0" || amazon.MaxRecipientDenomination != "100.0" ||
		len(amazon.FixedRecipientDenominations) != 0 || len(amazon.FixedRecipientToSender) != 0 {
		t.Fatalf("Amazon US = %+v", amazon)
	}
	netflix := byID[15363]
	if netflix.RecipientCurrencyCode != "EUR" || netflix.RecipientToSenderRate != "1.176776" || netflix.MinSenderDenomination != "29.42" {
		t.Fatalf("Netflix Spain = %+v", netflix)
	}
	if byID[13948].DiscountPercentage != "5.0" || byID[10296].SenderFeePercentage != "1.00" {
		t.Fatal("discount or percentage fee lost")
	}
}

func TestAProductWithOddMetadataStillDecodes(t *testing.T) {
	var product GiftProduct
	raw := `{"productId":1,"metadata":{"0.99":"55 Diamonds","4.99":275,"9.99":null},"fixedRecipientToSenderDenominationsMap":null,
	"additionalRequirements":{"userIdRequired":true},"logoUrls":null,"redeemInstruction":null}`
	if err := json.Unmarshal([]byte(raw), &product); err != nil {
		t.Fatal(err)
	}
	if product.Metadata["0.99"] != "55 Diamonds" || product.Metadata["4.99"] != "275" || !product.AdditionalRequirements.UserIDRequired {
		t.Fatalf("product = %+v", product)
	}
}

func TestProductReadsOneAndRefusesNoID(t *testing.T) {
	f := newFake(t)
	f.on("giftcards", func(c call) reply {
		if c.path != "/products/10316" {
			return fail(404, `{"message":"Invalid product id","errorCode":"INVALID_PRODUCT"}`)
		}
		var page pageOf[json.RawMessage]
		_ = json.Unmarshal([]byte(fixture(t, "giftcards_products.json")), &page)
		return ok(string(page.Content[0]))
	})
	c := f.client()
	product, err := c.Product(context.Background(), 10316)
	if err != nil || product.ID != 10316 {
		t.Fatalf("product = %+v, err = %v", product, err)
	}
	if _, err := c.Product(context.Background(), 1); !IsNotFound(err) {
		t.Fatalf("err = %v", err)
	}
	if _, err := c.Product(context.Background(), 0); !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("err = %v", err)
	}
}

func TestOrderGiftCardSendsTheDocumentedBody(t *testing.T) {
	f := newFake(t)
	f.always("giftcards", ok(fixture(t, "gift_order_processing.json")))
	c := f.client()
	order, err := c.OrderGiftCard(context.Background(), GiftOrderRequest{
		ProductID: 20316, Quantity: 2, UnitPrice: "1.20013", CustomIdentifier: "pointy-ab12",
		SenderName: "  Pointy  ", RecipientEmail: " a@b.ly ", ProductUserID: "u-1", PreOrder: true,
		RecipientPhone: &GiftPhone{CountryCode: "LY", PhoneNumber: "912345678"},
	})
	if err != nil {
		t.Fatal(err)
	}
	sent := f.callsTo("giftcards")[0]
	if sent.method != http.MethodPost || sent.path != "/orders" || sent.header.Get("Content-Type") != "application/json" {
		t.Fatalf("request = %+v", sent)
	}
	body := string(sent.body)
	for _, part := range []string{`"productId":20316`, `"quantity":2`, `"unitPrice":1.20013`, `"customIdentifier":"pointy-ab12"`,
		`"senderName":"Pointy"`, `"recipientEmail":"a@b.ly"`, `"preOrder":true`,
		`"recipientPhoneDetails":{"countryCode":"LY","phoneNumber":"912345678"}`,
		`"productAdditionalRequirements":{"userId":"u-1"}`} {
		if !strings.Contains(body, part) {
			t.Errorf("body %s lacks %s", body, part)
		}
	}
	// The processing order of the fixture.
	if order.TransactionID != 79987 || order.Status != StatusProcessing || order.Status.Final() || !order.Status.InProgress() ||
		order.Amount != "2.20932" || order.Fee != "1.00" || order.CurrencyCode != "USD" ||
		order.Product.ProductID != 20316 || order.Product.UnitPrice != "1.234" || order.Product.Quantity != 1 ||
		order.Product.Brand.Name != "Mastercard" || order.Balance.Cost != "2.20932" || order.Balance.OldBalance == "" ||
		order.CustomIdentifier == "" || order.CreatedAt.IsZero() || order.RecipientEmail != "" {
		t.Fatalf("order = %+v", order)
	}
	if order.CreatedAt.Time.Location() != time.UTC {
		t.Fatalf("CreatedAt zone = %v", order.CreatedAt.Time.Location())
	}

	// Minimal request: no optional key at all.
	if _, err := c.OrderGiftCard(context.Background(), validGiftOrder()); err != nil {
		t.Fatal(err)
	}
	minimal := string(f.callsTo("giftcards")[1].body)
	for _, key := range []string{"recipientEmail", "recipientPhoneDetails", "productAdditionalRequirements", "preOrder"} {
		if strings.Contains(minimal, key) {
			t.Errorf("minimal body %s carries %s", minimal, key)
		}
	}
}

func TestAGiftTransactionReadsTheMisspelledBalanceBlock(t *testing.T) {
	raw := `{"transactionId":9,"amount":6.00000,"status":"successful","balaneInfo":{"oldBalance":10,"newBalance":4,"cost":6.00000,"currencyCode":"USD"}}`
	var tx GiftTransaction
	if err := json.Unmarshal([]byte(raw), &tx); err != nil {
		t.Fatal(err)
	}
	if tx.Balance.Cost != "6.00000" || tx.Balance.CurrencyCode != "USD" || tx.Status != StatusSuccessful {
		t.Fatalf("tx = %+v", tx)
	}
	both := `{"transactionId":9,"balanceInfo":{"cost":1},"balaneInfo":{"cost":2}}`
	if err := json.Unmarshal([]byte(both), &tx); err != nil || tx.Balance.Cost != "1" {
		t.Fatalf("the correct spelling must win: %+v, %v", tx.Balance, err)
	}
}

func TestOrderGiftCardValidatesBeforeSending(t *testing.T) {
	for name, change := range map[string]func(*GiftOrderRequest){
		"no product":       func(r *GiftOrderRequest) { r.ProductID = 0 },
		"no quantity":      func(r *GiftOrderRequest) { r.Quantity = 0 },
		"no price":         func(r *GiftOrderRequest) { r.UnitPrice = "" },
		"zero price":       func(r *GiftOrderRequest) { r.UnitPrice = "0" },
		"negative price":   func(r *GiftOrderRequest) { r.UnitPrice = "-5" },
		"price not number": func(r *GiftOrderRequest) { r.UnitPrice = "five" },
		"no identifier":    func(r *GiftOrderRequest) { r.CustomIdentifier = " " },
		"long identifier":  func(r *GiftOrderRequest) { r.CustomIdentifier = strings.Repeat("x", MaxIdentifierLength+1) },
		"no sender name":   func(r *GiftOrderRequest) { r.SenderName = "" },
	} {
		t.Run(name, func(t *testing.T) {
			f := newFake(t)
			f.always("giftcards", ok("{}"))
			request := validGiftOrder()
			change(&request)
			_, err := f.client().OrderGiftCard(context.Background(), request)
			if !errors.Is(err, ErrInvalidRequest) || !Definite(err) {
				t.Fatalf("err = %v", err)
			}
			if len(f.callsTo("auth"))+len(f.callsTo("giftcards")) != 0 {
				t.Fatal("an invalid order reached the network")
			}
		})
	}
	// A 150 character identifier is the longest accepted.
	f := newFake(t)
	f.always("giftcards", ok(fixture(t, "gift_order_processing.json")))
	request := validGiftOrder()
	request.CustomIdentifier = strings.Repeat("é", MaxIdentifierLength)
	if _, err := f.client().OrderGiftCard(context.Background(), request); err != nil {
		t.Fatal(err)
	}
}

func TestGiftRedeemCodesAskForTheV2Answer(t *testing.T) {
	f := newFake(t)
	f.on("giftcards", func(c call) reply {
		if c.header.Get("Accept") != "application/com.reloadly.giftcards-v2+json" {
			return fail(406, "")
		}
		return ok(fixture(t, "gift_codes_v2.json"))
	})
	codes, err := f.client().GiftRedeemCodes(context.Background(), 79965)
	if err != nil {
		t.Fatal(err)
	}
	if path := f.callsTo("giftcards")[0].path; path != "/orders/transactions/79965/cards" {
		t.Fatalf("path = %q", path)
	}
	if len(codes) != 1 || codes[0].CardNumber != "" || codes[0].PinCode != "22610test" || codes[0].RedemptionURL != "https://reloadly.com" {
		t.Fatalf("codes = %+v", codes)
	}
	// v1 puts the code or the link in cardNumber; a number is kept as written.
	var v1 []GiftCode
	if err := json.Unmarshal([]byte(fixture(t, "gift_codes_v1.json")), &v1); err != nil || v1[0].CardNumber != "https://reloadly.com" {
		t.Fatalf("v1 = %+v, %v", v1, err)
	}
	var numeric []GiftCode
	if err := json.Unmarshal([]byte(`[{"cardNumber":12345678901234567890,"pinCode":1234}]`), &numeric); err != nil ||
		numeric[0].CardNumber != "12345678901234567890" || numeric[0].PinCode != "1234" {
		t.Fatalf("numeric codes = %+v, %v", numeric, err)
	}
	if _, err := f.client().GiftRedeemCodes(context.Background(), 0); !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("err = %v", err)
	}
}

func TestGiftTransactionReadsOneOrder(t *testing.T) {
	f := newFake(t)
	f.always("giftcards", ok(fixture(t, "gift_transaction_red_lobster.json")))
	tx, err := f.client().GiftTransaction(context.Background(), 79965)
	if err != nil {
		t.Fatal(err)
	}
	if path := f.callsTo("giftcards")[0].path; path != "/reports/transactions/79965" {
		t.Fatalf("path = %q", path)
	}
	if tx.TransactionID != 79965 || tx.Status != StatusSuccessful || !tx.Status.Succeeded() || tx.Amount != "6.00000" ||
		tx.Balance.Cost != "6.00000" || tx.Balance.OldBalance != "999.81000" || tx.Balance.NewBalance != "993.81000" ||
		tx.Product.UnitPrice != "5.00" || tx.CreatedAt.Time != time.Date(2026, 10, 8, 1, 42, 10, 0, time.UTC) {
		t.Fatalf("tx = %+v", tx)
	}
}

func TestFindGiftTransactionsByIdentifier(t *testing.T) {
	f := newFake(t)
	f.always("giftcards", ok(fixture(t, "gift_transactions_page.json")))
	from := time.Date(2026, 10, 8, 1, 40, 0, 0, time.UTC)
	to := time.Date(2026, 10, 8, 1, 50, 0, 0, time.UTC)
	rows, err := f.client().FindGiftTransactions(context.Background(), " ptest-v-1 ", from, to)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].TransactionID != 79965 {
		t.Fatalf("rows = %+v", rows)
	}
	query := parseQueryDecoded(t, f.callsTo("giftcards")[0].query)
	// Reloadly reads the window as UTC-4: it is widened by a day and a half.
	if query["customIdentifier"] != "ptest-v-1" || query["startDate"] != "2026-10-06 13:40:00" ||
		query["endDate"] != "2026-10-09 13:50:00" || query["page"] != "1" {
		t.Fatalf("query = %v", query)
	}
	// Without an identifier the window is exact.
	g := newFake(t)
	g.always("giftcards", ok(fixture(t, "gift_transactions_page.json")))
	rows, err = g.client().FindGiftTransactions(context.Background(), "", from.Add(time.Hour), to.Add(time.Hour))
	if err != nil || len(rows) != 0 {
		t.Fatalf("rows outside the window = %+v, err = %v", rows, err)
	}
	if _, has := parseQueryDecoded(t, g.callsTo("giftcards")[0].query)["customIdentifier"]; has {
		t.Fatal("an empty identifier must not be sent")
	}
	rows, err = g.client().FindGiftTransactions(context.Background(), "", time.Time{}, time.Time{})
	if err != nil || len(rows) != 1 {
		t.Fatalf("an open window must keep the row: %+v, %v", rows, err)
	}
}

func TestGiftBalance(t *testing.T) {
	f := newFake(t)
	f.always("giftcards", ok(balanceBody))
	balance, err := f.client().GiftBalance(context.Background())
	if err != nil || balance.Balance != "993.81000" || balance.CurrencyCode != "USD" || !balance.FrozenBalance.Empty() ||
		balance.LowBalanceThreshold != "0.000000" {
		t.Fatalf("balance = %+v, err = %v", balance, err)
	}
	if rat, ok := balance.Balance.Rat(); !ok || rat.FloatString(5) != "993.81000" {
		t.Fatal("the balance is not an exact number")
	}
}

func TestGiftErrorsKeepTheirCodes(t *testing.T) {
	for _, test := range []struct {
		body string
		code string
		is   func(error) bool
	}{
		{`{"timeStamp":"x","message":"The custom identifier provided has already been used. Please provide a new, unique custom identifier","path":"/orders","errorCode":"CUSTOM_IDENTIFIER_ALREADY_USED","infoLink":null,"details":[]}`, CodeDuplicateCustomIdentifier, IsDuplicateIdentifier},
		{`{"timeStamp":"x","message":"Invalid price. Please ensure you selected the right price","path":"/orders","errorCode":"WRONG_PRODUCT_PRICE","infoLink":null,"details":[]}`, CodeWrongProductPrice, func(error) bool { return true }},
	} {
		f := newFake(t)
		f.always("giftcards", fail(400, test.body))
		_, err := f.client().OrderGiftCard(context.Background(), validGiftOrder())
		var api *APIError
		if !errors.As(err, &api) || api.Code != test.code || !test.is(err) || !Definite(err) {
			t.Fatalf("err = %#v", err)
		}
	}
}
