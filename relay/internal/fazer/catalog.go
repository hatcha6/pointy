package fazer

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"
)

// maxCatalogPages bounds a cursor walk: 500 a page is far more than the API
// lists, and a cursor that never ends must not spin forever.
const maxCatalogPages = 40

// Text is a string field the API may also write as a number or null. Prices
// are "decimal strings" in the spec; a number is kept exactly as written.
type Text string

// UnmarshalJSON implements json.Unmarshaler.
func (t *Text) UnmarshalJSON(raw []byte) error {
	raw = bytes.TrimSpace(raw)
	switch {
	case len(raw) == 0 || bytes.Equal(raw, []byte("null")):
		*t = ""
	case raw[0] == '"':
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			return err
		}
		*t = Text(strings.TrimSpace(s))
	case raw[0] == 't' || raw[0] == 'f':
		*t = Text(raw)
	default:
		var n json.Number
		if err := json.Unmarshal(raw, &n); err != nil {
			return fmt.Errorf("fazer: %s is neither text nor a number", raw)
		}
		*t = Text(n.String())
	}
	return nil
}

func (t Text) String() string { return string(t) }

// Count is an integer field the API may also write as a string.
type Count int

// UnmarshalJSON implements json.Unmarshaler.
func (c *Count) UnmarshalJSON(raw []byte) error {
	var t Text
	if err := t.UnmarshalJSON(raw); err != nil {
		return err
	}
	if t == "" {
		*c = 0
		return nil
	}
	value, err := strconv.ParseFloat(string(t), 64)
	if err != nil {
		return fmt.Errorf("fazer: %q is not a count", t)
	}
	*c = Count(value)
	return nil
}

// Field is one thing the buyer types for a top-up: a player ID, a server.
type Field struct {
	Key   string `json:"key"`
	Label string `json:"label"`
	// Type is "text" or "select"; a select takes one of Options' values.
	Type    string   `json:"type"`
	Options []Option `json:"options,omitempty"`
}

// Option is one choice of a select field.
type Option struct {
	Value string `json:"value"`
	Label string `json:"label"`
}

type wireField struct {
	Key     Text             `json:"key"`
	Label   Text             `json:"label"`
	Type    Text             `json:"type"`
	Options []map[string]any `json:"options"`
}

func (w wireField) field() Field {
	field := Field{Key: w.Key.String(), Label: w.Label.String(), Type: strings.ToLower(w.Type.String())}
	if field.Type == "" {
		field.Type = "text"
	}
	for _, raw := range w.Options {
		value := firstText(raw, "value", "id", "key", "code")
		if value == "" {
			continue
		}
		label := firstText(raw, "label", "name", "title", "text")
		if label == "" {
			label = value
		}
		field.Options = append(field.Options, Option{Value: value, Label: label})
	}
	return field
}

func fields(wire []wireField) []Field {
	out := make([]Field, 0, len(wire))
	for _, w := range wire {
		if field := w.field(); field.Key != "" {
			out = append(out, field)
		}
	}
	return out
}

// firstText is the first of keys present in an object, as text.
func firstText(object map[string]any, keys ...string) string {
	for _, key := range keys {
		switch value := object[key].(type) {
		case string:
			if value = strings.TrimSpace(value); value != "" {
				return value
			}
		case float64:
			return strconv.FormatFloat(value, 'f', -1, 64)
		case json.Number:
			return value.String()
		}
	}
	return ""
}

// Category is one game, gift card brand or region the API lists.
type Category struct {
	ID       string
	Name     string
	Note     string
	ImageURL string
}

type wireCategory struct {
	CategoryID Text `json:"category_id"`
	Name       Text `json:"name"`
	Note       Text `json:"note"`
	ImageURL   Text `json:"imageurl"`
}

type pageMeta struct {
	NextCursor *string `json:"next_cursor"`
	HasMore    bool    `json:"has_more"`
}

