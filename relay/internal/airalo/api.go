package airalo

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// maxCatalogPages bounds a catalog read: the first page normally holds it all.
const maxCatalogPages = 40

// catalogPageSize is the "high limit" Airalo suggests for reading the whole
// catalog at once.
const catalogPageSize = 1000

// Packages reads the whole catalog of first eSIMs, in the language asked for
// (country names and titles). An eSIM's top-ups are asked for by its ICCID. Airalo answers every page after the first with
// an object keyed by the destination's index instead of an array; both read.
func (c *Client) Packages(ctx context.Context, language string) (Pricing, []Destination, error) {
	var all []Destination
	var pricing Pricing
	for page := 1; page <= maxCatalogPages; page++ {
		query := url.Values{"limit": {strconv.Itoa(catalogPageSize)}}
		if page > 1 {
			query.Set("page", strconv.Itoa(page))
		}
		var answer struct {
			Pricing Pricing         `json:"pricing"`
			Data    json.RawMessage `json:"data"`
			Meta    struct {
				LastPage Number `json:"last_page"`
			} `json:"meta"`
		}
		if err := c.read(ctx, "packages", "/v2/packages", query, language, &answer); err != nil {
			return Pricing{}, nil, err
		}
		if page == 1 {
			pricing = answer.Pricing
		}
		found, err := readDestinations(answer.Data)
		if err != nil {
			return Pricing{}, nil, &APIError{Op: "packages", Status: http.StatusOK, Message: "unreadable catalog: " + err.Error()}
		}
		all = append(all, found...)
		if len(found) == 0 || page >= answer.Meta.LastPage.Int() {
			return pricing, all, nil
		}
	}
	return Pricing{}, nil, errors.New("airalo: the catalog has more pages than expected")
}

func readDestinations(raw json.RawMessage) ([]Destination, error) {
	text := strings.TrimSpace(string(raw))
	if text == "" || text == "null" {
		return nil, nil
	}
	if text[0] == '[' {
		var list []Destination
		return list, json.Unmarshal(raw, &list)
	}
	var indexed map[string]Destination
	if err := json.Unmarshal(raw, &indexed); err != nil {
		return nil, err
	}
	list := make([]Destination, 0, len(indexed))
	for _, destination := range indexed {
		list = append(list, destination)
	}
	return list, nil
}

// SubmitOrder orders one eSIM. description travels with the order: it is how
// an order whose answer was lost is found again (FindOrders).
func (c *Client) SubmitOrder(ctx context.Context, packageID, description, brand string) (Order, error) {
	var answer struct {
		Data Order `json:"data"`
	}
	err := c.call(ctx, "order", http.MethodPost, "/v2/orders", nil, "", formBody(map[string]string{
		"quantity":            "1",
		"package_id":          packageID,
		"type":                "sim",
		"description":         description,
		"brand_settings_name": brand,
	}), &answer)
	return answer.Data, err
}

// SubmitTopUp adds a top-up package to an eSIM.
func (c *Client) SubmitTopUp(ctx context.Context, packageID, iccid, description string) (Order, error) {
	var answer struct {
		Data Order `json:"data"`
	}
	err := c.call(ctx, "topup", http.MethodPost, "/v2/orders/topups", nil, "", formBody(map[string]string{
		"package_id":  packageID,
		"iccid":       iccid,
		"description": description,
	}), &answer)
	return answer.Data, err
}

// Order reads one order with its eSIMs.
func (c *Client) Order(ctx context.Context, id string) (Order, error) {
	var answer struct {
		Data Order `json:"data"`
	}
	err := c.read(ctx, "order_read", "/v2/orders/"+url.PathEscape(id),
		url.Values{"include": {"sims,status"}}, "", &answer)
	return answer.Data, err
}

// FindOrders lists the orders whose description contains text.
func (c *Client) FindOrders(ctx context.Context, description string) ([]Order, error) {
	var answer struct {
		Data []Order `json:"data"`
	}
	err := c.read(ctx, "order_find", "/v2/orders", url.Values{
		"include":             {"sims,status"},
		"filter[description]": {description},
		"limit":               {"10"},
	}, "", &answer)
	return answer.Data, err
}

