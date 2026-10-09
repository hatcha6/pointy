package relay

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"pointy/relay/internal/alerts"
	"pointy/relay/internal/control"
)

func newAlertServer(t *testing.T) (HTTPServer, *[]map[string]any) {
	t.Helper()
	var mu sync.Mutex
	published := &[]map[string]any{}
	ntfy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		mu.Lock()
		*published = append(*published, body)
		mu.Unlock()
	}))
	t.Cleanup(ntfy.Close)
	store, _ := provisionRelayInstallation(t)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	return HTTPServer{
		Store:      store,
		Hub:        NewHub(),
		Logger:     logger,
		AdminToken: "admin-token",
		Alerts:     &alerts.Ntfy{Server: ntfy.URL, Topics: AlertTopicSource(store), Logger: logger},
	}, published
}

func alertRequest(t *testing.T, server HTTPServer, method, path string, admin bool) (int, map[string]any) {
	t.Helper()
	req := httptest.NewRequest(method, "http://relay"+path, strings.NewReader(`{"actor":"ops"}`))
	if admin {
		req.Header.Set("Authorization", "Bearer admin-token")
	}
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	var body map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	return rec.Code, body
}

func TestAlertTopicSetupStatusAndTest(t *testing.T) {
	server, published := newAlertServer(t)

	if code, _ := alertRequest(t, server, http.MethodGet, "/v1/alerts", false); code != http.StatusUnauthorized {
		t.Fatalf("the topic is a secret: unauthenticated status answered %d", code)
	}
	if code, body := alertRequest(t, server, http.MethodGet, "/v1/alerts", true); code != http.StatusOK || body["configured"] != false {
		t.Fatalf("fresh relay status %d %v", code, body)
	}
	if code, _ := alertRequest(t, server, http.MethodPost, "/v1/alerts/test", true); code != http.StatusConflict {
		t.Fatalf("test without a topic answered %d", code)
	}

	code, body := alertRequest(t, server, http.MethodPost, "/v1/alerts/topic", true)
	topic, _ := body["topic"].(string)
	if code != http.StatusOK || !strings.HasPrefix(topic, "daftar-alerts-") || body["actor"] != "ops" ||
		!strings.HasSuffix(body["subscribe_url"].(string), "/"+topic) {
		t.Fatalf("setup %d %v", code, body)
	}
	if _, status := alertRequest(t, server, http.MethodGet, "/v1/alerts", true); status["topic"] != topic {
		t.Fatalf("status does not show the stored topic: %v", status)
	}

	if code, body := alertRequest(t, server, http.MethodPost, "/v1/alerts/test", true); code != http.StatusOK {
		t.Fatalf("test %d %v", code, body)
	}
	if len(*published) != 1 || (*published)[0]["topic"] != topic {
		t.Fatalf("test notification not published to the topic: %v", *published)
	}

	_, rotated := alertRequest(t, server, http.MethodPost, "/v1/alerts/topic", true)
	if rotated["topic"] == topic {
		t.Fatal("rotation kept the old topic")
	}
}

func TestAlertMarksAreClaimedOncePerCooldown(t *testing.T) {
	store, _ := provisionRelayInstallation(t)
	var marks control.AlertStore = store
	ctx := t.Context()
	if won, _ := marks.ClaimAlert(ctx, "k", supplierAccountAlertCooldown); !won {
		t.Fatal("first claim lost")
	}
	if won, _ := marks.ClaimAlert(ctx, "k", supplierAccountAlertCooldown); won {
		t.Fatal("second claim inside the cooldown won")
	}
	if had, _ := marks.ReleaseAlert(ctx, "k"); !had {
		t.Fatal("release did not find the mark")
	}
	if won, _ := marks.ClaimAlert(ctx, "k", supplierAccountAlertCooldown); !won {
		t.Fatal("claim after release lost")
	}
}

func TestWalletTopUpAlertSaysAmountShopAndOutcome(t *testing.T) {
	topUp := control.WalletTopUp{
		InstallationID: "inst-1",
		ShopName:       "متجر النسيم",
		Method:         "dafa_sadad",
		Amount:         "50.00",
		InvoiceNo:      "W-1001",
		PayerHint:      "091•••678",
		Status:         control.WalletTopUpPaid,
	}
	paid, ok := walletTopUpAlert(topUp, "paid_webhook", "")
	if !ok || paid.Title != "Paid 50.00 LYD" || paid.Priority != alerts.PriorityHigh ||
		!strings.Contains(paid.Body, "متجر النسيم") || !strings.Contains(paid.Body, "W-1001") || !strings.Contains(paid.Body, "091•••678") {
		t.Fatalf("paid alert %+v", paid)
	}

	for _, event := range []string{"payment_started", "canceled", "confirm_unauthorized", "otp_rejected"} {
		if _, ok := walletTopUpAlert(topUp, event, ""); ok {
			t.Fatalf("%s is not a result: only paid or failed is sent", event)
		}
	}

	declined, ok := walletTopUpAlert(topUp, "confirm_declined", "")
	if !ok || declined.Title != "Top-up failed 50.00 LYD" {
		t.Fatalf("declined alert %+v", declined)
	}

	topUp.Status, topUp.ErrorCode = control.WalletTopUpFailed, walletCodeAmountMismatch
	held, _ := walletTopUpAlert(topUp, "held_reconcile", "dafa reports 40")
	if held.Priority != alerts.PriorityUrgent || !strings.Contains(held.Body, "amount_mismatch") {
		t.Fatalf("held alert %+v", held)
	}

	topUp.TestMode = true
	test, _ := walletTopUpAlert(topUp, "paid_confirm", "")
	if !strings.HasPrefix(test.Title, "[TEST] ") || test.Priority > alerts.PriorityLow {
		t.Fatalf("test money must read as test and stay quiet: %+v", test)
	}
}
