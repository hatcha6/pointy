package control

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// A monthly expense (or income) is a line the books need every month: the
// rent, the server bill, a salary. It writes its own line on its day.
//
// Two kinds: an auto one writes the same amount itself; a confirm one (the
// electricity bill, whose amount changes) waits as "due" until an operator
// writes the month's line with the real amount, or skips the month. Either
// way the month's line carries the key recurring:<id>:<month>, so it is
// written once however many relay instances or browsers try.

// Recurring modes.
const (
	FinanceRecurringAuto    = "auto"
	FinanceRecurringConfirm = "confirm"
)

// maxFinanceBackfillMonths bounds how far back a new monthly line writes.
const maxFinanceBackfillMonths = 24

// FinanceRecurring is one monthly line.
type FinanceRecurring struct {
	ID        string `json:"id"`
	Direction string `json:"direction"`
	Category  string `json:"category"`
	// Amount, Currency and Rate are as on an entry: Amount in Currency.
	Amount   string `json:"amount"`
	Currency string `json:"currency"`
	Rate     string `json:"rate"`
	// DayOfMonth is when the month's line falls due, 1–28.
	DayOfMonth     int    `json:"day_of_month"`
	Mode           string `json:"mode"`
	Counterparty   string `json:"counterparty,omitempty"`
	Note           string `json:"note,omitempty"`
	InstallationID string `json:"installation_id,omitempty"`
	// StartMonth is the first month it covers; EndMonth the last, if set.
	StartMonth string `json:"start_month"`
	EndMonth   string `json:"end_month,omitempty"`
	// Skipped are months the operator said had no such line.
	Skipped   []string   `json:"skipped"`
	Active    bool       `json:"active"`
	Actor     string     `json:"actor,omitempty"`
	CreatedAt time.Time  `json:"created_at"`
	UpdatedAt time.Time  `json:"updated_at"`
	StoppedAt *time.Time `json:"stopped_at,omitempty"`
	StoppedBy string     `json:"stopped_by,omitempty"`
}

// FinanceRecurringKey is the idempotency key of a monthly line's month.
func FinanceRecurringKey(id, month string) string {
	return "recurring:" + id + ":" + month
}

// DueDay is the day the month's line falls on: "2026-10-05".
func (r FinanceRecurring) DueDay(month string) string {
	day := r.DayOfMonth
	if day < 1 {
		day = 1
	}
	return month + "-" + twoDigits(day)
}

func twoDigits(n int) string {
	return string([]byte{byte('0' + n/10), byte('0' + n%10)})
}

// DueMonths are the months whose line is due by now and not written (posted
// holds the months that have one, voided or not) or skipped, oldest first.
func (r FinanceRecurring) DueMonths(posted map[string]bool, now time.Time) []string {
	if !r.Active {
		return nil
	}
	today := FinanceDayStart(now).Format("2006-01-02")
	current := FinanceMonth(now)
	first := FinanceDayStart(now).AddDate(0, -(maxFinanceBackfillMonths - 1), 0).Format("2006-01")
	if r.StartMonth > first {
		first = r.StartMonth
	}
	skipped := map[string]bool{}
	for _, m := range r.Skipped {
		skipped[m] = true
	}
	due := []string{}
	for month := first; month <= current; month = nextFinanceMonth(month) {
		if r.EndMonth != "" && month > r.EndMonth {
			break
		}
		if posted[month] || skipped[month] || r.DueDay(month) > today {
			continue
		}
		due = append(due, month)
	}
	return due
}

func nextFinanceMonth(month string) string {
	t, err := time.Parse("2006-01", month)
	if err != nil {
		return "9999-12"
	}
	return t.AddDate(0, 1, 0).Format("2006-01")
}

