package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"pointy/relay/internal/vouchers"
)

// Detector finds the operator a phone number belongs to, by asking the supplier.
type Detector interface {
	// Detect returns the id of the operator of a number; ErrNotDetected when the
	// supplier cannot tell. Any other error means the supplier could not be asked.
	Detect(ctx context.Context, country string, phone Phone) (int64, error)
}

// ErrNotDetected is a number no operator could be found for.
var ErrNotDetected = errors.New("no operator could be detected for this number")

// Defaults of the service's timings.
const (
	DefaultRefreshInterval = 15 * time.Minute
	DefaultLoadTimeout     = 3 * time.Minute
	DefaultRequestTimeout  = 45 * time.Second
	DefaultSettleWait      = 20 * time.Second
	// retryAfterFailedLoad is how long a lazily warmed directory waits before it
	// asks the supplier again after a failed first read.
	retryAfterFailedLoad = 10 * time.Second
	// retryAfterFailedRefresh is how soon the background worker reads again
	// after a failure, whatever its interval.
	retryAfterFailedRefresh = time.Minute
	maxRenderedKept         = 8
	// staleIntervals and minimumStaleAfter: a directory whose last good reading
	// is older than this many refresh intervals (and never less than the
	// minimum) is no longer sold from, however long the supplier has been down.
	staleIntervals    = 3
	minimumStaleAfter = 45 * time.Minute
	// maxNoted bounds the memory of Every.
	maxNoted = 4096
)

// Config wires a Service.
type Config struct {
	// Source is where the directory comes from: Reloadly, or the fixture in test
	// mode without Reloadly. Nil leaves the service unconfigured.
	Source Source
	// Detector finds an operator by number: Reloadly, or nothing (the fake of test
	// mode is used).
	Detector Detector
	// Reloadly buys and reads back real orders. Nil when Reloadly is not
	// configured.
	Reloadly Executor
	// Balances reads the company's balance at the supplier, for the operator.
	Balances BalanceReader
	// TestMode sells every order from the fake supplier instead: nothing is
	// bought, the shop's balance is still charged.
	TestMode bool
	// TargetKey is the secret that keys the digest of an order's target (see
	// target.go). Empty keeps no digest, and a replay is then judged by the masked
	// target alone.
	TargetKey []byte
	// Sandbox says Reloadly is its SANDBOX (fake money): orders really go there,
	// and everything that reaches a shop (the directory, the ledger row, the
	// statement entry, the receipt) is marked as a test all the same.
	Sandbox bool
	// Namer gives the Arabic names; nil uses the relay's tables.
	Namer Namer
	// Interval is how often the supplier is read again; zero reads it once (and
	// then the directory never goes stale). With an interval, a directory whose
	// last good reading is older than three of them (at least 45 minutes) is no
	// longer sold from: quotes and orders are refused until it is read again.
	Interval time.Duration
	// LoadTimeout bounds one reading of the whole directory.
	LoadTimeout time.Duration
	// RequestTimeout bounds one order's call to the supplier; SettleWait is how
	// long the executor then waits for an accepted order to finish before it
	// is left to the reconciler.
	RequestTimeout time.Duration
	SettleWait     time.Duration
	Logger         *slog.Logger
	// Now is the clock; nil is time.Now.
	Now func() time.Time
}

// Service is the services directory and everything built on it: detection,
// quotes and the preparation of orders. The HTTP layer owns the ledger and
// calls it.
type Service struct {
	cfg      Config
	namer    Namer
	test     *TestExecutor
	selling  Executor
	supplier string

	mu      sync.RWMutex
	snap    *snapshot
	lastOK  time.Time
	lastTry time.Time
	lastErr error
	// rejected is the last reading that was not believed against the directory in
	// use; a good reading clears it.
	rejected *Rejection
	flight   *loadFlight
	rendered map[renderKey]*Rendered
	// accepting is an operator's "this smaller directory is real", good for the
	// next reading only.
	accepting atomic.Bool
	// shortDeliveries counts top-ups that credited less than they promised.
	shortDeliveries atomic.Int64

	notedMu sync.Mutex
	noted   map[string]time.Time
}

type renderKey struct {
	hash, settings, flags, logos string
	test, configured             bool
}

type loadFlight struct {
	done chan struct{}
	err  error
}

