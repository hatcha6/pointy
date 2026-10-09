package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"os"
	"sort"
	"strings"
	"text/tabwriter"
	"time"

	"pointy/relay/internal/reloadly"
	"pointy/relay/internal/vouchers"
)

// pointy-relay vouchers compare [--brand KEY]
//
// For every catalog item that lists two or more suppliers: what each costs the
// company in dinars at the stored settings, who a purchase made now is placed
// with, how much that saves against the next supplier, and what the shop is
// charged against that cost. The relay does the arithmetic (it is the same
// ranking a purchase uses); this only lays it out.

// comparedSupplier is one supplier of a compared item.
type comparedSupplier struct {
	Supplier  string
	Cost      *big.Rat // dinars; nil when it cannot be told
	Candidate bool
	Reason    string
}

// comparedItem is one item that lists several suppliers.
type comparedItem struct {
	Item      string
	Brand     string
	Name      string
	Suppliers []comparedSupplier // in listing order
	// Winner is who a purchase is placed with first, "" when no supplier can sell
	// the card; WinnerCost is what it costs in dinars (nil when not known).
	Winner     string
	WinnerCost *big.Rat
	// Saving is what the winner saves against the next supplier that can sell
	// the card, in dinars, and SavingPercent as a share of that supplier's cost;
	// nil when there is no such supplier or a cost is unknown.
	Saving        *big.Rat
	SavingPercent *big.Rat
	// UnitPrice is what the shop pays now; Margin is that less the winner's cost,
	// MarginPercent as a share of the cost. nil when there is no winner cost.
	UnitPrice     *big.Rat
	Margin        *big.Rat
	MarginPercent *big.Rat
}

// voucherComparison is the whole comparison and its totals.
type voucherComparison struct {
	Items []comparedItem
	// Suppliers names every supplier that appears, in column order.
	Suppliers []string
	// Wins counts the items each supplier is bought from first.
	Wins map[string]int
	// OnlyOne are items where just one supplier can sell the card now (so there
	// is no choice to make); NoneSells are items no supplier can sell.
	OnlyOne   int
	NoneSells int
	// Savings are the winners' savings against their runner-up, in dinars and in
	// percent, for the items where each supplier wins.
	Savings        map[string][]*big.Rat
	SavingPercents map[string][]*big.Rat
	// BelowCost counts the items whose shop price is under the winner's cost.
	BelowCost int
}

func ratFrom(text string) *big.Rat {
	value, ok := new(big.Rat).SetString(strings.TrimSpace(text))
	if !ok {
		return nil
	}
	return value
}

// compareSuppliers lays out the items of a catalog that list two or more
// suppliers, optionally only one brand's.
func compareSuppliers(response voucherAdminCatalog, brandKey string) voucherComparison {
	prices := map[string]*big.Rat{}
	if response.View != nil {
		for _, brand := range response.View.Brands {
			for _, item := range brand.Items {
				prices[item.Key] = ratFrom(item.UnitPrice)
			}
		}
	}
	comparison := voucherComparison{
		Wins:           map[string]int{},
		Savings:        map[string][]*big.Rat{},
		SavingPercents: map[string][]*big.Rat{},
	}
	seen := map[string]bool{}
	for _, entry := range response.Supply {
		if len(entry.Suppliers) < 2 || (brandKey != "" && entry.Brand != brandKey) {
			continue
		}
		item := comparedItem{Item: entry.Item, Brand: entry.Brand, Name: entry.Name, UnitPrice: prices[entry.Item]}
		var ranked []comparedSupplier
		for _, supplier := range entry.Suppliers {
			compared := comparedSupplier{
				Supplier:  supplier.Supplier,
				Cost:      ratFrom(supplier.CostLYD),
				Candidate: supplier.Candidate,
				Reason:    supplier.Reason,
			}
			item.Suppliers = append(item.Suppliers, compared)
			seen[supplier.Supplier] = true
			if supplier.Candidate {
				ranked = append(ranked, compared)
			}
		}
		// The relay's order of trying them: by rank, which the answer already
		// carries as the entries' order of preference.
		sort.SliceStable(ranked, func(i, j int) bool {
			return rankOf(entry, ranked[i].Supplier) < rankOf(entry, ranked[j].Supplier)
		})
		switch len(ranked) {
		case 0:
			comparison.NoneSells++
		case 1:
			comparison.OnlyOne++
		}
		if len(ranked) > 0 {
			winner := ranked[0]
			item.Winner, item.WinnerCost = winner.Supplier, winner.Cost
			comparison.Wins[winner.Supplier]++
			if len(ranked) > 1 && winner.Cost != nil && ranked[1].Cost != nil && ranked[1].Cost.Sign() > 0 {
				item.Saving = new(big.Rat).Sub(ranked[1].Cost, winner.Cost)
				item.SavingPercent = new(big.Rat).Mul(new(big.Rat).Quo(item.Saving, ranked[1].Cost), big.NewRat(100, 1))
				comparison.Savings[winner.Supplier] = append(comparison.Savings[winner.Supplier], item.Saving)
				comparison.SavingPercents[winner.Supplier] = append(comparison.SavingPercents[winner.Supplier], item.SavingPercent)
			}
			if item.UnitPrice != nil && winner.Cost != nil && winner.Cost.Sign() > 0 {
				item.Margin = new(big.Rat).Sub(item.UnitPrice, winner.Cost)
				item.MarginPercent = new(big.Rat).Mul(new(big.Rat).Quo(item.Margin, winner.Cost), big.NewRat(100, 1))
				if item.Margin.Sign() < 0 {
					comparison.BelowCost++
				}
			}
		}
		comparison.Items = append(comparison.Items, item)
	}
	for supplier := range seen {
		comparison.Suppliers = append(comparison.Suppliers, supplier)
	}
	sort.Slice(comparison.Suppliers, func(i, j int) bool {
		return supplierColumn(comparison.Suppliers[i]) < supplierColumn(comparison.Suppliers[j])
	})
	return comparison
}

