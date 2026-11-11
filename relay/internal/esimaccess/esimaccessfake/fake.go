// Package esimaccessfake is an eSIM Access Partner API that runs in memory, for
// tests and local runs: a small catalog, orders that issue eSIMs, top-ups,
// usage and the webhook setting. It keeps the real API's shapes and quirks that
// the relay depends on: an eSIM made after its order answers, a repeated
// transactionId that is the same order, prices checked against the order.
package esimaccessfake

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

const gigabyte = int64(1) << 30

// Server is the fake. Set its knobs with Set.
type Server struct {
	mu sync.Mutex

	// AccessCode is the key calls must carry.
	AccessCode string
	// Balance is the account's balance in ten-thousandths of a dollar.
	Balance int64
	// AllocatingReads is how many reads of a new order answer "still
	// allocating" before its eSIM shows.
	AllocatingReads int
	// LoseOrderAnswer drops the answer of the next order after placing it.
	LoseOrderAnswer bool
	// FailOrderCode fails the next order with this error code, placing nothing.
	FailOrderCode string
	// Webhook is the address events are posted to.
	Webhook string
	// Now stands in for the clock (tests with a clock of their own).
	Now func() time.Time

	// Orders counts orders placed (a repeated transactionId counts once);
	// TopUps counts top-ups loaded.
	Orders int
	TopUps int

	packages []map[string]any
	topups   []map[string]any
	profiles []*profile
	next     int
}

type profile struct {
	tranNo, orderNo, transactionID, iccid, code string
	created                                     time.Time
	total, used                                 int64
	days                                        int
	status, smdp                                string
	expires                                     time.Time
	pendingReads                                int
	loaded                                      []map[string]any
}

// New builds a fake with a small catalog.
func New() *Server {
	s := &Server{AccessCode: "access", Balance: 500 * 10000, Now: time.Now}
	local := func(code, slug, name, country string, gb float64, days int, price int64, operator string) map[string]any {
		return map[string]any{
			"packageCode": code, "slug": slug, "name": name, "price": price, "currencyCode": "USD",
			"volume": int64(gb * float64(gigabyte)), "smsStatus": 0, "dataType": 1, "unusedValidTime": 180,
			"duration": days, "durationUnit": "DAY", "location": country, "description": name, "activeType": 2,
			"retailPrice": price * 157 / 100, "speed": "4G/5G", "ipExport": "NL", "supportTopUpType": 2, "fupPolicy": "",
			"locationNetworkList": []any{map[string]any{
				"locationName": name[:strings.Index(name, " ")], "locationLogo": "/img/flags/" + strings.ToLower(country) + ".png",
				"locationCode": country, "operatorList": []any{map[string]any{"operatorName": operator, "networkType": "5G"}},
			}},
		}
	}
	s.packages = []map[string]any{
		local("PTR1G7", "TR_1_7", "Turkey 1GB 7Days", "TR", 1, 7, 4600, "Vodafone"),
		local("PTR1G7P", "TR_1_7_P", "Turkey 1GB 7Days Premium", "TR", 1, 7, 5600, "Turkcell"),
		local("PTR3G30", "TR_3_30", "Turkey 3GB 30Days", "TR", 3, 30, 14200, "Vodafone"),
		local("PTR5G30", "TR_5_30", "Turkey 5GB 30Days", "TR", 5, 30, 23000, "Vodafone"),
		local("PTN1G7", "TN_1_7", "Tunisia 1GB 7Days", "TN", 1, 7, 9500, "OOREDOO TN"),
		local("PAE1G7", "AE_1_7", "United Arab Emirates 1GB 7Days", "AE", 1, 7, 17500, "Du"),
		local("PEG20G30", "EG_20_30", "Egypt 20GB 30Days", "EG", 20, 30, 210000, "Orange"),
	}
	// A day pass, which the shelf does not sell.
	daily := local("PTRDAY", "TR_1_Daily", "Turkey 1GB/Day", "TR", 1, 1, 5400, "Vodafone")
	daily["dataType"] = 2
	s.packages = append(s.packages, daily)
	// A regional plan: several countries, a code of its own.
	europe := local("PEU1G7", "EU-33_1_7", "Europe (33 areas) 1GB 7Days", "IT,FR,DE", 1, 7, 6400, "TIM")
	europe["locationNetworkList"] = []any{
		map[string]any{"locationName": "Italy", "locationCode": "IT", "locationLogo": "/img/flags/it.png",
			"operatorList": []any{map[string]any{"operatorName": "TIM", "networkType": "5G"}}},
		map[string]any{"locationName": "France", "locationCode": "FR", "locationLogo": "/img/flags/fr.png",
			"operatorList": []any{map[string]any{"operatorName": "Orange", "networkType": "5G"}}},
		map[string]any{"locationName": "Germany", "locationCode": "DE", "locationLogo": "/img/flags/de.png",
			"operatorList": []any{map[string]any{"operatorName": "O2", "networkType": "5G"}}},
	}
	s.packages = append(s.packages, europe)
	s.topups = []map[string]any{
		local("TOPUP_PTR1G7", "TR_1_7", "Turkey 1GB 7Days", "TR", 1, 7, 4600, "Vodafone"),
		local("TOPUP_PTR3G30", "TR_3_30", "Turkey 3GB 30Days", "TR", 3, 30, 14200, "Vodafone"),
	}
	return s
}

