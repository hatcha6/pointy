package agentmcp

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"pointy/relay/internal/control"
)

// Every tool forwards GET requests to the relay's own admin handlers — the
// same ones the console and CLI read — so there is one way to compute each
// figure. sales_breakdown only adds up what the purchases listing returns.

type param struct {
	name        string
	kind        string // string, integer or boolean
	description string
	enum        []string
}

type tool struct {
	title       string
	description string
	params      []param
	run         func(c *call) (any, error)
}

func (t tool) schema() map[string]any {
	properties := map[string]any{}
	for _, p := range t.params {
		property := map[string]any{"type": p.kind, "description": p.description}
		if len(p.enum) > 0 {
			property["enum"] = p.enum
		}
		properties[p.name] = property
	}
	return map[string]any{"type": "object", "properties": properties, "additionalProperties": false}
}

// call is one tool call: its arguments and a way to read admin routes.
type call struct {
	s     *Server
	r     *http.Request
	grant control.MCPGrant
	args  map[string]any
}

// errTool is a tool error the model should see (bad argument, a handler's
// refusal); other errors are reported generically.
type errTool struct{ message string }

func (e errTool) Error() string { return e.message }

func (c *call) str(name string) string {
	value, _ := c.args[name].(string)
	return strings.TrimSpace(value)
}

func (c *call) integer(name string, fallback, maxValue int) int {
	switch value := c.args[name].(type) {
	case float64:
		if value >= 1 {
			return min(int(value), maxValue)
		}
	case string:
		if n, err := strconv.Atoi(value); err == nil && n >= 1 {
			return min(n, maxValue)
		}
	}
	return fallback
}

func (c *call) boolean(name string) bool {
	value, _ := c.args[name].(bool)
	return value
}

// get reads one admin route in process and returns its redacted JSON.
func (c *call) get(route string, query url.Values) (any, error) {
	inner := c.r.Clone(c.r.Context())
	inner.Method = http.MethodGet
	inner.URL = &url.URL{Path: route, RawQuery: query.Encode()}
	inner.RequestURI = ""
	inner.Body = http.NoBody
	inner.ContentLength = 0
	inner.Header = http.Header{}
	inner.Header.Set("Accept", "application/json")
	inner.Header.Set("Authorization", "Bearer "+c.s.cfg.AdminToken)
	inner.Header.Set("X-Pointy-Admin-Actor", "claude:"+c.grant.Name)
	rec := httptest.NewRecorder()
	c.s.cfg.Admin.ServeHTTP(rec, inner)
	var body any
	decoder := json.NewDecoder(bytes.NewReader(rec.Body.Bytes()))
	decoder.UseNumber()
	if err := decoder.Decode(&body); err != nil {
		return nil, errTool{fmt.Sprintf("%s answered %d without JSON", route, rec.Code)}
	}
	body = redact(body)
	if rec.Code >= 400 {
		encoded, _ := json.Marshal(body)
		return nil, errTool{fmt.Sprintf("%s answered %d: %s", route, rec.Code, truncate(string(encoded), 500))}
	}
	return body, nil
}

// several reads routes that may each fail on their own (a supplier that is
// not configured): each answer, or its error, under its name.
func (c *call) several(routes map[string]string) map[string]any {
	out := map[string]any{}
	for name, route := range routes {
		path, rawQuery, _ := strings.Cut(route, "?")
		query, _ := url.ParseQuery(rawQuery)
		body, err := c.get(path, query)
		if err != nil {
			out[name] = map[string]any{"unavailable": err.Error()}
			continue
		}
		out[name] = body
	}
	return out
}

// drop removes fields by name anywhere in an answer: what one tool must not
// show though the shared redaction lets it through (an order's player account).
func drop(value any, names ...string) any {
	switch v := value.(type) {
	case map[string]any:
		for _, name := range names {
			delete(v, name)
		}
		for key, item := range v {
			v[key] = drop(item, names...)
		}
	case []any:
		for i, item := range v {
			v[i] = drop(item, names...)
		}
	}
	return value
}

