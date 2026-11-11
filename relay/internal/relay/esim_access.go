package relay

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"

	"pointy/relay/internal/airalo"
	"pointy/relay/internal/alerts"
	"pointy/relay/internal/control"
	"pointy/relay/internal/esimaccess"
	"pointy/relay/internal/vouchers"
)

// eSIM Access is the shelf's second supplier (the first is Airalo). The app
// sees one shelf: a plan says who it is bought from, an eSIM says who issued
// it, and everything the app reads (the install details, the usage, the
// top-ups, the low-data alerts) has the same shape from either.
//
//	POST /v1/customers/esim/webhook/access/{token}   eSIM Access's events
//
// eSIM Access does not sign its webhooks. The address carries a secret, and a
// delivery is believed for nothing but which eSIM to read again: what is told
// to a customer always comes from the API.

const (
	// esimAccessPlanPrefix marks a plan id as eSIM Access's, so an order item
	// names its supplier and no two suppliers' ids can collide.
	esimAccessPlanPrefix = "ea."
	// esimAccessImages is where the API's relative image paths live.
	esimAccessImages = "https://p.qrsim.net"
	// esimAccessMinMB leaves the plans under a gigabyte off the shelf: with a
	// lowest price they would cost what the gigabyte does.
	esimAccessMinMB = 1024
	// esimAccessBalanceEvery spaces the low-balance alerts.
	esimAccessBalanceEvery = 12 * time.Hour

	maxESIMAccessWebhookLen = 64 << 10
)

// ESIMAccessWebhookPath is where eSIM Access's events arrive on this relay; the
// secret token follows it.
const ESIMAccessWebhookPath = "/v1/customers/esim/webhook/access"

// Alert levels the relay works out itself from an eSIM Access eSIM's usage,
// beside Airalo's (airalo.Level75 and the rest), which they share.
const esimLevelUsedUp = "used-up"

// ESIMAccessWebhookToken is the secret in the webhook address eSIM Access is
// given, derived from the account's access code, so it needs no setting of its
// own. Rotating the code changes it: the relay registers the address again.
func ESIMAccessWebhookToken(accessCode string) string {
	accessCode = strings.TrimSpace(accessCode)
	if accessCode == "" {
		return ""
	}
	mac := hmac.New(sha256.New, []byte(accessCode))
	mac.Write([]byte("pointy-esimaccess-webhook/v1"))
	return hex.EncodeToString(mac.Sum(nil))[:32]
}

// esimSupplierOf is who issued an eSIM; "" for a simulated one.
func esimSupplierOf(esim control.CustomerESIM) string {
	switch {
	case esim.Simulated:
		return ""
	case esim.Supplier != "":
		return esim.Supplier
	}
	return vouchers.SupplierAiralo
}

// planSupplier is who a catalog plan is bought from.
func planSupplier(plan esimPlan) string {
	if plan.Supplier != "" {
		return plan.Supplier
	}
	return vouchers.SupplierAiralo
}

// --- the catalog -----------------------------------------------------------

// esimAccessRegions names the regions eSIM Access sells, by the code its slugs
// start with. A region missing here is named from its countries when they are
// few, and otherwise left off the shelf until it is given a name.
var esimAccessRegions = map[string]string{
	"AF": "أفريقيا", "AS": "آسيا", "AS-5": "آسيا الوسطى", "CA": "آسيا الوسطى",
	"AUNZ": "أستراليا ونيوزيلندا", "EU-7": "البلقان", "CB": "الكاريبي",
	"CN": "الصين وهونغ كونغ وماكاو", "CNHK": "الصين وهونغ كونغ",
	"CNJPKR": "الصين واليابان وكوريا الجنوبية", "EU": "أوروبا", "EU-43": "أوروبا والمغرب",
	"SAAEQAKWOMBH": "دول الخليج", "ME-6": "دول الخليج", "GL": "عالمي",
	"JPKR": "اليابان وكوريا الجنوبية", "ME": "الشرق الأوسط", "ME-12": "الشرق الأوسط وشمال أفريقيا",
	"NA": "أمريكا الشمالية", "OCE": "أوقيانوسيا", "SA": "أمريكا الجنوبية",
	"SAS": "جنوب آسيا", "SEA": "جنوب شرق آسيا", "USCA": "أمريكا وكندا",
}

