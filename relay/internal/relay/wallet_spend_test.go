package relay

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/control"
)

// sellingPlans is the harness wallet selling both plans, a month at a time.
func (h *walletHarness) sellingPlans() {
	h.server.Wallet.Plans = map[string]WalletPlan{
		control.WalletPlanRemoteAccess: {Price: "50.000", Days: 30},
		control.WalletPlanAI:           {Price: "30.000", Days: 30},
	}
}

// credit puts money in the shop's main wallet, as an operator's adjustment.
func (h *walletHarness) credit(t *testing.T, amount string) {
	t.Helper()
	if _, _, err := h.store.PostWalletEntry(context.Background(), control.WalletPosting{
		InstallationID: h.shop.Installation.ID,
		Kind:           control.WalletEntryAdjustment,
		Amount:         amount,
		Description:    "test credit",
		IdempotencyKey: "credit-" + amount + "-" + time.Now().Format(time.RFC3339Nano),
	}); err != nil {
		t.Fatal(err)
	}
}

func (h *walletHarness) spend(t *testing.T, path, body string) (int, map[string]any) {
	t.Helper()
	status, decoded, _ := h.do(t, http.MethodPost, path, h.shop.AccessToken, body, nil)
	return status, decoded
}

func (h *walletHarness) installation(t *testing.T) control.Installation {
	t.Helper()
	installation, err := h.store.GetInstallation(context.Background(), h.shop.Installation.ID)
	if err != nil {
		t.Fatal(err)
	}
	return installation
}

func planByKey(t *testing.T, body map[string]any, key string) map[string]any {
	t.Helper()
	plans, _ := body["plans"].([]any)
	for _, raw := range plans {
		if plan, _ := raw.(map[string]any); plan["key"] == key {
			return plan
		}
	}
	t.Fatalf("no %s plan in %v", key, body["plans"])
	return nil
}

func TestWalletOverviewShowsTheSMSBalanceAndThePlans(t *testing.T) {
	h := newWalletHarness(t)
	h.server.Wallet.Plans = map[string]WalletPlan{control.WalletPlanRemoteAccess: {Price: "50", Days: 30}}
	h.credit(t, "20")

	status, body, _ := h.do(t, http.MethodGet, "/v1/wallet", h.shop.AccessToken, "", nil)
	if status != http.StatusOK || body["balance"] != "20.000" {
		t.Fatalf("overview: %d %v", status, body)
	}
	sms, _ := body["sms"].(map[string]any)
	if sms["balance"] != "0.000" || sms["price"] != "0.150" || sms["messages_left"] != float64(0) || sms["available"] != false {
		t.Fatalf("an empty SMS balance: %v", sms)
	}
	remote := planByKey(t, body, control.WalletPlanRemoteAccess)
	if remote["available"] != true || remote["price"] != "50.000" || remote["period_days"] != float64(30) ||
		remote["active"] != false || remote["until"] != nil || remote["included"] != false || remote["max_periods"] != float64(12) {
		t.Fatalf("remote access is sold and not running: %v", remote)
	}
	ai := planByKey(t, body, control.WalletPlanAI)
	if ai["available"] != false || ai["price"] != nil || ai["active"] != false {
		t.Fatalf("a plan without a price is shown but not sold: %v", ai)
	}
}

