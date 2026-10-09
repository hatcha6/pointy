package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// The pricing settings of the services the company sells besides cards —
// direct top-up and bill payments, bought from Reloadly in dollars. Which
// dollar rate, which markups and which retail step turn Reloadly's price into
// the shop's and the customer's are the operator's to publish, like a catalog:
// every version is kept, the newest is current.
//
//	GET /v1/vouchers/admin/settings          the current settings (the demo defaults, "stored": false, before the first)
//	PUT /v1/vouchers/admin/settings          publish: the settings' own fields, plus an optional "note" and "actor"
//	GET /v1/vouchers/admin/settings/history  the versions, newest first, without their documents

const (
	// voucherSettingsTTL is how long a node trusts its idea of the current
	// settings before asking the store again. A publish through this node's own
	// admin route is seen at once; another node sees it within this time.
	voucherSettingsTTL      = 5 * time.Second
	maxVoucherSettingsBytes = 16 << 10
)

// Error codes of the settings admin route.
const (
	voucherCodeInvalidSettings    = "invalid_settings"
	voucherCodeSettingsUnreadable = "settings_unreadable"
)

// VoucherSettingsCache keeps the parsed current settings between requests:
// the document is parsed once per version, and which version is current is
// asked of the store at most every few seconds. Settings are small, so the
// whole record is read to find out. Shared by every copy of the server; a nil
// cache reads the store on every call, which is correct, only slower.
type VoucherSettingsCache struct {
	mu      sync.Mutex
	checked time.Time
	loaded  loadedVoucherSettings
	ready   bool
	// reported is the stored version that was last reported unreadable, so the
	// log says it once per change and not on every request.
	reported string
	// rates are the stored exchange rates, read at ratesAt (see withLiveRate).
	rates   []control.ExchangeRate
	ratesAt time.Time
	ratesOK bool
}

// voucherSettingsUnreadableError is the stored settings document that does not
// parse: a value the code does not accept, or a field it does not know (a
// rolling update that adds a settings field meets this on the nodes still
// running the old code). Card sales go on without a dollar rate; the settings
// admin route says loudly what is wrong.
type voucherSettingsUnreadableError struct {
	ID  string
	Err error
}

func (e *voucherSettingsUnreadableError) Error() string {
	return fmt.Sprintf("stored voucher settings %s do not parse: %v", e.ID, e.Err)
}

func (e *voucherSettingsUnreadableError) Unwrap() error { return e.Err }

