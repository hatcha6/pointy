package resala

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const sendResponse = `{"failed":0,"failed_numbers":[],"is_prod":true,
 "sms_template_version":{"id":"ver-1","version_number":2,
   "body":"شكرًا لتسوقك من $1. فاتورتك رقم $2 بقيمة $3.","status":"APPROVED",
   "variables":[{"id":"a","key":"$1","max_runes":0},{"id":"b","key":"$2","max_runes":0},{"id":"c","key":"$3","max_runes":0}]},
 "succeeded":1,"total_cost":0.1,"total_free_messages":0,"total_messages":1,"total_sent_free_messages":0}`

func TestSendTemplatePostsOneMultipartRecordsField(t *testing.T) {
	var hits int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		if r.Method != http.MethodPost || r.URL.Path != "/api/v1/messages/send-template" {
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		if got := r.URL.Query().Get("sms_template_id"); got != "tpl-uuid" {
			t.Errorf("expected sms_template_id tpl-uuid, got %q", got)
		}
		if !strings.HasSuffix(r.URL.RawQuery, "&test") {
			t.Errorf("expected a bare test flag, got query %q", r.URL.RawQuery)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer secret-token" {
			t.Errorf("unexpected authorization %q", got)
		}
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			t.Fatalf("expected multipart form data: %v", err)
		}
		if len(r.MultipartForm.Value) != 1 || len(r.MultipartForm.File) != 0 {
			t.Errorf("expected exactly one form field, got %#v", r.MultipartForm.Value)
		}
		raw := r.FormValue("records")
		if !strings.HasPrefix(raw, `[{"phone":"218912345678","$1":"محل النور","$2":"000123","$3":"125.00 د.ل"}`) {
			t.Errorf("records field not in Resala's shape: %s", raw)
		}
		var records []map[string]string
		if err := json.Unmarshal([]byte(raw), &records); err != nil {
			t.Fatalf("records is not a JSON array: %v", err)
		}
		if len(records) != 1 || records[0]["phone"] != "218912345678" || records[0]["$3"] != "125.00 د.ل" {
			t.Errorf("unexpected records %#v", records)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, sendResponse)
	}))
	defer server.Close()

	client := New(Config{BaseURL: server.URL + "/api/v1/", Token: "secret-token"})
	result, err := client.SendTemplate(context.Background(), "tpl-uuid", []Record{{
		Phone:  "218912345678",
		Values: []string{"محل النور", "000123", "125.00 د.ل"},
	}}, true)
	if err != nil {
		t.Fatal(err)
	}
	if hits != 1 {
		t.Fatalf("expected one call, got %d", hits)
	}
	if result.Succeeded != 1 || result.Failed != 0 || !result.IsProd || result.TotalMessages != 1 {
		t.Fatalf("unexpected counts %+v", result)
	}
	if result.TotalCost != 0.1 || result.TotalCostText != "0.1" {
		t.Fatalf("expected cost 0.1 kept as text, got %v / %q", result.TotalCost, result.TotalCostText)
	}
	if result.Template.Body != "شكرًا لتسوقك من $1. فاتورتك رقم $2 بقيمة $3." ||
		result.Template.VersionNumber != 2 ||
		strings.Join(result.Template.Variables, ",") != "$1,$2,$3" {
		t.Fatalf("unexpected template %+v", result.Template)
	}
}

func TestSendTemplateOmitsTestFlagForRealSends(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Has("test") {
			t.Errorf("a real send must not carry the test flag: %q", r.URL.RawQuery)
		}
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, sendResponse)
	}))
	defer server.Close()

	client := New(Config{BaseURL: server.URL, Token: "t"})
	if _, err := client.SendTemplate(context.Background(), "tpl", []Record{{Phone: "218912345678", Values: []string{"a"}}}, false); err != nil {
		t.Fatal(err)
	}
}