// walk reads every page of a cursor listing. page decodes one answer and says
// what comes next.
func (c *Client) walk(ctx context.Context, op, path string, page func(raw json.RawMessage) (pageMeta, error)) error {
	cursor := ""
	for i := 0; i < maxCatalogPages; i++ {
		query := url.Values{"limit": {"500"}, "include_ui": {"1"}}
		if cursor != "" {
			query.Set("cursor", cursor)
		}
		var raw json.RawMessage
		if err := c.get(ctx, op, path, query, &raw); err != nil {
			return err
		}
		meta, err := page(raw)
		if err != nil {
			return err
		}
		if !meta.HasMore || meta.NextCursor == nil || strings.TrimSpace(*meta.NextCursor) == "" ||
			*meta.NextCursor == cursor {
			return nil
		}
		cursor = *meta.NextCursor
	}
	return fmt.Errorf("fazer: %s did not end after %d pages", op, maxCatalogPages)
}

func (c *Client) categories(ctx context.Context, op, path string) ([]Category, error) {
	var out []Category
	err := c.walk(ctx, op, path, func(raw json.RawMessage) (pageMeta, error) {
		var answer struct {
			Items []wireCategory `json:"items"`
			Meta  pageMeta       `json:"meta"`
		}
		if err := json.Unmarshal(raw, &answer); err != nil {
			return pageMeta{}, &TransportError{Op: op, Err: err, Sent: true}
		}
		for _, item := range answer.Items {
			if item.CategoryID == "" {
				continue
			}
			out = append(out, Category{
				ID: item.CategoryID.String(), Name: item.Name.String(),
				Note: item.Note.String(), ImageURL: item.ImageURL.String(),
			})
		}
		return answer.Meta, nil
	})
	return out, err
}

// --- top-ups ----------------------------------------------------------------

// TopupCategories lists the games (and other services) topped up by account.
func (c *Client) TopupCategories(ctx context.Context) ([]Category, error) {
	return c.categories(ctx, "list top-up categories", "/topups")
}

// TopupOffer is one amount a top-up category sells.
type TopupOffer struct {
	ID       string
	Name     string
	PriceUSD string
}

// TopupCategory is one game's offers and the fields its buyer fills in.
type TopupCategory struct {
	Category
	Offers []TopupOffer
	Fields []Field
}

// TopupOffers reads one category's offers and fields. An offer without an id
// cannot be ordered and is left out.
func (c *Client) TopupOffers(ctx context.Context, categoryID string) (TopupCategory, error) {
	categoryID = strings.TrimSpace(categoryID)
	if categoryID == "" {
		return TopupCategory{}, errors.New("fazer: a top-up category id is required")
	}
	var answer struct {
		wireCategory
		Offers []struct {
			OfferID  Text `json:"offer_id"`
			Name     Text `json:"name"`
			PriceUSD Text `json:"price_usd"`
		} `json:"offers"`
		Fields []wireField `json:"fields"`
	}
	query := url.Values{"category_id": {categoryID}, "include_ui": {"1"}}
	if err := c.get(ctx, "read top-up offers", "/topups/offers", query, &answer); err != nil {
		return TopupCategory{}, err
	}
	out := TopupCategory{
		Category: Category{
			ID: firstNonEmpty(answer.CategoryID.String(), categoryID), Name: answer.Name.String(),
			Note: answer.Note.String(), ImageURL: answer.ImageURL.String(),
		},
		Fields: fields(answer.Fields),
	}
	for _, offer := range answer.Offers {
		if offer.OfferID == "" {
			continue
		}
		out.Offers = append(out.Offers, TopupOffer{
			ID: offer.OfferID.String(), Name: offer.Name.String(), PriceUSD: offer.PriceUSD.String(),
		})
	}
	return out, nil
}

// CheckableGame is a game whose player IDs the API can look up.
type CheckableGame struct {
	CategoryID string
	Name       string
	Fields     []Field
}

