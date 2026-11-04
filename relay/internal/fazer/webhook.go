package fazer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
)

// Webhook is the account's webhook as FazerCards keeps it: where it posts and
// how its deliveries have gone. The HMAC secret it signs them with is left
// out (WebhookSecret reads it): this is what the console is shown. The relay
// reads every order back over the API instead of believing a delivery, so
// the signature only tells a real delivery from a forged nudge.
//
// The spec (0.1.0) documents the setup calls and the `webhook.test` event,
// but not the order events or how the signature is sent.
type Webhook struct {
	URL                 string
	Enabled             bool
	ConsecutiveFailures int
	LastSuccessAt       string
	LastFailureAt       string
	LastFailureReason   string
}

// Webhook reads the account's webhook; set is false when none is set.
func (c *Client) Webhook(ctx context.Context) (hook Webhook, set bool, err error) {
	var answer struct {
		Webhook *struct {
			URL                 Text  `json:"url"`
			Enabled             bool  `json:"enabled"`
			ConsecutiveFailures Count `json:"consecutive_failures"`
			LastSuccessAt       Text  `json:"last_success_at"`
			LastFailureAt       Text  `json:"last_failure_at"`
			LastFailureReason   Text  `json:"last_failure_reason"`
		} `json:"webhook"`
	}
	if err := c.get(ctx, "read the webhook", "/account/webhook", nil, &answer); err != nil {
		return Webhook{}, false, err
	}
	if answer.Webhook == nil {
		return Webhook{}, false, nil
	}
	w := answer.Webhook
	return Webhook{
		URL: w.URL.String(), Enabled: w.Enabled, ConsecutiveFailures: int(w.ConsecutiveFailures),
		LastSuccessAt: w.LastSuccessAt.String(), LastFailureAt: w.LastFailureAt.String(),
		LastFailureReason: w.LastFailureReason.String(),
	}, true, nil
}

// WebhookSecret is the HMAC secret FazerCards signs its deliveries with,
// read with the API key (so it is never configured by hand, and a rotated one
// is read again); empty when no webhook is set. Never log or show it.
func (c *Client) WebhookSecret(ctx context.Context) (string, error) {
	var answer struct {
		Webhook *struct {
			Secret Text `json:"secret"`
		} `json:"webhook"`
	}
	if err := c.get(ctx, "read the webhook secret", "/account/webhook", nil, &answer); err != nil {
		return "", err
	}
	if answer.Webhook == nil {
		return "", nil
	}
	return strings.TrimSpace(answer.Webhook.Secret.String()), nil
}

// SetWebhook points the account's webhook at url. FazerCards makes its secret
// the first time one is set.
func (c *Client) SetWebhook(ctx context.Context, url string, enabled bool) error {
	url = strings.TrimSpace(url)
	if url == "" {
		return errors.New("fazer: a webhook needs a URL")
	}
	payload, err := json.Marshal(map[string]any{"url": url, "enabled": enabled})
	if err != nil {
		return fmt.Errorf("fazer: encode the webhook: %w", err)
	}
	raw, err := c.do(ctx, "set the webhook", http.MethodPut, "/account/webhook", nil, payload, "")
	if err != nil {
		return err
	}
	return decodeAnswer("set the webhook", raw, nil)
}

// WebhookTest is how FazerCards' one test delivery went: the status our end
// answered with, or why it could not be delivered.
type WebhookTest struct {
	Delivered bool
	Status    int
	Error     string
}

// TestWebhook has FazerCards send one `webhook.test` event, without retries.
// A delivery that failed is an answer, not an error: ok false here describes
// the delivery, not the call.
func (c *Client) TestWebhook(ctx context.Context) (WebhookTest, error) {
	raw, err := c.do(ctx, "test the webhook", http.MethodPost, "/account/webhook/test", nil, []byte("{}"), "")
	if err != nil {
		return WebhookTest{}, err
	}
	var answer struct {
		OK     bool   `json:"ok"`
		Status *Count `json:"status"`
		Error  Text   `json:"error"`
	}
	if err := json.Unmarshal(raw, &answer); err != nil {
		return WebhookTest{}, &TransportError{Op: "test the webhook", Err: fmt.Errorf("unreadable answer: %w", err), Sent: true}
	}
	test := WebhookTest{Delivered: answer.OK, Error: answer.Error.String()}
	if answer.Status != nil {
		test.Status = int(*answer.Status)
	}
	return test, nil
}

// WebhookDelivery is one recent delivery, for diagnosis.
type WebhookDelivery struct {
	Event          string
	Attempt        int
	Status         string
	ResponseStatus int
	CreatedAt      string
	NextRetryAt    string
}

// WebhookDeliveries reads the last 50 deliveries.
func (c *Client) WebhookDeliveries(ctx context.Context) ([]WebhookDelivery, error) {
	var answer struct {
		Deliveries []struct {
			Event          Text  `json:"event"`
			Attempt        Count `json:"attempt"`
			Status         Text  `json:"status"`
			ResponseStatus Count `json:"response_status"`
			CreatedAt      Text  `json:"created_at"`
			NextRetryAt    Text  `json:"next_retry_at"`
		} `json:"deliveries"`
	}
	if err := c.get(ctx, "list webhook deliveries", "/account/webhook/deliveries", nil, &answer); err != nil {
		return nil, err
	}
	deliveries := make([]WebhookDelivery, 0, len(answer.Deliveries))
	for _, d := range answer.Deliveries {
		deliveries = append(deliveries, WebhookDelivery{
			Event: d.Event.String(), Attempt: int(d.Attempt), Status: d.Status.String(),
			ResponseStatus: int(d.ResponseStatus), CreatedAt: d.CreatedAt.String(), NextRetryAt: d.NextRetryAt.String(),
		})
	}
	return deliveries, nil
}