// New builds a service. It reads nothing: the first request, or Run, does.
func New(cfg Config) *Service {
	s := &Service{cfg: cfg, namer: cfg.Namer, rendered: map[renderKey]*Rendered{}}
	if s.namer == nil {
		s.namer = TableNamer{}
	}
	s.test = NewTestExecutor()
	switch {
	case cfg.TestMode:
		s.selling, s.supplier = s.test, SupplierTest
	case cfg.Reloadly != nil:
		s.selling, s.supplier = cfg.Reloadly, SupplierReloadly
	}
	return s
}

func (s *Service) now() time.Time {
	if s.cfg.Now != nil {
		return s.cfg.Now()
	}
	return time.Now()
}

func (s *Service) logger() *slog.Logger {
	if s.cfg.Logger != nil {
		return s.cfg.Logger
	}
	return slog.Default()
}

// Configured reports whether orders can be sold: the supplier is configured or
// test mode is on, and there is a directory to sell from.
func (s *Service) Configured() bool {
	return s != nil && s.selling != nil && s.cfg.Source != nil
}

// TestMode reports whether orders go to the fake supplier.
func (s *Service) TestMode() bool { return s != nil && s.cfg.TestMode }

// Sandbox reports whether Reloadly is its sandbox: orders are really placed
// there, with fake money.
func (s *Service) Sandbox() bool { return s != nil && s.cfg.Sandbox }

// TestOrSandbox reports whether what is sold is not real: a fake supplier, or
// Reloadly's sandbox. A shop is told so everywhere (the directory, the purchase
// row and the statement entry, the receipt), whichever of the two it is.
func (s *Service) TestOrSandbox() bool { return s != nil && (s.cfg.TestMode || s.cfg.Sandbox) }

// Every reports whether an event named key has not been reported for d, and
// notes that it is reported now: a log line that must not repeat on every
// request, or every minute of a reconciler's round, asks first.
func (s *Service) Every(key string, d time.Duration) bool {
	if s == nil {
		return true
	}
	now := s.now()
	s.notedMu.Lock()
	defer s.notedMu.Unlock()
	if last, ok := s.noted[key]; ok && now.Sub(last) < d {
		return false
	}
	if s.noted == nil {
		s.noted = map[string]time.Time{}
	}
	if len(s.noted) >= maxNoted {
		for old, at := range s.noted {
			if now.Sub(at) > 24*time.Hour {
				delete(s.noted, old)
			}
		}
		if len(s.noted) >= maxNoted {
			s.noted = map[string]time.Time{}
		}
	}
	s.noted[key] = now
	return true
}

// Supplier is the key new orders are booked under: "reloadly", or "test" in
// test mode.
func (s *Service) Supplier() string {
	if s == nil {
		return ""
	}
	return s.supplier
}

// ExecutorFor is who an order booked under a supplier key was placed with, to
// read it back. A test order is always readable, even after test mode is
// switched off.
func (s *Service) ExecutorFor(supplier string) (Executor, bool) {
	if s == nil {
		return nil, false
	}
	switch supplier {
	case SupplierTest:
		return s.test, true
	case SupplierReloadly:
		return s.cfg.Reloadly, s.cfg.Reloadly != nil
	}
	return nil, false
}

// RequestTimeout is how long one call to the supplier may take.
func (s *Service) RequestTimeout() time.Duration {
	if s != nil && s.cfg.RequestTimeout > 0 {
		return s.cfg.RequestTimeout
	}
	return DefaultRequestTimeout
}

// SettleWait is how long an accepted order is waited for before it is left to
// the reconciler.
func (s *Service) SettleWait() time.Duration {
	if s != nil && s.cfg.SettleWait > 0 {
		return s.cfg.SettleWait
	}
	return DefaultSettleWait
}

func (s *Service) loadTimeout() time.Duration {
	if s.cfg.LoadTimeout > 0 {
		return s.cfg.LoadTimeout
	}
	return DefaultLoadTimeout
}

