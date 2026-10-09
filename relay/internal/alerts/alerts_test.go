package alerts

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"regexp"
	"sync"
	"testing"
	"time"
)

type published struct {
	Topic    string   `json:"topic"`
	Title    string   `json:"title"`
	Message  string   `json:"message"`
	Priority int      `json:"priority"`
	Tags     []string `json:"tags"`
	Click    string   `json:"click"`
}

// fakeNtfy records what was published; fail makes it answer 500.
type fakeNtfy struct {
	mu   sync.Mutex
	got  []published
	auth []string
	fail bool
}

func (f *fakeNtfy) server(t *testing.T) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		if f.fail {
			http.Error(w, "down", http.StatusInternalServerError)
			return
		}
		var message published
		if err := json.NewDecoder(r.Body).Decode(&message); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		f.got = append(f.got, message)
		f.auth = append(f.auth, r.Header.Get("Authorization"))
	}))
	t.Cleanup(server.Close)
	return server
}

func (f *fakeNtfy) messages() []published {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]published(nil), f.got...)
}

type memoryMarks struct {
	marks map[string]time.Time
	now   time.Time
}

func (m *memoryMarks) ClaimAlert(_ context.Context, key string, cooldown time.Duration) (bool, error) {
	if at, ok := m.marks[key]; ok && m.now.Sub(at) < cooldown {
		return false, nil
	}
	m.marks[key] = m.now
	return true, nil
}

func (m *memoryMarks) ReleaseAlert(_ context.Context, key string) (bool, error) {
	_, ok := m.marks[key]
	delete(m.marks, key)
	return ok, nil
}

func staticTopic(topic string) TopicSource {
	return TopicFunc(func(context.Context) (string, error) { return topic, nil })
}

func quiet() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func TestPublishSendsJSONWithTitlePrefixAndToken(t *testing.T) {
	fake := &fakeNtfy{}
	server := fake.server(t)
	notifier := &Ntfy{Server: server.URL, Token: "tk", Prefix: "[staging]", Topics: staticTopic("daftar-alerts-x"), Logger: quiet()}
	err := notifier.Publish(context.Background(), Message{Title: "دفع 50", Body: "متجر", Priority: PriorityHigh, Tags: []string{"moneybag"}})
	if err != nil {
		t.Fatal(err)
	}
	got := fake.messages()
	if len(got) != 1 {
		t.Fatalf("published %d", len(got))
	}
	if got[0].Topic != "daftar-alerts-x" || got[0].Title != "[staging] دفع 50" || got[0].Message != "متجر" ||
		got[0].Priority != PriorityHigh || len(got[0].Tags) != 1 || fake.auth[0] != "Bearer tk" {
		t.Fatalf("unexpected publish %+v auth %q", got[0], fake.auth[0])
	}
}

func TestPublishLinksToTheConsolePageOnlyWhenTheConsoleIsKnown(t *testing.T) {
	fake := &fakeNtfy{}
	server := fake.server(t)
	linked := &Ntfy{Server: server.URL, Topics: staticTopic("daftar-alerts-x"), LinkBase: "https://relay.example/console/", Logger: quiet()}
	if err := linked.Publish(context.Background(), Message{Title: "t", Click: "/topups/abc"}); err != nil {
		t.Fatal(err)
	}
	plain := &Ntfy{Server: server.URL, Topics: staticTopic("daftar-alerts-x"), Logger: quiet()}
	if err := plain.Publish(context.Background(), Message{Title: "t", Click: "/topups/abc"}); err != nil {
		t.Fatal(err)
	}
	// Only a path inside the console: never a link to somewhere else.
	if err := linked.Publish(context.Background(), Message{Title: "t", Click: "https://evil.example"}); err != nil {
		t.Fatal(err)
	}
	got := fake.messages()
	if got[0].Click != "https://relay.example/console/topups/abc" || got[1].Click != "" || got[2].Click != "" {
		t.Fatalf("links: %q %q %q", got[0].Click, got[1].Click, got[2].Click)
	}
}

