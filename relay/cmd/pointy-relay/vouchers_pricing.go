package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"os"
	"strings"
	"text/tabwriter"
	"time"

	"pointy/relay/internal/vouchers"
)

// pointy-relay vouchers pricing report --catalog catalog.json [--rate 9.76] [--brand KEY]
//
// For every auto-priced card of a catalog file: the cheapest supplier cost the
// relay knows now, the market price brought to today's dollar rate, and the
// price the relay would sell at, with the company's and the shop's cut. Items
// whose floor is above the market are flagged: we are not the cheapest there.

type pricingRow struct {
	Item, Brand string
	Cost        *big.Rat
	Priced      vouchers.MarketPricing
	Flag        string
}

func pricingRows(document vouchers.Document, costs map[string]*big.Rat, settings vouchers.Settings, rate *big.Rat, now time.Time, brand string) []pricingRow {
	margin := settings.MarginFor(vouchers.ServiceKindCard)
	var rows []pricingRow
	for _, b := range document.Brands {
		if brand != "" && b.Key != brand {
			continue
		}
		for _, item := range b.Items {
			cost := costs[item.Key]
			if !document.AutoPriced(item) || cost == nil {
				continue
			}
			if strings.EqualFold(item.FaceCurrency, "LYD") {
				face := ratFrom(item.FaceValue)
				if shop, retail, ok := margin.LocalPrices(cost, face); ok {
					rows = append(rows, pricingRow{Item: item.Key, Brand: b.Key, Cost: cost, Flag: "local at face", Priced: vouchers.MarketPricing{
						Retail: retail, ShopPays: shop, CompanyCut: new(big.Rat).Sub(shop, cost), ShopCut: new(big.Rat).Sub(retail, shop)}})
				}
				continue
			}
			marketNow := margin.MarketNow(item.Market, rate, now)
			priced, ok := margin.MarketPrices(cost, marketNow)
			if !ok {
				continue
			}
			row := pricingRow{Item: item.Key, Brand: b.Key, Cost: cost, Priced: priced}
			if marketNow == nil {
				// No fresh market: the plain formula is what sells.
				if plain, ok := margin.Prices(cost); ok {
					row.Priced.Retail, row.Priced.ShopPays = plain.Retail, plain.ShopPays
					row.Priced.CompanyCut = new(big.Rat).Sub(plain.ShopPays, cost)
					row.Priced.ShopCut = new(big.Rat).Sub(plain.Retail, plain.ShopPays)
				}
				row.Flag = "formula"
			} else if priced.FloorAboveMarket {
				row.Flag = "NOT CHEAPEST"
			}
			rows = append(rows, row)
		}
	}
	return rows
}

func renderPricingRows(w io.Writer, rows []pricingRow) {
	tw := tabwriter.NewWriter(w, 0, 4, 2, ' ', 0)
	fmt.Fprintln(tw, "item\tcost\tmarket_now\tretail\tshop pays\tcompany cut\tshop cut\tflag")
	dash := func(v *big.Rat) string {
		if v == nil {
			return "-"
		}
		return v.FloatString(2)
	}
	for _, r := range rows {
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", r.Item, dash(r.Cost), dash(r.Priced.MarketNow),
			dash(r.Priced.Retail), dash(r.Priced.ShopPays), dash(r.Priced.CompanyCut), dash(r.Priced.ShopCut), r.Flag)
	}
	tw.Flush()
}

func runVoucherPricing(args []string) error {
	if len(args) == 0 || args[0] != "report" {
		return usageError("usage: vouchers pricing report --catalog FILE [--rate N] [--brand KEY]")
	}
	flags := flag.NewFlagSet("vouchers pricing report", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	file := flags.String("catalog", "", "catalog file whose market data and auto items are priced")
	rateText := flags.String("rate", "", "dinars per dollar (default: the settings' rate)")
	brand := flags.String("brand", "", "only this brand key")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	raw, err := os.ReadFile(*file)
	if err != nil {
		return err
	}
	document, err := vouchers.ParseDocument(raw)
	if err != nil {
		return err
	}
	body, err := admin.requestRaw(http.MethodGet, "/v1/vouchers/admin/catalog", nil, "", nil, 2*time.Minute)
	if err != nil {
		return err
	}
	var response voucherAdminCatalog
	if err := json.Unmarshal(body, &response); err != nil {
		return err
	}
	_, answer, err := readVoucherSettings(admin)
	if err != nil {
		return err
	}
	settings := answer.Settings.Normalized()
	rate, _ := settings.EffectiveUSDRate()
	if text := strings.TrimSpace(*rateText); text != "" {
		rate = ratFrom(text)
	}
	if rate == nil {
		return fmt.Errorf("no dollar rate: pass --rate")
	}
	costs := map[string]*big.Rat{}
	for _, entry := range response.Supply {
		for _, s := range entry.Suppliers {
			if c := ratFrom(s.CostLYD); s.Candidate && c != nil && (costs[entry.Item] == nil || c.Cmp(costs[entry.Item]) < 0) {
				costs[entry.Item] = c
			}
		}
		if len(entry.Suppliers) == 0 && entry.Offer != nil && entry.Offer.Currency == "LYD" {
			costs[entry.Item] = ratFrom(entry.Offer.Price)
		}
	}
	renderPricingRows(os.Stdout, pricingRows(document, costs, settings, rate, time.Now(), strings.TrimSpace(*brand)))
	return nil
}
