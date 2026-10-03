package relay

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/observability"
	"pointy/relay/internal/resala"
)

// The invoice invoiceSend asks for, as Resala renders it.
const invoiceContent = "شكرًا لتسوقك من محل النور. فاتورتك رقم 000123 بقيمة 125.00 د.ل."

// newCheckHarness is a harness whose relay runs the sent-log sync and knows
// the invoice's approved text, with a funded shop.
func newCheckHarness(t *testing.T) (*smsHarness, control.ProvisionedInstallation) {
	t.Helper()
	h := newSMSHarness(t)
	h.server.SMS.DeliverySyncInterval = 5 * time.Minute
	h.learnTemplate(t, "tpl-invoice", invoiceTemplateBody)
	return h, h.provision(t, smsShop{funded: true})
}

func (h *smsHarness) heldRow(t *testing.T, installationID string, body map[string]any) control.SMSMessage {
	t.Helper()
	id, _ := body["id"].(string)
	return h.ledgerRow(t, installationID, id)
}

func TestSMSSendHoldsAFailureThatMayHaveGoneOut(t *testing.T) {
	h, shop := newCheckHarness(t)

	// Resala erred after taking the request: the SMS may be on its way.
	h.resala.respond(http.StatusInternalServerError, `{"message":"server error"}`)
	status, body := h.send(t, shop.AccessToken, invoiceSend("5xx"))
	expectSMSCode(t, status, body, http.StatusBadGateway, "provider_error")
	if body["held"] != true || body["id"] == "" {
		t.Fatalf("the failure says its price is held, and names the message: %v", body)
	}
	row := h.heldRow(t, shop.Installation.ID, body)
	if row.HeldSince == nil || row.Status != control.SMSStatusFailed || row.ContentSHA256 != smsContentSHA256(invoiceContent) {
		t.Fatalf("held, with the text it would have had: %+v", row)
	}
	if got := h.smsBalance(t, shop.Installation.ID); got != "14.850" {
		t.Fatalf("the price stays until the log is checked, balance %s", got)
	}

	// Resala did not answer in time.
	h.server.SMS.RequestTimeout = 50 * time.Millisecond
	h.resala.mu.Lock()
	h.resala.delay = 500 * time.Millisecond
	h.resala.mu.Unlock()
	status, body = h.send(t, shop.AccessToken, invoiceSend("timeout"))
	expectSMSCode(t, status, body, http.StatusBadGateway, "provider_error")
	if body["held"] != true || h.smsBalance(t, shop.Installation.ID) != "14.700" {
		t.Fatalf("a timeout is held too: %v balance %s", body, h.smsBalance(t, shop.Installation.ID))
	}
}

func TestSMSSendRefundsAFailureThatCannotHaveGoneOut(t *testing.T) {
	h, shop := newCheckHarness(t)

	// A refusal Resala stated.
	h.resala.respond(http.StatusUnprocessableEntity, `{"message":"invalid","errors":{"records":["bad number"]}}`)
	status, body := h.send(t, shop.AccessToken, invoiceSend("refused"))
	expectSMSCode(t, status, body, http.StatusBadGateway, "provider_rejected")
	if body["held"] != false || h.smsBalance(t, shop.Installation.ID) != smsShopBalance {
		t.Fatalf("a stated refusal is refunded at once: %v balance %s", body, h.smsBalance(t, shop.Installation.ID))
	}

	// Resala could not be reached at all: nothing left the relay.
	closed := httptest.NewServer(http.NotFoundHandler())
	closed.Close()
	h.server.SMS.BaseURL = closed.URL
	status, body = h.send(t, shop.AccessToken, invoiceSend("unreachable"))
	expectSMSCode(t, status, body, http.StatusBadGateway, "provider_error")
	if body["held"] != false || h.smsBalance(t, shop.Installation.ID) != smsShopBalance {
		t.Fatalf("a send that never connected is refunded at once: %v balance %s", body, h.smsBalance(t, shop.Installation.ID))
	}
}

func TestSMSSendRefundsAtOnceWhatTheLogCannotSettle(t *testing.T) {
	// A template never sent: the relay could not recognise the message in
	// the log, so a doubtful failure is refunded at once.
	h := newSMSHarness(t)
	h.server.SMS.DeliverySyncInterval = 5 * time.Minute
	shop := h.provision(t, smsShop{funded: true})
	h.resala.respond(http.StatusBadGateway, `{"message":"bad gateway"}`)
	status, body := h.send(t, shop.AccessToken, invoiceSend("unknown-text"))
	expectSMSCode(t, status, body, http.StatusBadGateway, "provider_error")
	if body["held"] != false || h.smsBalance(t, shop.Installation.ID) != smsShopBalance {
		t.Fatalf("an unrecognisable message is refunded at once: %v balance %s", body, h.smsBalance(t, shop.Installation.ID))
	}

	// No sent-log sync on this relay: nothing would ever settle a hold.
	h2, shop2 := newCheckHarness(t)
	h2.server.SMS.DeliverySyncInterval = 0
	h2.resala.respond(http.StatusBadGateway, `{"message":"bad gateway"}`)
	status, body = h2.send(t, shop2.AccessToken, invoiceSend("no-sync"))
	expectSMSCode(t, status, body, http.StatusBadGateway, "provider_error")
	if body["held"] != false || h2.smsBalance(t, shop2.Installation.ID) != smsShopBalance {
		t.Fatalf("without the sync a failure is refunded at once: %v balance %s", body, h2.smsBalance(t, shop2.Installation.ID))
	}
}