// prepareFinanceRecurring checks a monthly line. The money fields are checked
// the way an entry's are.
func prepareFinanceRecurring(r FinanceRecurring, now time.Time) (FinanceRecurring, error) {
	probe, err := prepareFinanceEntry(FinanceEntry{
		Direction:      r.Direction,
		Category:       r.Category,
		OriginalAmount: r.Amount,
		Currency:       r.Currency,
		Rate:           r.Rate,
		OccurredOn:     FinanceDayStart(now).Format("2006-01-02"),
		IdempotencyKey: "probe",
	}, now)
	if err != nil {
		return FinanceRecurring{}, err
	}
	r.Direction, r.Category, r.Amount, r.Currency, r.Rate = probe.Direction, probe.Category, probe.OriginalAmount, probe.Currency, probe.Rate
	if r.Currency == FinanceCurrency {
		r.Rate = ""
	}
	if r.DayOfMonth < 1 || r.DayOfMonth > 28 {
		return FinanceRecurring{}, invalidFinance("day_of_month is 1 to 28, so every month has it")
	}
	r.Mode = strings.ToLower(strings.TrimSpace(r.Mode))
	if r.Mode == "" {
		r.Mode = FinanceRecurringAuto
	}
	if r.Mode != FinanceRecurringAuto && r.Mode != FinanceRecurringConfirm {
		return FinanceRecurring{}, invalidFinance("mode is auto or confirm")
	}
	r.StartMonth = strings.TrimSpace(r.StartMonth)
	if r.StartMonth == "" {
		r.StartMonth = FinanceMonth(now)
	}
	r.EndMonth = strings.TrimSpace(r.EndMonth)
	if !financeMonthPattern.MatchString(r.StartMonth) || (r.EndMonth != "" && (!financeMonthPattern.MatchString(r.EndMonth) || r.EndMonth < r.StartMonth)) {
		return FinanceRecurring{}, invalidFinance("months are written 2006-01, the end after the start")
	}
	if r.StartMonth > nextFinanceMonth(FinanceMonth(now)) {
		return FinanceRecurring{}, invalidFinance("start_month is at most next month")
	}
	r.Counterparty = truncateRunes(strings.TrimSpace(r.Counterparty), maxFinanceText)
	r.Note = truncateRunes(strings.TrimSpace(r.Note), maxFinanceNote)
	r.InstallationID = truncateRunes(strings.TrimSpace(r.InstallationID), maxFinanceText)
	r.Actor = truncateRunes(strings.TrimSpace(r.Actor), maxFinanceText)
	clean := []string{}
	seen := map[string]bool{}
	for _, m := range r.Skipped {
		if financeMonthPattern.MatchString(m) && !seen[m] {
			seen[m] = true
			clean = append(clean, m)
		}
	}
	sort.Strings(clean)
	r.Skipped = clean
	return r, nil
}

// FinanceRecurringChange is an operator's edit. Nil fields stay as they are.
type FinanceRecurringChange struct {
	Category     *string `json:"category,omitempty"`
	Amount       *string `json:"amount,omitempty"`
	Currency     *string `json:"currency,omitempty"`
	Rate         *string `json:"rate,omitempty"`
	DayOfMonth   *int    `json:"day_of_month,omitempty"`
	Mode         *string `json:"mode,omitempty"`
	Counterparty *string `json:"counterparty,omitempty"`
	Note         *string `json:"note,omitempty"`
	EndMonth     *string `json:"end_month,omitempty"`
	// Skip adds a month to Skipped; Unskip takes one off.
	Skip   string `json:"skip,omitempty"`
	Unskip string `json:"unskip,omitempty"`
	// Active false stops it (no more months fall due); true resumes it.
	Active *bool  `json:"active,omitempty"`
	Actor  string `json:"actor,omitempty"`
}