func TestWalletSMSAllocationMovesTheMoneyOnce(t *testing.T) {
	h := newWalletHarness(t)
	h.credit(t, "20")

	status, body := h.spend(t, "/v1/wallet/sms/allocations", `{"amount":"15","idempotency_key":"alloc-1","requested_by":"hatem"}`)
	if status != http.StatusCreated || body["balance"] != "5.000" || body["replayed"] != false {
		t.Fatalf("allocation: %d %v", status, body)
	}
	sms, _ := body["sms"].(map[string]any)
	if sms["balance"] != "15.000" || sms["messages_left"] != float64(100) {
		t.Fatalf("fifteen dinars is a hundred messages: %v", sms)
	}
	transfer, _ := body["transfer"].(map[string]any)
	out, _ := transfer["out"].(map[string]any)
	in, _ := transfer["in"].(map[string]any)
	if out["account"] != "main" || out["amount"] != "-15.000" || out["kind"] != "transfer" ||
		in["account"] != "sms" || in["amount"] != "15.000" || in["description"] != "تحويل من المحفظة" {
		t.Fatalf("both sides of the transfer: %v", transfer)
	}

	// A retry of the same key gets the same transfer back and moves nothing.
	status, body = h.spend(t, "/v1/wallet/sms/allocations", `{"amount":"15","idempotency_key":"alloc-1"}`)
	if status != http.StatusOK || body["replayed"] != true || body["balance"] != "5.000" {
		t.Fatalf("replay: %d %v", status, body)
	}

	status, body = h.spend(t, "/v1/wallet/sms/allocations", `{"amount":6,"idempotency_key":"alloc-2"}`)
	if status != http.StatusConflict || body["code"] != walletCodeInsufficientBalance || body["balance"] != "5.000" || body["amount"] != "6.000" {
		t.Fatalf("more than the wallet holds: %d %v", status, body)
	}
	status, body = h.spend(t, "/v1/wallet/sms/allocations", `{"amount":"0.1","idempotency_key":"alloc-3"}`)
	if status != http.StatusUnprocessableEntity || body["code"] != walletCodeInvalidAmount || body["min_amount"] != "0.150" {
		t.Fatalf("less than one message: %d %v", status, body)
	}
	for _, bad := range []string{`{"amount":"1.2345","idempotency_key":"k"}`, `{"amount":"-5","idempotency_key":"k"}`, `{"amount":"x","idempotency_key":"k"}`} {
		if status, body := h.spend(t, "/v1/wallet/sms/allocations", bad); status != http.StatusUnprocessableEntity {
			t.Fatalf("%s must be refused: %d %v", bad, status, body)
		}
	}
	if status, body := h.spend(t, "/v1/wallet/sms/allocations", `{"amount":"1"}`); status != http.StatusBadRequest {
		t.Fatalf("a spend needs its key: %d %v", status, body)
	}

	// Each balance has its own statement.
	status, page, _ := h.do(t, http.MethodGet, "/v1/wallet/entries", h.shop.AccessToken, "", nil)
	entries, _ := page["entries"].([]any)
	kinds := map[any]bool{}
	for _, raw := range entries {
		kinds[raw.(map[string]any)["kind"]] = true
	}
	if status != http.StatusOK || len(entries) != 2 || !kinds["transfer"] || !kinds["adjustment"] {
		t.Fatalf("the main statement shows the credit and the transfer out: %d %v", status, page)
	}
	status, page, _ = h.do(t, http.MethodGet, "/v1/wallet/entries?account=sms", h.shop.AccessToken, "", nil)
	entries, _ = page["entries"].([]any)
	if status != http.StatusOK || len(entries) != 1 || entries[0].(map[string]any)["amount"] != "15.000" {
		t.Fatalf("the SMS statement shows the transfer in: %d %v", status, page)
	}
	if status, _, _ := h.do(t, http.MethodGet, "/v1/wallet/entries?account=savings", h.shop.AccessToken, "", nil); status != http.StatusBadRequest {
		t.Fatalf("an unknown account is a 400, got %d", status)
	}
}