func TestSMSReplayHoldsASendThatNeverFinished(t *testing.T) {
	h, shop := newCheckHarness(t)
	// A relay died mid-call ten minutes ago: its claim is still pending,
	// paid for, with the text it was sending.
	if _, _, err := h.store.BeginSMS(context.Background(), control.SMSMessage{
		InstallationID: shop.Installation.ID,
		IdempotencyKey: "died",
		Kind:           "invoice",
		ConsentClass:   "transactional",
		Recipient:      "218912345678",
		TemplateID:     "tpl-invoice",
		TemplateBody:   invoiceTemplateBody,
		ContentSHA256:  smsContentSHA256(invoiceContent),
		CreatedAt:      h.now.Add(-10 * time.Minute),
	}, control.SMSClaimTerms{Price: "0.150", Parts: 1}); err != nil {
		t.Fatal(err)
	}
	status, body := h.send(t, shop.AccessToken, invoiceSend("died"))
	expectSMSCode(t, status, body, http.StatusBadGateway, "outcome_unknown")
	if body["held"] != true || h.smsBalance(t, shop.Installation.ID) != "14.850" {
		t.Fatalf("an unknown outcome is held for the log: %v balance %s", body, h.smsBalance(t, shop.Installation.ID))
	}
	if len(h.resala.calls()) != 0 {
		t.Fatal("a replay never sends again")
	}
}

// checkPoller is the sync as the server runs it, at a given time.
func checkPoller(h *smsHarness, lister SMSSentLister, at time.Time) (*SMSDeliveryPoller, *observability.Metrics) {
	metrics := observability.NewMetrics()
	return &SMSDeliveryPoller{
		Client:  lister,
		Store:   h.store,
		Clock:   testClock{now: at},
		Metrics: metrics,
		Logger:  h.server.Logger,
	}, metrics
}

// holdOne makes one held invoice for the shop: Resala erred on the send.
func (h *smsHarness) holdOne(t *testing.T, token, key string) control.SMSMessage {
	t.Helper()
	h.resala.respond(http.StatusInternalServerError, `{"message":"server error"}`)
	status, body := h.send(t, token, invoiceSend(key))
	if status != http.StatusBadGateway || body["held"] != true {
		t.Fatalf("expected a held failure: %d %v", status, body)
	}
	id, _ := body["id"].(string)
	rows, err := h.store.GetSMSByIDs(context.Background(), "", []string{id})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) == 1 {
		return rows[0]
	}
	return control.SMSMessage{ID: id}
}

func onePage(rows ...resala.SentMessage) map[int]resala.SentPage {
	return map[int]resala.SentPage{1: {CurrentPage: 1, LastPage: 1, Messages: rows}}
}

func TestSMSCheckKeepsAHeldMessageTheLogShows(t *testing.T) {
	h, shop := newCheckHarness(t)
	// An earlier send, five minutes before, tells the relay what Resala
	// charges per part (0.1); it has its own row in the log.
	h.server.Clock = testClock{now: h.now.Add(-5 * time.Minute)}
	if status, body := h.send(t, shop.AccessToken, invoiceSend("earlier")); status != http.StatusCreated {
		t.Fatalf("an earlier send: %d %v", status, body)
	}
	h.server.Clock = testClock{now: h.now}
	held := h.holdOne(t, shop.AccessToken, "found")

	earlier := logRow("log-1", "912345678", invoiceContent, "Delivered", h.now.Add(-5*time.Minute+5*time.Second))
	logged := logRow("log-77", "912345678", invoiceContent, "Delivered", h.now.Add(20*time.Second))
	logged.UpdatedAt = h.now.Add(time.Minute)
	poller, metrics := checkPoller(h, &fakeSentLister{pages: onePage(logged, earlier)}, h.now.Add(2*time.Minute))
	result, err := poller.SyncOnce(context.Background())
	if err != nil || result.Held != 1 || result.Kept != 1 || result.Refunded != 0 || result.Delivered != 1 {
		t.Fatalf("the sync keeps what the log shows, and reports the earlier one: %+v %v", result, err)
	}
	row := h.ledgerRow(t, shop.Installation.ID, held.ID)
	if row.HeldSince != nil || row.Status != control.SMSStatusDelivered || row.ProviderMessageID != "log-77" ||
		row.ErrorCode != "" || row.DeliveredAt == nil || row.Price != "0.150" || row.Cost != "0.10" {
		t.Fatalf("it went out after all, stays paid for, and its cost is estimated: %+v", row)
	}
	if got := h.smsBalance(t, shop.Installation.ID); got != "14.700" {
		t.Fatalf("no refund for a message that went out, balance %s", got)
	}
	if metrics.Snapshot().SMSChecksByOutcome["kept"] != 1 {
		t.Fatalf("counted: %v", metrics.Snapshot().SMSChecksByOutcome)
	}
	// The shop's backend asking for its status now hears it was delivered.
	_, statuses, _ := h.do(t, http.MethodGet, "/v1/sms/status?ids="+held.ID, shop.AccessToken, "")
	if got := statuses["messages"].([]any)[0].(map[string]any)["status"]; got != "delivered" {
		t.Fatalf("the status endpoint reports the outcome: %v", statuses)
	}
}

