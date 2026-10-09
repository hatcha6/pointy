package vouchers

import (
	"errors"
	"math/big"
	"reflect"
	"strings"
	"testing"
)

func settingsRatOf(t *testing.T, text string) *big.Rat {
	t.Helper()
	value, ok := new(big.Rat).SetString(text)
	if !ok {
		t.Fatalf("%q is not a number", text)
	}
	return value
}

// demoRate is a settings value for tests that need a priced relay.
func demoRate(mutate func(*Settings)) Settings {
	settings := Settings{USDRate: "9.71"}
	if mutate != nil {
		mutate(&settings)
	}
	return settings
}

func TestDefaultSettingsAreTheDemonstrationNumbers(t *testing.T) {
	got := DefaultSettings()
	want := Settings{
		FundingPercent: "0",
		Airtime:        ServicePricing{OrderMode: "usd", USDBufferPercent: "0.5", ServiceFeeLYD: "2"},
		Bills:          ServicePricing{OrderMode: "auto", USDBufferPercent: "0.5", ServiceFeeLYD: "0"},
		Margin: Margin{FixedLYD: "0.50", MinMarginLYD: "0.50", Brackets: defaultBrackets(), ShopSharePercent: "35", RoundStep: "0.25", MinShopMargin: "0.10",
			MarketGapPercent: "3", MarketMaxAgeDays: "30", CompanyMinPct: "3", CompanyMinLYD: "0.50", ShopMinPct: "2.5", ShopMinLYD: "0.50", LocalCompanyShare: "20"},
		USDRateSource: "fulus", USDRateSeries: "cash", USDRateBufferPercent: "0", USDRateMaxAge: "48h",
		Popular: []string{
			"NE", "ML", "NG", "EG", "GH", "SN", "TN", "BD", "PK", "IN",
			"PH", "TR", "MA", "DZ", "CM", "BF", "CI", "GN", "GM", "ET",
		},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("defaults:\n got %+v\nwant %+v", got, want)
	}
	if got.Priced() {
		t.Fatal("there is no dollar rate by default: nothing may be priced by guess")
	}
	if problems := got.Validate(); len(problems) != 0 {
		t.Fatalf("the defaults must be valid: %v", problems)
	}
	// Each call hands out its own list.
	got.Popular[0] = "XX"
	if DefaultSettings().Popular[0] != "NE" || DefaultPopularCountries()[0] != "NE" {
		t.Fatal("the default popular list must not be shared")
	}
}

func TestParseSettingsAcceptsAndNormalizes(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want func(Settings) bool
	}{
		{"empty object is every default", `{}`, func(s Settings) bool { return reflect.DeepEqual(s, DefaultSettings()) }},
		{"only a rate", `{"usd_rate":"9.71"}`, func(s Settings) bool {
			return s.USDRate == "9.71" && s.Margin.FixedLYD == "0.50" && s.Priced()
		}},
		{"everything", `{
			"usd_rate": " 9.7123 ", "funding_percent": "1.5",
			"airtime": {"order_mode": " LOCAL ", "usd_buffer_percent": "1.25", "margin": {"fixed_lyd": "1"}},
			"bills": {"shop_markup_percent": "4.25", "retail_markup_percent": "8", "order_mode": "Auto"},
			"retail_step": "0.5", "min_shop_margin": "0.25",
			"popular": ["ml", " ne ", "ML", "ng"]
		}`, func(s Settings) bool {
			return s.USDRate == "9.7123" && s.FundingPercent == "1.5" &&
				s.Airtime.OrderMode == "local" && s.Airtime.USDBufferPercent == "1.25" && s.Airtime.Margin.FixedLYD == "1" &&
				// the old pair 4.25 / 8 became a margin: all of the 8 %, 46.875 % of it the shop's
				s.Bills.Margin != nil && s.Bills.Margin.ShopSharePercent == "46.875" && s.Bills.ShopMarkupPercent == "" &&
				s.Margin.RoundStep == "0.5" && s.Margin.MinShopMargin == "0.25" && s.RetailStep == "" &&
				reflect.DeepEqual(s.Popular, []string{"ML", "NE", "NG"})
		}},
		{"zero markups and margin are allowed", `{"funding_percent":"0","airtime":{"shop_markup_percent":"0","retail_markup_percent":"0"},"min_shop_margin":"0"}`,
			func(s Settings) bool { return s.Margin.MinShopMargin == "0" && s.Airtime.Margin == nil }},
		{"an empty popular list is the default list", `{"popular":[]}`, func(s Settings) bool {
			return reflect.DeepEqual(s.Popular, DefaultPopularCountries())
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := ParseSettings([]byte(c.raw))
			if err != nil {
				t.Fatalf("ParseSettings: %v", err)
			}
			if !c.want(got) {
				t.Fatalf("unexpected result: %+v", got)
			}
		})
	}
}

