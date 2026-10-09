package relay

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"pointy/relay/internal/bnplus"
	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// The operator's side of the card shop (admin token):
//
//	GET  /v1/vouchers/admin/config
//	GET  /v1/vouchers/admin/catalog               current document, what shops see, supply per item
//	PUT  /v1/vouchers/admin/catalog               publish {document, actor, note}
//	GET  /v1/vouchers/admin/catalogs              history
//	GET  /v1/vouchers/admin/settings              pricing settings of top-up and bills (vouchers_settings.go)
//	PUT  /v1/vouchers/admin/settings              publish them: the fields, plus note and actor
//	GET  /v1/vouchers/admin/settings/history      versions, newest first
//	POST /v1/vouchers/admin/images                upload one PNG/JPEG/WebP (raw body)
//	GET  /v1/vouchers/admin/images/{sha256}       read one back (the operator console shows them)
//	GET  /v1/vouchers/admin/offers?supplier=      what suppliers sell the company
//	POST /v1/vouchers/admin/offers/sync           read them now
//	GET  /v1/vouchers/admin/purchases?installation_id=&status=&kind=card|airtime|bill&held=1&limit=
//	POST /v1/vouchers/admin/purchases/{id}/check  ask the supplier now
//	POST /v1/vouchers/admin/purchases/{id}/resolve {outcome: refund|found, supplier_order_id, reason, actor}
//	GET  /v1/vouchers/admin/bnplus/{wallets|groups|companies|cards|orders|order}
//	GET  /v1/vouchers/admin/reloadly/balance      the company's gift card balance at Reloadly (USD)

const (
	maxVoucherCatalogBytes = 4 << 20
	maxVoucherImageBytes   = 2 << 20
	maxVoucherImageSide    = 2048
)

func (s HTTPServer) handleVoucherAdminRoutes(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/v1/vouchers/admin")
	store, ok := s.voucherStore()
	if !ok {
		writeSMSError(w, http.StatusNotImplemented, voucherCodeUnavailable, "vouchers are not supported by this relay's store", nil)
		return
	}
	switch {
	case path == "/config" && r.Method == http.MethodGet:
		s.handleVoucherAdminConfig(w, r, store)
	case path == "/catalog" && r.Method == http.MethodGet:
		s.handleVoucherAdminCatalog(w, r, store)
	case path == "/catalog" && r.Method == http.MethodPut:
		s.handleVoucherAdminPublish(w, r, store)
	case path == "/catalogs" && r.Method == http.MethodGet:
		s.handleVoucherAdminHistory(w, r, store)
	case path == "/settings" && r.Method == http.MethodGet:
		s.handleVoucherAdminSettings(w, r, store)
	case path == "/settings" && r.Method == http.MethodPut:
		s.handleVoucherAdminSettingsPublish(w, r, store)
	case path == "/settings/history" && r.Method == http.MethodGet:
		s.handleVoucherAdminSettingsHistory(w, r, store)
	case path == "/images" && r.Method == http.MethodPost:
		s.handleVoucherAdminImage(w, r, store)
	case strings.HasPrefix(path, "/images/") && r.Method == http.MethodGet:
		s.writeVoucherImage(w, r, store, strings.TrimPrefix(path, "/images/"))
	case path == "/offers" && r.Method == http.MethodGet:
		s.handleVoucherAdminOffers(w, r, store)
	case path == "/offers/sync" && r.Method == http.MethodPost:
		s.handleVoucherAdminOfferSync(w, r, store)
	case path == "/purchases" && r.Method == http.MethodGet:
		s.handleVoucherAdminPurchases(w, r, store)
	case strings.HasPrefix(path, "/purchases/") && r.Method == http.MethodPost:
		id, action, _ := strings.Cut(strings.Trim(strings.TrimPrefix(path, "/purchases/"), "/"), "/")
		switch action {
		case "check":
			s.handleVoucherAdminCheck(w, r, store, id)
		case "resolve":
			s.handleVoucherAdminResolve(w, r, store, id)
		default:
			writeNotFound(w)
		}
	case strings.HasPrefix(path, "/bnplus/") && r.Method == http.MethodGet:
		s.handleVoucherAdminBNPlus(w, r, strings.TrimPrefix(path, "/bnplus/"))
	case strings.HasPrefix(path, "/reloadly/") && r.Method == http.MethodGet:
		s.handleVoucherAdminReloadly(w, r, strings.TrimPrefix(path, "/reloadly/"))
	default:
		writeNotFound(w)
	}
}

