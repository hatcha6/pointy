package services

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/vouchers"
)

// fakeNames names the operators the tests use, the way the relay's table does,
// without depending on the table.
type fakeNames struct{}

func (fakeNames) Operator(name, iso, _ string) (string, bool) {
	switch iso + "|" + name {
	case "ML|Orange Mali":
		return "أورنج مالي", true
	case "NE|Airtel Niger":
		return "إيرتل النيجر", true
	}
	return "", false
}

func (fakeNames) Biller(name, iso string) (string, bool) {
	switch iso + "|" + name {
	case "NG|Ikeja Electricity Prepaid":
		return "كهرباء إيكيجا (مسبقة الدفع)", true
	case "SN|Facture Sen-Elec Senegal":
		return "فاتورة الكهرباء (السنغال)", true
	case "ML|Canal+ Mali":
		return "كانال بلس مالي", true
	}
	return "", false
}

func (fakeNames) Plan(description string) (string, bool) {
	if strings.HasPrefix(description, "Canalplus Acces English Basic") {
		return "كانال بلس أكسيس إنجليش بيسك – شهر", true
	}
	return "", false
}

func fixtureService(t *testing.T, edit ...func(*Config)) *Service {
	t.Helper()
	cfg := Config{
		Source:   FixtureSource{},
		TestMode: true,
		Namer:    fakeNames{},
		Now:      func() time.Time { return time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC) },
	}
	for _, change := range edit {
		change(&cfg)
	}
	return New(cfg)
}

func pricing(t *testing.T, rate string) PricingInput {
	t.Helper()
	settings := vouchers.DefaultSettings()
	if rate != "" {
		settings = settingsWithRate(t, rate)
	}
	_, key, err := vouchers.EncodeSettings(settings)
	if err != nil {
		t.Fatal(err)
	}
	return PricingInput{Settings: settings, SettingsKey: key}
}

func countryOf(t *testing.T, view *Directory, code string) Country {
	t.Helper()
	for _, country := range view.Countries {
		if country.Code == code {
			return country
		}
	}
	t.Fatalf("%s is not in the directory", code)
	return Country{}
}

func operatorOf(t *testing.T, view *Directory, code string, id int64) Operator {
	t.Helper()
	country := countryOf(t, view, code)
	if country.Airtime != nil {
		for _, operator := range country.Airtime.Operators {
			if operator.ID == id {
				return operator
			}
		}
	}
	t.Fatalf("operator %d is not in %s", id, code)
	return Operator{}
}

func billerOf(t *testing.T, view *Directory, code string, id int64) Biller {
	t.Helper()
	country := countryOf(t, view, code)
	if country.Bills != nil {
		for _, biller := range country.Bills.Billers {
			if biller.ID == id {
				return biller
			}
		}
	}
	t.Fatalf("biller %d is not in %s", id, code)
	return Biller{}
}

func TestTheFixtureMakesAPricedDirectory(t *testing.T) {
	service := fixtureService(t)
	rendered, err := service.Directory(context.Background(), pricing(t, "9.71"))
	if err != nil {
		t.Fatal(err)
	}
	view := rendered.View
	if !view.Configured || !view.Priced || !view.TestMode || view.Currency != "LYD" || len(rendered.Version) != 16 {
		t.Fatalf("header: %+v", view)
	}
	if view.Popular[0] != "NE" || view.Popular[1] != "ML" || view.Popular[2] != "NG" {
		t.Fatalf("the popular countries come in the settings' order, those served: %v", view.Popular)
	}
	if view.Countries[0].Code != "NE" || view.Countries[0].Popular != 1 || countryOf(t, view, "ML").Popular != 2 {
		t.Fatalf("popular countries first: %s %d", view.Countries[0].Code, view.Countries[0].Popular)
	}
	mali := countryOf(t, view, "ML")
	if mali.Name != "مالي" || mali.NameEN != "Mali" || mali.Currency != "XOF" || mali.CurrencyName != "فرنك أفريقي" ||
		len(mali.Dial) != 1 || mali.Dial[0] != "223" {
		t.Fatalf("mali: %+v", mali)
	}
	orange := operatorOf(t, view, "ML", 289)
	if orange.Name != "أورنج مالي" || orange.NameEN != "Orange Mali" || orange.Mode != "range" ||
		orange.AmountCurrency != "XOF" || orange.ReceiveCurrency != "XOF" || orange.Approximate {
		t.Fatalf("orange mali: %+v", orange)
	}
	if orange.Min == "" || orange.Max == "" || len(orange.Amounts) < 3 {
		t.Fatalf("a range operator carries its limits and tiles: %+v", orange)
	}
	for _, amount := range orange.Amounts {
		if amount.UnitPrice == "" || amount.RetailPrice == "" || amount.Receive != amount.Amount {
			t.Fatalf("a local tile receives what it costs and is priced: %+v", amount)
		}
	}
	if len(view.Unsupported) == 0 {
		t.Fatal("the countries without a service are listed")
	}
	for _, code := range []string{"LY", "SD", "SY", "TD", "ER"} {
		found := false
		for _, entry := range view.Unsupported {
			found = found || (entry.Code == code && entry.Name != "")
		}
		if !found {
			t.Errorf("%s must be listed as unsupported", code)
		}
	}
}

