// Package airalofake is an in-memory Airalo Partner API, for tests and for
// running the relay and the app end to end without Airalo. Its shapes follow
// the Partner API docs. Airalo's own sandbox test packages behave as documented.
package airalofake

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Server is the fake's state; Handler serves it.
type Server struct {
	mu sync.Mutex

	// TokenRequests, OrderRequests count the calls that matter to the go-live
	// checklist: one token shared, and never a second order for one purchase.
	TokenRequests int
	OrderRequests int
	TopUpRequests int
	// RejectToken makes the next API call answer 401, as an expired token does.
	RejectToken bool
	// FailOrdersWith500 takes the order and then answers 500: the answer is lost.
	FailOrdersWith500 bool
	// NextDuplicate answers the next order with code 83.
	NextDuplicate bool
	// OptIns holds the webhook URLs by notification type.
	OptIns map[string]string

	token  int
	orders []*order
	sims   map[string]*order
}

type order struct {
	ID          int
	Description string
	PackageID   string
	Type        string
	ICCID       string
	Created     time.Time
}

// New builds an empty fake.
func New() *Server {
	return &Server{OptIns: map[string]string{}, sims: map[string]*order{}}
}

// Orders is how many orders of eSIMs and top-ups the fake holds.
func (s *Server) Orders() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.orders)
}

// Set changes the fake's state under its lock.
func (s *Server) Set(change func(*Server)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	change(s)
}

func plan(id, title, data string, mb, days int, net, retail float64) map[string]any {
	return map[string]any{
		"id": id, "type": "sim", "title": title, "data": data, "amount": mb, "day": days,
		"is_unlimited": false, "short_info": "لا تتضمن هذه الشريحة رقم هاتف.", "net_price": net, "price": retail,
		"prices": map[string]any{
			"net_price":                map[string]any{"USD": net},
			"recommended_retail_price": map[string]any{"USD": retail},
		},
	}
}

func operator(title, kind string, packages []map[string]any, coverage ...map[string]any) map[string]any {
	return map[string]any{
		"id": 1, "title": title, "type": kind, "plan_type": "data", "esim_type": "Prepaid", "is_prepaid": true,
		"rechargeability": true, "activation_policy": "first-usage", "is_kyc_verify": false, "is_roaming": true,
		"apn_type": "automatic", "install_window_days": 90, "topup_grace_window_days": 30,
		"info": []string{"بيانات فقط"}, "packages": packages, "coverages": coverage,
	}
}

func coverage(code, name string, networks ...string) map[string]any {
	list := []map[string]any{}
	for _, network := range networks {
		list = append(list, map[string]any{"name": network, "types": []string{"5G", "LTE"}})
	}
	return map[string]any{"code": code, "name": name, "networks": list}
}