// arabicCountries counts countries the way Arabic does: "3 دول", "33 دولة".
func arabicCountries(count int) string {
	if count%100 >= 3 && count%100 <= 10 {
		return fmt.Sprintf("%d دول", count)
	}
	return fmt.Sprintf("%d دولة", count)
}

// esimAccessRegionName is a region's Arabic name: its family and how many
// countries it covers ("أوروبا · 33 دولة"), since several regions of one family
// differ only in that.
func esimAccessRegionName(region string, codes []string) (string, bool) {
	family, _, _ := strings.Cut(region, "-")
	name := esimAccessRegions[region]
	if name == "" {
		name = esimAccessRegions[family]
	}
	if name != "" {
		if len(codes) > 3 {
			name += " · " + arabicCountries(len(codes))
		}
		return name, true
	}
	if len(codes) < 2 || len(codes) > 3 {
		return "", false
	}
	names := make([]string, 0, len(codes))
	for _, code := range codes {
		country := vouchers.CountryName(code)
		if country == "" {
			return "", false
		}
		names = append(names, country)
	}
	return strings.Join(names, " و"), true
}

func esimAccessSlug(text string) string {
	var slug strings.Builder
	dash := false
	for _, r := range strings.ToLower(strings.TrimSpace(text)) {
		switch {
		case (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9'):
			slug.WriteRune(r)
			dash = false
		case !dash && slug.Len() > 0:
			slug.WriteByte('-')
			dash = true
		}
	}
	return strings.Trim(slug.String(), "-")
}

func esimAccessImage(logo string) string {
	logo = strings.TrimSpace(logo)
	switch {
	case logo == "":
		return ""
	case strings.HasPrefix(logo, "http://"), strings.HasPrefix(logo, "https://"):
		return logo
	}
	return esimAccessImages + "/" + strings.TrimLeft(logo, "/")
}

// esimAccessNetworks is a country's networks as the shelf lists them.
func esimAccessNetworks(location esimaccess.Location) []string {
	networks := []string{}
	for _, operator := range location.Operators {
		name := strings.TrimSpace(operator.Name)
		if name != "" && !containsString(networks, name) {
			networks = append(networks, name)
		}
	}
	return networks
}

// esimAccessPlan shapes one package as a shelf plan; ok is false for one the
// shelf does not sell.
func esimAccessPlan(source esimaccess.Package, topUp bool) (esimPlan, bool) {
	megabytes, days, price := source.Megabytes(), source.Days(), int64(source.Price)
	currency := strings.ToUpper(strings.TrimSpace(source.Currency))
	switch {
	case source.Code == "" || price <= 0 || megabytes <= 0 || days <= 0:
		return esimPlan{}, false
	case currency != "" && currency != "USD":
		return esimPlan{}, false
	case int(source.DataType) != esimaccess.DataTotal && int(source.DataType) != 0:
		// Day passes are priced per day and topped up by the day: not sold yet.
		return esimPlan{}, false
	case !topUp && megabytes < esimAccessMinMB:
		return esimPlan{}, false
	}
	policy := "first-usage"
	if int(source.ActiveType) == esimaccess.ActiveOnInstall {
		policy = "installation"
	}
	operator := ""
	if len(source.Locations) == 1 {
		operator = strings.Join(esimAccessNetworks(source.Locations[0]), " · ")
	}
	return esimPlan{
		ID: esimAccessPlanPrefix + source.Code, Supplier: vouchers.SupplierESIMAccess, Ref: source.Code, CostUnits: price,
		Title: strings.TrimSpace(source.Name), Data: esimDataLabelMB(megabytes), AmountMB: megabytes, Days: days,
		NetUSD: float64(price) / esimaccess.Units, RetailUSD: float64(source.RetailPrice) / esimaccess.Units,
		Info:     strings.TrimSpace(source.Speed),
		Operator: operator, PlanType: "data",
		Rechargeable:      int(source.SupportTopUpType) == esimaccess.TopUpYes,
		ActivationPolicy:  policy,
		InstallWindowDays: int(source.UnusedValidTime),
	}, true
}

// shapeESIMAccessCatalog cuts eSIM Access's packages down to the shelf's
// destinations. The same amount for the same days is listed once, at its
// cheapest: the API sells it several times over (other networks, other exits).
func shapeESIMAccessCatalog(packages []esimaccess.Package) esimCatalog {
	byKey := map[string]*esimDestination{}
	countries := map[string]map[string]esimCountry{}
	for _, source := range packages {
		plan, ok := esimAccessPlan(source, false)
		codes := source.Codes()
		if !ok || len(codes) == 0 {
			continue
		}
		var key, name, kind, country string
		if len(codes) == 1 {
			country, kind = codes[0], esimKindLocal
			english := ""
			if len(source.Locations) > 0 {
				english = source.Locations[0].Name
			}
			// A country the tills have no Arabic name for is not sold here.
			name = vouchers.CountryName(country)
			key = firstNonEmpty(esimAccessSlug(english), strings.ToLower(country))
		} else {
			region, _, _ := strings.Cut(strings.TrimSpace(source.Slug), "_")
			named, known := esimAccessRegionName(region, esimAccessNamed(codes))
			if region == "" || !known {
				continue
			}
			name, kind, key = named, esimKindRegional, "ea-"+strings.ToLower(region)
			if strings.HasPrefix(region, "GL") {
				kind = esimKindGlobal
			}
		}
		if key == "" || name == "" {
			continue
		}
		destination := byKey[key]
		if destination == nil {
			destination = &esimDestination{Key: key, Kind: kind, Country: country, Name: name, Plans: []esimPlan{}}
			byKey[key], countries[key] = destination, map[string]esimCountry{}
		}
		for _, location := range source.Locations {
			code := strings.ToUpper(strings.TrimSpace(location.Code))
			if code == "" && len(codes) == 1 {
				code = codes[0]
			}
			if code == "" || vouchers.CountryName(code) == "" {
				continue
			}
			if destination.Image == "" && kind == esimKindLocal {
				destination.Image = esimAccessImage(location.Logo)
			}
			entry := countries[key][code]
			entry.Code, entry.Name = code, vouchers.CountryName(code)
			for _, network := range esimAccessNetworks(location) {
				if !containsString(entry.Networks, network) {
					entry.Networks = append(entry.Networks, network)
				}
			}
			countries[key][code] = entry
		}
		for _, code := range esimAccessNamed(codes) {
			if _, listed := countries[key][code]; !listed {
				countries[key][code] = esimCountry{Code: code, Name: vouchers.CountryName(code)}
			}
		}
		destination.Plans = append(destination.Plans, plan)
	}
	catalog := esimCatalog{Destinations: make([]esimDestination, 0, len(byKey))}
	// Two regions that read the same on the shelf (eSIM Access sells the Gulf
	// twice over): the one that starts cheaper is listed.
	keys := make([]string, 0, len(byKey))
	for key := range byKey {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	named := map[string]string{}
	for _, key := range keys {
		destination := byKey[key]
		if destination.Kind == esimKindLocal {
			continue
		}
		if other, taken := named[destination.Name]; taken {
			if cheapestESIMNet(destination.Plans) < cheapestESIMNet(byKey[other].Plans) {
				delete(byKey, other)
				named[destination.Name] = key
			} else {
				delete(byKey, key)
			}
			continue
		}
		named[destination.Name] = key
	}
	for key, destination := range byKey {
		destination.Plans = cheapestESIMPlans(destination.Plans)
		sortESIMPlans(destination.Plans)
		for _, country := range countries[key] {
			destination.Countries = append(destination.Countries, country)
		}
		sort.Slice(destination.Countries, func(i, j int) bool { return destination.Countries[i].Code < destination.Countries[j].Code })
		catalog.Destinations = append(catalog.Destinations, *destination)
	}
	sort.SliceStable(catalog.Destinations, func(i, j int) bool { return catalog.Destinations[i].Key < catalog.Destinations[j].Key })
	return catalog
}

// esimAccessNamed is the countries the tills have an Arabic name for.
func esimAccessNamed(codes []string) []string {
	named := make([]string, 0, len(codes))
	for _, code := range codes {
		if vouchers.CountryName(code) != "" {
			named = append(named, code)
		}
	}
	return named
}

func cheapestESIMNet(plans []esimPlan) float64 {
	cheapest := 0.0
	for i, plan := range plans {
		if i == 0 || plan.NetUSD < cheapest {
			cheapest = plan.NetUSD
		}
	}
	return cheapest
}

// esimPlanSize is what makes two plans the same offer to a customer.
type esimPlanSize struct {
	megabytes, days int
	unlimited       bool
	calls           bool
}

func sizeOfESIMPlan(plan esimPlan) esimPlanSize {
	return esimPlanSize{megabytes: plan.AmountMB, days: plan.Days, unlimited: plan.Unlimited, calls: plan.Voice > 0 || plan.Text > 0}
}

// cheapestESIMPlans keeps, of the plans of one size, the one that costs least.
func cheapestESIMPlans(plans []esimPlan) []esimPlan {
	best := map[esimPlanSize]int{}
	kept := make([]esimPlan, 0, len(plans))
	for _, plan := range plans {
		size := sizeOfESIMPlan(plan)
		if at, seen := best[size]; seen {
			if plan.NetUSD < kept[at].NetUSD {
				kept[at] = plan
			}
			continue
		}
		best[size] = len(kept)
		kept = append(kept, plan)
	}
	return kept
}

func sortESIMPlans(plans []esimPlan) {
	sort.SliceStable(plans, func(i, j int) bool {
		a, b := plans[i], plans[j]
		if a.Unlimited != b.Unlimited {
			return b.Unlimited
		}
		if a.AmountMB != b.AmountMB {
			return a.AmountMB < b.AmountMB
		}
		return a.Days < b.Days
	})
}

// only is the catalog's plans of one supplier: what is kept of a supplier whose
// catalog could not be read this time.
func (c *esimCatalog) only(supplier string) esimCatalog {
	part := esimCatalog{Destinations: []esimDestination{}}
	if c == nil {
		return part
	}
	for _, destination := range c.Destinations {
		plans := []esimPlan{}
		for _, plan := range destination.Plans {
			if planSupplier(plan) == supplier {
				plans = append(plans, plan)
			}
		}
		if len(plans) == 0 {
			continue
		}
		destination.Plans = plans
		part.Destinations = append(part.Destinations, destination)
	}
	return part
}

// mergeESIMCatalogs lays a second supplier's catalog over the first's. A
// country both sell is one destination, under the first's key and name, and a
// plan both sell in the same size is listed once, from whoever charges the
// company less. Regions are never merged: two suppliers' "Europe" cover
// different countries.
func mergeESIMCatalogs(first, second esimCatalog) esimCatalog {
	merged := esimCatalog{Destinations: make([]esimDestination, 0, len(first.Destinations)+len(second.Destinations))}
	byCountry, keys := map[string]int{}, map[string]bool{}
	for _, destination := range first.Destinations {
		if destination.Kind == esimKindLocal && destination.Country != "" {
			byCountry[destination.Country] = len(merged.Destinations)
		}
		keys[destination.Key] = true
		merged.Destinations = append(merged.Destinations, destination)
	}
	for _, destination := range second.Destinations {
		at, shared := byCountry[destination.Country]
		if destination.Kind != esimKindLocal || destination.Country == "" || !shared {
			if keys[destination.Key] {
				destination.Key = "ea-" + destination.Key
			}
			keys[destination.Key] = true
			merged.Destinations = append(merged.Destinations, destination)
			continue
		}
		target := merged.Destinations[at]
		plans := append(append([]esimPlan{}, target.Plans...), destination.Plans...)
		target.Plans = cheapestAcrossSuppliers(plans)
		sortESIMPlans(target.Plans)
		for _, country := range destination.Countries {
			found := false
			for i := range target.Countries {
				if target.Countries[i].Code != country.Code {
					continue
				}
				found = true
				for _, network := range country.Networks {
					if !containsString(target.Countries[i].Networks, network) {
						target.Countries[i].Networks = append(target.Countries[i].Networks, network)
					}
				}
			}
			if !found {
				target.Countries = append(target.Countries, country)
			}
		}
		merged.Destinations[at] = target
	}
	sort.SliceStable(merged.Destinations, func(i, j int) bool { return merged.Destinations[i].Key < merged.Destinations[j].Key })
	return merged
}

// cheapestAcrossSuppliers drops a plan another supplier sells in the same size
// for less. Plans of one supplier are left as that supplier listed them.
func cheapestAcrossSuppliers(plans []esimPlan) []esimPlan {
	kept := make([]esimPlan, 0, len(plans))
	for i, plan := range plans {
		beaten := false
		for j, other := range plans {
			if i == j || planSupplier(other) == planSupplier(plan) || sizeOfESIMPlan(other) != sizeOfESIMPlan(plan) {
				continue
			}
			if other.NetUSD < plan.NetUSD || (other.NetUSD == plan.NetUSD && j < i) {
				beaten = true
				break
			}
		}
		if !beaten {
			kept = append(kept, plan)
		}
	}
	return kept
}

// --- usage, install, top-ups -----------------------------------------------

// esimAccessUsage reads an eSIM's usage in the shelf's words. An eSIM the
// account no longer holds under that number (cancelled, or its ICCID issued
// again) has ended.
func (s HTTPServer) esimAccessUsage(ctx context.Context, esim control.CustomerESIM) (control.CustomerESIMUsage, error) {
	if s.ESIM.Access == nil {
		return control.CustomerESIMUsage{}, errors.New("eSIM Access is not configured")
	}
	profile, err := s.ESIM.Access.Profile(ctx, esim.SupplierRef, esimAccessICCID(esim))
	if errors.Is(err, esimaccess.ErrNoProfile) {
		return control.CustomerESIMUsage{Status: airalo.UsageExpired}, nil
	}
	if err != nil {
		return control.CustomerESIMUsage{}, err
	}
	return esimAccessReading(profile, esim.Unlimited), nil
}

// esimAccessICCID is the ICCID to ask eSIM Access by: none for a row whose
// ICCID went to a newer eSIM.
func esimAccessICCID(esim control.CustomerESIM) string {
	if strings.Contains(esim.ICCID, "~") {
		return ""
	}
	return esim.ICCID
}

func esimAccessReading(profile esimaccess.Profile, unlimited bool) control.CustomerESIMUsage {
	const megabyte = int64(1) << 20
	total, used := int64(profile.TotalVolume), int64(profile.OrderUsage)
	remaining := total - used
	if remaining < 0 {
		remaining = 0
	}
	reading := control.CustomerESIMUsage{TotalMB: int(total / megabyte), RemainingMB: int(remaining / megabyte)}
	status := strings.ToUpper(strings.TrimSpace(profile.Status))
	switch {
	case profile.Ended():
		reading.Status = airalo.UsageExpired
	case status == esimaccess.StatusUsedUp:
		reading.Status, reading.RemainingMB = airalo.UsageFinished, 0
	case status == esimaccess.StatusInUse:
		reading.Status = airalo.UsageActive
	case status == esimaccess.StatusGotResource:
		reading.Status = airalo.UsageNotActive
	default:
		reading.Status = airalo.UsageUnknown
	}
	// Before the plan starts, "expiredTime" is only the last day to install it.
	if reading.Status == airalo.UsageActive || reading.Status == airalo.UsageFinished {
		reading.ExpiresAt = esimaccess.ParseTime(profile.ExpiredTime)
	}
	if unlimited {
		reading.RemainingMB, reading.TotalMB = 0, 0
	}
	return reading
}

// esimAccessInstall is everything that installs an eSIM Access eSIM, read from
// the API each time like Airalo's.
func (s HTTPServer) esimAccessInstall(ctx context.Context, esim control.CustomerESIM) (map[string]any, error) {
	if s.ESIM.Access == nil {
		return nil, errors.New("eSIM Access is not configured")
	}
	profile, err := s.ESIM.Access.Profile(ctx, esim.SupplierRef, esimAccessICCID(esim))
	if err != nil {
		return nil, err
	}
	address, matchingID := profile.SMDP()
	if address == "" {
		return nil, errors.New("the eSIM has no activation code")
	}
	install := map[string]any{
		"qr": profile.AC, "smdp": address, "activation_code": matchingID,
		"apple_url":   "https://esimsetup.apple.com/esim_qrcode_provisioning?carddata=" + profile.AC,
		"android_url": "https://esimsetup.android.com/esim_qrcode_provisioning?carddata=" + profile.AC,
		// A travel eSIM works on its partner networks: data roaming must be on.
		"roaming":  true,
		"recycled": profile.Ended(),
	}
	apnType, apn := "automatic", strings.TrimSpace(profile.APN)
	if apn != "" {
		apnType = "manual"
		install["apn_value"], install["android_apn_value"], install["ios_apn_value"] = apn, apn, apn
	}
	install["apn_type"], install["android_apn_type"], install["ios_apn_type"] = apnType, apnType, apnType
	// The page to hand someone else: eSIM Access's own, with the QR and no code.
	if link := strings.TrimSpace(profile.ShortURL); strings.HasPrefix(link, "https://") {
		install["share_link"] = link
	}
	return install, nil
}

// esimAccessTopUps is what an eSIM Access eSIM can be topped up with.
func (s HTTPServer) esimAccessTopUps(ctx context.Context, esim control.CustomerESIM) ([]esimPlan, error) {
	if s.ESIM.Access == nil {
		return nil, errors.New("eSIM Access is not configured")
	}
	packages, err := s.ESIM.Access.TopUps(ctx, esim.SupplierRef, esimAccessICCID(esim))
	if err != nil {
		return nil, err
	}
	plans := make([]esimPlan, 0, len(packages))
	for _, source := range packages {
		if plan, ok := esimAccessPlan(source, true); ok {
			plans = append(plans, plan)
		}
	}
	plans = cheapestESIMPlans(plans)
	sortESIMPlans(plans)
	return plans, nil
}

// --- eSIM Access's account: its webhook and its balance ---------------------

// ensureESIMAccessWebhook points eSIM Access's events at this relay.
func (s HTTPServer) ensureESIMAccessWebhook(ctx context.Context) {
	address := s.ESIM.accessWebhookAddress()
	if s.ESIM.Access == nil || address == "" {
		return
	}
	current, err := s.ESIM.Access.Webhook(ctx)
	if err == nil && current == address {
		return
	}
	if err := s.ESIM.Access.SetWebhook(ctx, address); err != nil {
		s.logger().Error("setting eSIM Access's webhook failed", "error", err)
		return
	}
	s.logger().Info("eSIM Access's webhook is set")
}

// watchESIMAccessBalance tells the operator when the prepaid balance runs low:
// without it every eSIM order fails.
func (s HTTPServer) watchESIMAccessBalance(ctx context.Context) {
	if s.ESIM.Access == nil {
		return
	}
	balance, err := s.ESIM.Access.Balance(ctx)
	if err != nil {
		s.logger().Warn("reading eSIM Access's balance failed", "error", err)
		return
	}
	s.logger().Info("eSIM Access balance", "usd", esimaccess.Dollars(balance))
	state := s.ESIM.state
	if state == nil || s.ESIM.AccessLowBalance <= 0 || balance >= s.ESIM.AccessLowBalance {
		return
	}
	now := s.clock().Now()
	state.mu.Lock()
	told := now.Sub(state.balanceToldAt) < esimAccessBalanceEvery
	if !told {
		state.balanceToldAt = now
	}
	state.mu.Unlock()
	if told || s.Alerts == nil {
		return
	}
	s.Alerts.Send(alerts.Message{
		Title:    "رصيد eSIM Access منخفض: " + esimaccess.Dollars(balance) + " USD",
		Body:     "Top the account up before eSIM orders start failing.",
		Priority: alerts.PriorityUrgent,
		Tags:     []string{"warning"},
	})
}

// handleESIMAccessWebhook takes eSIM Access's events. Every delivery with the
// right token is acknowledged: a failure here must not make eSIM Access drop
// the address.
func (s HTTPServer) handleESIMAccessWebhook(w http.ResponseWriter, r *http.Request, token string) {
	want := s.ESIM.AccessWebhookToken
	if s.ESIM.Access == nil || want == "" || subtle.ConstantTimeCompare([]byte(token), []byte(want)) != 1 {
		writeNotFound(w)
		return
	}
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusOK)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxESIMAccessWebhookLen))
	if err != nil {
		writeCustomerError(w, http.StatusRequestEntityTooLarge, "invalid_request", "the delivery is too large", nil)
		return
	}
	event, ok := esimaccess.DecodeEvent(body)
	if ok && event.AboutUsage() {
		ctx := context.WithoutCancel(r.Context())
		if err := s.tellESIMAccessUsage(ctx, event); err != nil {
			s.logger().Error("handling an eSIM Access event failed", "type", event.Type,
				"iccid_tail", iccidTail(event.Content.ICCID), "error", err)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "processed"})
}

