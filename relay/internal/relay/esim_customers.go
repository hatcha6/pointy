package relay

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"pointy/relay/internal/airalo"
	"pointy/relay/internal/alerts"
	"pointy/relay/internal/control"
	"pointy/relay/internal/esimaccess"
	"pointy/relay/internal/fcm"
	"pointy/relay/internal/vouchers"
)

const (
	// esimUsageFresh is how long a usage reading is shown without asking again.
	// Airalo caches the answer for 20 minutes, so asking sooner tells nothing.
	esimUsageFresh = 10 * time.Minute
	esimReadBudget = 8 * time.Second
	// esimListRefresh bounds how many eSIMs one list read refreshes.
	esimListRefresh     = 8
	maxAiraloWebhookLen = 64 << 10
)

// routeCustomerESIM serves everything under /v1/customers/esim and /esims.
func (s HTTPServer) routeCustomerESIM(w http.ResponseWriter, r *http.Request, store control.CustomerStore, path string) {
	switch {
	case path == "/v1/customers/esim/webhook":
		s.handleAiraloWebhook(w, r)
	case strings.HasPrefix(path, ESIMAccessWebhookPath+"/"):
		s.handleESIMAccessWebhook(w, r, strings.TrimPrefix(path, ESIMAccessWebhookPath+"/"))
	case path == "/v1/customers/esim/destinations" && r.Method == http.MethodGet:
		if visible, answered := s.esimShelfVisible(w, r, store); answered {
			return
		} else if !visible {
			writeJSON(w, http.StatusOK, map[string]any{"available": false, "destinations": []any{}})
			return
		}
		s.handleESIMDestinations(w, r)
	case strings.HasPrefix(path, "/v1/customers/esim/destinations/") && r.Method == http.MethodGet:
		if visible, answered := s.esimShelfVisible(w, r, store); answered {
			return
		} else if !visible {
			writeCustomerError(w, http.StatusNotFound, "esim_unavailable", "eSIMs are not on sale right now", nil)
			return
		}
		s.handleESIMDestination(w, r, strings.TrimPrefix(path, "/v1/customers/esim/destinations/"))
	case path == "/v1/customers/esim/device" && r.Method == http.MethodPost:
		if visible, answered := s.esimShelfVisible(w, r, store); answered {
			return
		} else if !visible {
			writeJSON(w, http.StatusOK, map[string]any{"known": false})
			return
		}
		s.handleESIMDevice(w, r)
	case path == "/v1/customers/esims" && r.Method == http.MethodGet:
		s.withCustomer(w, r, store, func(customer control.Customer, _ control.CustomerSession) {
			s.handleCustomerESIMList(w, r, customer)
		})
	case strings.HasPrefix(path, "/v1/customers/esims/"):
		iccid, action, _ := strings.Cut(strings.TrimPrefix(path, "/v1/customers/esims/"), "/")
		s.withCustomer(w, r, store, func(customer control.Customer, _ control.CustomerSession) {
			switch {
			case action == "" && r.Method == http.MethodGet:
				s.handleCustomerESIMRead(w, r, customer, iccid)
			case action == "" && r.Method == http.MethodPut:
				s.handleCustomerESIMRename(w, r, customer, iccid)
			case action == "topups" && r.Method == http.MethodGet:
				s.handleCustomerESIMTopUps(w, r, customer, iccid)
			default:
				writeNotFound(w)
			}
		})
	default:
		writeNotFound(w)
	}
}

func (s HTTPServer) customerESIMStore(w http.ResponseWriter) (control.CustomerESIMStore, bool) {
	store, ok := s.Store.(control.CustomerESIMStore)
	if !ok {
		writeCustomerError(w, http.StatusServiceUnavailable, "esim_unavailable", "this relay keeps no eSIMs", nil)
	}
	return store, ok
}

// ownCustomerESIM reads an eSIM of the signed-in customer; any other's is "not found".
func (s HTTPServer) ownCustomerESIM(w http.ResponseWriter, r *http.Request, store control.CustomerESIMStore, customer control.Customer, iccid string) (control.CustomerESIM, bool) {
	esim, err := store.GetCustomerESIM(r.Context(), iccid)
	if errors.Is(err, control.ErrCustomerESIMNotFound) || (err == nil && esim.CustomerID != customer.ID) {
		writeCustomerError(w, http.StatusNotFound, "esim_not_found", "no such eSIM", nil)
		return control.CustomerESIM{}, false
	}
	if err != nil {
		s.customerInternalError(w, "customer eSIM read failed", err)
		return control.CustomerESIM{}, false
	}
	return s.esimAsHeld(r.Context(), esim), true
}