// rankOf is a supplier's place in the order a purchase tries an item's
// suppliers (1 first).
func rankOf(entry voucherAdminSupply, supplier string) int {
	for _, s := range entry.Suppliers {
		if s.Supplier == supplier {
			return s.Rank
		}
	}
	return 1 << 30
}

// supplierColumn orders the suppliers' columns: BN Plus, Reloadly, then the rest
// by name.
func supplierColumn(supplier string) string {
	switch supplier {
	case vouchers.SupplierBNPlus:
		return "0"
	case vouchers.SupplierReloadly:
		return "1"
	}
	return "2" + supplier
}

// median is the middle of values (the mean of the middle two for an even count);
// nil for none.
func median(values []*big.Rat) *big.Rat {
	if len(values) == 0 {
		return nil
	}
	sorted := append([]*big.Rat(nil), values...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Cmp(sorted[j]) < 0 })
	middle := len(sorted) / 2
	if len(sorted)%2 == 1 {
		return sorted[middle]
	}
	sum := new(big.Rat).Add(sorted[middle-1], sorted[middle])
	return sum.Quo(sum, big.NewRat(2, 1))
}

func sumRats(values []*big.Rat) *big.Rat {
	total := new(big.Rat)
	for _, value := range values {
		total.Add(total, value)
	}
	return total
}

func dinars(value *big.Rat) string {
	if value == nil {
		return "-"
	}
	return value.FloatString(2)
}

func signedDinars(value *big.Rat) string {
	if value == nil {
		return "-"
	}
	if value.Sign() > 0 {
		return "+" + value.FloatString(2)
	}
	return value.FloatString(2)
}

func percent(value *big.Rat) string {
	if value == nil {
		return ""
	}
	return fmt.Sprintf(" (%s %%)", value.FloatString(1))
}

// renderVoucherComparison prints the table and the totals.
func renderVoucherComparison(w io.Writer, comparison voucherComparison, settings *voucherSettingsAnswer) {
	if settings != nil {
		if !settings.Settings.Priced() {
			fmt.Fprintln(w, "usd_rate is NOT SET: Reloadly cannot be priced, so no Reloadly cost appears and Reloadly sells nothing.")
			fmt.Fprintln(w, "Set it:  pointy-relay vouchers settings set --usd-rate <dinars per dollar> --note '...'")
		} else {
			normalized := settings.Settings.Normalized()
			fmt.Fprintf(w, "Costs in dinars at 1 USD = %s LYD (+%s %% funding fee), the stored settings.\n", normalized.USDRate, normalized.FundingPercent)
		}
		fmt.Fprintln(w)
	}
	if len(comparison.Items) == 0 {
		fmt.Fprintln(w, "No catalog item lists two or more suppliers (give an item a \"suppliers\" list, see `pointy-relay vouchers catalog example`).")
		return
	}

	writer := tabwriter.NewWriter(w, 0, 2, 2, ' ', 0)
	header := []string{"ITEM", "CARD"}
	for _, supplier := range comparison.Suppliers {
		header = append(header, strings.ToUpper(supplier))
	}
	header = append(header, "BUY FROM", "SAVING", "SHOP PAYS", "MARGIN")
	fmt.Fprintln(writer, strings.Join(header, "\t"))
	type note struct{ supplier, reason string }
	notes := map[note][]string{}
	var noteOrder []note
	for _, item := range comparison.Items {
		cells := []string{item.Item, item.Name}
		for _, supplier := range comparison.Suppliers {
			cell := "n/a"
			for _, listed := range item.Suppliers {
				if listed.Supplier != supplier {
					continue
				}
				cell = dinars(listed.Cost)
				if !listed.Candidate {
					cell += " !"
					key := note{supplier, listed.Reason}
					if _, known := notes[key]; !known {
						noteOrder = append(noteOrder, key)
					}
					notes[key] = append(notes[key], item.Item)
				}
			}
			cells = append(cells, cell)
		}
		winner := "-"
		if item.Winner != "" {
			winner = item.Winner
		}
		saving := "-"
		if item.Saving != nil {
			saving = dinars(item.Saving) + percent(item.SavingPercent)
		}
		margin := "-"
		if item.Margin != nil {
			margin = signedDinars(item.Margin) + percent(item.MarginPercent)
			if item.Margin.Sign() < 0 {
				margin += " LOSS"
			}
		}
		cells = append(cells, winner, saving, dinars(item.UnitPrice), margin)
		fmt.Fprintln(writer, strings.Join(cells, "\t"))
	}
	_ = writer.Flush()

	if len(noteOrder) > 0 {
		fmt.Fprintln(w, "\n! = that supplier cannot sell the card now:")
		for _, key := range noteOrder {
			items := notes[key]
			shown := strings.Join(items[:min(len(items), 3)], ", ")
			if len(items) > 3 {
				shown += fmt.Sprintf(" and %d more", len(items)-3)
			}
			fmt.Fprintf(w, "  %s: %s (%d: %s)\n", key.supplier, key.reason, len(items), shown)
		}
	}

	fmt.Fprintf(w, "\n%d items list two or more suppliers.\n", len(comparison.Items))
	for _, supplier := range comparison.Suppliers {
		fmt.Fprintf(w, "  %s is bought from first on %d", supplier, comparison.Wins[supplier])
		if savings := comparison.Savings[supplier]; len(savings) > 0 {
			fmt.Fprintf(w, ", saving a median of %s LYD%s a card against the next supplier (%s LYD in all, one of each)",
				dinars(median(savings)), percent(median(comparison.SavingPercents[supplier])), dinars(sumRats(savings)))
		}
		fmt.Fprintln(w)
	}
	if comparison.OnlyOne > 0 {
		fmt.Fprintf(w, "  %d have only one supplier able to sell them now (no choice to make).\n", comparison.OnlyOne)
	}
	if comparison.NoneSells > 0 {
		fmt.Fprintf(w, "  %d cannot be bought from any supplier now.\n", comparison.NoneSells)
	}
	if comparison.BelowCost > 0 {
		fmt.Fprintf(w, "  %d sell below the cost of the supplier they are bought from (LOSS): reprice them.\n", comparison.BelowCost)
	}
}

