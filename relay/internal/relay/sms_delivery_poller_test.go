package relay

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"sort"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/observability"
	"pointy/relay/internal/resala"
)

func ledgerRow(id, recipient string, sentAt time.Time, content string) control.SMSMessage {
	row := control.SMSMessage{ID: id, Recipient: recipient, CreatedAt: sentAt.Add(-time.Second), SentAt: &sentAt}
	if content != "" {
		row.ContentSHA256 = smsContentSHA256(content)
	}
	return row
}

func logRow(id, number, content, status string, createdAt time.Time) resala.SentMessage {
	return resala.SentMessage{
		ID:        id,
		Code:      "218",
		Region:    "LY",
		Number:    number,
		Content:   content,
		Source:    "message",
		Env:       "production",
		Status:    status,
		CreatedAt: createdAt,
	}
}

func matchedPairs(matches []smsDeliveryMatch) map[string]string {
	pairs := map[string]string{}
	for _, match := range matches {
		pairs[match.Message.ID] = match.Row.ID
	}
	return pairs
}

func TestMatchSMSDeliveriesPrefersContentThenNearestTime(t *testing.T) {
	t0 := time.Date(2026, 9, 27, 10, 0, 0, 0, time.UTC)
	candidates := []control.SMSMessage{
		ledgerRow("c1", "218912345678", t0, "alpha"),
		ledgerRow("c2", "218912345678", t0.Add(2*time.Minute), "beta"),
		ledgerRow("c3", "218923456789", t0, ""),
		ledgerRow("c4", "218945555555", t0, "gamma"),
	}
	pinned := ledgerRow("c5", "218912345000", t0, "delta")
	pinned.ProviderMessageID = "p-5"
	candidates = append(candidates, pinned)

	testRow := logRow("r8", "912345678", "alpha", "Delivered", t0)
	testRow.Env = "development"
	rows := []resala.SentMessage{
		// Nearer in time to c1, but its content is c2's.
		logRow("r1", "912345678", "beta", "Delivered", t0.Add(10*time.Second)),
		logRow("r2", "912345678", "alpha", "Delivered", t0.Add(2*time.Minute+10*time.Second)),
		logRow("r3", "923456789", "x", "sent", t0.Add(30*time.Second)),
		logRow("r4", "923456789", "x", "sent", t0.Add(5*time.Minute)),
		// Eleven minutes out: not the same message.
		logRow("r5", "945555555", "gamma", "Delivered", t0.Add(11*time.Minute)),
		// c5 is pinned to p-5, however far away it is and whatever is nearer.
		logRow("p-5", "912345000", "delta", "Delivered", t0.Add(30*time.Minute)),
		logRow("p-7", "912345000", "delta", "Delivered", t0),
		// A test send never matches a real one.
		testRow,
	}
	got := matchedPairs(matchSMSDeliveries(candidates, rows))
	want := map[string]string{"c1": "r2", "c2": "r1", "c3": "r3", "c5": "p-5"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for candidate, row := range want {
		if got[candidate] != row {
			t.Fatalf("%s matched %q, want %q (all: %v)", candidate, got[candidate], row, got)
		}
	}
}

func TestMatchSMSDeliveriesUsesEachRowOnce(t *testing.T) {
	t0 := time.Date(2026, 9, 27, 10, 0, 0, 0, time.UTC)
	candidates := []control.SMSMessage{
		ledgerRow("far", "218912345678", t0.Add(-4*time.Minute), ""),
		ledgerRow("near", "218912345678", t0, ""),
	}
	rows := []resala.SentMessage{logRow("only", "912345678", "", "Delivered", t0.Add(20*time.Second))}
	got := matchedPairs(matchSMSDeliveries(candidates, rows))
	if len(got) != 1 || got["near"] != "only" {
		t.Fatalf("one log row belongs to one message, the nearest: %v", got)
	}
}

func TestMatchSMSDeliveriesReadsEveryNumberForm(t *testing.T) {
	t0 := time.Date(2026, 9, 27, 10, 0, 0, 0, time.UTC)
	candidates := []control.SMSMessage{
		ledgerRow("a", "218911111111", t0, ""),
		ledgerRow("b", "218922222222", t0, ""),
		ledgerRow("c", "218933333333", t0, ""),
		ledgerRow("d", "218944444444", t0, ""),
	}
	national := logRow("ra", "911111111", "", "Delivered", t0)
	full := logRow("rb", "218922222222", "", "Delivered", t0)
	trunk := logRow("rc", "0933333333", "", "Delivered", t0)
	split := logRow("rd", "944444444", "", "Delivered", t0)
	split.Code = "218"
	other := logRow("rx", "944444444", "", "Delivered", t0)
	other.Code = "20"
	other.Number = "1044444444" // an Egyptian number: never ours
	got := matchedPairs(matchSMSDeliveries(candidates, []resala.SentMessage{national, full, trunk, split, other}))
	if len(got) != 4 || got["a"] != "ra" || got["b"] != "rb" || got["c"] != "rc" || got["d"] != "rd" {
		t.Fatalf("unexpected matches %v", got)
	}
}

func TestSMSDeliveryStatusMapping(t *testing.T) {
	cases := map[string]struct {
		status string
		known  bool
	}{
		"delivered":   {control.SMSStatusDelivered, true},
		"Delivered":   {control.SMSStatusDelivered, true},
		" DELIVERED ": {control.SMSStatusDelivered, true},
		"undelivered": {control.SMSStatusUndelivered, true},
		"Failed":      {control.SMSStatusUndelivered, true},
		"rejected":    {control.SMSStatusUndelivered, true},
		"Expired":     {control.SMSStatusUndelivered, true},
		"Sent":        {control.SMSStatusSent, true},
		"":            {"", false},
		"null":        {"", false},
		"accepted":    {"", false},
		"queued":      {"", false},
	}
	for raw, want := range cases {
		status, known := smsDeliveryStatus(raw)
		if status != want.status || known != want.known {
			t.Errorf("smsDeliveryStatus(%q) = %q, %v; want %q, %v", raw, status, known, want.status, want.known)
		}
	}
}

type fakeSentLister struct {
	pages map[int]resala.SentPage
	err   error
	calls []resala.SentQuery
}

func (f *fakeSentLister) ListSent(_ context.Context, query resala.SentQuery) (resala.SentPage, error) {
	f.calls = append(f.calls, query)
	if f.err != nil {
		return resala.SentPage{}, f.err
	}
	return f.pages[query.Page], nil
}

type deliveryFixture struct {
	store  *control.FileStore
	now    time.Time
	sentAt time.Time
}

func newDeliveryFixture(t *testing.T) *deliveryFixture {
	t.Helper()
	now := time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), testClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	return &deliveryFixture{store: store, now: now, sentAt: now.Add(-30 * time.Minute)}
}

