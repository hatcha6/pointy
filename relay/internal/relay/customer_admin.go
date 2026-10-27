package relay

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"

	"pointy/relay/internal/control"
	"pointy/relay/internal/fcm"
)

// The operator console's view of «دفتر كروت» (admin token): who the customers
// are and what they bought, their credit, their devices; stopping an
// account, adjusting its credit, and the notifications sent to them.
//
//	GET    /v1/customers/admin/summary
//	GET    /v1/customers/admin/customers?q=&segment=&limit=&offset=
//	GET    /v1/customers/admin/customers/{id}
//	POST   /v1/customers/admin/customers/{id}/credit    {amount, note, key}
//	POST   /v1/customers/admin/customers/{id}/block     {blocked, reason}
//	POST   /v1/customers/admin/customers/{id}/sign-out
//	DELETE /v1/customers/admin/customers/{id}/sessions/{session}
//	DELETE /v1/customers/admin/customers/{id}
//	GET    /v1/customers/admin/orders?status=&channel=&q=&customer=&limit=
//	GET    /v1/customers/admin/orders/{id}
//	GET    /v1/customers/admin/notifications?customer=&limit=
//	POST   /v1/customers/admin/notifications            {audience, customer_id, title, body, link, campaign}
//	GET    /v1/customers/admin/shelf
//	PUT    /v1/customers/admin/shelf                    {ios_gift_cards}

// CustomerPusher sends a notification to a topic or to one device (fcm).
type CustomerPusher interface {
	SendTopic(ctx context.Context, topic string, message fcm.Message) error
	SendToken(ctx context.Context, token string, message fcm.Message) error
}

// customerPushAudiences are the topics every phone of a build joins.
var customerPushAudiences = map[string]bool{"all": true, "ios": true, "play": true, "apk": true}

const customerAdminPrefix = "/v1/customers/admin/"

type customerAdminStore interface {
	control.CustomerStore
	control.CustomerOrderStore
	control.CustomerAdminStore
}

func (s HTTPServer) handleCustomerAdminRoutes(w http.ResponseWriter, r *http.Request) {
	store, ok := s.Store.(customerAdminStore)
	if !ok {
		writeCustomerError(w, http.StatusServiceUnavailable, "customers_unconfigured", "this relay keeps no customers", nil)
		return
	}
	route := strings.TrimPrefix(strings.TrimSuffix(r.URL.Path, "/"), customerAdminPrefix)
	parts := strings.Split(route, "/")
	switch {
	case route == "summary" && r.Method == http.MethodGet:
		s.handleCustomerAdminSummary(w, r, store)
	case route == "customers" && r.Method == http.MethodGet:
		s.handleCustomerAdminList(w, r, store)
	case len(parts) == 2 && parts[0] == "customers" && r.Method == http.MethodGet:
		s.handleCustomerAdminDetail(w, r, store, parts[1])
	case len(parts) == 2 && parts[0] == "customers" && r.Method == http.MethodDelete:
		s.handleCustomerAdminDelete(w, r, store, parts[1])
	case len(parts) == 3 && parts[0] == "customers" && parts[2] == "credit" && r.Method == http.MethodPost:
		s.handleCustomerAdminCredit(w, r, store, parts[1])
	case len(parts) == 3 && parts[0] == "customers" && parts[2] == "block" && r.Method == http.MethodPost:
		s.handleCustomerAdminBlock(w, r, store, parts[1])
	case len(parts) == 3 && parts[0] == "customers" && parts[2] == "sign-out" && r.Method == http.MethodPost:
		s.handleCustomerAdminSignOut(w, r, store, parts[1], "")
	case len(parts) == 4 && parts[0] == "customers" && parts[2] == "sessions" && r.Method == http.MethodDelete:
		s.handleCustomerAdminSignOut(w, r, store, parts[1], parts[3])
	case route == "orders" && r.Method == http.MethodGet:
		s.handleCustomerAdminOrders(w, r, store)
	case len(parts) == 2 && parts[0] == "orders" && r.Method == http.MethodGet:
		s.handleCustomerAdminOrder(w, r, store, parts[1])
	case route == "notifications" && r.Method == http.MethodGet:
		s.handleCustomerAdminNotifications(w, r, store)
	case route == "shelf" && r.Method == http.MethodGet:
		s.handleCustomerAdminShelf(w, r)
		return
	case route == "shelf" && r.Method == http.MethodPut:
		s.handleCustomerAdminSetShelf(w, r)
		return
	case route == "notifications" && r.Method == http.MethodPost:
		s.handleCustomerAdminNotify(w, r, store)
	default:
		writeNotFound(w)
	}
}

