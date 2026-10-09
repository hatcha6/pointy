package alerts

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"strings"

	"pointy/relay/internal/bnplus"
	"pointy/relay/internal/reloadly"
)

// ReloadlyBalance reads the company's Reloadly account: one dollar balance
// shared by gift cards, top-ups and bills.
func ReloadlyBalance(client *reloadly.Client) func(context.Context) (*big.Rat, error) {
	return func(ctx context.Context) (*big.Rat, error) {
		balance, err := client.GiftBalance(ctx)
		if err != nil {
			return nil, err
		}
		amount, ok := balance.Balance.Rat()
		if !ok {
			return nil, fmt.Errorf("reloadly balance %q is not a number", balance.Balance.String())
		}
		return amount, nil
	}
}

// BNPlusBalance reads the company's BN Plus wallet in currency ("LYD").
func BNPlusBalance(client *bnplus.Client, currency string) func(context.Context) (*big.Rat, error) {
	return func(ctx context.Context) (*big.Rat, error) {
		wallets, err := client.Wallets(ctx)
		if err != nil {
			return nil, err
		}
		for _, wallet := range wallets {
			if !strings.EqualFold(wallet.Currency, currency) {
				continue
			}
			amount, ok := new(big.Rat).SetString(strings.TrimSpace(wallet.Balance))
			if !ok {
				return nil, fmt.Errorf("bn plus %s balance %q is not a number", currency, wallet.Balance)
			}
			return amount, nil
		}
		return nil, fmt.Errorf("bn plus has no %s wallet", currency)
	}
}

// OpenRouterBalance reads the dollars left at OpenRouter. With a management
// key it is the account's credits less its usage (GET /credits, which only a
// management key may read); without one, what is left under the API key's own
// limit (GET /key), which is all an ordinary key can see.
func OpenRouterBalance(client *http.Client, baseURL, apiKey, managementKey string) func(context.Context) (*big.Rat, error) {
	baseURL = strings.TrimRight(strings.TrimSpace(baseURL), "/")
	return func(ctx context.Context) (*big.Rat, error) {
		if key := strings.TrimSpace(managementKey); key != "" {
			var answer struct {
				Data struct {
					TotalCredits json.Number `json:"total_credits"`
					TotalUsage   json.Number `json:"total_usage"`
				} `json:"data"`
			}
			if err := getJSON(ctx, client, baseURL+"/credits", "Authorization", "Bearer "+key, &answer); err != nil {
				return nil, err
			}
			credits, ok1 := new(big.Rat).SetString(answer.Data.TotalCredits.String())
			usage, ok2 := new(big.Rat).SetString(answer.Data.TotalUsage.String())
			if !ok1 || !ok2 {
				return nil, errors.New("openrouter credits answer has no numbers")
			}
			return credits.Sub(credits, usage), nil
		}
		var answer struct {
			Data struct {
				LimitRemaining *json.Number `json:"limit_remaining"`
			} `json:"data"`
		}
		if err := getJSON(ctx, client, baseURL+"/key", "Authorization", "Bearer "+strings.TrimSpace(apiKey), &answer); err != nil {
			return nil, err
		}
		if answer.Data.LimitRemaining == nil {
			return nil, errors.New("the openrouter key has no credit limit; set POINTY_RELAY_OPENROUTER_MANAGEMENT_KEY to read the account's credits")
		}
		remaining, ok := new(big.Rat).SetString(answer.Data.LimitRemaining.String())
		if !ok {
			return nil, errors.New("openrouter limit_remaining is not a number")
		}
		return remaining, nil
	}
}

// SerperBalance reads the search credits left at Serper (GET /account on the
// host of the images endpoint the relay already uses).
func SerperBalance(client *http.Client, endpoint, apiKey string) func(context.Context) (*big.Rat, error) {
	accountURL := "https://google.serper.dev/account"
	if parsed, err := url.Parse(strings.TrimSpace(endpoint)); err == nil && parsed.Host != "" {
		accountURL = parsed.Scheme + "://" + parsed.Host + "/account"
	}
	return func(ctx context.Context) (*big.Rat, error) {
		var answer struct {
			Balance *json.Number `json:"balance"`
		}
		if err := getJSON(ctx, client, accountURL, "X-API-KEY", strings.TrimSpace(apiKey), &answer); err != nil {
			return nil, err
		}
		if answer.Balance == nil {
			return nil, errors.New("serper account answer has no balance")
		}
		balance, ok := new(big.Rat).SetString(answer.Balance.String())
		if !ok {
			return nil, errors.New("serper balance is not a number")
		}
		return balance, nil
	}
}

func getJSON(ctx context.Context, client *http.Client, target, header, value string, into any) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return err
	}
	request.Header.Set(header, value)
	request.Header.Set("Accept", "application/json")
	if client == nil {
		client = http.DefaultClient
	}
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return err
	}
	if response.StatusCode/100 != 2 {
		return fmt.Errorf("%s answered %d: %s", request.URL.Host, response.StatusCode, truncate(strings.TrimSpace(string(raw)), 200))
	}
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.UseNumber()
	return decoder.Decode(into)
}
