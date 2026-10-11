package relay

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"testing"

	"pointy/relay/internal/control"
)

func TestFinancePositionIsWhatTheOwnersCanTake(t *testing.T) {
	store, provisioned := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:      store,
		Hub:        NewHub(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken: "admin-token",
	}
	ctx := context.Background()
	shop := provisioned.Installation.ID
	post := func(posting control.WalletPosting) {
		t.Helper()
		posting.InstallationID, posting.Actor = shop, "ops"
		if _, _, err := store.PostWalletEntry(ctx, posting); err != nil {
			t.Fatal(err)
		}
	}
	// The shop paid 200 in cash and got 20 free as compensation, then spent
	// 30 on texts and 70 on the assistant: 120 of its own is still unspent.
	post(control.WalletPosting{Kind: control.WalletEntryAdjustment, Amount: "200", Description: "إيداع نقدي", IdempotencyKey: "cash"})
	post(control.WalletPosting{Kind: control.WalletEntryAdjustment, Amount: "20", Description: control.GoodwillStatementPrefix + " — تأخر", IdempotencyKey: "gift"})
	post(control.WalletPosting{Kind: control.WalletEntryCharge, Service: control.WalletServiceSMS, Amount: "-30", IdempotencyKey: "c1"})
	post(control.WalletPosting{Kind: control.WalletEntryCharge, Service: control.WalletServiceAI, Amount: "-70", IdempotencyKey: "c2"})

	for key, body := range map[string]string{
		"in":  `{"direction":"income","category":"setup_fee","amount":"100","occurred_on":"2026-06-01","idempotency_key":"in","actor":"Hatem"}`,
		"out": `{"direction":"expense","category":"hosting","amount":"40","occurred_on":"2026-06-01","idempotency_key":"out","actor":"Hatem"}`,
		"me":  `{"direction":"withdrawal","category":"owner_draw","amount":"25","occurred_on":"2026-06-02","idempotency_key":"me","actor":"Hatem"}`,
	} {
		if code, created := financeRequest(t, server, http.MethodPost, "/v1/finance/entries", body); code != http.StatusCreated {
			t.Fatalf("%s: %d %v", key, code, created)
		}
	}

	code, position := financeRequest(t, server, http.MethodGet, "/v1/finance/position", "")
	if code != http.StatusOK {
		t.Fatalf("position %d %v", code, position)
	}
	gross := position["gross"].(map[string]any)
	if gross["sales"] != "100.000" || gross["profit"] != "100.000" || gross["cost"] != "0.000" {
		t.Fatalf("gross %v", gross)
	}
	if lines := position["services"].([]any); len(lines) != 2 || lines[0].(map[string]any)["key"] != "ai" {
		t.Fatalf("services %v", lines)
	}
	// Profit 100 + 100 income − 40 hosting = 160; less the 20 given away and
	// the 25 already taken.
	for field, want := range map[string]string{
		"net_profit": "160.000",
		"goodwill":   "20.000",
		"withdrawn":  "25.000",
		"shops_owe":  "0.000",
		"available":  "115.000",
		"shops_hold": "120.000",
	} {
		if position[field] != want {
			t.Fatalf("%s = %v, want %s (%v)", field, position[field], want, position)
		}
	}

	// A withdrawal is not an expense: the profit and loss leaves it out.
	_, summary := financeRequest(t, server, http.MethodGet, "/v1/finance/summary?from=2026-06-01&to=2026-06-30", "")
	if net := summary["totals"].(map[string]any)["net"]; net != "160.000" {
		t.Fatalf("net with a withdrawal %v", net)
	}
	// Nor is it a monthly line.
	if code, _ := financeRequest(t, server, http.MethodPost, "/v1/finance/recurring",
		`{"direction":"withdrawal","category":"owner_draw","amount":"10","day_of_month":1,"mode":"auto","actor":"Hatem"}`); code != http.StatusBadRequest {
		t.Fatalf("a monthly withdrawal %d", code)
	}

	// A shop that spent beyond what it paid owes it: not ours until it pays.
	post(control.WalletPosting{Kind: control.WalletEntryAdjustment, Amount: "-150", Description: "تصحيح", IdempotencyKey: "fix", AllowOverdraft: true})
	_, position = financeRequest(t, server, http.MethodGet, "/v1/finance/position", "")
	if position["shops_owe"] != "30.000" || position["owing_shops"].(float64) != 1 || position["available"] != "85.000" {
		t.Fatalf("with a debt %v", position)
	}
}
