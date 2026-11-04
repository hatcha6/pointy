package vouchers

import (
	"fmt"
	"testing"
)

func TestValidateRedeem(t *testing.T) {
	cases := []struct {
		name   string
		redeem Redeem
		ok     bool
	}{
		{"a call", Redeem{Kind: RedeemDial, Template: "120{code}"}, true},
		{"a USSD code", Redeem{Kind: RedeemDial, Template: "*112*{code}#"}, true},
		{"a link taking the code", Redeem{Kind: RedeemLink, Template: "https://apps.apple.com/redeem?code={code}", Pattern: "X[A-Z0-9]{15}"}, true},
		{"a page, the code pasted", Redeem{Kind: RedeemLink, Template: "https://www.roblox.com/redeem"}, true},
		{"a link per country", Redeem{Kind: RedeemLink, Template: "https://www.amazon.com/gc/redeem?claimCode={code}", ByCountry: map[string]string{"AE": "https://www.amazon.ae/gc/redeem?claimCode={code}"}}, true},
		{"a dial without the code", Redeem{Kind: RedeemDial, Template: "120"}, false},
		{"a dial with letters", Redeem{Kind: RedeemDial, Template: "call{code}"}, false},
		{"a dial by country", Redeem{Kind: RedeemDial, Template: "120{code}", ByCountry: map[string]string{"LY": "121{code}"}}, false},
		{"plain http", Redeem{Kind: RedeemLink, Template: "http://example.com/redeem?code={code}"}, false},
		{"another scheme", Redeem{Kind: RedeemLink, Template: "javascript:alert('{code}')"}, false},
		{"a login in the host", Redeem{Kind: RedeemLink, Template: "https://apple.com@evil.example/{code}"}, false},
		{"the code as the host", Redeem{Kind: RedeemLink, Template: "https://{code}.evil.example/"}, false},
		{"the code twice", Redeem{Kind: RedeemLink, Template: "https://example.com/{code}?c={code}"}, false},
		{"a bad country link", Redeem{Kind: RedeemLink, Template: "https://example.com/", ByCountry: map[string]string{"AE": "http://example.ae/"}}, false},
		{"an unknown kind", Redeem{Kind: "sms", Template: "120{code}"}, false},
		{"a pattern that does not compile", Redeem{Kind: RedeemLink, Template: "https://example.com/", Pattern: "("}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var problems []string
			validateRedeem(func(path, format string, args ...any) {
				problems = append(problems, path+": "+fmt.Sprintf(format, args...))
			}, "brands[0].redeem", tc.redeem)
			if tc.ok && len(problems) > 0 {
				t.Fatalf("refused: %v", problems)
			}
			if !tc.ok && len(problems) == 0 {
				t.Fatal("accepted")
			}
		})
	}
}

func TestNormalizeRedeem(t *testing.T) {
	if normalizeRedeem(nil) != nil {
		t.Fatal("no redeem stays none")
	}
	got := normalizeRedeem(&Redeem{
		Kind:      " link ",
		Template:  " https://a.example/ ",
		ByCountry: map[string]string{" ae ": " https://b.example/ "},
	})
	if got.Kind != RedeemLink || got.Template != "https://a.example/" || got.ByCountry["AE"] != "https://b.example/" {
		t.Fatalf("got %+v", got)
	}
}
