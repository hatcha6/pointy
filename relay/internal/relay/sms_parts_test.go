package relay

import (
	"bytes"
	"context"
	"log/slog"
	"net/http"
	"strings"
	"testing"

	"pointy/relay/internal/control"
)

// A shop with a long name pushes the invoice past one SMS (70 Arabic letters).
func longInvoiceSend(key string) string {
	return smsSendJSON("invoice", "+218912345678", key, false, "مؤسسة النور للمواد الغذائية والمنظفات", "000123", "125.00 د.ل")
}

func (h *smsHarness) smsEntries(t *testing.T, installationID string) []control.WalletEntry {
	t.Helper()
	entries, err := h.store.ListWalletEntries(context.Background(), control.WalletEntryFilter{
		InstallationID: installationID,
		Account:        control.WalletAccountSMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	return entries
}

func (h *smsHarness) ledgerRow(t *testing.T, installationID, id string) control.SMSMessage {
	t.Helper()
	rows, err := h.store.GetSMSByIDs(context.Background(), installationID, []string{id})
	if err != nil || len(rows) != 1 {
		t.Fatalf("ledger row %s: %v %v", id, rows, err)
	}
	return rows[0]
}

func TestSMSSendIsPaidPerPart(t *testing.T) {
	h := newSMSHarness(t)
	h.learnTemplate(t, "tpl-invoice", invoiceTemplateBody)
	shop := h.provision(t, smsShop{funded: true})

	status, body := h.send(t, shop.AccessToken, longInvoiceSend("long-1"))
	if status != http.StatusCreated || body["parts"] != float64(2) || body["charged"] != "0.300" || body["balance"] != "14.700" {
		t.Fatalf("a two-SMS invoice costs two parts: %d %v", status, body)
	}
	row := h.ledgerRow(t, shop.Installation.ID, body["id"].(string))
	if row.Parts != 2 || row.Price != "0.300" {
		t.Fatalf("the ledger keeps the parts and their price: %+v", row)
	}
	entries := h.smsEntries(t, shop.Installation.ID)
	var charge *control.WalletEntry
	for i := range entries {
		if entries[i].Kind == control.WalletEntryCharge {
			if charge != nil {
				t.Fatalf("a message counted right is one statement line: %+v", entries)
			}
			charge = &entries[i]
		}
	}
	if charge == nil || charge.Amount != "-0.300" || charge.Description != "فاتورة بيع (رسالتان)" {
		t.Fatalf("the statement says how many SMS the message took: %+v", charge)
	}

	// A replay reports the same parts and price, and charges nothing again.
	status, body = h.send(t, shop.AccessToken, longInvoiceSend("long-1"))
	if status != http.StatusOK || body["replayed"] != true || body["parts"] != float64(2) ||
		body["charged"] != "0.300" || body["balance"] != "14.700" {
		t.Fatalf("a replay: %d %v", status, body)
	}

	// The usage report counts the SMS the messages took and what they were paid.
	if _, body := h.send(t, shop.AccessToken, invoiceSend("short-1")); body["parts"] != float64(1) {
		t.Fatalf("a short invoice is one part: %v", body)
	}
	status, usage := h.admin(t, "/v1/sms/usage")
	totals, _ := usage["totals"].(map[string]any)
	if status != http.StatusOK || totals["messages"] != float64(2) || totals["parts"] != float64(3) || totals["charged"] != "0.450" {
		t.Fatalf("usage totals: %d %v", status, usage)
	}
}

func TestSMSSendRefusesWhatTheBalanceCannotHold(t *testing.T) {
	h := newSMSHarness(t)
	h.learnTemplate(t, "tpl-invoice", invoiceTemplateBody)
	shop := h.provision(t, smsShop{})
	h.fundSMS(t, shop.Installation.ID, "0.150")

	// One part's worth does not pay for a two-part message, and says so.
	status, body := h.send(t, shop.AccessToken, longInvoiceSend("long"))
	expectSMSCode(t, status, body, http.StatusPaymentRequired, "insufficient_balance")
	if body["parts"] != float64(2) || body["amount"] != "0.300" || body["balance"] != "0.150" || body["price"] != "0.150" {
		t.Fatalf("the refusal names the parts and their price: %v", body)
	}
	if len(h.resala.calls()) != 0 {
		t.Fatal("a message the balance cannot hold never reaches Resala")
	}
	// It still pays for a short one.
	if status, body := h.send(t, shop.AccessToken, invoiceSend("short")); status != http.StatusCreated || body["balance"] != "0.000" {
		t.Fatalf("a one-part message fits: %d %v", status, body)
	}
}

func TestSMSSendHoldsTheLongestForANeverSentTemplate(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{})
	h.fundSMS(t, shop.Installation.ID, "0.300")

	// Nothing has gone out from this template yet, so the relay cannot count
	// the message: it holds as if the text were as long as any template.
	status, body := h.send(t, shop.AccessToken, invoiceSend("first"))
	expectSMSCode(t, status, body, http.StatusPaymentRequired, "insufficient_balance")
	if body["parts"] != float64(3) || body["amount"] != "0.450" {
		t.Fatalf("a never-sent template holds the longest: %v", body)
	}

	h.fundSMS(t, shop.Installation.ID, "0.150")
	status, body = h.send(t, shop.AccessToken, invoiceSend("first"))
	if status != http.StatusCreated || body["parts"] != float64(1) || body["charged"] != "0.150" || body["balance"] != "0.300" {
		t.Fatalf("the answer gives back what the hold did not need: %d %v", status, body)
	}
	var held, returned bool
	for _, entry := range h.smsEntries(t, shop.Installation.ID) {
		switch {
		case entry.Kind == control.WalletEntryCharge && entry.Amount == "-0.450" && entry.Description == "فاتورة بيع (3 رسائل)":
			held = true
		case entry.Kind == control.WalletEntryRefund && entry.Amount == "0.300" &&
			entry.Description == "استرداد فرق عدد الرسائل: فاتورة بيع (رسالة واحدة)":
			returned = true
		}
	}
	if !held || !returned {
		t.Fatalf("the statement shows the hold and what came back: %+v", h.smsEntries(t, shop.Installation.ID))
	}

	// From now on the template's text is known: the next message is held for
	// exactly its one part.
	status, body = h.send(t, shop.AccessToken, invoiceSend("second"))
	if status != http.StatusCreated || body["balance"] != "0.150" {
		t.Fatalf("a known template holds exactly: %d %v", status, body)
	}
	for _, entry := range h.smsEntries(t, shop.Installation.ID) {
		if entry.Reference == body["id"] && entry.Amount != "-0.150" {
			t.Fatalf("held for one part, settled nothing: %+v", entry)
		}
	}
}

func TestSMSSendBillsTheSMSResalaCounts(t *testing.T) {
	h := newSMSHarness(t)
	h.learnTemplate(t, "tpl-invoice", invoiceTemplateBody)
	shop := h.provision(t, smsShop{})
	h.fundSMS(t, shop.Installation.ID, "0.150")

	// Resala sent the one-part text as two SMS: the company pays for two, so
	// the shop does, even past its balance — the message is already out.
	h.resala.respond(http.StatusCreated, resalaSendBodyCounting(invoiceTemplateBody, 0, true, "0.2", 2))
	status, body := h.send(t, shop.AccessToken, invoiceSend("counted-two"))
	if status != http.StatusCreated || body["parts"] != float64(2) || body["charged"] != "0.300" || body["balance"] != "-0.150" {
		t.Fatalf("the shop pays what Resala bills: %d %v", status, body)
	}
	var settled bool
	for _, entry := range h.smsEntries(t, shop.Installation.ID) {
		if entry.Kind == control.WalletEntryCharge && entry.Amount == "-0.150" &&
			entry.Description == "فرق عدد الرسائل: فاتورة بيع (رسالتان)" {
			settled = true
		}
	}
	if !settled {
		t.Fatalf("the extra part is its own statement line: %+v", h.smsEntries(t, shop.Installation.ID))
	}
	// Below zero, nothing more goes out until the debt is paid.
	status, body = h.send(t, shop.AccessToken, invoiceSend("in-debt"))
	expectSMSCode(t, status, body, http.StatusPaymentRequired, "insufficient_balance")

	// A count far above the text's own is a glitch, not a longer message: the
	// shop pays at most two parts more than the relay counted.
	h.fundSMS(t, shop.Installation.ID, "1.150")
	h.resala.respond(http.StatusCreated, resalaSendBodyCounting(invoiceTemplateBody, 0, true, "0.3", 40))
	status, body = h.send(t, shop.AccessToken, invoiceSend("glitch"))
	if status != http.StatusCreated || body["parts"] != float64(3) || body["charged"] != "0.450" {
		t.Fatalf("a glitching count is capped: %d %v", status, body)
	}
	// A count below the text's own does not lower the price.
	h.resala.respond(http.StatusCreated, resalaSendBodyCounting(invoiceTemplateBody, 0, true, "0.1", 1))
	status, body = h.send(t, shop.AccessToken, longInvoiceSend("counted-low"))
	if status != http.StatusCreated || body["parts"] != float64(2) || body["charged"] != "0.300" {
		t.Fatalf("the relay's own count is the floor: %d %v", status, body)
	}
}

func TestSMSSendRaisesTheAlarmWhenAMessageSellsBelowCost(t *testing.T) {
	h := newSMSHarness(t)
	var logs bytes.Buffer
	h.server.Logger = slog.New(slog.NewTextHandler(&logs, nil))
	h.learnTemplate(t, "tpl-invoice", invoiceTemplateBody)
	shop := h.provision(t, smsShop{funded: true})

	if status, body := h.send(t, shop.AccessToken, invoiceSend("at-margin")); status != http.StatusCreated {
		t.Fatalf("send: %d %v", status, body)
	}
	if strings.Contains(logs.String(), "raise POINTY_RELAY_SMS_PRICE") {
		t.Fatalf("0.150 against a 0.10 cost is no alarm:\n%s", logs.String())
	}

	// Resala charged more for the message than the shop paid for it.
	h.resala.respond(http.StatusCreated, resalaSendBody(invoiceTemplateBody, 0, true, "0.2"))
	if status, body := h.send(t, shop.AccessToken, invoiceSend("below-cost")); status != http.StatusCreated {
		t.Fatalf("send: %d %v", status, body)
	}
	if !strings.Contains(logs.String(), "level=ERROR") || !strings.Contains(logs.String(), "raise POINTY_RELAY_SMS_PRICE") {
		t.Fatalf("a message sold below cost must raise the alarm:\n%s", logs.String())
	}
}
