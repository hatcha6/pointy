package fcm

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeGoogle struct {
	t        *testing.T
	key      *rsa.PublicKey
	mu       sync.Mutex
	signIns  int
	messages []map[string]any
	dead     map[string]bool
}

func (g *fakeGoogle) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	g.mu.Lock()
	defer g.mu.Unlock()
	switch {
	case r.URL.Path == "/token":
		body, _ := io.ReadAll(r.Body)
		form, _ := url.ParseQuery(string(body))
		parts := strings.Split(form.Get("assertion"), ".")
		if form.Get("grant_type") != "urn:ietf:params:oauth:grant-type:jwt-bearer" || len(parts) != 3 {
			http.Error(w, "bad grant", http.StatusBadRequest)
			return
		}
		signature, _ := base64.RawURLEncoding.DecodeString(parts[2])
		digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
		if err := rsa.VerifyPKCS1v15(g.key, crypto.SHA256, digest[:], signature); err != nil {
			http.Error(w, "bad signature", http.StatusUnauthorized)
			return
		}
		claims, _ := base64.RawURLEncoding.DecodeString(parts[1])
		var c map[string]any
		_ = json.Unmarshal(claims, &c)
		if c["iss"] != "sender@daftar-cards.iam.gserviceaccount.com" ||
			c["scope"] != "https://www.googleapis.com/auth/firebase.messaging" {
			http.Error(w, "bad claims", http.StatusUnauthorized)
			return
		}
		g.signIns++
		_, _ = io.WriteString(w, `{"access_token":"ya29.test","expires_in":3600}`)
	case r.URL.Path == "/v1/projects/daftar-cards/messages:send":
		if r.Header.Get("Authorization") != "Bearer ya29.test" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		var body struct {
			Message map[string]any `json:"message"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if token, _ := body.Message["token"].(string); g.dead[token] {
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, `{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}`)
			return
		}
		g.messages = append(g.messages, body.Message)
		_, _ = io.WriteString(w, `{"name":"projects/daftar-cards/messages/1"}`)
	default:
		http.NotFound(w, r)
	}
}

func testClient(t *testing.T) (*Client, *fakeGoogle) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	google := &fakeGoogle{t: t, key: &key.PublicKey, dead: map[string]bool{"dead-token": true}}
	server := httptest.NewServer(google)
	t.Cleanup(server.Close)
	credentials, _ := json.Marshal(map[string]string{
		"type":         "service_account",
		"project_id":   "daftar-cards",
		"private_key":  string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})),
		"client_email": "sender@daftar-cards.iam.gserviceaccount.com",
		"token_uri":    server.URL + "/token",
	})
	client, err := New(credentials, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	client.sendBase = server.URL
	return client, google
}

func TestATopicAndADeviceAreSentTo(t *testing.T) {
	client, google := testClient(t)
	ctx := context.Background()
	message := Message{Title: "عرض", Body: "خصم ليبيانا", Link: "https://cards.dftr.ly/brand/libyana", Campaign: "oct"}
	if err := client.SendTopic(ctx, "all", message); err != nil {
		t.Fatal(err)
	}
	if err := client.SendToken(ctx, "live-token", Message{Title: "t", Body: "b"}); err != nil {
		t.Fatal(err)
	}
	if err := client.SendToken(ctx, "dead-token", message); !errors.Is(err, ErrUnregistered) {
		t.Fatalf("dead token: %v", err)
	}
	if google.signIns != 1 {
		t.Fatalf("signed in %d times, want the token kept", google.signIns)
	}
	if len(google.messages) != 2 {
		t.Fatalf("messages = %v", google.messages)
	}
	first := google.messages[0]
	notification := first["notification"].(map[string]any)
	data := first["data"].(map[string]any)
	if first["topic"] != "all" || notification["title"] != "عرض" || data["link"] != message.Link || data["campaign"] != "oct" {
		t.Fatalf("topic message = %v", first)
	}
	if channel := first["android"].(map[string]any)["notification"].(map[string]any)["channel_id"]; channel != "general" {
		t.Fatalf("android channel = %v", channel)
	}
	if second := google.messages[1]; second["token"] != "live-token" || second["data"] != nil {
		t.Fatalf("token message = %v", second)
	}
}

func TestAnExpiringTokenIsReplaced(t *testing.T) {
	client, google := testClient(t)
	now := time.Date(2026, 10, 27, 9, 0, 0, 0, time.UTC)
	client.now = func() time.Time { return now }
	ctx := context.Background()
	_ = client.SendTopic(ctx, "all", Message{Title: "a", Body: "b"})
	now = now.Add(56 * time.Minute)
	_ = client.SendTopic(ctx, "all", Message{Title: "a", Body: "b"})
	if google.signIns != 2 {
		t.Fatalf("sign-ins = %d", google.signIns)
	}
}

func TestOnlyAServiceAccountKeyIsTaken(t *testing.T) {
	for _, raw := range []string{"", "{}", `{"type":"authorized_user"}`,
		`{"type":"service_account","project_id":"p","client_email":"e","private_key":"nope"}`} {
		if _, err := New([]byte(raw), nil); err == nil {
			t.Fatalf("%q accepted", raw)
		}
	}
}
