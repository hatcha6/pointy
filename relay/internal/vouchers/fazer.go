package vouchers

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"pointy/relay/internal/fazer"
)

// SupplierFazer is FazerCards, paid in dollars from the company's account
// there: gift cards and game keys (codes), and game top-ups, Telegram Stars
// and Premium, Steam wallet top-ups and Steam games sent as gifts (sent to an
// account, see target.go).
const SupplierFazer = "fazer"

// FazerCards products, the first part of a ref's ID.
const (
	FazerGiftCard = "giftcard"
	FazerGameKey  = "gamekey"
	FazerTopup    = "topup"
	FazerStars    = "stars"
	FazerPremium  = "premium"
	FazerSteam    = "steam"
	// FazerSteamGift is a Steam game sent as a gift to a friend invite link.
	FazerSteamGift = "steamgift"
)

const (
	// DefaultFazerCacheTTL is how long a category's offers, read for the offer
	// sync, are reused.
	DefaultFazerCacheTTL = 10 * time.Minute
	// fazerOfferReaders is how many categories the offer sync reads at once.
	fazerOfferReaders = 4
	// fazerSettle is how long Buy waits for an order to finish before
	// answering pending: most codes and top-ups take seconds, and a code in
	// hand now saves the shop a read back.
	fazerSettle       = 12 * time.Second
	fazerSettlePause  = 2 * time.Second
	fazerCurrency     = "USD"
	fazerRefFindPages = 10

	// An account check is FazerCards asking the game, which takes a second or
	// more; what it found is reused for a while. A player found stays found
	// for longer than one that was not (an ID being typed in, or a new
	// account); a check that could not tell is never reused.
	fazerFoundTTL     = 10 * time.Minute
	fazerNotFoundTTL  = 2 * time.Minute
	fazerChecksKept   = 4096
	fazerWarmInterval = time.Minute
)

// fazerRef is a FazerCards ref's ID read back: a product, a category (a gift
// card brand, a game, a top-up game) and an offer in it; or the quantity of
// stars, the months of Premium, the amount and currency of a Steam top-up; or
// a Steam game's app id, the edition's sub id and the region it is bought in.
type fazerRef struct {
	Product  string
	Category string
	Offer    string
	Quantity int
	Months   int
	Currency string
	Amount   string
	AppID    int64
	SubID    int64
	Region   string
}

// NeedsAccount reports whether the product is sent to an account.
func (r fazerRef) NeedsAccount() bool {
	switch r.Product {
	case FazerTopup, FazerStars, FazerPremium, FazerSteam, FazerSteamGift:
		return true
	}
	return false
}

func (r fazerRef) id() string {
	esc := url.PathEscape
	switch r.Product {
	case FazerGiftCard, FazerGameKey, FazerTopup:
		return r.Product + "/" + esc(r.Category) + "/" + esc(r.Offer)
	case FazerStars:
		return FazerStars + "/" + strconv.Itoa(r.Quantity)
	case FazerPremium:
		return FazerPremium + "/" + strconv.Itoa(r.Months)
	case FazerSteam:
		return FazerSteam + "/" + r.Currency + "/" + r.Amount
	case FazerSteamGift:
		return fmt.Sprintf("%s/%d/%d/%s", FazerSteamGift, r.AppID, r.SubID, r.Region)
	}
	return ""
}

// parseFazerRefID is the inverse of fazerRef.id.
func parseFazerRefID(id string) (fazerRef, error) {
	parts := strings.Split(strings.TrimSpace(id), "/")
	bad := fmt.Errorf("fazer ref %q is not one this relay writes", id)
	unescape := func(text string) (string, bool) {
		value, err := url.PathUnescape(text)
		return value, err == nil && strings.TrimSpace(value) != ""
	}
	switch parts[0] {
	case FazerGiftCard, FazerGameKey, FazerTopup:
		if len(parts) != 3 {
			return fazerRef{}, bad
		}
		category, ok1 := unescape(parts[1])
		offer, ok2 := unescape(parts[2])
		if !ok1 || !ok2 {
			return fazerRef{}, bad
		}
		return fazerRef{Product: parts[0], Category: category, Offer: offer}, nil
	case FazerStars, FazerPremium:
		if len(parts) != 2 {
			return fazerRef{}, bad
		}
		n, err := strconv.Atoi(parts[1])
		if err != nil {
			return fazerRef{}, bad
		}
		if parts[0] == FazerStars {
			return fazerRef{Product: FazerStars, Quantity: n}, nil
		}
		return fazerRef{Product: FazerPremium, Months: n}, nil
	case FazerSteam:
		if len(parts) != 3 {
			return fazerRef{}, bad
		}
		return fazerRef{Product: FazerSteam, Currency: parts[1], Amount: parts[2]}, nil
	case FazerSteamGift:
		if len(parts) != 4 {
			return fazerRef{}, bad
		}
		appID, err1 := strconv.ParseInt(parts[1], 10, 64)
		subID, err2 := strconv.ParseInt(parts[2], 10, 64)
		if err1 != nil || err2 != nil || appID <= 0 || subID <= 0 || !steamRegionPattern.MatchString(parts[3]) {
			return fazerRef{}, bad
		}
		return fazerRef{Product: FazerSteamGift, AppID: appID, SubID: subID, Region: parts[3]}, nil
	}
	return fazerRef{}, bad
}

