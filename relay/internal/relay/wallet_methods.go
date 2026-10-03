package relay

import (
	"fmt"
	"strings"

	"pointy/relay/internal/control"
	"pointy/relay/internal/dafa"
)

// The ways a shop pays into its wallet. Each is one Dafa provider under the
// relay's own name for it, so the shop's backend and app never learn a
// gateway's identifiers and a second gateway could sit beside this one.

// What the payer does after a top-up starts.
const (
	// walletKindOTP: the provider texts the payer a code, the app sends it.
	walletKindOTP = "otp"
	// walletKindHostedPage: the payer pays on the gateway's own page in the
	// browser, and the relay learns the outcome from the gateway.
	walletKindHostedPage = "hosted_page"
)

type walletMethod struct {
	Key      string
	Provider dafa.Provider
	// NameAr is the method as the shop's statement names it.
	NameAr string
}

func (m walletMethod) kind() string {
	if m.Provider.HostedPage {
		return walletKindHostedPage
	}
	return walletKindOTP
}

func mustDafaProvider(id string) dafa.Provider {
	provider, ok := dafa.LookupProvider(id)
	if !ok {
		panic("unknown dafa provider " + id)
	}
	return provider
}

// walletMethods is the default offer, in the order the app shows it: the bank
// cards nearly every owner holds, then the mobile wallets. The operator's
// POINTY_RELAY_WALLET_METHODS narrows and reorders it.
var walletMethods = []walletMethod{
	{Key: control.WalletTopUpMethodDafaMoamalat, Provider: mustDafaProvider(dafa.ProviderMoamalat), NameAr: "البطاقات المصرفية"},
	{Key: control.WalletTopUpMethodDafaSadad, Provider: mustDafaProvider(dafa.ProviderSadad), NameAr: "سداد"},
	{Key: control.WalletTopUpMethodDafaEdfali, Provider: mustDafaProvider(dafa.ProviderEdfali), NameAr: "إدفعلي"},
	{Key: control.WalletTopUpMethodDafaMobiCash, Provider: mustDafaProvider(dafa.ProviderMobiCash), NameAr: "موبي كاش"},
	{Key: control.WalletTopUpMethodDafaYussorPay, Provider: mustDafaProvider(dafa.ProviderYussorPay), NameAr: "يسر باي"},
	{Key: control.WalletTopUpMethodDafaMasrafiPay, Provider: mustDafaProvider(dafa.ProviderMasrafiPay), NameAr: "مصرفي باي"},
	{Key: control.WalletTopUpMethodDafaSaharaPay, Provider: mustDafaProvider(dafa.ProviderSaharaPay), NameAr: "صحارى باي"},
}

func lookupWalletMethod(key string) (walletMethod, bool) {
	for _, method := range walletMethods {
		if method.Key == key {
			return method, true
		}
	}
	return walletMethod{}, false
}

// ParseWalletMethods reads the operator's list of methods to offer: method
// keys (dafa_sadad) or Dafa's own provider names (sadad, yussor-pay), comma
// separated, in the order to show them. Empty offers every method.
func ParseWalletMethods(spec string) ([]string, error) {
	var keys []string
	seen := map[string]bool{}
	for _, raw := range strings.Split(spec, ",") {
		name := strings.ToLower(strings.TrimSpace(raw))
		if name == "" {
			continue
		}
		method, ok := lookupWalletMethod(name)
		if !ok {
			for _, candidate := range walletMethods {
				if candidate.Provider.ID == name {
					method, ok = candidate, true
					break
				}
			}
		}
		if !ok {
			return nil, fmt.Errorf("unknown wallet method %q (known: %s)", name, strings.Join(walletMethodKeys(), ", "))
		}
		if !seen[method.Key] {
			seen[method.Key] = true
			keys = append(keys, method.Key)
		}
	}
	return keys, nil
}

func walletMethodKeys() []string {
	keys := make([]string, 0, len(walletMethods))
	for _, method := range walletMethods {
		keys = append(keys, method.Key)
	}
	return keys
}

// maskWalletPayer is the payer as the relay keeps it: the phone's network
// prefix and last three digits, a card's last four. Enough for an owner to
// recognise, never enough to reuse.
func maskWalletPayer(payer dafa.Payer, normalized string) string {
	switch {
	case payer == dafa.PayerPhone && len(normalized) == 9:
		return "0" + normalized[:2] + "•••" + normalized[6:]
	case payer == dafa.PayerCard && len(normalized) >= 4:
		return "•••• " + normalized[len(normalized)-4:]
	}
	return ""
}
