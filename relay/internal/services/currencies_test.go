package services

import (
	"encoding/json"
	"os"
	"testing"
	"unicode"
)

type liveCountry struct {
	ISOName      string   `json:"isoName"`
	Name         string   `json:"name"`
	CurrencyCode string   `json:"currencyCode"`
	CallingCodes []string `json:"callingCodes"`
}

func loadLiveCountries(t *testing.T) []liveCountry {
	t.Helper()
	raw, err := os.ReadFile("testdata/countries_live.json")
	if err != nil {
		t.Fatal(err)
	}
	var countries []liveCountry
	if err := json.Unmarshal(raw, &countries); err != nil {
		t.Fatal(err)
	}
	if len(countries) < 100 {
		t.Fatalf("the live country list should hold well over a hundred countries, got %d", len(countries))
	}
	return countries
}

func TestEveryCurrencyReloadlyServesHasAnArabicName(t *testing.T) {
	for _, country := range loadLiveCountries(t) {
		if !HasCurrencyName(country.CurrencyCode) {
			t.Errorf("%s (%s) has no Arabic currency name", country.CurrencyCode, country.Name)
		}
	}
}

func TestCurrencyNamesAreArabicAndShort(t *testing.T) {
	for code, name := range currencyNamesAR {
		arabic := false
		for _, r := range name {
			if unicode.Is(unicode.Arabic, r) {
				arabic = true
			}
			if unicode.IsLetter(r) && unicode.Is(unicode.Latin, r) {
				t.Errorf("%s: %q must not contain Latin letters", code, name)
			}
		}
		if !arabic {
			t.Errorf("%s: %q is not Arabic", code, name)
		}
		if len([]rune(name)) > 26 {
			t.Errorf("%s: %q is too long for an amount line", code, name)
		}
	}
}

func TestTheNamesTheOwnerAskedFor(t *testing.T) {
	for code, want := range map[string]string{
		"XOF": "فرنك أفريقي", "XAF": "فرنك أفريقي", "NGN": "نيرة نيجيرية", "EGP": "جنيه مصري",
		"TND": "دينار تونسي", "GHS": "سيدي غاني", "TRY": "ليرة تركية", "PKR": "روبية باكستانية",
		"BDT": "تاكا بنغلاديشية", "PHP": "بيزو فلبيني", "INR": "روبية هندية", "MAD": "درهم مغربي",
		"DZD": "دينار جزائري", "USD": "دولار أمريكي",
	} {
		if got := CurrencyName(code); got != want {
			t.Errorf("%s: got %q want %q", code, got, want)
		}
	}
	if got := CurrencyName(" xyz "); got != "XYZ" {
		t.Errorf("an unknown currency is written by its code, got %q", got)
	}
	if got := CurrencyName("ngn"); got != "نيرة نيجيرية" {
		t.Errorf("codes are case-insensitive, got %q", got)
	}
}