func (s HTTPServer) handleVoucherAdminConfig(w http.ResponseWriter, _ *http.Request, _ control.VoucherStore) {
	suppliers := make([]string, 0, len(s.Vouchers.Suppliers))
	for key := range s.Vouchers.Suppliers {
		suppliers = append(suppliers, key)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"configured":       s.Vouchers.Configured(),
		"test_mode":        s.Vouchers.TestMode,
		"sandbox":          s.Vouchers.SandboxMode(),
		"suppliers":        suppliers,
		"catalog_accepts":  vouchers.SupplierKeys(),
		"bnplus":           s.Vouchers.BNPlus != nil,
		"reloadly":         s.Vouchers.Reloadly != nil,
		"reloadly_sandbox": s.Vouchers.Reloadly != nil && s.Vouchers.Reloadly.Sandbox(),
		"rate_limit":       s.Vouchers.RateLimit.String(),
		"request_timeout":  s.Vouchers.requestTimeout().String(),
		"sync_interval":    s.Vouchers.SyncInterval.String(),
		"offers_max_age":   s.Vouchers.offersMaxAge().String(),
		"promotion_grace":  vouchers.PromotionGrace.String(),
		"stale_after":      s.Vouchers.staleAfter().String(),
		"absent_after":     voucherAbsentAfter.String(),
		"operator_after":   voucherOperatorAfter.String(),
		"price_decimals":   2,
		"currency":         vouchers.Currency,
		"max_quantity":     maxVoucherQuantity,
		"max_image_bytes":  maxVoucherImageBytes,
		"max_catalog_size": maxVoucherCatalogBytes,
	})
}

// voucherItemSupply is what the operator sees beside each item: whom it is
// bought from, what each supplier charges for it now, and whether it sells.
// Supplier, Ref, MaxCost and Offer describe the first supplier the item lists
// (the only one, for most items); Suppliers has them all, with what each costs
// the company in dinars and who is bought from first.
type voucherItemSupply struct {
	Item      string                `json:"item"`
	Brand     string                `json:"brand"`
	Name      string                `json:"name"`
	Supplier  string                `json:"supplier"`
	Ref       string                `json:"ref"`
	MaxCost   string                `json:"max_cost,omitempty"`
	Offer     *control.VoucherOffer `json:"offer"`
	Available bool                  `json:"available"`
	Reason    string                `json:"reason,omitempty"`
	// Winner is the supplier a purchase made now is placed with first; empty
	// when none can sell the card.
	Winner    string                  `json:"winner,omitempty"`
	Suppliers []voucherSupplierSupply `json:"suppliers"`
}

// voucherSupplierSupply is one supplier of an item as the relay judges it now.
type voucherSupplierSupply struct {
	Supplier string                `json:"supplier"`
	Ref      string                `json:"ref"`
	MaxCost  string                `json:"max_cost,omitempty"`
	Offer    *control.VoucherOffer `json:"offer"`
	// CostLYD is the card's price in dinars at the stored settings (four
	// decimals), empty when it cannot be told.
	CostLYD string `json:"cost_lyd,omitempty"`
	// Candidate says a purchase could be placed with this supplier now; Rank
	// is its place in the order they are tried (1 first), 0 for a non-candidate.
	Candidate bool   `json:"candidate"`
	Rank      int    `json:"rank,omitempty"`
	Reason    string `json:"reason,omitempty"`
	// Note is a caveat on a supplier that can still sell: its price and stock are
	// unknown (its offers were never read, or were read too long ago).
	Note string `json:"note,omitempty"`
}