// CheckableGames lists the games whose player ID can be checked before an
// order (PUBG Mobile, Free Fire, Mobile Legends…). The list changes.
func (c *Client) CheckableGames(ctx context.Context) ([]CheckableGame, error) {
	var answer struct {
		Items []struct {
			CategoryID Text        `json:"category_id"`
			Name       Text        `json:"name"`
			Fields     []wireField `json:"fields"`
		} `json:"items"`
	}
	if err := c.get(ctx, "list checkable games", "/topups/validate-id", nil, &answer); err != nil {
		return nil, err
	}
	out := make([]CheckableGame, 0, len(answer.Items))
	for _, item := range answer.Items {
		if item.CategoryID == "" {
			continue
		}
		out = append(out, CheckableGame{
			CategoryID: item.CategoryID.String(), Name: item.Name.String(), Fields: fields(item.Fields),
		})
	}
	return out, nil
}

// PlayerCheck is what a game says about a player ID.
type PlayerCheck struct {
	Valid      bool
	PlayerName string
	PlayerID   string
	// Region is the player's region when the game reports it ("EUROPE").
	Region string
}

// CheckPlayer looks a player ID up before an order. A 422 (the game could not
// confirm the ID either way) is ErrUnconfirmed. It is a read and is retried.
func (c *Client) CheckPlayer(ctx context.Context, categoryID string, values map[string]string) (PlayerCheck, error) {
	categoryID = strings.TrimSpace(categoryID)
	if categoryID == "" {
		return PlayerCheck{}, errors.New("fazer: a category id is required to check a player")
	}
	body := map[string]any{"category_id": categoryID, "fields": values}
	var answer struct {
		Valid      bool `json:"valid"`
		PlayerName Text `json:"player_name"`
		PlayerID   Text `json:"player_id"`
		Region     Text `json:"region"`
	}
	err := c.retryPost(ctx, "check a player", "/topups/validate-id", body, &answer)
	if err != nil {
		return PlayerCheck{}, err
	}
	return PlayerCheck{
		Valid: answer.Valid, PlayerName: answer.PlayerName.String(),
		PlayerID: answer.PlayerID.String(), Region: answer.Region.String(),
	}, nil
}

// retryPost is a POST that only reads, retried like a GET.
func (c *Client) retryPost(ctx context.Context, op, path string, body, into any) error {
	var err error
	backoff := c.retryBackoff
	for attempt := 1; attempt <= maxReadAttempts; attempt++ {
		if err = c.post(ctx, op, path, body, "", into); err == nil {
			return nil
		}
		if attempt == maxReadAttempts || ctx.Err() != nil || !retryableRead(err) {
			return err
		}
		select {
		case <-ctx.Done():
			return err
		case <-timeAfter(backoff):
		}
		backoff *= 2
	}
	return err
}

// --- gift cards and game keys -------------------------------------------------

// StockOffer is one gift card or game key the API sells, with what is left.
type StockOffer struct {
	ID          string
	Name        string
	PriceUSD    string
	Stock       int
	MinQuantity int
	MaxQuantity int
}

type wireStockOffer struct {
	CardID Text  `json:"card_id"`
	KeyID  Text  `json:"key_id"`
	Name   Text  `json:"name"`
	Price  Text  `json:"price_usd"`
	Stock  Count `json:"stock"`
	Min    Count `json:"min_order_quantity"`
	Max    Count `json:"max_order_quantity"`
}

func stockOffers(wire []wireStockOffer) []StockOffer {
	out := make([]StockOffer, 0, len(wire))
	for _, w := range wire {
		id := firstNonEmpty(w.CardID.String(), w.KeyID.String())
		if id == "" {
			continue
		}
		out = append(out, StockOffer{
			ID: id, Name: w.Name.String(), PriceUSD: w.Price.String(),
			Stock: int(w.Stock), MinQuantity: int(w.Min), MaxQuantity: int(w.Max),
		})
	}
	return out
}

// GiftCardCategories lists the gift card brands.
func (c *Client) GiftCardCategories(ctx context.Context) ([]Category, error) {
	return c.categories(ctx, "list gift card categories", "/giftcards")
}

// GiftCards is one gift card category's offers.
type GiftCards struct {
	Category
	Offers []StockOffer
}