func TestParseSettingsRefuses(t *testing.T) {
	cases := []struct {
		name, raw, contains string
	}{
		{"a misspelt field", `{"retial_step":"0.5"}`, "retial_step"},
		{"a misspelt nested field", `{"airtime":{"shop_markup":"2"}}`, "shop_markup"},
		{"trailing content", `{} {}`, "trailing"},
		{"an array", `[]`, "JSON object"},
		{"null", `null`, "JSON object"},
		{"a string", `"9.71"`, "JSON object"},
		{"nothing", ``, "JSON object"},
		{"broken JSON", `{"usd_rate":`, "not valid JSON"},
		{"a JSON number where a string belongs", `{"usd_rate": 9.71}`, "usd_rate"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := ParseSettings([]byte(c.raw))
			if err == nil || !strings.Contains(err.Error(), c.contains) {
				t.Fatalf("err = %v, want it to mention %q", err, c.contains)
			}
		})
	}
	if _, err := ParseSettings([]byte(`{"usd_rate": 9.71}`)); err == nil || !strings.Contains(err.Error(), "strings") {
		t.Fatalf("a JSON number should be told to be a string: %v", err)
	}
}

func TestParseSettingsReportsEveryProblemAtOnce(t *testing.T) {
	raw := `{
		"usd_rate": "0",
		"funding_percent": "-1",
		"airtime": {"shop_markup_percent": "abc", "retail_markup_percent": "5.5555555555"},
		"bills": {"shop_markup_percent": "1e3"},
		"retail_step": "0",
		"min_shop_margin": "0.123",
		"popular": ["NE", "ZZ", "WW", "EU", "N", "", "N3"]
	}`
	_, err := ParseSettings([]byte(raw))
	var problems SettingsProblems
	if !errors.As(err, &problems) {
		t.Fatalf("want SettingsProblems, got %T: %v", err, err)
	}
	byPath := map[string]string{}
	for _, problem := range problems {
		byPath[problem.Path] = problem.Message
	}
	for _, path := range []string{
		"usd_rate", "funding_percent", "airtime.shop_markup_percent", "airtime.retail_markup_percent",
		"bills.shop_markup_percent", "retail_step", "min_shop_margin",
		"popular[1]", "popular[2]", "popular[3]", "popular[4]", "popular[5]", "popular[6]",
	} {
		if byPath[path] == "" {
			t.Errorf("no problem reported for %s; got %v", path, byPath)
		}
	}
	if _, listed := byPath["popular[0]"]; listed {
		t.Errorf("NE is a country: %v", byPath)
	}
	if !strings.Contains(err.Error(), "invalid voucher settings:") || !strings.Contains(err.Error(), "retail_step") {
		t.Errorf("the message should list the problems: %v", err)
	}
	if got := len(problems); got != 13 {
		t.Errorf("want 13 problems, got %d: %v", got, problems)
	}
}