func catalog() []map[string]any {
	const image = "https://cdn-revamp.airalo.com/images/fake.png"
	return []map[string]any{
		{"slug": "turkey", "country_code": "TR", "title": "تركيا", "image": map[string]any{"url": image},
			"operators": []map[string]any{operator("Merhaba", "local", []map[string]any{
				plan("merhaba-7days-1gb", "1 GB - 7 أيام", "1 GB", 1024, 7, 2.5, 4.5),
				plan("merhaba-30days-3gb", "3 GB - 30 يوماً", "3 GB", 3072, 30, 5.5, 11),
				plan("merhaba-30days-10gb", "10 GB - 30 يوماً", "10 GB", 10240, 30, 14, 26),
				plan("test-out-of-stock-7days-1gb", "اختبار نفاد", "1 GB", 1024, 7, 2, 4),
				plan("test-insufficient-balance-7days-1gb", "اختبار رصيد", "1 GB", 1024, 7, 2, 4),
			}, coverage("TR", "تركيا", "Turkcell", "Vodafone"))}},
		{"slug": "egypt", "country_code": "EG", "title": "مصر", "image": map[string]any{"url": image},
			"operators": []map[string]any{operator("Nile", "local", []map[string]any{
				plan("nile-7days-1gb", "1 GB - 7 أيام", "1 GB", 1024, 7, 3, 6),
				plan("nile-30days-5gb", "5 GB - 30 يوماً", "5 GB", 5120, 30, 10, 19),
			}, coverage("EG", "مصر", "Orange", "Etisalat"))}},
		{"slug": "europe", "country_code": "", "title": "أوروبا", "image": map[string]any{"url": image},
			"operators": []map[string]any{operator("Eurolink", "global", []map[string]any{
				plan("eurolink-7days-1gb", "1 GB - 7 أيام", "1 GB", 1024, 7, 3, 5),
				plan("eurolink-30days-10gb", "10 GB - 30 يوماً", "10 GB", 10240, 30, 16, 30),
			}, coverage("FR", "فرنسا", "Orange"), coverage("IT", "إيطاليا", "TIM"), coverage("DE", "ألمانيا", "Telekom"))}},
		{"slug": "world", "country_code": "", "title": "العالم", "image": map[string]any{"url": image},
			"operators": []map[string]any{operator("Discover", "global", []map[string]any{
				plan("discover-7days-1gb", "1 GB - 7 أيام", "1 GB", 1024, 7, 6, 9),
			}, coverage("US", "الولايات المتحدة", "T-Mobile"), coverage("FR", "فرنسا", "Orange"))}},
	}
}