func TestSMSCheckRefundsAHeldMessageTheLogDoesNotShow(t *testing.T) {
	h, shop := newCheckHarness(t)
	held := h.holdOne(t, shop.AccessToken, "lost")
	// Another message to the same phone at the same time, with other words.
	other := logRow("log-other", "912345678", "رسالة أخرى", "Delivered", h.now.Add(10*time.Second))
	older := logRow("log-old", "923456789", "x", "Delivered", h.now.Add(-time.Hour))
	lister := &fakeSentLister{pages: onePage(other, older)}

	// Too soon: the log may not show it yet.
	poller, _ := checkPoller(h, lister, h.now.Add(5*time.Minute))
	if result, err := poller.SyncOnce(context.Background()); err != nil || result.Refunded != 0 || result.Kept != 0 {
		t.Fatalf("a fresh hold waits: %+v %v", result, err)
	}
	if h.ledgerRow(t, shop.Installation.ID, held.ID).HeldSince == nil {
		t.Fatal("still held")
	}

	// Past the grace, in a read that reached back past it: refunded.
	poller, metrics := checkPoller(h, lister, h.now.Add(20*time.Minute))
	result, err := poller.SyncOnce(context.Background())
	if err != nil || result.Refunded != 1 || result.Kept != 0 {
		t.Fatalf("a message the log does not show is refunded: %+v %v", result, err)
	}
	row := h.ledgerRow(t, shop.Installation.ID, held.ID)
	if row.HeldSince != nil || row.Status != control.SMSStatusFailed || row.ErrorCode != "provider_error" {
		t.Fatalf("refunded and closed: %+v", row)
	}
	if got := h.smsBalance(t, shop.Installation.ID); got != smsShopBalance {
		t.Fatalf("its price came back, balance %s", got)
	}
	if metrics.Snapshot().SMSChecksByOutcome["refunded"] != 1 {
		t.Fatalf("counted: %v", metrics.Snapshot().SMSChecksByOutcome)
	}
	// Settled once: the next sync has nothing to do.
	if result, err := poller.SyncOnce(context.Background()); err != nil || result.Held != 0 || result.Refunded != 0 {
		t.Fatalf("nothing left to check: %+v %v", result, err)
	}
}

func TestSMSCheckWaitsWhileTheLogHasNotBeenReadBackFarEnough(t *testing.T) {
	h, shop := newCheckHarness(t)
	held := h.holdOne(t, shop.AccessToken, "deep")
	// A busy log: every page is full of later messages, deeper than the sync
	// may read in one go. Nothing proves the message is not in it.
	pages := map[int]resala.SentPage{}
	for page := 1; page <= smsSentLogCheckMaxPages+1; page++ {
		rows := make([]resala.SentMessage, smsDeliveryPageSize)
		for i := range rows {
			rows[i] = logRow(fmt.Sprintf("busy-%d-%d", page, i), "945555555", "x", "Delivered", h.now.Add(25*time.Minute))
		}
		pages[page] = resala.SentPage{CurrentPage: page, Messages: rows}
	}
	lister := &fakeSentLister{pages: pages}
	poller, _ := checkPoller(h, lister, h.now.Add(30*time.Minute))
	result, err := poller.SyncOnce(context.Background())
	if err != nil || result.Refunded != 0 || result.Kept != 0 {
		t.Fatalf("an uncovered hold waits: %+v %v", result, err)
	}
	if len(lister.calls) != smsSentLogCheckMaxPages {
		t.Fatalf("the sync reads deeper for a hold, up to its budget: %d pages", len(lister.calls))
	}
	if h.ledgerRow(t, shop.Installation.ID, held.ID).HeldSince == nil || h.smsBalance(t, shop.Installation.ID) != "14.850" {
		t.Fatal("still held, still paid")
	}
}