// tellESIMAccessUsage reads the eSIM an event names and tells its buyer what
// the reading says, once per level. An eSIM this relay did not sell, or one
// whose ICCID now belongs to another, is no error.
func (s HTTPServer) tellESIMAccessUsage(ctx context.Context, event esimaccess.Event) error {
	store, ok := s.Store.(control.CustomerESIMStore)
	if !ok || event.Content.ICCID == "" {
		return nil
	}
	esim, err := store.GetCustomerESIM(ctx, event.Content.ICCID)
	if errors.Is(err, control.ErrCustomerESIMNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if esimSupplierOf(esim) != vouchers.SupplierESIMAccess ||
		(esim.SupplierRef != "" && event.Content.TranNo != "" && esim.SupplierRef != event.Content.TranNo) {
		return nil
	}
	callCtx, cancel := context.WithTimeout(ctx, esimReadBudget)
	defer cancel()
	usage, err := s.esimAccessUsage(callCtx, esim)
	if err != nil {
		return err
	}
	if err := store.UpdateCustomerESIMUsage(ctx, esim.ICCID, usage); err != nil {
		return err
	}
	// The package's size names the package: a top-up changes it, and the same
	// levels are told again for the new one.
	packageName := fmt.Sprintf("%d MB", usage.TotalMB)
	for _, level := range esimUsageLevels(usage, s.clock().Now()) {
		told, err := s.tellESIMLevel(ctx, store, esim, level, packageName)
		if err != nil {
			return err
		}
		if told {
			// One push at a time: the most pressing level that is new.
			break
		}
	}
	return nil
}

// esimUsageLevels is the alert levels a reading has reached, the most pressing
// first.
func esimUsageLevels(usage control.CustomerESIMUsage, now time.Time) []string {
	levels := []string{}
	switch usage.Status {
	case airalo.UsageFinished:
		return []string{esimLevelUsedUp}
	case airalo.UsageActive:
	default:
		return levels
	}
	if usage.ExpiresAt != nil {
		switch left := usage.ExpiresAt.Sub(now); {
		case left <= 0:
		case left <= 24*time.Hour:
			levels = append(levels, airalo.Level1Day)
		case left <= 72*time.Hour:
			levels = append(levels, airalo.Level3Days)
		}
	}
	if usage.TotalMB > 0 {
		switch used := usage.TotalMB - usage.RemainingMB; {
		case used*10 >= usage.TotalMB*9:
			levels = append(levels, airalo.Level90)
		case used*4 >= usage.TotalMB*3:
			levels = append(levels, airalo.Level75)
		}
	}
	return levels
}
