// Package fcm sends «دفتر كروت» notifications through Firebase Cloud
// Messaging's HTTP v1 API, signed in as the project's service account: to a
// topic every phone of a build joins ("all", "ios", "play", "apk"), or to
// one device's token.
//
// Nothing but the standard library: the service account's key signs a
// short-lived JWT, Google trades it for an access token, which is kept until
// a few minutes before it runs out.
package fcm

import (
	"bytes"
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
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const (
	scope       = "https://www.googleapis.com/auth/firebase.messaging"
	defaultSend = "https://fcm.googleapis.com"
)

// ErrUnregistered is a device token Firebase no longer knows: the app was
// removed, or the token replaced. Forget it.
var ErrUnregistered = errors.New("fcm: token no longer registered")

// Message is what a phone shows, and where tapping it goes.
type Message struct {
	Title string
	Body  string
	// Link is a https://cards.dftr.ly/… address the app opens when tapped.
	Link string
	// Campaign names the message in the app's analytics.
	Campaign string
}

// Client sends as one service account.
type Client struct {
	projectID   string
	clientEmail string
	key         *rsa.PrivateKey
	tokenURL    string
	sendBase    string
	http        *http.Client
	now         func() time.Time

	mu      sync.Mutex
	access  string
	expires time.Time
}

type serviceAccount struct {
	Type        string `json:"type"`
	ProjectID   string `json:"project_id"`
	PrivateKey  string `json:"private_key"`
	ClientEmail string `json:"client_email"`
	TokenURI    string `json:"token_uri"`
}

// New reads a service account key file (the JSON Firebase's console
// downloads). httpClient nil uses one with a 15 s timeout.
func New(credentials []byte, httpClient *http.Client) (*Client, error) {
	var account serviceAccount
	if err := json.Unmarshal(credentials, &account); err != nil {
		return nil, fmt.Errorf("fcm: the service account key is not JSON: %w", err)
	}
	if account.Type != "service_account" || account.ProjectID == "" || account.ClientEmail == "" {
		return nil, errors.New("fcm: not a service account key (needs type, project_id and client_email)")
	}
	block, _ := pem.Decode([]byte(account.PrivateKey))
	if block == nil {
		return nil, errors.New("fcm: the service account key has no private key")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("fcm: the private key does not parse: %w", err)
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("fcm: the private key is not RSA")
	}
	if account.TokenURI == "" {
		account.TokenURI = "https://oauth2.googleapis.com/token"
	}
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 15 * time.Second}
	}
	return &Client{
		projectID:   account.ProjectID,
		clientEmail: account.ClientEmail,
		key:         key,
		tokenURL:    account.TokenURI,
		sendBase:    defaultSend,
		http:        httpClient,
		now:         time.Now,
	}, nil
}

// ProjectID is the Firebase project the client sends through.
func (c *Client) ProjectID() string { return c.projectID }

// SendTopic sends m to every phone that joined topic.
func (c *Client) SendTopic(ctx context.Context, topic string, m Message) error {
	return c.send(ctx, map[string]any{"topic": topic}, m)
}

// SendToken sends m to one device; ErrUnregistered when the token is dead.
func (c *Client) SendToken(ctx context.Context, token string, m Message) error {
	return c.send(ctx, map[string]any{"token": token}, m)
}

func (c *Client) send(ctx context.Context, target map[string]any, m Message) error {
	access, err := c.accessToken(ctx)
	if err != nil {
		return err
	}
	data := map[string]string{}
	if m.Link != "" {
		data["link"] = m.Link
	}
	if m.Campaign != "" {
		data["campaign"] = m.Campaign
	}
	message := map[string]any{
		"notification": map[string]string{"title": m.Title, "body": m.Body},
		"android": map[string]any{
			"priority":     "high",
			"notification": map[string]string{"channel_id": "general"},
		},
		"apns": map[string]any{
			"payload": map[string]any{"aps": map[string]any{"sound": "default"}},
		},
	}
	if len(data) > 0 {
		message["data"] = data
	}
	for key, value := range target {
		message[key] = value
	}
	body, err := json.Marshal(map[string]any{"message": message})
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost,
		c.sendBase+"/v1/projects/"+url.PathEscape(c.projectID)+"/messages:send", bytes.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+access)
	request.Header.Set("Content-Type", "application/json")
	response, err := c.http.Do(request)
	if err != nil {
		return fmt.Errorf("fcm: send: %w", err)
	}
	defer response.Body.Close()
	reply, _ := io.ReadAll(io.LimitReader(response.Body, 64<<10))
	if response.StatusCode == http.StatusOK {
		return nil
	}
	if response.StatusCode == http.StatusUnauthorized {
		// A revoked or expired token: the next send asks for a new one.
		c.mu.Lock()
		c.access = ""
		c.mu.Unlock()
	}
	var failure struct {
		Error struct {
			Status  string `json:"status"`
			Message string `json:"message"`
			Details []struct {
				ErrorCode string `json:"errorCode"`
			} `json:"details"`
		} `json:"error"`
	}
	_ = json.Unmarshal(reply, &failure)
	for _, detail := range failure.Error.Details {
		if detail.ErrorCode == "UNREGISTERED" {
			return ErrUnregistered
		}
	}
	if response.StatusCode == http.StatusNotFound && target["token"] != nil {
		return ErrUnregistered
	}
	reason := strings.TrimSpace(failure.Error.Message)
	if reason == "" {
		reason = strings.TrimSpace(string(reply))
	}
	return fmt.Errorf("fcm: send refused (%d %s): %s", response.StatusCode, failure.Error.Status, reason)
}

// accessToken is a live OAuth token for the service account, fetched again
// five minutes before the last one runs out.
func (c *Client) accessToken(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if c.access != "" && now.Before(c.expires.Add(-5*time.Minute)) {
		return c.access, nil
	}
	assertion, err := c.assertion(now)
	if err != nil {
		return "", err
	}
	form := url.Values{
		"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion":  {assertion},
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, c.tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response, err := c.http.Do(request)
	if err != nil {
		return "", fmt.Errorf("fcm: sign-in: %w", err)
	}
	defer response.Body.Close()
	reply, _ := io.ReadAll(io.LimitReader(response.Body, 64<<10))
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("fcm: sign-in refused (%d): %s", response.StatusCode, strings.TrimSpace(string(reply)))
	}
	var token struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(reply, &token); err != nil || token.AccessToken == "" {
		return "", errors.New("fcm: sign-in answered without a token")
	}
	c.access = token.AccessToken
	c.expires = now.Add(time.Duration(token.ExpiresIn) * time.Second)
	return c.access, nil
}

// assertion is the signed JWT Google trades for an access token.
func (c *Client) assertion(now time.Time) (string, error) {
	encode := func(v any) (string, error) {
		raw, err := json.Marshal(v)
		if err != nil {
			return "", err
		}
		return base64.RawURLEncoding.EncodeToString(raw), nil
	}
	header, err := encode(map[string]string{"alg": "RS256", "typ": "JWT"})
	if err != nil {
		return "", err
	}
	claims, err := encode(map[string]any{
		"iss":   c.clientEmail,
		"scope": scope,
		"aud":   c.tokenURL,
		"iat":   now.Unix(),
		"exp":   now.Add(time.Hour).Unix(),
	})
	if err != nil {
		return "", err
	}
	signed := header + "." + claims
	digest := sha256.Sum256([]byte(signed))
	signature, err := rsa.SignPKCS1v15(rand.Reader, c.key, crypto.SHA256, digest[:])
	if err != nil {
		return "", err
	}
	return signed + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}
