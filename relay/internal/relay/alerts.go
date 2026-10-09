package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"pointy/relay/internal/alerts"
	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// The company's alert channel (see package alerts): an ntfy topic the
// company's phones subscribe to. The operator sets it up and tests it here:
//
//	GET  /v1/alerts        whether it is set up, and where to subscribe
//	POST /v1/alerts/topic  generate a fresh topic (a rotation shuts out
//	                       every phone subscribed to the old one)
//	POST /v1/alerts/test   send a test notification
//
// All admin-only. The topic is a secret on the public server, so only these
// routes ever answer it.

// AlertTopicSource reads the topic from the control store.
func AlertTopicSource(store control.InstallationStore) alerts.TopicSource {
	return alerts.TopicFunc(func(ctx context.Context) (string, error) {
		alertStore, ok := store.(control.AlertStore)
		if !ok {
			return "", nil
		}
		settings, err := alertStore.AlertSettings(ctx)
		return settings.Topic, err
	})
}

func (s HTTPServer) alertStore(w http.ResponseWriter) (control.AlertStore, bool) {
	store, ok := s.Store.(control.AlertStore)
	if !ok || s.Alerts == nil {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "alerts unavailable"})
		return nil, false
	}
	return store, true
}

func (s HTTPServer) alertPayload(settings control.AlertSettings) map[string]any {
	payload := map[string]any{
		"configured": settings.Topic != "",
		"server":     s.Alerts.ServerURL(),
	}
	if settings.Topic != "" {
		payload["topic"] = settings.Topic
		payload["subscribe_url"] = s.Alerts.SubscribeURL(settings.Topic)
		payload["updated_at"] = settings.UpdatedAt
		payload["actor"] = settings.Actor
	}
	return payload
}

func (s HTTPServer) handleAlertStatus(w http.ResponseWriter, r *http.Request) {
	store, ok := s.alertStore(w)
	if !ok {
		return
	}
	settings, err := store.AlertSettings(r.Context())
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, s.alertPayload(settings))
}