func TestSendTemplateNeverRetries(t *testing.T) {
	cases := map[string]http.HandlerFunc{
		"server error": func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusBadGateway)
		},
		"dropped connection": func(w http.ResponseWriter, _ *http.Request) {
			hijacker, _ := w.(http.Hijacker)
			conn, _, _ := hijacker.Hijack()
			_ = conn.Close()
		},
	}
	for name, handler := range cases {
		t.Run(name, func(t *testing.T) {
			var hits int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				atomic.AddInt32(&hits, 1)
				handler(w, r)
			}))
			defer server.Close()

			client := New(Config{BaseURL: server.URL, Token: "t", RetryBackoff: time.Millisecond})
			_, err := client.SendTemplate(context.Background(), "tpl", []Record{{Phone: "218912345678", Values: []string{"a"}}}, false)
			if err == nil {
				t.Fatal("expected an error")
			}
			if got := atomic.LoadInt32(&hits); got != 1 {
				t.Fatalf("a send must be attempted exactly once, got %d attempts", got)
			}
		})
	}
}

func TestSendTemplateTimeoutIsATransportError(t *testing.T) {
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	defer server.Close()
	defer close(release)

	client := New(Config{BaseURL: server.URL, Token: "t", Timeout: 20 * time.Millisecond})
	_, err := client.SendTemplate(context.Background(), "tpl", []Record{{Phone: "218912345678", Values: []string{"a"}}}, false)
	var transport *TransportError
	if !errors.As(err, &transport) || !transport.Timeout() {
		t.Fatalf("expected a timed-out transport error, got %v", err)
	}
}

func TestSendTemplateMapsProviderErrors(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		check  func(t *testing.T, err error)
	}{
		{
			name:   "unauthorized",
			status: http.StatusUnauthorized,
			body:   `{"status":401,"type":"Unauthorized","message":"invalid token"}`,
			check: func(t *testing.T, err error) {
				if !errors.Is(err, ErrUnauthorized) {
					t.Fatalf("expected ErrUnauthorized, got %v", err)
				}
			},
		},
		{
			name:   "forbidden",
			status: http.StatusForbidden,
			body:   `{"status":403,"type":"Forbidden","message":"not allowed"}`,
			check: func(t *testing.T, err error) {
				if !errors.Is(err, ErrForbidden) {
					t.Fatalf("expected ErrForbidden, got %v", err)
				}
			},
		},
		{
			name:   "empty wallet",
			status: http.StatusBadRequest,
			body:   `{"status":400,"type":"BadRequest","message":"wallet must have at least 0.15 LYD to send an sms","request_id":"req-42"}`,
			check: func(t *testing.T, err error) {
				if !errors.Is(err, ErrInsufficientCredit) {
					t.Fatalf("expected ErrInsufficientCredit, got %v", err)
				}
				var provider *ProviderError
				if !errors.As(err, &provider) || provider.RequestID != "req-42" || provider.Status != 400 {
					t.Fatalf("expected the provider details to survive, got %#v", err)
				}
			},
		},
		{
			name:   "other bad request",
			status: http.StatusBadRequest,
			body:   `{"status":400,"type":"BadRequest","message":"template is not approved"}`,
			check: func(t *testing.T, err error) {
				if errors.Is(err, ErrInsufficientCredit) {
					t.Fatal("a plain 400 is not a credit problem")
				}
				var provider *ProviderError
				if !errors.As(err, &provider) || provider.Message != "template is not approved" {
					t.Fatalf("expected the message to survive, got %v", err)
				}
			},
		},
		{
			name:   "validation",
			status: http.StatusUnprocessableEntity,
			body:   `{"status":422,"type":"InputValidation","message":"input validation error.","errors":{"phone":["LY phones must be made of 9 numbers"]}}`,
			check: func(t *testing.T, err error) {
				var validation *ValidationError
				if !errors.As(err, &validation) {
					t.Fatalf("expected a ValidationError, got %v", err)
				}
				if got := validation.Errors["phone"]; len(got) != 1 || got[0] != "LY phones must be made of 9 numbers" {
					t.Fatalf("unexpected field errors %#v", validation.Errors)
				}
				if !strings.Contains(validation.Detail(), "phone: LY phones must be made of 9 numbers") {
					t.Fatalf("detail should carry the field error, got %q", validation.Detail())
				}
			},
		},
		{
			name:   "server error",
			status: http.StatusInternalServerError,
			body:   `<html>upstream exploded</html>`,
			check: func(t *testing.T, err error) {
				var provider *ProviderError
				if !errors.As(err, &provider) || provider.Status != 500 || !strings.Contains(provider.Message, "upstream exploded") {
					t.Fatalf("expected a 500 ProviderError with the raw text, got %v", err)
				}
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = io.WriteString(w, tc.body)
			}))
			defer server.Close()
			client := New(Config{BaseURL: server.URL, Token: "t"})
			_, err := client.SendTemplate(context.Background(), "tpl", []Record{{Phone: "218912345678", Values: []string{"a"}}}, false)
			tc.check(t, err)
		})
	}
}