func TestSMSCheckNeverTakesAnotherMessagesLogRow(t *testing.T) {
	h, shop := newCheckHarness(t)
	held := h.holdOne(t, shop.AccessToken, "first-try")
	// The cashier saw "failed" and sent the same invoice again, which went
	// out; the sync matched it and pinned its log row.
	h.resala.respond(http.StatusCreated, resalaSendBody(invoiceTemplateBody, 0, true, "0.1"))
	status, again := h.send(t, shop.AccessToken, invoiceSend("second-try"))
	if status != http.StatusCreated {
		t.Fatalf("the resend: %d %v", status, again)
	}
	resentID, _ := again["id"].(string)
	if err := h.store.UpdateSMSDelivery(context.Background(), resentID, control.SMSStatusDelivered, "log-resent", h.now); err != nil {
		t.Fatal(err)
	}
	// The log has the one message that went out: the resend's.
	lister := &fakeSentLister{pages: onePage(
		logRow("log-resent", "912345678", invoiceContent, "Delivered", h.now.Add(3*time.Minute)),
	)}
	poller, _ := checkPoller(h, lister, h.now.Add(20*time.Minute))
	result, err := poller.SyncOnce(context.Background())
	if err != nil || result.Kept != 0 || result.Refunded != 1 {
		t.Fatalf("the resend's row is not the first try's: %+v %v", result, err)
	}
	if row := h.ledgerRow(t, shop.Installation.ID, held.ID); row.Status != control.SMSStatusFailed || row.HeldSince != nil {
		t.Fatalf("the first try never went out: %+v", row)
	}
	// One message paid for: the resend.
	if got := h.smsBalance(t, shop.Installation.ID); got != "14.850" {
		t.Fatalf("the shop pays for the one message that went out, balance %s", got)
	}
}

func TestSMSCheckPrefersTheNearerOfTwoIdenticalMessages(t *testing.T) {
	h, shop := newCheckHarness(t)
	held := h.holdOne(t, shop.AccessToken, "held")
	// The resend went out three minutes later and still awaits its report.
	h.resala.respond(http.StatusCreated, resalaSendBody(invoiceTemplateBody, 0, true, "0.1"))
	resentAt := h.now.Add(3 * time.Minute)
	h.server.Clock = testClock{now: resentAt}
	if status, body := h.send(t, shop.AccessToken, invoiceSend("resent")); status != http.StatusCreated {
		t.Fatalf("the resend: %d %v", status, body)
	}
	lister := &fakeSentLister{pages: onePage(
		logRow("log-1", "912345678", invoiceContent, "", resentAt.Add(5*time.Second)),
	)}
	poller, _ := checkPoller(h, lister, h.now.Add(20*time.Minute))
	result, err := poller.SyncOnce(context.Background())
	if err != nil || result.Kept != 0 || result.Refunded != 1 {
		t.Fatalf("the log row is the resend's, the nearer one: %+v %v", result, err)
	}
	if row := h.ledgerRow(t, shop.Installation.ID, held.ID); row.HeldSince != nil || row.Status != control.SMSStatusFailed {
		t.Fatalf("the held try is refunded: %+v", row)
	}
}

func TestSMSCheckRefundsUncheckedPastTheDeadline(t *testing.T) {
	h, shop := newCheckHarness(t)
	held := h.holdOne(t, shop.AccessToken, "stale")
	lister := &fakeSentLister{err: errors.New("resala is down")}

	// The log cannot be read: a fresh hold waits for it.
	poller, _ := checkPoller(h, lister, h.now.Add(time.Hour))
	if _, err := poller.SyncOnce(context.Background()); err == nil {
		t.Fatal("an unreadable log is an error")
	}
	if h.ledgerRow(t, shop.Installation.ID, held.ID).HeldSince == nil {
		t.Fatal("a hold waits while the log is unreadable")
	}

	// Two days on it still cannot be read: refunded rather than kept forever.
	poller, metrics := checkPoller(h, lister, h.now.Add(smsSentLogCheckDeadline+time.Minute))
	result, err := poller.SyncOnce(context.Background())
	if err == nil || result.Expired != 1 {
		t.Fatalf("an expired hold is refunded unchecked: %+v %v", result, err)
	}
	if row := h.ledgerRow(t, shop.Installation.ID, held.ID); row.HeldSince != nil || h.smsBalance(t, shop.Installation.ID) != smsShopBalance {
		t.Fatalf("refunded: %+v balance %s", row, h.smsBalance(t, shop.Installation.ID))
	}
	if metrics.Snapshot().SMSChecksByOutcome["expired"] != 1 {
		t.Fatalf("counted: %v", metrics.Snapshot().SMSChecksByOutcome)
	}
}