// Handler serves the Partner API.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v2/token", func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		s.TokenRequests++
		s.token++
		answer(w, 200, map[string]any{"data": map[string]any{
			"access_token": fmt.Sprintf("token-%d", s.token), "expires_in": 86400, "token_type": "Bearer",
		}})
	})
	authed := func(next func(http.ResponseWriter, *http.Request)) func(http.ResponseWriter, *http.Request) {
		return func(w http.ResponseWriter, r *http.Request) {
			s.mu.Lock()
			current := fmt.Sprintf("Bearer token-%d", s.token)
			reject := s.RejectToken
			s.RejectToken = false
			s.mu.Unlock()
			if reject || r.Header.Get("Authorization") != current {
				answer(w, 401, map[string]any{"code": 401, "reason": "Authentication failed"})
				return
			}
			next(w, r)
		}
	}
	mux.HandleFunc("GET /v2/packages", authed(func(w http.ResponseWriter, _ *http.Request) {
		answer(w, 200, map[string]any{"pricing": map[string]any{"model": "net_pricing", "discount_percentage": 0}, "data": catalog(),
			"meta": map[string]any{"current_page": 1, "last_page": 1}})
	}))
	mux.HandleFunc("POST /v2/orders", authed(s.submitOrder))
	mux.HandleFunc("POST /v2/orders/topups", authed(s.submitTopUp))
	mux.HandleFunc("GET /v2/orders", authed(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		want := r.URL.Query().Get("filter[description]")
		list := []map[string]any{}
		for _, order := range s.orders {
			if strings.Contains(order.Description, want) {
				list = append(list, orderJSON(order))
			}
		}
		answer(w, 200, map[string]any{"data": list})
	}))
	mux.HandleFunc("GET /v2/orders/{id}", authed(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		for _, order := range s.orders {
			if strconv.Itoa(order.ID) == r.PathValue("id") {
				answer(w, 200, map[string]any{"data": orderJSON(order)})
				return
			}
		}
		answer(w, 404, map[string]any{"code": 404, "reason": "Not found"})
	}))
	mux.HandleFunc("GET /v2/sims/{iccid}", authed(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		order, ok := s.sims[r.PathValue("iccid")]
		if !ok {
			answer(w, 404, map[string]any{"code": 404, "reason": "Not found"})
			return
		}
		sim := simJSON(order.ICCID)
		sim["sharing"] = map[string]any{"link": "https://esims.cloud/fake/" + order.ICCID, "access_code": "1234"}
		answer(w, 200, map[string]any{"data": sim})
	}))
	mux.HandleFunc("GET /v2/sims/{iccid}/usage", authed(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		if _, ok := s.sims[r.PathValue("iccid")]; !ok {
			answer(w, 422, map[string]any{"code": 43, "reason": "Bad request. Invalid ICCID."})
			return
		}
		answer(w, 200, map[string]any{"data": map[string]any{
			"remaining": 512, "total": 1024, "expired_at": time.Now().Add(72 * time.Hour).UTC().Format("2006-01-02 15:04:05"),
			"is_unlimited": false, "status": "ACTIVE", "remaining_voice": 0, "remaining_text": 0, "total_voice": 0, "total_text": 0,
		}, "meta": map[string]any{"message": "success"}})
	}))
	mux.HandleFunc("GET /v2/sims/{iccid}/topups", authed(func(w http.ResponseWriter, _ *http.Request) {
		answer(w, 200, map[string]any{"data": []map[string]any{
			{"id": "merhaba-7days-1gb-topup", "type": "topup", "title": "1 GB - 7 أيام", "data": "1 GB", "amount": 1024, "day": 7, "price": 4.5, "net_price": 2.5},
			{"id": "merhaba-30days-3gb-topup", "type": "topup", "title": "3 GB - 30 يوماً", "data": "3 GB", "amount": 3072, "day": 30, "price": 11, "net_price": 5.5},
		}})
	}))
	mux.HandleFunc("POST /v2/compatible-devices/check", authed(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Model string `json:"model"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		switch {
		// Like the real list: the newer iPhone identifiers are missing from it.
		case strings.HasPrefix(body.Model, "iPhone17,"):
			answer(w, 200, map[string]any{"data": map[string]any{"supported": false, "reason": "not_in_compatible_list", "device": nil}})
		case strings.HasPrefix(body.Model, "iPhone") || strings.HasPrefix(body.Model, "SM-S"):
			answer(w, 200, map[string]any{"data": map[string]any{"supported": true, "reason": nil,
				"device": map[string]any{"os": "ios", "brand": "Apple", "name": "iPhone"}}})
		default:
			answer(w, 200, map[string]any{"data": map[string]any{"supported": false, "reason": "not_in_compatible_list", "device": nil}})
		}
	}))
	mux.HandleFunc("GET /v2/notifications/opt-in", authed(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		kind := r.URL.Query().Get("type")
		if url, ok := s.OptIns[kind]; ok {
			answer(w, 200, map[string]any{"data": map[string]any{"notification": map[string]any{"type": kind, "contact_point": url}}})
			return
		}
		answer(w, 404, map[string]any{"code": 404, "reason": "Not found"})
	}))
	mux.HandleFunc("POST /v2/notifications/opt-in", authed(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Type       string `json:"type"`
			WebhookURL string `json:"webhook_url"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		// Airalo checks the URL with a HEAD first.
		if head, err := http.Head(body.WebhookURL); err != nil || head.StatusCode != 200 {
			answer(w, 422, map[string]any{"code": 43, "reason": "Bad request. The webhook URL did not answer HEAD."})
			return
		}
		s.mu.Lock()
		s.OptIns[body.Type] = body.WebhookURL
		s.mu.Unlock()
		answer(w, 200, map[string]any{"data": map[string]any{"contact_point": body.WebhookURL}})
	}))
	mux.HandleFunc("GET /v2/balance", authed(func(w http.ResponseWriter, _ *http.Request) {
		answer(w, 200, map[string]any{"data": map[string]any{"balances": map[string]any{
			"name": "balance", "availableBalance": map[string]any{"amount": 1000, "currency": "USD"},
		}}})
	}))
	return mux
}