func (s HTTPServer) handleVoucherAdminCatalog(w http.ResponseWriter, r *http.Request, store control.VoucherStore) {
	ctx := r.Context()
	loaded, err := s.currentVoucherCatalog(ctx, store)
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher catalog read failed", err)
		return
	}
	if loaded.empty {
		writeJSON(w, http.StatusOK, map[string]any{"catalog": nil, "view": nil, "supply": []voucherItemSupply{}})
		return
	}
	offers, err := s.loadVoucherOffers(ctx, store)
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher offers read failed", err)
		return
	}
	settings, err := s.voucherSettingsForCards(ctx, store)
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher settings read failed", err)
		return
	}
	view := vouchers.Shop(s.autoPricedDocument(loaded.document, offers, settings), loaded.record.SHA256, s.clock().Now(), s.Vouchers.MarksTest(), s.voucherAvailability(offers, settings))
	supply := []voucherItemSupply{}
	for _, brand := range loaded.document.Brands {
		for _, item := range brand.Items {
			located, ok := vouchers.Find(loaded.document, item.Key)
			if !ok {
				continue
			}
			ranking := s.Vouchers.rankSuppliers(located, offers, settings)
			entry := voucherItemSupply{
				Item:      item.Key,
				Brand:     brand.Key,
				Name:      located.Name(),
				Supplier:  located.Ref.Supplier,
				Ref:       located.Ref.ID,
				MaxCost:   located.Ref.MaxCost,
				Suppliers: ranking.supplies(offers),
			}
			if offer, known := offers.offer(located.Ref); known {
				entry.Offer = &offer
			}
			entry.Reason, _ = ranking.unavailable()
			entry.Available = entry.Reason == ""
			if len(ranking.Candidates) > 0 {
				entry.Winner = ranking.Candidates[0].Ref.Supplier
			}
			supply = append(supply, entry)
		}
	}
	record := loaded.record
	if full, err := store.CurrentVoucherCatalog(ctx); err == nil {
		record = full
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"catalog": record,
		"view":    view,
		"supply":  supply,
	})
}

type voucherPublishRequest struct {
	Document json.RawMessage `json:"document"`
	Actor    string          `json:"actor"`
	Note     string          `json:"note"`
}

// handleVoucherAdminPublish serves PUT /v1/vouchers/admin/catalog: validate a
// document, normalize it, and make it current. A document identical to the
// current one is not published again.
func (s HTTPServer) handleVoucherAdminPublish(w http.ResponseWriter, r *http.Request, store control.VoucherStore) {
	var request voucherPublishRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxVoucherCatalogBytes)).Decode(&request); err != nil {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "invalid request body", nil)
		return
	}
	document, err := vouchers.ParseDocument(request.Document)
	if err != nil {
		writeSMSError(w, http.StatusUnprocessableEntity, voucherCodeInvalidRequest, err.Error(), nil)
		return
	}
	ctx := r.Context()
	refs := vouchers.Images(document)
	sums := make([]string, 0, len(refs))
	for _, ref := range refs {
		sums = append(sums, strings.TrimPrefix(ref, vouchers.ImagePrefix))
	}
	missing, err := store.MissingVoucherImages(ctx, sums)
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher image check failed", err)
		return
	}
	absent := map[string]bool{}
	for _, sum := range missing {
		absent[vouchers.ImagePrefix+sum] = true
	}
	problems := vouchers.Validate(document, vouchers.ValidateOptions{
		KnownImage: func(ref string) bool { return !absent[ref] },
	})
	if len(problems) > 0 {
		writeSMSError(w, http.StatusUnprocessableEntity, "invalid_catalog", problems.Error(), map[string]any{"problems": problems})
		return
	}
	normalized := vouchers.Normalize(document)
	raw, sum, err := vouchers.Encode(normalized)
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher catalog encoding failed", err)
		return
	}
	summary := voucherCatalogSummary(normalized)
	if head, err := store.VoucherCatalogHead(ctx); err == nil && head.SHA256 == sum {
		writeJSON(w, http.StatusOK, map[string]any{"catalog": head, "unchanged": true, "summary": summary})
		return
	}
	published, err := store.PublishVoucherCatalog(ctx, control.VoucherCatalog{
		SHA256:   sum,
		Document: raw,
		Actor:    request.Actor,
		Note:     request.Note,
	})
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher catalog publish failed", err)
		return
	}
	if s.VoucherCache != nil {
		s.VoucherCache.mu.Lock()
		s.VoucherCache.checked = time.Time{}
		s.VoucherCache.mu.Unlock()
	}
	s.logger().Info("voucher catalog published",
		"catalog_id", published.ID, "sha256", published.SHA256, "actor", published.Actor,
		"brands", summary["brands"], "items", summary["items"])
	published.Document = nil
	writeJSON(w, http.StatusCreated, map[string]any{"catalog": published, "unchanged": false, "summary": summary})
}