func TestSendTemplateUnreadableSuccessIsAnUnknownOutcome(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, "definitely not json")
	}))
	defer server.Close()
	client := New(Config{BaseURL: server.URL, Token: "t"})
	_, err := client.SendTemplate(context.Background(), "tpl", []Record{{Phone: "218912345678", Values: []string{"a"}}}, false)
	var transport *TransportError
	if !errors.As(err, &transport) {
		t.Fatalf("an accepted-but-unreadable send must be an unknown outcome, got %v", err)
	}
}

func TestListSentQueriesTheDeliveryLogAndRetriesServerErrors(t *testing.T) {
	var hits int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempt := atomic.AddInt32(&hits, 1)
		if r.Method != http.MethodGet || r.URL.Path != "/sent-view" {
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		query := r.URL.Query()
		if query.Get("filters") != "source:message" || query.Get("page") != "2" ||
			query.Get("paginate") != "100" || query.Get("sorts") != "-created_at" {
			t.Errorf("unexpected query %q", r.URL.RawQuery)
		}
		if r.Header.Get("Authorization") != "Bearer t" {
			t.Errorf("missing bearer token")
		}
		if attempt < 3 {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		_, _ = io.WriteString(w, `{"data":[
			{"id":"m-2","code":"218","region":"LY","number":"912345678","content":"hello","source":"message","env":"production","status":"Delivered","created_at":"2026-09-27T10:15:00.000000Z"},
			{"id":17,"code":218,"region":"LY","number":912345679,"content":"x","source":"message","env":"production","status":null,"created_at":"2026-09-27 10:14:00"}
		],"meta":{"current_page":2,"last_page":"5","total":430}}`)
	}))
	defer server.Close()

	client := New(Config{BaseURL: server.URL, Token: "t", RetryBackoff: time.Millisecond})
	page, err := client.ListSent(context.Background(), SentQuery{Page: 2, PerPage: 100})
	if err != nil {
		t.Fatal(err)
	}
	if got := atomic.LoadInt32(&hits); got != 3 {
		t.Fatalf("expected two retries then success, got %d attempts", got)
	}
	if page.CurrentPage != 2 || page.LastPage != 5 || page.Total != 430 || len(page.Messages) != 2 {
		t.Fatalf("unexpected page %+v", page)
	}
	first, second := page.Messages[0], page.Messages[1]
	if first.ID != "m-2" || first.Status != "Delivered" || first.Number != "912345678" ||
		!first.CreatedAt.Equal(time.Date(2026, 9, 27, 10, 15, 0, 0, time.UTC)) {
		t.Fatalf("unexpected first row %+v", first)
	}
	if second.ID != "17" || second.Code != "218" || second.Number != "912345679" || second.Status != "" ||
		!second.CreatedAt.Equal(time.Date(2026, 9, 27, 10, 14, 0, 0, time.UTC)) {
		t.Fatalf("unexpected second row %+v", second)
	}
}

func TestListSentGivesUpAfterTwoRetries(t *testing.T) {
	var hits int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer server.Close()
	client := New(Config{BaseURL: server.URL, Token: "t", RetryBackoff: time.Millisecond})
	_, err := client.ListSent(context.Background(), SentQuery{})
	var provider *ProviderError
	if !errors.As(err, &provider) || provider.Status != http.StatusServiceUnavailable {
		t.Fatalf("expected the last 503, got %v", err)
	}
	if got := atomic.LoadInt32(&hits); got != 3 {
		t.Fatalf("expected 1 attempt + 2 retries, got %d", got)
	}
}

