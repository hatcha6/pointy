package relay

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"unicode/utf8"

	"pointy/relay/internal/control"
)

// Bank-transfer top-ups. The shop transfers to one of the company's accounts
// with LYPay or OnePay, then sends the amount, its own account (bank, number
// and IBAN) and the receipt. The top-up waits in review until an operator
// finds the money on the company's statement and credits it — or rejects it
// with a reason the shop reads. The receipt never credits anything; it is
// what lets the operator find the transfer fast.

const (
	walletCodeBankTransferUnavailable = "bank_transfer_unavailable"
	walletCodeInvalidChannel          = "invalid_channel"
	walletCodeInvalidPayerBank        = "invalid_payer_bank"
	walletCodeInvalidPayerAccount     = "invalid_payer_account"
	walletCodeInvalidIBAN             = "invalid_iban"
	walletCodeInvalidReceipt          = "invalid_receipt"
	walletCodeReceiptTooLarge         = "receipt_too_large"
	walletCodeTooManyReviews          = "too_many_reviews"
	walletCodeNotInReview             = "not_in_review"
	walletKindBankTransfer            = "bank_transfer"
)

const (
	// maxWalletReviews is how many transfers one shop may have waiting at
	// once: enough for a real day, too few to flood the operators.
	maxWalletReviews = 5
	// walletSavedPayers is how many of its own accounts a shop is offered.
	walletSavedPayers = 5
	// walletRejectReasonMinRunes keeps a rejection readable to the shop.
	walletRejectReasonMinRunes = 3
)

// walletReceiptTypes are the receipts an operator's browser can show.
var walletReceiptTypes = map[string]string{
	"image/jpeg":      ".jpg",
	"image/png":       ".png",
	"image/webp":      ".webp",
	"application/pdf": ".pdf",
}

func (s HTTPServer) walletBankStore() (control.WalletBankStore, bool) {
	store, ok := s.Store.(control.WalletBankStore)
	return store, ok
}

// walletBankOffer is the bank-transfer block of the shop's wallet: the
// company's accounts and the shop's own accounts it paid from before.
func (s HTTPServer) walletBankOffer(ctx context.Context, installationID string, recent []control.WalletTopUp) map[string]any {
	offer := map[string]any{"available": false, "accounts": []any{}, "saved_payers": []any{}}
	store, ok := s.walletBankStore()
	if !ok {
		return offer
	}
	settings, err := store.WalletBankSettings(ctx)
	if err != nil {
		s.logger().Warn("reading the bank accounts failed", "error", err)
		return offer
	}
	accounts := settings.EnabledAccounts()
	if len(accounts) == 0 {
		return offer
	}
	walletStore, _ := s.walletStore()
	topUps := recent
	if walletStore != nil {
		if listed, err := walletStore.ListWalletTopUps(ctx, control.WalletTopUpFilter{
			InstallationID: installationID, Limit: 100,
		}); err == nil {
			topUps = listed
		}
	}
	offer["available"] = true
	offer["accounts"] = accounts
	offer["saved_payers"] = control.SavedWalletPayers(topUps, walletSavedPayers)
	offer["channels"] = []string{control.WalletTransferLYPay, control.WalletTransferOnePay}
	offer["max_receipt_bytes"] = control.MaxWalletReceiptBytes
	offer["receipt_types"] = []string{"image/jpeg", "image/png", "image/webp", "application/pdf"}
	return offer
}

