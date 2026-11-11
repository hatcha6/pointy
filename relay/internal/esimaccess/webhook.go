package esimaccess

import (
	"encoding/json"
	"strings"
)

// Webhook event types.
const (
	NotifyOrderStatus   = "ORDER_STATUS"
	NotifyESIMStatus    = "ESIM_STATUS"
	NotifyDataUsage     = "DATA_USAGE"
	NotifyValidityUsage = "VALIDITY_USAGE"
	NotifySMDPEvent     = "SMDP_EVENT"
	NotifyCheckHealth   = "CHECK_HEALTH"
)

// Event is one webhook delivery. The API does not sign its deliveries: nothing
// in one is believed. It only says which eSIM to read again.
type Event struct {
	Type    string `json:"notifyType"`
	ID      string `json:"notifyId"`
	Content struct {
		ICCID         string `json:"iccid"`
		OrderNo       string `json:"orderNo"`
		TranNo        string `json:"esimTranNo"`
		TransactionID string `json:"transactionId"`
	} `json:"content"`
}

// DecodeEvent reads a delivery's body.
func DecodeEvent(body []byte) (Event, bool) {
	var event Event
	if err := json.Unmarshal(body, &event); err != nil {
		return Event{}, false
	}
	event.Type = strings.ToUpper(strings.TrimSpace(event.Type))
	return event, event.Type != ""
}

// AboutUsage reports an event after which an eSIM's usage is worth reading.
func (e Event) AboutUsage() bool {
	switch e.Type {
	case NotifyDataUsage, NotifyValidityUsage, NotifyESIMStatus:
		return e.Content.ICCID != "" || e.Content.TranNo != ""
	}
	return false
}
