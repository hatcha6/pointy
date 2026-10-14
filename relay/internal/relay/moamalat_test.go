package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/alerts"
	"pointy/relay/internal/control"
	"pointy/relay/internal/moamalat"
)

// fakeMoamalat is the portal API: it answers each token as told.
type fakeMoamalat struct {
	mu     sync.Mutex
	answer map[string]func(w http.ResponseWriter)
	pokes  map[string]int
}

func (f *fakeMoamalat) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	f.mu.Lock()
	f.pokes[token]++
	answer := f.answer[token]
	f.mu.Unlock()
	if answer == nil {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"listOfMerchant":[]}`))
		return
	}
	answer(w)
}

func (f *fakeMoamalat) set(token string, answer func(w http.ResponseWriter)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.answer[token] = answer
}

func (f *fakeMoamalat) count(token string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.pokes[token]
}

func moamalatDead(w http.ResponseWriter) {
	w.WriteHeader(http.StatusUnauthorized)
	_, _ = w.Write([]byte(`{"oprationstate": "6"}`))
}

func moamalatCloudflare(w http.ResponseWriter) {
	w.WriteHeader(http.StatusForbidden)
	_, _ = w.Write([]byte(`<!DOCTYPE html><title>Just a moment...</title>`))
}

type moamalatHarness struct {
	t      *testing.T
	store  *control.FileStore
	clock  *settingsClock
	server HTTPServer
	keeper *MoamalatKeeper
	portal *fakeMoamalat
	shop   control.ProvisionedInstallation
	ntfy   *ntfySink
}

// ntfySink counts the alerts that reach the company's channel.
type ntfySink struct {
	mu     sync.Mutex
	titles []string
}

func (n *ntfySink) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	var message map[string]any
	_ = json.Unmarshal(body, &message)
	title, _ := message["title"].(string)
	n.mu.Lock()
	n.titles = append(n.titles, title)
	n.mu.Unlock()
}

func (n *ntfySink) waitFor(t *testing.T, prefix string, want int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		n.mu.Lock()
		got := 0
		for _, title := range n.titles {
			if strings.HasPrefix(title, prefix) {
				got++
			}
		}
		n.mu.Unlock()
		if got == want {
			// Settle: a second alert would arrive by now.
			time.Sleep(50 * time.Millisecond)
			n.mu.Lock()
			again := 0
			for _, title := range n.titles {
				if strings.HasPrefix(title, prefix) {
					again++
				}
			}
			n.mu.Unlock()
			if again != want {
				t.Fatalf("alerts %q: %d, want %d", prefix, again, want)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("alerts %q: %d, want %d", prefix, got, want)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func newMoamalatHarness(t *testing.T) *moamalatHarness {
	t.Helper()
	clock := &settingsClock{now: time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC)}
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.SetAlertSettings(context.Background(), control.AlertSettings{Topic: "daftar-alerts-moamalat-test"}); err != nil {
		t.Fatal(err)
	}
	key := make([]byte, moamalat.KeyBytes)
	for i := range key {
		key[i] = byte(7 * i)
	}
	sealer, err := moamalat.NewSealer(key)
	if err != nil {
		t.Fatal(err)
	}
	portal := &fakeMoamalat{answer: map[string]func(http.ResponseWriter){}, pokes: map[string]int{}}
	portalServer := httptest.NewServer(portal)
	t.Cleanup(portalServer.Close)
	sink := &ntfySink{}
	ntfyServer := httptest.NewServer(sink)
	t.Cleanup(ntfyServer.Close)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	notifier := &alerts.Ntfy{Server: ntfyServer.URL, Topics: AlertTopicSource(store), Logger: logger}
	shop, err := store.ProvisionInstallation(context.Background(), control.ProvisionInstallationRequest{ShopName: "Card Shop"})
	if err != nil {
		t.Fatal(err)
	}
	return &moamalatHarness{
		t: t, store: store, clock: clock, portal: portal, shop: shop, ntfy: sink,
		server: HTTPServer{
			Store: store, Hub: NewHub(), Logger: logger, Clock: clock,
			AdminToken: "admin-token", Alerts: notifier, MoamalatSealer: sealer,
		},
		keeper: &MoamalatKeeper{
			Store: store, Sealer: sealer, Alerts: notifier, Logger: logger,
			Client: &moamalat.Client{BaseURL: portalServer.URL},
			Jitter: func() float64 { return 0 },
		},
	}
}

func (h *moamalatHarness) call(method, target, token string, body any) (int, map[string]any) {
	h.t.Helper()
	var raw []byte
	if body != nil {
		raw, _ = json.Marshal(body)
	}
	request := httptest.NewRequest(method, "http://relay.test"+target, bytes.NewReader(raw))
	if token == "admin" {
		request.Header.Set("Authorization", "Bearer admin-token")
	} else if token != "" {
		request.Header.Set(AccessTokenHeader, token)
	}
	recorder := httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	var decoded map[string]any
	if recorder.Body.Len() > 0 {
		if err := json.Unmarshal(recorder.Body.Bytes(), &decoded); err != nil {
			h.t.Fatalf("not JSON (%d): %s", recorder.Code, recorder.Body.String())
		}
	}
	if strings.Contains(recorder.Body.String(), "sealed") || strings.Contains(recorder.Body.String(), "v1:") {
		h.t.Fatalf("a response leaked the sealed token: %s", recorder.Body.String())
	}
	return recorder.Code, decoded
}

func (h *moamalatHarness) link(token, tokenID string) {
	h.t.Helper()
	status, body := h.call(http.MethodPut, "/v1/moamalat/link", h.shop.AccessToken, map[string]string{
		"mid": "000000000145771", "token": token, "token_id": tokenID,
	})
	if status != http.StatusOK || body["state"] != "alive" || body["token_id"] != tokenID {
		h.t.Fatalf("link %d %v", status, body)
	}
}

func (h *moamalatHarness) held() control.MoamalatLink {
	h.t.Helper()
	link, err := h.store.GetMoamalatLink(context.Background(), h.shop.Installation.ID)
	if err != nil {
		h.t.Fatal(err)
	}
	return link
}

func TestMoamalatLinkIsHeldSealedAndPokedOnTheTick(t *testing.T) {
	h := newMoamalatHarness(t)
	if status, body := h.call(http.MethodGet, "/v1/moamalat/link", h.shop.AccessToken, nil); status != 200 || body["linked"] != false {
		t.Fatalf("nothing linked yet: %d %v", status, body)
	}
	if status, _ := h.call(http.MethodPut, "/v1/moamalat/link", "", map[string]string{"mid": "1", "token": "a.b.c", "token_id": "t1"}); status != http.StatusUnauthorized {
		t.Fatalf("no installation token: %d", status)
	}
	if status, _ := h.call(http.MethodPut, "/v1/moamalat/link", h.shop.AccessToken, map[string]string{"mid": "1", "token": "not-a-jwt", "token_id": "t1"}); status != http.StatusBadRequest {
		t.Fatalf("a non-JWT is refused: %d", status)
	}
	h.link("h.p.s1", "t1")
	if held := h.held(); held.SealedToken == "" || strings.Contains(held.SealedToken, "h.p.s1") {
		t.Fatalf("held in the clear: %+v", held)
	}

	// Due at once: poked, then not again until the tick.
	if claimed := h.keeper.RunOnce(context.Background()); claimed != 1 || h.portal.count("h.p.s1") != 1 {
		t.Fatalf("first pass claimed %d, pokes %d", claimed, h.portal.count("h.p.s1"))
	}
	if held := h.held(); held.LastOKAt.IsZero() || !held.NextPokeAt.Equal(h.clock.Now().Add(moamalat.Tick)) {
		t.Fatalf("after an accepted poke: %+v", held)
	}
	h.keeper.RunOnce(context.Background())
	if h.portal.count("h.p.s1") != 1 {
		t.Fatal("poked again before the tick")
	}
	h.clock.advance(moamalat.Tick)
	h.keeper.RunOnce(context.Background())
	if h.portal.count("h.p.s1") != 2 {
		t.Fatal("not poked on the tick")
	}
}

func TestMoamalatTransientFailuresRetryThenAlertAtRiskOnce(t *testing.T) {
	h := newMoamalatHarness(t)
	h.link("h.p.s1", "t1")
	h.portal.set("h.p.s1", moamalatCloudflare)

	h.keeper.RunOnce(context.Background())
	held := h.held()
	if held.State != control.MoamalatAlive || held.Failures != 1 || !held.NextPokeAt.Equal(h.clock.Now().Add(20*time.Second)) {
		t.Fatalf("a Cloudflare page is a transient fault, retried on the ladder: %+v", held)
	}
	// Past the at-risk mark: every 30 s, one alert however many failures.
	h.clock.advance(9 * time.Minute)
	for i := 0; i < 3; i++ {
		h.keeper.RunOnce(context.Background())
		if held := h.held(); !held.NextPokeAt.Equal(h.clock.Now().Add(moamalat.AtRiskRetry)) {
			t.Fatalf("at-risk cadence: %+v", held)
		}
		h.clock.advance(moamalat.AtRiskRetry)
	}
	h.ntfy.waitFor(t, "Moamalat token at risk", 1)
	if status, body := h.call(http.MethodGet, "/v1/moamalat/link", h.shop.AccessToken, nil); status != 200 || body["at_risk"] != true {
		t.Fatalf("the shop's read says at risk: %v", body)
	}

	// Through again: the alert ends with a recovery note.
	h.portal.set("h.p.s1", nil)
	h.keeper.RunOnce(context.Background())
	h.ntfy.waitFor(t, "Moamalat token warm again", 1)
	if held := h.held(); held.Failures != 0 || held.State != control.MoamalatAlive {
		t.Fatalf("recovered: %+v", held)
	}
}

func TestMoamalatDeathStopsPokingAndAlertsOnce(t *testing.T) {
	h := newMoamalatHarness(t)
	h.link("h.p.s1", "t1")
	h.portal.set("h.p.s1", moamalatDead)
	h.keeper.RunOnce(context.Background())
	held := h.held()
	if held.State != control.MoamalatNeedsReauth || held.SealedToken != "" || held.DeathSource != "relay" {
		t.Fatalf("death: %+v", held)
	}
	h.clock.advance(time.Hour)
	h.keeper.RunOnce(context.Background())
	if h.portal.count("h.p.s1") != 1 {
		t.Fatal("a dead token is never retried")
	}
	h.ntfy.waitFor(t, "Moamalat needs re-linking", 1)
	if _, body := h.call(http.MethodGet, "/v1/moamalat/link", h.shop.AccessToken, nil); body["state"] != "needs_reauth" || body["token_id"] != "t1" {
		t.Fatalf("the shop learns of it on its read: %v", body)
	}

	// Re-link: a new token, alive and due at once.
	h.link("h.p.s2", "t2")
	h.keeper.RunOnce(context.Background())
	if h.portal.count("h.p.s2") != 1 || h.held().State != control.MoamalatAlive {
		t.Fatalf("re-linked token not kept warm: %+v", h.held())
	}
}

func TestMoamalatAStaleDeathDoesNotFlipAReLinkedShop(t *testing.T) {
	h := newMoamalatHarness(t)
	h.link("h.p.s1", "t1")
	claims, err := h.store.ClaimMoamalatPokes(context.Background(), 10, time.Minute)
	if err != nil || len(claims) != 1 {
		t.Fatalf("claim %v %v", claims, err)
	}
	// While that poke is out, the shop re-links.
	h.link("h.p.s2", "t2")
	h.portal.set("h.p.s1", moamalatDead)
	h.keeper.poke(context.Background(), h.store, claims[0])
	if held := h.held(); held.State != control.MoamalatAlive || held.TokenID != "t2" || held.SealedToken == "" {
		t.Fatalf("the old token's 401 flipped the new link: %+v", held)
	}
	// Nor does the backend's report about the old token.
	if status, body := h.call(http.MethodPost, "/v1/moamalat/link/dead", h.shop.AccessToken, map[string]string{"token_id": "t1"}); status != 200 || body["applied"] != false {
		t.Fatalf("stale report applied: %d %v", status, body)
	}
	if status, body := h.call(http.MethodPost, "/v1/moamalat/link/dead", h.shop.AccessToken, map[string]string{"token_id": "t2"}); status != 200 || body["applied"] != true {
		t.Fatalf("current report not applied: %d %v", status, body)
	}
	if held := h.held(); held.State != control.MoamalatNeedsReauth || held.DeathSource != "backend" {
		t.Fatalf("backend's death: %+v", held)
	}
}

func TestMoamalatKillSwitchStopsTheRelayAndDeletesEveryCopy(t *testing.T) {
	h := newMoamalatHarness(t)
	h.link("h.p.s1", "t1")
	if _, err := h.store.SetIntegrationSwitch(context.Background(), control.IntegrationSwitch{Provider: "moamalat", Disabled: true, Reason: "letter"}); err != nil {
		t.Fatal(err)
	}
	if claimed := h.keeper.RunOnce(context.Background()); claimed != 0 || h.portal.count("h.p.s1") != 0 {
		t.Fatal("poked against the kill switch")
	}
	if _, err := h.store.GetMoamalatLink(context.Background(), h.shop.Installation.ID); err != control.ErrNotFound {
		t.Fatalf("copy kept against the kill switch: %v", err)
	}
	if status, body := h.call(http.MethodPut, "/v1/moamalat/link", h.shop.AccessToken, map[string]string{"mid": "1", "token": "a.b.c", "token_id": "t9"}); status != http.StatusConflict || body["error"] != "switched_off" {
		t.Fatalf("a token accepted against the kill switch: %d %v", status, body)
	}
	if status, body := h.call(http.MethodGet, "/v1/moamalat/admin/links", "admin", nil); status != 200 || body["switched_off"] != true {
		t.Fatalf("admin view: %d %v", status, body)
	}
}

func TestMoamalatShopUnlinkDeletesTheCopy(t *testing.T) {
	h := newMoamalatHarness(t)
	h.link("h.p.s1", "t1")
	if status, body := h.call(http.MethodDelete, "/v1/moamalat/link", h.shop.AccessToken, nil); status != 200 || body["deleted"] != true {
		t.Fatalf("delete %d %v", status, body)
	}
	h.keeper.RunOnce(context.Background())
	if h.portal.count("h.p.s1") != 0 {
		t.Fatal("poked after the shop unlinked")
	}
	if status, body := h.call(http.MethodGet, "/v1/moamalat/admin/links", "", nil); status != http.StatusUnauthorized {
		t.Fatalf("the fleet view is admin-only: %d %v", status, body)
	}
}

func TestMoamalatAnUnreadableCopyIsDroppedForTheShopToResend(t *testing.T) {
	h := newMoamalatHarness(t)
	h.link("h.p.s1", "t1")
	other, _ := moamalat.NewSealer(make([]byte, moamalat.KeyBytes))
	h.keeper.Sealer = other
	h.keeper.RunOnce(context.Background())
	if _, err := h.store.GetMoamalatLink(context.Background(), h.shop.Installation.ID); err != control.ErrNotFound {
		t.Fatalf("an unreadable copy is dropped: %v", err)
	}
}
