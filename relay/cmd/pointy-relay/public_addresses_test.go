package main

import "testing"

func TestPublicAddressesAdvertiseOnlyHTTPSOrigins(t *testing.T) {
	got, err := buildPublicAddresses(" https://My.dftr.ly/ ", "https://shop.dftr.ly")
	if err != nil || got.API != "https://my.dftr.ly" || got.Pages != "https://shop.dftr.ly" {
		t.Fatalf("got %+v, %v", got, err)
	}
	// The wallet tolerates a plain-http public URL (Dafa then skips the
	// webhook); it is simply not handed to shops.
	got, err = buildPublicAddresses("http://relay.local", "")
	if err != nil || got.API != "" || got.Pages != "" {
		t.Fatalf("http api: got %+v, %v", got, err)
	}
	for _, pages := range []string{"http://shop.dftr.ly", "https://shop.dftr.ly/s", "shop.dftr.ly"} {
		if _, err := buildPublicAddresses("", pages); err == nil {
			t.Fatalf("accepted pages %q", pages)
		}
	}
}
