package services

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/reloadly"
)

// What the directory leaves out on purpose: a country the relay cannot name in
// Arabic, and the bill plans hiddenPlanWords name.

// withCountry adds a country to the fixture that the supplier sells in: three
// copies of Orange Mali as its operators and (when billers is set) one copy of
// Ikeja's electricity biller.
func withCountry(iso, name string, operators int, biller bool) func(*Raw) {
	return func(raw *Raw) {
		var base reloadly.Operator
		for _, operator := range raw.Operators {
			if operator.Key() == 289 {
				base = operator
			}
		}
		next := int64(9200)
		for _, operator := range raw.Operators {
			if operator.Key() >= next {
				next = operator.Key() + 1
			}
		}
		for i := 0; i < operators; i++ {
			copied := base
			copied.ID, copied.OperatorID = next+int64(i), next+int64(i)
			copied.Name = name + " Mobile " + string(rune('A'+i))
			copied.Country.ISOName, copied.Country.Name = iso, name
			raw.Operators = append(raw.Operators, copied)
		}
		if biller {
			for _, b := range raw.Billers {
				if b.ID == 5 {
					copied := b
					copied.ID, copied.Name = 9300, name+" Electricity"
					copied.CountryCode, copied.CountryName = iso, name
					raw.Billers = append(raw.Billers, copied)
					break
				}
			}
		}
		raw.Countries = append(raw.Countries, reloadly.TopupCountry{
			ISOName: iso, Name: name, CurrencyCode: "XOF", CallingCodes: []string{"+999"},
		})
	}
}

func countryCodes(view *Directory) map[string]bool {
	codes := map[string]bool{}
	for _, country := range view.Countries {
		codes[country.Code] = true
	}
	return codes
}