// firstReport says whether this unreadable version has not been reported yet,
// and remembers it has. A nil cache reports every time.
func (c *VoucherSettingsCache) firstReport(id string) bool {
	if c == nil {
		return true
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.reported == id {
		return false
	}
	c.reported = id
	return true
}

// loadedVoucherSettings is the current pricing settings and where they came
// from.
type loadedVoucherSettings struct {
	settings vouchers.Settings
	// record names the published version, without its document; zero when no
	// version was ever published and the settings are the demo defaults.
	record control.VoucherSettingsRecord
	stored bool
}

// snapshot is a copy that shares no slice with the cache.
func (l loadedVoucherSettings) snapshot() loadedVoucherSettings {
	l.settings = l.settings.Clone()
	return l
}

// invalidate makes the next read ask the store.
func (c *VoucherSettingsCache) invalidate() {
	if c == nil {
		return
	}
	c.mu.Lock()
	c.checked = time.Time{}
	c.mu.Unlock()
}

// currentVoucherSettings reads the published pricing settings. stored is false
// before the first version is published: the settings are then the demo
// defaults — with no dollar rate, so nothing from Reloadly can be priced. The
// result is the caller's to keep; it shares nothing with the cache.
func (s HTTPServer) currentVoucherSettings(ctx context.Context, store control.VoucherStore) (vouchers.Settings, bool, error) {
	loaded, err := s.loadVoucherSettings(ctx, store)
	if err != nil {
		return vouchers.Settings{}, false, err
	}
	return loaded.settings, loaded.stored, nil
}

func (s HTTPServer) loadVoucherSettings(ctx context.Context, store control.VoucherStore) (loadedVoucherSettings, error) {
	loaded, err := s.loadStoredVoucherSettings(ctx, store)
	if err != nil {
		return loaded, err
	}
	loaded.settings = s.withLiveRate(ctx, loaded.settings)
	return loaded, nil
}

func (s HTTPServer) loadStoredVoucherSettings(ctx context.Context, store control.VoucherStore) (loadedVoucherSettings, error) {
	cache := s.VoucherSettingsCache
	now := s.clock().Now()
	if cache != nil {
		cache.mu.Lock()
		if cache.ready && now.Sub(cache.checked) < voucherSettingsTTL {
			loaded := cache.loaded.snapshot()
			cache.mu.Unlock()
			return loaded, nil
		}
		cache.mu.Unlock()
	}
	record, err := store.CurrentVoucherSettings(ctx)
	if errors.Is(err, control.ErrVoucherSettingsNotFound) {
		loaded := loadedVoucherSettings{settings: vouchers.DefaultSettings()}
		cache.remember(loaded, now)
		return loaded.snapshot(), nil
	}
	if err != nil {
		return loadedVoucherSettings{}, err
	}
	if cache != nil {
		// The same document as the one already parsed: only the version's
		// own details can differ (a rollback publishes an old document again).
		cache.mu.Lock()
		if cache.ready && cache.loaded.stored && cache.loaded.record.SHA256 == record.SHA256 {
			record.Document = nil
			cache.loaded.record = record
			cache.checked = now
			loaded := cache.loaded.snapshot()
			cache.mu.Unlock()
			return loaded, nil
		}
		cache.mu.Unlock()
	}
	settings, err := vouchers.ParseSettings(record.Document)
	if err != nil {
		return loadedVoucherSettings{}, &voucherSettingsUnreadableError{ID: record.ID, Err: err}
	}
	record.Document = nil
	loaded := loadedVoucherSettings{settings: settings, record: record, stored: true}
	cache.remember(loaded, now)
	return loaded.snapshot(), nil
}

func (c *VoucherSettingsCache) remember(loaded loadedVoucherSettings, now time.Time) {
	if c == nil {
		return
	}
	c.mu.Lock()
	c.loaded = loaded.snapshot()
	c.checked = now
	c.ready = true
	c.mu.Unlock()
}

// voucherSettingsView is how the admin route (and so the CLI) shows settings:
// the settings themselves, the version they came from, whether Reloadly can be
// priced with them, and which knobs are still the demonstration values nobody
// decided.
func voucherSettingsView(settings vouchers.Settings, record *control.VoucherSettingsRecord) map[string]any {
	return map[string]any{
		"stored":        record != nil,
		"settings":      settings,
		"record":        record,
		"priced":        settings.Priced(),
		"demo_defaults": settings.DemoDefaults(),
	}
}

// handleVoucherAdminSettings serves GET /v1/vouchers/admin/settings. It reads
// the store, not the cache: the operator sees what is published now.
func (s HTTPServer) handleVoucherAdminSettings(w http.ResponseWriter, r *http.Request, store control.VoucherStore) {
	record, err := store.CurrentVoucherSettings(r.Context())
	if errors.Is(err, control.ErrVoucherSettingsNotFound) {
		writeJSON(w, http.StatusOK, voucherSettingsView(vouchers.DefaultSettings(), nil))
		return
	}
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher settings read failed", err)
		return
	}
	settings, err := vouchers.ParseSettings(record.Document)
	if err != nil {
		// Said loudly, with the document, so the operator can see what is wrong
		// and publish a corrected one. Card sales are not stopped by this.
		s.logger().Error("the stored voucher settings cannot be read", "settings_id", record.ID, "error", err)
		writeSMSError(w, http.StatusInternalServerError, voucherCodeSettingsUnreadable,
			fmt.Sprintf("THE STORED VOUCHER SETTINGS (version %s) CANNOT BE READ: %v. Card sales go on without a dollar rate "+
				"(Reloadly is unpriced); publish a corrected document: pointy-relay vouchers settings set --file settings.json",
				record.ID, err),
			map[string]any{"settings_id": record.ID, "document": json.RawMessage(record.Document)})
		return
	}
	record.Document = nil
	writeJSON(w, http.StatusOK, voucherSettingsView(settings, &record))
}

