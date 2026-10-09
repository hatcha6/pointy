package services

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"pointy/relay/internal/reloadly"
)

// flakySource serves the fixture, can be told to fail, and counts its reads.
type flakySource struct {
	mu     sync.Mutex
	fail   error
	edit   func(*Raw)
	loaded atomic.Int64
}

func (s *flakySource) Load(ctx context.Context) (Raw, error) {
	s.loaded.Add(1)
	s.mu.Lock()
	fail, edit := s.fail, s.edit
	s.mu.Unlock()
	if fail != nil {
		return Raw{}, fail
	}
	raw, err := FixtureSource{}.Load(ctx)
	if err == nil && edit != nil {
		edit(&raw)
	}
	return raw, err
}

func (s *flakySource) set(fail error, edit func(*Raw)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fail, s.edit = fail, edit
}

type movingClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *movingClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *movingClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

func TestTheLastGoodDirectoryStandsWhenTheSupplierFails(t *testing.T) {
	source := &flakySource{}
	clock := &movingClock{now: time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)}
	service := New(Config{Source: source, TestMode: true, Namer: fakeNames{}, Now: clock.Now})
	in := pricing(t, "9.71")
	first, err := service.Directory(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}

	clock.advance(15 * time.Minute)
	source.set(errors.New("reloadly is down"), nil)
	if err := service.Refresh(context.Background()); err == nil {
		t.Fatal("a failed reading is reported")
	}
	again, err := service.Directory(context.Background(), in)
	if err != nil || again != first {
		t.Fatalf("the last good directory stands: %v", err)
	}
	stats := service.Stats()
	if stats.LastError != "reloadly is down" || !stats.Loaded || stats.Build.Operators == 0 {
		t.Fatalf("stats: %+v", stats)
	}

	// Nothing new at the supplier: the same directory, with the same moment.
	source.set(nil, nil)
	clock.advance(15 * time.Minute)
	if err := service.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	same, _ := service.Directory(context.Background(), in)
	if same != first || !same.View.GeneratedAt.Equal(first.View.GeneratedAt) {
		t.Fatal("a reading that found nothing new changes nothing, not even the moment")
	}
	if got := service.Stats(); got.LastError != "" || got.ReadAt == nil || !got.ReadAt.Equal(clock.Now()) {
		t.Fatalf("a good reading clears the error and notes the time: %+v", got)
	}

	// Something new: a new directory, a new version, a new moment.
	source.set(nil, func(raw *Raw) {
		for i := range raw.Operators {
			if raw.Operators[i].Key() == 289 {
				raw.Operators[i].Name = "Orange Mali Plus"
			}
		}
	})
	clock.advance(15 * time.Minute)
	if err := service.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	changed, _ := service.Directory(context.Background(), in)
	if changed.Version == first.Version || !changed.View.GeneratedAt.Equal(clock.Now().Truncate(time.Second)) {
		t.Fatalf("a change moves the version and the moment: %s -> %s", first.Version, changed.Version)
	}
}