func TestWalletPlanPurchaseRunsThePlanFromTheWallet(t *testing.T) {
	h := newWalletHarness(t)
	h.sellingPlans()
	h.credit(t, "200")
	id := h.shop.Installation.ID
	month := 30 * 24 * time.Hour

	status, body := h.spend(t, "/v1/wallet/subscriptions", `{"plan":"remote_access","idempotency_key":"buy-1","requested_by":"hatem"}`)
	if status != http.StatusCreated || body["balance"] != "150.000" || body["replayed"] != false {
		t.Fatalf("purchase: %d %v", status, body)
	}
	plan, _ := body["plan"].(map[string]any)
	if plan["active"] != true || plan["until"] != h.now.Add(month).Format(time.RFC3339) {
		t.Fatalf("a month of remote access from now: %v", plan)
	}
	entry, _ := body["entry"].(map[string]any)
	if entry["amount"] != "-50.000" || entry["service"] != "remote_access" || entry["description"] != "اشتراك الوصول عن بُعد حتى 2026-10-30" {
		t.Fatalf("the statement line: %v", entry)
	}
	installation := h.installation(t)
	if !installation.RelayActive(h.now) || installation.AIActive(h.now) {
		t.Fatalf("remote access runs and the assistant does not: %+v", installation)
	}

	// Renewing early adds after what is already paid for, for two months.
	status, body = h.spend(t, "/v1/wallet/subscriptions", `{"plan":"remote_access","periods":2,"idempotency_key":"buy-2"}`)
	plan, _ = body["plan"].(map[string]any)
	if status != http.StatusCreated || body["balance"] != "50.000" || plan["until"] != h.now.Add(3*month).Format(time.RFC3339) {
		t.Fatalf("renewal: %d %v", status, body)
	}
	// The same key never pays twice.
	status, body = h.spend(t, "/v1/wallet/subscriptions", `{"plan":"remote_access","periods":2,"idempotency_key":"buy-2"}`)
	if status != http.StatusOK || body["replayed"] != true || body["balance"] != "50.000" {
		t.Fatalf("replay: %d %v", status, body)
	}

	status, body = h.spend(t, "/v1/wallet/subscriptions", `{"plan":"ai","periods":2,"idempotency_key":"ai-1"}`)
	if status != http.StatusConflict || body["code"] != walletCodeInsufficientBalance || body["amount"] != "60.000" {
		t.Fatalf("two months of the assistant is more than the wallet holds: %d %v", status, body)
	}
	if h.installation(t).AIActive(h.now) {
		t.Fatal("a refused purchase must buy nothing")
	}
	if status, body := h.spend(t, "/v1/wallet/subscriptions", `{"plan":"ai","idempotency_key":"ai-2"}`); status != http.StatusCreated || body["balance"] != "20.000" {
		t.Fatalf("one month of the assistant: %d %v", status, body)
	}
	if !h.installation(t).AIActive(h.now) {
		t.Fatal("the assistant runs once it is paid for")
	}

	for body, code := range map[string]string{
		`{"plan":"ai","periods":13,"idempotency_key":"k"}`: walletCodeInvalidPeriods,
		`{"plan":"gold","idempotency_key":"k"}`:            walletCodePlanUnavailable,
	} {
		if status, answer := h.spend(t, "/v1/wallet/subscriptions", body); status != http.StatusUnprocessableEntity || answer["code"] != code {
			t.Fatalf("%s: expected %s, got %d %v", body, code, status, answer)
		}
	}
	delete(h.server.Wallet.Plans, control.WalletPlanAI)
	if status, answer := h.spend(t, "/v1/wallet/subscriptions", `{"plan":"ai","idempotency_key":"k"}`); answer["code"] != walletCodePlanUnavailable {
		t.Fatalf("a plan the relay no longer sells: %d %v", status, answer)
	}

	// Each purchase is in the installation's history, under the shop's name.
	events, err := h.store.ListAdminAuditEvents(context.Background(), id, 10)
	if err != nil {
		t.Fatal(err)
	}
	purchases := 0
	for _, event := range events {
		if event.Action == control.AuditActionSubscriptionPurchased {
			purchases++
			if !strings.HasPrefix(event.Actor, "wallet") {
				t.Fatalf("a purchase is the wallet's doing: %+v", event)
			}
		}
	}
	if purchases != 3 {
		t.Fatalf("expected 3 purchases in the history, got %d", purchases)
	}

	// The status read the shop's backend syncs from carries both dates.
	status, self, _ := h.do(t, http.MethodGet, "/v1/installations/"+id, h.shop.AccessToken, "", nil)
	if status != http.StatusOK || self["remote_access_paid_until"] != h.now.Add(3*month).Format(time.RFC3339) ||
		self["ai_paid_until"] != h.now.Add(month).Format(time.RFC3339) || self["relay_active"] != true || self["ai_active"] != true {
		t.Fatalf("self view: %d %v", status, self)
	}
}

