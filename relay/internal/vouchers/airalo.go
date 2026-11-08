package vouchers

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"

	"pointy/relay/internal/airalo"
)

// SupplierAiralo is Airalo: eSIMs and their top-ups, paid in dollars from the
// company's account there. Its catalog is not the card catalog (thousands of
// plans, by destination): the relay's eSIM shelf reads it directly, and no card
// item can name this supplier. It is a supplier so that buying, the books and
// the reconciler treat an eSIM as any other purchase.
const SupplierAiralo = "airalo"

const (
	airaloRefSIM   = "sim/"
	airaloRefTopUp = "topup/"
)

// AiraloSIMRef is the ref of a first eSIM on a package.
func AiraloSIMRef(packageID string) Ref {
	return Ref{Supplier: SupplierAiralo, ID: airaloRefSIM + packageID}
}

// AiraloTopUpRef is the ref of a top-up package for an issued eSIM.
func AiraloTopUpRef(iccid, packageID string) Ref {
	return Ref{Supplier: SupplierAiralo, ID: airaloRefTopUp + iccid + "/" + packageID}
}

// AiraloSupplier buys through the Partner API. Each purchase is one eSIM.
type AiraloSupplier struct {
	Client *airalo.Client
	// Brand is the partner brand eSIMs Cloud pages are shown under (Partner
	// Platform, brand settings); empty is unbranded.
	Brand string
}

func (s *AiraloSupplier) Key() string { return SupplierAiralo }

// Buy places the order once. clientRef goes in the order's description, which
// is how Find sees it again when the answer is lost. An order is never resent
// here: an answer that proves nothing (a timeout, code 83, a 5xx) leaves the
// purchase open for the reconciler, which looks the order up before anything
// else happens. With the purchase's claim row, that is what keeps a customer
// from being sold, or the company charged for, two eSIMs.
func (s *AiraloSupplier) Buy(ctx context.Context, ref Ref, quantity int, clientRef string) (Purchase, error) {
	if quantity != 1 {
		return Purchase{}, &Failure{Code: FailureRefused, Detail: "an eSIM purchase is for one eSIM", Definite: true}
	}
	var order airalo.Order
	var err error
	switch {
	case strings.HasPrefix(ref.ID, airaloRefSIM):
		order, err = s.Client.SubmitOrder(ctx, strings.TrimPrefix(ref.ID, airaloRefSIM), clientRef, s.Brand)
	case strings.HasPrefix(ref.ID, airaloRefTopUp):
		iccid, packageID, ok := strings.Cut(strings.TrimPrefix(ref.ID, airaloRefTopUp), "/")
		if !ok {
			return Purchase{}, &Failure{Code: FailureRefused, Detail: "a malformed top-up ref", Definite: true}
		}
		order, err = s.Client.SubmitTopUp(ctx, packageID, iccid, clientRef)
	default:
		return Purchase{}, &Failure{Code: FailureRefused, Detail: "a malformed eSIM ref", Definite: true}
	}
	if err != nil {
		return Purchase{}, airaloFailure(err)
	}
	return airaloPurchase(ref, order), nil
}

// airaloFailure sorts Airalo's error table into what the ledger needs: whether
// the money can come back now.
func airaloFailure(err error) error {
	code := FailureUnknown
	var apiErr *airalo.APIError
	if errors.As(err, &apiErr) {
		switch {
		case apiErr.Code == airalo.CodeInsufficientCredit:
			code = FailureCredit
		case apiErr.Code == airalo.CodeOutOfStock || apiErr.Code == airalo.CodeNotEnoughStock:
			code = FailureOutOfStock
		case apiErr.Status == 401 || apiErr.Status == 403:
			code = FailureUnauthorized
		case airalo.DefinitelyNotOrdered(err):
			code = FailureRefused
		}
	}
	return &Failure{Code: code, Detail: err.Error(), Definite: airalo.DefinitelyNotOrdered(err)}
}

