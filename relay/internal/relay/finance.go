package relay

import (
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"pointy/relay/internal/control"
)

// The company's books (see control/finance.go), admin-only:
//
//	GET  /v1/finance/entries              the hand-written lines, filtered
//	POST /v1/finance/entries              write one (income or expense)
//	POST /v1/finance/entries/{id}/void    take one out, with a reason
//	GET  /v1/finance/summary?from=&to=    profit and loss for a period
//
// The summary is the one place the two kinds of numbers meet: what the relay
// recorded on its own (services shops paid for, supplier and SMS costs) and
// what the operator wrote. A shop's top-up is reported beside the result,
// never in it: until the shop spends it, it is the shop's money.

const maxFinanceRequestBytes = 16 << 10

// maxFinancePeriod bounds one summary: the roll-up reads every month in it.
const maxFinancePeriod = 3 * 366 * 24 * time.Hour

type financeEntryRequest struct {
	Direction      string `json:"direction"`
	Category       string `json:"category"`
	Amount         string `json:"amount"`
	Currency       string `json:"currency"`
	Rate           string `json:"rate"`
	OccurredOn     string `json:"occurred_on"`
	Counterparty   string `json:"counterparty"`
	Note           string `json:"note"`
	InstallationID string `json:"installation_id"`
	Reference      string `json:"reference"`
	IdempotencyKey string `json:"idempotency_key"`
	Actor          string `json:"actor"`
	// Attachments are receipts uploaded first (POST /v1/finance/attachments).
	Attachments []financeAttachmentRequest `json:"attachments"`
	// RecurringID and RecurringMonth write a monthly line's month: its key
	// is the month's, so it is written once.
	RecurringID    string `json:"recurring_id"`
	RecurringMonth string `json:"recurring_month"`
}

func (s HTTPServer) financeStore(w http.ResponseWriter) (control.FinanceStore, bool) {
	store, ok := s.Store.(control.FinanceStore)
	if !ok {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "the company books are unavailable"})
		return nil, false
	}
	return store, true
}

func writeFinanceError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]string{"error": message, "code": code})
}

func (s HTTPServer) writeFinanceStoreError(w http.ResponseWriter, message string, err error) {
	switch {
	case errors.Is(err, control.ErrInvalidFinanceEntry):
		writeFinanceError(w, http.StatusBadRequest, "invalid_request", strings.TrimPrefix(err.Error(), control.ErrInvalidFinanceEntry.Error()+": "))
	case errors.Is(err, control.ErrNotFound):
		writeFinanceError(w, http.StatusNotFound, "not_found", "finance entry not found")
	case errors.Is(err, control.ErrFinanceEntryVoided):
		writeFinanceError(w, http.StatusConflict, "already_voided", "the entry was already voided")
	default:
		s.logger().Error(message, "error", err)
		writeFinanceError(w, http.StatusInternalServerError, "internal_error", "relay store failed")
	}
}

// handleFinanceRoutes dispatches /v1/finance/...
func (s HTTPServer) handleFinanceRoutes(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	switch {
	case path == "/v1/finance/entries" && r.Method == http.MethodGet:
		s.handleFinanceList(w, r)
	case path == "/v1/finance/entries" && r.Method == http.MethodPost:
		s.handleFinanceCreate(w, r)
	case strings.HasPrefix(path, "/v1/finance/entries/") && strings.HasSuffix(path, "/void") && r.Method == http.MethodPost:
		id := strings.TrimSuffix(strings.TrimPrefix(path, "/v1/finance/entries/"), "/void")
		if id == "" || strings.Contains(id, "/") {
			writeNotFound(w)
			return
		}
		s.handleFinanceVoid(w, r, id)
	case strings.HasPrefix(path, "/v1/finance/entries/") && strings.HasSuffix(path, "/attachments") && r.Method == http.MethodPost:
		id := strings.TrimSuffix(strings.TrimPrefix(path, "/v1/finance/entries/"), "/attachments")
		if id == "" || strings.Contains(id, "/") {
			writeNotFound(w)
			return
		}
		s.handleFinanceAddAttachment(w, r, id)
	case path == "/v1/finance/attachments" && r.Method == http.MethodPost:
		s.handleFinanceAttachmentUpload(w, r)
	case strings.HasPrefix(path, "/v1/finance/attachments/") && r.Method == http.MethodGet:
		s.handleFinanceAttachmentRead(w, r, strings.TrimPrefix(path, "/v1/finance/attachments/"))
	case path == "/v1/finance/recurring" && r.Method == http.MethodGet:
		s.handleFinanceRecurringList(w, r)
	case path == "/v1/finance/recurring" && r.Method == http.MethodPost:
		s.handleFinanceRecurringCreate(w, r)
	case strings.HasPrefix(path, "/v1/finance/recurring/") && r.Method == http.MethodPatch:
		id := strings.TrimPrefix(path, "/v1/finance/recurring/")
		if id == "" || strings.Contains(id, "/") {
			writeNotFound(w)
			return
		}
		s.handleFinanceRecurringUpdate(w, r, id)
	case path == "/v1/finance/summary" && r.Method == http.MethodGet:
		s.handleFinanceSummary(w, r)
	default:
		writeNotFound(w)
	}
}