func TestPublishWithoutTopicSendsNothing(t *testing.T) {
	fake := &fakeNtfy{}
	server := fake.server(t)
	notifier := &Ntfy{Server: server.URL, Topics: staticTopic(""), Logger: quiet()}
	if err := notifier.Publish(context.Background(), Message{Title: "x"}); !errors.Is(err, ErrNoTopic) {
		t.Fatalf("want ErrNoTopic, got %v", err)
	}
	var off *Ntfy
	off.Send(Message{Title: "nil channel is safe"})
	if len(fake.messages()) != 0 {
		t.Fatal("published without a topic")
	}
}

func TestNewTopicIsLongRandomAndNtfySafe(t *testing.T) {
	a, err := NewTopic()
	if err != nil {
		t.Fatal(err)
	}
	b, _ := NewTopic()
	if a == b || len(a) < 40 || !regexp.MustCompile(`^daftar-alerts-[a-z2-7]{26}$`).MatchString(a) {
		t.Fatalf("weak or malformed topics %q %q", a, b)
	}
}

func TestBalanceWatcherAlertsOnceRepeatsAndRecovers(t *testing.T) {
	fake := &fakeNtfy{}
	server := fake.server(t)
	balance := big.NewRat(20, 1)
	marks := &memoryMarks{marks: map[string]time.Time{}, now: time.Unix(1_000_000, 0)}
	watcher := &BalanceWatcher{
		Notifier: &Ntfy{Server: server.URL, Topics: staticTopic("daftar-alerts-test-topic-xx"), Logger: quiet()},
		Marks:    marks,
		Repeat:   time.Hour,
		Logger:   quiet(),
		Sources: []BalanceSource{{
			Key: "reloadly", Name: "Reloadly", Unit: "USD", Floor: big.NewRat(50, 1),
			Read: func(context.Context) (*big.Rat, error) { return balance, nil },
		}},
	}
	ctx := context.Background()

	watcher.Sweep(ctx)
	watcher.Sweep(ctx) // a second instance, or the next sweep: no repeat yet
	if got := fake.messages(); len(got) != 1 || got[0].Title != "Reloadly balance low: 20.00 USD" || got[0].Priority != PriorityHigh {
		t.Fatalf("want one low alert, got %+v", got)
	}

	marks.now = marks.now.Add(2 * time.Hour)
	watcher.Sweep(ctx)
	if got := fake.messages(); len(got) != 2 {
		t.Fatalf("still low after Repeat should alert again, got %d", len(got))
	}

	balance = big.NewRat(500, 1)
	watcher.Sweep(ctx)
	watcher.Sweep(ctx)
	got := fake.messages()
	if len(got) != 3 || got[2].Title != "Reloadly balance back up: 500.00 USD" {
		t.Fatalf("want one recovery alert, got %+v", got)
	}
}

func TestBalanceWatcherSaysUnreadableAfterRepeatedFailures(t *testing.T) {
	fake := &fakeNtfy{}
	server := fake.server(t)
	watcher := &BalanceWatcher{
		Notifier:        &Ntfy{Server: server.URL, Topics: staticTopic("daftar-alerts-test-topic-xx"), Logger: quiet()},
		Marks:           &memoryMarks{marks: map[string]time.Time{}, now: time.Unix(1_000_000, 0)},
		UnreadableAfter: 2,
		Logger:          quiet(),
		Sources: []BalanceSource{{
			Key: "serper", Name: "Serper", Unit: "credits", Floor: big.NewRat(300, 1),
			Read: func(context.Context) (*big.Rat, error) { return nil, errors.New("401 unauthorized") },
		}},
	}
	watcher.Sweep(context.Background())
	if len(fake.messages()) != 0 {
		t.Fatal("one failure is not news")
	}
	watcher.Sweep(context.Background())
	watcher.Sweep(context.Background())
	if got := fake.messages(); len(got) != 1 || got[0].Title != "Serper balance unreadable" {
		t.Fatalf("want one unreadable alert, got %+v", got)
	}
}

