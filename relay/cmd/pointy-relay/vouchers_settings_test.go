package main

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"pointy/relay/internal/control"
	relayserver "pointy/relay/internal/relay"
	"pointy/relay/internal/vouchers"
)

func TestMergeVoucherSettingsOverridesOnlyWhatWasGiven(t *testing.T) {
	base := vouchers.Settings{USDRate: "9.71", Margin: vouchers.Margin{RoundStep: "0.5"}, Popular: []string{"NE", "ML"}}.Normalized()
	merged := mergeVoucherSettings(base, map[string]string{
		"margin-fixed": " 3 ",
		"bills-margin": "1:::50:8,:4",
		"popular":      "eg, ng;tn  PK",
	})
	want := base.Clone()
	want.Margin.FixedLYD = "3"
	want.Bills.Margin = &vouchers.Margin{FixedLYD: "1", Brackets: []vouchers.Bracket{{UpToLYD: "50", Percent: "8"}, {Percent: "4"}}}
	want.Popular = []string{"eg", "ng", "tn", "PK"}
	if !reflect.DeepEqual(merged, want) {
		t.Fatalf("\n got %+v\nwant %+v", merged, want)
	}
	if base.Margin.FixedLYD != "0.50" || !reflect.DeepEqual(base.Popular, []string{"NE", "ML"}) {
		t.Fatalf("the base must not change: %+v", base)
	}

	// Every knob has a flag that sets the field it names.
	every := map[string]string{}
	for _, knob := range voucherSettingsKnobs {
		every[knob.flag] = "7"
	}
	every["popular"] = "NE"
	all := mergeVoucherSettings(vouchers.Settings{}, every)
	if all.USDRate != "7" || all.FundingPercent != "7" || all.Airtime.ShopMarkupPercent != "7" || all.Airtime.RetailMarkupPercent != "7" ||
		all.Airtime.OrderMode != "7" || all.Airtime.USDBufferPercent != "7" || all.Bills.OrderMode != "7" ||
		all.Margin.RoundStep != "7" || all.Margin.MinShopMargin != "7" || all.Margin.FixedLYD != "7" || all.Margin.ShopSharePercent != "7" ||
		all.USDRateSource != "7" || all.USDRateSeries != "7" || all.USDRateBankCode != "7" || all.USDRateBufferPercent != "7" ||
		all.USDRateMaxAge != "7" || all.Airtime.Margin == nil || all.CardMargin == nil || !reflect.DeepEqual(all.Popular, []string{"NE"}) {
		t.Fatalf("a flag does not reach its field: %+v", all)
	}
	if len(voucherSettingsKnobs) != 34 {
		t.Fatalf("one flag per knob: %v", voucherSettingsKnobNames())
	}

	// Blank means "the default" — except for the rate, where it means "unset".
	blank := mergeVoucherSettings(base, map[string]string{"usd-rate": "", "retail-step": "", "popular": ""}).Normalized()
	if blank.USDRate != "" || blank.Margin.RoundStep != "0.25" || !reflect.DeepEqual(blank.Popular, vouchers.DefaultPopularCountries()) {
		t.Fatalf("blank values: %+v", blank)
	}
}

func TestSplitCountryCodes(t *testing.T) {
	cases := map[string][]string{
		"":              nil,
		"  ":            nil,
		"NE":            {"NE"},
		"NE,ML,NG":      {"NE", "ML", "NG"},
		" ne , ml ;ng ": {"ne", "ml", "ng"},
		"NE,,ML":        {"NE", "ML"},
	}
	for in, want := range cases {
		if got := splitCountryCodes(in); !reflect.DeepEqual(got, want) {
			t.Errorf("splitCountryCodes(%q) = %#v, want %#v", in, got, want)
		}
	}
}

func renderedSettings(answer voucherSettingsAnswer) string {
	var out bytes.Buffer
	renderVoucherSettings(&out, answer)
	return out.String()
}

