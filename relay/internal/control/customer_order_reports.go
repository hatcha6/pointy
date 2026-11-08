package control

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// A «دفتر كروت» customer reporting a problem with one of their orders (a
// top-up that did not show up in the game, gone to the wrong account): what
// they said, and what an operator answered. An order has at most one open
// report; once it is resolved the customer may report again.

// ErrCustomerOrderReportNotFound is a report this relay does not have.
var ErrCustomerOrderReportNotFound = errors.New("customer order report not found")

// Customer order report reasons, as the app offers them.
const (
	CustomerReportNotArrived   = "not_arrived"
	CustomerReportWrongAccount = "wrong_account"
	CustomerReportWrongAmount  = "wrong_amount"
	CustomerReportOther        = "other"
)

// CustomerReportReasons are the reasons a report may give.
var CustomerReportReasons = map[string]bool{
	CustomerReportNotArrived:   true,
	CustomerReportWrongAccount: true,
	CustomerReportWrongAmount:  true,
	CustomerReportOther:        true,
}

// Customer order report statuses.
const (
	CustomerReportOpen     = "open"
	CustomerReportResolved = "resolved"
)

const (
	maxCustomerReportNote  = 500
	maxCustomerReportReply = 500
)

// CustomerOrderReport is one report about one order.
type CustomerOrderReport struct {
	ID         string `json:"id"`
	OrderID    string `json:"order_id"`
	CustomerID string `json:"customer_id"`
	Reason     string `json:"reason"`
	// Note is the customer's own words, if any.
	Note   string `json:"note,omitempty"`
	Status string `json:"status"`
	// Reply is the operator's answer, shown to the customer on the order.
	Reply      string     `json:"reply,omitempty"`
	ResolvedBy string     `json:"resolved_by,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
	ResolvedAt *time.Time `json:"resolved_at,omitempty"`
}

// CustomerOrderReportFilter narrows the operator's list.
type CustomerOrderReportFilter struct {
	Status string
	Limit  int
}

// CustomerOrderReportStore is an optional store capability (type-asserted).
type CustomerOrderReportStore interface {
	// ReportCustomerOrder files a report, or returns the order's open one
	// unchanged (created=false): a second tap never files twice.
	ReportCustomerOrder(ctx context.Context, report CustomerOrderReport) (CustomerOrderReport, bool, error)
	// CustomerOrderReports is an order's reports, newest first.
	CustomerOrderReports(ctx context.Context, orderID string) ([]CustomerOrderReport, error)
	// ListCustomerOrderReports is every report, newest first.
	ListCustomerOrderReports(ctx context.Context, filter CustomerOrderReportFilter) ([]CustomerOrderReport, error)
	// ResolveCustomerOrderReport closes a report with the operator's reply;
	// resolving it again changes nothing (resolved=false).
	ResolveCustomerOrderReport(ctx context.Context, id, reply, actor string) (CustomerOrderReport, bool, error)
	// ForgetCustomerOrderReports removes a customer's reports when they delete
	// their account.
	ForgetCustomerOrderReports(ctx context.Context, customerID string) error
}

var (
	_ CustomerOrderReportStore = (*FileStore)(nil)
	_ CustomerOrderReportStore = (*PostgresStore)(nil)
	_ CustomerOrderReportStore = (*CachedInstallationStore)(nil)
)

func normalizeCustomerOrderReport(report CustomerOrderReport) (CustomerOrderReport, error) {
	report.OrderID = strings.TrimSpace(report.OrderID)
	report.Reason = strings.TrimSpace(report.Reason)
	report.Note = truncateRunes(strings.TrimSpace(report.Note), maxCustomerReportNote)
	if report.OrderID == "" || report.CustomerID == "" || !CustomerReportReasons[report.Reason] {
		return CustomerOrderReport{}, errors.New("a report needs an order, a customer and a known reason")
	}
	report.Status = CustomerReportOpen
	report.Reply, report.ResolvedBy, report.ResolvedAt = "", "", nil
	if report.ID == "" {
		id, err := NewInstallationID()
		if err != nil {
			return CustomerOrderReport{}, err
		}
		report.ID = id
	}
	return report, nil
}

func sortCustomerOrderReports(list []CustomerOrderReport) {
	sort.SliceStable(list, func(i, j int) bool {
		if !list[i].CreatedAt.Equal(list[j].CreatedAt) {
			return list[i].CreatedAt.After(list[j].CreatedAt)
		}
		return list[i].ID > list[j].ID
	})
}

// --- file store ------------------------------------------------------------

func (s *FileStore) ReportCustomerOrder(_ context.Context, report CustomerOrderReport) (CustomerOrderReport, bool, error) {
	report, err := normalizeCustomerOrderReport(report)
	if err != nil {
		return CustomerOrderReport{}, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, existing := range s.data.CustomerOrderReports {
		if existing.OrderID == report.OrderID && existing.Status == CustomerReportOpen {
			return existing, false, nil
		}
	}
	report.CreatedAt = s.clock.Now()
	if s.data.CustomerOrderReports == nil {
		s.data.CustomerOrderReports = map[string]CustomerOrderReport{}
	}
	s.data.CustomerOrderReports[report.ID] = report
	if err := s.saveLocked(); err != nil {
		delete(s.data.CustomerOrderReports, report.ID)
		return CustomerOrderReport{}, false, err
	}
	return report, true, nil
}

func (s *FileStore) CustomerOrderReports(_ context.Context, orderID string) ([]CustomerOrderReport, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	list := make([]CustomerOrderReport, 0)
	for _, report := range s.data.CustomerOrderReports {
		if report.OrderID == orderID {
			list = append(list, report)
		}
	}
	sortCustomerOrderReports(list)
	return list, nil
}

func (s *FileStore) ListCustomerOrderReports(_ context.Context, filter CustomerOrderReportFilter) ([]CustomerOrderReport, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	list := make([]CustomerOrderReport, 0)
	for _, report := range s.data.CustomerOrderReports {
		if filter.Status == "" || report.Status == filter.Status {
			list = append(list, report)
		}
	}
	sortCustomerOrderReports(list)
	if filter.Limit > 0 && len(list) > filter.Limit {
		list = list[:filter.Limit]
	}
	return list, nil
}

func (s *FileStore) ResolveCustomerOrderReport(_ context.Context, id, reply, actor string) (CustomerOrderReport, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	report, ok := s.data.CustomerOrderReports[id]
	if !ok {
		return CustomerOrderReport{}, false, ErrCustomerOrderReportNotFound
	}
	if report.Status == CustomerReportResolved {
		return report, false, nil
	}
	previous := report
	now := s.clock.Now()
	report.Status = CustomerReportResolved
	report.Reply = truncateRunes(strings.TrimSpace(reply), maxCustomerReportReply)
	report.ResolvedBy = strings.TrimSpace(actor)
	report.ResolvedAt = &now
	s.data.CustomerOrderReports[id] = report
	if err := s.saveLocked(); err != nil {
		s.data.CustomerOrderReports[id] = previous
		return CustomerOrderReport{}, false, err
	}
	return report, true, nil
}

func (s *FileStore) ForgetCustomerOrderReports(_ context.Context, customerID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	removed := map[string]CustomerOrderReport{}
	for id, report := range s.data.CustomerOrderReports {
		if report.CustomerID == customerID {
			removed[id] = report
			delete(s.data.CustomerOrderReports, id)
		}
	}
	if len(removed) == 0 {
		return nil
	}
	if err := s.saveLocked(); err != nil {
		for id, report := range removed {
			s.data.CustomerOrderReports[id] = report
		}
		return err
	}
	return nil
}

// --- Postgres --------------------------------------------------------------

const customerOrderReportColumns = `id, order_id, customer_id, reason, note, status, reply, resolved_by,
	created_at, resolved_at`

func scanCustomerOrderReport(row pgx.Row) (CustomerOrderReport, error) {
	var report CustomerOrderReport
	err := row.Scan(&report.ID, &report.OrderID, &report.CustomerID, &report.Reason, &report.Note, &report.Status,
		&report.Reply, &report.ResolvedBy, &report.CreatedAt, &report.ResolvedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return CustomerOrderReport{}, ErrCustomerOrderReportNotFound
	}
	return report, err
}

func (s *PostgresStore) queryCustomerOrderReports(ctx context.Context, sql string, args ...any) ([]CustomerOrderReport, error) {
	rows, err := s.pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	list := make([]CustomerOrderReport, 0)
	for rows.Next() {
		report, err := scanCustomerOrderReport(rows)
		if err != nil {
			return nil, err
		}
		list = append(list, report)
	}
	return list, rows.Err()
}

func (s *PostgresStore) ReportCustomerOrder(ctx context.Context, report CustomerOrderReport) (CustomerOrderReport, bool, error) {
	report, err := normalizeCustomerOrderReport(report)
	if err != nil {
		return CustomerOrderReport{}, false, err
	}
	// The partial unique index keeps one open report per order, whichever
	// relay node files it.
	created, err := scanCustomerOrderReport(s.pool.QueryRow(ctx, `
INSERT INTO relay_customer_order_reports (id, order_id, customer_id, reason, note, status, created_at)
VALUES ($1, $2, $3, $4, $5, 'open', $6)
ON CONFLICT (order_id) WHERE status = 'open' DO NOTHING
RETURNING `+customerOrderReportColumns,
		report.ID, report.OrderID, report.CustomerID, report.Reason, report.Note, s.clock.Now()))
	if err == nil {
		return created, true, nil
	}
	if !errors.Is(err, ErrCustomerOrderReportNotFound) {
		return CustomerOrderReport{}, false, err
	}
	existing, err := scanCustomerOrderReport(s.pool.QueryRow(ctx, `SELECT `+customerOrderReportColumns+`
FROM relay_customer_order_reports WHERE order_id = $1 AND status = 'open'`, report.OrderID))
	return existing, false, err
}

func (s *PostgresStore) CustomerOrderReports(ctx context.Context, orderID string) ([]CustomerOrderReport, error) {
	return s.queryCustomerOrderReports(ctx, `SELECT `+customerOrderReportColumns+`
FROM relay_customer_order_reports WHERE order_id = $1 ORDER BY created_at DESC, id DESC`, orderID)
}

func (s *PostgresStore) ListCustomerOrderReports(ctx context.Context, filter CustomerOrderReportFilter) ([]CustomerOrderReport, error) {
	limit := filter.Limit
	if limit <= 0 {
		limit = 500
	}
	return s.queryCustomerOrderReports(ctx, `SELECT `+customerOrderReportColumns+`
FROM relay_customer_order_reports WHERE ($1 = '' OR status = $1)
ORDER BY created_at DESC, id DESC LIMIT $2`, filter.Status, limit)
}

func (s *PostgresStore) ResolveCustomerOrderReport(ctx context.Context, id, reply, actor string) (CustomerOrderReport, bool, error) {
	resolved, err := scanCustomerOrderReport(s.pool.QueryRow(ctx, `
UPDATE relay_customer_order_reports SET status = 'resolved', reply = $2, resolved_by = $3, resolved_at = $4
WHERE id = $1 AND status = 'open'
RETURNING `+customerOrderReportColumns,
		id, truncateRunes(strings.TrimSpace(reply), maxCustomerReportReply), strings.TrimSpace(actor), s.clock.Now()))
	if err == nil {
		return resolved, true, nil
	}
	if !errors.Is(err, ErrCustomerOrderReportNotFound) {
		return CustomerOrderReport{}, false, err
	}
	existing, err := scanCustomerOrderReport(s.pool.QueryRow(ctx, `SELECT `+customerOrderReportColumns+`
FROM relay_customer_order_reports WHERE id = $1`, id))
	return existing, false, err
}

func (s *PostgresStore) ForgetCustomerOrderReports(ctx context.Context, customerID string) error {
	_, err := s.pool.Exec(ctx, `DELETE FROM relay_customer_order_reports WHERE customer_id = $1`, customerID)
	return err
}

// --- the cached store forwards it all ---------------------------------------

func (s *CachedInstallationStore) customerOrderReportStore() (CustomerOrderReportStore, error) {
	store, ok := s.store.(CustomerOrderReportStore)
	if !ok {
		return nil, errCustomersUnsupported
	}
	return store, nil
}

func (s *CachedInstallationStore) ReportCustomerOrder(ctx context.Context, report CustomerOrderReport) (CustomerOrderReport, bool, error) {
	store, err := s.customerOrderReportStore()
	if err != nil {
		return CustomerOrderReport{}, false, err
	}
	return store.ReportCustomerOrder(ctx, report)
}

func (s *CachedInstallationStore) CustomerOrderReports(ctx context.Context, orderID string) ([]CustomerOrderReport, error) {
	store, err := s.customerOrderReportStore()
	if err != nil {
		return nil, err
	}
	return store.CustomerOrderReports(ctx, orderID)
}

func (s *CachedInstallationStore) ListCustomerOrderReports(ctx context.Context, filter CustomerOrderReportFilter) ([]CustomerOrderReport, error) {
	store, err := s.customerOrderReportStore()
	if err != nil {
		return nil, err
	}
	return store.ListCustomerOrderReports(ctx, filter)
}

func (s *CachedInstallationStore) ResolveCustomerOrderReport(ctx context.Context, id, reply, actor string) (CustomerOrderReport, bool, error) {
	store, err := s.customerOrderReportStore()
	if err != nil {
		return CustomerOrderReport{}, false, err
	}
	return store.ResolveCustomerOrderReport(ctx, id, reply, actor)
}

func (s *CachedInstallationStore) ForgetCustomerOrderReports(ctx context.Context, customerID string) error {
	store, err := s.customerOrderReportStore()
	if err != nil {
		return err
	}
	return store.ForgetCustomerOrderReports(ctx, customerID)
}