// handleVoucherAdminSettingsPublish serves PUT /v1/vouchers/admin/settings: the
// body is a settings document with an optional "note" and "actor" beside its
// fields. It is validated, normalized (the defaults written out) and made
// current; settings identical to the current ones are not published again.
func (s HTTPServer) handleVoucherAdminSettingsPublish(w http.ResponseWriter, r *http.Request, store control.VoucherStore) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxVoucherSettingsBytes))
	if err != nil {
		writeSMSError(w, http.StatusRequestEntityTooLarge, voucherCodeInvalidRequest, "settings are at most 16 KB", nil)
		return
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(body, &fields); err != nil || fields == nil {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "the body must be a JSON object", nil)
		return
	}
	var note, actor string
	for name, target := range map[string]*string{"note": &note, "actor": &actor} {
		raw, present := fields[name]
		if !present {
			continue
		}
		delete(fields, name)
		if err := json.Unmarshal(raw, target); err != nil {
			writeSMSError(w, http.StatusUnprocessableEntity, voucherCodeInvalidSettings, name+" must be a string", nil)
			return
		}
	}
	remaining, err := json.Marshal(fields)
	if err != nil {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "invalid request body", nil)
		return
	}
	settings, err := vouchers.ParseSettings(remaining)
	if err != nil {
		extra := map[string]any(nil)
		var problems vouchers.SettingsProblems
		if errors.As(err, &problems) {
			extra = map[string]any{"problems": problems}
		}
		writeSMSError(w, http.StatusUnprocessableEntity, voucherCodeInvalidSettings, err.Error(), extra)
		return
	}
	raw, sum, err := vouchers.EncodeSettings(settings)
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher settings encoding failed", err)
		return
	}
	ctx := r.Context()
	current, err := store.CurrentVoucherSettings(ctx)
	if err != nil && !errors.Is(err, control.ErrVoucherSettingsNotFound) {
		s.writeVoucherInternalError(w, "", "voucher settings read failed", err)
		return
	}
	if err == nil && voucherSettingsUnchanged(current, sum, settings) {
		current.Document = nil
		view := voucherSettingsView(settings, &current)
		view["unchanged"] = true
		writeJSON(w, http.StatusOK, view)
		return
	}
	published, err := store.PublishVoucherSettings(ctx, control.VoucherSettingsRecord{
		SHA256:   sum,
		Document: raw,
		Actor:    actor,
		Note:     note,
	})
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher settings publish failed", err)
		return
	}
	s.VoucherSettingsCache.invalidate()
	s.logger().Info("voucher settings published",
		"settings_id", published.ID, "sha256", published.SHA256, "actor", published.Actor,
		"priced", settings.Priced(), "demo_defaults", len(settings.DemoDefaults()))
	published.Document = nil
	view := voucherSettingsView(settings, &published)
	view["unchanged"] = false
	writeJSON(w, http.StatusCreated, view)
}

// voucherSettingsUnchanged reports whether publishing settings would change
// nothing: the current version is the very same document, or one that prices
// everything alike ("0.50" and "0.5" are the same step).
func voucherSettingsUnchanged(current control.VoucherSettingsRecord, sum string, settings vouchers.Settings) bool {
	if current.SHA256 == sum {
		return true
	}
	published, err := vouchers.ParseSettings(current.Document)
	return err == nil && published.Equal(settings)
}

// handleVoucherAdminSettingsHistory serves GET /v1/vouchers/admin/settings/history.
func (s HTTPServer) handleVoucherAdminSettingsHistory(w http.ResponseWriter, r *http.Request, store control.VoucherStore) {
	limit, _ := strconv.Atoi(strings.TrimSpace(r.URL.Query().Get("limit")))
	history, err := store.ListVoucherSettings(r.Context(), limit)
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher settings history failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"history": history})
}
