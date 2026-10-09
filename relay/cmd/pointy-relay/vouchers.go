package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"pointy/relay/internal/bnplus"
	"pointy/relay/internal/ratelimit"
	relayserver "pointy/relay/internal/relay"
	"pointy/relay/internal/reloadly"
	"pointy/relay/internal/vouchers"
)

// voucherSettings is the card shop's raw configuration as the server reads it.
type voucherSettings struct {
	BNPlusBaseURL  string
	BNPlusEmail    string
	BNPlusPassword string
	BNPlusToken    string
	// ReloadlyClientID and ReloadlyClientSecret are the company's Reloadly API
	// pair, both or neither; ReloadlySandbox points the client at Reloadly's
	// sandbox (fake money); ReloadlyTimeout bounds one Reloadly purchase.
	ReloadlyClientID     string
	ReloadlyClientSecret string
	ReloadlySandbox      bool
	ReloadlyTimeout      time.Duration
	RequestTimeout       time.Duration
	TestMode             bool
	SyncInterval         time.Duration
	RateLimit            string
}

// buildVoucherConfig validates the card shop's settings. A malformed limit,
// interval or URL stops the relay at startup; half a set of BN Plus
// credentials only leaves BN Plus off with a warning, because the relay
// carries the whole fleet and must not stop over one supplier. The supplier
// clients are attached by attachVoucherSuppliers once the shared HTTP
// transport exists.
func buildVoucherConfig(settings voucherSettings) (relayserver.VoucherConfig, bnplus.Config, []string, error) {
	var warnings []string
	rate, err := ratelimit.ParsePolicy(settings.RateLimit)
	if err != nil {
		return relayserver.VoucherConfig{}, bnplus.Config{}, nil, fmt.Errorf("POINTY_RELAY_VOUCHERS_RATE_LIMIT: %w", err)
	}
	if settings.SyncInterval < 0 {
		return relayserver.VoucherConfig{}, bnplus.Config{}, nil, fmt.Errorf("POINTY_RELAY_VOUCHERS_SYNC_INTERVAL must be 0 (off) or positive")
	}
	timeout := settings.RequestTimeout
	if timeout <= 0 {
		timeout = 45 * time.Second
	}
	baseURL := strings.TrimSpace(settings.BNPlusBaseURL)
	if baseURL == "" {
		baseURL = bnplus.DefaultBaseURL
	}
	parsed, err := url.Parse(baseURL)
	if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Host == "" {
		return relayserver.VoucherConfig{}, bnplus.Config{}, nil, fmt.Errorf("POINTY_RELAY_BNPLUS_BASE_URL must be an http(s) URL, got %q", settings.BNPlusBaseURL)
	}
	credentials := bnplus.Config{
		BaseURL:  baseURL,
		Email:    settings.BNPlusEmail,
		Password: settings.BNPlusPassword,
		Token:    settings.BNPlusToken,
		Timeout:  timeout,
	}
	if credentials.Partial() {
		warnings = append(warnings, "BN Plus has only part of its credentials (POINTY_RELAY_BNPLUS_EMAIL, _PASSWORD and _TOKEN go together); cards are not bought from it")
		credentials = bnplus.Config{BaseURL: baseURL, Timeout: timeout}
	}
	if settings.TestMode {
		warnings = append(warnings, "vouchers are in TEST MODE: every purchase gets fake TEST- codes and no supplier is called, while shops' voucher balances are still charged")
	}
	return relayserver.VoucherConfig{
		TestMode:       settings.TestMode,
		RateLimit:      rate,
		RequestTimeout: timeout,
		SyncInterval:   settings.SyncInterval,
		Breaker:        relayserver.NewSupplierBreaker(),
	}, credentials, warnings, nil
}

// attachVoucherSuppliers builds the clients of the suppliers the relay has
// credentials for.
func attachVoucherSuppliers(config *relayserver.VoucherConfig, credentials bnplus.Config, client *http.Client) {
	config.Suppliers = map[string]vouchers.Supplier{}
	if credentials.Configured() {
		credentials.HTTPClient = withoutRedirects(client)
		bn := bnplus.New(credentials)
		config.BNPlus = bn
		config.Suppliers[vouchers.SupplierBNPlus] = vouchers.BNPlusSupplier{Client: bn}
	}
}

// withoutRedirects is a copy of client that never follows a redirect. A
// purchase is a POST that spends money: following a 307 or 308 would send it
// again, and every call carries the company's credentials, which a redirect
// would carry to wherever it points. The redirect itself is the answer, which
// the supplier clients read as a failure.
func withoutRedirects(client *http.Client) *http.Client {
	var copied http.Client
	if client != nil {
		copied = *client
	}
	copied.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return &copied
}

// defaultReloadlyTimeout bounds one Reloadly purchase call.
const defaultReloadlyTimeout = 45 * time.Second