func TestValidateNumbers(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*Settings)
		path   string // "" = valid
	}{
		{"rate zero", func(s *Settings) { s.USDRate = "0" }, "usd_rate"},
		{"rate zero with decimals", func(s *Settings) { s.USDRate = "0.000000" }, "usd_rate"},
		{"rate negative", func(s *Settings) { s.USDRate = "-9.71" }, "usd_rate"},
		{"rate with a comma", func(s *Settings) { s.USDRate = "9,71" }, "usd_rate"},
		{"rate with exponent", func(s *Settings) { s.USDRate = "1e1" }, "usd_rate"},
		{"rate with ten decimals", func(s *Settings) { s.USDRate = "9.7100000001" }, "usd_rate"},
		{"rate with nine decimals", func(s *Settings) { s.USDRate = "9.710000001" }, ""},
		{"rate an integer", func(s *Settings) { s.USDRate = "10" }, ""},
		{"blank rate is unset, not wrong", func(s *Settings) { s.USDRate = "  " }, ""},
		{"funding zero", func(s *Settings) { s.FundingPercent = "0" }, ""},
		{"funding negative", func(s *Settings) { s.FundingPercent = "-0.5" }, "funding_percent"},
		{"step zero", func(s *Settings) { s.RetailStep = "0" }, "retail_step"},
		{"step 0.00", func(s *Settings) { s.RetailStep = "0.00" }, "retail_step"},
		{"step with three decimals", func(s *Settings) { s.RetailStep = "0.125" }, "retail_step"},
		{"step 0.05", func(s *Settings) { s.RetailStep = "0.05" }, ""},
		{"margin zero", func(s *Settings) { s.MinShopMargin = "0" }, ""},
		{"margin with three decimals", func(s *Settings) { s.MinShopMargin = "0.001" }, "min_shop_margin"},
		{"bills markup junk", func(s *Settings) { s.Bills.RetailMarkupPercent = "five" }, "bills.retail_markup_percent"},
		{"huge markup", func(s *Settings) { s.Airtime.ShopMarkupPercent = "100000" }, ""},
		{"a billion percent", func(s *Settings) { s.Airtime.ShopMarkupPercent = "1000000000" }, ""},
		{"too many digits", func(s *Settings) { s.Airtime.ShopMarkupPercent = "1000000000000" }, "airtime.shop_markup_percent"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			settings := Settings{}
			c.mutate(&settings)
			problems := settings.Validate()
			if c.path == "" {
				if len(problems) != 0 {
					t.Fatalf("want valid, got %v", problems)
				}
				return
			}
			if len(problems) != 1 || problems[0].Path != c.path {
				t.Fatalf("want one problem at %s, got %v", c.path, problems)
			}
		})
	}
	tooMany := Settings{Popular: make([]string, 61)}
	for i := range tooMany.Popular {
		tooMany.Popular[i] = "NE"
	}
	if problems := tooMany.Validate(); len(problems) == 0 || problems[0].Path != "popular" {
		t.Fatalf("an absurd popular list is refused: %v", problems)
	}
}