func (s HTTPServer) handleFinanceList(w http.ResponseWriter, r *http.Request) {
	store, ok := s.financeStore(w)
	if !ok {
		return
	}
	s.postDueFinanceRecurring(r.Context(), store)
	query := r.URL.Query()
	limit, _ := strconv.Atoi(query.Get("limit"))
	entries, err := store.ListFinanceEntries(r.Context(), control.FinanceEntryFilter{
		From:           query.Get("from"),
		To:             query.Get("to"),
		Direction:      query.Get("direction"),
		Category:       query.Get("category"),
		InstallationID: query.Get("installation_id"),
		IncludeVoided:  query.Get("include_voided") == "1" || query.Get("include_voided") == "true",
		Limit:          limit,
	})
	if err != nil {
		s.writeFinanceStoreError(w, "finance listing failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": entries, "count": len(entries)})
}

func (s HTTPServer) handleFinanceCreate(w http.ResponseWriter, r *http.Request) {
	store, ok := s.financeStore(w)
	if !ok {
		return
	}
	var request financeEntryRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxFinanceRequestBytes)).Decode(&request); err != nil {
		writeFinanceError(w, http.StatusBadRequest, "invalid_request", "invalid request body")
		return
	}
	if strings.TrimSpace(request.Actor) == "" {
		writeFinanceError(w, http.StatusBadRequest, "invalid_request", "actor is required: every line names who wrote it")
		return
	}
	attachments, err := s.resolveFinanceAttachments(r.Context(), request.Attachments)
	if err != nil {
		s.writeFinanceAttachmentError(w, err)
		return
	}
	key := request.IdempotencyKey
	if request.RecurringID != "" {
		key = control.FinanceRecurringKey(request.RecurringID, request.RecurringMonth)
	}
	entry, existing, err := store.CreateFinanceEntry(r.Context(), control.FinanceEntry{
		Direction:      request.Direction,
		Category:       request.Category,
		OriginalAmount: request.Amount,
		Currency:       request.Currency,
		Rate:           request.Rate,
		OccurredOn:     request.OccurredOn,
		Counterparty:   request.Counterparty,
		Note:           request.Note,
		InstallationID: request.InstallationID,
		Reference:      request.Reference,
		IdempotencyKey: key,
		Actor:          request.Actor,
		Attachments:    attachments,
		RecurringID:    request.RecurringID,
		RecurringMonth: request.RecurringMonth,
	})
	if err != nil {
		s.writeFinanceStoreError(w, "finance entry failed", err)
		return
	}
	status := http.StatusCreated
	if existing {
		status = http.StatusOK
	}
	writeJSON(w, status, entry)
}