func TestListSentDoesNotRetryAClientError(t *testing.T) {
	var hits int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer server.Close()
	client := New(Config{BaseURL: server.URL, Token: "t", RetryBackoff: time.Millisecond})
	if _, err := client.ListSent(context.Background(), SentQuery{}); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("expected ErrUnauthorized, got %v", err)
	}
	if got := atomic.LoadInt32(&hits); got != 1 {
		t.Fatalf("a 401 will not change on retry, got %d attempts", got)
	}
}

func TestRecordMarshalJSONKeepsVariableOrderAndLiteralText(t *testing.T) {
	values := make([]string, 10)
	for i := range values {
		values[i] = string(rune('a' + i))
	}
	values[0] = "https://x.test/?a=1&b=<2>"
	raw, err := encodeRecords([]Record{{Phone: "218912345678", Values: values}})
	if err != nil {
		t.Fatal(err)
	}
	want := `[{"phone":"218912345678","$1":"https://x.test/?a=1&b=<2>","$2":"b","$3":"c","$4":"d","$5":"e","$6":"f","$7":"g","$8":"h","$9":"i","$10":"j"}]`
	if string(raw) != want {
		t.Fatalf("got  %s\nwant %s", raw, want)
	}
}

func TestRenderBody(t *testing.T) {
	ten := []string{"v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10"}
	cases := []struct {
		name   string
		body   string
		values []string
		want   string
	}{
		{"positional", "Welcome to $1 we are glad to have you $2", []string{"Alpha", "Sara"}, "Welcome to Alpha we are glad to have you Sara"},
		{"arabic", "شكرًا لتسوقك من $1. فاتورتك رقم $2 بقيمة $3.", []string{"محل النور", "000123", "125.00 د.ل"}, "شكرًا لتسوقك من محل النور. فاتورتك رقم 000123 بقيمة 125.00 د.ل."},
		{"ten is not one-zero", "$10|$1|$2", ten, "v10|v1|v2"},
		{"one-zero with one value", "$10", []string{"x"}, "x0"},
		{"values are not re-substituted", "$1 $2", []string{"costs $2", "ok"}, "costs $2 ok"},
		{"unknown key stays", "$3 and $0 and $01 and $", []string{"a"}, "$3 and $0 and $01 and $"},
		{"key at the end", "id: $2", []string{"a", "b"}, "id: b"},
		{"no values", "static $1", nil, "static $1"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := RenderBody(tc.body, tc.values); got != tc.want {
				t.Fatalf("RenderBody(%q) = %q, want %q", tc.body, got, tc.want)
			}
		})
	}
}

func TestNormalizeLibyanMobile(t *testing.T) {
	valid := map[string]string{
		"+218912345678":    "218912345678",
		"+218 91 234 5678": "218912345678",
		"00218912345678":   "218912345678",
		"218912345678":     "218912345678",
		"0912345678":       "218912345678",
		"091-234-5678":     "218912345678",
		"(091) 234.5678":   "218912345678",
		"912345678":        "218912345678",
		"٠٩٢٣٤٥٦٧٨٩":       "218923456789",
		"‎+218945551234":   "218945551234",
	}
	for raw, want := range valid {
		got, ok := NormalizeLibyanMobile(raw)
		if !ok || got != want {
			t.Errorf("NormalizeLibyanMobile(%q) = %q, %v; want %q", raw, got, ok, want)
		}
	}
	invalid := []string{
		"",
		"+2180912345678", // trunk zero after the country code
		"+21891234567",   // too short
		"218812345678",   // not a mobile (starts with 8)
		"0212345678",     // Tripoli landline
		"+20912345678",   // Egypt
		"+0912345678",    // plus without a country code
		"0912345678x",
		"91234567",
		"2189123456789",
		"21+8912345678",
	}
	for _, raw := range invalid {
		if got, ok := NormalizeLibyanMobile(raw); ok {
			t.Errorf("NormalizeLibyanMobile(%q) = %q, want rejection", raw, got)
		}
	}
}