func queryOf(pairs ...string) url.Values {
	values := url.Values{}
	for i := 0; i+1 < len(pairs); i += 2 {
		if pairs[i+1] != "" {
			values.Set(pairs[i], pairs[i+1])
		}
	}
	return values
}

func catalog() (map[string]tool, []string) {
	dateParam := func(name, what string) param {
		return param{name: name, kind: "string", description: what + " day, YYYY-MM-DD (Libya time)."}
	}
	tools := []struct {
		name string
		tool
	}{
		{"finance_summary", tool{
			title:       "Finance summary",
			description: "Income, expenses, profit and margin per service for a period, the same-length period before it for comparison, monthly series, wallet top-ups by method and the dollar rate the books use. Defaults to the handler's default period (this month).",
			params:      []param{dateParam("from", "First"), dateParam("to", "Last")},
			run: func(c *call) (any, error) {
				return c.get("/v1/finance/summary", queryOf("from", c.str("from"), "to", c.str("to")))
			},
		}},
		{"finance_position", tool{
			title:       "Finance position",
			description: "Where the company's money is now: cash and bank, supplier balances held, shop wallet liabilities, owed and receivable totals.",
			run:         func(c *call) (any, error) { return c.get("/v1/finance/position", nil) },
		}},
		{"voucher_purchases", tool{
			title:       "Voucher purchases",
			description: "Latest card, airtime and bill purchases (newest first) with shop, item, supplier, amount, cost in dinars, profit, status, error and held state. Use held=true for purchases stuck with a supplier, status=failed for failures.",
			params: []param{
				{name: "status", kind: "string", description: "Only this status.", enum: []string{"pending", "succeeded", "failed"}},
				{name: "kind", kind: "string", description: "Only this kind.", enum: []string{"card", "airtime", "bill"}},
				{name: "buyer", kind: "string", description: "Who bought.", enum: []string{"shops", "customers", "company"}},
				{name: "held", kind: "boolean", description: "Only purchases held (awaiting the supplier or the operator)."},
				{name: "installation_id", kind: "string", description: "Only this shop."},
				{name: "limit", kind: "integer", description: "How many, 1-500 (default 100)."},
			},
			run: func(c *call) (any, error) {
				query := queryOf("status", c.str("status"), "kind", c.str("kind"), "buyer", c.str("buyer"),
					"installation_id", c.str("installation_id"), "limit", strconv.Itoa(c.integer("limit", 100, 500)))
				if c.boolean("held") {
					query.Set("held", "1")
				}
				return c.get("/v1/vouchers/admin/purchases", query)
			},
		}},
		{"sales_breakdown", tool{
			title:       "Sales breakdown",
			description: "Succeeded purchases added up by shop, item, supplier or day: count, quantity, sales, cost and profit in dinars. Reads at most the latest 500 purchases; 'covers_from' says how far back they reach.",
			params: []param{
				{name: "group_by", kind: "string", description: "How to group (default shop).", enum: []string{"shop", "item", "supplier", "day", "buyer"}},
				{name: "buyer", kind: "string", description: "Who bought.", enum: []string{"shops", "customers", "company"}},
				{name: "kind", kind: "string", description: "Only this kind.", enum: []string{"card", "airtime", "bill"}},
				dateParam("since", "First"),
			},
			run: runSalesBreakdown,
		}},
		{"dollar_rate", tool{
			title:       "Dollar rate and funding",
			description: "The dollar rate cards are priced at: the fulus.ly series in use (parallel market, e.g. North Africa Bank 'nab'), its recent history, the live rate and when it was read, the funding-aware quote (replacement cost, peak, momentum, cushion, shock), supplier fundings (USDT top-ups) and per-supplier books. A 'problem' or 'rate_problem' field means the feed is stale or pricing fell back to a manual rate.",
			params:      []param{{name: "history_points", kind: "integer", description: "Keep the latest N history points (default 60)."}},
			run: func(c *call) (any, error) {
				body, err := c.get("/v1/vouchers/admin/fx", nil)
				if err != nil {
					return nil, err
				}
				if state, ok := body.(map[string]any); ok {
					if history, ok := state["history"].([]any); ok {
						if keep := c.integer("history_points", 60, 1000); len(history) > keep {
							state["history"] = history[len(history)-keep:]
							state["history_note"] = fmt.Sprintf("latest %d of %d points", keep, len(history))
						}
					}
				}
				return body, nil
			},
		}},
		{"pricing_settings", tool{
			title:       "Pricing settings",
			description: "The published voucher pricing settings (margins, minimum shop margin, dollar rate source and buffer, FX policy) and their recent change history.",
			params:      []param{{name: "history_limit", kind: "integer", description: "Changes to include, 1-50 (default 10)."}},
			run: func(c *call) (any, error) {
				return c.several(map[string]string{
					"settings": "/v1/vouchers/admin/settings",
					"history":  "/v1/vouchers/admin/settings/history?limit=" + strconv.Itoa(c.integer("history_limit", 10, 50)),
				}), nil
			},
		}},
		{"supplier_balances", tool{
			title:       "Supplier balances",
			description: "The company's balance at each supplier as the supplier reports it now: BN Plus wallets (dinars), FazerCards account, Reloadly cards and airtime/bill balances (USD). eSIM Access's balance is in dollar_rate's supplier books when it has been read.",
			run: func(c *call) (any, error) {
				return c.several(map[string]string{
					"bnplus":            "/v1/vouchers/admin/bnplus/wallets",
					"fazer":             "/v1/vouchers/admin/fazer/account",
					"reloadly":          "/v1/vouchers/admin/reloadly/balance",
					"reloadly_services": "/v1/services/admin/balance",
				}), nil
			},
		}},
		{"catalog_items", tool{
			title:       "Catalog items and margins",
			description: "Every card in the published catalog with who supplies it, each supplier's current cost in dinars, stock, and whether it can sell now. Compare against pricing_settings to find margins below the floor.",
			run:         func(c *call) (any, error) { return c.get("/v1/vouchers/admin/catalog/items", nil) },
		}},
		{"company_stock", tool{
			title:       "Company card stock",
			description: "The company's own stock of card codes by item: how many are on the shelf, sold and voided. Never the codes.",
			run:         func(c *call) (any, error) { return c.get("/v1/vouchers/admin/stock", nil) },
		}},
		{"wallet_topups", tool{
			title:       "Wallet top-ups",
			description: "Shop wallet top-ups (Dafa card payments, bank transfers, cash), newest first. status=review means a bank transfer waits for the operator.",
			params: []param{
				{name: "status", kind: "string", description: "Only this status.", enum: []string{"pending", "review", "paid", "rejected", "canceled", "failed", "expired"}},
				{name: "limit", kind: "integer", description: "How many, 1-200 (default 50)."},
			},
			run: func(c *call) (any, error) {
				return c.get("/v1/wallet/admin/topups", queryOf("status", c.str("status"), "limit", strconv.Itoa(c.integer("limit", 50, 200))))
			},
		}},
		{"shop_wallets", tool{
			title:       "Shop wallets",
			description: "Every shop's wallet balance (what the company owes shops in prepaid credit).",
			run:         func(c *call) (any, error) { return c.get("/v1/wallet/admin/wallets", nil) },
		}},
		{"fleet_health", tool{
			title:       "Fleet and installation health",
			description: "The relay's own health (nodes, Postgres, Redis, traffic), the fleet's versions and update runs, and every installation with its subscription and last-seen state.",
			run: func(c *call) (any, error) {
				return c.several(map[string]string{
					"system":        "/v1/system",
					"fleet":         "/v1/fleet",
					"installations": "/v1/installations",
				}), nil
			},
		}},
		{"alerts", tool{
			title:       "Active alerts",
			description: "Alerts the relay is raising now (low supplier balance, stuck purchases, stale feeds and the like).",
			run:         func(c *call) (any, error) { return c.get("/v1/alerts/active", nil) },
		}},
		{"customers_summary", tool{
			title:       "Consumer app summary",
			description: "Daftar Cards app totals: customers, orders and sales. Aggregates only; no customer details.",
			run:         func(c *call) (any, error) { return c.get("/v1/customers/admin/summary", nil) },
		}},
		{"cards_customers", tool{
			title:       "Cards app customers",
			description: "Daftar Cards app customers with orders, delivered count, total spent, store credit, devices, platforms and last seen. Customers are identified by id only; phone numbers are removed. Segments: active (default), buyers, blocked, deleted, all.",
			params: []param{
				{name: "segment", kind: "string", description: "Which customers.", enum: []string{"active", "buyers", "blocked", "deleted", "all"}},
				{name: "limit", kind: "integer", description: "How many, 1-500 (default 100)."},
				{name: "offset", kind: "integer", description: "Skip this many (paging)."},
			},
			run: func(c *call) (any, error) {
				segment := c.str("segment")
				if segment == "active" {
					segment = ""
				}
				return c.get("/v1/customers/admin/customers", queryOf("segment", segment,
					"limit", strconv.Itoa(c.integer("limit", 100, 500)), "offset", strconv.Itoa(c.integer("offset", 0, 1_000_000))))
			},
		}},
		{"cards_orders", tool{
			title:       "Cards app orders",
			description: "Daftar Cards app orders, newest first: item, channel (iOS, Android, web), total, credit used, fee, payment method, status, error, cost and profit. Player IDs and payment details are removed.",
			params: []param{
				{name: "status", kind: "string", description: "Only this status.", enum: []string{"awaiting_payment", "paid", "fulfilling", "delivered", "refunded", "cancelled", "failed", "expired"}},
				{name: "channel", kind: "string", description: "Only this channel."},
				{name: "customer", kind: "string", description: "Only this customer id."},
				{name: "limit", kind: "integer", description: "How many, 1-1000 (default 200)."},
			},
			run: func(c *call) (any, error) {
				body, err := c.get("/v1/customers/admin/orders", queryOf("status", c.str("status"), "channel", c.str("channel"),
					"customer", c.str("customer"), "limit", strconv.Itoa(c.integer("limit", 200, 1000))))
				return drop(body, orderPrivateFields...), err
			},
		}},
		{"cards_sales_breakdown", tool{
			title:       "Cards app sales breakdown",
			description: "Cards app orders added up by item, channel, status, day or payment method: count, quantity, sales (order totals), cost and profit in dinars. Reads the latest 1000 orders; 'covers_from' says how far back.",
			params: []param{
				{name: "group_by", kind: "string", description: "How to group (default item).", enum: []string{"item", "channel", "status", "day", "method"}},
				{name: "status", kind: "string", description: "Only this status (default delivered).", enum: []string{"delivered", "refunded", "failed", "cancelled", "expired", "all"}},
				dateParam("since", "First"),
			},
			run: runCardsBreakdown,
		}},
		{"cards_order_reports", tool{
			title:       "Cards app problem reports",
			description: "Problems customers reported on their orders («الإبلاغ عن مشكلة») and whether they were resolved.",
			params:      []param{{name: "status", kind: "string", description: "Only this status (open or resolved)."}},
			run: func(c *call) (any, error) {
				return c.get("/v1/customers/admin/reports", queryOf("status", c.str("status")))
			},
		}},
		{"cards_engagement", tool{
			title:       "Cards app campaigns and notifications",
			description: "Campaigns (codes, rewards, caps, last day, uses) and the push notifications sent, with devices reached and failures.",
			run: func(c *call) (any, error) {
				return c.several(map[string]string{
					"campaigns":     "/v1/customers/admin/campaigns",
					"notifications": "/v1/customers/admin/notifications",
				}), nil
			},
		}},
		{"cards_shelf", tool{
			title:       "Cards app shelf",
			description: "What the app sells where: the mobile-apps shelf rules (hidden, web only or on sale per store) and the eSIM promotions.",
			run: func(c *call) (any, error) {
				return c.several(map[string]string{
					"shelf":       "/v1/customers/admin/shelf",
					"esim_promos": "/v1/customers/admin/esim-promos",
				}), nil
			},
		}},
	}
	byName := map[string]tool{}
	order := make([]string, 0, len(tools))
	for _, t := range tools {
		byName[t.name] = t.tool
		order = append(order, t.name)
	}
	return byName, order
}