// Set changes the fake's knobs under its lock.
func (s *Server) Set(change func(*Server)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	change(s)
}

// Use sets what an eSIM has used, and its status.
func (s *Server) Use(iccid string, usedBytes int64, status string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, p := range s.profiles {
		if p.iccid == iccid {
			p.used = usedBytes
			if status != "" {
				p.status = status
			}
			if p.smdp == "RELEASED" {
				p.smdp = "ENABLED"
			}
		}
	}
}

// Allocate finishes making every eSIM still being made.
func (s *Server) Allocate() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, p := range s.profiles {
		p.pendingReads = 0
	}
}

// Expire sets when an eSIM's plan ends.
func (s *Server) Expire(iccid string, at time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, p := range s.profiles {
		if p.iccid == iccid {
			p.expires = at
		}
	}
}

// TranNo is the transaction number of the eSIM with this ICCID.
func (s *Server) TranNo(iccid string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, p := range s.profiles {
		if p.iccid == iccid {
			return p.tranNo
		}
	}
	return ""
}

// Handler serves the API.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	route := func(path string, handle func(body map[string]any) (any, string)) {
		mux.HandleFunc("/api/v1/open/"+path, func(w http.ResponseWriter, r *http.Request) {
			raw, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
			body := map[string]any{}
			_ = json.Unmarshal(raw, &body)
			s.mu.Lock()
			if r.Method != http.MethodPost || r.Header.Get("RT-AccessCode") != s.AccessCode {
				s.mu.Unlock()
				fail(w, "101003")
				return
			}
			obj, code := handle(body)
			lost := path == "esim/order" && code == "" && s.LoseOrderAnswer
			if lost {
				s.LoseOrderAnswer = false
			}
			s.mu.Unlock()
			if lost {
				hijack(w)
				return
			}
			if code != "" {
				fail(w, code)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{"success": true, "errorCode": "0", "errorMsg": nil, "obj": obj})
		})
	}
	route("package/list", s.listPackages)
	route("esim/order", s.order)
	route("esim/query", s.query)
	route("esim/topup", s.topUp)
	route("esim/cancel", s.cancel)
	route("balance/query", func(map[string]any) (any, string) { return map[string]any{"balance": s.Balance}, "" })
	route("webhook/query", func(map[string]any) (any, string) { return map[string]any{"webhook": s.Webhook}, "" })
	route("webhook/save", func(body map[string]any) (any, string) {
		s.Webhook, _ = body["webhook"].(string)
		return map[string]any{}, ""
	})
	return mux
}

