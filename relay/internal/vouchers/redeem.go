package vouchers

import (
	"fmt"
	"net/url"
	"regexp"
	"strings"
)

// CodePlaceholder stands for a card's code in a Redeem template.
const CodePlaceholder = "{code}"

const (
	RedeemDial = "dial"
	RedeemLink = "link"
)

// Redeem is how a customer's phone redeems a brand's card in one tap: the
// string it dials, or the issuer's own page. It is only ever listed from the
// issuer's published instructions or its own links: a wrong one costs a customer
// their first try at a card they paid for, with nobody to ask.
type Redeem struct {
	// Kind is RedeemDial or RedeemLink.
	Kind string `json:"kind"`
	// Template is what to dial or open. A dial must carry CodePlaceholder. A
	// link may not: the app copies the code first either way, so a page that
	// takes no code from its address is still one tap and a paste away.
	Template string `json:"template"`
	// ByCountry replaces Template for an item of that country, for an issuer
	// whose cards only work on their own country's site.
	ByCountry map[string]string `json:"by_country,omitempty"`
	// Pattern is the shape of a code the template takes, with spaces and dashes
	// removed. A code that does not match gets no button.
	Pattern string `json:"pattern,omitempty"`
}

var dialTemplate = regexp.MustCompile(`^[0-9*#]*\{code\}[0-9*#]*$`)

func validateRedeem(add func(path, format string, args ...any), path string, redeem Redeem) {
	check := func(path, template string) {
		switch redeem.Kind {
		case RedeemDial:
			if !dialTemplate.MatchString(template) {
				add(path, "a dial is digits, * and # around one %s", CodePlaceholder)
			}
		case RedeemLink:
			if err := checkRedeemLink(template); err != nil {
				add(path, "%v", err)
			}
		}
	}
	if redeem.Kind != RedeemDial && redeem.Kind != RedeemLink {
		add(path+".kind", "%q is not %s or %s", redeem.Kind, RedeemDial, RedeemLink)
	}
	check(path+".template", redeem.Template)
	if redeem.Kind == RedeemDial && len(redeem.ByCountry) > 0 {
		add(path+".by_country", "only a link differs by country")
	}
	for country, template := range redeem.ByCountry {
		check(fmt.Sprintf("%s.by_country[%s]", path, country), template)
	}
	if redeem.Pattern != "" {
		if _, err := regexp.Compile(redeem.Pattern); err != nil {
			add(path+".pattern", "does not compile: %v", err)
		}
	}
}

// checkRedeemLink holds a link to https and a plain host, as it carries the
// code a customer paid for.
func checkRedeemLink(template string) error {
	if strings.Count(template, CodePlaceholder) > 1 {
		return fmt.Errorf("at most one %s", CodePlaceholder)
	}
	parsed, err := url.Parse(strings.ReplaceAll(template, CodePlaceholder, "CODE"))
	if err != nil {
		return fmt.Errorf("not a link: %v", err)
	}
	if parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil {
		return fmt.Errorf("a link must be https on a plain host")
	}
	if strings.Contains(parsed.Host, "CODE") {
		return fmt.Errorf("the code cannot be in the host")
	}
	return nil
}

func normalizeRedeem(redeem *Redeem) *Redeem {
	if redeem == nil {
		return nil
	}
	out := Redeem{
		Kind:     strings.TrimSpace(redeem.Kind),
		Template: strings.TrimSpace(redeem.Template),
		Pattern:  strings.TrimSpace(redeem.Pattern),
	}
	if len(redeem.ByCountry) > 0 {
		out.ByCountry = make(map[string]string, len(redeem.ByCountry))
		for country, template := range redeem.ByCountry {
			out.ByCountry[strings.ToUpper(strings.TrimSpace(country))] = strings.TrimSpace(template)
		}
	}
	return &out
}