func TestTheFirstReadIsLazyAndRetriedAfterAFailure(t *testing.T) {
	source := &flakySource{}
	source.set(errors.New("reloadly is down"), nil)
	clock := &movingClock{now: time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)}
	service := New(Config{Source: source, TestMode: true, Namer: fakeNames{}, Now: clock.Now})
	in := pricing(t, "9.71")

	if _, err := service.Directory(context.Background(), in); err == nil {
		t.Fatal("nothing has ever been read: the directory is unavailable")
	}
	// A request right after does not hammer the supplier again.
	if _, err := service.Directory(context.Background(), in); err == nil {
		t.Fatal("still unavailable")
	}
	if source.loaded.Load() != 1 {
		t.Fatalf("one failed reading, then patience: %d", source.loaded.Load())
	}
	// Quotes and orders say why.
	if _, refusal := service.Quote(context.Background(), in, QuoteRequest{Kind: "airtime", OperatorID: 289, Amount: "5000"}); refusal == nil ||
		refusal.Code != CodeServiceUnavailable || refusal.Extra["reason"] != ReasonDirectoryUnavailable || refusal.Status != 409 {
		t.Fatalf("quote while unavailable: %v", refusal)
	}
	if _, refusal := service.PrepareOrder(context.Background(), in, OrderRequest{Kind: "airtime", OperatorID: 289, Amount: "5000", AmountCurrency: "XOF"}); refusal == nil ||
		refusal.Code != CodeServiceUnavailable {
		t.Fatalf("order while unavailable: %v", refusal)
	}
	if _, refusal := service.Detect(context.Background(), in, "ML", "70123456"); refusal == nil || refusal.Code != CodeServiceUnavailable {
		t.Fatalf("detect while unavailable: %v", refusal)
	}

	source.set(nil, nil)
	clock.advance(11 * time.Second)
	if _, err := service.Directory(context.Background(), in); err != nil {
		t.Fatalf("recovered: %v", err)
	}
}

func TestTheBackgroundWorkerReadsAgainAndStops(t *testing.T) {
	source := &flakySource{}
	service := New(Config{Source: source, TestMode: true, Namer: fakeNames{}, Interval: 5 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		service.Run(ctx)
		close(done)
	}()
	deadline := time.After(5 * time.Second)
	for source.loaded.Load() < 3 {
		select {
		case <-deadline:
			t.Fatalf("the worker reads again and again: %d readings", source.loaded.Load())
		case <-time.After(time.Millisecond):
		}
	}
	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("the worker must stop when its context ends")
	}

	// An interval of zero is once.
	once := &flakySource{}
	oneShot := New(Config{Source: once, TestMode: true, Namer: fakeNames{}, Interval: 0})
	finished := make(chan struct{})
	go func() {
		oneShot.Run(context.Background())
		close(finished)
	}()
	select {
	case <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("with no interval the worker reads once and returns")
	}
	if once.loaded.Load() != 1 {
		t.Fatalf("once: %d", once.loaded.Load())
	}
	// An unconfigured service has nothing to do.
	New(Config{}).Run(context.Background())
}

func TestConcurrentFirstReadsShareOneReading(t *testing.T) {
	source := &flakySource{}
	service := New(Config{Source: source, TestMode: true, Namer: fakeNames{}})
	in := pricing(t, "9.71")
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := service.Directory(context.Background(), in); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if source.loaded.Load() != 1 {
		t.Fatalf("twelve first requests, one reading: %d", source.loaded.Load())
	}
}

func TestOnlyPlainActiveAirtimeIsOnTheShelf(t *testing.T) {
	source := &flakySource{}
	source.set(nil, func(raw *Raw) {
		base := raw.Operators[0]
		variant := func(id int64, change func(*reloadly.Operator)) {
			op := base
			op.ID, op.OperatorID = id, id
			op.Name = "Variant"
			change(&op)
			raw.Operators = append(raw.Operators, op)
		}
		variant(9001, func(o *reloadly.Operator) { o.Data = true })
		variant(9002, func(o *reloadly.Operator) { o.Bundle = true })
		variant(9003, func(o *reloadly.Operator) { o.ComboProduct = true })
		variant(9004, func(o *reloadly.Operator) { o.Pin = true })
		variant(9005, func(o *reloadly.Operator) { o.Status = "INACTIVE" })
		variant(9006, func(o *reloadly.Operator) {})
	})
	service := New(Config{Source: source, TestMode: true, Namer: fakeNames{}})
	snap, err := service.current(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []int64{9001, 9002, 9003, 9004, 9005} {
		if _, listed := snap.operators[id]; listed {
			t.Errorf("operator %d is not plain, active airtime and must not be sold", id)
		}
	}
	if _, listed := snap.operators[9006]; !listed {
		t.Error("a plain active operator is sold")
	}
}