// maxToolText keeps a result under claude.ai's tool-result limit.
const maxToolText = 100_000

func (s *Server) callTool(r *http.Request, grant control.MCPGrant, raw json.RawMessage) (any, *rpcError) {
	var params struct {
		Name      string         `json:"name"`
		Arguments map[string]any `json:"arguments"`
	}
	if err := json.Unmarshal(raw, &params); err != nil {
		return nil, &rpcError{Code: -32602, Message: "invalid params"}
	}
	t, ok := s.tools[params.Name]
	if !ok {
		return nil, &rpcError{Code: -32602, Message: "unknown tool: " + params.Name}
	}
	args, _ := json.Marshal(params.Arguments)
	auditPath := "/mcp/tools/" + params.Name
	if !s.allow(r.Context(), "calls:"+grant.ID, s.cfg.CallPolicy) || !s.allow(r.Context(), "daily:"+grant.ID, s.cfg.DailyPolicy) {
		s.audit(r, grant, "mcp."+params.Name, auditPath, http.StatusTooManyRequests, string(args))
		return toolText("Rate limit reached for this connector; try again later.", true), nil
	}
	if params.Arguments == nil {
		params.Arguments = map[string]any{}
	}
	started := s.cfg.Now()
	result, err := t.run(&call{s: s, r: r, grant: grant, args: params.Arguments})
	status := http.StatusOK
	if err != nil {
		status = http.StatusBadGateway
		var toolErr errTool
		message := "the relay could not answer this tool"
		if errors.As(err, &toolErr) {
			message = toolErr.message
		} else {
			s.cfg.Logger.Error("mcp tool failed", "tool", params.Name, "error", err)
		}
		s.audit(r, grant, "mcp."+params.Name, auditPath, status, string(args))
		return toolText(message, true), nil
	}
	s.audit(r, grant, "mcp."+params.Name, auditPath, status, string(args))
	s.cfg.Logger.Info("mcp tool call", "grant", grant.ID, "tool", params.Name, "took", s.cfg.Now().Sub(started))
	return toolText(fitText(result, maxToolText), false), nil
}