func customerESIMPayload(esim control.CustomerESIM) map[string]any {
	return map[string]any{
		"iccid": esim.ICCID, "order_id": esim.OrderID, "package_id": esim.PackageID,
		"title": esim.Title, "data": esim.Data, "days": esim.Days, "operator": esim.Operator,
		"destination": esim.Destination, "destination_name": esim.DestinationName, "country": esim.Country, "image": esim.Image,
		"unlimited": esim.Unlimited, "rechargeable": esim.Rechargeable,
		"label": esim.Label, "gift": esim.Gift, "test_mode": esim.TestMode && !esim.Simulated,
		"usage": map[string]any{
			"status": esim.UsageStatus, "remaining_mb": esim.RemainingMB, "total_mb": esim.TotalMB,
			"expires_at": esim.ExpiresAt, "read_at": esim.UsageAt,
		},
		"created_at": esim.CreatedAt,
	}
}

// refreshESIMUsage reads the usage when the last reading is old, and an eSIM
// that has ended is not asked about again. A failed read keeps the last reading.
func (s HTTPServer) refreshESIMUsage(ctx context.Context, store control.CustomerESIMStore, esim control.CustomerESIM) control.CustomerESIM {
	now := s.clock().Now()
	if esim.UsageAt != nil && now.Sub(*esim.UsageAt) < esimUsageFresh && esim.UsageStatus != "" {
		return esim
	}
	if esim.UsageStatus == airalo.UsageExpired {
		return esim
	}
	usage, ok := s.readESIMUsage(ctx, esim)
	if !ok {
		return esim
	}
	if err := store.UpdateCustomerESIMUsage(ctx, esim.ICCID, usage); err != nil {
		s.logger().Warn("storing an eSIM's usage failed", "iccid_tail", iccidTail(esim.ICCID), "error", err)
	}
	esim.UsageStatus, esim.RemainingMB, esim.TotalMB, esim.ExpiresAt, esim.UsageAt =
		usage.Status, usage.RemainingMB, usage.TotalMB, usage.ExpiresAt, &now
	return esim
}

func (s HTTPServer) readESIMUsage(ctx context.Context, esim control.CustomerESIM) (control.CustomerESIMUsage, bool) {
	if esim.Simulated {
		return simulatedESIMUsage(esim, 0), true
	}
	if esimSupplierOf(esim) == vouchers.SupplierESIMAccess {
		callCtx, cancel := context.WithTimeout(ctx, esimReadBudget)
		defer cancel()
		usage, err := s.esimAccessUsage(callCtx, esim)
		if err != nil {
			s.logger().Warn("reading an eSIM's usage failed", "iccid_tail", iccidTail(esim.ICCID), "error", err)
			return control.CustomerESIMUsage{}, false
		}
		return usage, true
	}
	if s.ESIM.Client == nil {
		return control.CustomerESIMUsage{}, false
	}
	callCtx, cancel := context.WithTimeout(ctx, esimReadBudget)
	defer cancel()
	usage, err := s.ESIM.Client.Usage(callCtx, esim.ICCID)
	if err != nil {
		// A recycled eSIM can never be used again; Airalo says so as an error.
		if airalo.IsCode(err, airalo.CodeRecycled) {
			return control.CustomerESIMUsage{Status: airalo.UsageExpired}, true
		}
		s.logger().Warn("reading an eSIM's usage failed", "iccid_tail", iccidTail(esim.ICCID), "error", err)
		return control.CustomerESIMUsage{}, false
	}
	reading := control.CustomerESIMUsage{
		Status:      strings.ToUpper(strings.TrimSpace(usage.Status)),
		RemainingMB: usage.RemainingMB.Int(),
		TotalMB:     usage.TotalMB.Int(),
		ExpiresAt:   parseAiraloTime(usage.ExpiredAt),
	}
	// Airalo's totals read 0 and mean nothing on an unlimited plan.
	if usage.Unlimited || esim.Unlimited {
		reading.RemainingMB, reading.TotalMB = 0, 0
	}
	return reading, true
}

// iccidTail names an eSIM in the logs without its whole number.
func iccidTail(iccid string) string {
	if len(iccid) <= 4 {
		return iccid
	}
	return iccid[len(iccid)-4:]
}