// GiftCards reads one category's offers.
func (c *Client) GiftCards(ctx context.Context, categoryID string) (GiftCards, error) {
	categoryID = strings.TrimSpace(categoryID)
	if categoryID == "" {
		return GiftCards{}, errors.New("fazer: a gift card category id is required")
	}
	var answer struct {
		wireCategory
		Offers []wireStockOffer `json:"offers"`
	}
	query := url.Values{"category_id": {categoryID}, "include_ui": {"1"}}
	if err := c.get(ctx, "read gift cards", "/giftcards/cards", query, &answer); err != nil {
		return GiftCards{}, err
	}
	return GiftCards{
		Category: Category{
			ID: firstNonEmpty(answer.CategoryID.String(), categoryID), Name: answer.Name.String(),
			Note: answer.Note.String(), ImageURL: answer.ImageURL.String(),
		},
		Offers: stockOffers(answer.Offers),
	}, nil
}

// Game is one game the game key catalog sells keys for.
type Game struct {
	ID       string
	Name     string
	Region   string
	Platform string
	// RegionRestricted: the keys activate only in some countries
	// (GameKeyRegions lists them).
	RegionRestricted bool
	AppID            int64
	ImageURL         string
}

type wireGame struct {
	GameID            Text  `json:"game_id"`
	Name              Text  `json:"name"`
	GameName          Text  `json:"GameName"`
	Region            Text  `json:"region"`
	Platform          Text  `json:"platform"`
	RegionRestriction bool  `json:"region_restriction"`
	AppID             Count `json:"appid"`
	ImageURL          Text  `json:"imageurl"`
}

func (w wireGame) game() Game {
	return Game{
		ID: w.GameID.String(), Name: firstNonEmpty(w.Name.String(), w.GameName.String()),
		Region: w.Region.String(), Platform: strings.ToLower(w.Platform.String()),
		RegionRestricted: w.RegionRestriction, AppID: int64(w.AppID), ImageURL: w.ImageURL.String(),
	}
}

// Games lists the games with at least one key on sale.
func (c *Client) Games(ctx context.Context) ([]Game, error) {
	var out []Game
	err := c.walk(ctx, "list game key games", "/gamekeys", func(raw json.RawMessage) (pageMeta, error) {
		var answer struct {
			Items []wireGame `json:"items"`
			Meta  pageMeta   `json:"meta"`
		}
		if err := json.Unmarshal(raw, &answer); err != nil {
			return pageMeta{}, &TransportError{Op: "list game key games", Err: err, Sent: true}
		}
		for _, item := range answer.Items {
			if item.GameID != "" {
				out = append(out, item.game())
			}
		}
		return answer.Meta, nil
	})
	return out, err
}

// GameKeys is one game's key offers.
type GameKeys struct {
	Game
	Keys []StockOffer
}

// GameKeys reads one game's key offers.
func (c *Client) GameKeys(ctx context.Context, gameID string) (GameKeys, error) {
	gameID = strings.TrimSpace(gameID)
	if gameID == "" {
		return GameKeys{}, errors.New("fazer: a game id is required")
	}
	var answer struct {
		wireGame
		Keys []wireStockOffer `json:"keys"`
	}
	query := url.Values{"game_id": {gameID}, "include_ui": {"1"}}
	if err := c.get(ctx, "read game keys", "/gamekeys/keys", query, &answer); err != nil {
		return GameKeys{}, err
	}
	game := answer.game()
	if game.ID == "" {
		game.ID = gameID
	}
	return GameKeys{Game: game, Keys: stockOffers(answer.Keys)}, nil
}

// Country is a country a game key does or does not activate in.
type Country struct {
	Code string `json:"code"`
	Name string `json:"name"`
}

// RegionAvailability is where one game's keys activate.
type RegionAvailability struct {
	RegionType      string
	HasAvailability bool
	Available       []Country
	Unavailable     []Country
}

// ActivatesIn reports whether the keys are listed as activating in a country
// (an ISO 3166-1 alpha-2 code).
func (r RegionAvailability) ActivatesIn(code string) bool {
	for _, country := range r.Available {
		if strings.EqualFold(country.Code, code) {
			return true
		}
	}
	return false
}