func TestNormalized(t *testing.T) {
	got := Settings{
		USDRate:        " 9.71 ",
		FundingPercent: " ",
		Airtime:        ServicePricing{OrderMode: " usd "},
		Margin:         Margin{RoundStep: " 0.5"},
		Popular:        []string{" ne", "ML ", "ne", "", "ml"},
	}.Normalized()
	want := Settings{
		USDRate:        "9.71",
		FundingPercent: "0",
		Airtime:        ServicePricing{OrderMode: "usd", USDBufferPercent: "0.5", ServiceFeeLYD: "2"},
		Bills:          ServicePricing{OrderMode: "auto", USDBufferPercent: "0.5", ServiceFeeLYD: "0"},
		Margin: Margin{FixedLYD: "0.50", MinMarginLYD: "0.50", Brackets: defaultBrackets(), ShopSharePercent: "35", RoundStep: "0.5", MinShopMargin: "0.10",
			MarketGapPercent: "3", MarketMaxAgeDays: "30", CompanyMinPct: "3", CompanyMinLYD: "0.50", ShopMinPct: "2.5", ShopMinLYD: "0.50", LocalCompanyShare: "20"},
		USDRateSource: "fulus", USDRateSeries: "cash", USDRateBufferPercent: "0", USDRateMaxAge: "48h",
		Popular: []string{"NE", "ML"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("\n got %+v\nwant %+v", got, want)
	}
	if again := got.Normalized(); !reflect.DeepEqual(again, got) {
		t.Fatalf("normalizing twice must change nothing: %+v", again)
	}
	clone := got.Clone()
	clone.Popular[0] = "ZZ"
	if got.Popular[0] != "NE" {
		t.Fatal("Clone must not share the popular list")
	}
}

func TestEncodeSettingsIsStableAndNormalized(t *testing.T) {
	a, shaA, err := EncodeSettings(Settings{USDRate: "9.71", Popular: []string{"ne", "ML"}})
	if err != nil {
		t.Fatal(err)
	}
	b, shaB, err := EncodeSettings(Settings{Popular: []string{"NE", "ml", "NE"}, USDRate: " 9.71"})
	if err != nil {
		t.Fatal(err)
	}
	if string(a) != string(b) || shaA != shaB || len(shaA) != 64 {
		t.Fatalf("the same settings must encode alike:\n%s\n%s", a, b)
	}
	if !strings.Contains(string(a), `"usd_rate":"9.71"`) || !strings.Contains(string(a), `"round_step":"0.25"`) ||
		!strings.Contains(string(a), `"popular":["NE","ML"]`) {
		t.Fatalf("the stored form carries the defaults it fills in: %s", a)
	}
	_, shaC, _ := EncodeSettings(Settings{USDRate: "9.72", Popular: []string{"NE", "ML"}})
	if shaC == shaA {
		t.Fatal("different settings must have different fingerprints")
	}
	// What is stored reads back as the same settings.
	parsed, err := ParseSettings(a)
	if err != nil || !reflect.DeepEqual(parsed, Settings{USDRate: "9.71", Popular: []string{"NE", "ML"}}.Normalized()) {
		t.Fatalf("round trip: %+v %v", parsed, err)
	}
}

func TestUSDToLYD(t *testing.T) {
	cases := []struct {
		name     string
		settings Settings
		usd      string
		want     string // "" = not convertible
	}{
		{"no rate", Settings{}, "5", ""},
		{"blank rate", Settings{USDRate: " "}, "5", ""},
		{"zero rate", Settings{USDRate: "0"}, "5", ""},
		{"junk rate", Settings{USDRate: "abc"}, "5", ""},
		{"junk funding", Settings{USDRate: "9.71", FundingPercent: "x"}, "5", ""},
		{"five dollars", Settings{USDRate: "9.71"}, "5", "48.55"},
		{"nothing to convert is nothing", Settings{USDRate: "9.71"}, "0", "0"},
		{"a negative amount is refused", Settings{USDRate: "9.71"}, "-1", ""},
		{"funding on top, exactly", Settings{USDRate: "9.71", FundingPercent: "2.5"}, "10", "99.5275"},
		{"many decimals of rate stay exact", Settings{USDRate: "9.710001", FundingPercent: "0"}, "100", "971.0001"},
		{"cents of a dollar", Settings{USDRate: "9.71"}, "0.35", "3.3985"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := c.settings.USDToLYD(settingsRatOf(t, c.usd))
			if c.want == "" {
				if ok || got != nil {
					t.Fatalf("want not convertible, got %v %v", got, ok)
				}
				return
			}
			if !ok || got.Cmp(settingsRatOf(t, c.want)) != 0 {
				t.Fatalf("got %v %v, want %s", got, ok, c.want)
			}
		})
	}
	if got, ok := (Settings{USDRate: "9.71"}).USDToLYD(nil); ok || got != nil {
		t.Fatalf("a missing amount is not converted: %v %v", got, ok)
	}
	// The argument is never changed.
	usd := settingsRatOf(t, "7")
	_, _ = Settings{USDRate: "9.71", FundingPercent: "3"}.USDToLYD(usd)
	if usd.Cmp(settingsRatOf(t, "7")) != 0 {
		t.Fatal("USDToLYD changed its argument")
	}
}

func TestFormatDinars(t *testing.T) {
	cases := map[string]string{
		"91.3":         "91.30",
		"96.5":         "96.50",
		"0":            "0.00",
		"5":            "5.00",
		"1234567.891":  "1234567.89",
		"0.005":        "0.01",
		"0.004":        "0.00",
		"-1.5":         "-1.50",
		"100000000.01": "100000000.01",
	}
	for in, want := range cases {
		if got := FormatDinars(settingsRatOf(t, in)); got != want {
			t.Errorf("FormatDinars(%s) = %q, want %q", in, got, want)
		}
	}
	if FormatDinars(nil) != "" {
		t.Error("FormatDinars(nil) must be empty")
	}
}

func TestDemoDefaultsNameTheKnobsNobodyDecided(t *testing.T) {
	all := []string{
		"funding_percent", "margin", "airtime.order_mode", "airtime.usd_buffer_percent", "airtime.service_fee_lyd",
		"bills.order_mode", "bills.usd_buffer_percent", "popular",
	}
	if got := DefaultSettings().DemoDefaults(); !reflect.DeepEqual(got, all) {
		t.Fatalf("defaults: %v", got)
	}
	if got := (Settings{USDRate: "9.71"}).DemoDefaults(); !reflect.DeepEqual(got, all) {
		t.Fatalf("a rate alone decides nothing else: %v", got)
	}
	decided := Settings{
		USDRate:        "9.71",
		FundingPercent: "1.5",
		Margin:         Margin{FixedLYD: "1"},
		Popular:        []string{"NE", "ML"},
	}
	want := []string{
		"airtime.order_mode", "airtime.usd_buffer_percent", "airtime.service_fee_lyd", "bills.order_mode", "bills.usd_buffer_percent",
	}
	if got := decided.DemoDefaults(); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	if got := (Settings{
		FundingPercent: "1",
		Airtime:        ServicePricing{OrderMode: "local", USDBufferPercent: "1", ServiceFeeLYD: "3"},
		Bills:          ServicePricing{OrderMode: "local", USDBufferPercent: "1"},
		Margin:         Margin{RoundStep: "1", FixedLYD: "1"}, Popular: []string{"EG"},
	}).DemoDefaults(); len(got) != 0 || got == nil {
		t.Fatalf("everything decided lists nothing (and an empty list, not null): %#v", got)
	}
}