// handleCustomerESIMList serves GET /v1/customers/esims[?order=].
func (s HTTPServer) handleCustomerESIMList(w http.ResponseWriter, r *http.Request, customer control.Customer) {
	store, ok := s.customerESIMStore(w)
	if !ok {
		return
	}
	ctx := context.WithoutCancel(r.Context())
	var list []control.CustomerESIM
	if orderID := strings.TrimSpace(r.URL.Query().Get("order")); orderID != "" {
		esim, err := store.CustomerESIMByOrder(ctx, customer.ID, orderID)
		if err != nil && !errors.Is(err, control.ErrCustomerESIMNotFound) {
			s.customerInternalError(w, "customer eSIM read failed", err)
			return
		}
		if err == nil {
			list = []control.CustomerESIM{esim}
		}
	} else {
		var err error
		if list, err = store.ListCustomerESIMs(ctx, customer.ID); err != nil {
			s.customerInternalError(w, "customer eSIMs read failed", err)
			return
		}
	}
	for i := range list {
		list[i] = s.esimAsHeld(ctx, list[i])
	}
	// Reads the newest few that are out of date, at once.
	var wait sync.WaitGroup
	for i := range min(len(list), esimListRefresh) {
		wait.Add(1)
		go func(i int) {
			defer wait.Done()
			list[i] = s.refreshESIMUsage(ctx, store, list[i])
		}(i)
	}
	wait.Wait()
	payloads := make([]map[string]any, 0, len(list))
	for _, esim := range list {
		payloads = append(payloads, customerESIMPayload(esim))
	}
	writeJSON(w, http.StatusOK, map[string]any{"esims": payloads})
}

// handleCustomerESIMRead serves one eSIM, with how to install it.
func (s HTTPServer) handleCustomerESIMRead(w http.ResponseWriter, r *http.Request, customer control.Customer, iccid string) {
	store, ok := s.customerESIMStore(w)
	if !ok {
		return
	}
	esim, ok := s.ownCustomerESIM(w, r, store, customer, iccid)
	if !ok {
		return
	}
	ctx := context.WithoutCancel(r.Context())
	esim = s.refreshESIMUsage(ctx, store, esim)
	body := customerESIMPayload(esim)
	install, err := s.esimInstall(ctx, esim)
	if err != nil {
		// The eSIM is still theirs: the page shows the usage, and asks again.
		s.logger().Warn("reading an eSIM's install details failed", "iccid_tail", iccidTail(esim.ICCID), "error", err)
	} else {
		body["install"] = install
	}
	writeJSON(w, http.StatusOK, map[string]any{"esim": body})
}

// esimInstall is everything that installs an eSIM, read from its supplier each time:
// the direct links, the QR's text, the manual details, the APN and the share page.
func (s HTTPServer) esimInstall(ctx context.Context, esim control.CustomerESIM) (map[string]any, error) {
	if esim.Simulated {
		code := "TEST" + iccidTail(esim.ICCID)
		lpa := "LPA:1$test.dftr.ly$" + code
		return map[string]any{
			"qr": lpa, "smdp": "test.dftr.ly", "activation_code": code,
			"apple_url":   "https://esimsetup.apple.com/esim_qrcode_provisioning?carddata=" + lpa,
			"android_url": "https://esimsetup.android.com/esim_qrcode_provisioning?carddata=" + lpa,
			"roaming":     true, "apn_type": "automatic", "android_apn_type": "automatic",
			"share_link": "https://cards.dftr.ly", "share_code": "0000",
		}, nil
	}
	callCtx, cancel := context.WithTimeout(ctx, esimReadBudget)
	defer cancel()
	if esimSupplierOf(esim) == vouchers.SupplierESIMAccess {
		return s.esimAccessInstall(callCtx, esim)
	}
	if s.ESIM.Client == nil {
		return nil, errors.New("eSIMs are not configured")
	}
	sim, err := s.ESIM.Client.SIM(callCtx, esim.ICCID)
	if err != nil {
		return nil, err
	}
	install := map[string]any{
		"qr": sim.QRCode, "smdp": sim.LPA, "activation_code": sim.MatchingID,
		"confirmation_code": sim.Confirmation,
		"apple_url":         sim.AppleURL, "android_url": sim.AndroidURL,
		"roaming": sim.Roaming, "apn_type": sim.APNType, "apn_value": sim.APNValue,
		"recycled": sim.Recycled,
	}
	if sim.APN != nil {
		install["android_apn_type"], install["android_apn_value"] = sim.APN.Android.Type, sim.APN.Android.Value
		install["ios_apn_type"], install["ios_apn_value"] = sim.APN.IOS.Type, sim.APN.IOS.Value
	}
	if sim.Sharing != nil {
		install["share_link"], install["share_code"] = sim.Sharing.Link, sim.Sharing.AccessCode
	}
	return install, nil
}