func (s *Server) submitOrder(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseMultipartForm(1 << 16); err != nil {
		answer(w, 400, map[string]any{"code": 43, "reason": "Bad request."})
		return
	}
	packageID := r.FormValue("package_id")
	s.mu.Lock()
	defer s.mu.Unlock()
	s.OrderRequests++
	if s.NextDuplicate {
		s.NextDuplicate = false
		answer(w, 422, map[string]any{"code": 83, "reason": "Request throttled. You have already placed an identical order"})
		return
	}
	switch packageID {
	case "test-insufficient-balance-7days-1gb":
		answer(w, 422, map[string]any{"code": 11, "reason": "Insufficient Airalo Credit"})
		return
	case "test-maintenance-mode-7days-1gb":
		answer(w, 422, map[string]any{"code": 13, "reason": "The requested operator is currently undergoing maintenance."})
		return
	case "test-out-of-stock-7days-1gb":
		answer(w, 422, map[string]any{"code": 34, "reason": "The requested eSIM package is invalid or it is currently out of stock."})
		return
	case "test-not-enough-7days-1gb":
		answer(w, 422, map[string]any{"code": 33, "reason": "Insufficient stock of eSIMs remaining"})
		return
	}
	created := &order{
		ID: len(s.orders) + 1, Description: r.FormValue("description"), PackageID: packageID, Type: "sim",
		ICCID: fmt.Sprintf("89000000000000%05d", len(s.orders)+1), Created: time.Now().UTC(),
	}
	s.orders = append(s.orders, created)
	s.sims[created.ICCID] = created
	if s.FailOrdersWith500 {
		s.FailOrdersWith500 = false
		answer(w, 500, map[string]any{"reason": "Internal Server Error"})
		return
	}
	answer(w, 200, map[string]any{"data": orderJSON(created), "meta": map[string]any{"message": "success"}})
}

func (s *Server) submitTopUp(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseMultipartForm(1 << 16); err != nil {
		answer(w, 400, map[string]any{"code": 43, "reason": "Bad request."})
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.TopUpRequests++
	iccid := r.FormValue("iccid")
	if _, ok := s.sims[iccid]; !ok {
		answer(w, 422, map[string]any{"code": 73, "reason": "The eSIM with iccid " + iccid + " has been recycled."})
		return
	}
	created := &order{ID: len(s.orders) + 1, Description: r.FormValue("description"), PackageID: r.FormValue("package_id"), Type: "topup", Created: time.Now().UTC()}
	s.orders = append(s.orders, created)
	answer(w, 200, map[string]any{"data": orderJSON(created)})
}

func simJSON(iccid string) map[string]any {
	lpa := "LPA:1$lpa.fake.airalo.com$" + iccid
	return map[string]any{
		"id": 1, "iccid": iccid, "lpa": "lpa.fake.airalo.com", "matching_id": iccid, "qrcode": lpa,
		"qrcode_url":                      "https://sandbox.airalo.com/qr?id=" + iccid,
		"direct_apple_installation_url":   "https://esimsetup.apple.com/esim_qrcode_provisioning?carddata=" + lpa,
		"direct_android_installation_url": "https://esimsetup.android.com/esim_qrcode_provisioning?carddata=" + lpa,
		"apn_type":                        "automatic", "apn_value": nil, "is_roaming": true, "confirmation_code": nil,
		"apn": map[string]any{
			"ios":     map[string]any{"apn_type": "automatic", "apn_value": nil},
			"android": map[string]any{"apn_type": "manual", "apn_value": "fake.apn"},
		},
	}
}

func orderJSON(o *order) map[string]any {
	body := map[string]any{
		"id": o.ID, "code": fmt.Sprintf("20261105-%06d", o.ID), "package_id": o.PackageID, "type": o.Type,
		"description": o.Description, "quantity": 1, "currency": "USD", "price": 4.5, "net_price": 2.5,
		"created_at": o.Created.Format("2006-01-02 15:04:05"), "status": map[string]any{"slug": "completed"},
		"sims": []map[string]any{},
	}
	if o.ICCID != "" {
		body["sims"] = []map[string]any{simJSON(o.ICCID)}
	}
	return body
}

func answer(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
