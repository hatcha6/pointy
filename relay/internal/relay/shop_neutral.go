package relay

import (
	"strings"

	"pointy/relay/internal/services"
	"pointy/relay/internal/vouchers"
)

// Shops never learn which supplier the company buys from. The relay's own
// ledger, logs and admin views keep the supplier's codes, ids and sentences;
// everything a shop reads goes through these functions first.
//
//	supplier_out_of_stock                          out_of_stock
//	supplier_refused                               refused
//	supplier_credit / _unauthorized / _unreachable unavailable
//	supplier_unknown                               unknown
const (
	shopFailureOutOfStock  = "out_of_stock"
	shopFailureRefused     = "refused"
	shopFailureUnavailable = "unavailable"
	shopFailureUnknown     = "unknown"
)

// shopFailureCode is the code of a failed purchase as a shop reads it.
func shopFailureCode(code string) string {
	switch code {
	case vouchers.FailureOutOfStock:
		return shopFailureOutOfStock
	case vouchers.FailureRefused:
		return shopFailureRefused
	case vouchers.FailureUnknown:
		return shopFailureUnknown
	case vouchers.FailureCredit, vouchers.FailureUnauthorized, vouchers.FailureUnreachable:
		return shopFailureUnavailable
	}
	if strings.HasPrefix(code, "supplier_") {
		return shopFailureUnavailable
	}
	return code
}

// shopFailureDetail is the detail of a failed purchase as a shop reads it: the
// relay's own words when the failure was its own, a fixed sentence when the
// supplier's code or sentence is behind it.
func shopFailureDetail(code, detail string) string {
	if !strings.HasPrefix(code, "supplier_") {
		return detail
	}
	switch shopFailureCode(code) {
	case shopFailureOutOfStock:
		return "the item is out of stock"
	case shopFailureRefused:
		return "the order was refused"
	case shopFailureUnknown:
		return "the order has not finished"
	}
	return "the service is unavailable right now"
}

// shopReceipt is a receipt as a shop reads it: the supplier's transaction id is
// replaced by the purchase's own id, and the supplier's suffix is cut off the
// operator's reference.
func shopReceipt(purchaseID string, receipt map[string]string) map[string]string {
	if len(receipt) == 0 {
		return receipt
	}
	cleaned := make(map[string]string, len(receipt))
	for key, value := range receipt {
		cleaned[key] = value
	}
	if _, ok := cleaned[services.ReceiptTransactionID]; ok {
		cleaned[services.ReceiptTransactionID] = purchaseID
	}
	for _, key := range []string{services.ReceiptOperatorReference, services.ReceiptBillerReference} {
		if value, ok := cleaned[key]; ok {
			cleaned[key] = strings.TrimSuffix(value, ":OrderConfirmed")
		}
	}
	return cleaned
}