func TestRenderVoucherSettingsSaysPlainlyWhatNobodyDecided(t *testing.T) {
	// Before anything is published: demo defaults, no rate.
	out := renderedSettings(voucherSettingsAnswer{Settings: vouchers.DefaultSettings()})
	for _, want := range []string{
		"NEVER PUBLISHED", "(unset)", "NOT SET", "Reloadly is NOT PRICED", "rate_unset",
		"settings set --usd-rate", "8 knob(s) are still demonstration values, not decisions by the owner",
		"funding_percent, margin, airtime.order_mode, airtime.usd_buffer_percent, airtime.service_fee_lyd, bills.order_mode, bills.usd_buffer_percent, popular",
		"Margin ladder", "cost 20.00 -> margin 2.10 + service fee 2.00, shop pays 23.37, retail 24.25",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("the defaults' output should contain %q:\n%s", want, out)
		}
	}
	if got := strings.Count(out, "DEMO DEFAULT"); got != 8 {
		t.Errorf("every one of the 8 other knobs is flagged, got %d:\n%s", got, out)
	}
	if strings.Contains(out, "the customer is asked") {
		t.Errorf("an unpriced relay shows no prices:\n%s", out)
	}

	// A published version with a decided rate and two decided markups.
	settings := vouchers.Settings{
		USDRate: "9.71",
		Margin:  vouchers.Margin{FixedLYD: "1", Brackets: []vouchers.Bracket{{Percent: "10"}}, ShopSharePercent: "0", MinMarginLYD: "0"},
	}.Normalized()
	answer := voucherSettingsAnswer{Stored: true, Settings: settings, Priced: true}
	answer.Record = &struct {
		ID        string `json:"id"`
		SHA256    string `json:"sha256"`
		Actor     string `json:"actor"`
		Note      string `json:"note"`
		CreatedAt string `json:"created_at"`
	}{ID: "ver-1", Actor: "ops", Note: "October", CreatedAt: "2026-10-08T12:00:00Z"}
	out = renderedSettings(answer)
	for _, want := range []string{
		"published", "by ops", `("October")`, "(version ver-1)",
		"Reloadly is priced: one dollar costs the company 9.71 dinars.",
		// 10 USD = 97.10 LYD. Margin 1 + 10 % of it = 10.71, all the shop's to pay: 107.81, retail up to the quarter.
		"a direct top-up that costs Reloadly 10 USD (97.10 LYD): the shop pays 109.81, the customer is asked 110.00",
		"a bill payment that costs Reloadly 10 USD (97.10 LYD): the shop pays 107.81, the customer is asked 108.00",
		"7 knob(s) are still demonstration values",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("the published output should contain %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "NEVER PUBLISHED") || strings.Contains(out, "NOT PRICED") {
		t.Errorf("a published, priced version is neither:\n%s", out)
	}
	if got := strings.Count(out, "DEMO DEFAULT"); got != 7 {
		t.Errorf("two of the 8 other knobs were decided, got %d flagged:\n%s", got, out)
	}

	// Every knob decided and a funding fee: nothing is flagged.
	decided := vouchers.Settings{
		USDRate: "10", FundingPercent: "2.5",
		Airtime: vouchers.ServicePricing{OrderMode: "local", USDBufferPercent: "1", ServiceFeeLYD: "0"},
		Bills:   vouchers.ServicePricing{OrderMode: "local", USDBufferPercent: "1"},
		Margin:  vouchers.Margin{RoundStep: "0.5", MinShopMargin: "0.2", FixedLYD: "1"},
		Popular: []string{"EG"},
	}
	out = renderedSettings(voucherSettingsAnswer{Stored: true, Settings: decided, Priced: true})
	if strings.Contains(out, "DEMO DEFAULT") || strings.Contains(out, "demonstration values") {
		t.Errorf("everything is decided:\n%s", out)
	}
	if !strings.Contains(out, "one dollar costs the company 10 dinars (10.25 with the funding fee).") {
		t.Errorf("the funding fee should be shown:\n%s", out)
	}

	// A dry run names itself.
	out = renderedSettings(voucherSettingsAnswer{Settings: decided, Heading: "DRY RUN: nothing is published."})
	if !strings.HasPrefix(out, "DRY RUN: nothing is published.") || strings.Contains(out, "NEVER PUBLISHED") {
		t.Errorf("heading:\n%s", out)
	}
}

// settingsRelay is a real relay server on a file store, and the environment the
// CLI reads to reach it.
func settingsRelay(t *testing.T) *control.FileStore {
	t.Helper()
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), nil)
	if err != nil {
		t.Fatal(err)
	}
	relay := httptest.NewServer(relayserver.HTTPServer{
		Store:                store,
		Hub:                  relayserver.NewHub(),
		Logger:               slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken:           "admin-token",
		Vouchers:             relayserver.VoucherConfig{TestMode: true},
		VoucherSettingsCache: &relayserver.VoucherSettingsCache{},
	})
	t.Cleanup(relay.Close)
	t.Setenv("POINTY_RELAY_CONTROL_URL", relay.URL)
	t.Setenv("POINTY_RELAY_ADMIN_TOKEN", "admin-token")
	t.Setenv("POINTY_RELAY_ALLOW_INSECURE_CONTROL", "true")
	return store
}

func currentSettings(t *testing.T, store *control.FileStore) (vouchers.Settings, control.VoucherSettingsRecord) {
	t.Helper()
	record, err := store.CurrentVoucherSettings(context.Background())
	if err != nil {
		t.Fatalf("no settings published: %v", err)
	}
	settings, err := vouchers.ParseSettings(record.Document)
	if err != nil {
		t.Fatal(err)
	}
	return settings, record
}