func TestADirectoryWithoutARateCarriesNoPrices(t *testing.T) {
	service := fixtureService(t)
	rendered, err := service.Directory(context.Background(), pricing(t, ""))
	if err != nil {
		t.Fatal(err)
	}
	if rendered.View.Priced {
		t.Fatal("no rate, no prices")
	}
	for _, country := range rendered.View.Countries {
		if country.Airtime == nil {
			continue
		}
		for _, operator := range country.Airtime.Operators {
			for _, amount := range operator.Amounts {
				if amount.UnitPrice != "" || amount.RetailPrice != "" {
					t.Fatalf("%s carries a price without a rate: %+v", operator.NameEN, amount)
				}
			}
		}
	}
	if strings.Contains(string(rendered.Body), "unit_price") {
		t.Fatal("an unpriced body must leave the price fields out altogether")
	}
}

func TestTheVersionMovesWithThePrices(t *testing.T) {
	service := fixtureService(t)
	first, _ := service.Directory(context.Background(), pricing(t, "9.71"))
	again, _ := service.Directory(context.Background(), pricing(t, "9.71"))
	if first != again {
		t.Fatal("the same settings reuse the rendering")
	}
	other, _ := service.Directory(context.Background(), pricing(t, "9.80"))
	if other.Version == first.Version {
		t.Fatal("a new rate is a new version")
	}
	unpriced, _ := service.Directory(context.Background(), pricing(t, ""))
	if unpriced.Version == first.Version || unpriced.Version == other.Version {
		t.Fatal("no rate is a version of its own")
	}
	withFlag := pricing(t, "9.71")
	withFlag.Flags = map[string]string{"ML": "sha256:" + strings.Repeat("a", 64)}
	withFlag.FlagsKey = "flags-1"
	flagged, _ := service.Directory(context.Background(), withFlag)
	if flagged.Version == first.Version || countryOf(t, flagged.View, "ML").Flag == "" {
		t.Fatal("a flag from the catalog is part of the directory")
	}
}

func TestAnUnconfiguredServiceHasAnEmptyDirectory(t *testing.T) {
	service := New(Config{})
	rendered, err := service.Directory(context.Background(), pricing(t, "9.71"))
	if err != nil {
		t.Fatal(err)
	}
	if rendered.View.Configured || len(rendered.View.Countries) != 0 || string(rendered.Body) == "" ||
		!strings.Contains(string(rendered.Body), `"countries":[]`) {
		t.Fatalf("%s", rendered.Body)
	}
	if _, refusal := service.Quote(context.Background(), pricing(t, "9.71"), QuoteRequest{Kind: "airtime", OperatorID: 289, Amount: "5000"}); refusal == nil ||
		refusal.Code != CodeServicesUnconfigured || refusal.Status != 503 {
		t.Fatalf("an unconfigured service quotes nothing: %v", refusal)
	}
}

func TestOneCountryEntryOnTheWire(t *testing.T) {
	service := fixtureService(t)
	rendered, _ := service.Directory(context.Background(), pricing(t, "9.71"))
	mali := countryOf(t, rendered.View, "ML")
	mali.Airtime.Operators = mali.Airtime.Operators[:1]
	mali.Bills = nil
	data, _ := json.MarshalIndent(mali, "", "  ")
	t.Log("\n" + string(data))
	var generic map[string]any
	if err := json.Unmarshal(data, &generic); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"code", "name", "name_en", "dial", "currency", "currency_name", "flag", "popular", "airtime"} {
		if _, ok := generic[key]; !ok {
			t.Errorf("country is missing %q", key)
		}
	}
}
