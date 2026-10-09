package services

import (
	"strings"

	"pointy/relay/internal/vouchers"
)

// extraCountryNamesAR are countries Reloadly lists that the relay's card shop
// table (vouchers.CountryName) does not name, in the same short everyday form.
var extraCountryNamesAR = map[string]string{
	"AN": "جزر الأنتيل الهولندية",
}

// CountryNameAR is the Arabic short name of a country code, "" when the relay
// knows none. The card shop's table is the main source; it is the relay's one
// list of countries, so the services use it rather than keep a second.
func CountryNameAR(code string) string {
	code = strings.ToUpper(strings.TrimSpace(code))
	if name := vouchers.CountryName(code); name != "" {
		return name
	}
	return extraCountryNamesAR[code]
}
