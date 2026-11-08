package airalo

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The live test talks to Airalo with the company's credentials. It is skipped
// unless they are set:
//
//	AIRALO_LIVE_CLIENT_ID=… AIRALO_LIVE_CLIENT_SECRET=… go test ./internal/airalo -run Live -v
//
// It only runs on an account in Sandbox mode, which it proves first: Airalo's
// documented test package answers "maintenance" in Sandbox and is unknown in
// Production, and neither can be charged. Nothing it orders in Sandbox costs
// anything. AIRALO_LIVE_RAW=dir saves each answer there, the token's excepted.

type rawSaver struct {
	dir string
	n   int
}

func (r *rawSaver) RoundTrip(request *http.Request) (*http.Response, error) {
	response, err := http.DefaultTransport.RoundTrip(request)
	if err != nil || r.dir == "" || strings.HasSuffix(request.URL.Path, "/token") {
		return response, err
	}
	body, readErr := io.ReadAll(response.Body)
	response.Body.Close()
	if readErr != nil {
		return response, readErr
	}
	response.Body = io.NopCloser(bytes.NewReader(body))
	r.n++
	name := fmt.Sprintf("%02d_%s_%s_%d.json", r.n, request.Method,
		strings.ReplaceAll(strings.Trim(request.URL.Path, "/"), "/", "_"), response.StatusCode)
	_ = os.WriteFile(filepath.Join(r.dir, name), body, 0o600)
	return response, nil
}