func toolText(text string, isError bool) map[string]any {
	return map[string]any{"content": []map[string]any{{"type": "text", "text": text}}, "isError": isError}
}

// fitText encodes a result, shortening its longest lists until it fits.
func fitText(result any, limit int) string {
	encoded, _ := json.MarshalIndent(result, "", " ")
	for keep := 200; len(encoded) > limit && keep >= 5; keep /= 2 {
		encoded, _ = json.MarshalIndent(trimLists(result, keep), "", " ")
	}
	if len(encoded) > limit {
		return string(encoded[:limit]) + "\n…(cut)"
	}
	return string(encoded)
}

func trimLists(value any, keep int) any {
	switch v := value.(type) {
	case map[string]any:
		out := make(map[string]any, len(v))
		for key, item := range v {
			out[key] = trimLists(item, keep)
		}
		return out
	case []any:
		if len(v) > keep {
			out := make([]any, 0, keep+1)
			for _, item := range v[:keep] {
				out = append(out, trimLists(item, keep))
			}
			return append(out, fmt.Sprintf("…%d more not shown", len(v)-keep))
		}
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = trimLists(item, keep)
		}
		return out
	default:
		return value
	}
}

// --- sales breakdown -----------------------------------------------------------

type salesGroup struct {
	Key      string `json:"key"`
	Name     string `json:"name,omitempty"`
	Count    int    `json:"count"`
	Quantity int64  `json:"quantity"`
	Sales    string `json:"sales"`
	Cost     string `json:"cost"`
	Profit   string `json:"profit"`
	Unpriced int    `json:"unpriced,omitempty"`

	sales, cost, profit *big.Rat
}

