package vouchers

import (
	"encoding/base64"
	"errors"
	"strings"
	"testing"
)

func TestStockSealerRoundTripsAndBindsTheItem(t *testing.T) {
	key, err := GenerateStockKey()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := ParseStockKey(key)
	if err != nil {
		t.Fatal(err)
	}
	sealer, err := NewStockSealer(raw)
	if err != nil {
		t.Fatal(err)
	}
	sealed, err := sealer.Seal("psn-10", "1234-5678-9012")
	if err != nil || !strings.HasPrefix(sealed, "v1:") || strings.Contains(sealed, "1234") {
		t.Fatalf("sealed %q %v", sealed, err)
	}
	again, _ := sealer.Seal("psn-10", "1234-5678-9012")
	if again == sealed {
		t.Fatal("each seal takes a fresh nonce")
	}
	if code, err := sealer.Open("psn-10", sealed); err != nil || code != "1234-5678-9012" {
		t.Fatalf("open: %q %v", code, err)
	}
	if _, err := sealer.Open("psn-20", sealed); !errors.Is(err, ErrStockSealUnreadable) {
		t.Fatalf("a code moved to another item's row must not open: %v", err)
	}
	other, _ := NewStockSealer(make([]byte, StockKeyBytes))
	if _, err := other.Open("psn-10", sealed); !errors.Is(err, ErrStockSealUnreadable) {
		t.Fatalf("another key must not open it: %v", err)
	}
	if sealer.Fingerprint("A") != sealer.Fingerprint("A") || sealer.Fingerprint("A") == sealer.Fingerprint("B") ||
		sealer.Fingerprint("A") == other.Fingerprint("A") {
		t.Fatal("fingerprints are stable per key and differ by code and key")
	}
}

func TestParseStockKey(t *testing.T) {
	key := make([]byte, StockKeyBytes)
	key[0] = 0xfb
	for _, text := range []string{
		base64.StdEncoding.EncodeToString(key),
		base64.RawURLEncoding.EncodeToString(key),
		"  " + base64.StdEncoding.EncodeToString(key) + "\n",
	} {
		if got, err := ParseStockKey(text); err != nil || got[0] != 0xfb {
			t.Errorf("%q: %v", text, err)
		}
	}
	for _, text := range []string{"", "not base64!", base64.StdEncoding.EncodeToString(make([]byte, 16))} {
		if _, err := ParseStockKey(text); err == nil {
			t.Errorf("%q should be refused", text)
		}
	}
}

func TestMaskCode(t *testing.T) {
	for code, want := range map[string]string{"1234-5678-9012": "••••9012", "abc": "•••", "": ""} {
		if got := MaskCode(code); got != want {
			t.Errorf("%q -> %q, want %q", code, got, want)
		}
	}
}