func voucherCatalogSummary(document vouchers.Document) map[string]int {
	items := 0
	for _, brand := range document.Brands {
		items += len(brand.Items)
	}
	return map[string]int{
		"categories": len(document.Categories),
		"countries":  len(document.Countries),
		"brands":     len(document.Brands),
		"items":      items,
	}
}

func (s HTTPServer) handleVoucherAdminHistory(w http.ResponseWriter, r *http.Request, store control.VoucherStore) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	catalogs, err := store.ListVoucherCatalogs(r.Context(), limit)
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher catalog history failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"catalogs": catalogs})
}

// handleVoucherAdminImage serves POST /v1/vouchers/admin/images: the raw
// bytes of one PNG, JPEG or WebP, stored under their SHA-256.
func (s HTTPServer) handleVoucherAdminImage(w http.ResponseWriter, r *http.Request, store control.VoucherStore) {
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxVoucherImageBytes))
	if err != nil {
		writeSMSError(w, http.StatusRequestEntityTooLarge, voucherCodeInvalidRequest, "an image is at most 2 MB", nil)
		return
	}
	if len(data) == 0 {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "the image is empty", nil)
		return
	}
	contentType := http.DetectContentType(data)
	width, height := 0, 0
	switch contentType {
	case "image/png", "image/jpeg":
		config, _, err := image.DecodeConfig(bytes.NewReader(data))
		if err != nil {
			writeSMSError(w, http.StatusUnprocessableEntity, voucherCodeInvalidRequest, "the image does not decode: "+err.Error(), nil)
			return
		}
		width, height = config.Width, config.Height
		if width > maxVoucherImageSide || height > maxVoucherImageSide {
			writeSMSError(w, http.StatusUnprocessableEntity, voucherCodeInvalidRequest, "an image is at most 2048 px on a side", nil)
			return
		}
	case "image/webp":
	default:
		writeSMSError(w, http.StatusUnsupportedMediaType, voucherCodeInvalidRequest,
			"only PNG, JPEG and WebP images are accepted, got "+contentType, nil)
		return
	}
	digest := sha256.Sum256(data)
	stored, created, err := store.PutVoucherImage(r.Context(), control.VoucherImage{
		SHA256:      hex.EncodeToString(digest[:]),
		ContentType: contentType,
		Data:        data,
		Width:       width,
		Height:      height,
	})
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher image upload failed", err)
		return
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	writeJSON(w, status, map[string]any{
		"ref":          vouchers.ImagePrefix + stored.SHA256,
		"sha256":       stored.SHA256,
		"content_type": stored.ContentType,
		"width":        stored.Width,
		"height":       stored.Height,
		"bytes":        len(data),
		"created":      created,
	})
}

// voucherAdminOffer is an offer with what it costs the company in dinars at the
// stored settings, so the suppliers read side by side.
type voucherAdminOffer struct {
	control.VoucherOffer
	CostLYD string `json:"cost_lyd,omitempty"`
}

