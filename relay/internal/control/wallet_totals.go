package control

import (
	"context"
	"fmt"
	"math/big"
)

// WalletTotals is the optional capability to add up one wallet account across
// every shop: what the shops together can still spend from it. The voucher
// account's total is money the company has promised to turn into cards, so
// the supplier balance must cover it.
type WalletTotals interface {
	// WalletAccountTotal sums the positive balances of account and counts
	// the shops holding one.
	WalletAccountTotal(ctx context.Context, account string) (*big.Rat, int, error)
}

func (s *FileStore) WalletAccountTotal(_ context.Context, account string) (*big.Rat, int, error) {
	account = NormalizeWalletAccount(account)
	if !ValidWalletAccount(account) {
		return nil, 0, fmt.Errorf("unknown wallet account %q", account)
	}
	s.mu.RLock()
	defer s.mu.RUnlock()

	total, shops := new(big.Rat), 0
	seen := map[string]bool{}
	for _, entry := range s.data.WalletEntries {
		if seen[entry.InstallationID] || NormalizeWalletAccount(entry.Account) != account {
			continue
		}
		seen[entry.InstallationID] = true
		if balance, _ := s.walletBalanceLocked(entry.InstallationID, account); balance.Sign() > 0 {
			total.Add(total, balance)
			shops++
		}
	}
	return total, shops, nil
}

func (s *PostgresStore) WalletAccountTotal(ctx context.Context, account string) (*big.Rat, int, error) {
	account = NormalizeWalletAccount(account)
	if !ValidWalletAccount(account) {
		return nil, 0, fmt.Errorf("unknown wallet account %q", account)
	}
	query := `SELECT COALESCE(SUM(balance) FILTER (WHERE balance > 0), 0)::text, COUNT(*) FILTER (WHERE balance > 0)
		FROM relay_wallet_accounts WHERE account = $1`
	args := []any{account}
	if account == WalletAccountMain {
		query = `SELECT COALESCE(SUM(balance) FILTER (WHERE balance > 0), 0)::text, COUNT(*) FILTER (WHERE balance > 0)
			FROM relay_wallets`
		args = nil
	}
	var raw string
	var shops int
	if err := s.pool.QueryRow(ctx, query, args...).Scan(&raw, &shops); err != nil {
		return nil, 0, err
	}
	total, ok := new(big.Rat).SetString(raw)
	if !ok {
		return nil, 0, fmt.Errorf("wallet total %q is not a number", raw)
	}
	return total, shops, nil
}
