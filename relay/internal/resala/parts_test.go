package resala

import (
	"strings"
	"testing"
)

// The same cases as the shop backend's SegmentCountingTests, so the relay and
// the shop never disagree on what a message costs.
func TestCountPartsMatchesTheShopsCount(t *testing.T) {
	cases := []struct {
		name string
		text string
		want int
	}{
		{"empty is still one", "", 1},
		{"short latin", "Hello, your order is ready.", 1},
		{"160 septets fit one", strings.Repeat("A", 160), 1},
		{"161 septets take two", strings.Repeat("A", 161), 2},
		{"153 per part after that", strings.Repeat("A", 306), 2},
		{"307 septets take three", strings.Repeat("A", 307), 3},
		{"an extension character costs two septets", strings.Repeat("€", 80), 1},
		{"81 of them do not fit", strings.Repeat("€", 81), 2},
		{"70 arabic letters fit one", strings.Repeat("ش", 70), 1},
		{"71 take two", strings.Repeat("ش", 71), 2},
		{"67 per part after that", strings.Repeat("ش", 134), 2},
		{"135 take three", strings.Repeat("ش", 135), 3},
		{"one arabic letter makes the whole text ucs-2", strings.Repeat("A", 70) + "ش", 2},
		{"35 emoji are 70 units", strings.Repeat("😀", 35), 1},
		{"36 emoji are 72", strings.Repeat("😀", 36), 2},
	}
	for _, tc := range cases {
		if got := CountParts(tc.text); got != tc.want {
			t.Errorf("%s: CountParts = %d, want %d", tc.name, got, tc.want)
		}
	}
}

func TestCountPartsOfARealInvoice(t *testing.T) {
	// The approved invoice text with a typical shop name and amount: one SMS.
	short := RenderBody("شكرًا لتسوقك من $1. فاتورتك رقم $2 بقيمة $3.", []string{"محل التجربة", "000123", "12.500 د.ل"})
	if got := CountParts(short); got != 1 {
		t.Fatalf("a short invoice is one SMS, got %d (%d characters)", got, len([]rune(short)))
	}
	// The same message from a shop with a long name runs past 70 letters.
	long := RenderBody("شكرًا لتسوقك من $1. فاتورتك رقم $2 بقيمة $3.", []string{"مؤسسة النور للمواد الغذائية والمنظفات", "000123", "12.500 د.ل"})
	if got := CountParts(long); got != 2 {
		t.Fatalf("a long invoice is two SMS, got %d (%d characters)", got, len([]rune(long)))
	}
}

func TestUCS2Parts(t *testing.T) {
	for units, want := range map[int]int{0: 1, 70: 1, 71: 2, 134: 2, 135: 3, 201: 3, 202: 4} {
		if got := UCS2Parts(units); got != want {
			t.Errorf("UCS2Parts(%d) = %d, want %d", units, got, want)
		}
	}
}