func TestBalanceWatcherRetriesAnUndeliveredAlert(t *testing.T) {
	fake := &fakeNtfy{fail: true}
	server := fake.server(t)
	watcher := &BalanceWatcher{
		Notifier: &Ntfy{Server: server.URL, Topics: staticTopic("daftar-alerts-test-topic-xx"), Logger: quiet()},
		Marks:    &memoryMarks{marks: map[string]time.Time{}, now: time.Unix(1_000_000, 0)},
		Logger:   quiet(),
		Sources: []BalanceSource{{
			Key: "bnplus_lyd", Name: "BN Plus", Unit: "LYD", Floor: big.NewRat(500, 1),
			Read: func(context.Context) (*big.Rat, error) { return big.NewRat(0, 1), nil },
		}},
	}
	watcher.Sweep(context.Background())
	fake.mu.Lock()
	fake.fail = false
	fake.mu.Unlock()
	watcher.Sweep(context.Background())
	if got := fake.messages(); len(got) != 1 || got[0].Priority != PriorityUrgent {
		t.Fatalf("want the empty balance alerted urgently on the retry, got %+v", got)
	}
}

func TestBalanceWatcherReadsNothingWithoutATopic(t *testing.T) {
	reads := 0
	watcher := &BalanceWatcher{
		Notifier: &Ntfy{Topics: staticTopic(""), Logger: quiet()},
		Marks:    &memoryMarks{marks: map[string]time.Time{}},
		Logger:   quiet(),
		Sources: []BalanceSource{{
			Key: "x", Name: "X", Floor: big.NewRat(1, 1),
			Read: func(context.Context) (*big.Rat, error) { reads++; return big.NewRat(0, 1), nil },
		}},
	}
	watcher.Sweep(context.Background())
	if reads != 0 {
		t.Fatal("read a balance with nowhere to say it")
	}
}

func TestProviderBalanceReaders(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/account" && r.Header.Get("X-API-KEY") == "serper-key":
			_, _ = io.WriteString(w, `{"balance":2088,"rateLimit":5}`)
		case r.URL.Path == "/api/v1/key" && r.Header.Get("Authorization") == "Bearer or-key":
			_, _ = io.WriteString(w, `{"data":{"limit":10,"limit_remaining":8.753456588,"usage":1.2}}`)
		case r.URL.Path == "/api/v1/credits" && r.Header.Get("Authorization") == "Bearer or-mgmt":
			_, _ = io.WriteString(w, `{"data":{"total_credits":100.5,"total_usage":25.75}}`)
		default:
			http.Error(w, "no", http.StatusUnauthorized)
		}
	}))
	defer server.Close()
	ctx := context.Background()

	serper, err := SerperBalance(server.Client(), server.URL+"/images", "serper-key")(ctx)
	if err != nil || serper.Cmp(big.NewRat(2088, 1)) != 0 {
		t.Fatalf("serper %v %v", serper, err)
	}
	limited, err := OpenRouterBalance(server.Client(), server.URL+"/api/v1", "or-key", "")(ctx)
	if err != nil || limited.FloatString(2) != "8.75" {
		t.Fatalf("openrouter key %v %v", limited, err)
	}
	credits, err := OpenRouterBalance(server.Client(), server.URL+"/api/v1", "or-key", "or-mgmt")(ctx)
	if err != nil || credits.FloatString(2) != "74.75" {
		t.Fatalf("openrouter credits %v %v", credits, err)
	}
	if _, err := SerperBalance(server.Client(), server.URL+"/images", "wrong")(ctx); err == nil {
		t.Fatal("a refused key must read as an error, not a zero balance")
	}
}