func fail(w http.ResponseWriter, code string) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"success": false, "errorCode": code, "errorMsg": "refused (" + code + ")", "obj": nil})
}

// hijack closes the connection without an answer.
func hijack(w http.ResponseWriter) {
	if hijacker, ok := w.(http.Hijacker); ok {
		if conn, _, err := hijacker.Hijack(); err == nil {
			_ = conn.Close()
			return
		}
	}
	w.WriteHeader(http.StatusBadGateway)
}

func text(body map[string]any, key string) string {
	value, _ := body[key].(string)
	return strings.TrimSpace(value)
}

func number(value any) int64 {
	switch typed := value.(type) {
	case float64:
		return int64(typed)
	case int64:
		return typed
	case int:
		return int64(typed)
	}
	return 0
}

func (s *Server) listPackages(body map[string]any) (any, string) {
	if text(body, "type") == "TOPUP" {
		iccid, tranNo := text(body, "iccid"), text(body, "esimTranNo")
		for _, p := range s.profiles {
			if (tranNo != "" && p.tranNo == tranNo) || (tranNo == "" && p.iccid == iccid) {
				return map[string]any{"packageList": s.topups}, ""
			}
		}
		return map[string]any{"packageList": []any{}}, ""
	}
	return map[string]any{"packageList": s.packages}, ""
}

func (s *Server) find(list []map[string]any, code string) map[string]any {
	for _, pkg := range list {
		if pkg["packageCode"] == code || pkg["slug"] == code {
			return pkg
		}
	}
	return nil
}

func (s *Server) order(body map[string]any) (any, string) {
	transactionID := text(body, "transactionId")
	items, _ := body["packageInfoList"].([]any)
	if transactionID == "" || len(items) != 1 {
		return nil, "000105"
	}
	for _, p := range s.profiles {
		if p.transactionID == transactionID {
			return map[string]any{"orderNo": p.orderNo, "transactionId": transactionID}, ""
		}
	}
	if s.FailOrderCode != "" {
		code := s.FailOrderCode
		s.FailOrderCode = ""
		return nil, code
	}
	item, _ := items[0].(map[string]any)
	pkg := s.find(s.packages, text(item, "packageCode"))
	if pkg == nil {
		return nil, "310241"
	}
	price := number(pkg["price"])
	if asked := number(item["price"]); asked > 0 && asked != price {
		return nil, "200005"
	}
	if s.Balance < price {
		return nil, "200007"
	}
	s.Balance -= price
	s.Orders++
	s.next++
	now := s.Now().UTC()
	created := &profile{
		tranNo:  fmt.Sprintf("2611%010d", s.next),
		orderNo: fmt.Sprintf("B2611%010d", s.next), transactionID: transactionID,
		iccid: fmt.Sprintf("894310817%010d", s.next), code: pkg["packageCode"].(string), created: now,
		total: number(pkg["volume"]), days: int(number(pkg["duration"])),
		status: "GOT_RESOURCE", smdp: "RELEASED", expires: now.AddDate(0, 0, 180),
		pendingReads: s.AllocatingReads,
		loaded: []map[string]any{{
			"packageName": pkg["name"], "packageCode": pkg["packageCode"], "slug": pkg["slug"],
			"duration": pkg["duration"], "volume": pkg["volume"], "locationCode": pkg["location"],
			"createTime": now.Format("2006-01-02T15:04:05-0700"),
		}},
	}
	s.profiles = append(s.profiles, created)
	return map[string]any{"orderNo": created.orderNo, "transactionId": transactionID}, ""
}