type customerESIMRenameRequest struct {
	Label string `json:"label"`
}

func (s HTTPServer) handleCustomerESIMRename(w http.ResponseWriter, r *http.Request, customer control.Customer, iccid string) {
	store, ok := s.customerESIMStore(w)
	if !ok {
		return
	}
	var request customerESIMRenameRequest
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	esim, err := store.RenameCustomerESIM(r.Context(), customer.ID, iccid, request.Label)
	if errors.Is(err, control.ErrCustomerESIMNotFound) {
		writeCustomerError(w, http.StatusNotFound, "esim_not_found", "no such eSIM", nil)
		return
	}
	if err != nil {
		s.customerInternalError(w, "customer eSIM rename failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"esim": customerESIMPayload(esim)})
}

// handleCustomerESIMTopUps serves what an eSIM can be topped up with, priced.
func (s HTTPServer) handleCustomerESIMTopUps(w http.ResponseWriter, r *http.Request, customer control.Customer, iccid string) {
	store, ok := s.customerESIMStore(w)
	if !ok {
		return
	}
	esim, ok := s.ownCustomerESIM(w, r, store, customer, iccid)
	if !ok {
		return
	}
	ctx := r.Context()
	pricing, priced := s.esimPricingNow(ctx)
	if !priced {
		writeCustomerError(w, http.StatusServiceUnavailable, "esim_unavailable", "top-ups are not on sale right now", nil)
		return
	}
	plans, err := s.esimTopUps(ctx, esim)
	if err != nil {
		// A top-up the operator disabled, or a recycled eSIM: nothing to offer.
		if airalo.IsCode(err, airalo.CodeRecycled) || airalo.IsCode(err, airalo.CodeTopUpDisabled) || airalo.IsNotFound(err) ||
			errors.Is(err, esimaccess.ErrNoProfile) {
			writeJSON(w, http.StatusOK, map[string]any{"plans": []any{}})
			return
		}
		s.logger().Warn("reading an eSIM's top-ups failed", "iccid_tail", iccidTail(iccid), "error", err)
		writeCustomerError(w, http.StatusBadGateway, "esim_unavailable", "top-ups cannot be read right now", nil)
		return
	}
	rows := make([]map[string]any, 0, len(plans))
	for _, plan := range plans {
		price, ok := pricing.price(plan)
		if !ok {
			continue
		}
		rows = append(rows, map[string]any{
			"item": esimTopUpItemPrefix + esim.ICCID + ":" + plan.ID, "id": plan.ID,
			"title": plan.Title, "data": plan.Data, "amount_mb": plan.AmountMB, "days": plan.Days,
			"unlimited": plan.Unlimited, "voice": plan.Voice, "text": plan.Text, "info": plan.Info,
			"price": control.FormatWalletAmount(price),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"plans": rows})
}

// --- Airalo's webhook -------------------------------------------------------

func decodeAiraloEvent(body []byte) (airalo.Event, bool) {
	var event airalo.Event
	if err := json.Unmarshal(body, &event); err != nil {
		return airalo.Event{}, false
	}
	return event, true
}

// handleAiraloWebhook takes Airalo's alerts. HEAD is how Airalo checks the URL
// before an opt-in. A delivery is believed only with a good signature; one this
// relay cannot use is still acknowledged, or Airalo repeats it 20 times.
func (s HTTPServer) handleAiraloWebhook(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodHead:
		w.WriteHeader(http.StatusOK)
		return
	case http.MethodPost:
	default:
		writeNotFound(w)
		return
	}
	if s.ESIM.Client == nil {
		writeCustomerError(w, http.StatusServiceUnavailable, "esim_unavailable", "eSIMs are not configured", nil)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxAiraloWebhookLen))
	if err != nil {
		writeCustomerError(w, http.StatusRequestEntityTooLarge, "invalid_request", "the delivery is too large", nil)
		return
	}
	if !airalo.VerifySignature(s.ESIM.Client.Secret(), body, r.Header.Get(airalo.SignatureHeader)) {
		s.logger().Warn("an Airalo webhook failed its signature check", "bytes", len(body))
		writeCustomerError(w, http.StatusUnauthorized, "invalid_signature", "the signature does not match", nil)
		return
	}
	event, ok := decodeAiraloEvent(body)
	if !ok {
		s.logger().Warn("an Airalo webhook could not be read", "bytes", len(body))
		writeJSON(w, http.StatusOK, map[string]any{"status": "ignored"})
		return
	}
	ctx := context.WithoutCancel(r.Context())
	switch {
	case event.IsLowData():
		if err := s.tellESIMLowData(ctx, event); err != nil {
			// Above 204 means "try again": Airalo does, every 15 minutes.
			s.logger().Error("handling an eSIM low-data alert failed", "iccid_tail", iccidTail(event.ICCID), "error", err)
			writeCustomerError(w, http.StatusUnprocessableEntity, "not_processed", "try again", nil)
			return
		}
	case event.Message != "":
		s.logger().Warn("Airalo credit alert", "message", event.Message, "remaining", event.Remaining.String())
		if s.Alerts != nil {
			s.Alerts.Send(alerts.Message{
				Title:    "رصيد Airalo: " + truncateRunes(event.Message, 80),
				Body:     "Remaining: " + event.Remaining.String() + " USD\nTop the account up before eSIM orders start failing.",
				Priority: alerts.PriorityUrgent,
				Tags:     []string{"warning"},
			})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "processed"})
}

// tellESIMLowData pushes a low-data or expiry alert to the buyer's phones, once
// per level and package. An unknown ICCID (another system's, or a deleted
// account's) is no error.
func (s HTTPServer) tellESIMLowData(ctx context.Context, event airalo.Event) error {
	store, ok := s.Store.(control.CustomerESIMStore)
	if !ok {
		return nil
	}
	esim, err := store.GetCustomerESIM(ctx, event.ICCID)
	if errors.Is(err, control.ErrCustomerESIMNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	_, err = s.tellESIMLevel(ctx, store, esim, event.Level, event.PackageName)
	return err
}

// tellESIMLevel pushes one alert level of an eSIM to its buyer's phones, once
// per level and package, whichever supplier the eSIM is from. told is false for
// a level already told (or one with no message).
func (s HTTPServer) tellESIMLevel(ctx context.Context, store control.CustomerESIMStore, esim control.CustomerESIM, level, packageName string) (bool, error) {
	if _, ok := esimLowDataMessage(esim, level); !ok {
		s.logger().Warn("an eSIM alert of an unknown level", "level", level)
		return false, nil
	}
	first, err := store.ClaimCustomerESIMNotice(ctx, esim.ICCID, level, packageName)
	if err != nil || !first {
		return false, err
	}
	message, _ := esimLowDataMessage(esim, level)
	admin, ok := s.Store.(customerAdminStore)
	if s.CustomerPush == nil || !ok {
		return true, nil
	}
	pushCtx, cancel := context.WithTimeout(ctx, customerOrderPushBudget)
	defer cancel()
	sessions, err := admin.CustomerSessions(pushCtx, esim.CustomerID)
	if err != nil {
		return true, err
	}
	var record control.CustomerNotification
	s.pushToDevices(pushCtx, admin, sessions, message, &record)
	s.logger().Info("told a customer about their eSIM", "iccid_tail", iccidTail(esim.ICCID), "level", level,
		"devices", record.Devices, "sent", record.Sent, "failed", record.Failed)
	return true, nil
}

// esimLowDataMessage is what the phone says at each level, and it always ends on
// what to do next. A plan that takes no top-ups asks for a new eSIM instead.
func esimLowDataMessage(esim control.CustomerESIM, level string) (fcm.Message, bool) {
	whose := esimAlertWhose(esim)
	action := "اشحنها الآن لتبقى متصلاً."
	if !esim.Rechargeable {
		action = "اشترِ شريحة جديدة لتبقى متصلاً."
	}
	var title, body, tag string
	switch level {
	case airalo.Level75:
		title, tag = "استهلكت 75% من باقتك", "75"
		body = whose + ": بقي ربع الباقة تقريباً. " + action
	case airalo.Level90:
		title, tag = "باقتك على وشك النفاد", "90"
		body = whose + ": بقي 10% فقط. " + action
	case airalo.Level3Days:
		title, tag = "تنتهي باقتك بعد 3 أيام", "3days"
		body = whose + ": " + action
	case airalo.Level1Day:
		title, tag = "تنتهي باقتك غداً", "1day"
		body = whose + ": " + action
	case esimLevelUsedUp:
		title, tag = "انتهت بيانات باقتك", "used_up"
		body = whose + ": " + action
	default:
		return fcm.Message{}, false
	}
	return fcm.Message{
		Title: title, Body: body,
		Link:     customerESIMLink(esim.ICCID),
		Campaign: "esim_low_data_" + tag,
		// One alert per eSIM on the phone: the newest replaces the last.
		Order: "esim-" + esim.ICCID,
	}, true
}

// customerESIMLink opens one eSIM in the app.
func customerESIMLink(iccid string) string {
	return "https://cards.dftr.ly/esims/" + iccid
}