func queryInt(values url.Values, key string, fallback, most int) int {
	value, err := strconv.Atoi(values.Get(key))
	if err != nil || value <= 0 {
		return fallback
	}
	return min(value, most)
}

func (s HTTPServer) handleCustomerAdminSummary(w http.ResponseWriter, r *http.Request, store customerAdminStore) {
	stats, err := store.CustomerStats(r.Context())
	if err != nil {
		s.customerInternalError(w, "customer stats failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"stats": stats, "push_configured": s.CustomerPush != nil})
}

func (s HTTPServer) handleCustomerAdminList(w http.ResponseWriter, r *http.Request, store customerAdminStore) {
	query := r.URL.Query()
	list, total, err := store.ListCustomers(r.Context(), control.CustomerListFilter{
		Query:   query.Get("q"),
		Segment: query.Get("segment"),
		Limit:   queryInt(query, "limit", 100, 500),
		Offset:  queryInt(query, "offset", 0, 1_000_000),
	})
	if err != nil {
		s.customerInternalError(w, "customer list failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"customers": list, "total": total})
}

// customerAdminSessionView is a device as the console shows it: never its
// token hashes, only whether it can be sent a notification.
func customerAdminSessionView(session control.CustomerSession) map[string]any {
	return map[string]any{
		"id":           session.ID,
		"device_name":  session.DeviceName,
		"platform":     session.Platform,
		"created_at":   session.CreatedAt,
		"last_seen_at": session.LastSeenAt,
		"expires_at":   session.ExpiresAt,
		"push":         session.PushToken != "",
	}
}

func (s HTTPServer) handleCustomerAdminDetail(w http.ResponseWriter, r *http.Request, store customerAdminStore, id string) {
	ctx := r.Context()
	summary, err := store.CustomerSummaryByID(ctx, id)
	if errors.Is(err, control.ErrCustomerNotFound) {
		writeCustomerError(w, http.StatusNotFound, "customer_not_found", "no such customer", nil)
		return
	}
	if err != nil {
		s.customerInternalError(w, "customer read failed", err)
		return
	}
	sessions, err := store.CustomerSessions(ctx, id)
	if err != nil {
		s.customerInternalError(w, "customer sessions failed", err)
		return
	}
	devices := make([]map[string]any, 0, len(sessions))
	for _, session := range sessions {
		devices = append(devices, customerAdminSessionView(session))
	}
	balance, entries, err := store.CustomerCredit(ctx, id, 100)
	if err != nil {
		s.customerInternalError(w, "customer credit failed", err)
		return
	}
	orders, err := store.ListCustomerOrders(ctx, control.CustomerOrderFilter{CustomerID: id, Limit: 200})
	if err != nil {
		s.customerInternalError(w, "customer orders failed", err)
		return
	}
	notifications, err := store.ListCustomerNotifications(ctx, control.CustomerNotificationFilter{CustomerID: id, Limit: 50})
	if err != nil {
		s.customerInternalError(w, "customer notifications failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"customer":      summary,
		"sessions":      devices,
		"credit":        map[string]any{"balance": balance, "entries": entries},
		"orders":        orders,
		"notifications": notifications,
	})
}

func (s HTTPServer) handleCustomerAdminDelete(w http.ResponseWriter, r *http.Request, store customerAdminStore, id string) {
	err := store.DeleteCustomer(r.Context(), id)
	if errors.Is(err, control.ErrCustomerNotFound) {
		writeCustomerError(w, http.StatusNotFound, "customer_not_found", "no such customer", nil)
		return
	}
	if err != nil {
		s.customerInternalError(w, "customer delete failed", err)
		return
	}
	s.logger().Info("operator deleted a customer account", "customer_id", id, "actor", adminActor(r, ""))
	w.WriteHeader(http.StatusNoContent)
}

func (s HTTPServer) handleCustomerAdminCredit(w http.ResponseWriter, r *http.Request, store customerAdminStore, id string) {
	var request struct {
		Amount string `json:"amount"`
		Note   string `json:"note"`
		Key    string `json:"key"`
		Actor  string `json:"actor"` // the console names its operator in every write
	}
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	entry, balance, created, err := store.AdjustCustomerCredit(r.Context(), control.CustomerCreditChange{
		CustomerID: id, Amount: request.Amount, Note: request.Note, Actor: adminActor(r, request.Actor), Reference: request.Key,
	})
	switch {
	case errors.Is(err, control.ErrCustomerNotFound):
		writeCustomerError(w, http.StatusNotFound, "customer_not_found", "no such customer", nil)
	case errors.Is(err, control.ErrCustomerCreditInvalid):
		writeCustomerError(w, http.StatusBadRequest, "invalid_adjustment",
			"an adjustment needs a non-zero amount (at most three decimals), a note and a key", nil)
	case errors.Is(err, control.ErrCustomerCreditInsufficient):
		writeCustomerError(w, http.StatusConflict, "insufficient_credit", "the customer's credit cannot go below zero", nil)
	case err != nil:
		s.customerInternalError(w, "customer credit adjustment failed", err)
	default:
		if created {
			s.logger().Info("operator adjusted a customer's credit",
				"customer_id", id, "amount", entry.Amount, "actor", entry.Actor)
		}
		writeJSON(w, http.StatusOK, map[string]any{"entry": entry, "balance": balance, "created": created})
	}
}

func (s HTTPServer) handleCustomerAdminBlock(w http.ResponseWriter, r *http.Request, store customerAdminStore, id string) {
	var request struct {
		Blocked bool   `json:"blocked"`
		Reason  string `json:"reason"`
		Actor   string `json:"actor"`
	}
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	if request.Blocked && strings.TrimSpace(request.Reason) == "" {
		writeCustomerError(w, http.StatusBadRequest, "reason_required", "say why the account is stopped", nil)
		return
	}
	customer, err := store.SetCustomerBlocked(r.Context(), id, request.Blocked, request.Reason)
	if errors.Is(err, control.ErrCustomerNotFound) {
		writeCustomerError(w, http.StatusNotFound, "customer_not_found", "no such customer", nil)
		return
	}
	if err != nil {
		s.customerInternalError(w, "customer block failed", err)
		return
	}
	s.logger().Info("operator changed a customer's access",
		"customer_id", id, "blocked", request.Blocked, "actor", adminActor(r, request.Actor))
	writeJSON(w, http.StatusOK, map[string]any{"customer": customer})
}

func (s HTTPServer) handleCustomerAdminSignOut(w http.ResponseWriter, r *http.Request, store customerAdminStore, id, sessionID string) {
	if sessionID != "" {
		deleted, err := store.DeleteCustomerSession(r.Context(), id, sessionID)
		if err != nil {
			s.customerInternalError(w, "customer sign-out failed", err)
			return
		}
		if !deleted {
			writeCustomerError(w, http.StatusNotFound, "session_not_found", "no such session", nil)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"signed_out": 1})
		return
	}
	count, err := store.DeleteCustomerSessions(r.Context(), id)
	if err != nil {
		s.customerInternalError(w, "customer sign-out failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"signed_out": count})
}

// customerOrderAdminView is an order with its customer's phone.
type customerOrderAdminView struct {
	control.CustomerOrder
	CustomerPhone string `json:"customer_phone,omitempty"`
}

// withPhones names each order's customer, reading each customer once.
func withPhones(ctx context.Context, store customerAdminStore, orders []control.CustomerOrder) []customerOrderAdminView {
	phones := map[string]string{}
	views := make([]customerOrderAdminView, 0, len(orders))
	for _, order := range orders {
		phone, known := phones[order.CustomerID]
		if !known {
			if customer, err := store.GetCustomer(ctx, order.CustomerID); err == nil {
				phone = customer.Phone
			}
			phones[order.CustomerID] = phone
		}
		views = append(views, customerOrderAdminView{CustomerOrder: order, CustomerPhone: phone})
	}
	return views
}

func (s HTTPServer) handleCustomerAdminOrders(w http.ResponseWriter, r *http.Request, store customerAdminStore) {
	query := r.URL.Query()
	orders, err := store.ListCustomerOrders(r.Context(), control.CustomerOrderFilter{
		CustomerID: query.Get("customer"),
		Status:     query.Get("status"),
		Channel:    query.Get("channel"),
		Query:      query.Get("q"),
		Limit:      queryInt(query, "limit", 200, 1000),
	})
	if err != nil {
		s.customerInternalError(w, "customer orders failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"orders": withPhones(r.Context(), store, orders)})
}

func (s HTTPServer) handleCustomerAdminOrder(w http.ResponseWriter, r *http.Request, store customerAdminStore, id string) {
	order, err := store.GetCustomerOrder(r.Context(), id)
	if errors.Is(err, control.ErrCustomerOrderNotFound) {
		writeCustomerError(w, http.StatusNotFound, "order_not_found", "no such order", nil)
		return
	}
	if err != nil {
		s.customerInternalError(w, "customer order read failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"order": withPhones(r.Context(), store, []control.CustomerOrder{order})[0]})
}

func (s HTTPServer) handleCustomerAdminNotifications(w http.ResponseWriter, r *http.Request, store customerAdminStore) {
	query := r.URL.Query()
	list, err := store.ListCustomerNotifications(r.Context(), control.CustomerNotificationFilter{
		CustomerID: query.Get("customer"),
		Limit:      queryInt(query, "limit", 100, 500),
	})
	if err != nil {
		s.customerInternalError(w, "customer notifications failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"notifications": list, "push_configured": s.CustomerPush != nil})
}

// customerNotificationLink keeps a notification's link on the app's own
// address: anything else would open in the app as the shelf, or not at all.
func customerNotificationLink(raw string) (string, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", true
	}
	link, err := url.Parse(raw)
	if err != nil || link.Scheme != "https" || link.Host != "cards.dftr.ly" || link.User != nil {
		return "", false
	}
	return link.String(), true
}

func (s HTTPServer) handleCustomerAdminNotify(w http.ResponseWriter, r *http.Request, store customerAdminStore) {
	if s.CustomerPush == nil {
		writeCustomerError(w, http.StatusServiceUnavailable, "push_unconfigured",
			"notifications are not configured (POINTY_RELAY_FCM_SERVICE_ACCOUNT)", nil)
		return
	}
	var request struct {
		Audience   string `json:"audience"`
		CustomerID string `json:"customer_id"`
		Title      string `json:"title"`
		Body       string `json:"body"`
		Link       string `json:"link"`
		Campaign   string `json:"campaign"`
		Actor      string `json:"actor"`
	}
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	request.Title, request.Body = strings.TrimSpace(request.Title), strings.TrimSpace(request.Body)
	if request.Title == "" || request.Body == "" {
		writeCustomerError(w, http.StatusBadRequest, "invalid_notification", "a notification needs a title and words", nil)
		return
	}
	link, ok := customerNotificationLink(request.Link)
	if !ok {
		writeCustomerError(w, http.StatusBadRequest, "invalid_link", "a link must be a https://cards.dftr.ly/… address", nil)
		return
	}
	message := fcm.Message{Title: request.Title, Body: request.Body, Link: link, Campaign: strings.TrimSpace(request.Campaign)}
	record := control.CustomerNotification{
		Audience: request.Audience, Title: message.Title, Body: message.Body, Link: link,
		Campaign: message.Campaign, SentBy: adminActor(r, request.Actor),
	}
	ctx := r.Context()
	switch {
	case customerPushAudiences[request.Audience]:
		if err := s.CustomerPush.SendTopic(ctx, request.Audience, message); err != nil {
			record.Failed, record.Error = 1, err.Error()
		} else {
			record.Sent = 1
		}
	case request.Audience == "customer":
		customer, err := store.GetCustomer(ctx, request.CustomerID)
		if err != nil || customer.DeletedAt != nil {
			writeCustomerError(w, http.StatusNotFound, "customer_not_found", "no such customer", nil)
			return
		}
		record.CustomerID = customer.ID
		sessions, err := store.CustomerSessions(ctx, customer.ID)
		if err != nil {
			s.customerInternalError(w, "customer sessions failed", err)
			return
		}
		s.pushToDevices(ctx, store, sessions, message, &record)
		if record.Devices == 0 {
			writeCustomerError(w, http.StatusConflict, "no_devices",
				"this customer has no phone that accepts notifications", nil)
			return
		}
	default:
		writeCustomerError(w, http.StatusBadRequest, "invalid_audience",
			"audience is all, ios, play, apk or customer", nil)
		return
	}
	stored, err := store.RecordCustomerNotification(ctx, record)
	if err != nil {
		s.customerInternalError(w, "customer notification log failed", err)
		return
	}
	s.logger().Info("operator sent a notification", "audience", record.Audience,
		"customer_id", record.CustomerID, "sent", record.Sent, "failed", record.Failed, "actor", record.SentBy)
	status := http.StatusOK
	if record.Sent == 0 {
		status = http.StatusBadGateway
	}
	writeJSON(w, status, map[string]any{"notification": stored})
}

// pushToDevices sends to each device that registered a token, a few at a
// time, forgetting the tokens Firebase no longer knows.
func (s HTTPServer) pushToDevices(ctx context.Context, store customerAdminStore, sessions []control.CustomerSession, message fcm.Message, record *control.CustomerNotification) {
	var (
		mu    sync.Mutex
		wait  sync.WaitGroup
		errs  []string
		lanes = make(chan struct{}, 4)
	)
	for _, session := range sessions {
		if session.PushToken == "" {
			continue
		}
		record.Devices++
		wait.Add(1)
		lanes <- struct{}{}
		go func(token string) {
			defer wait.Done()
			defer func() { <-lanes }()
			err := s.CustomerPush.SendToken(ctx, token, message)
			if errors.Is(err, fcm.ErrUnregistered) {
				_ = store.ForgetCustomerPushToken(context.WithoutCancel(ctx), token)
			}
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				record.Failed++
				errs = append(errs, err.Error())
				return
			}
			record.Sent++
		}(session.PushToken)
	}
	wait.Wait()
	if len(errs) > 0 {
		record.Error = errs[0]
	}
}

// handleCustomerPushToken is the app telling the relay where this device
// takes notifications (PUT /v1/customers/me/push, {"token": ""} to stop).
func (s HTTPServer) handleCustomerPushToken(w http.ResponseWriter, r *http.Request, store control.CustomerStore, customer control.Customer, session control.CustomerSession) {
	admin, ok := store.(control.CustomerAdminStore)
	if !ok {
		writeCustomerError(w, http.StatusServiceUnavailable, "customers_unconfigured", "this relay keeps no customers", nil)
		return
	}
	var request struct {
		Token string `json:"token"`
	}
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	token := strings.TrimSpace(request.Token)
	if len(token) > 4096 || strings.ContainsAny(token, " \n\t") {
		writeCustomerError(w, http.StatusBadRequest, "invalid_token", "not a notification token", nil)
		return
	}
	if err := admin.SetCustomerPushToken(r.Context(), customer.ID, session.ID, token); err != nil {
		s.customerInternalError(w, "customer push token failed", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s HTTPServer) customerShelfStore(w http.ResponseWriter) (control.CustomerShelfStore, bool) {
	store, ok := s.Store.(control.CustomerShelfStore)
	if !ok {
		writeCustomerError(w, http.StatusServiceUnavailable, "customers_unconfigured", "this relay keeps no customers", nil)
	}
	return store, ok
}

func (s HTTPServer) handleCustomerAdminShelf(w http.ResponseWriter, r *http.Request) {
	store, ok := s.customerShelfStore(w)
	if !ok {
		return
	}
	settings, err := store.CustomerShelfSettings(r.Context())
	if err != nil {
		s.customerInternalError(w, "customer shelf read failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"shelf": settings})
}

// handleCustomerAdminSetShelf changes what the iPhone app does with the cards
// Apple reserves for in-app purchase. Every shelf read after it sees the new
// choice: the catalog's version names it, so the app's cached shelf is stale.
func (s HTTPServer) handleCustomerAdminSetShelf(w http.ResponseWriter, r *http.Request) {
	store, ok := s.customerShelfStore(w)
	if !ok {
		return
	}
	var request struct {
		IOSGiftCards string `json:"ios_gift_cards"`
		Actor        string `json:"actor"`
	}
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	settings, err := store.SetCustomerShelfSettings(r.Context(), control.CustomerShelfSettings{
		IOSGiftCards: request.IOSGiftCards, Actor: adminActor(r, request.Actor),
	})
	if errors.Is(err, control.ErrInvalidCustomerShelf) {
		writeCustomerError(w, http.StatusBadRequest, "invalid_shelf",
			"ios_gift_cards must be hidden, web_only or sell", nil)
		return
	}
	if err != nil {
		s.customerInternalError(w, "customer shelf write failed", err)
		return
	}
	s.logger().Warn("operator changed the iPhone shelf's gift cards",
		"ios_gift_cards", settings.IOSGiftCards, "actor", settings.Actor)
	writeJSON(w, http.StatusOK, map[string]any{"shelf": settings})
}
