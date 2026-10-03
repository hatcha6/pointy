package resala

import "unicode/utf16"

// SMS part sizes. A text that fits the GSM 03.38 alphabet goes out in 7-bit
// septets: 160 in a single SMS, 153 in each part of a longer one (the rest of
// each part carries the header that joins them on the phone). One character
// outside that alphabet — every Arabic letter — sends the WHOLE text as UCS-2:
// 70 in a single SMS, 67 in each part.
//
// Carriers bill per part, so a part is what a message costs: the shop's
// backend counts the same way (apps/messaging/segments.py).
const (
	gsm7SingleSeptets = 160
	gsm7PartSeptets   = 153
	ucs2SingleUnits   = 70
	ucs2PartUnits     = 67
)

// gsm7Basic is the GSM 03.38 basic alphabet; gsm7Extension holds the
// characters that cost two septets (an escape and the character).
const (
	gsm7Basic = "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\x1bÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?" +
		"¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
	gsm7Extension = "^{}\\[~]|€"
)

var gsm7Septets = func() map[rune]int {
	septets := map[rune]int{}
	for _, r := range gsm7Basic {
		septets[r] = 1
	}
	for _, r := range gsm7Extension {
		septets[r] = 2
	}
	return septets
}()

// CountParts is how many SMS a text goes out as, and so is paid for as. An
// empty text is still one.
func CountParts(text string) int {
	septets := 0
	for _, r := range text {
		cost, ok := gsm7Septets[r]
		if !ok {
			return UCS2Parts(len(utf16.Encode([]rune(text))))
		}
		septets += cost
	}
	if septets <= gsm7SingleSeptets {
		return 1
	}
	return ceilDiv(septets, gsm7PartSeptets)
}

// UCS2Parts is how many SMS a UCS-2 text of the given length goes out as. The
// length is in UTF-16 units, so a character beyond the basic plane (an emoji)
// counts twice.
func UCS2Parts(units int) int {
	if units <= ucs2SingleUnits {
		return 1
	}
	return ceilDiv(units, ucs2PartUnits)
}

func ceilDiv(n, d int) int {
	return (n + d - 1) / d
}