func (s HTTPServer) handleVoucherAdminOffers(w http.ResponseWriter, r *http.Request, store control.VoucherStore) {
	offers, err := store.ListVoucherOffers(r.Context(), strings.TrimSpace(r.URL.Query().Get("supplier")))
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher offers read failed", err)
		return
	}
	settings, err := s.voucherSettingsForCards(r.Context(), store)
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher settings read failed", err)
		return
	}
	rows := make([]voucherAdminOffer, 0, len(offers))
	for _, offer := range offers {
		row := voucherAdminOffer{VoucherOffer: offer}
		if cost, _ := offerCostLYD(offer, settings); cost != nil {
			row.CostLYD = cost.FloatString(4)
		}
		rows = append(rows, row)
	}
	writeJSON(w, http.StatusOK, map[string]any{"offers": rows})
}

func (s HTTPServer) handleVoucherAdminOfferSync(w http.ResponseWriter, r *http.Request, store control.VoucherStore) {
	result := syncVoucherOffers(r.Context(), s.Vouchers, store, s.logger())
	if err := result.err(); err != nil {
		writeSMSError(w, http.StatusBadGateway, "supplier_unreachable", err.Error(), map[string]any{"synced": result.Counts})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"synced": result.Counts})
}

func (s HTTPServer) handleVoucherAdminPurchases(w http.ResponseWriter, r *http.Request, store control.VoucherStore) {
	query := r.URL.Query()
	status := strings.TrimSpace(query.Get("status"))
	if status != "" && !control.ValidVoucherPurchaseStatus(status) {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "status must be pending, succeeded or failed", nil)
		return
	}
	kind := strings.TrimSpace(query.Get("kind"))
	if kind != "" && !control.ValidVoucherKind(kind) {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "kind must be card, airtime or bill", nil)
		return
	}
	limit, _ := strconv.Atoi(query.Get("limit"))
	held := query.Get("held") == "1" || strings.EqualFold(query.Get("held"), "true")
	purchases, err := store.ListVoucherPurchases(r.Context(), control.VoucherPurchaseFilter{
		InstallationID: strings.TrimSpace(query.Get("installation_id")),
		Status:         status,
		Kind:           kind,
		HeldOnly:       held,
		Limit:          limit,
	})
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher purchase listing failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"purchases": purchases})
}

func (s HTTPServer) handleVoucherAdminCheck(w http.ResponseWriter, r *http.Request, store control.VoucherStore, id string) {
	purchase, err := store.GetVoucherPurchase(r.Context(), id)
	if errors.Is(err, control.ErrVoucherPurchaseNotFound) {
		writeSMSError(w, http.StatusNotFound, voucherCodeNotFound, "no such purchase", nil)
		return
	}
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher purchase read failed", err)
		return
	}
	checked, verdict, checkErr := s.checkVoucherPurchase(context.WithoutCancel(r.Context()), store, purchase)
	body := map[string]any{"purchase": checked, "verdict": verdict}
	if checkErr != nil {
		body["error"] = checkErr.Error()
	}
	writeJSON(w, http.StatusOK, body)
}

type voucherResolveRequest struct {
	Outcome         string `json:"outcome"`
	SupplierOrderID string `json:"supplier_order_id"`
	Reason          string `json:"reason"`
	Actor           string `json:"actor"`
}