func applyFinanceRecurringChange(r FinanceRecurring, change FinanceRecurringChange, now time.Time) (FinanceRecurring, error) {
	set := func(into *string, value *string) {
		if value != nil {
			*into = *value
		}
	}
	set(&r.Category, change.Category)
	set(&r.Amount, change.Amount)
	set(&r.Currency, change.Currency)
	set(&r.Rate, change.Rate)
	set(&r.Mode, change.Mode)
	set(&r.Counterparty, change.Counterparty)
	set(&r.Note, change.Note)
	set(&r.EndMonth, change.EndMonth)
	if change.DayOfMonth != nil {
		r.DayOfMonth = *change.DayOfMonth
	}
	if m := strings.TrimSpace(change.Skip); m != "" {
		if !financeMonthPattern.MatchString(m) {
			return FinanceRecurring{}, invalidFinance("skip names a month (2006-01)")
		}
		r.Skipped = append(r.Skipped, m)
	}
	if m := strings.TrimSpace(change.Unskip); m != "" {
		kept := []string{}
		for _, have := range r.Skipped {
			if have != m {
				kept = append(kept, have)
			}
		}
		r.Skipped = kept
	}
	if change.Active != nil && *change.Active != r.Active {
		r.Active = *change.Active
		if r.Active {
			r.StoppedAt, r.StoppedBy = nil, ""
		} else {
			at := now.UTC()
			r.StoppedAt, r.StoppedBy = &at, truncateRunes(strings.TrimSpace(change.Actor), maxFinanceText)
		}
	}
	if r.Currency == FinanceCurrency || strings.EqualFold(r.Currency, FinanceCurrency) {
		r.Rate = ""
	}
	prepared, err := prepareFinanceRecurring(r, now)
	if err != nil {
		return FinanceRecurring{}, err
	}
	prepared.UpdatedAt = now.UTC()
	return prepared, nil
}

func newFinanceRecurring(r FinanceRecurring, now time.Time) (FinanceRecurring, error) {
	if r.Currency == "" || strings.EqualFold(r.Currency, FinanceCurrency) {
		r.Rate = ""
	}
	r, err := prepareFinanceRecurring(r, now)
	if err != nil {
		return FinanceRecurring{}, err
	}
	id, err := NewInstallationID()
	if err != nil {
		return FinanceRecurring{}, err
	}
	r.ID = "rec_" + id
	r.Active = true
	r.CreatedAt = now.UTC()
	r.UpdatedAt = r.CreatedAt
	r.StoppedAt, r.StoppedBy = nil, ""
	return r, nil
}

func sortFinanceRecurring(list []FinanceRecurring) {
	sort.SliceStable(list, func(i, j int) bool {
		if list[i].Active != list[j].Active {
			return list[i].Active
		}
		if list[i].DayOfMonth != list[j].DayOfMonth {
			return list[i].DayOfMonth < list[j].DayOfMonth
		}
		return list[i].CreatedAt.Before(list[j].CreatedAt)
	})
}

// FinanceRecurringStore is part of the books: the monthly lines.
type FinanceRecurringStore interface {
	CreateFinanceRecurring(ctx context.Context, r FinanceRecurring) (FinanceRecurring, error)
	ListFinanceRecurring(ctx context.Context) ([]FinanceRecurring, error)
	UpdateFinanceRecurring(ctx context.Context, id string, change FinanceRecurringChange) (FinanceRecurring, error)
	// FinanceRecurringPosted is, per monthly line, the months that have a
	// line in the books (voided ones too: a voided month was decided).
	FinanceRecurringPosted(ctx context.Context) (map[string]map[string]bool, error)
}

// --- file store ------------------------------------------------------------