var libya = time.FixedZone("Africa/Tripoli", 2*60*60)

func runSalesBreakdown(c *call) (any, error) {
	groupBy := c.str("group_by")
	if groupBy == "" {
		groupBy = "shop"
	}
	var since time.Time
	if raw := c.str("since"); raw != "" {
		day, err := time.ParseInLocation("2006-01-02", raw, libya)
		if err != nil {
			return nil, errTool{"since must be YYYY-MM-DD"}
		}
		since = day
	}
	body, err := c.get("/v1/vouchers/admin/purchases", queryOf("status", "succeeded", "buyer", c.str("buyer"),
		"kind", c.str("kind"), "limit", "500"))
	if err != nil {
		return nil, err
	}
	listing, _ := body.(map[string]any)
	purchases, _ := listing["purchases"].([]any)
	groups := map[string]*salesGroup{}
	total := &salesGroup{Key: "total", sales: new(big.Rat), cost: new(big.Rat), profit: new(big.Rat)}
	var oldest time.Time
	counted := 0
	for _, raw := range purchases {
		p, _ := raw.(map[string]any)
		if p == nil || p["test_mode"] == true {
			continue
		}
		created, _ := time.Parse(time.RFC3339Nano, fmt.Sprint(p["created_at"]))
		if !since.IsZero() && created.Before(since) {
			continue
		}
		if oldest.IsZero() || created.Before(oldest) {
			oldest = created
		}
		counted++
		key, name := groupKey(groupBy, p, created)
		g := groups[key]
		if g == nil {
			g = &salesGroup{Key: key, Name: name, sales: new(big.Rat), cost: new(big.Rat), profit: new(big.Rat)}
			groups[key] = g
		}
		salesField := ""
		if strings.TrimSpace(fmt.Sprint(valueOr(p["installation_id"], ""))) != "" {
			salesField = "amount"
		}
		for _, target := range []*salesGroup{g, total} {
			target.add(p, salesField)
		}
	}
	list := make([]*salesGroup, 0, len(groups))
	for _, g := range groups {
		list = append(list, g.finish())
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].sales.Cmp(list[j].sales) != 0 {
			return list[i].sales.Cmp(list[j].sales) > 0
		}
		return list[i].Key < list[j].Key
	})
	out := map[string]any{
		"group_by": groupBy, "groups": list, "total": total.finish(),
		"purchases_counted": counted, "listing_size": len(purchases),
		"note": "sales = what shops paid (a customer order's sale is in finance_summary); company purchases carry cost only. unpriced = cost unknown.",
	}
	if !oldest.IsZero() {
		out["covers_from"] = oldest.UTC().Format(time.RFC3339)
	}
	if len(purchases) >= 500 {
		out["truncated"] = "only the latest 500 purchases were read; use finance_summary for whole periods"
	}
	return out, nil
}