// steamRegionPattern is a Steam gift region as FazerCards names them: a
// country ("US") or a group of them ("MENA", "CIS", "EURO").
var steamRegionPattern = regexp.MustCompile(`^[A-Z]{2,6}$`)

// parseFazerRef reads an item's FazerCards block:
//
//	{"key": "fazer", "product": "giftcard", "category": "app_store_itunes_us", "offer": "…", "max_cost": "…"}
//	{"key": "fazer", "product": "gamekey",  "category": "<game_id>",  "offer": "<key_id>"}
//	{"key": "fazer", "product": "topup",    "category": "pubg_mobile_auto", "offer": "<offer_id>"}
//	{"key": "fazer", "product": "stars",    "quantity": 500}
//	{"key": "fazer", "product": "premium",  "months": 3}
//	{"key": "fazer", "product": "steam",    "currency": "USD", "amount": "10"}
//	{"key": "fazer", "product": "steamgift", "app_id": 1245620, "sub_id": 440408, "region": "MENA"}
func parseFazerRef(raw json.RawMessage) (Ref, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var block struct {
		Key      string      `json:"key"`
		Product  string      `json:"product"`
		Category string      `json:"category"`
		Offer    string      `json:"offer"`
		Quantity int         `json:"quantity"`
		Months   int         `json:"months"`
		Currency string      `json:"currency"`
		Amount   json.Number `json:"amount"`
		AppID    int64       `json:"app_id"`
		SubID    int64       `json:"sub_id"`
		Region   string      `json:"region"`
		MaxCost  string      `json:"max_cost"`
	}
	if err := decoder.Decode(&block); err != nil {
		return Ref{}, fmt.Errorf("fazer takes key, product, category, offer, quantity, months, currency, amount, app_id, sub_id, region and max_cost: %v", err)
	}
	ref := fazerRef{Product: strings.ToLower(strings.TrimSpace(block.Product))}
	switch ref.Product {
	case FazerGiftCard, FazerGameKey, FazerTopup:
		ref.Category, ref.Offer = strings.TrimSpace(block.Category), strings.TrimSpace(block.Offer)
		if ref.Category == "" || ref.Offer == "" {
			return Ref{}, fmt.Errorf("fazer %s needs category and offer, as FazerCards names them", ref.Product)
		}
	case FazerStars:
		if block.Quantity < 50 || block.Quantity > 100000 {
			return Ref{}, errors.New("fazer stars needs quantity, 50 to 100000 stars")
		}
		ref.Quantity = block.Quantity
	case FazerPremium:
		if block.Months != 3 && block.Months != 6 && block.Months != 12 {
			return Ref{}, errors.New("fazer premium needs months: 3, 6 or 12")
		}
		ref.Months = block.Months
	case FazerSteam:
		ref.Currency = strings.ToUpper(strings.TrimSpace(block.Currency))
		if ref.Currency != "USD" {
			// RUB, UAH and KZT top-ups are priced from FazerCards' own rates,
			// which the relay does not price from: dollars only.
			return Ref{}, errors.New("fazer steam is sold in USD")
		}
		amount, ok := new(big.Rat).SetString(string(block.Amount))
		if !ok || amount.Sign() <= 0 || !pricePattern.MatchString(string(block.Amount)) {
			return Ref{}, errors.New("fazer steam needs amount, dollars with at most two decimals")
		}
		ref.Amount = amount.FloatString(2)
		ref.Amount = strings.TrimSuffix(strings.TrimRight(ref.Amount, "0"), ".")
	case FazerSteamGift:
		ref.AppID, ref.SubID = block.AppID, block.SubID
		ref.Region = strings.ToUpper(strings.TrimSpace(block.Region))
		if ref.AppID <= 0 || ref.SubID <= 0 {
			return Ref{}, errors.New("fazer steamgift needs app_id and sub_id, as FazerCards lists the game's editions")
		}
		if !steamRegionPattern.MatchString(ref.Region) {
			return Ref{}, errors.New(`fazer steamgift needs region, a Steam region as FazerCards names it ("MENA")`)
		}
	default:
		return Ref{}, fmt.Errorf("fazer product must be %s, %s, %s, %s, %s, %s or %s",
			FazerGiftCard, FazerGameKey, FazerTopup, FazerStars, FazerPremium, FazerSteam, FazerSteamGift)
	}
	maxCost, err := parseMaxCost(block.MaxCost)
	if err != nil {
		return Ref{}, err
	}
	return Ref{Supplier: SupplierFazer, ID: ref.id(), MaxCost: maxCost}, nil
}

