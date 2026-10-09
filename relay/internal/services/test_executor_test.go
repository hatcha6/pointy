package services

import (
	"context"
	"math/big"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/vouchers"
)

func TestTheTestExecutorIsDeterministicAndRemembersWhatItWasAsked(t *testing.T) {
	executor := NewTestExecutor()
	phone, _ := ParsePhone("70123456", "ML", []string{"223"})
	order := AirtimeOrder{ClientRef: "purchase-1", OperatorID: 289, OperatorName: "Orange Mali", Phone: phone,
		Amount: big.NewRat(19901, 2000), Currency: "USD", Receive: Money{Amount: "5000", Currency: "XOF"}}
	first, err := executor.Airtime(context.Background(), order)
	if err != nil {
		t.Fatal(err)
	}
	again, _ := NewTestExecutor().Airtime(context.Background(), order)
	if first.OrderID != again.OrderID || len(first.OrderID) != 10 || first.Status != vouchers.StatusSucceeded || first.CostUSD != "0" {
		t.Fatalf("a purchase has one fake id, whoever asks: %s %s", first.OrderID, again.OrderID)
	}
	if first.Receipt[ReceiptPhone] != "+22370123456" || first.Receipt[ReceiptDeliveredAmount] != "5000" || first.Receipt[ReceiptOrderCurrency] != "USD" ||
		!strings.HasPrefix(first.Receipt[ReceiptOperatorReference], "TEST-") {
		t.Fatalf("receipt: %v", first.Receipt)
	}
	other, _ := executor.Airtime(context.Background(), AirtimeOrder{ClientRef: "purchase-2", Phone: phone, Amount: big.NewRat(1, 1)})
	if other.OrderID == first.OrderID {
		t.Fatal("another purchase, another id")
	}
	// Read back by id and found by reference.
	read, err := executor.Lookup(context.Background(), KindAirtime, first.OrderID)
	if err != nil || read.Receipt[ReceiptPhone] != "+22370123456" {
		t.Fatalf("lookup: %+v %v", read, err)
	}
	found, err := executor.FindByClientRef(context.Background(), KindAirtime, "purchase-1", time.Time{}, time.Time{})
	if err != nil || len(found) != 1 || found[0].OrderID != first.OrderID {
		t.Fatalf("find: %+v %v", found, err)
	}
	if none, _ := executor.FindByClientRef(context.Background(), KindAirtime, "never", time.Time{}, time.Time{}); len(none) != 0 {
		t.Fatalf("nothing: %+v", none)
	}
	// A restarted relay still reads what the id alone determines.
	restarted, err := NewTestExecutor().Lookup(context.Background(), KindAirtime, first.OrderID)
	if err != nil || restarted.Status != vouchers.StatusSucceeded || restarted.Receipt[ReceiptTransactionID] != first.OrderID ||
		restarted.Receipt[ReceiptOperatorReference] != first.Receipt[ReceiptOperatorReference] {
		t.Fatalf("after a restart: %+v %v", restarted, err)
	}
	if _, err := executor.Lookup(context.Background(), KindAirtime, "not-a-test-id"); err == nil {
		t.Fatal("only fake ids are read")
	}
	if _, err := executor.Airtime(context.Background(), AirtimeOrder{}); err == nil {
		t.Fatal("an order without a reference is refused")
	}
}

func TestTheTestExecutorHandsBackATokenOnlyForPrepaidElectricity(t *testing.T) {
	executor := NewTestExecutor()
	bill := func(ref, typ, service string) Result {
		result, err := executor.Bill(context.Background(), BillOrder{ClientRef: ref, BillerName: "Woyofal Senegal", Account: "14500000001",
			Amount: big.NewRat(5000, 1), Currency: "XOF", Receive: Money{Amount: "5000", Currency: "XOF"}, Type: typ, Service: service})
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	prepaid := bill("b1", BillElectricity, ServicePrepaid)
	if !strings.HasPrefix(prepaid.Receipt[ReceiptToken], "TEST-") || prepaid.Receipt[ReceiptUnits] == "" || prepaid.Receipt[ReceiptAccount] != "14500000001" ||
		prepaid.Receipt[ReceiptAmount] != "5000" {
		t.Fatalf("prepaid electricity: %v", prepaid.Receipt)
	}
	for _, c := range [][2]string{{BillTV, ServicePrepaid}, {BillElectricity, ServicePostpaid}, {BillWater, ServicePostpaid}} {
		if token := bill("b-"+c[0]+c[1], c[0], c[1]).Receipt[ReceiptToken]; token != "" {
			t.Errorf("%s %s has no token, got %q", c[0], c[1], token)
		}
	}
	again := bill("b1", BillElectricity, ServicePrepaid)
	if again.Receipt[ReceiptToken] != prepaid.Receipt[ReceiptToken] {
		t.Fatal("the same purchase reads the same fake token")
	}
}

func TestRedactHidesWhatTheSupplierEchoed(t *testing.T) {
	for _, c := range []struct {
		text    string
		secrets []string
		want    string
	}{
		{"Invalid recipient phone 22370123456 for the operator", nil, "Invalid recipient phone ••• for the operator"},
		{"Invalid recipient +22370123456", nil, "Invalid recipient •••"},
		{"phone 70123456 unknown", []string{"70123456"}, "phone •••••456 unknown"},
		{"Unknown meter AB-77-1234x.", []string{"ab-77-1234x"}, "Unknown meter ••••••••34x."},
		{"national 70123456 / full 22370123456", []string{"70123456", "22370123456"}, "national •••••456 / full ••••••••456"},
		{"short 123 stays", []string{"123"}, "short 123 stays"},
		{"nothing to hide", []string{"70123456"}, "nothing to hide"},
		{"  padded  ", nil, "padded"},
	} {
		if got := Redact(c.text, c.secrets...); got != c.want {
			t.Errorf("Redact(%q, %v) = %q, want %q", c.text, c.secrets, got, c.want)
		}
	}
	if RedactError(nil) != "" {
		t.Error("no error, no text")
	}
}