// handleVoucherAdminResolve serves POST /v1/vouchers/admin/purchases/{id}/resolve:
// the operator settles a purchase the reconciler could not — refunding it,
// or naming the supplier order its cards came from.
func (s HTTPServer) handleVoucherAdminResolve(w http.ResponseWriter, r *http.Request, store control.VoucherStore, id string) {
	var request voucherResolveRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxVoucherRequestBytes)).Decode(&request); err != nil {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "invalid request body", nil)
		return
	}
	request.Reason = strings.TrimSpace(request.Reason)
	if request.Reason == "" {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "reason is required", nil)
		return
	}
	resolution := control.VoucherPurchaseResolution{
		Detail: "operator " + strings.TrimSpace(request.Actor) + ": " + request.Reason,
	}
	switch strings.ToLower(strings.TrimSpace(request.Outcome)) {
	case "refund":
		resolution.Found = false
	case "found":
		resolution.Found = true
		resolution.SupplierOrderID = strings.TrimSpace(request.SupplierOrderID)
		if resolution.SupplierOrderID == "" {
			writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "found needs supplier_order_id", nil)
			return
		}
	default:
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "outcome must be refund or found", nil)
		return
	}
	resolved, applied, err := store.ResolveVoucherPurchase(r.Context(), strings.TrimSpace(id), resolution)
	switch {
	case errors.Is(err, control.ErrVoucherPurchaseNotFound):
		writeSMSError(w, http.StatusNotFound, voucherCodeNotFound, "no such purchase", nil)
		return
	case errors.Is(err, control.ErrVoucherOrderClaimed):
		writeSMSError(w, http.StatusConflict, "order_claimed", "that supplier order already settles another purchase", nil)
		return
	case err != nil:
		s.writeVoucherInternalError(w, "", "voucher purchase resolution failed", err)
		return
	}
	s.logger().Info("a card purchase was settled by the operator",
		"purchase_id", resolved.ID, "outcome", request.Outcome, "actor", request.Actor,
		"reason", request.Reason, "applied", applied)
	writeJSON(w, http.StatusOK, map[string]any{"purchase": resolved, "applied": applied})
}

// handleVoucherAdminReloadly answers the operator's reads from Reloadly with
// the company's credentials, which never leave the relay.
func (s HTTPServer) handleVoucherAdminReloadly(w http.ResponseWriter, r *http.Request, what string) {
	client := s.Vouchers.Reloadly
	if client == nil {
		writeSMSError(w, http.StatusServiceUnavailable, "supplier_unconfigured", "Reloadly is not configured on this relay", nil)
		return
	}
	switch strings.Trim(what, "/") {
	case "balance":
		balance, err := client.GiftBalance(r.Context())
		if err != nil {
			writeSMSError(w, http.StatusBadGateway, "supplier_error", err.Error(), nil)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"reloadly": balance, "sandbox": client.Sandbox()})
	default:
		writeNotFound(w)
	}
}

// handleVoucherAdminBNPlus answers the operator's discovery reads from BN
// Plus with the company's credentials, which never leave the relay.
func (s HTTPServer) handleVoucherAdminBNPlus(w http.ResponseWriter, r *http.Request, what string) {
	client := s.Vouchers.BNPlus
	if client == nil {
		writeSMSError(w, http.StatusServiceUnavailable, "supplier_unconfigured", "BN Plus is not configured on this relay", nil)
		return
	}
	query := r.URL.Query()
	number := func(name string) int64 {
		value, _ := strconv.ParseInt(strings.TrimSpace(query.Get(name)), 10, 64)
		return value
	}
	ctx := r.Context()
	var (
		body any
		err  error
	)
	switch strings.Trim(what, "/") {
	case "wallets":
		body, err = client.Wallets(ctx)
	case "groups":
		groupType := bnplus.AllGroups
		switch strings.ToLower(strings.TrimSpace(query.Get("type"))) {
		case "1", "local":
			groupType = bnplus.LocalGroups
		case "2", "international":
			groupType = bnplus.InternationalGroup
		}
		body, err = client.Groups(ctx, groupType)
	case "companies":
		body, err = client.Companies(ctx, number("group_id"))
	case "cards":
		body, err = client.Cards(ctx, number("branch_id"))
	case "orders":
		body, err = client.Orders(ctx)
	case "order":
		body, err = client.OrderStatus(ctx, number("order_id"))
	default:
		writeNotFound(w)
		return
	}
	if err != nil {
		writeSMSError(w, http.StatusBadGateway, "supplier_error", err.Error(), nil)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"bnplus": body})
}