// RefNeedsAccount reports whether a ref's card is sent to an account rather
// than handed over as a code.
func RefNeedsAccount(ref Ref) bool {
	if ref.Supplier != SupplierFazer {
		return false
	}
	parsed, err := parseFazerRefID(ref.ID)
	return err == nil && parsed.NeedsAccount()
}

// FazerSupplier buys from FazerCards with the company's dollar account. The
// relay passes the purchase's id as each order's Idempotency-Key, so a replay
// can never charge twice. It implements WantedOffers (a card is priced from its
// category, read on demand), BalanceReader, TargetBuyer and TargetChecker.
type FazerSupplier struct {
	Client *fazer.Client
	// SteamFeePercent is what a Steam top-up costs over its face value, as the
	// account's plan charges it ("3.5"). Empty: unknown, so Steam top-ups are
	// listed out of stock rather than priced blind.
	SteamFeePercent string
	// CacheTTL is how long a category's offers are reused;
	// DefaultFazerCacheTTL when zero.
	CacheTTL time.Duration

	mu        sync.Mutex
	topups    map[string]fazerCached[fazer.TopupCategory]
	giftcards map[string]fazerCached[fazer.GiftCards]
	gamekeys  map[string]fazerCached[fazer.GameKeys]
	gifts     map[string]fazerCached[fazer.SteamGift]
	stars     fazerCached[fazer.StarsQuote]
	premium   fazerCached[[]fazer.PremiumPlan]
	nowFunc   func() time.Time
	sleep     func(context.Context, time.Duration) bool

	balance   *big.Rat
	balanceAt time.Time

	checks map[string]fazerCheck
}

// fazerCheck is one account check's answer, and until when it stands.
type fazerCheck struct {
	answer AccountCheck
	until  time.Time
}

type fazerCached[T any] struct {
	value T
	at    time.Time
	ok    bool
}

var (
	_ Supplier      = (*FazerSupplier)(nil)
	_ RefFinder     = (*FazerSupplier)(nil)
	_ WantedOffers  = (*FazerSupplier)(nil)
	_ BalanceReader = (*FazerSupplier)(nil)
	_ TargetBuyer   = (*FazerSupplier)(nil)
	_ TargetChecker = (*FazerSupplier)(nil)
)

func (s *FazerSupplier) Key() string { return SupplierFazer }

func (s *FazerSupplier) now() time.Time {
	if s.nowFunc != nil {
		return s.nowFunc()
	}
	return time.Now()
}

func (s *FazerSupplier) ttl() time.Duration {
	if s.CacheTTL > 0 {
		return s.CacheTTL
	}
	return DefaultFazerCacheTTL
}