func TestACountryWithoutAnArabicNameIsNeverOffered(t *testing.T) {
	plain := fixtureService(t)
	in := pricing(t, "9.71")
	plainView, err := plain.Directory(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}

	// Israel is the one country of Reloadly's list the relay has no Arabic name for.
	source := &flakySource{}
	source.set(nil, withCountry("IL", "Israel", 3, true))
	service := New(Config{Source: source, TestMode: true, Namer: fakeNames{}, Now: func() time.Time {
		return time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	}})
	rendered, err := service.Directory(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	if countryCodes(rendered.View)["IL"] {
		t.Fatal("Israel is not offered")
	}
	for _, unsupported := range rendered.View.Unsupported {
		if unsupported.Code == "IL" {
			t.Fatal("a country the relay cannot name is not listed as unsupported either")
		}
	}
	// Nothing else changed: the same countries, the same version.
	if len(rendered.View.Countries) != len(plainView.View.Countries) || rendered.Version != plainView.Version {
		t.Fatalf("the rest of the directory is the plain one: %d countries, %s vs %d, %s",
			len(rendered.View.Countries), rendered.Version, len(plainView.View.Countries), plainView.Version)
	}
	// What it would have sold can be neither quoted nor ordered.
	for id := int64(9200); id < 9203; id++ {
		if _, refusal := quote(t, service, in, QuoteRequest{Kind: "airtime", OperatorID: id, Amount: "5000", AmountCurrency: "XOF"}); refusal == nil || refusal.Code != "unknown_operator" {
			t.Fatalf("operator %d: %v", id, refusal)
		}
	}
	if _, refusal := quote(t, service, in, QuoteRequest{Kind: "bill", BillerID: 9300, Amount: "5000", AmountCurrency: "XOF"}); refusal == nil || refusal.Code != "unknown_biller" {
		t.Fatalf("the biller: %v", refusal)
	}
	if _, refusal := service.Detect(context.Background(), in, "IL", "501234567"); refusal == nil || refusal.Code != "operator_not_detected" {
		t.Fatalf("a number in a country nothing is sold in: %v", refusal)
	}

	// The operator is told what was dropped.
	build := service.Stats().Build
	if len(build.Dropped) != 1 || build.Dropped[0] != (DroppedCountry{Code: "IL", Name: "Israel", Operators: 3, Billers: 1}) {
		t.Fatalf("dropped: %+v", build.Dropped)
	}
	if build.Skipped[skipNoCountryName] != 4 {
		t.Fatalf("skipped: %v", build.Skipped)
	}
	if got := build.Dropped[0].String(); got != "IL (Israel): 3 operators, 1 billers" {
		t.Fatalf("string: %q", got)
	}
	if missing := service.MissingNames(); len(missing) != len(plain.MissingNames()) {
		t.Fatalf("a dropped country is not a missing name: %+v", missing)
	}
}

func TestACountryTheRelayCanNameInArabicIsKept(t *testing.T) {
	// The Netherlands Antilles are not in the card shop's table; the services
	// carry their own Arabic name for them.
	source := &flakySource{}
	source.set(nil, withCountry("AN", "Netherlands Antilles", 2, false))
	service := New(Config{Source: source, TestMode: true, Namer: fakeNames{}})
	rendered, err := service.Directory(context.Background(), pricing(t, "9.71"))
	if err != nil {
		t.Fatal(err)
	}
	country := countryOf(t, rendered.View, "AN")
	if country.Name != "جزر الأنتيل الهولندية" || country.NameEN != "Netherlands Antilles" || country.Airtime == nil || len(country.Airtime.Operators) != 2 {
		t.Fatalf("AN: %+v", country)
	}
	if dropped := service.Stats().Build.Dropped; len(dropped) != 0 {
		t.Fatalf("nothing is dropped: %+v", dropped)
	}
}

// capturedLog is a logger whose lines the test can read.
func capturedLog() (*slog.Logger, *bytes.Buffer) {
	buffer := &bytes.Buffer{}
	return slog.New(slog.NewTextHandler(buffer, &slog.HandlerOptions{Level: slog.LevelDebug})), buffer
}

func TestTheDroppedCountriesAreLoggedOncePerChange(t *testing.T) {
	logger, logs := capturedLog()
	source := &flakySource{}
	source.set(nil, withCountry("IL", "Israel", 3, false))
	clock := &movingClock{now: time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)}
	service := New(Config{Source: source, TestMode: true, Namer: fakeNames{}, Now: clock.Now, Logger: logger})
	if _, err := service.Directory(context.Background(), pricing(t, "9.71")); err != nil {
		t.Fatal(err)
	}
	const message = "leaves out countries that have no Arabic name"
	if got := strings.Count(logs.String(), message); got != 1 || !strings.Contains(logs.String(), "IL (Israel): 3 operators, 0 billers") {
		t.Fatalf("the first reading says so once:\n%s", logs)
	}

	// The same reading again: nothing is said again.
	clock.advance(15 * time.Minute)
	if err := service.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(logs.String(), message); got != 1 {
		t.Fatalf("a reading that found nothing new is silent (%d):\n%s", got, logs)
	}

	// A second country the relay cannot name appears at the supplier: said again,
	// with both, although nothing that is sold changed.
	both := func(raw *Raw) {
		withCountry("IL", "Israel", 3, false)(raw)
		withCountry("ZZ", "Zedland", 1, false)(raw)
	}
	source.set(nil, both)
	clock.advance(15 * time.Minute)
	if err := service.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(logs.String(), message); got != 2 || !strings.Contains(logs.String(), "ZZ (Zedland): 1 operators, 0 billers") {
		t.Fatalf("a new dropped country is reported (%d):\n%s", got, logs)
	}
}

