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

func TestBuildConnectorEndpoints(t *testing.T) {
	got, err := buildConnectorEndpoints("", "https://my.dftr.ly")
	if err != nil || len(got) != 1 || got[0] != "wss://my.dftr.ly/v1/connector/tunnel" {
		t.Fatalf("derived from the public URL: %v %v", got, err)
	}
	got, err = buildConnectorEndpoints("", "")
	if err != nil || got == nil || len(got) != 0 {
		t.Fatalf("no public URL must advertise an empty list: %v %v", got, err)
	}
	got, err = buildConnectorEndpoints("wss://my.dftr.ly, tunnel.dftr.ly:11061", "https://ignored.example")
	if err != nil || len(got) != 2 || got[0] != "wss://my.dftr.ly/v1/connector/tunnel" || got[1] != "tls://tunnel.dftr.ly:11061" {
		t.Fatalf("explicit list: %v %v", got, err)
	}
	got, err = buildConnectorEndpoints("none", "https://my.dftr.ly")
	if err != nil || got == nil || len(got) != 0 {
		t.Fatalf("none must advertise an empty list: %v %v", got, err)
	}
	if _, err := buildConnectorEndpoints("https://my.dftr.ly", ""); err == nil {
		t.Fatal("an https:// address is not a tunnel address")
	}
}