// SIM reads an issued eSIM with its share link.
func (c *Client) SIM(ctx context.Context, iccid string) (SIM, error) {
	var answer struct {
		Data SIM `json:"data"`
	}
	err := c.read(ctx, "sim", "/v2/sims/"+url.PathEscape(iccid),
		url.Values{"include": {"share"}}, "", &answer)
	return answer.Data, err
}

// Usage reads what is left on an eSIM. Airalo caches the answer for 20 minutes
// and takes ten reads a minute per ICCID.
func (c *Client) Usage(ctx context.Context, iccid string) (Usage, error) {
	var answer struct {
		Data Usage `json:"data"`
	}
	err := c.read(ctx, "usage", "/v2/sims/"+url.PathEscape(iccid)+"/usage", nil, "", &answer)
	return answer.Data, err
}

// TopUps lists the packages an eSIM can be topped up with.
func (c *Client) TopUps(ctx context.Context, iccid, language string) (Pricing, []Package, error) {
	var answer struct {
		Pricing Pricing   `json:"pricing"`
		Data    []Package `json:"data"`
	}
	err := c.read(ctx, "topups", "/v2/sims/"+url.PathEscape(iccid)+"/topups", nil, language, &answer)
	return answer.Pricing, answer.Data, err
}

// CheckDevice asks whether a hardware model supports eSIM.
func (c *Client) CheckDevice(ctx context.Context, model string) (DeviceCheck, error) {
	var answer struct {
		Data DeviceCheck `json:"data"`
	}
	err := c.call(ctx, "device_check", http.MethodPost, "/v2/compatible-devices/check", nil, "",
		jsonBody(map[string]string{"model": model}), &answer)
	return answer.Data, err
}

// Notification reads one opt-in; ok is false when the account has none.
func (c *Client) Notification(ctx context.Context, kind string) (Notification, bool, error) {
	var answer struct {
		Data struct {
			Notification Notification `json:"notification"`
		} `json:"data"`
	}
	// No opt-in answers 204, with no body.
	err := c.read(ctx, "notification", "/v2/notifications/opt-in", url.Values{"type": {kind}}, "", &answer)
	if IsNotFound(err) {
		return Notification{}, false, nil
	}
	if err != nil {
		return Notification{}, false, err
	}
	return answer.Data.Notification, answer.Data.Notification.ContactPoint != "", nil
}

// OptIn subscribes a webhook. Airalo sends the URL a HEAD request first and
// refuses unless it answers 200. The credit-limit alert asks for its thresholds.
func (c *Client) OptIn(ctx context.Context, kind, webhookURL string) error {
	body := map[string]any{"type": kind, "webhook_url": webhookURL}
	if kind == NotifyCreditLimit {
		body["levels"] = []int{50, 70, 80, 90}
	}
	return c.call(ctx, "opt_in", http.MethodPost, "/v2/notifications/opt-in", nil, "", jsonBody(body), nil)
}

// OptOut ends an opt-in.
func (c *Client) OptOut(ctx context.Context, kind string) error {
	return c.call(ctx, "opt_out", http.MethodPost, "/v2/notifications/opt-out", nil, "",
		jsonBody(map[string]string{"type": kind}), nil)
}

// Balance reads the account's Airalo credit. ok is false for an account without
// one ("If there is no account, the response should be an empty array").
func (c *Client) Balance(ctx context.Context) (Balance, bool, error) {
	var answer struct {
		Data struct {
			Balances struct {
				AvailableBalance struct {
					Amount   Number `json:"amount"`
					Currency string `json:"currency"`
				} `json:"availableBalance"`
			} `json:"balances"`
		} `json:"data"`
	}
	if err := c.read(ctx, "balance", "/v2/balance", nil, "", &answer); err != nil {
		var apiErr *APIError
		if errors.As(err, &apiErr) && apiErr.Status == http.StatusOK {
			return Balance{}, false, nil
		}
		return Balance{}, false, err
	}
	raw := answer.Data.Balances.AvailableBalance
	if raw.Amount == "" {
		return Balance{}, false, nil
	}
	amount, err := strconv.ParseFloat(raw.Amount.String(), 64)
	if err != nil {
		return Balance{}, false, nil
	}
	return Balance{Amount: amount, Currency: raw.Currency}, true, nil
}
