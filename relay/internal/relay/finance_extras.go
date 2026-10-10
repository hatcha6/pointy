package relay

import (
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

// Receipts behind the books' lines, and the monthly lines:
//
//	POST /v1/finance/attachments               store a photo or PDF ("file"); its ref
//	GET  /v1/finance/attachments/{sha256}      read one back
//	POST /v1/finance/entries/{id}/attachments  add a stored one to a line
//	GET  /v1/finance/recurring                 the monthly lines and what is due
//	POST /v1/finance/recurring                 a new monthly line
//	PATCH /v1/finance/recurring/{id}           change, skip a month, stop, resume
//
// Receipts share the bank-transfer receipt store: bytes by their SHA-256,
// typed from the bytes, never from the name.

type financeAttachmentRequest struct {
	SHA256 string `json:"sha256"`
	Name   string `json:"name"`
}

// resolveFinanceAttachments turns what the browser named into refs from the
// store: a hash nobody uploaded is refused.
func (s HTTPServer) resolveFinanceAttachments(ctx context.Context, requested []financeAttachmentRequest) ([]control.WalletReceiptRef, error) {
	if len(requested) == 0 {
		return nil, nil
	}
	bank, ok := s.walletBankStore()
	if !ok {
		return nil, errors.New("receipts are unavailable")
	}
	refs := make([]control.WalletReceiptRef, 0, len(requested))
	for _, item := range requested {
		sha := strings.ToLower(strings.TrimSpace(item.SHA256))
		if !control.ValidWalletReceiptHash(sha) {
			return nil, control.ErrInvalidFinanceEntry
		}
		receipt, err := bank.WalletReceipt(ctx, sha)
		if err != nil {
			return nil, err
		}
		refs = append(refs, control.WalletReceiptRef{SHA256: sha, ContentType: receipt.ContentType, Name: item.Name, Size: len(receipt.Data)})
	}
	return refs, nil
}

func (s HTTPServer) handleFinanceAttachmentUpload(w http.ResponseWriter, r *http.Request) {
	bank, ok := s.walletBankStore()
	if !ok {
		writeFinanceError(w, http.StatusNotImplemented, "unavailable", "receipts are unavailable")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, control.MaxWalletReceiptBytes+64<<10)
	if err := r.ParseMultipartForm(1 << 20); err != nil {
		writeFinanceError(w, http.StatusRequestEntityTooLarge, "too_large", "the file is larger than 10 MB")
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		writeFinanceError(w, http.StatusBadRequest, "invalid_request", `attach the file as "file"`)
		return
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, control.MaxWalletReceiptBytes+1))
	if err != nil || len(data) == 0 {
		writeFinanceError(w, http.StatusBadRequest, "invalid_request", "the file could not be read")
		return
	}
	if len(data) > control.MaxWalletReceiptBytes {
		writeFinanceError(w, http.StatusRequestEntityTooLarge, "too_large", "the file is larger than 10 MB")
		return
	}
	contentType := sniffWalletReceipt(data)
	if contentType == "" {
		writeFinanceError(w, http.StatusUnsupportedMediaType, "unsupported", "a receipt is a photo (JPEG, PNG, WebP) or a PDF")
		return
	}
	sum := sha256.Sum256(data)
	hash := hex.EncodeToString(sum[:])
	if err := bank.PutWalletReceipt(r.Context(), control.WalletReceipt{SHA256: hash, ContentType: contentType, Data: data}); err != nil {
		s.writeFinanceStoreError(w, "storing a finance receipt failed", err)
		return
	}
	name := strings.TrimSpace(header.Filename)
	if name == "" || utf8.RuneCountInString(name) > 120 {
		name = "receipt" + walletReceiptTypes[contentType]
	}
	writeJSON(w, http.StatusCreated, control.WalletReceiptRef{SHA256: hash, ContentType: contentType, Name: name, Size: len(data)})
}

func (s HTTPServer) handleFinanceAttachmentRead(w http.ResponseWriter, r *http.Request, sha string) {
	bank, ok := s.walletBankStore()
	if !ok || !control.ValidWalletReceiptHash(sha) {
		writeNotFound(w)
		return
	}
	receipt, err := bank.WalletReceipt(r.Context(), sha)
	if errors.Is(err, control.ErrWalletReceiptNotFound) {
		writeFinanceError(w, http.StatusNotFound, "not_found", "no such receipt")
		return
	}
	if err != nil {
		s.writeFinanceStoreError(w, "reading a finance receipt failed", err)
		return
	}
	w.Header().Set("Content-Type", receipt.ContentType)
	w.Header().Set("Content-Length", strconv.Itoa(len(receipt.Data)))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "private, max-age=3600, immutable")
	w.Header().Set("Content-Security-Policy", "sandbox; default-src 'none'")
	w.Header().Set("Content-Disposition", mime.FormatMediaType("inline", map[string]string{
		"filename": "receipt-" + sha[:12] + walletReceiptTypes[receipt.ContentType],
	}))
	_, _ = w.Write(receipt.Data)
}

func (s HTTPServer) handleFinanceAddAttachment(w http.ResponseWriter, r *http.Request, id string) {
	store, ok := s.financeStore(w)
	if !ok {
		return
	}
	var request financeAttachmentRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxFinanceRequestBytes)).Decode(&request); err != nil {
		writeFinanceError(w, http.StatusBadRequest, "invalid_request", "invalid request body")
		return
	}
	refs, err := s.resolveFinanceAttachments(r.Context(), []financeAttachmentRequest{request})
	if err != nil {
		s.writeFinanceAttachmentError(w, err)
		return
	}
	entry, err := store.AddFinanceAttachment(r.Context(), id, refs[0])
	if err != nil {
		s.writeFinanceAttachmentError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, entry)
}