func groupKey(groupBy string, p map[string]any, created time.Time) (string, string) {
	text := func(name string) string { return strings.TrimSpace(fmt.Sprint(valueOr(p[name], ""))) }
	switch groupBy {
	case "item":
		return text("item"), text("name")
	case "supplier":
		return text("supplier"), ""
	case "day":
		return created.In(libya).Format("2006-01-02"), ""
	case "buyer":
		switch {
		case text("installation_id") != "":
			return "shops", ""
		case text("purpose") == "customer":
			return "customers", ""
		default:
			return "company", ""
		}
	default:
		if id := text("installation_id"); id != "" {
			return id, text("shop_name")
		}
		return "(no shop)", ""
	}
}

func valueOr(value any, fallback any) any {
	if value == nil {
		return fallback
	}
	return value
}

func ratOf(value any) (*big.Rat, bool) {
	if value == nil {
		return nil, false
	}
	r, ok := new(big.Rat).SetString(strings.TrimSpace(fmt.Sprint(value)))
	return r, ok
}

// add counts one sale; salesField names its price ("" when it earns no sale).
func (g *salesGroup) add(p map[string]any, salesField string) {
	g.Count++
	if q, ok := ratOf(p["quantity"]); ok && q.IsInt() {
		g.Quantity += q.Num().Int64()
	}
	if salesField != "" {
		if amount, ok := ratOf(p[salesField]); ok {
			g.sales.Add(g.sales, amount)
		}
	}
	cost, ok := ratOf(p["cost_lyd"])
	if !ok {
		g.Unpriced++
		return
	}
	g.cost.Add(g.cost, cost)
	if profit, ok := ratOf(p["profit"]); ok {
		g.profit.Add(g.profit, profit)
	}
}