func TestPlansNamingAHiddenWordAreNotOffered(t *testing.T) {
	service := fixtureService(t)
	in := pricing(t, "9.71")
	rendered, err := service.Directory(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	canal := billerOf(t, rendered.View, "ML", 27)
	// Canal+ Mali lists 28 plans; 8 are its adult-content ones ("... Charme ...").
	if len(canal.Plans) != 20 {
		t.Fatalf("plans: %d", len(canal.Plans))
	}
	for _, plan := range canal.Plans {
		if strings.Contains(strings.ToLower(plan.DescriptionEN), "charme") {
			t.Fatalf("a hidden plan is listed: %+v", plan)
		}
	}
	if hidden := service.Stats().Build.HiddenPlans; hidden != 8 {
		t.Fatalf("hidden plans: %d", hidden)
	}

	// A hidden plan can be neither quoted nor ordered, by its id or by its amount.
	for _, hidden := range []QuoteRequest{
		{Kind: "bill", BillerID: 27, Amount: "11000", AmountCurrency: "XOF", AmountID: 1},
		{Kind: "bill", BillerID: 27, Amount: "11000", AmountCurrency: "XOF"},
		{Kind: "bill", BillerID: 27, Amount: "63000", AmountCurrency: "XOF", AmountID: 20},
	} {
		if _, refusal := quote(t, service, in, hidden); refusal == nil || refusal.Status != 422 || refusal.Code != "amount_not_offered" {
			t.Fatalf("quoting %+v: %v", hidden, refusal)
		}
		if _, refusal := service.PrepareOrder(context.Background(), in, OrderRequest{
			Kind: "bill", BillerID: 27, Country: "ML", Account: "12345678",
			Amount: hidden.Amount, AmountCurrency: hidden.AmountCurrency, AmountID: hidden.AmountID,
		}); refusal == nil || refusal.Code != "amount_not_offered" {
			t.Fatalf("ordering %+v: %v", hidden, refusal)
		}
	}
	// The plans around it are sold as before.
	for _, visible := range []QuoteRequest{
		{Kind: "bill", BillerID: 27, Amount: "10000", AmountCurrency: "XOF", AmountID: 3},
		{Kind: "bill", BillerID: 27, Amount: "15000", AmountCurrency: "XOF"},
	} {
		if _, refusal := quote(t, service, in, visible); refusal != nil {
			t.Fatalf("quoting %+v: %v", visible, refusal)
		}
	}
}

func TestHiddenPlanWordsAreOneEditableList(t *testing.T) {
	if !planHidden("Canalplus Evasion Charme (16000/1MOIS)") || !planHidden("canalplus ACCES CHARME") {
		t.Fatal("the default hides Charme in any letter case")
	}
	if planHidden("Canalplus Acces English Basic (10000/1MOIS)") || planHidden("") {
		t.Fatal("other plans are offered")
	}

	saved := hiddenPlanWords
	t.Cleanup(func() { hiddenPlanWords = saved })
	in := pricing(t, "9.71")
	count := func() int {
		service := fixtureService(t)
		rendered, err := service.Directory(context.Background(), in)
		if err != nil {
			t.Fatal(err)
		}
		return len(billerOf(t, rendered.View, "ML", 27).Plans)
	}

	hiddenPlanWords = nil
	if got := count(); got != 28 {
		t.Fatalf("with nothing hidden every plan is offered: %d", got)
	}
	hiddenPlanWords = []string{"Charme", "  English Plus "}
	// What the fixture lists for Canal+ Mali that says either word.
	raw, err := FixtureSource{}.Load(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	sayingEither := 0
	for _, biller := range raw.Billers {
		if biller.ID != 27 {
			continue
		}
		for _, plan := range biller.LocalFixedAmounts {
			description := strings.ToLower(plan.Description)
			if strings.Contains(description, "charme") || strings.Contains(description, "english plus") {
				sayingEither++
			}
		}
	}
	if sayingEither <= 8 {
		t.Fatalf("the fixture has English Plus plans besides the 8 Charme ones: %d", sayingEither)
	}
	if got := count(); got != 28-sayingEither {
		t.Fatalf("two words hide %d of 28: %d offered", sayingEither, got)
	}
	hiddenPlanWords = []string{"", "   "}
	if got := count(); got != 28 {
		t.Fatalf("blank words hide nothing: %d", got)
	}
}

func TestABillerWhoseEveryPlanIsHiddenIsLeftOut(t *testing.T) {
	saved := hiddenPlanWords
	t.Cleanup(func() { hiddenPlanWords = saved })
	hiddenPlanWords = []string{"Canalplus"}
	service := fixtureService(t)
	rendered, err := service.Directory(context.Background(), pricing(t, "9.71"))
	if err != nil {
		t.Fatal(err)
	}
	// Canal+ is Mali's only biller: with nothing left to sell, Mali has no bills.
	if bills := countryOf(t, rendered.View, "ML").Bills; bills != nil {
		t.Fatalf("a biller with nothing left to sell is not offered: %+v", bills)
	}
	build := service.Stats().Build
	if build.Skipped[skipAllPlansHidden] != 1 {
		t.Fatalf("skipped: %v", build.Skipped)
	}
}