// Run keeps the directory fresh until ctx ends: it reads the supplier at once
// and then every Interval (never again when Interval is zero). A failed reading
// keeps the last good directory and is tried again soon.
func (s *Service) Run(ctx context.Context) {
	if !s.Configured() {
		return
	}
	for {
		err := s.Refresh(ctx)
		if ctx.Err() != nil {
			return
		}
		wait := s.cfg.Interval
		if err != nil {
			s.logger().Warn("reading the services directory failed; the last one stands", "error", err)
			if wait <= 0 || wait > retryAfterFailedRefresh {
				wait = retryAfterFailedRefresh
			}
		} else if wait <= 0 {
			return
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}

// Refresh reads the supplier now and swaps the directory in when something
// changed. Readers meanwhile keep the directory they have; concurrent refreshes
// share one reading.
func (s *Service) Refresh(ctx context.Context) error {
	if !s.Configured() {
		return nil
	}
	s.mu.Lock()
	flight := s.flight
	if flight == nil {
		flight = &loadFlight{done: make(chan struct{})}
		s.flight = flight
		go s.runFlight(flight)
	}
	s.mu.Unlock()
	select {
	case <-flight.done:
		return flight.err
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (s *Service) runFlight(flight *loadFlight) {
	ctx, cancel := context.WithTimeout(context.Background(), s.loadTimeout())
	defer cancel()
	err := s.load(ctx)
	s.mu.Lock()
	s.flight = nil
	s.mu.Unlock()
	flight.err = err
	close(flight.done)
}

func (s *Service) load(ctx context.Context) error {
	accepting := s.accepting.Swap(false)
	started := s.now()
	raw, err := s.cfg.Source.Load(ctx)
	if err != nil {
		s.mu.Lock()
		s.lastTry, s.lastErr = started, err
		s.mu.Unlock()
		return err
	}
	snap := buildSnapshot(raw, s.namer, started)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lastTry = started
	if reason := implausible(s.snap, snap, accepting); reason != "" {
		return s.reject(started, snap, reason)
	}
	s.lastOK, s.lastErr, s.rejected = started, nil, nil
	if s.snap != nil && s.snap.hash == snap.hash {
		// Nothing new at the supplier, in anything a price, a limit or a name is
		// made of: the directory, its moment and every rendering stay as they are.
		return nil
	}
	s.snap = snap
	s.rendered = map[renderKey]*Rendered{}
	s.logger().Info("services directory read",
		"countries", snap.stats.Countries, "operators", snap.stats.Operators, "billers", snap.stats.Billers,
		"skipped", snap.stats.Skipped, "hidden_plans", snap.stats.HiddenPlans, "untranslated", len(snap.untranslated))
	if len(snap.stats.Dropped) > 0 {
		// Said once per reading that changed something, not on every request: these
		// countries are never offered, so nobody would otherwise notice them.
		dropped := make([]string, 0, len(snap.stats.Dropped))
		for _, country := range snap.stats.Dropped {
			dropped = append(dropped, country.String())
		}
		s.logger().Info("the services directory leaves out countries that have no Arabic name", "countries", dropped)
	}
	return nil
}

// Rejection is a reading of the supplier that was not believed against the
// directory in use: it listed nothing, or far less than before. The directory in
// use stays; the operator decides (`services directory --refresh --accept`).
type Rejection struct {
	At     time.Time `json:"at"`
	Reason string    `json:"reason"`
	// What the rejected reading listed, and what the directory in use has.
	Countries     int `json:"countries"`
	Operators     int `json:"operators"`
	Billers       int `json:"billers"`
	KeptCountries int `json:"kept_countries"`
	KeptOperators int `json:"kept_operators"`
	KeptBillers   int `json:"kept_billers"`
}

// implausible says why a reading must not replace the directory in use, "" when
// it may. A supplier that lists no country at all is never believed; against a
// directory in use, one that lists none of a kind it had, or less than half of
// what it had, looks like an outage of the supplier and not like its catalog. An
// operator who knows better says so (accepting), for one reading.
func implausible(current, next *snapshot, accepting bool) string {
	if next.stats.Countries == 0 {
		return "it lists no country that can be sold"
	}
	if current == nil || accepting {
		return ""
	}
	for _, kind := range []struct {
		name     string
		was, now int
	}{
		{"countries", current.stats.Countries, next.stats.Countries},
		{"operators", current.stats.Operators, next.stats.Operators},
		{"billers", current.stats.Billers, next.stats.Billers},
	} {
		switch {
		case kind.was > 0 && kind.now == 0:
			return fmt.Sprintf("it lists no %s (the directory in use has %d)", kind.name, kind.was)
		case kind.now*2 < kind.was:
			return fmt.Sprintf("it lists %d %s, fewer than half of the %d in use", kind.now, kind.name, kind.was)
		}
	}
	return ""
}

// reject keeps the directory in use (s.mu is held). With none yet, the reading
// is a failure: there is nothing to sell from.
func (s *Service) reject(at time.Time, next *snapshot, reason string) error {
	if s.snap == nil {
		err := fmt.Errorf("the supplier's directory looks wrong: %s", reason)
		s.lastErr = err
		s.logger().Error("the supplier's directory looks wrong; there is none to fall back on", "reason", reason)
		return err
	}
	s.lastErr = nil
	s.rejected = &Rejection{
		At: at, Reason: reason,
		Countries: next.stats.Countries, Operators: next.stats.Operators, Billers: next.stats.Billers,
		KeptCountries: s.snap.stats.Countries, KeptOperators: s.snap.stats.Operators, KeptBillers: s.snap.stats.Billers,
	}
	s.logger().Error("the supplier's directory looks wrong; the one in use is kept",
		"reason", reason,
		"read_countries", next.stats.Countries, "read_operators", next.stats.Operators, "read_billers", next.stats.Billers,
		"kept_countries", s.snap.stats.Countries, "kept_operators", s.snap.stats.Operators, "kept_billers", s.snap.stats.Billers,
		"accept_with", "pointy-relay services directory --refresh --accept")
	return nil
}

// RefreshAccepting reads the supplier like Refresh, but believes a directory
// that is far smaller than the one in use: the operator knows the supplier
// really dropped that much. A directory that lists nothing is still refused.
func (s *Service) RefreshAccepting(ctx context.Context) error {
	for attempt := 0; attempt < 2; attempt++ {
		s.accepting.Store(true)
		err := s.Refresh(ctx)
		if !s.accepting.Load() {
			// A reading that began after the request used it.
			return err
		}
		// The reading joined began before the request: read again.
	}
	s.accepting.Store(false)
	return errors.New("the supplier could not be read with the override; try again")
}

// staleAfter is how old the last good reading may be before nothing is sold
// from the directory: three refresh intervals, and never less than 45 minutes.
// A directory that is read once (no interval) never goes stale.
func (s *Service) staleAfter() time.Duration {
	if s == nil || s.cfg.Interval <= 0 {
		return 0
	}
	return max(staleIntervals*s.cfg.Interval, minimumStaleAfter)
}

// isStale reports whether the last good reading is older than staleAfter.
func (s *Service) isStale() bool {
	limit := s.staleAfter()
	if limit <= 0 {
		return false
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.snap != nil && !s.lastOK.IsZero() && s.now().Sub(s.lastOK) > limit
}

// errNoDirectory is the directory not being available yet.
var errNoDirectory = errors.New("the services directory has not been read yet")

// current is the directory snapshot, read lazily on the first request.
func (s *Service) current(ctx context.Context) (*snapshot, error) {
	s.mu.RLock()
	snap, lastErr, lastTry := s.snap, s.lastErr, s.lastTry
	s.mu.RUnlock()
	if snap != nil {
		return snap, nil
	}
	if !s.Configured() {
		return nil, errNoDirectory
	}
	if lastErr != nil && s.now().Sub(lastTry) < retryAfterFailedLoad {
		return nil, lastErr
	}
	if err := s.Refresh(ctx); err != nil {
		return nil, err
	}
	s.mu.RLock()
	snap = s.snap
	s.mu.RUnlock()
	if snap == nil {
		return nil, errNoDirectory
	}
	return snap, nil
}

// OperatorLogoURLs are the supplier's logo URLs of the operators in the
// directory in use, for the relay to copy; nil before the first reading.
func (s *Service) OperatorLogoURLs() []string {
	if s == nil {
		return nil
	}
	s.mu.RLock()
	snap := s.snap
	s.mu.RUnlock()
	if snap == nil {
		return nil
	}
	seen := map[string]bool{}
	var urls []string
	for _, op := range snap.operators {
		if op.logo != "" && !seen[op.logo] {
			seen[op.logo] = true
			urls = append(urls, op.logo)
		}
	}
	sort.Strings(urls)
	return urls
}

// Directory is what a shop reads, priced and flagged. Before the supplier
// could be read it is an error; a service that is not configured has an empty
// directory that says so.
func (s *Service) Directory(ctx context.Context, in PricingInput) (*Rendered, error) {
	if !s.Configured() {
		return emptyDirectory(in, s.TestOrSandbox()), nil
	}
	snap, err := s.current(ctx)
	if err != nil {
		return nil, err
	}
	key := renderKey{hash: snap.hash, settings: in.SettingsKey, flags: in.FlagsKey, logos: in.LogosKey, test: s.TestOrSandbox(), configured: true}
	s.mu.RLock()
	cached := s.rendered[key]
	s.mu.RUnlock()
	if cached != nil {
		return cached, nil
	}
	rendered := snap.render(in, key.test, key.configured)
	s.mu.Lock()
	if s.snap == snap {
		if len(s.rendered) >= maxRenderedKept {
			s.rendered = map[renderKey]*Rendered{}
		}
		s.rendered[key] = rendered
	}
	s.mu.Unlock()
	return rendered, nil
}

func emptyDirectory(in PricingInput, test bool) *Rendered {
	directory := &Directory{
		GeneratedAt: time.Unix(0, 0).UTC(),
		Currency:    vouchers.Currency,
		TestMode:    test,
		Configured:  false,
		Priced:      in.Settings.Priced(),
		Popular:     []string{},
		Countries:   []Country{},
		Unsupported: []Unsupported{},
	}
	body, _ := json.Marshal(directory)
	sum := sha256.Sum256(body)
	directory.Version = hex.EncodeToString(sum[:8])
	body, _ = json.Marshal(directory)
	return &Rendered{Version: directory.Version, Body: body, View: directory}
}

// NoteShortDelivery records a top-up that credited less than the sale promised:
// the sale stands, the operator looks at the counter.
func (s *Service) NoteShortDelivery() { s.shortDeliveries.Add(1) }

// Balances reads the company's balance at the supplier, one line per product.
func (s *Service) Balances(ctx context.Context) ([]ProductBalance, bool) {
	if s == nil || s.cfg.Balances == nil {
		return nil, false
	}
	return s.cfg.Balances.Balances(ctx), true
}

// MissingNames are the names of the current directory that the Arabic tables
// could not translate: the directory shows Reloadly's spelling for them.
func (s *Service) MissingNames() []MissingName {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.snap == nil {
		return nil
	}
	return append([]MissingName(nil), s.snap.untranslated...)
}

// Stats is the state of the service for the operator.
type Stats struct {
	Configured bool `json:"configured"`
	// TestMode is a fake supplier; Sandbox is Reloadly's sandbox. Shops are told
	// "test" for either (the directory's test_mode).
	TestMode     bool       `json:"test_mode"`
	Sandbox      bool       `json:"sandbox"`
	Supplier     string     `json:"supplier"`
	Loaded       bool       `json:"loaded"`
	ReadAt       *time.Time `json:"read_at,omitempty"`
	LastTry      *time.Time `json:"last_try,omitempty"`
	LastError    string     `json:"last_error,omitempty"`
	Changed      *time.Time `json:"changed_at,omitempty"`
	Version      string     `json:"structure,omitempty"`
	Build        buildStats `json:"build"`
	Untranslated int        `json:"untranslated"`
	Interval     string     `json:"interval"`
	// Stale is true when the last good reading is older than StaleAfter: quotes
	// and orders are refused (service_unavailable, reason "stale") until the
	// supplier is read again.
	Stale      bool   `json:"stale"`
	StaleAfter string `json:"stale_after,omitempty"`
	// Rejected is the last reading that was not believed (see Rejection), until a
	// good one clears it.
	Rejected *Rejection `json:"rejected,omitempty"`
	// ShortDeliveries counts top-ups that credited less than they promised since
	// the relay started.
	ShortDeliveries int64 `json:"short_deliveries"`
}

// Stats reports what the service has read and when.
func (s *Service) Stats() Stats {
	s.mu.RLock()
	defer s.mu.RUnlock()
	stats := Stats{
		Configured: s.Configured(),
		TestMode:   s.TestMode(),
		Sandbox:    s.Sandbox(),
		Supplier:   s.supplier,
		Loaded:     s.snap != nil,
		Interval:   s.cfg.Interval.String(),

		ShortDeliveries: s.shortDeliveries.Load(),
	}
	if limit := s.staleAfter(); limit > 0 {
		stats.StaleAfter = limit.String()
		stats.Stale = s.snap != nil && !s.lastOK.IsZero() && s.now().Sub(s.lastOK) > limit
	}
	if s.rejected != nil {
		rejected := *s.rejected
		stats.Rejected = &rejected
	}
	if !s.lastOK.IsZero() {
		at := s.lastOK
		stats.ReadAt = &at
	}
	if !s.lastTry.IsZero() {
		at := s.lastTry
		stats.LastTry = &at
	}
	if s.lastErr != nil {
		stats.LastError = s.lastErr.Error()
	}
	if s.snap != nil {
		at := s.snap.at
		stats.Changed = &at
		stats.Version = s.snap.hash
		stats.Build = s.snap.stats
		stats.Untranslated = len(s.snap.untranslated)
	}
	return stats
}