// GameKeyRegions reads where one game's keys activate.
func (c *Client) GameKeyRegions(ctx context.Context, gameID string) (RegionAvailability, error) {
	gameID = strings.TrimSpace(gameID)
	if gameID == "" {
		return RegionAvailability{}, errors.New("fazer: a game id is required")
	}
	var answer struct {
		RegionType      Text      `json:"region_type"`
		HasAvailability bool      `json:"has_availability"`
		Available       []Country `json:"available"`
		Unavailable     []Country `json:"unavailable"`
	}
	query := url.Values{"game_id": {gameID}}
	if err := c.get(ctx, "read game key regions", "/gamekeys/region-restriction", query, &answer); err != nil {
		return RegionAvailability{}, err
	}
	return RegionAvailability{
		RegionType: answer.RegionType.String(), HasAvailability: answer.HasAvailability,
		Available: answer.Available, Unavailable: answer.Unavailable,
	}, nil
}

// --- Telegram and Steam -------------------------------------------------------

// StarsQuote is the price of Telegram Stars.
type StarsQuote struct {
	// PricePerStar is dollars for one star, seven decimals.
	PricePerStar string
	Min, Max     int
	UpdatedAt    string
}

// TelegramStars reads the price of Telegram Stars.
func (c *Client) TelegramStars(ctx context.Context) (StarsQuote, error) {
	var answer struct {
		PricePerStar Text  `json:"price_per_star"`
		Min          Count `json:"min_amount"`
		Max          Count `json:"max_amount"`
		UpdatedAt    Text  `json:"rates_updated_at"`
	}
	if err := c.get(ctx, "read the Telegram Stars price", "/telegram/stars", nil, &answer); err != nil {
		return StarsQuote{}, err
	}
	return StarsQuote{
		PricePerStar: answer.PricePerStar.String(), Min: int(answer.Min), Max: int(answer.Max),
		UpdatedAt: answer.UpdatedAt.String(),
	}, nil
}

// PremiumPlan is one Telegram Premium length and its price in dollars.
type PremiumPlan struct {
	Months   int
	PriceUSD string
}

// TelegramPremium reads the Telegram Premium plans (3, 6 and 12 months).
func (c *Client) TelegramPremium(ctx context.Context) ([]PremiumPlan, error) {
	var answer struct {
		Plans []struct {
			Months Count `json:"months"`
			Price  Text  `json:"price_usd"`
		} `json:"plans"`
	}
	if err := c.get(ctx, "read the Telegram Premium plans", "/telegram/premium", nil, &answer); err != nil {
		return nil, err
	}
	plans := make([]PremiumPlan, 0, len(answer.Plans))
	for _, plan := range answer.Plans {
		if plan.Months > 0 && plan.Price != "" {
			plans = append(plans, PremiumPlan{Months: int(plan.Months), PriceUSD: plan.Price.String()})
		}
	}
	return plans, nil
}

// SteamRates is how many roubles, hryvnias and tenge one dollar buys for a
// Steam top-up.
type SteamRates struct {
	Rates     map[string]string
	UpdatedAt string
}

// SteamRates reads the Steam top-up exchange rates.
func (c *Client) SteamRates(ctx context.Context) (SteamRates, error) {
	var answer struct {
		Rates     map[string]Text `json:"rates"`
		UpdatedAt Text            `json:"updated_at"`
	}
	if err := c.get(ctx, "read the Steam rates", "/steam-topup/rates", nil, &answer); err != nil {
		return SteamRates{}, err
	}
	rates := make(map[string]string, len(answer.Rates))
	for currency, rate := range answer.Rates {
		rates[strings.ToUpper(currency)] = rate.String()
	}
	return SteamRates{Rates: rates, UpdatedAt: answer.UpdatedAt.String()}, nil
}

// SteamLoginCheck is whether a Steam account can be topped up.
type SteamLoginCheck struct {
	CanRefill bool
	// Unverified: the check itself was down, so nothing was learned. An order
	// for an unknown login is refunded by the API on its own.
	Unverified bool
}