func (s HTTPServer) handleAlertTopic(w http.ResponseWriter, r *http.Request) {
	store, ok := s.alertStore(w)
	if !ok {
		return
	}
	var request struct {
		Actor string `json:"actor"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&request); err != nil && !errors.Is(err, io.EOF) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	topic, err := alerts.NewTopic()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not generate a topic"})
		return
	}
	settings, err := store.SetAlertSettings(r.Context(), control.AlertSettings{
		Topic: topic,
		Actor: adminActor(r, request.Actor),
	})
	if err != nil {
		writeStoreError(w, err)
		return
	}
	s.Alerts.Forget()
	s.logger().Warn("relay alert topic set", "actor", settings.Actor)
	writeJSON(w, http.StatusOK, s.alertPayload(settings))
}

func (s HTTPServer) handleAlertTest(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.alertStore(w); !ok {
		return
	}
	s.Alerts.Forget()
	err := s.Alerts.Publish(r.Context(), alerts.Message{
		Title:    "Relay alerts are working",
		Body:     fmt.Sprintf("Test from relay node %s at %s.", s.NodeID, s.clock().Now().UTC().Format(time.RFC3339)),
		Priority: alerts.PriorityDefault,
		Tags:     []string{"tada"},
	})
	if errors.Is(err, alerts.ErrNoTopic) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
		return
	}
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"sent": true})
}

// alertOnce sends message unless an alert under key went out less than
// cooldown ago, from this relay instance or another.
func (s HTTPServer) alertOnce(key string, cooldown time.Duration, message alerts.Message) {
	if s.Alerts == nil {
		return
	}
	store, ok := s.Store.(control.AlertStore)
	if !ok {
		return
	}
	won, err := store.ClaimAlert(context.Background(), key, cooldown)
	if err != nil {
		s.logger().Warn("alert mark unclaimable; alert not sent", "key", key, "error", err)
		return
	}
	if won {
		s.Alerts.Send(message)
	}
}

// supplierAccountAlertCooldown spaces repeats of one supplier refusing the
// company's account: every purchase meets it, the phone needs it once an hour.
const supplierAccountAlertCooldown = time.Hour

// alertSupplierAccount says the company's account at a card supplier cannot
// buy (its balance is empty, its credentials refused).
func (s HTTPServer) alertSupplierAccount(supplier string, failure *vouchers.Failure) {
	if failure == nil || (failure.Code != vouchers.FailureCredit && failure.Code != vouchers.FailureUnauthorized) {
		return
	}
	title := supplier + ": out of balance"
	if failure.Code == vouchers.FailureUnauthorized {
		title = supplier + ": credentials refused"
	}
	s.alertOnce("supplier_account:"+supplier+":"+failure.Code, supplierAccountAlertCooldown, alerts.Message{
		Title:    title,
		Body:     "A card purchase failed on the company's account at " + supplier + ".\n" + truncateRunes(failure.Detail, 300),
		Priority: alerts.PriorityUrgent,
		Tags:     []string{"rotating_light"},
		Click:    "/suppliers?tab=balances",
	})
}

// alertWalletTopUp tells the company's phones how a shop's wallet payment
// ended: paid or failed. Nothing else is sent: not its start, not a
// cancellation, not a mistyped code.
func alertWalletTopUp(notifier *alerts.Ntfy, topUp control.WalletTopUp, event, detail string) {
	if notifier == nil {
		return
	}
	message, ok := walletTopUpAlert(topUp, event, detail)
	if ok {
		notifier.Send(message)
	}
}

func walletTopUpAlert(topUp control.WalletTopUp, event, detail string) (alerts.Message, bool) {
	amount := topUp.Amount + " LYD"
	shop := strings.TrimSpace(topUp.ShopName)
	if shop == "" {
		shop = topUp.InstallationID
	}
	method := topUp.Method
	if known, ok := lookupWalletMethod(topUp.Method); ok {
		method = known.NameAr
	} else if transfer := topUp.Transfer; transfer != nil {
		method = "Bank transfer (" + transfer.Channel + ")"
	}
	lines := []string{
		"Shop: " + shop,
		"Method: " + method,
		"Invoice: " + topUp.InvoiceNo,
	}
	if topUp.RequestedBy != "" {
		lines = append(lines, "By: "+topUp.RequestedBy)
	}
	if transfer := topUp.Transfer; transfer != nil {
		lines = append(lines, "From: "+transfer.PayerBank+" "+transfer.PayerAccount, "IBAN: "+transfer.PayerIBAN)
	} else if topUp.PayerHint != "" {
		lines = append(lines, "Payer: "+topUp.PayerHint)
	}
	if topUp.ErrorCode == control.WalletTopUpRejected {
		lines = append(lines, "Reason: "+truncateRunes(topUp.ErrorDetail, 200))
	} else if topUp.ErrorCode != "" {
		lines = append(lines, "Reason: "+topUp.ErrorCode)
	}
	if detail != "" {
		lines = append(lines, truncateRunes(detail, 200))
	}
	var message alerts.Message
	switch {
	case event == "bank_transfer_submitted":
		// The one alert that asks for work: a receipt waits for someone to
		// find the money on the statement. Tapping it opens the review.
		message = alerts.Message{Title: "Bank transfer to verify: " + amount, Priority: alerts.PriorityHigh, Tags: []string{"bank", "receipt"}}
	case event == "operator_rejected":
		message = alerts.Message{Title: "Bank transfer rejected " + amount, Priority: alerts.PriorityLow, Tags: []string{"no_entry_sign"}}
	case strings.HasPrefix(event, "paid_"), event == "operator_confirmed":
		message = alerts.Message{Title: "Paid " + amount, Priority: alerts.PriorityHigh, Tags: []string{"white_check_mark", "moneybag"}}
		if event == "operator_confirmed" {
			message.Title += " (confirmed by hand)"
		}
	case strings.HasPrefix(event, "held_"):
		message = alerts.Message{Title: "Paid with a mismatch, reconcile: " + amount, Priority: alerts.PriorityUrgent, Tags: []string{"rotating_light"}}
	case event == "start_failed", event == "confirm_declined", event == "otp_attempts_exceeded":
		message = alerts.Message{Title: "Top-up failed " + amount, Priority: alerts.PriorityDefault, Tags: []string{"x"}}
		if topUp.ErrorCode == walletCodeGatewayUnauthorized {
			message.Priority, message.Tags = alerts.PriorityUrgent, []string{"rotating_light"}
		}
	default:
		return alerts.Message{}, false
	}
	if topUp.TestMode {
		message.Title = "[TEST] " + message.Title
		message.Priority = min(message.Priority, alerts.PriorityLow)
	}
	message.Body = strings.Join(lines, "\n")
	message.Click = "/topups/" + url.PathEscape(topUp.ID)
	return message, true
}