// handleWalletBankTransferCreate serves POST /v1/wallet/topups/bank-transfer,
// a multipart form: the transfer's fields and the receipt as "receipt".
func (s HTTPServer) handleWalletBankTransferCreate(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	bank, ok := s.walletBankStore()
	if !ok {
		writeWalletError(w, http.StatusServiceUnavailable, walletCodeBankTransferUnavailable,
			"bank transfers are unavailable on this relay", nil)
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, control.MaxWalletReceiptBytes+maxWalletRequestBytes)
	if err := r.ParseMultipartForm(1 << 20); err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			writeWalletError(w, http.StatusRequestEntityTooLarge, walletCodeReceiptTooLarge,
				"the receipt is larger than 10 MB", map[string]any{"max_receipt_bytes": control.MaxWalletReceiptBytes})
			return
		}
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest, "invalid multipart form", nil)
		return
	}
	defer r.MultipartForm.RemoveAll()
	field := func(name string) string { return strings.TrimSpace(r.FormValue(name)) }

	ctx := r.Context()
	settings, err := bank.WalletBankSettings(ctx)
	if err != nil {
		s.writeWalletInternalError(w, "reading the bank accounts failed", installation.ID, err)
		return
	}
	accounts := settings.EnabledAccounts()
	if len(accounts) == 0 {
		writeWalletError(w, http.StatusServiceUnavailable, walletCodeBankTransferUnavailable,
			"no bank account is set up to receive transfers", nil)
		return
	}
	to := accounts[0]
	if id := field("to_account"); id != "" {
		if to, ok = settings.Account(id); !ok {
			writeWalletError(w, http.StatusUnprocessableEntity, walletCodeBankTransferUnavailable,
				"that receiving account is no longer offered", nil)
			return
		}
	}
	key := field("idempotency_key")
	if key == "" || utf8.RuneCountInString(key) > 128 {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest,
			"idempotency_key is required (at most 128 characters)", nil)
		return
	}
	amount, rejection := s.validateTopUpAmount(json.RawMessage(strconv.Quote(field("amount"))))
	if rejection != "" {
		minimum, maximum := s.Wallet.topUpBounds()
		writeWalletError(w, http.StatusUnprocessableEntity, walletCodeInvalidAmount, rejection, map[string]any{
			"min_amount":   minimum.FloatString(walletTopUpDecimals),
			"max_amount":   maximum.FloatString(walletTopUpDecimals),
			"max_decimals": walletTopUpDecimals,
		})
		return
	}
	transfer, code, rejection := validateBankTransfer(field)
	if code != "" {
		writeWalletError(w, http.StatusUnprocessableEntity, code, rejection, nil)
		return
	}
	transfer.ToAccount = to.ID

	// A replayed key answers the first top-up before the receipt is read
	// again: the app retrying a slow upload must not make a second one.
	if existing, found := s.walletTopUpByKey(ctx, store, installation.ID, key); found {
		writeJSON(w, http.StatusOK, map[string]any{"top_up": walletTopUpPayload(existing), "replayed": true})
		return
	}
	receipt, code, rejection := readWalletReceipt(r)
	if code != "" {
		status := http.StatusUnprocessableEntity
		if code == walletCodeReceiptTooLarge {
			status = http.StatusRequestEntityTooLarge
		}
		writeWalletError(w, status, code, rejection, nil)
		return
	}
	waiting, err := store.ListWalletTopUps(ctx, control.WalletTopUpFilter{
		InstallationID: installation.ID, Status: control.WalletTopUpReview, Limit: maxWalletReviews,
	})
	if err != nil {
		s.writeWalletInternalError(w, "listing transfers in review failed", installation.ID, err)
		return
	}
	if len(waiting) >= maxWalletReviews {
		writeWalletError(w, http.StatusTooManyRequests, walletCodeTooManyReviews,
			"several transfers are already waiting to be checked", nil)
		return
	}
	if s.enforceWalletTopUpRateLimit(w, r, installation.ID) {
		return
	}
	if err := bank.PutWalletReceipt(ctx, receipt.WalletReceipt); err != nil {
		s.writeWalletInternalError(w, "storing a receipt failed", installation.ID, err)
		return
	}
	transfer.Receipt = receipt.ref
	requestedBy := field("requested_by")
	if utf8.RuneCountInString(requestedBy) > maxWalletRequestedByRunes {
		requestedBy = string([]rune(requestedBy)[:maxWalletRequestedByRunes])
	}
	topUp, created, err := store.BeginWalletTopUp(ctx, control.WalletTopUp{
		InstallationID: installation.ID,
		Method:         control.WalletTopUpMethodBankTransfer,
		Amount:         control.FormatWalletAmount(amount),
		IdempotencyKey: key,
		RequestedBy:    requestedBy,
		PayerHint:      maskIBAN(transfer.PayerIBAN),
		TestMode:       s.Wallet.TestMode,
		Transfer:       &transfer,
	})
	if err != nil {
		s.writeWalletInternalError(w, "recording a bank transfer failed", installation.ID, err)
		return
	}
	if !created {
		writeJSON(w, http.StatusOK, map[string]any{"top_up": walletTopUpPayload(topUp), "replayed": true})
		return
	}
	topUp.ShopName = installation.ShopName
	s.logWalletTopUp(installation.ID, topUp, "bank_transfer_submitted", "")
	writeJSON(w, http.StatusCreated, map[string]any{
		"top_up":      walletTopUpPayload(topUp),
		"next_action": walletKindBankTransfer,
	})
}

