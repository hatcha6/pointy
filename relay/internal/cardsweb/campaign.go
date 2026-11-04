package cardsweb

import (
	"context"
	"net/http"
	"net/url"
	"strings"

	"pointy/relay/internal/control"
)

// A campaign's link, cards.dftr.ly/go/CODE: what an ad, a creator's post or a
// billboard's QR code points at. A phone with the app opens it in the app
// (the Universal Link covers every path), which reads the code itself. Here
// is everyone else: the open is counted per platform, then an iPhone goes to
// the App Store with the code as Apple's campaign token (ct, App Store
// Connect counts its installs), an Android phone to Google Play with it in
// the install referrer (the app reads it on first launch), and anything else
// to the campaign's page of the web app, the code in its address (?c=).

// Campaigns finds the live campaign a link names and counts its opens.
type Campaigns interface {
	OpenCampaignLink(ctx context.Context, code, platform string, count bool) (control.CustomerCampaign, bool)
}

// StoreLinks are the app's store pages a campaign link sends phones to;
// empty sends them to the web app instead.
type StoreLinks struct {
	// IOS is the App Store page, with Apple's provider token
	// (https://apps.apple.com/app/id…?pt=…&mt=8).
	IOS string
	// Android is the Google Play page
	// (https://play.google.com/store/apps/details?id=ly.dftr.cards).
	Android string
}

const campaignPrefix = "go/"

func (h *Handler) serveCampaign(w http.ResponseWriter, r *http.Request, code string) {
	platform := campaignPlatform(r.UserAgent())
	// A link preview's robot (WhatsApp, Facebook) is not a person opening it.
	count := r.Method == http.MethodGet && !isLinkPreviewRobot(r.UserAgent())
	target := "/"
	if h.campaigns != nil {
		if campaign, ok := h.campaigns.OpenCampaignLink(r.Context(), code, platform, count); ok {
			target = campaignTarget(campaign, platform, h.stores)
		}
	}
	header := w.Header()
	// Every open must reach the relay to be counted.
	header.Set("Cache-Control", "no-store")
	http.Redirect(w, r, target, http.StatusFound)
}

// campaignTarget is where campaign's link sends a visitor on platform.
func campaignTarget(campaign control.CustomerCampaign, platform string, stores StoreLinks) string {
	switch {
	case platform == "ios" && stores.IOS != "":
		if store, err := url.Parse(stores.IOS); err == nil {
			query := store.Query()
			query.Set("ct", campaign.Code)
			store.RawQuery = query.Encode()
			return store.String()
		}
	case platform == "android" && stores.Android != "":
		if store, err := url.Parse(stores.Android); err == nil {
			query := store.Query()
			query.Set("referrer", url.Values{
				"utm_source":   {"cards_link"},
				"utm_medium":   {campaign.Kind},
				"utm_campaign": {campaign.Code},
			}.Encode())
			store.RawQuery = query.Encode()
			return store.String()
		}
	}
	landing, err := url.Parse(campaign.Landing)
	if err != nil {
		landing = &url.URL{Path: "/"}
	}
	query := landing.Query()
	query.Set("c", campaign.Code)
	landing.RawQuery = query.Encode()
	return landing.String()
}

// campaignPlatform tells phones from the rest by their browser.
func campaignPlatform(userAgent string) string {
	agent := strings.ToLower(userAgent)
	switch {
	case strings.Contains(agent, "iphone"), strings.Contains(agent, "ipad"), strings.Contains(agent, "ipod"):
		return "ios"
	case strings.Contains(agent, "android"):
		return "android"
	default:
		return "web"
	}
}

func isLinkPreviewRobot(userAgent string) bool {
	agent := strings.ToLower(userAgent)
	for _, robot := range []string{
		"bot", "crawler", "spider", "facebookexternalhit", "whatsapp", "telegram", "slack", "preview", "curl",
	} {
		if strings.Contains(agent, robot) {
			return true
		}
	}
	return agent == ""
}