func TestLiveSandbox(t *testing.T) {
	id, secret := os.Getenv("AIRALO_LIVE_CLIENT_ID"), os.Getenv("AIRALO_LIVE_CLIENT_SECRET")
	if id == "" || secret == "" {
		t.Skip("set AIRALO_LIVE_CLIENT_ID and AIRALO_LIVE_CLIENT_SECRET to run the live test")
	}
	client := New(Config{
		ClientID: id, ClientSecret: secret,
		HTTPClient: &http.Client{Timeout: 120 * time.Second, Transport: &rawSaver{dir: os.Getenv("AIRALO_LIVE_RAW")}},
		RetryDelay: time.Second,
	})
	ctx := context.Background()

	// Sandbox or not: before anything that could cost money.
	_, err := client.SubmitOrder(ctx, "test-maintenance-mode-7days-1gb", "sandbox-probe", "")
	if !IsCode(err, CodeMaintenance) {
		t.Fatalf("not proven to be Sandbox, stopping before any real order: %v", err)
	}
	t.Log("Sandbox mode proven")

	for pkg, code := range map[string]int{
		"test-insufficient-balance-7days-1gb": CodeInsufficientCredit,
		"test-not-enough-7days-1gb":           CodeNotEnoughStock,
		"test-out-of-stock-7days-1gb":         CodeOutOfStock,
	} {
		_, err := client.SubmitOrder(ctx, pkg, "sandbox-error", "")
		t.Logf("%s: %v", pkg, err)
		if !IsCode(err, code) || !DefinitelyNotOrdered(err) {
			t.Errorf("%s should be code %d and definitely not ordered: %v", pkg, code, err)
		}
		time.Sleep(1200 * time.Millisecond)
	}

	if balance, found, err := client.Balance(ctx); err != nil {
		t.Errorf("balance: %v", err)
	} else {
		t.Logf("balance: %+v found=%v", balance, found)
	}
	for _, kind := range []string{NotifyLowData, NotifyCreditLimit} {
		note, found, err := client.Notification(ctx, kind)
		t.Logf("opt-in %s: %+v found=%v err=%v", kind, note, found, err)
	}
	for _, model := range []string{"iPhone13,2", "SM-S921B", "Nokia 3310"} {
		check, err := client.CheckDevice(ctx, model)
		if err != nil {
			t.Errorf("device %s: %v", model, err)
			continue
		}
		t.Logf("device %s: supported=%v reason=%q device=%+v", model, check.Supported, check.Reason, check.Device)
	}

	started := time.Now()
	pricing, destinations, err := client.Packages(ctx, "ar")
	if err != nil {
		t.Fatalf("packages: %v", err)
	}
	t.Logf("pricing: %+v", pricing)
	var plans, kyc, noCode int
	var first *Package
	var firstOperator Operator
	var firstPlace Destination
	for _, d := range destinations {
		if d.CountryCode == "" {
			noCode++
		}
		for _, o := range d.Operators {
			if o.KYC {
				kyc++
			}
			for i := range o.Packages {
				plans++
				if first == nil && d.CountryCode == "TR" {
					first, firstOperator, firstPlace = &o.Packages[i], o, d
				}
			}
		}
	}
	t.Logf("catalog: %d destinations (%d without a country), %d plans, %d KYC operators, read in %s",
		len(destinations), noCode, plans, kyc, time.Since(started).Round(time.Millisecond))
	if len(destinations) == 0 || first == nil {
		t.Fatal("no Turkish plan to order")
	}
	t.Logf("sample: %q %q image=%v operator=%q rechargeable=%v policy=%q window=%q grace=%q plan=%+v",
		firstPlace.Slug, firstPlace.Title, firstPlace.Image.URL != "", firstOperator.Title, firstOperator.Rechargeable,
		firstOperator.ActivationPolicy, firstOperator.InstallWindow, firstOperator.TopUpGrace, *first)

	reference := fmt.Sprintf("sandbox-%d", time.Now().Unix())
	order, err := client.SubmitOrder(ctx, first.ID, reference, "")
	if err != nil {
		t.Fatalf("order: %v", err)
	}
	if len(order.SIMs) != 1 {
		t.Fatalf("order holds %d eSIMs", len(order.SIMs))
	}
	sim := order.SIMs[0]
	t.Logf("order %s: price=%s net=%s paid=%s currency=%s apple=%v android=%v qr=%v apn=%v",
		order.ID, order.Price, order.NetPrice, order.PaidPrice, order.Currency,
		sim.AppleURL != "", sim.AndroidURL != "", strings.HasPrefix(sim.QRCode, "LPA:"), sim.APN != nil)

	found, err := client.FindOrders(ctx, reference)
	if err != nil || len(found) != 1 || found[0].Description != reference {
		t.Errorf("finding the order by its reference: %d found, %v", len(found), err)
	}
	read, err := client.Order(ctx, order.ID.String())
	if err != nil || len(read.SIMs) != 1 || read.SIMs[0].ICCID != sim.ICCID {
		t.Errorf("reading the order back: %+v, %v", read.Status, err)
	}
	full, err := client.SIM(ctx, sim.ICCID)
	if err != nil {
		t.Fatalf("sim: %v", err)
	}
	if full.Sharing == nil || full.Sharing.Link == "" || full.AppleURL == "" || full.AndroidURL == "" {
		t.Errorf("the eSIM lacks what installs it: sharing=%+v", full.Sharing)
	}
	usage, err := client.Usage(ctx, sim.ICCID)
	if err != nil {
		t.Errorf("usage: %v", err)
	}
	t.Logf("usage: %+v", usage)
	_, topUps, err := client.TopUps(ctx, sim.ICCID, "ar")
	if err != nil {
		t.Errorf("top-ups: %v", err)
	}
	t.Logf("top-ups: %d", len(topUps))
	if len(topUps) > 0 {
		time.Sleep(1200 * time.Millisecond)
		t.Logf("first top-up listed: %+v", struct {
			ID, Title, Price string
		}{topUps[0].ID, topUps[0].Title, topUps[0].Price.String()})
		topped, err := client.SubmitTopUp(ctx, topUps[0].ID, sim.ICCID, reference+"-topup")
		if err != nil {
			t.Errorf("top-up: %v", err)
		} else {
			t.Logf("top-up %s: type=%s price=%s net=%s paid=%s", topped.ID, topped.Type, topped.Price, topped.NetPrice, topped.PaidPrice)
		}
	}
	if _, err := client.Usage(ctx, "0000000000"); err == nil {
		t.Error("usage of an invalid ICCID should fail")
	} else {
		t.Logf("invalid ICCID: %v", err)
	}

	// With a public URL: opts in, then out again, and asks the simulator for one
	// delivery of each alert. Nothing fires in Sandbox otherwise.
	if hook := os.Getenv("AIRALO_LIVE_WEBHOOK"); hook != "" {
		for _, kind := range []string{NotifyLowData, NotifyCreditLimit} {
			if err := client.OptIn(ctx, kind, hook); err != nil {
				t.Errorf("opt-in %s: %v", kind, err)
				continue
			}
			note, found, err := client.Notification(ctx, kind)
			t.Logf("opted in %s: %+v found=%v err=%v", kind, note, found, err)
			if err := client.OptOut(ctx, kind); err != nil {
				t.Errorf("opt-out %s: %v", kind, err)
			}
		}
		for _, body := range []map[string]any{
			{"event": "low_data_notification", "type": "data_90", "iccid": sim.ICCID, "webhook_url": hook},
			{"event": "low_data_notification", "type": "expire_3", "iccid": sim.ICCID, "webhook_url": hook},
			{"event": "credit_limit_notification", "level": 80, "webhook_url": hook},
		} {
			err := client.call(ctx, "simulator", http.MethodPost, "/v2/simulator/webhook", nil, "", jsonBody(body), nil)
			t.Logf("simulated %v: %v", body["type"], err)
		}
	}
}
