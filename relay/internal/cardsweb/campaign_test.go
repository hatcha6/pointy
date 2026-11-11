package cardsweb

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"pointy/relay/internal/control"
)

type fakeCampaigns struct {
	opens []string
}

func (f *fakeCampaigns) OpenCampaignLink(_ context.Context, code, platform string, count bool) (control.CustomerCampaign, bool) {
	if code != "AHMED" && code != "ahmed" {
		return control.CustomerCampaign{}, false
	}
	if count {
		f.opens = append(f.opens, platform)
	}
	return control.CustomerCampaign{Code: "AHMED", Kind: "creator", Landing: "/brand/pubg"}, true
}

const (
	iphone  = "Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
	android = "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 Chrome/140 Mobile Safari/537.36"
	desktop = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 Safari/605.1.15"
)

func campaignHandler(t *testing.T, campaigns Campaigns, stores StoreLinks) *Handler {
	t.Helper()
	relay := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, "relay") })
	h, err := Wrap(relay, Config{Hosts: []string{"cards.dftr.ly"}, Files: build(), Campaigns: campaigns, Stores: stores})
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func open(h http.Handler, method, target, agent string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, "http://cards.dftr.ly"+target, nil)
	request.Header.Set("User-Agent", agent)
	recorder := httptest.NewRecorder()
	h.ServeHTTP(recorder, request)
	return recorder
}

func TestCampaignLinkSendsEachPhoneToItsStore(t *testing.T) {
	campaigns := &fakeCampaigns{}
	h := campaignHandler(t, campaigns, StoreLinks{
		IOS:     "https://apps.apple.com/app/id6740000000?pt=128000&mt=8",
		Android: "https://play.google.com/store/apps/details?id=ly.dftr.cards",
	})

	got := open(h, http.MethodGet, "/go/AHMED", iphone)
	if got.Code != http.StatusFound || got.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("iphone: %d %v", got.Code, got.Header())
	}
	location, _ := url.Parse(got.Header().Get("Location"))
	if location.Host != "apps.apple.com" || location.Query().Get("ct") != "AHMED" || location.Query().Get("pt") != "128000" {
		t.Fatalf("iphone went to %s", location)
	}

	location, _ = url.Parse(open(h, http.MethodGet, "/go/AHMED", android).Header().Get("Location"))
	referrer, _ := url.ParseQuery(location.Query().Get("referrer"))
	if location.Host != "play.google.com" || location.Query().Get("id") != "ly.dftr.cards" ||
		referrer.Get("utm_campaign") != "AHMED" || referrer.Get("utm_medium") != "creator" {
		t.Fatalf("android went to %s", location)
	}

	if got := open(h, http.MethodGet, "/go/AHMED", desktop).Header().Get("Location"); got != "/brand/pubg?c=AHMED" {
		t.Fatalf("desktop went to %s", got)
	}

	// WhatsApp fetching the link's preview is not an open.
	open(h, http.MethodGet, "/go/AHMED", "WhatsApp/2.24.1 A")
	open(h, http.MethodHead, "/go/AHMED", iphone)
	if len(campaigns.opens) != 3 || campaigns.opens[0] != "ios" || campaigns.opens[1] != "android" || campaigns.opens[2] != "web" {
		t.Fatalf("opens %v", campaigns.opens)
	}

	// An unknown code goes to the shelf; a deeper path is no campaign link:
	// the app, as for any address it does not know.
	if got := open(h, http.MethodGet, "/go/NOPE", iphone).Header().Get("Location"); got != "/" {
		t.Fatalf("unknown went to %s", got)
	}
	if got := open(h, http.MethodGet, "/go/AHMED/x", iphone); got.Header().Get("Location") != "" || !strings.Contains(got.Body.String(), "<title>") {
		t.Fatalf("deeper path: %d %s", got.Code, got.Header().Get("Location"))
	}
}

func TestCampaignLinkWithoutStoresOpensTheWebApp(t *testing.T) {
	h := campaignHandler(t, &fakeCampaigns{}, StoreLinks{})
	if got := open(h, http.MethodGet, "/go/ahmed", iphone).Header().Get("Location"); got != "/brand/pubg?c=AHMED" {
		t.Fatalf("iphone without a store went to %s", got)
	}
	// No campaigns at all (a relay keeping no customers): the shelf.
	if got := open(campaignHandler(t, nil, StoreLinks{}), http.MethodGet, "/go/AHMED", iphone).Header().Get("Location"); got != "/" {
		t.Fatalf("no campaigns went to %s", got)
	}
}
