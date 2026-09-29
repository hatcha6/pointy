package relay

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"pointy/relay/internal/control"
)

// The kill switch, end to end on the relay: the operator switches a provider
// off with the admin token, and every shop reads it off its own status read —
// the same call its backend already makes to sync its entitlements.

func newIntegrationSwitchServer(t *testing.T) (HTTPServer, control.ProvisionedInstallation) {
	t.Helper()
	store, provisioned := provisionRelayInstallation(t)
	return HTTPServer{
		Store:      store,
		Hub:        NewHub(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken: "admin-token",
	}, provisioned
}

func putSwitch(t *testing.T, server HTTPServer, provider, body string, admin bool) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPut, "http://relay/v1/fleet/integrations/"+provider, strings.NewReader(body))
	if admin {
		req.Header.Set("Authorization", "Bearer admin-token")
	}
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	return rec
}

// statusRead is the shop's own sync: GET /v1/installations/{id} with its
// access token, no admin credential anywhere.
func statusRead(t *testing.T, server HTTPServer, provisioned control.ProvisionedInstallation) map[string]any {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "http://relay/v1/installations/"+provisioned.Installation.ID, nil)
	req.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status read %d: %s", rec.Code, rec.Body.String())
	}
	var payload map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	return payload
}

func disabledIn(t *testing.T, payload map[string]any) []string {
	t.Helper()
	raw, ok := payload["integrations_disabled"]
	if !ok {
		t.Fatalf("status read carries no integrations_disabled: %v", payload)
	}
	list := []string{}
	for _, item := range raw.([]any) {
		list = append(list, item.(string))
	}
	return list
}

func TestShopsReadAProviderSwitchedOffOnTheirOwnStatusRead(t *testing.T) {
	server, provisioned := newIntegrationSwitchServer(t)

	if got := disabledIn(t, statusRead(t, server, provisioned)); len(got) != 0 {
		t.Fatalf("nothing switched off yet, got %v", got)
	}

	rec := putSwitch(t, server, "Qareeb", `{"disabled":true,"reason":"cease-and-desist 2026-09-28","actor":"hatem"}`, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("switch off %d: %s", rec.Code, rec.Body.String())
	}
	var stored control.IntegrationSwitch
	if err := json.Unmarshal(rec.Body.Bytes(), &stored); err != nil {
		t.Fatal(err)
	}
	if stored.Provider != "qareeb" || !stored.Disabled || stored.Actor != "hatem" {
		t.Fatalf("stored = %+v", stored)
	}

	if got := disabledIn(t, statusRead(t, server, provisioned)); !reflect.DeepEqual(got, []string{"qareeb"}) {
		t.Fatalf("the shop reads %v, want [qareeb]", got)
	}

	if rec := putSwitch(t, server, "qareeb", `{"disabled":false,"reason":"approved"}`, true); rec.Code != http.StatusOK {
		t.Fatalf("switch on %d: %s", rec.Code, rec.Body.String())
	}
	if got := disabledIn(t, statusRead(t, server, provisioned)); len(got) != 0 {
		t.Fatalf("back on, the shop still reads %v", got)
	}
}

func TestOnlyTheOperatorThrowsTheSwitch(t *testing.T) {
	server, provisioned := newIntegrationSwitchServer(t)

	if rec := putSwitch(t, server, "qareeb", `{"disabled":true}`, false); rec.Code != http.StatusUnauthorized {
		t.Fatalf("no admin token: want 401, got %d", rec.Code)
	}
	// A shop's own token is no admin credential.
	req := httptest.NewRequest(http.MethodPut, "http://relay/v1/fleet/integrations/qareeb", strings.NewReader(`{"disabled":true}`))
	req.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("shop token: want 401, got %d", rec.Code)
	}
	if got := disabledIn(t, statusRead(t, server, provisioned)); len(got) != 0 {
		t.Fatalf("a refused switch changed nothing, got %v", got)
	}
}

func TestSwitchRequestsAreValidated(t *testing.T) {
	server, _ := newIntegrationSwitchServer(t)
	for _, tc := range []struct {
		provider, body string
	}{
		{"has%20space", `{"disabled":true}`},
		{"9lives", `{"disabled":true}`},
		{"qareeb", `{"reason":"no state given"}`},
		{"qareeb", `not json`},
	} {
		if rec := putSwitch(t, server, tc.provider, tc.body, true); rec.Code != http.StatusBadRequest {
			t.Fatalf("%s %s: want 400, got %d: %s", tc.provider, tc.body, rec.Code, rec.Body.String())
		}
	}
}

func TestOperatorListsEverySwitch(t *testing.T) {
	server, _ := newIntegrationSwitchServer(t)
	putSwitch(t, server, "qareeb", `{"disabled":true,"reason":"letter"}`, true)
	putSwitch(t, server, "hdbox", `{"disabled":false}`, true)

	req := httptest.NewRequest(http.MethodGet, "http://relay/v1/fleet/integrations", nil)
	req.Header.Set("Authorization", "Bearer admin-token")
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("list %d: %s", rec.Code, rec.Body.String())
	}
	var response struct {
		Integrations []control.IntegrationSwitch `json:"integrations"`
		Disabled     []string                    `json:"disabled"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Integrations) != 2 || !reflect.DeepEqual(response.Disabled, []string{"qareeb"}) {
		t.Fatalf("list = %+v", response)
	}
}

// A store that cannot read its switches must not tell every shop that every
// provider is back on: the field is left out, and a backend keeps what it
// last heard.
func TestAnUnreadableSwitchTableLeavesTheFieldOut(t *testing.T) {
	store, provisioned := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:      failingSwitchStore{FileStore: store},
		Hub:        NewHub(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken: "admin-token",
	}
	payload := statusRead(t, server, provisioned)
	if _, ok := payload["integrations_disabled"]; ok {
		t.Fatalf("an unreadable table must leave the field out, got %v", payload["integrations_disabled"])
	}
}

type failingSwitchStore struct {
	*control.FileStore
}

func (failingSwitchStore) ListIntegrationSwitches(context.Context) ([]control.IntegrationSwitch, error) {
	return nil, io.ErrUnexpectedEOF
}