func (p *profile) payload() map[string]any {
	return map[string]any{
		"esimTranNo": p.tranNo, "orderNo": p.orderNo, "transactionId": p.transactionID, "iccid": p.iccid,
		"ac":        "LPA:1$rsp.fake.test$" + strings.ToUpper(p.tranNo),
		"qrCodeUrl": "https://p.fake.test/" + p.tranNo + ".png", "shortUrl": "https://p.fake.test/" + p.tranNo,
		"smdpStatus": p.smdp, "eid": "", "activeType": 2, "dataType": 1,
		"expiredTime": p.expires.Format("2006-01-02T15:04:05-0700"),
		"totalVolume": p.total, "totalDuration": p.days, "durationUnit": "DAY", "orderUsage": p.used,
		"esimStatus": p.status, "apn": "fake.apn", "supportTopUpType": 2, "packageList": p.loaded,
	}
}

func (s *Server) query(body map[string]any) (any, string) {
	orderNo, tranNo, iccid := text(body, "orderNo"), text(body, "esimTranNo"), text(body, "iccid")
	var from, to time.Time
	if raw := text(body, "startTime"); raw != "" {
		from, _ = time.Parse("2006-01-02T15:04-07:00", raw)
	}
	if raw := text(body, "endTime"); raw != "" {
		to, _ = time.Parse("2006-01-02T15:04-07:00", raw)
	}
	list := []any{}
	for _, p := range s.profiles {
		switch {
		case orderNo != "" && p.orderNo != orderNo, tranNo != "" && p.tranNo != tranNo, iccid != "" && p.iccid != iccid:
			continue
		case !from.IsZero() && p.created.Before(from), !to.IsZero() && p.created.After(to.Add(time.Minute)):
			continue
		}
		if p.pendingReads > 0 {
			if orderNo != "" {
				p.pendingReads--
				return nil, "200010"
			}
			continue
		}
		list = append(list, p.payload())
	}
	if orderNo != "" && len(list) == 0 {
		return nil, "310272"
	}
	return map[string]any{"esimList": list, "pager": map[string]any{"pageNum": 1, "pageSize": 500, "total": len(list)}}, ""
}

func (s *Server) topUp(body map[string]any) (any, string) {
	tranNo, iccid := text(body, "esimTranNo"), text(body, "iccid")
	pkg := s.find(s.topups, text(body, "packageCode"))
	if pkg == nil {
		return nil, "310241"
	}
	for _, p := range s.profiles {
		if (tranNo != "" && p.tranNo != tranNo) || (tranNo == "" && p.iccid != iccid) {
			continue
		}
		price := number(pkg["price"])
		if asked := number(body["amount"]); asked > 0 && asked != price {
			return nil, "200005"
		}
		if s.Balance < price {
			return nil, "200007"
		}
		s.Balance -= price
		s.TopUps++
		now := s.Now().UTC()
		p.total += number(pkg["volume"])
		p.days += int(number(pkg["duration"]))
		p.expires = p.expires.AddDate(0, 0, int(number(pkg["duration"])))
		if p.status == "USED_UP" {
			p.status = "IN_USE"
		}
		p.loaded = append(p.loaded, map[string]any{
			"packageName": pkg["name"], "packageCode": pkg["packageCode"], "slug": pkg["slug"],
			"duration": pkg["duration"], "volume": pkg["volume"], "locationCode": pkg["location"],
			"createTime": now.Format("2006-01-02T15:04:05-0700"),
		})
		return map[string]any{
			"transactionId": text(body, "transactionId"), "iccid": p.iccid,
			"expiredTime": p.expires.Format("2006-01-02T15:04:05-0700"),
			"totalVolume": p.total, "totalDuration": p.days, "orderUsage": p.used,
		}, ""
	}
	return nil, "310403"
}

func (s *Server) cancel(body map[string]any) (any, string) {
	for _, p := range s.profiles {
		if p.tranNo == text(body, "esimTranNo") && p.smdp == "RELEASED" {
			p.status = "CANCEL"
			return map[string]any{}, ""
		}
	}
	return nil, "200002"
}