func TestPricedNeedsAUsableRate(t *testing.T) {
	for rate, want := range map[string]bool{"": false, " ": false, "0": false, "abc": false, "9.71": true, " 9.71 ": true} {
		if got := (Settings{USDRate: rate}).Priced(); got != want {
			t.Errorf("Priced(%q) = %v, want %v", rate, got, want)
		}
	}
}

func TestEqualComparesWhatIsPriced(t *testing.T) {
	base := Settings{USDRate: "9.71", FundingPercent: "1.5", RetailStep: "0.5", Popular: []string{"NE", "ML"}}
	cases := []struct {
		name  string
		other Settings
		want  bool
	}{
		{"itself", base, true},
		{"numbers compare as numbers", Settings{USDRate: "9.710", FundingPercent: "1.50", RetailStep: "0.50", Popular: []string{"ne", " ML"}}, true},
		{"defaults written out or left blank", Settings{USDRate: "9.71", FundingPercent: "1.5", RetailStep: "0.5", Popular: []string{"NE", "ML"},
			Airtime: ServicePricing{ShopMarkupPercent: "2.0", RetailMarkupPercent: "5.50"}, MinShopMargin: "0.1"}, true},
		{"another rate", Settings{USDRate: "9.72", FundingPercent: "1.5", RetailStep: "0.5", Popular: []string{"NE", "ML"}}, false},
		{"no rate", Settings{FundingPercent: "1.5", RetailStep: "0.5", Popular: []string{"NE", "ML"}}, false},
		{"another markup", Settings{USDRate: "9.71", FundingPercent: "1.5", RetailStep: "0.5", Popular: []string{"NE", "ML"},
			Bills: ServicePricing{RetailMarkupPercent: "6"}}, false},
		{"another margin", Settings{USDRate: "9.71", FundingPercent: "1.5", RetailStep: "0.5", Popular: []string{"NE", "ML"}, MinShopMargin: "0.2"}, false},
		{"another airtime order mode", Settings{USDRate: "9.71", FundingPercent: "1.5", RetailStep: "0.5", Popular: []string{"NE", "ML"},
			Airtime: ServicePricing{OrderMode: "local"}}, false},
		{"another bills order mode", Settings{USDRate: "9.71", FundingPercent: "1.5", RetailStep: "0.5", Popular: []string{"NE", "ML"},
			Bills: ServicePricing{OrderMode: "LOCAL"}}, false},
		{"the default modes written out in capitals", Settings{USDRate: "9.71", FundingPercent: "1.5", RetailStep: "0.5", Popular: []string{"NE", "ML"},
			Airtime: ServicePricing{OrderMode: "USD", USDBufferPercent: "0.50"}, Bills: ServicePricing{OrderMode: "Auto"}}, true},
		{"another buffer", Settings{USDRate: "9.71", FundingPercent: "1.5", RetailStep: "0.5", Popular: []string{"NE", "ML"},
			Bills: ServicePricing{USDBufferPercent: "1"}}, false},
		{"the same countries in another order", Settings{USDRate: "9.71", FundingPercent: "1.5", RetailStep: "0.5", Popular: []string{"ML", "NE"}}, false},
		{"fewer countries", Settings{USDRate: "9.71", FundingPercent: "1.5", RetailStep: "0.5", Popular: []string{"NE"}}, false},
	}
	for _, c := range cases {
		if got := base.Equal(c.other); got != c.want {
			t.Errorf("%s: Equal = %v, want %v", c.name, got, c.want)
		}
		if got := c.other.Equal(base); got != c.want {
			t.Errorf("%s: Equal is not symmetric", c.name)
		}
	}
	if !(Settings{}).Equal(DefaultSettings()) {
		t.Error("blank settings are the defaults")
	}
}

