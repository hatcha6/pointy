package relay

import (
	"context"
	"net/http"
	"testing"

	"pointy/relay/internal/control"
)

func TestCustomerCampaignsEndToEnd(t *testing.T) {
	h := newCustomerHarness(t)
	h.server.AdminToken = "admin-token"

	// The console makes a campaign; a customer's token may not.
	billboard := map[string]any{
		"code": "lawha1", "name": "لوحة الساحل", "display_name": "لوحة الساحل", "kind": "billboard",
		"landing": "/brand/libyana", "reward": "5", "reward_limit": 100, "reward_until": "2027-11-01",
	}
	signedIn := h.signIn("0912345678")
	access := signedIn["access_token"].(string)
	if status, _ := h.do(http.MethodPost, "/v1/customers/admin/campaigns", access, billboard); status != http.StatusUnauthorized {
		t.Fatalf("a customer made a campaign: %d", status)
	}
	status, body := h.do(http.MethodPost, "/v1/customers/admin/campaigns", "admin-token", billboard)
	if status != http.StatusCreated || body["campaign"].(map[string]any)["code"] != "LAWHA1" {
		t.Fatalf("create: %d %v", status, body)
	}
	campaignID := body["campaign"].(map[string]any)["id"].(string)
	if status, body := h.do(http.MethodPost, "/v1/customers/admin/campaigns", "admin-token", billboard); status != http.StatusConflict || body["code"] != "code_taken" {
		t.Fatalf("duplicate: %d %v", status, body)
	}
	if status, body := h.do(http.MethodPost, "/v1/customers/admin/campaigns", "admin-token",
		map[string]any{"code": "x", "name": "x", "kind": "ad"}); status != http.StatusBadRequest || body["code"] != "invalid_campaign" {
		t.Fatalf("bad code: %d %v", status, body)
	}

	// The app checks a typed code; the answer never shows notes or results.
	status, body = h.do(http.MethodGet, "/v1/customers/campaigns/Lawha1", "", nil)
	if status != http.StatusOK {
		t.Fatalf("lookup: %d %v", status, body)
	}
	if view := body["campaign"].(map[string]any); view["code"] != "LAWHA1" || view["landing"] != "/brand/libyana" ||
		view["id"] != nil || view["reward"] != "5.000" || view["kind"] != "billboard" || view["reward_limit"] != nil {
		t.Fatalf("lookup view %v", view)
	}
	if status, body := h.do(http.MethodGet, "/v1/customers/campaigns/NOPE", "", nil); status != http.StatusNotFound || body["code"] != "unknown_campaign" {
		t.Fatalf("unknown: %d %v", status, body)
	}
	if status, _ := h.do(http.MethodPost, "/v1/customers/campaigns/LAWHA1/open", "", map[string]any{}); status != http.StatusOK {
		t.Fatalf("open: %d", status)
	}

	// A new customer's code rides on their sign-in.
	status, answer := h.do(http.MethodPost, "/v1/customers/auth/otp", "", map[string]any{"phone": "0923456789"})
	if status != http.StatusOK {
		t.Fatalf("otp: %d %v", status, answer)
	}
	status, answer = h.do(http.MethodPost, "/v1/customers/auth/verify", "", map[string]any{
		"phone": "0923456789", "code": h.sender.last(t, "218923456789"),
		"device":      map[string]any{"id": "dev-2", "platform": "android"},
		"attribution": map[string]any{"code": "lawha1", "via": "referrer", "heard_from": "billboard"},
	})
	if status != http.StatusOK || answer["code_accepted"] != true {
		t.Fatalf("verify with attribution: %d %v", status, answer)
	}
	if got := answer["attribution"].(map[string]any); got["campaign_code"] != "LAWHA1" || got["campaign_via"] != "referrer" || got["heard_from"] != "billboard" {
		t.Fatalf("attribution %v", got)
	}
	if reward := answer["reward"].(map[string]any); reward["amount"] != "5.000" || reward["display_name"] != "لوحة الساحل" || reward["via"] != "referrer" {
		t.Fatalf("reward %v", reward)
	}
	newAccess := answer["access_token"].(string)
	if status, credit := h.do(http.MethodGet, "/v1/customers/credit", newAccess, nil); status != http.StatusOK || credit["balance"] != "5.000" {
		t.Fatalf("credit after the reward: %d %v", status, credit)
	}

	// The first customer answers later; an unknown code is dropped, the
	// answer kept.
	status, body = h.do(http.MethodPut, "/v1/customers/me/attribution", access,
		map[string]any{"code": "NOPE", "heard_from": "friend"})
	if status != http.StatusOK || body["code_accepted"] != false || body["reward"] != nil || body["attribution"].(map[string]any)["heard_from"] != "friend" {
		t.Fatalf("put: %d %v", status, body)
	}
	if status, _ := h.do(http.MethodPut, "/v1/customers/me/attribution", "", map[string]any{"heard_from": "friend"}); status != http.StatusUnauthorized {
		t.Fatalf("signed out put: %d", status)
	}

	// An ended campaign credits no one new.
	if status, body := h.do(http.MethodPatch, "/v1/customers/admin/campaigns/"+campaignID, "admin-token",
		map[string]any{"active": false}); status != http.StatusOK || body["campaign"].(map[string]any)["active"] != false {
		t.Fatalf("end: %d %v", status, body)
	}
	if status, _ := h.do(http.MethodGet, "/v1/customers/campaigns/LAWHA1", "", nil); status != http.StatusNotFound {
		t.Fatalf("ended campaign still looks up: %d", status)
	}

	status, body = h.do(http.MethodGet, "/v1/customers/admin/campaigns", "admin-token", nil)
	if status != http.StatusOK {
		t.Fatalf("report: %d %v", status, body)
	}
	report := body["report"].(map[string]any)
	campaign := report["campaigns"].([]any)[0].(map[string]any)
	if campaign["customers"] != float64(1) || campaign["clicks"].(map[string]any)["app"] != float64(1) ||
		campaign["rewarded"] != float64(1) || campaign["rewards_given"] != "5.000" {
		t.Fatalf("campaign %v", campaign)
	}
	if report["no_campaign"].(map[string]any)["customers"] != float64(1) {
		t.Fatalf("no campaign %v", report["no_campaign"])
	}

	// The console's customer page names where they came from.
	customerID := answer["customer"].(map[string]any)["id"].(string)
	status, body = h.do(http.MethodGet, "/v1/customers/admin/customers/"+customerID, "admin-token", nil)
	if status != http.StatusOK || body["attribution"].(map[string]any)["campaign_code"] != "LAWHA1" {
		t.Fatalf("detail: %d %v", status, body["attribution"])
	}
}

func TestCampaignLinkCountsAndFindsTheLanding(t *testing.T) {
	h := newCustomerHarness(t)
	campaign, err := h.store.CreateCustomerCampaign(context.Background(), control.CustomerCampaign{
		Code: "AHMED", Name: "أحمد", Kind: control.CampaignKindCreator,
	})
	if err != nil {
		t.Fatal(err)
	}
	if got, ok := h.server.OpenCampaignLink(context.Background(), "ahmed", "ios", true); !ok || got.ID != campaign.ID {
		t.Fatalf("open = %+v %v", got, ok)
	}
	h.server.OpenCampaignLink(context.Background(), "AHMED", "web", false)
	if _, ok := h.server.OpenCampaignLink(context.Background(), "NOPE", "ios", true); ok {
		t.Fatal("an unknown code opened")
	}
	report, err := h.store.CustomerCampaignReport(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if clicks := report.Campaigns[0].Clicks; clicks["ios"] != 1 || clicks["web"] != 0 {
		t.Fatalf("clicks %v", clicks)
	}
}
