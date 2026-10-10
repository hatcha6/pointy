package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/control"
)

func financeRequest(t *testing.T, server HTTPServer, method, path, body string) (int, map[string]any) {
	t.Helper()
	req := httptest.NewRequest(method, "http://relay"+path, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-token")
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	var decoded map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &decoded)
	return rec.Code, decoded
}

func TestFinanceEntriesAndSummary(t *testing.T) {
	store, provisioned := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:      store,
		Hub:        NewHub(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken: "admin-token",
	}
	ctx := context.Background()
	shop := provisioned.Installation.ID
	// The test clock reads 2 June 2026: a shop paid 30 for texts and 50 for the
	// assistant this month.
	if _, _, err := store.PostWalletEntry(ctx, control.WalletPosting{
		InstallationID: shop, Kind: control.WalletEntryAdjustment, Amount: "200", Description: "cash", IdempotencyKey: "a", Actor: "ops",
	}); err != nil {
		t.Fatal(err)
	}
	for key, posting := range map[string][2]string{"c1": {control.WalletServiceSMS, "-30"}, "c2": {control.WalletServiceAI, "-50"}} {
		if _, _, err := store.PostWalletEntry(ctx, control.WalletPosting{
			InstallationID: shop, Kind: control.WalletEntryCharge, Service: posting[0], Amount: posting[1], IdempotencyKey: key, Actor: "ops",
		}); err != nil {
			t.Fatal(err)
		}
	}

	if code, _ := financeRequest(t, server, http.MethodPost, "/v1/finance/entries",
		`{"direction":"expense","category":"hosting","amount":"40","occurred_on":"2026-06-01","idempotency_key":"x"}`); code != http.StatusBadRequest {
		t.Fatalf("an entry without an actor: %d", code)
	}
	code, created := financeRequest(t, server, http.MethodPost, "/v1/finance/entries",
		`{"direction":"expense","category":"hosting","amount":"40","occurred_on":"2026-06-01","idempotency_key":"x","actor":"Hatem","installation_id":"`+shop+`"}`)
	if code != http.StatusCreated || created["amount"] != "40.000" {
		t.Fatalf("create %d %v", code, created)
	}
	if code, again := financeRequest(t, server, http.MethodPost, "/v1/finance/entries",
		`{"direction":"expense","category":"hosting","amount":"40","occurred_on":"2026-06-01","idempotency_key":"x","actor":"Hatem"}`); code != http.StatusOK || again["id"] != created["id"] {
		t.Fatalf("retry %d %v", code, again)
	}
	if code, body := financeRequest(t, server, http.MethodPost, "/v1/finance/entries",
		`{"direction":"income","category":"cash_subscription","amount":"abc","occurred_on":"2026-06-01","idempotency_key":"y","actor":"Hatem"}`); code != http.StatusBadRequest || !strings.Contains(body["error"].(string), "amount") {
		t.Fatalf("bad amount %d %v", code, body)
	}
	if code, _ := financeRequest(t, server, http.MethodPost, "/v1/finance/entries",
		`{"direction":"income","category":"cash_subscription","amount":"100","occurred_on":"2026-06-02","idempotency_key":"z","actor":"Hatem"}`); code != http.StatusCreated {
		t.Fatalf("income %d", code)
	}

	code, listed := financeRequest(t, server, http.MethodGet, "/v1/finance/entries?from=2026-06-01", "")
	if code != http.StatusOK || listed["count"].(float64) != 2 {
		t.Fatalf("list %d %v", code, listed)
	}

	code, summary := financeRequest(t, server, http.MethodGet, "/v1/finance/summary?from=2026-06-01&to=2026-06-30", "")
	if code != http.StatusOK {
		t.Fatalf("summary %d %v", code, summary)
	}
	totals := summary["totals"].(map[string]any)
	// Income: 30 SMS + 50 assistant + 100 cash. Expense: 40 hosting. The
	// 200 cash credit is the shop's money, not ours.
	if totals["income"] != "180.000" || totals["expense"] != "40.000" || totals["net"] != "140.000" || totals["margin_percent"] != "77.8" {
		t.Fatalf("totals %v", totals)
	}
	if months := summary["months"].([]any); len(months) != 1 || months[0].(map[string]any)["net"] != "140.000" {
		t.Fatalf("months %v", months)
	}
	if lines := summary["income"].([]any); len(lines) != 3 || lines[0].(map[string]any)["key"] != "cash_subscription" {
		t.Fatalf("income lines %v", lines)
	}
	if previous := summary["previous"].(map[string]any); previous["from"] != "2026-05-02" || previous["to"] != "2026-05-31" {
		t.Fatalf("previous period %v", previous)
	}

	// A void takes the line out of the result.
	if code, _ := financeRequest(t, server, http.MethodPost, "/v1/finance/entries/"+created["id"].(string)+"/void", `{"actor":"Hatem","reason":"wrong month"}`); code != http.StatusOK {
		t.Fatalf("void %d", code)
	}
	_, summary = financeRequest(t, server, http.MethodGet, "/v1/finance/summary?from=2026-06-01&to=2026-06-30", "")
	if net := summary["totals"].(map[string]any)["net"]; net != "180.000" {
		t.Fatalf("net after void %v", net)
	}

	if code, _ := financeRequest(t, server, http.MethodGet, "/v1/finance/summary?from=2026-07-01&to=2026-06-01", ""); code != http.StatusBadRequest {
		t.Fatalf("a backwards period %d", code)
	}
	req := httptest.NewRequest(http.MethodGet, "http://relay/v1/finance/summary", nil)
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("the books are admin-only: %d", rec.Code)
	}
}

