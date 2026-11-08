package control

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

func exerciseCustomerOrderReportStore(t *testing.T, store CustomerOrderReportStore) {
	t.Helper()
	ctx := context.Background()
	first, created, err := store.ReportCustomerOrder(ctx, CustomerOrderReport{
		OrderID: "o-1", CustomerID: "c-1", Reason: CustomerReportNotArrived, Note: "  لم يصل  "})
	if err != nil || !created || first.Status != CustomerReportOpen || first.Note != "لم يصل" || first.ID == "" {
		t.Fatalf("first: %+v %v %v", first, created, err)
	}
	again, created, err := store.ReportCustomerOrder(ctx, CustomerOrderReport{
		OrderID: "o-1", CustomerID: "c-1", Reason: CustomerReportOther})
	if err != nil || created || again.ID != first.ID || again.Reason != CustomerReportNotArrived {
		t.Fatalf("one open per order: %+v %v %v", again, created, err)
	}
	if _, _, err := store.ReportCustomerOrder(ctx, CustomerOrderReport{
		OrderID: "o-2", CustomerID: "c-1", Reason: "nope"}); err == nil {
		t.Fatal("an unknown reason was filed")
	}
	other, _, err := store.ReportCustomerOrder(ctx, CustomerOrderReport{
		OrderID: "o-9", CustomerID: "c-2", Reason: CustomerReportWrongAccount})
	if err != nil {
		t.Fatal(err)
	}

	open, err := store.ListCustomerOrderReports(ctx, CustomerOrderReportFilter{Status: CustomerReportOpen})
	if err != nil || len(open) != 2 {
		t.Fatalf("open: %+v %v", open, err)
	}

	resolved, changed, err := store.ResolveCustomerOrderReport(ctx, first.ID, "  أعدنا الشحن  ", "Hatem")
	if err != nil || !changed || resolved.Status != CustomerReportResolved || resolved.Reply != "أعدنا الشحن" ||
		resolved.ResolvedBy != "Hatem" || resolved.ResolvedAt == nil {
		t.Fatalf("resolve: %+v %v %v", resolved, changed, err)
	}
	if again, changed, err := store.ResolveCustomerOrderReport(ctx, first.ID, "x", "y"); err != nil || changed ||
		again.Reply != "أعدنا الشحن" {
		t.Fatalf("resolve again: %+v %v %v", again, changed, err)
	}
	if _, _, err := store.ResolveCustomerOrderReport(ctx, "missing", "", ""); !errors.Is(err, ErrCustomerOrderReportNotFound) {
		t.Fatalf("missing: %v", err)
	}

	// Resolved, the order may be reported again; newest first.
	second, created, err := store.ReportCustomerOrder(ctx, CustomerOrderReport{
		OrderID: "o-1", CustomerID: "c-1", Reason: CustomerReportWrongAmount})
	if err != nil || !created || second.ID == first.ID {
		t.Fatalf("second: %+v %v %v", second, created, err)
	}
	list, err := store.CustomerOrderReports(ctx, "o-1")
	if err != nil || len(list) != 2 || list[0].ID != second.ID {
		t.Fatalf("order's reports: %+v %v", list, err)
	}

	if err := store.ForgetCustomerOrderReports(ctx, "c-1"); err != nil {
		t.Fatal(err)
	}
	if list, _ := store.CustomerOrderReports(ctx, "o-1"); len(list) != 0 {
		t.Fatalf("forgotten: %+v", list)
	}
	if list, _ := store.CustomerOrderReports(ctx, other.OrderID); len(list) != 1 {
		t.Fatalf("another customer's report went too: %+v", list)
	}
}

func TestFileStoreCustomerOrderReports(t *testing.T) {
	store, err := NewFileStore(filepath.Join(t.TempDir(), "relay.json"), nil)
	if err != nil {
		t.Fatal(err)
	}
	exerciseCustomerOrderReportStore(t, store)
}

// Runs against a real PostgreSQL when POINTY_RELAY_TEST_DATABASE_URL names a
// throwaway database.
func TestPostgresStoreCustomerOrderReports(t *testing.T) {
	url := os.Getenv("POINTY_RELAY_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("POINTY_RELAY_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err := MigratePostgres(ctx, pool); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `DELETE FROM relay_customer_order_reports`); err != nil {
		t.Fatal(err)
	}
	exerciseCustomerOrderReportStore(t, &PostgresStore{pool: pool, clock: RealClock{}})
}
