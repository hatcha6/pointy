package relay

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"pointy/relay/internal/control"
)

func holidayTestServer(t *testing.T) (HTTPServer, control.ProvisionedInstallation) {
	t.Helper()
	store, provisioned := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:          store,
		Hub:            NewHub(),
		Logger:         slog.New(slog.NewTextHandler(io.Discard, nil)),
		AllowOpenAdmin: true,
	}
	return server, provisioned
}

func TestHTTPListHolidaysRequiresToken(t *testing.T) {
	server, _ := holidayTestServer(t)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "http://relay.test/v1/holidays", nil))
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 without a relay token, got %d", recorder.Code)
	}
}

func TestHTTPHolidayAdminLifecycleAndShopRead(t *testing.T) {
	server, provisioned := holidayTestServer(t)

	// Admin adds a global Eid range.
	body := `{"key":"eid_fitr_2026","name_en":"Eid al-Fitr","name_ar":"عيد الفطر",` +
		`"category":"religious","rule_type":"range","start_date":"2026-03-20","end_date":"2026-03-22"}`
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "http://relay.test/v1/holidays", strings.NewReader(body)))
	if recorder.Code != http.StatusCreated {
		t.Fatalf("expected 201 on create, got %d: %s", recorder.Code, recorder.Body.String())
	}
	var created control.Holiday
	if err := json.Unmarshal(recorder.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	if created.ID == "" {
		t.Fatal("expected a server-assigned id")
	}

	// A shop pulls its calendar with the installation access token.
	request := httptest.NewRequest(http.MethodGet, "http://relay.test/v1/holidays", nil)
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder = httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200 on shop read, got %d: %s", recorder.Code, recorder.Body.String())
	}
	var payload struct {
		Holidays []control.Holiday `json:"holidays"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Holidays) != 1 || payload.Holidays[0].Key != "eid_fitr_2026" {
		t.Fatalf("expected the seeded Eid, got %+v", payload.Holidays)
	}

	// Admin lists all via the trailing-slash route.
	recorder = httptest.NewRecorder()
	server.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "http://relay.test/v1/holidays/", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200 on admin list, got %d", recorder.Code)
	}

	// Admin patches then deletes it; a second delete is a 404.
	update := `{"key":"eid_fitr_2026","name_en":"Eid","name_ar":"عيد","category":"religious",` +
		`"rule_type":"range","start_date":"2026-03-20","end_date":"2026-03-23"}`
	recorder = httptest.NewRecorder()
	server.ServeHTTP(recorder, httptest.NewRequest(http.MethodPatch, "http://relay.test/v1/holidays/"+created.ID, strings.NewReader(update)))
	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200 on patch, got %d: %s", recorder.Code, recorder.Body.String())
	}
	recorder = httptest.NewRecorder()
	server.ServeHTTP(recorder, httptest.NewRequest(http.MethodDelete, "http://relay.test/v1/holidays/"+created.ID, nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200 on delete, got %d", recorder.Code)
	}
	recorder = httptest.NewRecorder()
	server.ServeHTTP(recorder, httptest.NewRequest(http.MethodDelete, "http://relay.test/v1/holidays/"+created.ID, nil))
	if recorder.Code != http.StatusNotFound {
		t.Fatalf("expected 404 on re-delete, got %d", recorder.Code)
	}
}

func TestHTTPHolidayCreateValidation(t *testing.T) {
	server, _ := holidayTestServer(t)
	for _, body := range []string{
		`{"key":"","rule_type":"fixed"}`,
		`{"key":"x","rule_type":"bogus"}`,
		`{"key":"x","rule_type":"range"}`,
		`{"key":"x","rule_type":"range","start_date":"2026-03-22","end_date":"2026-03-20"}`,
	} {
		recorder := httptest.NewRecorder()
		server.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "http://relay.test/v1/holidays", strings.NewReader(body)))
		if recorder.Code != http.StatusBadRequest {
			t.Fatalf("expected 400 for %s, got %d", body, recorder.Code)
		}
	}
}
