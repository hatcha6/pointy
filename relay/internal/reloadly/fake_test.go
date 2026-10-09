package reloadly

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// call is one request a fake server saw.
type call struct {
	server  string
	method  string
	path    string // escaped
	query   string
	header  http.Header
	body    []byte
	payload map[string]any
}

// reply is what a fake product answers.
type reply struct {
	status int
	body   string
	header map[string]string
	delay  time.Duration
}

func ok(body string) reply { return reply{status: http.StatusOK, body: body} }

func fail(status int, body string) reply { return reply{status: status, body: body} }

// fake is a stand-in for Reloadly: the token service and the three products,
// each on its own server so that its URL is its token audience.
type fake struct {
	t       *testing.T
	servers map[string]*httptest.Server

	mu        sync.Mutex
	calls     []call
	tokenSeq  int
	revoked   map[string]bool
	expiresIn string
	// authReplies, when set, answers token requests in turn (then the last).
	authReplies []reply
	authDelay   time.Duration
	handlers    map[string]func(call) reply
}

func newFake(t *testing.T) *fake {
	t.Helper()
	f := &fake{
		t:         t,
		servers:   map[string]*httptest.Server{},
		revoked:   map[string]bool{},
		handlers:  map[string]func(call) reply{},
		expiresIn: "3600",
	}
	for _, name := range []string{"auth", "giftcards", "topups", "utilities"} {
		name := name
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			f.serve(name, w, r)
		}))
		t.Cleanup(server.Close)
		f.servers[name] = server
	}
	return f
}

func (f *fake) url(name string) string { return f.servers[name].URL }

// on sets how a product answers; the default answer is a 404.
func (f *fake) on(server string, handler func(call) reply) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.handlers[server] = handler
}

// always answers every request of a product the same way.
func (f *fake) always(server string, r reply) { f.on(server, func(call) reply { return r }) }

// client builds a client against the fake, with fast retries.
func (f *fake) client(edit ...func(*Config)) *Client {
	f.t.Helper()
	cfg := Config{
		ClientID:     "test-id",
		ClientSecret: "test-secret",
		AuthURL:      f.url("auth"),
		GiftcardsURL: f.url("giftcards"),
		TopupsURL:    f.url("topups"),
		UtilitiesURL: f.url("utilities"),
		RetryBackoff: time.Millisecond,
	}
	for _, change := range edit {
		change(&cfg)
	}
	c, err := New(cfg)
	if err != nil {
		f.t.Fatal(err)
	}
	return c
}

func (f *fake) serve(name string, w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	seen := call{
		server: name,
		method: r.Method,
		path:   r.URL.EscapedPath(),
		query:  r.URL.RawQuery,
		header: r.Header.Clone(),
		body:   body,
	}
	_ = json.Unmarshal(body, &seen.payload)
	f.mu.Lock()
	f.calls = append(f.calls, seen)
	var answer reply
	switch {
	case name == "auth":
		answer = f.token()
	case f.revoked[strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")] || r.Header.Get("Authorization") == "":
		answer = fail(http.StatusUnauthorized,
			`{"timeStamp":"2026-10-08 01:41:29","message":"Invalid token","path":"`+r.URL.Path+`","errorCode":"INVALID_TOKEN","infoLink":null,"details":[]}`)
	default:
		if handler := f.handlers[name]; handler != nil {
			f.mu.Unlock()
			answer = handler(seen)
			f.mu.Lock()
		} else {
			answer = fail(http.StatusNotFound, `{"timestamp":"2026-10-08T01:41:31.693+00:00","status":404,"error":"Not Found","path":"`+r.URL.Path+`"}`)
		}
	}
	delay := answer.delay
	if name == "auth" {
		delay = f.authDelay
	}
	f.mu.Unlock()
	if delay > 0 {
		time.Sleep(delay)
	}
	w.Header().Set("Content-Type", "application/json")
	for key, value := range answer.header {
		w.Header().Set(key, value)
	}
	status := answer.status
	if status == 0 {
		status = http.StatusOK
	}
	w.WriteHeader(status)
	_, _ = io.WriteString(w, answer.body)
}

// token answers a token request (called with f.mu held). authReplies, when set,
// are consumed by token request number; an entry with a failing status or a
// body answers that request as given, any other entry (or none) issues token
// "tok-<number>".
func (f *fake) token() reply {
	f.tokenSeq++
	if n := len(f.authReplies); n > 0 {
		answer := f.authReplies[min(f.tokenSeq, n)-1]
		if (answer.status != 0 && answer.status != http.StatusOK) || answer.body != "" {
			return answer
		}
	}
	return ok(fmt.Sprintf(`{"access_token":"tok-%d","scope":"x","expires_in":%s,"token_type":"Bearer"}`, f.tokenSeq, f.expiresIn))
}

// callsTo are the requests a server saw, in order.
func (f *fake) callsTo(server string) []call {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []call
	for _, c := range f.calls {
		if c.server == server {
			out = append(out, c)
		}
	}
	return out
}

// revoke makes the product refuse a token from now on.
func (f *fake) revoke(token string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.revoked[token] = true
}

// fixture reads a file of testdata.
func fixture(t *testing.T, name string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// fixtureRows decodes the content of a fixture page.
func fixtureRows[T any](t *testing.T, name string) []T {
	t.Helper()
	var page pageOf[T]
	if err := json.Unmarshal([]byte(fixture(t, name)), &page); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return page.Content
}

// pageBody builds a Reloadly page envelope around rows; number is 0-based like
// Reloadly's own "number".
func pageBody(rows []string, number, totalPages int, withLast bool) string {
	last := ""
	if withLast {
		last = fmt.Sprintf(`,"last":%t`, number+1 >= totalPages)
	}
	return fmt.Sprintf(`{"content":[%s],"totalPages":%d,"number":%d%s}`, strings.Join(rows, ","), totalPages, number, last)
}

// parseQueryDecoded reads a raw query into its first values, decoded.
func parseQueryDecoded(t *testing.T, raw string) map[string]string {
	t.Helper()
	values, err := url.ParseQuery(raw)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for key := range values {
		out[key] = values.Get(key)
	}
	return out
}