func versions(t *testing.T, store *control.FileStore) int {
	t.Helper()
	history, err := store.ListVoucherSettings(context.Background(), 100)
	if err != nil {
		t.Fatal(err)
	}
	return len(history)
}

// The operator's whole loop on settings: look, set the rate, change one markup
// (the rate stays), change nothing, get a number wrong, preview, roll the rate
// back.
func TestVoucherSettingsCommandsLoop(t *testing.T) {
	store := settingsRelay(t)

	out, err := captureStdout(t, func() error { return runVoucherSettingsShow(nil) })
	if err != nil || !strings.Contains(out, "NEVER PUBLISHED") || !strings.Contains(out, "Reloadly is NOT PRICED") {
		t.Fatalf("show before anything is published: %v\n%s", err, out)
	}
	if out, err = captureStdout(t, func() error { return runVoucherSettingsHistory(nil) }); err != nil ||
		!strings.Contains(out, "No settings have been published") {
		t.Fatalf("history before anything is published: %v\n%s", err, out)
	}

	// Nothing to set is not "publish the defaults".
	if _, err := captureStdout(t, func() error { return runVoucherSettingsSet([]string{"--note", "nothing"}) }); err == nil ||
		!strings.Contains(err.Error(), "nothing to set") {
		t.Fatalf("a set with no knobs must refuse: %v", err)
	}
	if versions(t, store) != 0 {
		t.Fatal("a refused set published something")
	}

	// The first rate. Everything else is written out as the demo default.
	out, err = captureStdout(t, func() error {
		return runVoucherSettingsSet([]string{"--usd-rate", "9.71", "--note", "first rate", "--actor", "ops"})
	})
	if err != nil {
		t.Fatalf("set: %v\n%s", err, out)
	}
	for _, want := range []string{"Published.", "Reloadly is priced: one dollar costs the company 9.71 dinars.", "DEMO DEFAULT", `("first rate")`, "by ops"} {
		if !strings.Contains(out, want) {
			t.Errorf("set output should contain %q:\n%s", want, out)
		}
	}
	settings, record := currentSettings(t, store)
	if settings.USDRate != "9.71" || settings.Margin.RoundStep != "0.25" || settings.Margin.FixedLYD != "0.50" ||
		len(settings.Popular) != 20 || record.Actor != "ops" || record.Note != "first rate" {
		t.Fatalf("published: %+v %+v", settings, record)
	}

	// Another knob: the rate is kept (the flags override the PUBLISHED settings).
	if out, err = captureStdout(t, func() error {
		return runVoucherSettingsSet([]string{"--retail-step", "0.5", "--bills-shop-markup", "4", "--popular", "ml, ne", "--note", "coarser steps"})
	}); err != nil {
		t.Fatalf("set: %v\n%s", err, out)
	}
	settings, _ = currentSettings(t, store)
	if settings.USDRate != "9.71" || settings.Margin.RoundStep != "0.5" || settings.Bills.Margin == nil ||
		!reflect.DeepEqual(settings.Popular, []string{"ML", "NE"}) {
		t.Fatalf("a flag must keep the rest as published: %+v", settings)
	}
	if versions(t, store) != 2 {
		t.Fatalf("two versions, got %d", versions(t, store))
	}

	// The same again: not a third version, and it says so.
	if out, err = captureStdout(t, func() error { return runVoucherSettingsSet([]string{"--retail-step", "0.50"}) }); err != nil ||
		!strings.Contains(out, "Unchanged") {
		t.Fatalf("an unchanged set: %v\n%s", err, out)
	}
	if versions(t, store) != 2 {
		t.Fatalf("an unchanged set published a version: %d", versions(t, store))
	}

	// A wrong number is refused locally, naming the knob, and nothing is published.
	var stderr bytes.Buffer
	realStderr := os.Stderr
	reader, writer, _ := os.Pipe()
	os.Stderr = writer
	_, err = captureStdout(t, func() error {
		return runVoucherSettingsSet([]string{"--usd-rate", "nine", "--retail-step", "0", "--popular", "NE,QQ"})
	})
	_ = writer.Close()
	os.Stderr = realStderr
	_, _ = io.Copy(&stderr, reader)
	if err == nil || !strings.Contains(err.Error(), "3 problem(s)") {
		t.Fatalf("want 3 problems, got %v", err)
	}
	for _, path := range []string{"usd_rate", "margin.round_step", "popular[1]"} {
		if !strings.Contains(stderr.String(), path) {
			t.Errorf("the problems should name %s:\n%s", path, stderr.String())
		}
	}
	if versions(t, store) != 2 {
		t.Fatalf("a refused set published a version: %d", versions(t, store))
	}

	// A preview publishes nothing but shows the result.
	out, err = captureStdout(t, func() error {
		return runVoucherSettingsSet([]string{"--dry-run", "--usd-rate", "11.20"})
	})
	if err != nil || !strings.Contains(out, "DRY RUN") || !strings.Contains(out, "11.20") {
		t.Fatalf("dry run: %v\n%s", err, out)
	}
	if settings, _ = currentSettings(t, store); settings.USDRate != "9.71" || versions(t, store) != 2 {
		t.Fatalf("a dry run must publish nothing: %+v", settings)
	}

	// A file is the starting point instead of the published settings.
	file := filepath.Join(t.TempDir(), "settings.json")
	if err := os.WriteFile(file, []byte(`{"usd_rate":"10.05","airtime":{"shop_markup_percent":"1.5"},"popular":["eg"]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if out, err = captureStdout(t, func() error {
		return runVoucherSettingsSet([]string{"--file", file, "--min-shop-margin", "0.30", "--note", "from a file"})
	}); err != nil {
		t.Fatalf("set --file: %v\n%s", err, out)
	}
	settings, _ = currentSettings(t, store)
	if settings.USDRate != "10.05" || settings.Airtime.Margin == nil || settings.Margin.MinShopMargin != "0.30" ||
		settings.Margin.RoundStep != "0.25" || settings.Bills.Margin != nil || !reflect.DeepEqual(settings.Popular, []string{"EG"}) {
		t.Fatalf("the file replaces the published settings as the base: %+v", settings)
	}

	// A bad file is refused with its problems, before the relay is asked.
	bad := filepath.Join(t.TempDir(), "bad.json")
	if err := os.WriteFile(bad, []byte(`{"retial_step":"0.5"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err = captureStdout(t, func() error { return runVoucherSettingsSet([]string{"--file", bad}) }); err == nil ||
		!strings.Contains(err.Error(), "retial_step") {
		t.Fatalf("a misspelt field in a file: %v", err)
	}
	if _, err = captureStdout(t, func() error {
		return runVoucherSettingsSet([]string{"--file", filepath.Join(t.TempDir(), "nothing.json")})
	}); err == nil {
		t.Fatal("a missing file must fail")
	}

	// An empty rate takes Reloadly off the shelves; it is a version like any.
	if out, err = captureStdout(t, func() error { return runVoucherSettingsSet([]string{"--usd-rate", "", "--note", "pause"}) }); err != nil ||
		!strings.Contains(out, "Reloadly is NOT PRICED") {
		t.Fatalf("unset the rate: %v\n%s", err, out)
	}
	if settings, _ = currentSettings(t, store); settings.Priced() || settings.Airtime.Margin == nil {
		t.Fatalf("only the rate is unset: %+v", settings)
	}

	// show and history read it all back.
	if out, err = captureStdout(t, func() error { return runVoucherSettingsShow(nil) }); err != nil ||
		!strings.Contains(out, "version") || !strings.Contains(out, `("pause")`) {
		t.Fatalf("show: %v\n%s", err, out)
	}
	out, err = captureStdout(t, func() error { return runVoucherSettingsHistory([]string{"--limit", "10"}) })
	if err != nil || !strings.Contains(out, "PUBLISHED") || !strings.Contains(out, "first rate") ||
		!strings.Contains(out, "coarser steps") || !strings.Contains(out, "from a file") || !strings.Contains(out, "pause") {
		t.Fatalf("history: %v\n%s", err, out)
	}
	if out, err = captureStdout(t, func() error { return runVoucherSettingsShow([]string{"--json"}) }); err != nil ||
		!strings.Contains(out, `"stored": true`) || !strings.Contains(out, `"demo_defaults"`) {
		t.Fatalf("show --json: %v\n%s", err, out)
	}
}

func TestVoucherSettingsCommandsRouting(t *testing.T) {
	settingsRelay(t)
	for _, args := range [][]string{nil, {"unknown"}} {
		if err := runVoucherSettings(args); err == nil {
			t.Fatalf("runVoucherSettings(%v) must fail", args)
		}
	}
	// vouchers routes to it.
	out, err := captureStdout(t, func() error { return runVouchers([]string{"settings", "show"}) })
	if err != nil || !strings.Contains(out, "NEVER PUBLISHED") {
		t.Fatalf("vouchers settings show: %v\n%s", err, out)
	}
	// The usage tells about it.
	usage := renderUsage([]usageSection{*findUsageSection("vouchers")})
	for _, want := range []string{"settings show", "settings set", "--usd-rate", "settings history", "[--kind K]"} {
		if !strings.Contains(usage, want) {
			t.Errorf("the vouchers usage should mention %q:\n%s", want, usage)
		}
	}
}
