package services

import "strings"

// currencyNamesAR are the names a cashier says next to an amount: «5,000 فرنك
// أفريقي», «2,000 نيرة نيجيرية». They are short on purpose and in modern
// standard Arabic. The CFA francs of the west (XOF) and of the centre (XAF) share
// one name: no country has both, so the amount on a screen is never ambiguous.
// A code without an entry is written as the code itself (CurrencyName).
var currencyNamesAR = map[string]string{
	"AED": "درهم إماراتي",
	"AFN": "أفغاني",
	"ALL": "ليك ألباني",
	"AMD": "درام أرمني",
	"ANG": "غيلدر أنتيلي",
	"AOA": "كوانزا أنغولي",
	"ARS": "بيزو أرجنتيني",
	"AUD": "دولار أسترالي",
	"AWG": "فلورن أروبي",
	"AZN": "مانات أذربيجاني",
	"BBD": "دولار بربادوسي",
	"BDT": "تاكا بنغلاديشية",
	"BHD": "دينار بحريني",
	"BIF": "فرنك بوروندي",
	"BMD": "دولار برمودي",
	"BOB": "بوليفيانو بوليفي",
	"BRL": "ريال برازيلي",
	"BSD": "دولار بهامي",
	"BWP": "بولا بوتسواني",
	"BYN": "روبل بيلاروسي",
	"BZD": "دولار بليزي",
	"CAD": "دولار كندي",
	"CHF": "فرنك سويسري",
	"CLP": "بيزو تشيلي",
	"CNY": "يوان صيني",
	"COP": "بيزو كولومبي",
	"CRC": "كولون كوستاريكي",
	"CUP": "بيزو كوبي",
	"CVE": "إسكودو الرأس الأخضر",
	"DKK": "كرونة دنماركية",
	"DOP": "بيزو دومينيكاني",
	"DZD": "دينار جزائري",
	"EGP": "جنيه مصري",
	"ETB": "بير إثيوبي",
	"EUR": "يورو",
	"FJD": "دولار فيجي",
	"GBP": "جنيه إسترليني",
	"GEL": "لاري جورجي",
	"GHS": "سيدي غاني",
	"GMD": "دالاسي غامبي",
	"GNF": "فرنك غيني",
	"GTQ": "كيتزال غواتيمالي",
	"GYD": "دولار غياني",
	"HNL": "لمبيرا هندوراسي",
	"HTG": "غورد هايتي",
	"IDR": "روبية إندونيسية",
	"ILS": "شيكل",
	"INR": "روبية هندية",
	"IQD": "دينار عراقي",
	"IRR": "ريال إيراني",
	"JMD": "دولار جامايكي",
	"JOD": "دينار أردني",
	"KES": "شلن كيني",
	"KGS": "سوم قيرغيزي",
	"KMF": "فرنك جزر القمر",
	"KRW": "وون كوري",
	"KWD": "دينار كويتي",
	"KYD": "دولار جزر كايمان",
	"KZT": "تينغ كازاخستاني",
	"LAK": "كيب لاوسي",
	"LKR": "روبية سريلانكية",
	"LYD": "دينار ليبي",
	"MAD": "درهم مغربي",
	"MDL": "ليو مولدوفي",
	"MGA": "أرياري مدغشقري",
	"MKD": "دينار مقدوني",
	"MMK": "كيات ميانماري",
	"MRU": "أوقية موريتانية",
	"MWK": "كواشا ملاوية",
	"MXN": "بيزو مكسيكي",
	"MYR": "رينغيت ماليزي",
	"MZN": "متيكال موزمبيقي",
	"NAD": "دولار ناميبي",
	"NGN": "نيرة نيجيرية",
	"NIO": "كوردوبا نيكاراغوي",
	"NPR": "روبية نيبالية",
	"OMR": "ريال عُماني",
	"PEN": "سول بيروفي",
	"PGK": "كينا بابوا غينيا الجديدة",
	"PHP": "بيزو فلبيني",
	"PKR": "روبية باكستانية",
	"PLN": "زلوتي بولندي",
	"PYG": "غواراني باراغواي",
	"QAR": "ريال قطري",
	"RUB": "روبل روسي",
	"RWF": "فرنك رواندي",
	"SAR": "ريال سعودي",
	"SGD": "دولار سنغافوري",
	"SLE": "ليون سيراليوني",
	"SRD": "دولار سورينامي",
	"SZL": "ليلانجيني إسواتيني",
	"THB": "باخت تايلاندي",
	"TJS": "سوموني طاجيكي",
	"TMT": "مانات تركمانستاني",
	"TND": "دينار تونسي",
	"TOP": "بانغا تونغي",
	"TRY": "ليرة تركية",
	"TTD": "دولار ترينيداد وتوباغو",
	"TZS": "شلن تنزاني",
	"UAH": "هريفنيا أوكرانية",
	"UGX": "شلن أوغندي",
	"USD": "دولار أمريكي",
	"UYU": "بيزو أوروغواي",
	"UZS": "سوم أوزبكي",
	"VES": "بوليفار فنزويلي",
	"VND": "دونغ فيتنامي",
	"VUV": "فاتو فانواتي",
	"WST": "تالا ساموي",
	"XAF": "فرنك أفريقي",
	"XCD": "دولار شرق الكاريبي",
	"XOF": "فرنك أفريقي",
	"YER": "ريال يمني",
	"ZAR": "راند جنوب أفريقي",
	"ZMW": "كواشا زامبي",
}

// CurrencyName is the everyday short Arabic name of a currency code, or the code
// itself (upper-cased) when the table has none, so a screen always shows
// something a person can read.
func CurrencyName(code string) string {
	code = strings.ToUpper(strings.TrimSpace(code))
	if name, ok := currencyNamesAR[code]; ok {
		return name
	}
	return code
}

// HasCurrencyName reports whether a code has an Arabic name of its own.
func HasCurrencyName(code string) bool {
	_, ok := currencyNamesAR[strings.ToUpper(strings.TrimSpace(code))]
	return ok
}
