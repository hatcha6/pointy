package relay

import "testing"

func TestShopsReadTheRelaysPublicAddressesOnTheirStatusRead(t *testing.T) {
	server, provisioned := newIntegrationSwitchServer(t)
	server.Public = PublicAddresses{API: "https://my.dftr.ly", Pages: "https://shop.dftr.ly"}
	payload := statusRead(t, server, provisioned)
	if payload["public_api_url"] != "https://my.dftr.ly" || payload["public_pages_url"] != "https://shop.dftr.ly" {
		t.Fatalf("status read addresses: %v / %v", payload["public_api_url"], payload["public_pages_url"])
	}
}

func TestUnsetPublicAddressesAreLeftOut(t *testing.T) {
	// Absent means "keep your own setting"; an empty string must never reach
	// a shop as an address.
	server, provisioned := newIntegrationSwitchServer(t)
	payload := statusRead(t, server, provisioned)
	for _, key := range []string{"public_api_url", "public_pages_url"} {
		if _, ok := payload[key]; ok {
			t.Fatalf("%s sent while unset: %v", key, payload[key])
		}
	}
}