// buildReloadlyConfig reads Reloadly's settings. Half a set of credentials only
// leaves Reloadly off with a warning, exactly like BN Plus: the relay carries
// the whole fleet and must not stop over one supplier. A zero Config means
// Reloadly is not used. Running against the sandbox is warned about loudly,
// because the money there is fake and the catalog is not the live one.
func buildReloadlyConfig(settings voucherSettings) (reloadly.Config, []string) {
	id, secret := strings.TrimSpace(settings.ReloadlyClientID), strings.TrimSpace(settings.ReloadlyClientSecret)
	switch {
	case id == "" && secret == "":
		return reloadly.Config{}, nil
	case id == "" || secret == "":
		return reloadly.Config{}, []string{
			"Reloadly has only part of its credentials (POINTY_RELAY_RELOADLY_CLIENT_ID and _CLIENT_SECRET go together); Reloadly is not used",
		}
	}
	timeout := settings.ReloadlyTimeout
	if timeout <= 0 {
		timeout = defaultReloadlyTimeout
	}
	config := reloadly.Config{
		ClientID:        id,
		ClientSecret:    secret,
		Sandbox:         settings.ReloadlySandbox,
		PurchaseTimeout: timeout,
	}
	var warnings []string
	if config.Sandbox {
		warnings = append(warnings, "Reloadly is in SANDBOX mode (POINTY_RELAY_RELOADLY_SANDBOX): its money is fake and its catalog is not the live one, so nothing bought through it is real")
	}
	return config, warnings
}

// attachReloadlySupplier builds Reloadly's client and registers it as a card
// supplier. The relay's per-call timeout grows to cover Reloadly's, so neither
// supplier's purchase is cut short by the other's setting.
func attachReloadlySupplier(config *relayserver.VoucherConfig, credentials reloadly.Config, client *http.Client) error {
	if credentials.ClientID == "" {
		return nil
	}
	credentials.HTTPClient = withoutRedirects(client)
	reload, err := reloadly.New(credentials)
	if err != nil {
		return fmt.Errorf("reloadly: %w", err)
	}
	if config.Suppliers == nil {
		config.Suppliers = map[string]vouchers.Supplier{}
	}
	config.Reloadly = reload
	config.Suppliers[vouchers.SupplierReloadly] = &vouchers.ReloadlySupplier{Client: reload}
	config.RequestTimeout = max(config.RequestTimeout, credentials.PurchaseTimeout)
	return nil
}

// reloadlyStartupMode is how the startup log says which Reloadly the relay talks
// to: the sandbox is shouted, because it is fake money.
func reloadlyStartupMode(client *reloadly.Client) string {
	switch {
	case client == nil:
		return "off"
	case client.Sandbox():
		return "SANDBOX (fake money)"
	}
	return "live"
}

// runVouchers is the operator's side of the company's card shop.
func runVouchers(args []string) error {
	if len(args) == 0 {
		return usageError("missing vouchers command (catalog, settings, offers, compare, pricing, purchases, check, resolve, bnplus, reloadly, config)")
	}
	switch args[0] {
	case "catalog":
		return runVoucherCatalog(args[1:])
	case "settings":
		return runVoucherSettings(args[1:])
	case "offers":
		return runVoucherOffers(args[1:])
	case "compare":
		return runVoucherCompare(args[1:])
	case "pricing":
		return runVoucherPricing(args[1:])
	case "reloadly":
		return runVoucherReloadly(args[1:])
	case "purchases":
		return runVoucherPurchases(args[1:])
	case "check":
		return runVoucherCheck(args[1:])
	case "resolve":
		return runVoucherResolve(args[1:])
	case "bnplus":
		return runVoucherBNPlus(args[1:])
	case "config":
		return runVoucherConfig(args[1:])
	default:
		return usageError("unknown vouchers command %q", args[0])
	}
}

func runVoucherCatalog(args []string) error {
	if len(args) == 0 {
		return usageError("missing catalog command (example, check, push, show, history)")
	}
	switch args[0] {
	case "example":
		_, err := os.Stdout.WriteString(voucherCatalogExample)
		return err
	case "check":
		return runVoucherCatalogCheck(args[1:])
	case "push":
		return runVoucherCatalogPush(args[1:])
	case "show":
		return runVoucherCatalogShow(args[1:])
	case "history":
		return runVoucherCatalogHistory(args[1:])
	default:
		return usageError("unknown catalog command %q", args[0])
	}
}