// CheckSteamLogin asks whether a Steam login can receive a wallet top-up.
func (c *Client) CheckSteamLogin(ctx context.Context, login string) (SteamLoginCheck, error) {
	login = strings.TrimSpace(login)
	if login == "" {
		return SteamLoginCheck{}, errors.New("fazer: a Steam login is required")
	}
	var answer struct {
		CanRefill  bool `json:"can_refill"`
		Unverified bool `json:"unverified"`
	}
	if err := c.retryPost(ctx, "check a Steam login", "/steam-topup/check-login",
		map[string]string{"steamLogin": login}, &answer); err != nil {
		return SteamLoginCheck{}, err
	}
	return SteamLoginCheck{CanRefill: answer.CanRefill, Unverified: answer.Unverified}, nil
}

// --- Steam gifts ----------------------------------------------------------------

// SteamGiftEdition is one giftable edition of a game (a Steam package) and
// what it costs bought in each Steam region ("MENA", "CIS", "US"), in dollars.
type SteamGiftEdition struct {
	SubID  int64
	Name   string
	Prices map[string]string
}

// SteamGift is one game's giftable editions.
type SteamGift struct {
	AppID    int64
	Editions []SteamGiftEdition
}

// SteamGiftOffers reads one game's giftable editions and their prices per
// region. A game that is not in the gift catalog is a not-found error.
func (c *Client) SteamGiftOffers(ctx context.Context, appID string) (SteamGift, error) {
	appID = strings.TrimSpace(appID)
	if appID == "" {
		return SteamGift{}, errors.New("fazer: a Steam app id is required")
	}
	var answer struct {
		AppID  Count `json:"appid"`
		Offers []struct {
			SubID   Count `json:"sub_id"`
			Name    Text  `json:"name"`
			Regions []struct {
				Region Text `json:"region"`
				Price  Text `json:"price"`
			} `json:"regions"`
		} `json:"offers"`
	}
	if err := c.get(ctx, "read a Steam gift", "/steam-gifts/games/"+url.PathEscape(appID), nil, &answer); err != nil {
		return SteamGift{}, err
	}
	gift := SteamGift{AppID: int64(answer.AppID), Editions: make([]SteamGiftEdition, 0, len(answer.Offers))}
	for _, offer := range answer.Offers {
		if offer.SubID <= 0 {
			continue
		}
		edition := SteamGiftEdition{SubID: int64(offer.SubID), Name: offer.Name.String(), Prices: map[string]string{}}
		for _, region := range offer.Regions {
			if code := strings.ToUpper(strings.TrimSpace(region.Region.String())); code != "" {
				edition.Prices[code] = region.Price.String()
			}
		}
		gift.Editions = append(gift.Editions, edition)
	}
	return gift, nil
}

// --- the account ----------------------------------------------------------------

// Balance is the company's balance, in dollars to four places.
type Balance struct {
	Amount   string
	Currency string
}

// Balance reads the company's balance.
func (c *Client) Balance(ctx context.Context) (Balance, error) {
	var answer struct {
		Balance  Text `json:"balance"`
		Currency Text `json:"currency"`
	}
	if err := c.get(ctx, "read the balance", "/balance", nil, &answer); err != nil {
		return Balance{}, err
	}
	currency := strings.ToUpper(answer.Currency.String())
	if currency == "" {
		currency = "USD"
	}
	return Balance{Amount: answer.Balance.String(), Currency: currency}, nil
}

// Account is the profile behind the key, and whether its paid plan is active
// (nothing can be bought while it is not).
type Account struct {
	Login              string
	Plan               string
	PlanExpiresAt      string
	SubscriptionActive bool
}

// Me reads the account behind the key.
func (c *Client) Me(ctx context.Context) (Account, error) {
	var answer struct {
		Login              Text `json:"login"`
		Plan               Text `json:"plan"`
		PlanExpiresAt      Text `json:"planExpiresAt"`
		SubscriptionActive bool `json:"subscriptionActive"`
	}
	if err := c.get(ctx, "read the account", "/me", nil, &answer); err != nil {
		return Account{}, err
	}
	return Account{
		Login: answer.Login.String(), Plan: answer.Plan.String(),
		PlanExpiresAt: answer.PlanExpiresAt.String(), SubscriptionActive: answer.SubscriptionActive,
	}, nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	return ""
}