func (s *FileStore) CreateFinanceRecurring(_ context.Context, r FinanceRecurring) (FinanceRecurring, error) {
	r, err := newFinanceRecurring(r, s.clock.Now())
	if err != nil {
		return FinanceRecurring{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.data.FinanceRecurring == nil {
		s.data.FinanceRecurring = map[string]FinanceRecurring{}
	}
	s.data.FinanceRecurring[r.ID] = r
	if err := s.saveLocked(); err != nil {
		delete(s.data.FinanceRecurring, r.ID)
		return FinanceRecurring{}, err
	}
	return r, nil
}

func (s *FileStore) ListFinanceRecurring(_ context.Context) ([]FinanceRecurring, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	list := make([]FinanceRecurring, 0, len(s.data.FinanceRecurring))
	for _, r := range s.data.FinanceRecurring {
		list = append(list, r)
	}
	sortFinanceRecurring(list)
	return list, nil
}

func (s *FileStore) UpdateFinanceRecurring(_ context.Context, id string, change FinanceRecurringChange) (FinanceRecurring, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	before, ok := s.data.FinanceRecurring[id]
	if !ok {
		return FinanceRecurring{}, ErrNotFound
	}
	after, err := applyFinanceRecurringChange(before, change, s.clock.Now())
	if err != nil {
		return FinanceRecurring{}, err
	}
	s.data.FinanceRecurring[id] = after
	if err := s.saveLocked(); err != nil {
		s.data.FinanceRecurring[id] = before
		return FinanceRecurring{}, err
	}
	return after, nil
}

func (s *FileStore) FinanceRecurringPosted(_ context.Context) (map[string]map[string]bool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	posted := map[string]map[string]bool{}
	for _, entry := range s.data.FinanceEntries {
		if entry.RecurringID == "" {
			continue
		}
		if posted[entry.RecurringID] == nil {
			posted[entry.RecurringID] = map[string]bool{}
		}
		posted[entry.RecurringID][entry.RecurringMonth] = true
	}
	return posted, nil
}

// --- postgres store --------------------------------------------------------

const financeRecurringColumns = `id, direction, category, amount::text, currency, rate::text, day_of_month, mode,
	counterparty, note, installation_id, start_month, end_month, skipped, active, actor, created_at, updated_at,
	stopped_at, stopped_by`

func scanFinanceRecurring(row pgx.Row) (FinanceRecurring, error) {
	var r FinanceRecurring
	err := row.Scan(&r.ID, &r.Direction, &r.Category, &r.Amount, &r.Currency, &r.Rate, &r.DayOfMonth, &r.Mode,
		&r.Counterparty, &r.Note, &r.InstallationID, &r.StartMonth, &r.EndMonth, &r.Skipped, &r.Active, &r.Actor,
		&r.CreatedAt, &r.UpdatedAt, &r.StoppedAt, &r.StoppedBy)
	if err != nil {
		return FinanceRecurring{}, err
	}
	r.Amount = NormalizeWalletAmount(r.Amount)
	if r.Currency == FinanceCurrency {
		r.Rate = ""
	}
	if r.Skipped == nil {
		r.Skipped = []string{}
	}
	return r, nil
}

func financeRecurringArgs(r FinanceRecurring) ([]any, error) {
	skipped, err := json.Marshal(r.Skipped)
	if err != nil {
		return nil, err
	}
	rate := r.Rate
	if rate == "" {
		rate = "1"
	}
	return []any{r.ID, r.Direction, r.Category, r.Amount, r.Currency, rate, r.DayOfMonth, r.Mode,
		r.Counterparty, r.Note, r.InstallationID, r.StartMonth, r.EndMonth, string(skipped), r.Active, r.Actor,
		r.CreatedAt, r.UpdatedAt, r.StoppedAt, r.StoppedBy}, nil
}

const upsertFinanceRecurringSQL = `INSERT INTO relay_finance_recurring (` + `id, direction, category, amount, currency, rate,
	day_of_month, mode, counterparty, note, installation_id, start_month, end_month, skipped, active, actor,
	created_at, updated_at, stopped_at, stopped_by)
	VALUES ($1, $2, $3, $4::numeric, $5, $6::numeric, $7, $8, $9, $10, $11, $12, $13, $14::jsonb, $15, $16,
		$17::timestamptz, $18::timestamptz, $19, $20)
	ON CONFLICT (id) DO UPDATE SET category = EXCLUDED.category, amount = EXCLUDED.amount,
		currency = EXCLUDED.currency, rate = EXCLUDED.rate, day_of_month = EXCLUDED.day_of_month,
		mode = EXCLUDED.mode, counterparty = EXCLUDED.counterparty, note = EXCLUDED.note,
		end_month = EXCLUDED.end_month, skipped = EXCLUDED.skipped, active = EXCLUDED.active,
		updated_at = EXCLUDED.updated_at, stopped_at = EXCLUDED.stopped_at, stopped_by = EXCLUDED.stopped_by`

func (s *PostgresStore) CreateFinanceRecurring(ctx context.Context, r FinanceRecurring) (FinanceRecurring, error) {
	r, err := newFinanceRecurring(r, s.clock.Now())
	if err != nil {
		return FinanceRecurring{}, err
	}
	args, err := financeRecurringArgs(r)
	if err != nil {
		return FinanceRecurring{}, err
	}
	if _, err := s.pool.Exec(ctx, upsertFinanceRecurringSQL, args...); err != nil {
		return FinanceRecurring{}, err
	}
	return r, nil
}

func (s *PostgresStore) ListFinanceRecurring(ctx context.Context) ([]FinanceRecurring, error) {
	rows, err := s.pool.Query(ctx, `SELECT `+financeRecurringColumns+` FROM relay_finance_recurring`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	list := []FinanceRecurring{}
	for rows.Next() {
		r, err := scanFinanceRecurring(rows)
		if err != nil {
			return nil, err
		}
		list = append(list, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sortFinanceRecurring(list)
	return list, nil
}

func (s *PostgresStore) UpdateFinanceRecurring(ctx context.Context, id string, change FinanceRecurringChange) (FinanceRecurring, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return FinanceRecurring{}, err
	}
	defer tx.Rollback(ctx)
	before, err := scanFinanceRecurring(tx.QueryRow(ctx, `SELECT `+financeRecurringColumns+` FROM relay_finance_recurring WHERE id = $1 FOR UPDATE`, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return FinanceRecurring{}, ErrNotFound
	}
	if err != nil {
		return FinanceRecurring{}, err
	}
	after, err := applyFinanceRecurringChange(before, change, s.clock.Now())
	if err != nil {
		return FinanceRecurring{}, err
	}
	args, err := financeRecurringArgs(after)
	if err != nil {
		return FinanceRecurring{}, err
	}
	if _, err := tx.Exec(ctx, upsertFinanceRecurringSQL, args...); err != nil {
		return FinanceRecurring{}, err
	}
	return after, tx.Commit(ctx)
}

func (s *PostgresStore) FinanceRecurringPosted(ctx context.Context) (map[string]map[string]bool, error) {
	rows, err := s.pool.Query(ctx, `SELECT recurring_id, recurring_month FROM relay_finance_entries WHERE recurring_id <> ''`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	posted := map[string]map[string]bool{}
	for rows.Next() {
		var id, month string
		if err := rows.Scan(&id, &month); err != nil {
			return nil, err
		}
		if posted[id] == nil {
			posted[id] = map[string]bool{}
		}
		posted[id][month] = true
	}
	return posted, rows.Err()
}

// --- cache wrapper -----------------------------------------------------------

func (s *CachedInstallationStore) recurringStore() (FinanceRecurringStore, error) {
	store, ok := s.store.(FinanceRecurringStore)
	if !ok {
		return nil, errors.New("finance store is unavailable")
	}
	return store, nil
}

func (s *CachedInstallationStore) CreateFinanceRecurring(ctx context.Context, r FinanceRecurring) (FinanceRecurring, error) {
	store, err := s.recurringStore()
	if err != nil {
		return FinanceRecurring{}, err
	}
	return store.CreateFinanceRecurring(ctx, r)
}

func (s *CachedInstallationStore) ListFinanceRecurring(ctx context.Context) ([]FinanceRecurring, error) {
	store, err := s.recurringStore()
	if err != nil {
		return nil, err
	}
	return store.ListFinanceRecurring(ctx)
}

func (s *CachedInstallationStore) UpdateFinanceRecurring(ctx context.Context, id string, change FinanceRecurringChange) (FinanceRecurring, error) {
	store, err := s.recurringStore()
	if err != nil {
		return FinanceRecurring{}, err
	}
	return store.UpdateFinanceRecurring(ctx, id, change)
}

func (s *CachedInstallationStore) FinanceRecurringPosted(ctx context.Context) (map[string]map[string]bool, error) {
	store, err := s.recurringStore()
	if err != nil {
		return nil, err
	}
	return store.FinanceRecurringPosted(ctx)
}