// loadVoucherCatalogFile reads and checks a catalog file, images still as
// paths next to it.
func loadVoucherCatalogFile(path string) (vouchers.Document, string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return vouchers.Document{}, "", err
	}
	document, err := vouchers.ParseDocument(raw)
	if err != nil {
		return vouchers.Document{}, "", err
	}
	dir := filepath.Dir(path)
	problems := vouchers.Validate(document, vouchers.ValidateOptions{PathsAllowed: true})
	for _, ref := range vouchers.Images(document) {
		if strings.HasPrefix(ref, vouchers.ImagePrefix) {
			continue
		}
		if _, _, err := readVoucherImage(filepath.Join(dir, ref)); err != nil {
			problems = append(problems, vouchers.Problem{Path: ref, Message: err.Error()})
		}
	}
	if len(problems) > 0 {
		for _, problem := range problems {
			fmt.Fprintf(os.Stderr, "  %s: %s\n", problem.Path, problem.Message)
		}
		return vouchers.Document{}, "", fmt.Errorf("%s has %d problem(s)", path, len(problems))
	}
	return document, dir, nil
}

func readVoucherImage(path string) ([]byte, string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, "", fmt.Errorf("image %s: %w", path, err)
	}
	if len(data) > 2<<20 {
		return nil, "", fmt.Errorf("image %s is larger than 2 MB", path)
	}
	contentType := http.DetectContentType(data)
	switch contentType {
	case "image/png", "image/jpeg", "image/webp":
		return data, contentType, nil
	}
	return nil, "", fmt.Errorf("image %s is %s; use PNG, JPEG or WebP", path, contentType)
}

func runVoucherCatalogCheck(args []string) error {
	if len(args) == 0 {
		return usageError("missing catalog file")
	}
	document, _, err := loadVoucherCatalogFile(args[0])
	if err != nil {
		return err
	}
	items := 0
	for _, brand := range document.Brands {
		items += len(brand.Items)
	}
	fmt.Printf("%s is valid: %d categories, %d brands, %d items, %d images.\n",
		args[0], len(document.Categories), len(document.Brands), items, len(vouchers.Images(document)))
	return nil
}

