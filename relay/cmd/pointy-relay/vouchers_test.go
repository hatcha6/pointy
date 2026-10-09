package main

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/png"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/control"
	relayserver "pointy/relay/internal/relay"
	"pointy/relay/internal/vouchers"
)

func TestBuildVoucherConfig(t *testing.T) {
	config, credentials, warnings, err := buildVoucherConfig(voucherSettings{RateLimit: "30/minute"})
	if err != nil || len(warnings) != 0 || credentials.Configured() || config.TestMode {
		t.Fatalf("nothing set: %+v %+v %v %v", config, credentials, warnings, err)
	}
	attachVoucherSuppliers(&config, credentials, http.DefaultClient)
	if config.Configured() || config.BNPlus != nil {
		t.Fatal("no credentials, no test mode: nothing to sell")
	}

	config, credentials, warnings, err = buildVoucherConfig(voucherSettings{
		RateLimit: "30/minute", BNPlusEmail: "ops@example.ly", BNPlusPassword: "p", BNPlusToken: "t",
	})
	if err != nil || len(warnings) != 0 || !credentials.Configured() || credentials.BaseURL != "https://portal.bn-plusli.ly" ||
		credentials.Timeout != 45*time.Second {
		t.Fatalf("full set: %+v %v %v", credentials, warnings, err)
	}
	attachVoucherSuppliers(&config, credentials, http.DefaultClient)
	if !config.Configured() || config.BNPlus == nil || config.Suppliers[vouchers.SupplierBNPlus] == nil {
		t.Fatalf("BN Plus is on: %+v", config)
	}

	_, credentials, warnings, err = buildVoucherConfig(voucherSettings{RateLimit: "30/minute", BNPlusToken: "t"})
	if err != nil || len(warnings) != 1 || credentials.Configured() || credentials.Partial() {
		t.Fatalf("half a set warns and stays off: %+v %v %v", credentials, warnings, err)
	}

	if _, _, warnings, err = buildVoucherConfig(voucherSettings{RateLimit: "30/minute", TestMode: true}); err != nil ||
		len(warnings) != 1 || !strings.Contains(warnings[0], "TEST MODE") {
		t.Fatalf("test mode warns: %v %v", warnings, err)
	}
	for _, bad := range []voucherSettings{
		{RateLimit: "lots"},
		{RateLimit: "30/minute", SyncInterval: -time.Minute},
		{RateLimit: "30/minute", BNPlusBaseURL: "ftp://portal"},
	} {
		if _, _, _, err := buildVoucherConfig(bad); err == nil {
			t.Fatalf("%+v must stop the relay", bad)
		}
	}
}

func TestTheExampleCatalogIsValid(t *testing.T) {
	document, err := vouchers.ParseDocument([]byte(voucherCatalogExample))
	if err != nil {
		t.Fatal(err)
	}
	if problems := vouchers.Validate(document, vouchers.ValidateOptions{PathsAllowed: true}); len(problems) > 0 {
		t.Fatalf("the example must validate: %v", problems)
	}
}

func writePNG(t *testing.T, path string, shade uint8) {
	t.Helper()
	picture := image.NewRGBA(image.Rect(0, 0, 8, 5))
	for x := 0; x < 8; x++ {
		for y := 0; y < 5; y++ {
			picture.Set(x, y, color.RGBA{R: shade, G: 1, B: 2, A: 255})
		}
	}
	var buffer bytes.Buffer
	if err := png.Encode(&buffer, picture); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, buffer.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}

// The operator's whole loop: write the example next to its images, check it,
// push it (images uploaded, references swapped in), and read it back.
func TestCatalogPushUploadsTheImagesAndPublishes(t *testing.T) {
	dir := t.TempDir()
	catalogPath := filepath.Join(dir, "catalog.json")
	if err := os.WriteFile(catalogPath, []byte(voucherCatalogExample), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := runVoucherCatalogCheck([]string{catalogPath}); err == nil {
		t.Fatal("check must fail while the images are missing")
	}
	for i, name := range []string{
		"flags/us.png", "flags/gb.png", "logos/itunes.png", "logos/itunes-print.png",
		"logos/psn.png", "logos/psn-print.png", "logos/libyana.png", "logos/libyana-print.png",
	} {
		writePNG(t, filepath.Join(dir, name), uint8(10+i))
	}
	if err := runVoucherCatalogCheck([]string{catalogPath}); err != nil {
		t.Fatalf("check: %v", err)
	}

	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), nil)
	if err != nil {
		t.Fatal(err)
	}
	relay := httptest.NewServer(relayserver.HTTPServer{
		Store:      store,
		Hub:        relayserver.NewHub(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken: "admin-token",
		Vouchers:   relayserver.VoucherConfig{TestMode: true},
	})
	t.Cleanup(relay.Close)
	t.Setenv("POINTY_RELAY_CONTROL_URL", relay.URL)
	t.Setenv("POINTY_RELAY_ADMIN_TOKEN", "admin-token")
	t.Setenv("POINTY_RELAY_ALLOW_INSECURE_CONTROL", "true")

	if err := runVoucherCatalogPush([]string{catalogPath, "--note", "first", "--actor", "ops"}); err != nil {
		t.Fatalf("push: %v", err)
	}
	current, err := store.CurrentVoucherCatalog(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if current.Actor != "ops" || current.Note != "first" {
		t.Fatalf("published: %+v", current)
	}
	document, err := vouchers.ParseDocument(current.Document)
	if err != nil {
		t.Fatal(err)
	}
	refs := vouchers.Images(document)
	if len(refs) != 8 {
		t.Fatalf("eight images referenced, got %v", refs)
	}
	for _, ref := range refs {
		if !strings.HasPrefix(ref, vouchers.ImagePrefix) {
			t.Fatalf("%s was not swapped for its upload", ref)
		}
	}
	if err := runVoucherCatalogPush([]string{catalogPath}); err != nil {
		t.Fatalf("pushing the same catalog again: %v", err)
	}
	history, _ := store.ListVoucherCatalogs(context.Background(), 10)
	if len(history) != 1 {
		t.Fatalf("an unchanged push adds no version, got %d", len(history))
	}
	if err := runVoucherCatalogShow(nil); err != nil {
		t.Fatalf("show: %v", err)
	}
}