// airaloPurchase turns an order into the ledger's words. A code is the eSIM's
// activation string with its ICCID as the serial; a top-up has neither, so its
// one "code" just says the purchase went through.
func airaloPurchase(ref Ref, order airalo.Order) Purchase {
	purchase := Purchase{
		OrderID:  order.ID.String(),
		Status:   StatusPending,
		Cost:     airaloCost(order),
		Currency: strings.ToUpper(strings.TrimSpace(order.Currency)),
		Codes:    []Code{},
	}
	if purchase.Currency == "" {
		purchase.Currency = "USD"
	}
	if at, err := time.Parse("2006-01-02 15:04:05", order.CreatedAt); err == nil {
		purchase.At = at
	}
	status := ""
	if order.Status != nil {
		status = order.Status.Slug
	}
	switch status {
	case "failed", "refunded", "cancelled", "canceled":
		purchase.Status = StatusFailed
		purchase.Message = "airalo reports the order " + status
		return purchase
	}
	if strings.HasPrefix(ref.ID, airaloRefTopUp) {
		iccid, _, _ := strings.Cut(strings.TrimPrefix(ref.ID, airaloRefTopUp), "/")
		purchase.Status = StatusSucceeded
		purchase.Codes = []Code{{Code: "topup", Serial: iccid}}
		return purchase
	}
	for _, sim := range order.SIMs {
		purchase.Codes = append(purchase.Codes, Code{Code: sim.QRCode, Serial: sim.ICCID})
	}
	if len(purchase.Codes) > 0 {
		purchase.Status = StatusSucceeded
	}
	return purchase
}

// airaloCost is what the order cost the company: the discounted total where the
// account is on discount pricing, else the net price, else the price.
func airaloCost(order airalo.Order) string {
	for _, cost := range []airalo.Number{order.PaidPrice, order.NetPrice, order.Price} {
		if cost != "" {
			return cost.String()
		}
	}
	return ""
}

// Lookup reads an order by Airalo's id.
func (s *AiraloSupplier) Lookup(ctx context.Context, ref Ref, orderID string) (Purchase, error) {
	order, err := s.Client.Order(ctx, orderID)
	if err != nil {
		return Purchase{}, err
	}
	return airaloPurchase(ref, order), nil
}

// FindByClientRef finds the order a purchase placed, by its description.
// Airalo filters with a LIKE, so only an exact match counts.
func (s *AiraloSupplier) FindByClientRef(ctx context.Context, ref Ref, clientRef string, _, _ time.Time) ([]Purchase, error) {
	orders, err := s.Client.FindOrders(ctx, clientRef)
	if err != nil {
		return nil, err
	}
	found := make([]Purchase, 0, 1)
	for _, order := range orders {
		if strings.TrimSpace(order.Description) == clientRef {
			found = append(found, airaloPurchase(ref, order))
		}
	}
	return found, nil
}

// Find is never the way an Airalo order is found (FindByClientRef is exact):
// asked anyway, it knows of none it can name without a reference.
func (s *AiraloSupplier) Find(context.Context, Ref, int, time.Time, time.Time) ([]Purchase, error) {
	return nil, errors.New("airalo orders are found by their reference")
}

// Offers is empty: the eSIM shelf has its own catalog sync.
func (s *AiraloSupplier) Offers(context.Context) ([]Offer, error) { return []Offer{}, nil }

// ESIMPrice is what a customer pays for a plan, in dinars. Airalo recommends a
// retail price in dollars; the shelf sells at rrpPercent of it at today's rate,
// and never below what the operator's margin asks on the net cost, so a thin
// plan or a dear dollar cannot sell at a loss. ok is false when the plan has no
// net price or the margin policy does not read.
func ESIMPrice(netUSD, rrpUSD, rate *big.Rat, margin Margin, rrpPercent *big.Rat) (*big.Rat, bool) {
	if netUSD == nil || rate == nil || netUSD.Sign() <= 0 || rate.Sign() <= 0 {
		return nil, false
	}
	cost := new(big.Rat).Mul(netUSD, rate)
	floor, ok := margin.Prices(cost)
	if !ok || floor.Retail == nil {
		return nil, false
	}
	price := floor.Retail
	if rrpUSD != nil && rrpPercent != nil && rrpUSD.Sign() > 0 {
		recommended := new(big.Rat).Mul(new(big.Rat).Mul(rrpUSD, rate), rrpPercent)
		recommended.Quo(recommended, big.NewRat(100, 1))
		if parsed, parsedOK := margin.parse(); parsedOK {
			recommended = settingsCeil(recommended, parsed.step)
		}
		if recommended.Cmp(price) > 0 {
			price = recommended
		}
	}
	return price, true
}

// AiraloDollars reads a dollar figure from Airalo into a rational.
func AiraloDollars(value float64) *big.Rat {
	if value <= 0 {
		return nil
	}
	rat, ok := new(big.Rat).SetString(fmt.Sprintf("%.4f", value))
	if !ok {
		return nil
	}
	return rat
}