// sent puts a real, sent message in the ledger, as the send handler would.
func (f *deliveryFixture) sent(t *testing.T, key, recipient, content string, test bool) control.SMSMessage {
	t.Helper()
	ctx := context.Background()
	claim, _, err := f.store.BeginSMS(ctx, control.SMSMessage{
		InstallationID: "shop",
		IdempotencyKey: key,
		Kind:           "invoice",
		Recipient:      recipient,
		TemplateID:     "tpl",
		TestMode:       test,
		CreatedAt:      f.sentAt.Add(-time.Second),
	}, control.SMSClaimLimit{})
	if err != nil {
		t.Fatal(err)
	}
	sentAt := f.sentAt
	finished, _, err := f.store.FinishSMS(ctx, claim.ID, control.SMSOutcome{
		Status:        control.SMSStatusSent,
		Cost:          "0.1",
		ContentSHA256: smsContentSHA256(content),
		TestMode:      test,
		SentAt:        &sentAt,
	})
	if err != nil {
		t.Fatal(err)
	}
	return finished
}

func (f *deliveryFixture) row(t *testing.T, id string) control.SMSMessage {
	t.Helper()
	rows, err := f.store.GetSMSByIDs(context.Background(), "shop", []string{id})
	if err != nil || len(rows) != 1 {
		t.Fatalf("row %s: %v %v", id, rows, err)
	}
	return rows[0]
}