func (s HTTPServer) walletTopUpByKey(ctx context.Context, store control.WalletStore, installationID, key string) (control.WalletTopUp, bool) {
	topUps, err := store.ListWalletTopUps(ctx, control.WalletTopUpFilter{InstallationID: installationID, Limit: 200})
	if err != nil {
		return control.WalletTopUp{}, false
	}
	for _, topUp := range topUps {
		if topUp.IdempotencyKey == key {
			return topUp, true
		}
	}
	return control.WalletTopUp{}, false
}

// validateBankTransfer checks the payer's account as the shop typed it.
func validateBankTransfer(field func(string) string) (control.WalletBankTransfer, string, string) {
	transfer := control.WalletBankTransfer{
		Channel:      strings.ToLower(field("channel")),
		PayerBank:    strings.ToLower(field("payer_bank")),
		PayerAccount: control.NormalizeBankAccountNumber(field("payer_account")),
		PayerIBAN:    control.NormalizeIBAN(field("payer_iban")),
	}
	switch {
	case !control.ValidWalletTransferChannel(transfer.Channel):
		return transfer, walletCodeInvalidChannel, "channel must be lypay or onepay"
	case !control.ValidBankSlug(transfer.PayerBank):
		return transfer, walletCodeInvalidPayerBank, "payer_bank must name the payer's bank"
	case !control.ValidBankAccountNumber(transfer.PayerAccount):
		return transfer, walletCodeInvalidPayerAccount, "payer_account must be the payer's account number (digits)"
	case !control.ValidLibyanIBAN(transfer.PayerIBAN):
		return transfer, walletCodeInvalidIBAN, "payer_iban must be a valid Libyan IBAN (LY + 23 digits)"
	}
	return transfer, "", ""
}

type walletReceiptUpload struct {
	control.WalletReceipt
	ref control.WalletReceiptRef
}

// readWalletReceipt reads the "receipt" file and decides its type from its
// bytes, never from the name or the header the client sent.
func readWalletReceipt(r *http.Request) (walletReceiptUpload, string, string) {
	file, header, err := r.FormFile("receipt")
	if err != nil {
		return walletReceiptUpload{}, walletCodeInvalidReceipt, "attach the transfer's receipt as \"receipt\""
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, control.MaxWalletReceiptBytes+1))
	if err != nil {
		return walletReceiptUpload{}, walletCodeInvalidReceipt, "the receipt could not be read"
	}
	if len(data) > control.MaxWalletReceiptBytes {
		return walletReceiptUpload{}, walletCodeReceiptTooLarge, "the receipt is larger than 10 MB"
	}
	contentType := sniffWalletReceipt(data)
	if contentType == "" {
		return walletReceiptUpload{}, walletCodeInvalidReceipt, "the receipt must be a photo (JPEG, PNG, WebP) or a PDF"
	}
	sum := sha256.Sum256(data)
	hash := hex.EncodeToString(sum[:])
	name := strings.TrimSpace(header.Filename)
	if utf8.RuneCountInString(name) > 120 || name == "" {
		name = "receipt" + walletReceiptTypes[contentType]
	}
	return walletReceiptUpload{
		WalletReceipt: control.WalletReceipt{SHA256: hash, ContentType: contentType, Data: data},
		ref:           control.WalletReceiptRef{SHA256: hash, ContentType: contentType, Name: name, Size: len(data)},
	}, "", ""
}

func sniffWalletReceipt(data []byte) string {
	if bytes.HasPrefix(data, []byte("%PDF-")) {
		return "application/pdf"
	}
	detected, _, _ := mime.ParseMediaType(http.DetectContentType(data))
	if _, ok := walletReceiptTypes[detected]; ok && detected != "application/pdf" {
		return detected
	}
	return ""
}

// maskIBAN is the payer's IBAN as the history row shows it: its last four.
func maskIBAN(iban string) string {
	if len(iban) < 8 {
		return ""
	}
	return "LY•••" + iban[len(iban)-4:]
}

// --- the operator's side ---

