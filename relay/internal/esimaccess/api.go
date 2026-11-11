package esimaccess

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// Packages reads the whole catalog of first plans.
func (c *Client) Packages(ctx context.Context) ([]Package, error) {
	var answer struct {
		List []Package `json:"packageList"`
	}
	err := c.read(ctx, "packages", "/api/v1/open/package/list", map[string]string{"locationCode": "", "type": "BASE"}, &answer)
	return answer.List, err
}

// TopUps reads what one eSIM can be topped up with. tranNo names the eSIM; the
// ICCID is sent too, for an API that still asks by it.
func (c *Client) TopUps(ctx context.Context, tranNo, iccid string) ([]Package, error) {
	var answer struct {
		List []Package `json:"packageList"`
	}
	body := map[string]string{"type": "TOPUP", "iccid": strings.TrimSpace(iccid)}
	if tranNo = strings.TrimSpace(tranNo); tranNo != "" {
		body["esimTranNo"] = tranNo
	}
	err := c.read(ctx, "topups", "/api/v1/open/package/list", body, &answer)
	return answer.List, err
}

// Order places an order for one eSIM, once. transactionID is the caller's own
// reference (50 characters at most): the API treats a repeated one as the same
// request. price, when above zero, is what the caller expects to pay; the API
// refuses the order if the package costs something else now. The answer is the
// order's number; its eSIM is made in the background (see Profiles).
func (c *Client) Order(ctx context.Context, transactionID, packageCode string, price int64) (string, error) {
	item := map[string]any{"packageCode": packageCode, "count": 1}
	body := map[string]any{"transactionId": transactionID, "packageInfoList": []any{item}}
	if price > 0 {
		item["price"], body["amount"] = price, price
	}
	var answer struct {
		OrderNo string `json:"orderNo"`
	}
	if err := c.once(ctx, "order", "/api/v1/open/esim/order", body, &answer); err != nil {
		return "", err
	}
	if strings.TrimSpace(answer.OrderNo) == "" {
		return "", &APIError{Op: "order", Status: 200, Message: "the answer names no order"}
	}
	return answer.OrderNo, nil
}

// ProfileQuery picks eSIMs: by order, by eSIM, or by when they were ordered.
type ProfileQuery struct {
	OrderNo string
	TranNo  string
	ICCID   string
	From    time.Time
	To      time.Time
	Page    int
	Size    int
}

// Profiles reads eSIMs. An order whose eSIM is still being made answers with
// CodeAllocating (see IsCode).
func (c *Client) Profiles(ctx context.Context, query ProfileQuery) ([]Profile, int, error) {
	page, size := query.Page, query.Size
	if page <= 0 {
		page = 1
	}
	if size <= 0 {
		size = 20
	}
	body := map[string]any{"pager": map[string]int{"pageNum": page, "pageSize": size}}
	if query.OrderNo != "" {
		body["orderNo"] = query.OrderNo
	}
	if query.TranNo != "" {
		body["esimTranNo"] = query.TranNo
	}
	if query.ICCID != "" {
		body["iccid"] = query.ICCID
	}
	if !query.From.IsZero() {
		body["startTime"] = query.From.UTC().Format("2006-01-02T15:04-07:00")
	}
	if !query.To.IsZero() {
		body["endTime"] = query.To.UTC().Format("2006-01-02T15:04-07:00")
	}
	var answer struct {
		List  []Profile `json:"esimList"`
		Pager struct {
			Total Int `json:"total"`
		} `json:"pager"`
	}
	if err := c.read(ctx, "profiles", "/api/v1/open/esim/query", body, &answer); err != nil {
		return nil, 0, err
	}
	return answer.List, int(answer.Pager.Total), nil
}

// ErrNoProfile is an eSIM the account does not hold.
var ErrNoProfile = errors.New("esimaccess: no such eSIM")

// Profile reads one eSIM, by its transaction number when known, else by its
// ICCID. With both, an ICCID that now belongs to another eSIM is ErrNoProfile:
// the API reuses ICCIDs.
func (c *Client) Profile(ctx context.Context, tranNo, iccid string) (Profile, error) {
	query := ProfileQuery{Size: 5}
	if tranNo = strings.TrimSpace(tranNo); tranNo != "" {
		query.TranNo = tranNo
	} else {
		query.ICCID = strings.TrimSpace(iccid)
	}
	if query.TranNo == "" && query.ICCID == "" {
		return Profile{}, ErrNoProfile
	}
	list, _, err := c.Profiles(ctx, query)
	if err != nil {
		return Profile{}, err
	}
	for _, profile := range list {
		if tranNo != "" && profile.TranNo != tranNo {
			continue
		}
		if tranNo == "" && profile.ICCID != query.ICCID {
			continue
		}
		return profile, nil
	}
	return Profile{}, ErrNoProfile
}

// TopUp loads a top-up package on an eSIM, once. price above zero is checked
// by the API like an order's.
func (c *Client) TopUp(ctx context.Context, tranNo, iccid, packageCode, transactionID string, price int64) (TopUpResult, error) {
	body := map[string]any{"packageCode": packageCode, "transactionId": transactionID}
	if tranNo = strings.TrimSpace(tranNo); tranNo != "" {
		body["esimTranNo"] = tranNo
	} else {
		body["iccid"] = strings.TrimSpace(iccid)
	}
	if price > 0 {
		body["amount"] = price
	}
	var answer TopUpResult
	err := c.once(ctx, "topup", "/api/v1/open/esim/topup", body, &answer)
	return answer, err
}

// Cancel returns an eSIM nobody installed, for a refund to the balance.
func (c *Client) Cancel(ctx context.Context, tranNo string) error {
	return c.once(ctx, "cancel", "/api/v1/open/esim/cancel", map[string]string{"esimTranNo": tranNo}, nil)
}

// Balance is the account's prepaid balance, in Units.
func (c *Client) Balance(ctx context.Context) (int64, error) {
	var answer struct {
		Balance Int `json:"balance"`
	}
	err := c.read(ctx, "balance", "/api/v1/open/balance/query", nil, &answer)
	return int64(answer.Balance), err
}

// Webhook is the address the account's events are posted to; empty when none
// is set or the answer does not say.
func (c *Client) Webhook(ctx context.Context) (string, error) {
	var raw json.RawMessage
	if err := c.read(ctx, "webhook", "/api/v1/open/webhook/query", nil, &raw); err != nil {
		return "", err
	}
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return strings.TrimSpace(text), nil
	}
	var object map[string]any
	if json.Unmarshal(raw, &object) == nil {
		for _, key := range []string{"webhook", "webhookUrl", "url"} {
			if value, ok := object[key].(string); ok {
				return strings.TrimSpace(value), nil
			}
		}
	}
	return "", nil
}

// SetWebhook sets where the account's events are posted. The API calls the
// address once (CHECK_HEALTH) and refuses one that does not answer.
func (c *Client) SetWebhook(ctx context.Context, address string) error {
	return c.once(ctx, "set webhook", "/api/v1/open/webhook/save", map[string]string{"webhook": address}, nil)
}
