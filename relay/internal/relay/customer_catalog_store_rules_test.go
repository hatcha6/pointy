package relay

import (
	"testing"

	"pointy/relay/internal/control"
)

// What the store reviews decided, product by product: see the comments on
// iosRealWorldBrands and playHeldBrands.
func TestStoreRulesForGiftCards(t *testing.T) {
	config := CustomerConfig{}
	cases := []struct {
		brand, channel string
		sell           bool
	}{
		{"gc-airbnb", CustomerChannelIOS, true},
		{"gc-google-play", CustomerChannelIOS, false},
		{"gc-rewarble", CustomerChannelIOS, false},
		{"amazon", CustomerChannelIOS, false},
		{"gc-google-play", CustomerChannelPlay, true},
		{"gc-airbnb", CustomerChannelPlay, true},
		{"gc-rewarble", CustomerChannelPlay, false},
		{"gc-discord", CustomerChannelPlay, false},
		{"gc-adobe", CustomerChannelPlay, false},
		{"gc-rewarble", CustomerChannelWeb, true},
		{"gc-rewarble", CustomerChannelAPK, true},
	}
	for _, test := range cases {
		_, sell := config.shelf(test.channel, shelfBrand{Key: test.brand, Category: "gift_cards"}, control.MobileGiftCardsWebOnly)
		if sell != test.sell {
			t.Errorf("%s on %s sells = %v, want %v", test.brand, test.channel, sell, test.sell)
		}
	}
	// The operator's switch still reaches what is held.
	if show, _ := config.shelf(CustomerChannelPlay, shelfBrand{Key: "gc-rewarble", Category: "gift_cards"}, control.MobileGiftCardsHidden); show {
		t.Error("a held brand shows although the switch hides it")
	}
	if show, sell := config.shelf(CustomerChannelIOS, shelfBrand{Key: "gc-airbnb", Category: "gift_cards"}, control.MobileGiftCardsHidden); !show || !sell {
		t.Error("the switch must not take a real-world card off iOS")
	}
}