// handleWalletAdminTopUp serves GET /v1/wallet/admin/topups/{id}: one top-up
// with what the operator needs to decide it: the account it was sent to, and
// every other top-up that sent the same receipt.
func (s HTTPServer) handleWalletAdminTopUp(w http.ResponseWriter, r *http.Request, id string) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	ctx := r.Context()
	topUp, err := store.GetWalletTopUp(ctx, id)
	if errors.Is(err, control.ErrWalletTopUpNotFound) {
		writeWalletError(w, http.StatusNotFound, walletCodeNotFound, "top-up not found", nil)
		return
	}
	if err != nil {
		s.writeWalletInternalError(w, "reading a top-up failed", "", err)
		return
	}
	body := map[string]any{"top_up": topUp, "duplicates": []control.WalletTopUp{}}
	bank, hasBank := s.walletBankStore()
	if hasBank && topUp.Transfer != nil {
		if settings, err := bank.WalletBankSettings(ctx); err == nil {
			for _, account := range settings.Accounts {
				if account.ID == topUp.Transfer.ToAccount {
					body["account"] = account
				}
			}
		}
		if sha := topUp.Transfer.Receipt.SHA256; sha != "" {
			if others, err := bank.WalletTopUpsByReceipt(ctx, sha); err == nil {
				duplicates := []control.WalletTopUp{}
				for _, other := range others {
					if other.ID != topUp.ID {
						duplicates = append(duplicates, other)
					}
				}
				body["duplicates"] = duplicates
			}
		}
	}
	writeJSON(w, http.StatusOK, body)
}

// handleWalletAdminReceipt serves GET /v1/wallet/admin/topups/{id}/receipt.
func (s HTTPServer) handleWalletAdminReceipt(w http.ResponseWriter, r *http.Request, id string) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	bank, ok := s.walletBankStore()
	if !ok {
		writeNotFound(w)
		return
	}
	topUp, err := store.GetWalletTopUp(r.Context(), id)
	if err != nil || topUp.Transfer == nil || topUp.Transfer.Receipt.SHA256 == "" {
		writeWalletError(w, http.StatusNotFound, walletCodeNotFound, "no receipt for this top-up", nil)
		return
	}
	receipt, err := bank.WalletReceipt(r.Context(), topUp.Transfer.Receipt.SHA256)
	if errors.Is(err, control.ErrWalletReceiptNotFound) {
		writeWalletError(w, http.StatusNotFound, walletCodeNotFound, "the receipt is missing", nil)
		return
	}
	if err != nil {
		s.writeWalletInternalError(w, "reading a receipt failed", topUp.InstallationID, err)
		return
	}
	w.Header().Set("Content-Type", receipt.ContentType)
	w.Header().Set("Content-Length", strconv.Itoa(len(receipt.Data)))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "private, max-age=3600, immutable")
	w.Header().Set("Content-Security-Policy", "sandbox; default-src 'none'")
	w.Header().Set("Content-Disposition", mime.FormatMediaType("inline", map[string]string{
		"filename": "receipt-" + topUp.InvoiceNo + walletReceiptTypes[receipt.ContentType],
	}))
	_, _ = w.Write(receipt.Data)
}

type walletAdminRejectRequest struct {
	Actor  string `json:"actor"`
	Reason string `json:"reason"`
}

// handleWalletAdminRejectTopUp serves POST /v1/wallet/admin/topups/{id}/reject:
// a bank transfer the operator could not find, or that does not match. The
// reason is shown to the shop as written.
func (s HTTPServer) handleWalletAdminRejectTopUp(w http.ResponseWriter, r *http.Request, id string) {
	bank, ok := s.walletBankStore()
	if !ok {
		writeNotFound(w)
		return
	}
	var request walletAdminRejectRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxWalletRequestBytes)).Decode(&request); err != nil {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest, "invalid request body", nil)
		return
	}
	actor := strings.TrimSpace(request.Actor)
	reason := strings.TrimSpace(request.Reason)
	if actor == "" || utf8.RuneCountInString(reason) < walletRejectReasonMinRunes {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest,
			"actor and reason are required: the shop is shown the reason", nil)
		return
	}
	topUp, applied, err := bank.RejectWalletTopUp(r.Context(), id, actor, reason)
	if errors.Is(err, control.ErrWalletTopUpNotFound) {
		writeWalletError(w, http.StatusNotFound, walletCodeNotFound, "top-up not found", nil)
		return
	}
	if err != nil {
		s.writeWalletInternalError(w, "rejecting a top-up failed", "", err)
		return
	}
	if !applied {
		writeWalletError(w, http.StatusConflict, walletCodeNotInReview,
			"only a bank transfer waiting for review can be rejected", map[string]any{"top_up": topUp})
		return
	}
	s.logWalletTopUp(topUp.InstallationID, topUp, "operator_rejected", actor)
	writeJSON(w, http.StatusOK, map[string]any{"top_up": topUp, "applied": true})
}