func (s HTTPServer) handleFinanceVoid(w http.ResponseWriter, r *http.Request, id string) {
	store, ok := s.financeStore(w)
	if !ok {
		return
	}
	var request struct {
		Reason string `json:"reason"`
		Actor  string `json:"actor"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxFinanceRequestBytes)).Decode(&request); err != nil {
		writeFinanceError(w, http.StatusBadRequest, "invalid_request", "invalid request body")
		return
	}
	if strings.TrimSpace(request.Actor) == "" {
		writeFinanceError(w, http.StatusBadRequest, "invalid_request", "actor is required")
		return
	}
	entry, err := store.VoidFinanceEntry(r.Context(), id, request.Actor, request.Reason)
	if err != nil {
		s.writeFinanceStoreError(w, "finance void failed", err)
		return
	}
	writeJSON(w, http.StatusOK, entry)
}

// financeLine is one source of income or one kind of expense in a period.
type financeLine struct {
	// Source is "tracked" (the relay's own records) or "manual" (entries).
	Source string `json:"source"`
	Key    string `json:"key"`
	Amount string `json:"amount"`
	// Count is how many entries a manual line adds up.
	Count int `json:"count,omitempty"`
}

type financeTotals struct {
	Income  string `json:"income"`
	Expense string `json:"expense"`
	Net     string `json:"net"`
	// MarginPercent is net over income, one decimal; empty without income.
	MarginPercent string `json:"margin_percent"`
}

type financeMonthTotals struct {
	Month   string `json:"month"`
	Income  string `json:"income"`
	Expense string `json:"expense"`
	Net     string `json:"net"`
}

// financeBook adds up one period.
type financeBook struct {
	income   map[string]*big.Rat // "tracked:sms", "manual:cash_subscription"
	expense  map[string]*big.Rat
	counts   map[string]int
	months   map[string]*[2]big.Rat // income, expense
	topUps   map[string]*big.Rat
	unpriced map[string]*big.Rat
	usdRate  *big.Rat
}

func newFinanceBook(usdRate *big.Rat) *financeBook {
	return &financeBook{
		income:   map[string]*big.Rat{},
		expense:  map[string]*big.Rat{},
		counts:   map[string]int{},
		months:   map[string]*[2]big.Rat{},
		topUps:   map[string]*big.Rat{},
		unpriced: map[string]*big.Rat{},
		usdRate:  usdRate,
	}
}

func ratOf(raw string) *big.Rat {
	value, ok := new(big.Rat).SetString(strings.TrimSpace(raw))
	if !ok {
		return new(big.Rat)
	}
	return value
}

func addTo(into map[string]*big.Rat, key string, value *big.Rat) {
	if into[key] == nil {
		into[key] = new(big.Rat)
	}
	into[key].Add(into[key], value)
}

func (b *financeBook) month(name string) *[2]big.Rat {
	if b.months[name] == nil {
		b.months[name] = &[2]big.Rat{}
	}
	return b.months[name]
}

func (b *financeBook) add(month, direction, key string, value *big.Rat) {
	if value.Sign() == 0 {
		return
	}
	m := b.month(month)
	if direction == control.FinanceIncome {
		addTo(b.income, key, value)
		m[0].Add(&m[0], value)
	} else {
		addTo(b.expense, key, value)
		m[1].Add(&m[1], value)
	}
}

func (b *financeBook) addTracked(months []control.FinanceTrackedMonth) {
	for _, month := range months {
		for service, amount := range month.Revenue {
			b.add(month.Month, control.FinanceIncome, "tracked:"+service, ratOf(amount))
		}
		b.add(month.Month, control.FinanceExpense, "tracked:sms_cost", ratOf(month.SMSCost))
		for currency, cost := range month.SupplierCost {
			value := ratOf(cost)
			switch {
			case currency == control.FinanceCurrency:
			case currency == "USD" && b.usdRate != nil:
				value.Mul(value, b.usdRate)
			default:
				// No rate for it: reported beside the result, not guessed.
				addTo(b.unpriced, currency, value)
				continue
			}
			b.add(month.Month, control.FinanceExpense, "tracked:supplier_cost", value)
		}
		for method, amount := range month.TopUps {
			addTo(b.topUps, method, ratOf(amount))
		}
	}
}

func (b *financeBook) addEntries(entries []control.FinanceEntry) {
	for _, entry := range entries {
		key := "manual:" + entry.Category
		b.add(entry.OccurredOn[:7], entry.Direction, key, ratOf(entry.Amount))
		b.counts[entry.Direction+":"+key]++
	}
}

func (b *financeBook) totals() financeTotals {
	income, expense := new(big.Rat), new(big.Rat)
	for _, value := range b.income {
		income.Add(income, value)
	}
	for _, value := range b.expense {
		expense.Add(expense, value)
	}
	net := new(big.Rat).Sub(income, expense)
	totals := financeTotals{
		Income:  control.FormatWalletAmount(income),
		Expense: control.FormatWalletAmount(expense),
		Net:     control.FormatWalletAmount(net),
	}
	if income.Sign() > 0 {
		margin := new(big.Rat).Quo(net, income)
		totals.MarginPercent = margin.Mul(margin, big.NewRat(100, 1)).FloatString(1)
	}
	return totals
}

func (b *financeBook) lines(direction string, values map[string]*big.Rat) []financeLine {
	lines := make([]financeLine, 0, len(values))
	for key, value := range values {
		if value.Sign() == 0 {
			continue
		}
		source, name, _ := strings.Cut(key, ":")
		lines = append(lines, financeLine{
			Source: source,
			Key:    name,
			Amount: control.FormatWalletAmount(value),
			Count:  b.counts[direction+":"+key],
		})
	}
	sort.Slice(lines, func(i, j int) bool {
		if c := ratOf(lines[i].Amount).Cmp(ratOf(lines[j].Amount)); c != 0 {
			return c > 0
		}
		return lines[i].Source+lines[i].Key < lines[j].Source+lines[j].Key
	})
	return lines
}

// monthSeries is every month from first to last, including the empty ones,
// so a chart has no gaps.
func (b *financeBook) monthSeries(first, last time.Time) []financeMonthTotals {
	series := []financeMonthTotals{}
	for at := time.Date(first.Year(), first.Month(), 1, 0, 0, 0, 0, first.Location()); !at.After(last); at = at.AddDate(0, 1, 0) {
		name := at.Format("2006-01")
		m := b.month(name)
		net := new(big.Rat).Sub(&m[0], &m[1])
		series = append(series, financeMonthTotals{
			Month:   name,
			Income:  control.FormatWalletAmount(&m[0]),
			Expense: control.FormatWalletAmount(&m[1]),
			Net:     control.FormatWalletAmount(net),
		})
	}
	return series
}

func formatRatMap(values map[string]*big.Rat) map[string]string {
	out := map[string]string{}
	for key, value := range values {
		if value.Sign() != 0 {
			out[key] = control.FormatWalletAmount(value)
		}
	}
	return out
}

// financePeriod reads from/to (inclusive days); the default is this month so
// far.
func (s HTTPServer) financePeriod(r *http.Request) (from, to time.Time, ok bool) {
	now := control.FinanceDayStart(s.clock().Now())
	from = now.AddDate(0, 0, 1-now.Day())
	to = now
	query := r.URL.Query()
	for _, param := range []struct {
		name string
		into *time.Time
	}{{"from", &from}, {"to", &to}} {
		raw := strings.TrimSpace(query.Get(param.name))
		if raw == "" {
			continue
		}
		day, err := control.ParseFinanceDate(raw)
		if err != nil {
			return time.Time{}, time.Time{}, false
		}
		*param.into = day
	}
	if to.Before(from) || to.Sub(from) > maxFinancePeriod {
		return time.Time{}, time.Time{}, false
	}
	return from, to, true
}

func (s HTTPServer) financeBookFor(r *http.Request, store control.FinanceStore, from, to time.Time, usdRate *big.Rat) (*financeBook, int, error) {
	end := to.AddDate(0, 0, 1)
	tracked, err := store.FinanceTracked(r.Context(), from, end)
	if err != nil {
		return nil, 0, err
	}
	entries, err := store.ListFinanceEntries(r.Context(), control.FinanceEntryFilter{
		From:  from.Format("2006-01-02"),
		To:    to.Format("2006-01-02"),
		Limit: 5000,
	})
	if err != nil {
		return nil, 0, err
	}
	book := newFinanceBook(usdRate)
	book.addTracked(tracked)
	book.addEntries(entries)
	return book, len(entries), nil
}

func (s HTTPServer) handleFinanceSummary(w http.ResponseWriter, r *http.Request) {
	store, ok := s.financeStore(w)
	if !ok {
		return
	}
	s.postDueFinanceRecurring(r.Context(), store)
	from, to, ok := s.financePeriod(r)
	if !ok {
		writeFinanceError(w, http.StatusBadRequest, "invalid_request", "from and to are days (2006-01-02), from first, three years at most")
		return
	}

	// Dollar costs are turned into dinars at the pricing rate the shops are
	// charged at today: an estimate, and the summary says so.
	var usdRate *big.Rat
	rateInfo := map[string]string{}
	if voucherStore, ok := s.Store.(control.VoucherStore); ok {
		if settings, _, err := s.currentVoucherSettings(r.Context(), voucherStore); err == nil {
			if rate, source := settings.EffectiveUSDRate(); rate != nil {
				usdRate = rate
				rateInfo["rate"] = rate.FloatString(4)
				rateInfo["source"] = source
			}
		}
	}

	book, manualCount, err := s.financeBookFor(r, store, from, to, usdRate)
	if err != nil {
		s.writeFinanceStoreError(w, "finance summary failed", err)
		return
	}
	// The period just before, as long, for the comparison.
	days := int(to.Sub(from).Hours()/24+0.5) + 1
	previousTo := from.AddDate(0, 0, -1)
	previousFrom := previousTo.AddDate(0, 0, 1-days)
	previous, _, err := s.financeBookFor(r, store, previousFrom, previousTo, usdRate)
	if err != nil {
		s.writeFinanceStoreError(w, "finance summary failed", err)
		return
	}

	topUpTotal := new(big.Rat)
	for _, value := range book.topUps {
		topUpTotal.Add(topUpTotal, value)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"from":         from.Format("2006-01-02"),
		"to":           to.Format("2006-01-02"),
		"currency":     control.FinanceCurrency,
		"usd_rate":     rateInfo,
		"totals":       book.totals(),
		"previous":     map[string]any{"from": previousFrom.Format("2006-01-02"), "to": previousTo.Format("2006-01-02"), "totals": previous.totals()},
		"months":       book.monthSeries(from, to),
		"income":       book.lines(control.FinanceIncome, book.income),
		"expense":      book.lines(control.FinanceExpense, book.expense),
		"topups":       map[string]any{"total": control.FormatWalletAmount(topUpTotal), "by_method": formatRatMap(book.topUps)},
		"unpriced":     formatRatMap(book.unpriced),
		"manual_count": manualCount,
	})
}