func TestSMSDeliveryPollerAppliesReports(t *testing.T) {
	f := newDeliveryFixture(t)
	delivered := f.sent(t, "a", "218911111111", "hello a", false)
	failed := f.sent(t, "b", "218922222222", "hello b", false)
	stillSent := f.sent(t, "c", "218933333333", "hello c", false)
	quiet := f.sent(t, "d", "218944444444", "hello d", false)
	f.sent(t, "t", "218955555555", "hello t", true)

	reportedAt := f.sentAt.Add(40 * time.Second)
	deliveredRow := logRow("ra", "911111111", "hello a", "Delivered", f.sentAt.Add(5*time.Second))
	deliveredRow.UpdatedAt = reportedAt
	lister := &fakeSentLister{pages: map[int]resala.SentPage{
		1: {CurrentPage: 1, LastPage: 1, Messages: []resala.SentMessage{
			deliveredRow,
			logRow("rb", "922222222", "hello b", "FAILED", f.sentAt.Add(5*time.Second)),
			logRow("rc", "933333333", "hello c", "sent", f.sentAt.Add(5*time.Second)),
			logRow("rd", "944444444", "hello d", "", f.sentAt.Add(5*time.Second)),
			logRow("rt", "955555555", "hello t", "Delivered", f.sentAt.Add(5*time.Second)),
		}},
	}}
	metrics := observability.NewMetrics()
	poller := &SMSDeliveryPoller{Client: lister, Store: f.store, Clock: testClock{now: f.now}, Metrics: metrics}

	result, err := poller.SyncOnce(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if result.Candidates != 4 || result.Matched != 3 || result.Delivered != 1 || result.Undelivered != 1 || result.Tagged != 1 {
		t.Fatalf("unexpected sync result %+v", result)
	}
	if len(lister.calls) != 1 || lister.calls[0].Source != "message" || lister.calls[0].PerPage != 100 {
		t.Fatalf("unexpected log queries %+v", lister.calls)
	}

	if row := f.row(t, delivered.ID); row.Status != control.SMSStatusDelivered || row.ProviderMessageID != "ra" ||
		row.DeliveredAt == nil || !row.DeliveredAt.Equal(reportedAt) {
		t.Fatalf("expected delivered with Resala's report time, got %+v", row)
	}
	if row := f.row(t, failed.ID); row.Status != control.SMSStatusUndelivered || row.ProviderMessageID != "rb" {
		t.Fatalf("expected undelivered, got %+v", row)
	}
	if row := f.row(t, stillSent.ID); row.Status != control.SMSStatusSent || row.ProviderMessageID != "rc" {
		t.Fatalf("expected sent and pinned to its log row, got %+v", row)
	}
	if row := f.row(t, quiet.ID); row.Status != control.SMSStatusSent || row.ProviderMessageID != "" {
		t.Fatalf("a row the carrier has not reported stays untouched, got %+v", row)
	}
	counts := metrics.Snapshot().SMSDeliveriesByOutcome
	if counts["delivered"] != 1 || counts["undelivered"] != 1 || counts["sent"] != 1 {
		t.Fatalf("unexpected delivery counters %v", counts)
	}

	// The next sync has nothing new: the pinned row is still merely sent.
	again, err := poller.SyncOnce(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if again.Candidates != 2 || again.Matched != 0 {
		t.Fatalf("expected nothing new, got %+v", again)
	}
}

func TestSMSDeliveryPollerStopsPagingPastTheOldestCandidate(t *testing.T) {
	f := newDeliveryFixture(t)
	f.sent(t, "a", "218911111111", "hello", false)

	// Pages of 100 rows going back one minute per row; the candidate was sent
	// 30 minutes ago, so page 1 (rows 0-99 min old) already reaches past it
	// minus the 15-minute slack.
	pages := map[int]resala.SentPage{}
	for page := 1; page <= 20; page++ {
		var rows []resala.SentMessage
		for i := 0; i < 100; i++ {
			age := time.Duration((page-1)*100+i) * time.Minute
			rows = append(rows, logRow(fmt.Sprintf("r%d-%d", page, i), "900000000", "", "sent", f.now.Add(-age)))
		}
		pages[page] = resala.SentPage{CurrentPage: page, LastPage: 20, Messages: rows}
	}
	lister := &fakeSentLister{pages: pages}
	poller := &SMSDeliveryPoller{Client: lister, Store: f.store, Clock: testClock{now: f.now}}
	if _, err := poller.SyncOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(lister.calls) != 1 {
		t.Fatalf("expected paging to stop after page 1, read %d pages", len(lister.calls))
	}

	// When every row is newer than the candidate, paging stops at ten pages.
	for page := range pages {
		for i := range pages[page].Messages {
			pages[page].Messages[i].CreatedAt = f.now
		}
	}
	lister.calls = nil
	if _, err := poller.SyncOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(lister.calls) != 10 {
		t.Fatalf("expected the ten-page ceiling, read %d pages", len(lister.calls))
	}

	// And a short log stops at its last page.
	lister.calls = nil
	lister.pages = map[int]resala.SentPage{1: {CurrentPage: 1, LastPage: 2, Messages: pages[1].Messages}, 2: {CurrentPage: 2, LastPage: 2}}
	if _, err := poller.SyncOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	pagesRead := make([]int, 0, len(lister.calls))
	for _, call := range lister.calls {
		pagesRead = append(pagesRead, call.Page)
	}
	sort.Ints(pagesRead)
	if len(pagesRead) != 2 || pagesRead[1] != 2 {
		t.Fatalf("expected pages 1-2, read %v", pagesRead)
	}
}

func TestSMSDeliveryPollerLeavesTheProviderAloneWhenNothingAwaits(t *testing.T) {
	f := newDeliveryFixture(t)
	f.sent(t, "t", "218955555555", "test", true)
	lister := &fakeSentLister{}
	poller := &SMSDeliveryPoller{Client: lister, Store: f.store, Clock: testClock{now: f.now}}
	result, err := poller.SyncOnce(context.Background())
	if err != nil || result.Candidates != 0 {
		t.Fatalf("unexpected result %+v %v", result, err)
	}
	if len(lister.calls) != 0 {
		t.Fatal("nothing to reconcile means no call to Resala")
	}
}

func TestSMSDeliveryPollerReportsAProviderFailure(t *testing.T) {
	f := newDeliveryFixture(t)
	message := f.sent(t, "a", "218911111111", "hello", false)
	lister := &fakeSentLister{err: resala.ErrUnauthorized}
	poller := &SMSDeliveryPoller{Client: lister, Store: f.store, Clock: testClock{now: f.now}}
	if _, err := poller.SyncOnce(context.Background()); !errors.Is(err, resala.ErrUnauthorized) {
		t.Fatalf("expected the provider error, got %v", err)
	}
	if row := f.row(t, message.ID); row.Status != control.SMSStatusSent {
		t.Fatalf("a failed sync changes nothing, got %+v", row)
	}
}

func TestSMSDeliveryPollerInterval(t *testing.T) {
	cases := map[time.Duration]time.Duration{
		0:                defaultSMSDeliverySyncInterval,
		time.Second:      minSMSDeliverySyncInterval,
		10 * time.Minute: 10 * time.Minute,
	}
	for configured, want := range cases {
		if got := (&SMSDeliveryPoller{Interval: configured}).interval(); got != want {
			t.Fatalf("interval(%s) = %s, want %s", configured, got, want)
		}
	}
	var poller *SMSDeliveryPoller
	if poller.Enabled() || (&SMSDeliveryPoller{Client: &fakeSentLister{}}).Enabled() {
		t.Fatal("a poller without a client and a store is disabled")
	}
}
