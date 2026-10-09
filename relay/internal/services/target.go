package services

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
)

// Who an order is for is a customer's phone number or bill account, which the
// relay does not keep: the ledger holds the masked form ("+223•••••456"). A
// masked form is shared by many numbers, so it cannot tell a replay of an order
// from a different order sent under the same idempotency key. What tells them
// apart is a keyed digest of the full normalized target, kept in the order's
// write-once details:
//
//	HMAC-SHA256(key, "pointy-order-target/v1" 0 shop 0 kind 0 target 0 invoice 0 currency)
//
// cut to 16 hex digits (64 bits: two different targets share one by chance once
// in 2^64). It is keyed, never a plain hash, because a phone number has so few
// digits that a plain hash of it would be read back by trying them all; the key
// is a secret only the relay holds (cmd/pointy-relay derives it from the admin
// token, the way the node-proxy token is), so a copy of the ledger does not
// yield the numbers. The shop's id is part of the input, so the same number in
// two shops does not leave the same digest behind.
//
// The digest is not a secret of the order itself: nothing here is ever sent
// to a shop or a supplier.

// digestHexLength is how much of the HMAC is kept.
const digestHexLength = 16

// targetKeyID names the key a digest was made with (the first four hex digits of
// a keyed hash of a constant), so a digest made with a key that has since been
// rotated is told from a mismatch: it cannot be checked, which is not the same
// as a different order. Empty when there is no key.
func (s *Service) targetKeyID() string {
	if s == nil || len(s.cfg.TargetKey) == 0 {
		return ""
	}
	mac := hmac.New(sha256.New, s.cfg.TargetKey)
	mac.Write([]byte("pointy-order-target-key-id/v1"))
	return hex.EncodeToString(mac.Sum(nil))[:4]
}

// targetDigest is the keyed digest of an order's target: the digits of the phone
// number (country code first) or the account, the invoice number when the biller
// takes one, and the currency of the amount. Empty when the service has no key.
func (s *Service) targetDigest(installationID, kind, target, invoice, currency string) string {
	if s == nil || len(s.cfg.TargetKey) == 0 {
		return ""
	}
	mac := hmac.New(sha256.New, s.cfg.TargetKey)
	for _, part := range []string{
		"pointy-order-target/v1", strings.TrimSpace(installationID), kind, target, invoice,
		strings.ToUpper(strings.TrimSpace(currency)),
	} {
		mac.Write([]byte(part))
		mac.Write([]byte{0})
	}
	return hex.EncodeToString(mac.Sum(nil))[:digestHexLength]
}

// SameTarget says whether an order request is for the number or account that the
// ledger row it replays was placed for. It reads the row's details only (the
// digest, the calling codes the number was read with, whether an invoice was part
// of the order), never the directory, which may have changed since.
//
// known is false when the row cannot say: it was written before digests existed,
// or without a key, or with a key that has since been replaced. The caller then
// falls back to the masked target; it must not call such a replay a different
// order.
func (s *Service) SameTarget(installationID string, details json.RawMessage, request OrderRequest) (same, known bool) {
	var stored struct {
		Country    string   `json:"country"`
		Dial       []string `json:"dial"`
		HasInvoice bool     `json:"has_invoice"`
		KeyID      string   `json:"target_kid"`
		Digest     string   `json:"target_digest"`
	}
	if len(details) == 0 || json.Unmarshal(details, &stored) != nil {
		return false, false
	}
	if stored.Digest == "" || stored.KeyID == "" || stored.KeyID != s.targetKeyID() {
		return false, false
	}
	kind := strings.ToLower(strings.TrimSpace(request.Kind))
	var target, invoice string
	switch kind {
	case KindAirtime:
		// Recognising the number an order was placed for is not validating it: the
		// lengths a number must have today are not the lengths it once had to.
		phone, err := parsePhone(request.Phone, stored.Country, stored.Dial, false)
		if err != nil {
			// Not even a number of the country the order was for: another order.
			return false, true
		}
		target = phone.Digits()
	case KindBill:
		target = compactAccount(request.Account)
		if stored.HasInvoice {
			invoice = strings.TrimSpace(request.InvoiceID)
		}
	default:
		return false, false
	}
	want := s.targetDigest(installationID, kind, target, invoice, request.AmountCurrency)
	return hmac.Equal([]byte(want), []byte(stored.Digest)), true
}