// handleWalletAdminBankAccounts serves GET and PUT
// /v1/wallet/admin/bank-accounts: the company's receiving accounts.
func (s HTTPServer) handleWalletAdminBankAccounts(w http.ResponseWriter, r *http.Request) {
	bank, ok := s.walletBankStore()
	if !ok {
		writeWalletError(w, http.StatusServiceUnavailable, walletCodeBankTransferUnavailable,
			"bank transfers are unavailable on this relay", nil)
		return
	}
	if r.Method == http.MethodGet {
		settings, err := bank.WalletBankSettings(r.Context())
		if err != nil {
			s.writeWalletInternalError(w, "reading the bank accounts failed", "", err)
			return
		}
		writeJSON(w, http.StatusOK, settings)
		return
	}
	var request struct {
		Accounts []control.WalletBankAccount `json:"accounts"`
		Actor    string                      `json:"actor"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxWalletRequestBytes)).Decode(&request); err != nil {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest, "invalid request body", nil)
		return
	}
	saved, err := bank.SaveWalletBankSettings(r.Context(), control.WalletBankSettings{
		Accounts:  request.Accounts,
		UpdatedBy: request.Actor,
	})
	if errors.Is(err, control.ErrInvalidBankAccount) {
		writeWalletError(w, http.StatusUnprocessableEntity, walletCodeInvalidRequest,
			"each account needs a bank, its name, the holder, a numeric account number and a valid Libyan IBAN", nil)
		return
	}
	if err != nil {
		s.writeWalletInternalError(w, "saving the bank accounts failed", "", err)
		return
	}
	s.logger().Warn("wallet receiving accounts changed", "actor", request.Actor, "accounts", len(saved.Accounts))
	writeJSON(w, http.StatusOK, saved)
}

// bankTransferConfirmation is the settlement an operator's confirm makes for
// a bank transfer: the statement's reference is optional (the operator has
// the money in front of them), and the amount may be what actually arrived.
func bankTransferConfirmation(topUp control.WalletTopUp, request walletAdminConfirmRequest, actor string) (control.WalletTopUpSettlement, string) {
	settlement := control.WalletTopUpSettlement{
		ProviderTransactionID: strings.TrimSpace(request.ProviderTransactionID),
		ConfirmedBy:           "operator:" + actor,
		Description:           "شحن المحفظة " + topUp.InvoiceNo + " (تحويل مصرفي)",
	}
	if raw := strings.TrimSpace(request.Amount); raw != "" {
		amount, err := control.ParseWalletAmount(raw)
		if err != nil || amount.Sign() <= 0 || control.WalletAmountDecimals(raw) > walletTopUpDecimals {
			return control.WalletTopUpSettlement{}, "amount must be a positive number of dinars"
		}
		settlement.Amount = control.FormatWalletAmount(amount)
	}
	return settlement, ""
}

// confirmBankTransfer credits a bank transfer the operator found on the
// company's statement.
func (s HTTPServer) confirmBankTransfer(
	w http.ResponseWriter,
	r *http.Request,
	store control.WalletStore,
	topUp control.WalletTopUp,
	request walletAdminConfirmRequest,
	actor string,
) {
	if actor == "" {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest, "actor is required", nil)
		return
	}
	if topUp.Status != control.WalletTopUpReview && topUp.Status != control.WalletTopUpRejected {
		if topUp.Status == control.WalletTopUpPaid {
			writeJSON(w, http.StatusOK, map[string]any{"top_up": topUp, "applied": false})
			return
		}
		writeWalletError(w, http.StatusConflict, walletCodeNotInReview, "this transfer is not waiting for review", nil)
		return
	}
	settlement, rejection := bankTransferConfirmation(topUp, request, actor)
	if rejection != "" {
		writeWalletError(w, http.StatusUnprocessableEntity, walletCodeInvalidAmount, rejection, nil)
		return
	}
	settled, applied, err := store.SettleWalletTopUp(r.Context(), topUp.ID, settlement)
	if err != nil {
		s.writeWalletInternalError(w, "confirming a bank transfer failed", topUp.InstallationID, err)
		return
	}
	if applied {
		settled.ShopName = topUp.ShopName
		s.logWalletTopUp(settled.InstallationID, settled, "operator_confirmed", actor)
	}
	writeJSON(w, http.StatusOK, map[string]any{"top_up": settled, "applied": applied})
}