func (g *salesGroup) finish() *salesGroup {
	g.Sales, g.Cost, g.Profit = g.sales.FloatString(3), g.cost.FloatString(3), g.profit.FloatString(3)
	return g
}

// orderPrivateFields are a cards order's details about the payer: the player
// account it was sent to and the payment's own references.
var orderPrivateFields = []string{"account", "payer_hint", "checkout_url", "payment_id", "otp_attempts"}

func runCardsBreakdown(c *call) (any, error) {
	groupBy := c.str("group_by")
	if groupBy == "" {
		groupBy = "item"
	}
	status := c.str("status")
	switch status {
	case "":
		status = "delivered"
	case "all":
		status = ""
	}
	var since time.Time
	if raw := c.str("since"); raw != "" {
		day, err := time.ParseInLocation("2006-01-02", raw, libya)
		if err != nil {
			return nil, errTool{"since must be YYYY-MM-DD"}
		}
		since = day
	}
	body, err := c.get("/v1/customers/admin/orders", queryOf("status", status, "limit", "1000"))
	if err != nil {
		return nil, err
	}
	listing, _ := body.(map[string]any)
	orders, _ := listing["orders"].([]any)
	groups := map[string]*salesGroup{}
	total := &salesGroup{Key: "total", sales: new(big.Rat), cost: new(big.Rat), profit: new(big.Rat)}
	var oldest time.Time
	counted := 0
	for _, raw := range orders {
		o, _ := raw.(map[string]any)
		if o == nil || o["test_mode"] == true {
			continue
		}
		created, _ := time.Parse(time.RFC3339Nano, fmt.Sprint(o["created_at"]))
		if !since.IsZero() && created.Before(since) {
			continue
		}
		if oldest.IsZero() || created.Before(oldest) {
			oldest = created
		}
		counted++
		text := func(name string) string { return strings.TrimSpace(fmt.Sprint(valueOr(o[name], ""))) }
		key, name := text("item"), text("name")
		switch groupBy {
		case "channel", "status", "method":
			key, name = text(groupBy), ""
		case "day":
			key, name = created.In(libya).Format("2006-01-02"), ""
		}
		if key == "" {
			key = "(none)"
		}
		g := groups[key]
		if g == nil {
			g = &salesGroup{Key: key, Name: name, sales: new(big.Rat), cost: new(big.Rat), profit: new(big.Rat)}
			groups[key] = g
		}
		for _, target := range []*salesGroup{g, total} {
			target.add(o, "total")
		}
	}
	list := make([]*salesGroup, 0, len(groups))
	for _, g := range groups {
		list = append(list, g.finish())
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].sales.Cmp(list[j].sales) != 0 {
			return list[i].sales.Cmp(list[j].sales) > 0
		}
		return list[i].Key < list[j].Key
	})
	out := map[string]any{"group_by": groupBy, "status": firstNonEmpty(status, "all"), "groups": list,
		"total": total.finish(), "orders_counted": counted, "listing_size": len(orders),
		"note": "sales = order totals (store credit included). cost and profit are filled for delivered orders. unpriced = cost unknown."}
	if !oldest.IsZero() {
		out["covers_from"] = oldest.UTC().Format(time.RFC3339)
	}
	if len(orders) >= 1000 {
		out["truncated"] = "only the latest 1000 orders were read; use finance_summary for whole periods"
	}
	return out, nil
}
