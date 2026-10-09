// Package alerts sends the company's operational alerts — a supplier balance
// running low, a shop's wallet payment and how it ended — to an ntfy topic the
// company's phones subscribe to (https://ntfy.sh by default).
//
// Alerts are best effort by design: a notification that cannot be delivered
// is logged and dropped, never retried into the request that caused it, and
// never fails that request.
package alerts

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base32"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"
)

// ntfy priorities.
const (
	PriorityMin     = 1
	PriorityLow     = 2
	PriorityDefault = 3
	PriorityHigh    = 4
	PriorityUrgent  = 5
)

// DefaultServer is the public ntfy server.
const DefaultServer = "https://ntfy.sh"

// Message is one notification.
type Message struct {
	Title    string
	Body     string
	Priority int
	// Tags are ntfy tags; a tag that names an emoji ("warning",
	// "white_check_mark") is shown as that emoji before the title.
	Tags []string
	// Click is the operator console page the notification opens, as a path
	// inside the console ("/topups/<id>"). It is sent only when the relay
	// knows the console's address (Ntfy.LinkBase).
	Click string
}

// TopicSource answers the topic to publish to; empty means the channel is not
// set up and nothing is sent.
type TopicSource interface {
	AlertTopic(ctx context.Context) (string, error)
}

// TopicFunc adapts a function to TopicSource.
type TopicFunc func(ctx context.Context) (string, error)

func (f TopicFunc) AlertTopic(ctx context.Context) (string, error) { return f(ctx) }

// ErrNoTopic is a publish on a channel that has no topic yet.
var ErrNoTopic = errors.New("the alert channel has no topic: run `pointy-relay alerts setup`")

// Ntfy publishes to one ntfy topic. A nil *Ntfy is a channel that is off:
// every method is safe on it and sends nothing.
type Ntfy struct {
	// Server is the ntfy server's base URL; DefaultServer when empty.
	Server string
	// Token is an optional access token, for a self-hosted or reserved topic.
	Token string
	// Topics answers the topic; it is read at most once a TopicTTL.
	Topics     TopicSource
	TopicTTL   time.Duration
	HTTPClient *http.Client
	Logger     *slog.Logger
	// Prefix starts every title, e.g. "[staging]", so alerts from two relays
	// on one phone can be told apart.
	Prefix string
	// LinkBase is the operator console's address ("https://relay.example/console");
	// a message's Click path is joined to it so tapping the notification
	// opens that page. Empty sends no link.
	LinkBase string

	mu      sync.Mutex
	topic   string
	topicAt time.Time
}

const (
	defaultTopicTTL = time.Minute
	publishTimeout  = 15 * time.Second
)

func (n *Ntfy) server() string {
	server := strings.TrimRight(strings.TrimSpace(n.Server), "/")
	if server == "" {
		return DefaultServer
	}
	return server
}

func (n *Ntfy) logger() *slog.Logger {
	if n.Logger != nil {
		return n.Logger
	}
	return slog.Default()
}

// SubscribeURL is where a phone subscribes to topic.
func (n *Ntfy) SubscribeURL(topic string) string {
	if n == nil {
		return DefaultServer + "/" + topic
	}
	return n.server() + "/" + topic
}

// ServerURL is the server alerts go to.
func (n *Ntfy) ServerURL() string {
	if n == nil {
		return DefaultServer
	}
	return n.server()
}

// Forget drops the cached topic, so the next publish reads it again: used
// right after the operator rotates it on this instance.
func (n *Ntfy) Forget() {
	if n == nil {
		return
	}
	n.mu.Lock()
	n.topic, n.topicAt = "", time.Time{}
	n.mu.Unlock()
}

func (n *Ntfy) currentTopic(ctx context.Context) (string, error) {
	ttl := n.TopicTTL
	if ttl <= 0 {
		ttl = defaultTopicTTL
	}
	n.mu.Lock()
	if !n.topicAt.IsZero() && time.Since(n.topicAt) < ttl {
		topic := n.topic
		n.mu.Unlock()
		return topic, nil
	}
	n.mu.Unlock()
	if n.Topics == nil {
		return "", nil
	}
	topic, err := n.Topics.AlertTopic(ctx)
	if err != nil {
		return "", err
	}
	topic = strings.TrimSpace(topic)
	n.mu.Lock()
	n.topic, n.topicAt = topic, time.Now()
	n.mu.Unlock()
	return topic, nil
}

// Ready reports whether the channel has a topic to publish to.
func (n *Ntfy) Ready(ctx context.Context) bool {
	if n == nil {
		return false
	}
	topic, err := n.currentTopic(ctx)
	return err == nil && topic != ""
}

// Publish sends message now and reports what happened.
func (n *Ntfy) Publish(ctx context.Context, message Message) error {
	if n == nil {
		return ErrNoTopic
	}
	topic, err := n.currentTopic(ctx)
	if err != nil {
		return fmt.Errorf("alert topic unreadable: %w", err)
	}
	if topic == "" {
		return ErrNoTopic
	}
	return n.publishTo(ctx, topic, message)
}

func (n *Ntfy) publishTo(ctx context.Context, topic string, message Message) error {
	title := strings.TrimSpace(message.Title)
	if prefix := strings.TrimSpace(n.Prefix); prefix != "" {
		title = prefix + " " + title
	}
	// The JSON form, not headers: titles and bodies carry Arabic shop names,
	// which HTTP headers cannot.
	payload := map[string]any{"topic": topic, "message": message.Body}
	if title != "" {
		payload["title"] = title
	}
	if message.Priority >= PriorityMin && message.Priority <= PriorityUrgent {
		payload["priority"] = message.Priority
	}
	if len(message.Tags) > 0 {
		payload["tags"] = message.Tags
	}
	if link := n.link(message.Click); link != "" {
		payload["click"] = link
		payload["actions"] = []map[string]any{{"action": "view", "label": "Open", "url": link, "clear": true}}
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, n.server(), bytes.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	if token := strings.TrimSpace(n.Token); token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	client := n.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: publishTimeout}
	}
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode/100 != 2 {
		detail, _ := io.ReadAll(io.LimitReader(response.Body, 512))
		return fmt.Errorf("ntfy answered %d: %s", response.StatusCode, strings.TrimSpace(string(detail)))
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
	return nil
}

// link is the console page a message opens, or empty.
func (n *Ntfy) link(click string) string {
	base := strings.TrimRight(strings.TrimSpace(n.LinkBase), "/")
	click = strings.TrimSpace(click)
	if base == "" || click == "" || !strings.HasPrefix(click, "/") {
		return ""
	}
	return base + click
}

// Send publishes message in the background: the caller is usually serving a
// request that must not wait on, or fail because of, a notification.
func (n *Ntfy) Send(message Message) {
	if n == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), publishTimeout)
		defer cancel()
		if err := n.Publish(ctx, message); err != nil && !errors.Is(err, ErrNoTopic) {
			n.logger().Warn("relay alert not delivered", "title", message.Title, "error", err)
		}
	}()
}

// NewTopic is a fresh random topic: 128 bits, lowercase, prefixed so it reads
// as the company's on a phone's subscription list.
func NewTopic() (string, error) {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	encoded := strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(raw))
	return "daftar-alerts-" + encoded, nil
}