func runVoucherCompare(args []string) error {
	flags := flag.NewFlagSet("vouchers compare", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	brand := flags.String("brand", "", "only this brand key")
	if err := flags.Parse(args); err != nil {
		return err
	}
	raw, err := admin.requestRaw(http.MethodGet, "/v1/vouchers/admin/catalog", nil, "", nil, 2*time.Minute)
	if err != nil {
		return err
	}
	var response voucherAdminCatalog
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	if response.Catalog == nil || response.View == nil {
		fmt.Println("No catalog has been published. Start from `pointy-relay vouchers catalog example`.")
		return nil
	}
	_, settings, err := readVoucherSettings(admin)
	if err != nil {
		return err
	}
	renderVoucherComparison(os.Stdout, compareSuppliers(response, strings.TrimSpace(*brand)), &settings)
	return nil
}

// runVoucherReloadly reads Reloadly through the relay, with the company's
// credentials that never leave it.
func runVoucherReloadly(args []string) error {
	if len(args) == 0 {
		return usageError("missing reloadly command (balance)")
	}
	switch args[0] {
	case "balance":
		return runVoucherReloadlyBalance(args[1:])
	default:
		return usageError("unknown reloadly command %q", args[0])
	}
}

func runVoucherReloadlyBalance(args []string) error {
	flags := flag.NewFlagSet("vouchers reloadly balance", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	raw, err := admin.requestRaw(http.MethodGet, "/v1/vouchers/admin/reloadly/balance", nil, "", nil, time.Minute)
	if err != nil {
		if strings.Contains(err.Error(), "supplier_unconfigured") {
			return fmt.Errorf("Reloadly is not configured on this relay: set POINTY_RELAY_RELOADLY_CLIENT_ID and POINTY_RELAY_RELOADLY_CLIENT_SECRET (and POINTY_RELAY_RELOADLY_SANDBOX=true for the sandbox)")
		}
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var answer struct {
		Reloadly reloadly.Balance `json:"reloadly"`
		Sandbox  bool             `json:"sandbox"`
	}
	if err := json.Unmarshal(raw, &answer); err != nil {
		return printRawJSON(raw)
	}
	mode := "live"
	if answer.Sandbox {
		mode = "SANDBOX - fake money, not the company's"
	}
	balance := answer.Reloadly
	currency := balance.CurrencyCode
	if currency == "" {
		currency = "USD"
	}
	fmt.Printf("Reloadly gift card balance (%s): %s %s\n", mode, dashIfEmpty(balance.Balance.String()), currency)
	if frozen := balance.FrozenBalance.String(); frozen != "" && frozen != "0" && frozen != "0.0" && frozen != "0.00" {
		fmt.Printf("  frozen: %s %s\n", frozen, currency)
	}
	if threshold := balance.LowBalanceThreshold.String(); threshold != "" {
		fmt.Printf("  Reloadly's low-balance alert threshold: %s %s\n", threshold, currency)
	}
	return nil
}
