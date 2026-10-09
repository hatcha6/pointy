package services

import (
	"context"
	"errors"
	"strings"
	"sync"

	"pointy/relay/internal/reloadly"
)

// ReloadlySource reads the directory from Reloadly: the countries it tops up,
// every operator (all pages) and every biller. The three reads run side by side;
// any one failing fails the whole reading, so the directory is never half new.
type ReloadlySource struct {
	Client *reloadly.Client
}

// Load implements Source.
func (s ReloadlySource) Load(ctx context.Context) (Raw, error) {
	var (
		raw  Raw
		wg   sync.WaitGroup
		mu   sync.Mutex
		errs []error
	)
	run := func(read func() error) {
		defer wg.Done()
		if err := read(); err != nil {
			mu.Lock()
			errs = append(errs, err)
			mu.Unlock()
		}
	}
	wg.Add(3)
	go run(func() (err error) { raw.Countries, err = s.Client.TopupCountries(ctx); return })
	go run(func() (err error) { raw.Operators, err = s.Client.Operators(ctx); return })
	go run(func() (err error) { raw.Billers, err = s.Client.Billers(ctx); return })
	wg.Wait()
	if len(errs) > 0 {
		return Raw{}, errors.Join(errs...)
	}
	return raw, nil
}

// ReloadlyDetector finds an operator by asking Reloadly, which matches the
// prefixes of every operator it serves.
type ReloadlyDetector struct {
	Client *reloadly.Client
}

// Detect implements Detector. The number goes as country code plus national
// digits, the form Reloadly accepts everywhere (a trunk zero it accepts only where
// the country has one).
func (d ReloadlyDetector) Detect(ctx context.Context, country string, phone Phone) (int64, error) {
	operator, err := d.Client.DetectOperator(ctx, country, phone.Digits())
	if err != nil {
		var api *reloadly.APIError
		if errors.As(err, &api) && api.Structured() && api.Status >= 400 && api.Status < 500 &&
			api.Status != 401 && api.Status != 429 && !errors.Is(err, reloadly.ErrUnauthorized) {
			// 404 COULD_NOT_AUTO_DETECT_OPERATOR, 409 COUNTRY_NOT_SUPPORTED, a
			// number Reloadly finds invalid: no operator for this number.
			return 0, ErrNotDetected
		}
		return 0, err
	}
	if operator.Key() == 0 || strings.TrimSpace(operator.Name) == "" {
		return 0, ErrNotDetected
	}
	return operator.Key(), nil
}

// ProductBalance is the company's balance as one Reloadly product reports it.
type ProductBalance struct {
	Product  string `json:"product"`
	Balance  string `json:"balance,omitempty"`
	Frozen   string `json:"frozen,omitempty"`
	Currency string `json:"currency,omitempty"`
	Error    string `json:"error,omitempty"`
}

// BalanceReader reads the company's balance at the supplier.
type BalanceReader interface {
	Balances(ctx context.Context) []ProductBalance
}

// ReloadlyBalances reads the balance through each of the three products. It is
// one USD account; the three readings differ only if a product is unreachable.
type ReloadlyBalances struct {
	Client *reloadly.Client
}

// Balances implements BalanceReader.
func (b ReloadlyBalances) Balances(ctx context.Context) []ProductBalance {
	reads := []struct {
		product string
		read    func(context.Context) (reloadly.Balance, error)
	}{
		{"giftcards", b.Client.GiftBalance},
		{"topups", b.Client.TopupBalance},
		{"utilities", b.Client.UtilityBalance},
	}
	out := make([]ProductBalance, len(reads))
	var wg sync.WaitGroup
	for i, item := range reads {
		wg.Add(1)
		go func() {
			defer wg.Done()
			balance, err := item.read(ctx)
			out[i] = ProductBalance{Product: item.product}
			if err != nil {
				out[i].Error = err.Error()
				return
			}
			out[i].Currency = balance.CurrencyCode
			if value := rat(balance.Balance); value != nil {
				out[i].Balance = FormatAmount(value)
			}
			if value := rat(balance.FrozenBalance); value != nil {
				out[i].Frozen = FormatAmount(value)
			}
		}()
	}
	wg.Wait()
	return out
}