func TestFinanceRecurringPostsItselfAndWaitsForConfirm(t *testing.T) {
	store, _ := provisionRelayInstallation(t)
	server := HTTPServer{Store: store, Hub: NewHub(), Logger: slog.New(slog.NewTextHandler(io.Discard, nil)), AdminToken: "admin-token",
		Clock: testClock{now: time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)}}
	// The test clock reads 2 June 2026.
	if code, _ := financeRequest(t, server, http.MethodPost, "/v1/finance/recurring",
		`{"direction":"expense","category":"rent","amount":"800","day_of_month":1,"start_month":"2026-04","mode":"auto","actor":"Hatem"}`); code != http.StatusCreated {
		t.Fatalf("auto %d", code)
	}
	code, confirm := financeRequest(t, server, http.MethodPost, "/v1/finance/recurring",
		`{"direction":"expense","category":"utilities","amount":"150","day_of_month":1,"start_month":"2026-05","mode":"confirm","actor":"Hatem"}`)
	if code != http.StatusCreated {
		t.Fatalf("confirm %d", code)
	}
	// Reading the books writes April, May and June's rent, once.
	for i := 0; i < 2; i++ {
		_, listed := financeRequest(t, server, http.MethodGet, "/v1/finance/entries", "")
		if listed["count"].(float64) != 3 {
			t.Fatalf("auto lines %v", listed)
		}
	}
	_, list := financeRequest(t, server, http.MethodGet, "/v1/finance/recurring", "")
	if list["due_count"].(float64) != 2 {
		t.Fatalf("confirm due %v", list)
	}
	id := confirm["id"].(string)
	// May had a different bill; June is skipped.
	if code, _ := financeRequest(t, server, http.MethodPost, "/v1/finance/entries",
		`{"direction":"expense","category":"utilities","amount":"172.5","occurred_on":"2026-05-03","recurring_id":"`+id+`","recurring_month":"2026-05","actor":"Hatem"}`); code != http.StatusCreated {
		t.Fatalf("confirm May %d", code)
	}
	if code, _ := financeRequest(t, server, http.MethodPatch, "/v1/finance/recurring/"+id, `{"skip":"2026-06"}`); code != http.StatusOK {
		t.Fatalf("skip %d", code)
	}
	_, list = financeRequest(t, server, http.MethodGet, "/v1/finance/recurring", "")
	if list["due_count"].(float64) != 0 {
		t.Fatalf("still due %v", list)
	}
}

func TestFinanceAttachmentUploadAndRead(t *testing.T) {
	store, _ := provisionRelayInstallation(t)
	server := HTTPServer{Store: store, Hub: NewHub(), Logger: slog.New(slog.NewTextHandler(io.Discard, nil)), AdminToken: "admin-token"}
	upload := func(name string, data []byte) (int, map[string]any) {
		var body bytes.Buffer
		form := multipart.NewWriter(&body)
		part, _ := form.CreateFormFile("file", name)
		_, _ = part.Write(data)
		_ = form.Close()
		req := httptest.NewRequest(http.MethodPost, "http://relay/v1/finance/attachments", &body)
		req.Header.Set("Content-Type", form.FormDataContentType())
		req.Header.Set("Authorization", "Bearer admin-token")
		rec := httptest.NewRecorder()
		server.ServeHTTP(rec, req)
		var decoded map[string]any
		_ = json.Unmarshal(rec.Body.Bytes(), &decoded)
		return rec.Code, decoded
	}
	if code, _ := upload("evil.png", []byte("<html><script>alert(1)</script></html>")); code != http.StatusUnsupportedMediaType {
		t.Fatalf("html as a receipt: %d", code)
	}
	code, ref := upload("bill.pdf", []byte("%PDF-1.4 a bill"))
	if code != http.StatusCreated || ref["content_type"] != "application/pdf" {
		t.Fatalf("upload %d %v", code, ref)
	}
	sha := ref["sha256"].(string)
	code, entry := financeRequest(t, server, http.MethodPost, "/v1/finance/entries",
		`{"direction":"expense","category":"hosting","amount":"40","occurred_on":"2026-06-01","idempotency_key":"a","actor":"Hatem","attachments":[{"sha256":"`+sha+`","name":"bill.pdf"}]}`)
	if code != http.StatusCreated || len(entry["attachments"].([]any)) != 1 {
		t.Fatalf("entry %d %v", code, entry)
	}
	if code, _ := financeRequest(t, server, http.MethodPost, "/v1/finance/entries",
		`{"direction":"expense","category":"hosting","amount":"40","occurred_on":"2026-06-01","idempotency_key":"b","actor":"Hatem","attachments":[{"sha256":"`+strings.Repeat("c", 64)+`"}]}`); code != http.StatusBadRequest {
		t.Fatalf("a receipt nobody uploaded: %d", code)
	}
	req := httptest.NewRequest(http.MethodGet, "http://relay/v1/finance/attachments/"+sha, nil)
	req.Header.Set("Authorization", "Bearer admin-token")
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "application/pdf" || rec.Body.String() != "%PDF-1.4 a bill" {
		t.Fatalf("read %d %s", rec.Code, rec.Header().Get("Content-Type"))
	}
}