func TestOrderModesAndTheBuffer(t *testing.T) {
	defaults := DefaultSettings()
	if defaults.OrderMode("airtime") != OrderModeUSD || defaults.OrderMode("bill") != OrderModeAuto ||
		defaults.OrderMode("anything else") != OrderModeUSD {
		t.Fatalf("the defaults keep Reloadly's commission: %s / %s", defaults.OrderMode("airtime"), defaults.OrderMode("bill"))
	}
	if got := defaults.USDBufferPercent("airtime"); got == nil || got.Cmp(big.NewRat(1, 2)) != 0 {
		t.Fatalf("buffer: %v", got)
	}
	local := Settings{
		Airtime: ServicePricing{OrderMode: " Local ", USDBufferPercent: "1.25"},
		Bills:   ServicePricing{OrderMode: "LOCAL"},
	}.Normalized()
	if local.OrderMode("airtime") != OrderModeLocal || local.OrderMode("bill") != OrderModeLocal ||
		local.USDBufferPercent("airtime").Cmp(big.NewRat(5, 4)) != 0 || local.USDBufferPercent("bill").Cmp(big.NewRat(1, 2)) != 0 {
		t.Fatalf("modes and buffers: %+v", local)
	}
	// A mode another kind accepts is not accepted here.
	for _, c := range []struct {
		name   string
		mutate func(*Settings)
		path   string
	}{
		{"auto is not an airtime mode", func(s *Settings) { s.Airtime.OrderMode = "auto" }, "airtime.order_mode"},
		{"usd is not a bills mode", func(s *Settings) { s.Bills.OrderMode = "usd" }, "bills.order_mode"},
		{"an unknown mode", func(s *Settings) { s.Airtime.OrderMode = "dollars" }, "airtime.order_mode"},
		{"a negative buffer", func(s *Settings) { s.Airtime.USDBufferPercent = "-1" }, "airtime.usd_buffer_percent"},
		{"a buffer that is a surcharge", func(s *Settings) { s.Bills.USDBufferPercent = "25.01" }, "bills.usd_buffer_percent"},
		{"a buffer of words", func(s *Settings) { s.Bills.USDBufferPercent = "half" }, "bills.usd_buffer_percent"},
		{"the largest buffer", func(s *Settings) { s.Airtime.USDBufferPercent = "25" }, ""},
		{"no buffer at all", func(s *Settings) { s.Airtime.USDBufferPercent = "0" }, ""},
		{"local airtime", func(s *Settings) { s.Airtime.OrderMode = "local" }, ""},
		{"local bills", func(s *Settings) { s.Bills.OrderMode = "local" }, ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			settings := Settings{}
			c.mutate(&settings)
			problems := settings.Validate()
			if c.path == "" {
				if len(problems) != 0 {
					t.Fatalf("want valid, got %v", problems)
				}
				return
			}
			if len(problems) != 1 || problems[0].Path != c.path {
				t.Fatalf("want one problem at %s, got %v", c.path, problems)
			}
		})
	}
	// The stored form carries the modes, and reads back the same.
	raw, _, err := EncodeSettings(Settings{USDRate: "9.71", Airtime: ServicePricing{OrderMode: "local"}})
	if err != nil || !strings.Contains(string(raw), `"order_mode":"local"`) || !strings.Contains(string(raw), `"order_mode":"auto"`) {
		t.Fatalf("encoded: %s %v", raw, err)
	}
	parsed, err := ParseSettings(raw)
	if err != nil || parsed.OrderMode("airtime") != OrderModeLocal || parsed.OrderMode("bill") != OrderModeAuto {
		t.Fatalf("round trip: %+v %v", parsed, err)
	}
	// A version published before modes existed reads with the defaults.
	old, err := ParseSettings([]byte(`{"usd_rate":"9.71","funding_percent":"0","airtime":{"shop_markup_percent":"2","retail_markup_percent":"5.5"},"bills":{"shop_markup_percent":"2","retail_markup_percent":"5.5"},"retail_step":"0.25","min_shop_margin":"0.10","popular":["NE"]}`))
	if err != nil || old.OrderMode("airtime") != OrderModeUSD || old.OrderMode("bill") != OrderModeAuto {
		t.Fatalf("an earlier version: %+v %v", old, err)
	}
}