func TestWalletPlanPurchaseFollowsTheOperatorsSubscription(t *testing.T) {
	h := newWalletHarness(t)
	h.sellingPlans()
	h.credit(t, "100")
	id := h.shop.Installation.ID
	enabled, active := true, true
	operatorEnd := h.now.Add(10 * 24 * time.Hour)
	if _, err := h.store.UpdateSubscription(context.Background(), id, control.SubscriptionUpdate{
		RelayEnabled: &enabled, SubscriptionActive: &active, SubscriptionEndsAt: &operatorEnd,
	}); err != nil {
		t.Fatal(err)
	}
	// Paying while the operator's term runs starts where that term ends.
	status, body := h.spend(t, "/v1/wallet/subscriptions", `{"plan":"remote_access","idempotency_key":"after-term"}`)
	plan, _ := body["plan"].(map[string]any)
	if status != http.StatusCreated || plan["until"] != operatorEnd.Add(30*24*time.Hour).Format(time.RFC3339) {
		t.Fatalf("the paid month follows the operator's ten days: %d %v", status, body)
	}

	// A subscription that includes the plan with no end leaves nothing to buy.
	if _, err := h.store.UpdateSubscription(context.Background(), id, control.SubscriptionUpdate{ClearEnd: true}); err != nil {
		t.Fatal(err)
	}
	status, body = h.spend(t, "/v1/wallet/subscriptions", `{"plan":"remote_access","idempotency_key":"forever"}`)
	if status != http.StatusConflict || body["code"] != walletCodePlanIncluded || h.balance(t) != "50.000" {
		t.Fatalf("an included plan is not sold: %d %v", status, body)
	}
	_, overview, _ := h.do(t, http.MethodGet, "/v1/wallet", h.shop.AccessToken, "", nil)
	remote := planByKey(t, overview, control.WalletPlanRemoteAccess)
	if remote["included"] != true || remote["available"] != false || remote["active"] != true || remote["until"] != nil {
		t.Fatalf("the overview says the plan is included: %v", remote)
	}
}

func TestWalletOperatorReachesTheSMSBalance(t *testing.T) {
	h := newWalletHarness(t)
	h.sellingPlans()
	admin := map[string]string{"Authorization": "Bearer admin-token"}
	status, body, _ := h.do(t, http.MethodPost, "/v1/wallet/admin/entries", "",
		`{"installation_id":"`+h.shop.Installation.ID+`","account":"sms","kind":"adjustment","amount":"1.5","description":"ten free messages","actor":"ops"}`, admin)
	entry, _ := body["entry"].(map[string]any)
	if status != http.StatusCreated || entry["account"] != "sms" || entry["balance_after"] != "1.500" {
		t.Fatalf("a credit to the SMS balance: %d %v", status, body)
	}
	if h.balance(t) != "0.000" {
		t.Fatal("an SMS credit must leave the main wallet alone")
	}
	status, body, _ = h.do(t, http.MethodPost, "/v1/wallet/admin/entries", "",
		`{"installation_id":"`+h.shop.Installation.ID+`","kind":"transfer","amount":"1","description":"x","actor":"ops"}`, admin)
	if status != http.StatusBadRequest {
		t.Fatalf("a one-sided transfer cannot be typed in: %d %v", status, body)
	}
	status, wallets, _ := h.do(t, http.MethodGet, "/v1/wallet/admin/wallets?account=sms", "", "", admin)
	if status != http.StatusOK || wallets["count"] != float64(1) || wallets["total"] != "1.500" {
		t.Fatalf("SMS balances: %d %v", status, wallets)
	}
	status, entries, _ := h.do(t, http.MethodGet, "/v1/wallet/admin/entries?account=main&installation_id="+h.shop.Installation.ID, "", "", admin)
	if status != http.StatusOK || entries["count"] != float64(0) {
		t.Fatalf("the main statement is empty: %d %v", status, entries)
	}
	status, config, _ := h.do(t, http.MethodGet, "/v1/wallet/admin/config", "", "", admin)
	plans, _ := config["plans"].(map[string]any)
	remote, _ := plans[control.WalletPlanRemoteAccess].(map[string]any)
	if status != http.StatusOK || config["sms_price"] != "0.150" || remote["price"] != "50.000" || remote["period_days"] != float64(30) {
		t.Fatalf("config: %d %v", status, config)
	}
}