// runVoucherCatalogPush uploads the images a catalog file names, then
// publishes the catalog with them as uploaded references.
func runVoucherCatalogPush(args []string) error {
	if len(args) == 0 || strings.HasPrefix(args[0], "-") {
		return usageError("missing catalog file as the first argument")
	}
	path := args[0]
	flags := flag.NewFlagSet("vouchers catalog push", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	note := flags.String("note", "", "what changed, kept with the version")
	actor := flags.String("actor", "", "who published (defaults to POINTY_RELAY_OPERATOR, then $USER)")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	document, dir, err := loadVoucherCatalogFile(path)
	if err != nil {
		return err
	}
	uploaded := map[string]string{}
	upload := func(ref string) (string, error) {
		ref = strings.TrimSpace(ref)
		if ref == "" || strings.HasPrefix(ref, vouchers.ImagePrefix) {
			return ref, nil
		}
		if done, ok := uploaded[ref]; ok {
			return done, nil
		}
		data, contentType, err := readVoucherImage(filepath.Join(dir, ref))
		if err != nil {
			return "", err
		}
		raw, err := admin.requestRaw(http.MethodPost, "/v1/vouchers/admin/images", nil, contentType, data, 30*time.Second)
		if err != nil {
			return "", fmt.Errorf("uploading %s: %w", ref, err)
		}
		var answer struct {
			Ref     string `json:"ref"`
			Created bool   `json:"created"`
		}
		if err := json.Unmarshal(raw, &answer); err != nil || answer.Ref == "" {
			return "", fmt.Errorf("uploading %s: unexpected answer %s", ref, strings.TrimSpace(string(raw)))
		}
		state := "already there"
		if answer.Created {
			state = "uploaded"
		}
		fmt.Printf("  %-40s %s (%s)\n", ref, answer.Ref[:len(vouchers.ImagePrefix)+12]+"…", state)
		uploaded[ref] = answer.Ref
		return answer.Ref, nil
	}
	for i := range document.Countries {
		if document.Countries[i].Flag, err = upload(document.Countries[i].Flag); err != nil {
			return err
		}
	}
	for i := range document.Brands {
		logo := &document.Brands[i].Logo
		if logo.Display, err = upload(logo.Display); err != nil {
			return err
		}
		if logo.Print, err = upload(logo.Print); err != nil {
			return err
		}
	}
	raw, err := admin.requestRaw(http.MethodPut, "/v1/vouchers/admin/catalog", nil, "application/json",
		mustJSON(map[string]any{"document": document, "actor": resolveActor(*actor), "note": *note}), 60*time.Second)
	if err != nil {
		return err
	}
	var answer struct {
		Catalog struct {
			ID     string `json:"id"`
			SHA256 string `json:"sha256"`
		} `json:"catalog"`
		Unchanged bool           `json:"unchanged"`
		Summary   map[string]int `json:"summary"`
	}
	if err := json.Unmarshal(raw, &answer); err != nil {
		return printRawJSON(raw)
	}
	if answer.Unchanged {
		fmt.Printf("Unchanged: the relay already publishes this catalog (%s).\n", answer.Catalog.ID)
		return nil
	}
	fmt.Printf("Published catalog %s: %d categories, %d brands, %d items. Shops pick it up within five minutes.\n",
		answer.Catalog.ID, answer.Summary["categories"], answer.Summary["brands"], answer.Summary["items"])
	if listsReloadly(document) {
		fmt.Println("Reloadly prices only the cards a catalog names: run `pointy-relay vouchers offers --sync` so the new ones are priced and sell (the relay does it by itself every sync interval).")
	}
	return nil
}

// listsReloadly reports whether any item of the catalog can be bought from
// Reloadly.
func listsReloadly(document vouchers.Document) bool {
	for _, brand := range document.Brands {
		for _, item := range brand.Items {
			refs, err := vouchers.ParseRefs(item)
			if err != nil {
				continue
			}
			for _, ref := range refs {
				if ref.Supplier == vouchers.SupplierReloadly {
					return true
				}
			}
		}
	}
	return false
}

type voucherAdminCatalog struct {
	Catalog *struct {
		ID        string `json:"id"`
		SHA256    string `json:"sha256"`
		Actor     string `json:"actor"`
		Note      string `json:"note"`
		CreatedAt string `json:"created_at"`
	} `json:"catalog"`
	View *vouchers.ShopView `json:"view"`
	// Supply mirrors the relay's voucherItemSupply.
	Supply []voucherAdminSupply `json:"supply"`
}

// voucherAdminOfferRow is an offer as the relay's admin routes write it.
type voucherAdminOfferRow struct {
	Name     string `json:"name"`
	Price    string `json:"price"`
	Currency string `json:"currency"`
	InStock  bool   `json:"in_stock"`
}

// voucherAdminSupply mirrors the relay's voucherItemSupply: one item, whom it is
// bought from, and what each supplier costs.
type voucherAdminSupply struct {
	Item      string                `json:"item"`
	Brand     string                `json:"brand"`
	Name      string                `json:"name"`
	Supplier  string                `json:"supplier"`
	Ref       string                `json:"ref"`
	MaxCost   string                `json:"max_cost"`
	Offer     *voucherAdminOfferRow `json:"offer"`
	Available bool                  `json:"available"`
	Reason    string                `json:"reason"`
	Winner    string                `json:"winner"`
	Suppliers []struct {
		Supplier  string                `json:"supplier"`
		Ref       string                `json:"ref"`
		MaxCost   string                `json:"max_cost"`
		Offer     *voucherAdminOfferRow `json:"offer"`
		CostLYD   string                `json:"cost_lyd"`
		Candidate bool                  `json:"candidate"`
		Rank      int                   `json:"rank"`
		Reason    string                `json:"reason"`
	} `json:"suppliers"`
}

// supplierCells is how `catalog show` writes an item's supplier and price
// columns: one supplier as it always did, several side by side ("bnplus:12 |
// reloadly:13441/50"), the first of them being who is bought from first.
func (e voucherAdminSupply) supplierCells() (supplier, price string) {
	if len(e.Suppliers) < 2 {
		supplier = e.Supplier + ":" + e.Ref
		price = "-"
		if e.Offer != nil {
			price = e.Offer.Price + " " + e.Offer.Currency
			if e.MaxCost != "" {
				price += " (max " + e.MaxCost + ")"
			}
		}
		return supplier, price
	}
	var suppliers, prices []string
	for _, s := range e.Suppliers {
		suppliers = append(suppliers, s.Supplier+":"+s.Ref)
		cell := "-"
		if s.Offer != nil {
			cell = s.Offer.Price + " " + s.Offer.Currency
			if s.CostLYD != "" && !strings.EqualFold(s.Offer.Currency, "LYD") {
				cell += " = " + trimDinars(s.CostLYD) + " LYD"
			}
			if s.MaxCost != "" {
				cell += " (max " + s.MaxCost + ")"
			}
		}
		prices = append(prices, cell)
	}
	return strings.Join(suppliers, " | "), strings.Join(prices, " | ")
}

// trimDinars writes a dinar amount the relay sent with four decimals as two.
func trimDinars(value string) string {
	amount, ok := new(big.Rat).SetString(strings.TrimSpace(value))
	if !ok {
		return value
	}
	return amount.FloatString(2)
}

func runVoucherCatalogShow(args []string) error {
	flags := flag.NewFlagSet("vouchers catalog show", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/vouchers/admin/catalog", nil, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response voucherAdminCatalog
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	if response.Catalog == nil || response.View == nil {
		fmt.Println("No catalog has been published. Start from `pointy-relay vouchers catalog example`.")
		return nil
	}
	fmt.Printf("Catalog %s, published %s by %s%s\n\n", response.Catalog.ID, formatPeriodBound(response.Catalog.CreatedAt),
		dashIfEmpty(response.Catalog.Actor), noteSuffix(response.Catalog.Note))
	supply := map[string]int{}
	for i, entry := range response.Supply {
		supply[entry.Item] = i
	}
	categories := map[string]string{}
	for _, category := range response.View.Categories {
		categories[category.Key] = category.Name
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(writer, "#\tBRAND\tCATEGORY\tITEM\tLABEL\tSHOP PAYS\tCUSTOMER PAYS\tPROMO\tSUPPLIER\tSUPPLIER PRICE\tSELLS")
	for _, brand := range response.View.Brands {
		marker := ""
		if brand.Featured {
			marker = "★ "
		}
		for _, item := range brand.Items {
			label := item.Label
			if item.Country != "" {
				label = item.Country + " · " + label
			}
			promo := "-"
			if item.Promo != nil {
				promo = item.Promo.Badge + " until " + item.Promo.EndsAt.Format("2006-01-02 15:04")
			}
			supplier, price, sells := "-", "-", "yes"
			if i, ok := supply[item.Key]; ok {
				entry := response.Supply[i]
				supplier, price = entry.supplierCells()
				if !entry.Available {
					sells = "no: " + entry.Reason
				}
			}
			fmt.Fprintf(writer, "%d\t%s%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
				brand.Rank+1, marker, brand.Name, categories[brand.Category], item.Key, label,
				item.UnitPrice, item.RetailPrice, promo, supplier, price, sells)
		}
	}
	if err := writer.Flush(); err != nil {
		return err
	}
	fmt.Printf("\n%d categories, %d brands; shops see version %s.\n",
		len(response.View.Categories), len(response.View.Brands), response.View.Version)
	return nil
}

func noteSuffix(note string) string {
	if strings.TrimSpace(note) == "" {
		return ""
	}
	return ` ("` + note + `")`
}

func runVoucherCatalogHistory(args []string) error {
	flags := flag.NewFlagSet("vouchers catalog history", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	limit := flags.Int("limit", 20, "how many versions")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/vouchers/admin/catalogs", url.Values{"limit": {strconv.Itoa(*limit)}}, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response struct {
		Catalogs []struct {
			ID        string `json:"id"`
			SHA256    string `json:"sha256"`
			Actor     string `json:"actor"`
			Note      string `json:"note"`
			CreatedAt string `json:"created_at"`
		} `json:"catalogs"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(writer, "PUBLISHED\tCATALOG\tBY\tNOTE")
	for _, catalog := range response.Catalogs {
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\n", formatPeriodBound(catalog.CreatedAt), catalog.ID,
			dashIfEmpty(catalog.Actor), dashIfEmpty(catalog.Note))
	}
	return writer.Flush()
}

func runVoucherOffers(args []string) error {
	flags := flag.NewFlagSet("vouchers offers", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	supplier := flags.String("supplier", "", "only this supplier (bnplus, reloadly)")
	sync := flags.Bool("sync", false, "read every supplier's offers now first (Reloadly prices the cards the published catalog names)")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *sync {
		raw, err := admin.requestRaw(http.MethodPost, "/v1/vouchers/admin/offers/sync", nil, "application/json", []byte("{}"), 5*time.Minute)
		if err != nil {
			return err
		}
		fmt.Printf("Synced: %s\n\n", describeOfferSync(raw))
	}
	params := url.Values{}
	if value := strings.TrimSpace(*supplier); value != "" {
		params.Set("supplier", value)
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/vouchers/admin/offers", params, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response struct {
		Offers []struct {
			Supplier string `json:"supplier"`
			Ref      string `json:"ref"`
			Name     string `json:"name"`
			Group    string `json:"group"`
			Price    string `json:"price"`
			Currency string `json:"currency"`
			CostLYD  string `json:"cost_lyd"`
			InStock  bool   `json:"in_stock"`
			SyncedAt string `json:"synced_at"`
		} `json:"offers"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	if len(response.Offers) == 0 {
		fmt.Println("No offers read yet. Run with --sync (needs BN Plus or Reloadly credentials on the relay; Reloadly prices the cards the published catalog names).")
		return nil
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(writer, "SUPPLIER\tCARD ID\tCOMPANY\tCARD\tCOMPANY PRICE\tIN LYD\tSTOCK\tREAD")
	for _, offer := range response.Offers {
		stock := "in stock"
		if !offer.InStock {
			stock = "OUT"
		}
		// What the card costs the company in dinars at the stored settings, so the
		// suppliers read side by side; "-" when it cannot be told (no dollar rate).
		dinars := "-"
		if offer.CostLYD != "" {
			dinars = trimDinars(offer.CostLYD)
		}
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s %s\t%s\t%s\t%s\n", offer.Supplier, offer.Ref, dashIfEmpty(offer.Group),
			offer.Name, offer.Price, offer.Currency, dinars, stock, formatPeriodBound(offer.SyncedAt))
	}
	return writer.Flush()
}

// describeOfferSync reads the offer sync's answer ({"synced": {"bnplus": 451,
// "reloadly": 38}}) as a sentence that names every supplier read; anything else
// is shown as it came.
func describeOfferSync(raw []byte) string {
	var answer struct {
		Synced map[string]int `json:"synced"`
	}
	if err := json.Unmarshal(raw, &answer); err != nil || answer.Synced == nil {
		return strings.TrimSpace(string(raw))
	}
	if len(answer.Synced) == 0 {
		return "no supplier is configured on this relay"
	}
	suppliers := make([]string, 0, len(answer.Synced))
	for supplier := range answer.Synced {
		suppliers = append(suppliers, supplier)
	}
	sort.Strings(suppliers)
	parts := make([]string, 0, len(suppliers))
	for _, supplier := range suppliers {
		parts = append(parts, fmt.Sprintf("%s %d offers", supplier, answer.Synced[supplier]))
	}
	return strings.Join(parts, ", ")
}

func runVoucherPurchases(args []string) error {
	flags := flag.NewFlagSet("vouchers purchases", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	installation := flags.String("installation", "", "only this installation id")
	status := flags.String("status", "", "only this status: pending, succeeded, failed")
	kind := flags.String("kind", "", "only this kind: card, airtime (direct top-up), bill")
	held := flags.Bool("held", false, "only purchases whose outcome is still being found out")
	limit := flags.Int("limit", 50, "maximum rows (1-500)")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	params := url.Values{"limit": {strconv.Itoa(*limit)}}
	if value := strings.TrimSpace(*installation); value != "" {
		params.Set("installation_id", value)
	}
	if value := strings.TrimSpace(*status); value != "" {
		params.Set("status", value)
	}
	if value := strings.TrimSpace(*kind); value != "" {
		params.Set("kind", value)
	}
	if *held {
		params.Set("held", "1")
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/vouchers/admin/purchases", params, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response struct {
		Purchases []struct {
			ID              string  `json:"id"`
			ShopName        string  `json:"shop_name"`
			Kind            string  `json:"kind"`
			Name            string  `json:"name"`
			Target          string  `json:"target"`
			Quantity        int     `json:"quantity"`
			Amount          string  `json:"amount"`
			Supplier        string  `json:"supplier"`
			SupplierOrderID string  `json:"supplier_order_id"`
			SupplierCost    string  `json:"supplier_cost"`
			SupplierCurr    string  `json:"supplier_currency"`
			Status          string  `json:"status"`
			ErrorCode       string  `json:"error_code"`
			TestMode        bool    `json:"test_mode"`
			HeldSince       *string `json:"held_since"`
			CreatedAt       string  `json:"created_at"`
		} `json:"purchases"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(writer, "WHEN\tSHOP\tKIND\tITEM\tTARGET\tQTY\tCHARGED\tSUPPLIER COST\tSTATUS\tORDER\tPURCHASE")
	for _, row := range response.Purchases {
		status := row.Status
		if row.HeldSince != nil {
			status += " (held)"
		}
		if row.ErrorCode != "" {
			status += " " + row.ErrorCode
		}
		if row.TestMode {
			status += " [test]"
		}
		cost := "-"
		if row.SupplierCost != "" {
			cost = row.SupplierCost + " " + row.SupplierCurr
		}
		rowKind := row.Kind
		if rowKind == "" {
			rowKind = "card"
		}
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n", formatPeriodBound(row.CreatedAt),
			dashIfEmpty(row.ShopName), rowKind, row.Name, dashIfEmpty(row.Target), row.Quantity, row.Amount, cost, status,
			dashIfEmpty(row.SupplierOrderID), row.ID)
	}
	return writer.Flush()
}

func runVoucherCheck(args []string) error {
	flags := flag.NewFlagSet("vouchers check", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	if len(args) == 0 || strings.HasPrefix(args[0], "-") {
		return usageError("missing purchase id as the first argument")
	}
	id := strings.TrimSpace(args[0])
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	raw, err := admin.requestRaw(http.MethodPost, "/v1/vouchers/admin/purchases/"+url.PathEscape(id)+"/check",
		nil, "application/json", []byte("{}"), 2*time.Minute)
	if err != nil {
		return err
	}
	return printRawJSON(raw)
}

func runVoucherResolve(args []string) error {
	flags := flag.NewFlagSet("vouchers resolve", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	refund := flags.Bool("refund", false, "the cards were never bought: give the shop its money back")
	found := flags.String("found", "", "the cards were bought on this supplier order: keep the charge")
	reason := flags.String("reason", "", "why (required; kept on the purchase)")
	actor := flags.String("actor", "", "who decided (defaults to POINTY_RELAY_OPERATOR, then $USER)")
	if len(args) == 0 || strings.HasPrefix(args[0], "-") {
		return usageError("missing purchase id as the first argument")
	}
	id := strings.TrimSpace(args[0])
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if *refund == (strings.TrimSpace(*found) != "") {
		return usageError("pass exactly one of --refund or --found <supplier order id>")
	}
	if strings.TrimSpace(*reason) == "" {
		return usageError("--reason is required")
	}
	body := map[string]any{"reason": *reason, "actor": resolveActor(*actor), "outcome": "refund"}
	if !*refund {
		body["outcome"] = "found"
		body["supplier_order_id"] = strings.TrimSpace(*found)
	}
	raw, err := admin.requestJSON(http.MethodPost, "/v1/vouchers/admin/purchases/"+url.PathEscape(id)+"/resolve", nil, body)
	if err != nil {
		return err
	}
	return printRawJSON(raw)
}

// runVoucherBNPlus reads BN Plus through the relay, with the company's
// credentials that never leave it: what to put in a catalog's card_id.
func runVoucherBNPlus(args []string) error {
	if len(args) == 0 {
		return usageError("missing bnplus command (wallets, groups, companies, cards, orders, order)")
	}
	what := args[0]
	flags := flag.NewFlagSet("vouchers bnplus "+what, flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	groupType := flags.String("type", "", "groups: local or international")
	group := flags.Int64("group", 0, "companies: only this group id")
	branch := flags.Int64("branch", 0, "cards: the company (branch) id")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	rest := args[1:]
	params := url.Values{}
	if what == "order" {
		if len(rest) == 0 || strings.HasPrefix(rest[0], "-") {
			return usageError("missing order id")
		}
		params.Set("order_id", strings.TrimSpace(rest[0]))
		rest = rest[1:]
	}
	if err := flags.Parse(rest); err != nil {
		return err
	}
	switch what {
	case "wallets", "orders", "order":
	case "groups":
		if *groupType != "" {
			params.Set("type", *groupType)
		}
	case "companies":
		if *group > 0 {
			params.Set("group_id", strconv.FormatInt(*group, 10))
		}
	case "cards":
		if *branch <= 0 {
			return usageError("cards needs --branch <company id> (see `vouchers bnplus companies`)")
		}
		params.Set("branch_id", strconv.FormatInt(*branch, 10))
	default:
		return usageError("unknown bnplus command %q", what)
	}
	raw, err := admin.requestRaw(http.MethodGet, "/v1/vouchers/admin/bnplus/"+what, params, "", nil, 2*time.Minute)
	if err != nil {
		return err
	}
	if *asJSON || what == "order" || what == "orders" {
		// Orders carry codes: printed only when asked for, as JSON.
		return printRawJSON(raw)
	}
	var response struct {
		BNPlus json.RawMessage `json:"bnplus"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return printRawJSON(raw)
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	switch what {
	case "wallets":
		var wallets []bnplus.Wallet
		_ = json.Unmarshal(response.BNPlus, &wallets)
		fmt.Fprintln(writer, "WALLET\tCURRENCY\tBALANCE")
		for _, wallet := range wallets {
			fmt.Fprintf(writer, "%s\t%s\t%s\n", wallet.Name, wallet.Currency, wallet.Balance)
		}
	case "groups":
		var groups []bnplus.Group
		_ = json.Unmarshal(response.BNPlus, &groups)
		fmt.Fprintln(writer, "GROUP ID\tNAME\tTYPE")
		for _, group := range groups {
			fmt.Fprintf(writer, "%d\t%s / %s\t%s\n", group.ID, group.NameAR, group.NameEN, group.Type)
		}
	case "companies":
		var companies []bnplus.Company
		_ = json.Unmarshal(response.BNPlus, &companies)
		sort.Slice(companies, func(i, j int) bool { return companies[i].Name < companies[j].Name })
		fmt.Fprintln(writer, "COMPANY (BRANCH) ID\tNAME")
		for _, company := range companies {
			fmt.Fprintf(writer, "%d\t%s\n", company.BranchID, company.Name)
		}
	case "cards":
		var cards []bnplus.Card
		_ = json.Unmarshal(response.BNPlus, &cards)
		fmt.Fprintln(writer, "CARD ID\tNAME\tCOMPANY PRICE\tSTOCK")
		for _, card := range cards {
			stock := "in stock"
			if !card.InStock {
				stock = "OUT"
			}
			fmt.Fprintf(writer, "%d\t%s\t%s %s\t%s\n", card.ID, card.Name, card.MerchantPrice, card.Currency, stock)
		}
	}
	return writer.Flush()
}

func runVoucherConfig(args []string) error {
	flags := flag.NewFlagSet("vouchers config", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	if err := flags.Parse(args); err != nil {
		return err
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/vouchers/admin/config", nil, nil)
	if err != nil {
		return err
	}
	return printRawJSON(raw)
}

// requestRaw is requestJSON with a body of any type and a longer timeout:
// image uploads, supplier reads and syncs outlast the admin client's 10 s.
func (a *adminControlFlags) requestRaw(
	method, path string,
	query url.Values,
	contentType string,
	body []byte,
	timeout time.Duration,
) (json.RawMessage, error) {
	if strings.TrimSpace(*a.adminToken) == "" {
		return nil, fmt.Errorf("admin token is required (set --admin-token or POINTY_RELAY_ADMIN_TOKEN)")
	}
	endpoint, err := relayAdminEndpoint(*a.controlURL, path)
	if err != nil {
		return nil, err
	}
	if len(query) > 0 {
		endpoint.RawQuery = query.Encode()
	}
	client, err := newRelayAdminHTTPClient(relayAdminHTTPClientOptions{
		ControlURL:     *a.controlURL,
		AllowInsecure:  *a.allowInsecure,
		CAFile:         *a.caFile,
		ClientCertFile: *a.clientCertFile,
		ClientKeyFile:  *a.clientKeyFile,
		TLSServerName:  *a.tlsServerName,
	})
	if err != nil {
		return nil, err
	}
	client.Timeout = timeout
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	request, err := http.NewRequest(method, endpoint.String(), reader)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Accept", "application/json")
	if contentType != "" {
		request.Header.Set("Content-Type", contentType)
	}
	request.Header.Set("Authorization", "Bearer "+strings.TrimSpace(*a.adminToken))
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	payload, _ := io.ReadAll(io.LimitReader(response.Body, 32<<20))
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return nil, fmt.Errorf("relay admin %s %s returned %d: %s", method, path, response.StatusCode, strings.TrimSpace(string(payload)))
	}
	return json.RawMessage(payload), nil
}

func mustJSON(value any) []byte {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		panic(err)
	}
	return buffer.Bytes()
}

// voucherCatalogExample is a starter catalog: our categories, a featured
// brand sold for two store regions with a promotion, and a local card. Images
// are paths next to the file; push uploads them.
const voucherCatalogExample = `{
  "categories": [
    {"key": "gift_cards", "name": "بطاقات الهدايا", "sort": 10},
    {"key": "gaming", "name": "ألعاب", "sort": 20},
    {"key": "telecom", "name": "اتصالات", "sort": 30}
  ],
  "countries": [
    {"code": "US", "flag": "flags/us.png"},
    {"code": "GB", "flag": "flags/gb.png"}
  ],
  "brands": [
    {
      "key": "itunes",
      "name": "آيتونز",
      "aliases": ["iTunes", "Apple", "ابل"],
      "category": "gift_cards",
      "sort": 10,
      "featured": true,
      "badge": "الأكثر مبيعاً",
      "redeem_hint": "App Store ← الحساب ← استرداد بطاقة هدية",
      "logo": {"display": "logos/itunes.png", "print": "logos/itunes-print.png"},
      "items": [
        {
          "key": "itunes-us-10", "country": "US", "face_value": "10", "face_currency": "USD",
          "price": "52.00", "retail_price": "60.00",
          "promo": {"price": "50.00", "badge": "ربح أكبر", "starts_at": "2026-10-10T00:00:00+02:00", "ends_at": "2026-10-20T00:00:00+02:00"},
          "supplier": {"key": "bnplus", "card_id": 101, "max_cost": "51.00"}
        },
        {
          "key": "itunes-gb-10", "country": "GB", "face_value": "10", "face_currency": "GBP",
          "price": "68.00", "retail_price": "78.00",
          "supplier": {"key": "bnplus", "card_id": 102}
        }
      ]
    },
    {
      "key": "psn",
      "name": "بلايستيشن",
      "aliases": ["PlayStation", "PSN"],
      "category": "gaming",
      "sort": 20,
      "logo": {"display": "logos/psn.png", "print": "logos/psn-print.png"},
      "items": [
        {
          "key": "psn-us-20", "country": "US", "face_value": "20", "face_currency": "USD",
          "price": "104.00", "retail_price": "118.00",
          "suppliers": [
            {"key": "bnplus", "card_id": 201, "max_cost": "102.00"},
            {"key": "reloadly", "product_id": 13441, "amount": "20", "max_cost": "103.00"}
          ]
        }
      ]
    },
    {
      "key": "libyana",
      "name": "ليبيانا",
      "category": "telecom",
      "sort": 30,
      "logo": {"display": "logos/libyana.png", "print": "logos/libyana-print.png"},
      "items": [
        {
          "key": "libyana-10", "face_value": "10", "face_currency": "LYD",
          "price": "9.70", "retail_price": "10.00",
          "supplier": {"key": "bnplus", "card_id": 12}
        }
      ]
    }
  ]
}
`