func (s *FazerSupplier) wait(ctx context.Context, d time.Duration) bool {
	if s.sleep != nil {
		return s.sleep(ctx, d)
	}
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

// Buy orders quantity codes of a gift card or game key offer. A card sent to
// an account is refused here (BuyFor places it), before anything is sent.
func (s *FazerSupplier) Buy(ctx context.Context, ref Ref, quantity int, clientRef string) (Purchase, error) {
	parsed, err := parseFazerRefID(ref.ID)
	if err != nil {
		return Purchase{}, &Failure{Code: FailureRefused, Detail: err.Error(), Definite: true}
	}
	var order fazer.Order
	switch parsed.Product {
	case FazerGiftCard:
		order, err = s.Client.OrderGiftCards(ctx, parsed.Category, parsed.Offer, quantity, clientRef)
	case FazerGameKey:
		order, err = s.Client.OrderGameKeys(ctx, parsed.Category, parsed.Offer, quantity, clientRef)
	default:
		return Purchase{}, &Failure{Code: FailureRefused, Definite: true,
			Detail: "this card is sent to an account and needs one (BuyFor)"}
	}
	if err != nil {
		return Purchase{}, fazerFailure(err)
	}
	return s.settle(ctx, order, quantity, false)
}

// BuyFor sends one top-up, Stars, Premium, Steam top-up or Steam gift order to
// an account.
func (s *FazerSupplier) BuyFor(ctx context.Context, ref Ref, account Account, clientRef string) (Purchase, error) {
	parsed, err := parseFazerRefID(ref.ID)
	if err != nil {
		return Purchase{}, &Failure{Code: FailureRefused, Detail: err.Error(), Definite: true}
	}
	if !account.Present() {
		return Purchase{}, &Failure{Code: FailureRefused, Detail: ErrAccountRequired.Error(), Definite: true}
	}
	var order fazer.Order
	switch parsed.Product {
	case FazerTopup:
		order, err = s.Client.OrderTopup(ctx, parsed.Category, parsed.Offer, account, clientRef)
	case FazerStars:
		order, err = s.Client.BuyTelegramStars(ctx, firstAccountValue(account), parsed.Quantity, clientRef)
	case FazerPremium:
		order, err = s.Client.BuyTelegramPremium(ctx, firstAccountValue(account), parsed.Months, clientRef)
	case FazerSteam:
		order, err = s.Client.OrderSteamTopup(ctx, firstAccountValue(account), parsed.Currency, parsed.Amount, clientRef)
	case FazerSteamGift:
		order, err = s.Client.OrderSteamGift(ctx, firstAccountValue(account), parsed.AppID, parsed.SubID, parsed.Region, clientRef)
	default:
		return Purchase{}, &Failure{Code: FailureRefused, Definite: true,
			Detail: "this card is a code, not credit sent to an account"}
	}
	if err != nil {
		return Purchase{}, fazerFailure(err)
	}
	return s.settle(ctx, order, 1, true)
}

// firstAccountValue is the one value of a single-field target (a username, a
// login, an invite link), whatever the field is called.
func firstAccountValue(account Account) string {
	for _, key := range []string{"username", "telegram_username", "login", "steam_login", "invite_url"} {
		if value := account[key]; value != "" {
			return value
		}
	}
	for _, value := range account {
		return value
	}
	return ""
}

// settle reads a just-placed order back for a few seconds while it is still
// processing, and answers how it stands. An order whose answer names no id is
// still an order: it comes back pending with no id and is found again by its
// key.
func (s *FazerSupplier) settle(ctx context.Context, order fazer.Order, quantity int, toAccount bool) (Purchase, error) {
	purchase := fazerPurchase(order, quantity, toAccount)
	if purchase.Status != StatusPending || order.ID == "" || !Settles(ctx) {
		return s.finished(purchase, order)
	}
	deadline := s.now().Add(fazerSettle)
	for s.now().Before(deadline) {
		if !s.wait(ctx, fazerSettlePause) {
			break
		}
		read, err := s.Client.Order(ctx, order.ID)
		if err != nil {
			break
		}
		order, purchase = read, fazerPurchase(read, quantity, toAccount)
		if purchase.Status != StatusPending {
			break
		}
	}
	return s.finished(purchase, order)
}

// finished turns a refunded order into the failure it is (nothing delivered,
// the balance given back), and hands everything else over as it stands.
func (s *FazerSupplier) finished(purchase Purchase, order fazer.Order) (Purchase, error) {
	if purchase.Status == StatusFailed {
		detail := "FazerCards refunded order " + order.ID
		if order.Message != "" {
			detail += ": " + order.Message
		}
		return Purchase{}, &Failure{Code: FailureRefused, Detail: detail, Definite: true, OrderID: order.ID}
	}
	return purchase, nil
}

// fazerPurchase reads FazerCards' record of an order. A code order is only a
// success with every code in hand; an order to an account is a success when
// FazerCards says it is complete.
func fazerPurchase(order fazer.Order, quantity int, toAccount bool) Purchase {
	purchase := Purchase{OrderID: order.ID, Cost: order.CostUSD, At: order.CreatedAt}
	if purchase.Cost != "" {
		purchase.Currency = fazerCurrency
	}
	switch order.Status {
	case fazer.StatusCompleted:
		purchase.Status = StatusSucceeded
		if !toAccount {
			for _, code := range order.Codes {
				purchase.Codes = append(purchase.Codes, Code{Code: code.Code, Serial: code.Serial})
			}
			if len(purchase.Codes) < quantity {
				// Never claim success without the codes in hand.
				purchase.Status = StatusPending
			}
		}
	case fazer.StatusRefunded:
		purchase.Status = StatusFailed
		purchase.Cost, purchase.Currency = "", ""
		purchase.Message = "FazerCards ended the order " + order.RawStatus
	default:
		purchase.Status = StatusPending
	}
	return purchase
}

// Lookup reads an order back by FazerCards' public id.
func (s *FazerSupplier) Lookup(ctx context.Context, ref Ref, orderID string) (Purchase, error) {
	order, err := s.Client.Order(ctx, orderID)
	if err != nil {
		return Purchase{}, err
	}
	toAccount := RefNeedsAccount(ref)
	return fazerPurchase(order, max(1, len(order.Codes)), toAccount), nil
}

// Find is not how a FazerCards order is found again: FindByClientRef reads the
// order history for the purchase's key. Guessing by card and time is refused
// rather than answered with an emptiness that would read as "no such order".
func (s *FazerSupplier) Find(context.Context, Ref, int, time.Time, time.Time) ([]Purchase, error) {
	return nil, errors.New("a FazerCards order is found by the key it was placed with (FindByClientRef), not by card and time")
}

// FindByClientRef looks for the order placed with clientRef as its key in the
// newest pages of the order history. An empty answer is only given when the
// history was read to its end, or past orders older than from, and names its
// orders' keys; a history that never echoes keys cannot say "no such order",
// and answers an error instead. FazerCards' does not (seen 2026-11-03), so an
// order whose answer was lost before its id came back is left to an operator.
func (s *FazerSupplier) FindByClientRef(ctx context.Context, ref Ref, clientRef string, from, _ time.Time) ([]Purchase, error) {
	clientRef = strings.TrimSpace(clientRef)
	if clientRef == "" {
		return nil, errors.New("a client reference is required to find a FazerCards order")
	}
	toAccount := RefNeedsAccount(ref)
	echoes, complete := false, false
	var found []Purchase
	for page := 1; page <= fazerRefFindPages; page++ {
		orders, total, err := s.Client.Orders(ctx, page, 100)
		if err != nil {
			return nil, err
		}
		older := false
		for _, order := range orders {
			if order.IdempotencyKey != "" {
				echoes = true
			}
			if order.IdempotencyKey == clientRef {
				found = append(found, fazerPurchase(order, max(1, len(order.Codes)), toAccount))
			}
			if !from.IsZero() && !order.CreatedAt.IsZero() && order.CreatedAt.Before(from) {
				older = true
			}
		}
		if len(orders) == 0 || page*100 >= total || older {
			complete = true
			break
		}
	}
	if len(found) > 0 {
		return found, nil
	}
	if !complete {
		return nil, errors.New("the FazerCards order history is longer than the relay reads: the order was not found in its newest pages")
	}
	if !echoes {
		return nil, errors.New("FazerCards' order history does not name the key each order was placed with: a lost order cannot be told apart")
	}
	return nil, nil
}

// Offers lists nothing: a card is priced from its category's offers, which
// OffersFor reads for the cards the catalog names.
func (s *FazerSupplier) Offers(context.Context) ([]Offer, error) { return nil, nil }

// OffersFor prices exactly the wanted refs, in dollars. A ref whose offer is
// gone is absent from the answer; one out of stock (or a Steam top-up whose
// fee is not configured) is listed out of stock.
func (s *FazerSupplier) OffersFor(ctx context.Context, wanted []Ref) ([]Offer, error) {
	s.readBalance(ctx)
	now := s.now().UTC()
	seen := map[string]bool{}
	type priced struct {
		ref   Ref
		fazer fazerRef
		offer Offer
		found bool
		err   error
	}
	var rows []*priced
	// One read per category, so a category's refs stay together: two readers
	// of one category would each miss the cache and read it twice.
	var groups [][]*priced
	groupOf := map[string]int{}
	for _, ref := range wanted {
		if ref.Supplier != "" && ref.Supplier != SupplierFazer || seen[ref.ID] {
			continue
		}
		seen[ref.ID] = true
		parsed, err := parseFazerRefID(ref.ID)
		if err != nil {
			continue
		}
		row := &priced{ref: ref, fazer: parsed}
		rows = append(rows, row)
		name := parsed.Product + "/" + parsed.Category
		index, known := groupOf[name]
		if !known {
			index = len(groups)
			groupOf[name] = index
			groups = append(groups, nil)
		}
		groups[index] = append(groups[index], row)
	}
	// The catalog names hundreds of categories and the offer sync has a deadline:
	// read one after another, the last of them would be read as no longer sold.
	work := make(chan []*priced)
	var readers sync.WaitGroup
	for range fazerOfferReaders {
		readers.Add(1)
		go func() {
			defer readers.Done()
			for group := range work {
				for _, row := range group {
					row.offer, row.found, row.err = s.price(ctx, row.fazer)
				}
			}
		}()
	}
	for _, group := range groups {
		work <- group
	}
	close(work)
	readers.Wait()

	offers := make([]Offer, 0, len(rows))
	var firstErr error
	failed := 0
	for _, row := range rows {
		if row.err != nil {
			failed++
			if firstErr == nil {
				firstErr = row.err
			}
			continue
		}
		if !row.found {
			continue
		}
		offer := row.offer
		offer.Ref, offer.Currency, offer.SyncedAt = row.ref.ID, fazerCurrency, now
		offers = append(offers, offer)
	}
	if failed > 0 && len(offers) == 0 {
		// Nothing could be read: say so, rather than answer an empty list that
		// would read as "nothing is sold any more".
		return nil, firstErr
	}
	return offers, nil
}

// price is one ref's offer, from its category (cached).
func (s *FazerSupplier) price(ctx context.Context, ref fazerRef) (Offer, bool, error) {
	switch ref.Product {
	case FazerGiftCard:
		cards, err := cachedRead(s, ctx, &s.giftcards, ref.Category, s.Client.GiftCards)
		if err != nil {
			return Offer{}, false, ignoreNotFound(err)
		}
		return stockOffer(cards.Offers, ref.Offer, cards.Name)
	case FazerGameKey:
		keys, err := cachedRead(s, ctx, &s.gamekeys, ref.Category, s.Client.GameKeys)
		if err != nil {
			return Offer{}, false, ignoreNotFound(err)
		}
		return stockOffer(keys.Keys, ref.Offer, keys.Name)
	case FazerTopup:
		category, err := cachedRead(s, ctx, &s.topups, ref.Category, s.Client.TopupOffers)
		if err != nil {
			return Offer{}, false, ignoreNotFound(err)
		}
		for _, offer := range category.Offers {
			if offer.ID == ref.Offer {
				price, ok := usdPrice(offer.PriceUSD)
				return Offer{Name: offer.Name, Group: category.Name, Price: price, InStock: ok}, true, nil
			}
		}
		return Offer{}, false, nil
	case FazerStars:
		quote, err := cachedOne(s, ctx, &s.stars, s.Client.TelegramStars)
		if err != nil {
			return Offer{}, false, err
		}
		perStar, ok := new(big.Rat).SetString(quote.PricePerStar)
		if !ok || perStar.Sign() <= 0 {
			return Offer{Name: "Telegram Stars", InStock: false}, true, nil
		}
		total := new(big.Rat).Mul(perStar, big.NewRat(int64(ref.Quantity), 1))
		inRange := (quote.Min == 0 || ref.Quantity >= quote.Min) && (quote.Max == 0 || ref.Quantity <= quote.Max)
		return Offer{Name: strconv.Itoa(ref.Quantity) + " Telegram Stars", Group: "Telegram",
			Price: ceilCents(total), InStock: inRange}, true, nil
	case FazerPremium:
		plans, err := cachedOne(s, ctx, &s.premium, s.Client.TelegramPremium)
		if err != nil {
			return Offer{}, false, err
		}
		for _, plan := range plans {
			if plan.Months == ref.Months {
				price, ok := usdPrice(plan.PriceUSD)
				return Offer{Name: fmt.Sprintf("Telegram Premium %d months", ref.Months), Group: "Telegram",
					Price: price, InStock: ok}, true, nil
			}
		}
		return Offer{}, false, nil
	case FazerSteam:
		amount, ok := new(big.Rat).SetString(ref.Amount)
		fee, feeOK := new(big.Rat).SetString(strings.TrimSpace(s.SteamFeePercent))
		offer := Offer{Name: "Steam " + ref.Amount + " " + ref.Currency, Group: "Steam"}
		if !ok || !feeOK || fee.Sign() < 0 {
			// The plan's charge on a Steam top-up is not known: never priced blind.
			offer.Price, offer.InStock = "0", false
			return offer, true, nil
		}
		factor := new(big.Rat).Add(big.NewRat(1, 1), new(big.Rat).Quo(fee, big.NewRat(100, 1)))
		offer.Price, offer.InStock = ceilCents(new(big.Rat).Mul(amount, factor)), true
		return offer, true, nil
	case FazerSteamGift:
		gift, err := cachedRead(s, ctx, &s.gifts, strconv.FormatInt(ref.AppID, 10), s.Client.SteamGiftOffers)
		if err != nil {
			return Offer{}, false, ignoreNotFound(err)
		}
		for _, edition := range gift.Editions {
			if edition.SubID == ref.SubID {
				// An edition no longer sold in the region is out of stock there.
				price, ok := usdPrice(edition.Prices[ref.Region])
				return Offer{Name: edition.Name, Group: "Steam " + ref.Region, Price: price, InStock: ok}, true, nil
			}
		}
		return Offer{}, false, nil
	}
	return Offer{}, false, nil
}

func ignoreNotFound(err error) error {
	if fazer.IsNotFound(err) {
		return nil
	}
	return err
}

func stockOffer(offers []fazer.StockOffer, id, group string) (Offer, bool, error) {
	for _, offer := range offers {
		if offer.ID == id {
			price, ok := usdPrice(offer.PriceUSD)
			return Offer{Name: offer.Name, Group: group, Price: price, InStock: ok && offer.Stock > 0}, true, nil
		}
	}
	return Offer{}, false, nil
}

// usdPrice is a dollar price as the offer sync stores it, and whether it is a
// price at all.
func usdPrice(text string) (string, bool) {
	value, ok := new(big.Rat).SetString(strings.TrimSpace(text))
	if !ok || value.Sign() <= 0 {
		return "0", false
	}
	return value.FloatString(4), true
}

// ceilCents rounds a dollar amount up to the cent, as FazerCards bills it.
func ceilCents(value *big.Rat) string {
	cents := new(big.Rat).Mul(value, big.NewRat(100, 1))
	whole := new(big.Int).Quo(cents.Num(), cents.Denom())
	if new(big.Rat).SetInt(whole).Cmp(cents) < 0 {
		whole.Add(whole, big.NewInt(1))
	}
	return new(big.Rat).SetFrac(whole, big.NewInt(100)).FloatString(2)
}

// cachedRead reads one category through the supplier's cache.
func cachedRead[T any](
	s *FazerSupplier,
	ctx context.Context,
	cache *map[string]fazerCached[T],
	key string,
	read func(context.Context, string) (T, error),
) (T, error) {
	s.mu.Lock()
	if *cache == nil {
		*cache = map[string]fazerCached[T]{}
	}
	entry, cached := (*cache)[key]
	if cached && entry.ok && s.now().Sub(entry.at) < s.ttl() {
		s.mu.Unlock()
		return entry.value, nil
	}
	s.mu.Unlock()
	value, err := read(ctx, key)
	if err != nil {
		if cached && entry.ok && !fazer.IsNotFound(err) {
			// One category that did not answer this time keeps the prices last
			// read: an empty answer would take its cards off every shelf.
			return entry.value, nil
		}
		var zero T
		return zero, err
	}
	s.mu.Lock()
	(*cache)[key] = fazerCached[T]{value: value, at: s.now(), ok: true}
	s.mu.Unlock()
	return value, nil
}

// cachedOne reads a single quote through the supplier's cache.
func cachedOne[T any](s *FazerSupplier, ctx context.Context, cache *fazerCached[T], read func(context.Context) (T, error)) (T, error) {
	s.mu.Lock()
	if cache.ok && s.now().Sub(cache.at) < s.ttl() {
		value := cache.value
		s.mu.Unlock()
		return value, nil
	}
	s.mu.Unlock()
	value, err := read(ctx)
	if err != nil {
		var zero T
		return zero, err
	}
	s.mu.Lock()
	*cache = fazerCached[T]{value: value, at: s.now(), ok: true}
	s.mu.Unlock()
	return value, nil
}

func (s *FazerSupplier) readBalance(ctx context.Context) {
	balance, err := s.Client.Balance(ctx)
	if err != nil {
		return
	}
	amount, ok := new(big.Rat).SetString(balance.Amount)
	if !ok {
		return
	}
	s.mu.Lock()
	s.balance, s.balanceAt = amount, s.now()
	s.mu.Unlock()
}

// KeepWarm reads the balance every so often until ctx ends, so the relay's
// connection to FazerCards is open when a customer needs it: a cold one costs
// half a second of DNS, TCP and TLS before the first answer (measured
// 2026-11-03: 476 ms of a 599 ms first call; 108 ms warm). The balance it
// reads is the console's, fresher too.
func (s *FazerSupplier) KeepWarm(ctx context.Context, every time.Duration) {
	if every <= 0 {
		every = fazerWarmInterval
	}
	for {
		s.readBalance(ctx)
		if !s.wait(ctx, every) {
			return
		}
	}
}

// LastBalance is the company's balance at FazerCards as the offer sync (or
// KeepWarm) last read it, in dollars.
func (s *FazerSupplier) LastBalance() (*big.Rat, string, time.Time, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.balance == nil {
		return nil, "", time.Time{}, false
	}
	return new(big.Rat).Set(s.balance), fazerCurrency, s.balanceAt, true
}

// CheckAccount looks an account up before an order: a player ID with the
// game's validate-id (target.Check names it), a Steam login with check-login.
// A Telegram username has no check. An answer is reused for a while
// (fazerFoundTTL, fazerNotFoundTTL): the customer's brand page and their
// checkout ask about the same account a minute apart.
func (s *FazerSupplier) CheckAccount(ctx context.Context, ref Ref, target Target, account Account) (AccountCheck, error) {
	parsed, err := parseFazerRefID(ref.ID)
	if err != nil {
		return AccountCheck{}, err
	}
	key := fazerCheckKey(parsed, target, account)
	if answer, ok := s.knownCheck(key); ok {
		return answer, nil
	}
	answer, err := s.checkAccount(ctx, parsed, target, account)
	if err == nil {
		s.keepCheck(key, answer)
	}
	return answer, err
}

// fazerCheckKey names an account check: which look-up, and the account as
// typed, in a stable order.
func fazerCheckKey(ref fazerRef, target Target, account Account) string {
	keys := make([]string, 0, len(account))
	for key := range account {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString(ref.Product + "|" + strings.TrimSpace(target.Check))
	for _, key := range keys {
		b.WriteString("|" + key + "=" + account[key])
	}
	return b.String()
}

func (s *FazerSupplier) knownCheck(key string) (AccountCheck, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	known, ok := s.checks[key]
	if !ok || !s.now().Before(known.until) {
		return AccountCheck{}, false
	}
	return known.answer, true
}

func (s *FazerSupplier) keepCheck(key string, answer AccountCheck) {
	var ttl time.Duration
	switch answer.Status {
	case AccountValid:
		ttl = fazerFoundTTL
	case AccountInvalid:
		ttl = fazerNotFoundTTL
	default:
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	if s.checks == nil {
		s.checks = map[string]fazerCheck{}
	}
	if len(s.checks) >= fazerChecksKept {
		for old, known := range s.checks {
			if !now.Before(known.until) {
				delete(s.checks, old)
			}
		}
		if len(s.checks) >= fazerChecksKept {
			s.checks = map[string]fazerCheck{}
		}
	}
	s.checks[key] = fazerCheck{answer: answer, until: now.Add(ttl)}
}

// checkAccount asks FazerCards about one account.
func (s *FazerSupplier) checkAccount(ctx context.Context, parsed fazerRef, target Target, account Account) (AccountCheck, error) {
	switch parsed.Product {
	case FazerTopup:
		if strings.TrimSpace(target.Check) == "" {
			return AccountCheck{Status: AccountUnchecked}, nil
		}
		player, err := s.Client.CheckPlayer(ctx, target.Check, account)
		switch {
		case errors.Is(err, fazer.ErrUnconfirmed):
			return AccountCheck{Status: AccountUnconfirmed}, nil
		case err != nil:
			return AccountCheck{}, err
		case !player.Valid:
			return AccountCheck{Status: AccountInvalid}, nil
		}
		return AccountCheck{Status: AccountValid, Name: player.PlayerName, Region: player.Region}, nil
	case FazerSteam:
		login, err := s.Client.CheckSteamLogin(ctx, firstAccountValue(account))
		switch {
		case err != nil:
			return AccountCheck{}, err
		case login.Unverified:
			return AccountCheck{Status: AccountUnconfirmed}, nil
		case !login.CanRefill:
			return AccountCheck{Status: AccountInvalid}, nil
		}
		return AccountCheck{Status: AccountValid}, nil
	}
	return AccountCheck{Status: AccountUnchecked}, nil
}

// fazerFailure reads a failed order. Only what proves nothing was charged is
// definite (fazer.Definite); the rest waits for FazerCards' own records,
// found by the order's key.
func fazerFailure(err error) *Failure {
	failure := &Failure{Detail: err.Error(), Definite: fazer.Definite(err)}
	var transport *fazer.TransportError
	switch {
	case !failure.Definite:
		failure.Code = FailureUnknown
	case fazer.IsInsufficientBalance(err):
		failure.Code = FailureCredit
	case fazer.IsUnauthorized(err):
		failure.Code = FailureUnauthorized
	case fazer.IsOutOfStock(err):
		failure.Code = FailureOutOfStock
	case errors.As(err, &transport):
		failure.Code = FailureUnreachable
	default:
		failure.Code = FailureRefused
	}
	return failure
}
