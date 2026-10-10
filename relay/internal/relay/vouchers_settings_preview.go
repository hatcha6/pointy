package relay

import (
	"encoding/json"
	"math/big"
	"net/http"
	"strings"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// handleVoucherAdminSettingsPreview serves POST
// /v1/vouchers/admin/settings/preview: what a draft of the settings would make
// of a few costs, worked out by the same code that prices for the shops. It
// changes nothing, so the console can show the effect of every keystroke
// before the operator publishes.
//
//	{"settings": {...draft...}, "samples": [{"kind":"card","cost":"10","currency":"USD"}]}
func (s HTTPServer) handleVoucherAdminSettingsPreview(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Settings json.RawMessage `json:"settings"`
		Samples  []struct {
			Kind     string `json:"kind"`
			Cost     string `json:"cost"`
			Currency string `json:"currency"`
		} `json:"samples"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256<<10)).Decode(&request); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	settings, err := vouchers.ParseSettings(request.Settings)
	if err != nil {
		// A draft mid-edit: said, not refused.
		writeJSON(w, http.StatusOK, map[string]any{"valid": false, "problem": err.Error(), "samples": []any{}})
		return
	}
	settings = s.withLiveRate(r.Context(), settings)
	rate, source := settings.EffectiveUSDRate()
	rateView := map[string]string{"source": source}
	if rate != nil {
		rateView["rate"] = rate.FloatString(4)
	}
	if settings.RateProblem != "" {
		rateView["problem"] = settings.RateProblem
	}

	if len(request.Samples) > 12 {
		request.Samples = request.Samples[:12]
	}
	out := make([]map[string]any, 0, len(request.Samples))
	for _, sample := range request.Samples {
		kind := strings.ToLower(strings.TrimSpace(sample.Kind))
		currency := strings.ToUpper(strings.TrimSpace(sample.Currency))
		row := map[string]any{"kind": kind, "cost": sample.Cost, "currency": currency}
		cost, ok := new(big.Rat).SetString(strings.TrimSpace(sample.Cost))
		if !ok || cost.Sign() <= 0 {
			row["problem"] = "cost"
			out = append(out, row)
			continue
		}
		costLYD := cost
		if currency == "USD" {
			if costLYD, ok = settings.USDToLYD(cost); !ok {
				row["problem"] = "no_rate"
				out = append(out, row)
				continue
			}
		}
		prices, ok := settings.ServicePrices(kind, costLYD)
		if !ok {
			row["problem"] = "settings"
			out = append(out, row)
			continue
		}
		keeps := new(big.Rat).Sub(prices.ShopPays, costLYD)
		earns := new(big.Rat).Sub(prices.Retail, prices.ShopPays)
		row["cost_lyd"] = control.FormatWalletAmount(costLYD)
		row["margin"] = control.FormatWalletAmount(prices.Margin)
		row["fee"] = control.FormatWalletAmount(prices.Fee)
		row["shop_pays"] = control.FormatWalletAmount(prices.ShopPays)
		row["retail"] = control.FormatWalletAmount(prices.Retail)
		row["company_keeps"] = control.FormatWalletAmount(keeps)
		row["shop_earns"] = control.FormatWalletAmount(earns)
		out = append(out, row)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"valid":         true,
		"rate":          rateView,
		"priced":        settings.Priced(),
		"demo_defaults": settings.DemoDefaults(),
		"samples":       out,
	})
}