func (s HTTPServer) writeFinanceAttachmentError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, control.ErrWalletReceiptNotFound):
		writeFinanceError(w, http.StatusBadRequest, "invalid_request", "upload the receipt first")
	case errors.Is(err, control.ErrFinanceAttachmentLimit):
		writeFinanceError(w, http.StatusConflict, "too_many", "ten receipts at most on one line")
	default:
		s.writeFinanceStoreError(w, "finance attachment failed", err)
	}
}

// --- monthly lines ------------------------------------------------------------

// postDueFinanceRecurring writes the line of every auto monthly line's due
// months. It runs before the books are read, so they are never behind; the
// month's key makes it safe to run anywhere, any number of times.
func (s HTTPServer) postDueFinanceRecurring(ctx context.Context, store control.FinanceStore) {
	list, err := store.ListFinanceRecurring(ctx)
	if err != nil || len(list) == 0 {
		return
	}
	posted, err := store.FinanceRecurringPosted(ctx)
	if err != nil {
		return
	}
	now := s.clock().Now()
	for _, r := range list {
		if r.Mode != control.FinanceRecurringAuto {
			continue
		}
		for _, month := range r.DueMonths(posted[r.ID], now) {
			_, _, err := store.CreateFinanceEntry(ctx, control.FinanceEntry{
				Direction:      r.Direction,
				Category:       r.Category,
				OriginalAmount: r.Amount,
				Currency:       r.Currency,
				Rate:           r.Rate,
				OccurredOn:     r.DueDay(month),
				Counterparty:   r.Counterparty,
				Note:           r.Note,
				InstallationID: r.InstallationID,
				IdempotencyKey: control.FinanceRecurringKey(r.ID, month),
				Actor:          r.Actor,
				RecurringID:    r.ID,
				RecurringMonth: month,
			})
			if err != nil {
				s.logger().Warn("a monthly line could not be written", "recurring_id", r.ID, "month", month, "error", err)
			}
		}
	}
}

type financeRecurringView struct {
	control.FinanceRecurring
	// Due are the months waiting for the operator (a confirm line).
	Due []string `json:"due"`
	// LastMonth is the latest month that has its line.
	LastMonth string `json:"last_month,omitempty"`
	// NextDay is when the next line falls due, if it is still running.
	NextDay string `json:"next_day,omitempty"`
}

func (s HTTPServer) handleFinanceRecurringList(w http.ResponseWriter, r *http.Request) {
	store, ok := s.financeStore(w)
	if !ok {
		return
	}
	s.postDueFinanceRecurring(r.Context(), store)
	list, err := store.ListFinanceRecurring(r.Context())
	if err != nil {
		s.writeFinanceStoreError(w, "monthly lines listing failed", err)
		return
	}
	posted, err := store.FinanceRecurringPosted(r.Context())
	if err != nil {
		s.writeFinanceStoreError(w, "monthly lines listing failed", err)
		return
	}
	now := s.clock().Now()
	today := control.FinanceDayStart(now).Format("2006-01-02")
	views := make([]financeRecurringView, 0, len(list))
	due := 0
	for _, item := range list {
		view := financeRecurringView{FinanceRecurring: item, Due: []string{}}
		for month := range posted[item.ID] {
			if month > view.LastMonth {
				view.LastMonth = month
			}
		}
		if item.Mode == control.FinanceRecurringConfirm {
			view.Due = item.DueMonths(posted[item.ID], now)
			due += len(view.Due)
		}
		if item.Active {
			month := control.FinanceMonth(now)
			if item.DueDay(month) <= today || posted[item.ID][month] {
				month = nextMonth(month)
			}
			if item.StartMonth > month {
				month = item.StartMonth
			}
			if item.EndMonth == "" || month <= item.EndMonth {
				view.NextDay = item.DueDay(month)
			}
		}
		views = append(views, view)
	}
	writeJSON(w, http.StatusOK, map[string]any{"recurring": views, "due_count": due})
}

func nextMonth(month string) string {
	y, _ := strconv.Atoi(month[:4])
	m, _ := strconv.Atoi(month[5:])
	m++
	if m > 12 {
		m, y = 1, y+1
	}
	return strconv.Itoa(y) + "-" + string([]byte{byte('0' + m/10), byte('0' + m%10)})
}

func (s HTTPServer) handleFinanceRecurringCreate(w http.ResponseWriter, r *http.Request) {
	store, ok := s.financeStore(w)
	if !ok {
		return
	}
	var request control.FinanceRecurring
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxFinanceRequestBytes)).Decode(&request); err != nil {
		writeFinanceError(w, http.StatusBadRequest, "invalid_request", "invalid request body")
		return
	}
	if strings.TrimSpace(request.Actor) == "" {
		writeFinanceError(w, http.StatusBadRequest, "invalid_request", "actor is required")
		return
	}
	created, err := store.CreateFinanceRecurring(r.Context(), request)
	if err != nil {
		s.writeFinanceStoreError(w, "monthly line failed", err)
		return
	}
	writeJSON(w, http.StatusCreated, created)
}

func (s HTTPServer) handleFinanceRecurringUpdate(w http.ResponseWriter, r *http.Request, id string) {
	store, ok := s.financeStore(w)
	if !ok {
		return
	}
	var change control.FinanceRecurringChange
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxFinanceRequestBytes)).Decode(&change); err != nil {
		writeFinanceError(w, http.StatusBadRequest, "invalid_request", "invalid request body")
		return
	}
	updated, err := store.UpdateFinanceRecurring(r.Context(), id, change)
	if err != nil {
		s.writeFinanceStoreError(w, "monthly line change failed", err)
		return
	}
	writeJSON(w, http.StatusOK, updated)
}
