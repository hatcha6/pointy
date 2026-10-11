package control

import (
	"context"
	"math/big"
	"strings"
)

// FinancePosition is what stands, right now, between the company's profit and
// the money that is the owners' to take. The profit counts every service a
// shop paid for; some of that never reached the company as money:
//
//   - a shop that spent more than it paid in owes the difference (ShopsOwe);
//   - a charge for a card still being bought, or a text whose fate Resala has
//     not told yet, can still come back to the shop (InFlight);
//   - a credit given as compensation was spent as if it were money, and none
//     came in for it (Goodwill).
//
// Wallet balances are read from the ledger's real entries only: a test
// gateway's top-up was never money.
type FinancePosition struct {
	// ShopsHold is the shops' own money, unspent: never the company's.
	ShopsHold string `json:"shops_hold"`
	// ShopsOwe is what shops spent beyond what they paid in.
	ShopsOwe   string `json:"shops_owe"`
	OwingShops int    `json:"owing_shops"`
	InFlight   string `json:"in_flight"`
	Goodwill   string `json:"goodwill"`
	// StockCost is what the company paid for card codes still on its shelf:
	// money already spent, back only when they sell.
	StockCost string `json:"stock_cost"`
	// Manual is every unvoided hand-written line, all time, by direction.
	Manual map[string]string `json:"manual"`
}

// GoodwillStatementPrefix starts the statement line of a credit given as
// compensation (the console's «تعويض» source, money-dialogs.tsx). Keep the
// two in step.
const GoodwillStatementPrefix = "تعويض من دفتر"

// addBalances turns each shop's real balance into what shops hold and
// what they owe. A shop's accounts are netted: a debt on its SMS account is
// taken from its main wallet's next transfer.
func (p *FinancePosition) addBalances(balances map[string]*big.Rat) {
	hold, owe := new(big.Rat), new(big.Rat)
	for _, balance := range balances {
		switch balance.Sign() {
		case 1:
			hold.Add(hold, balance)
		case -1:
			owe.Sub(owe, balance)
			p.OwingShops++
		}
	}
	p.ShopsHold, p.ShopsOwe = FormatWalletAmount(hold), FormatWalletAmount(owe)
}

func ratOrZero(raw string) *big.Rat {
	value, ok := new(big.Rat).SetString(strings.TrimSpace(raw))
	if !ok {
		return new(big.Rat)
	}
	return value
}

func isGoodwillCredit(entry WalletEntry) bool {
	return entry.Kind == WalletEntryAdjustment && !entry.TestMode &&
		ratOrZero(entry.Amount).Sign() > 0 &&
		strings.HasPrefix(strings.TrimSpace(entry.Description), GoodwillStatementPrefix)
}

func (s *FileStore) FinancePosition(_ context.Context) (FinancePosition, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var position FinancePosition
	balances := map[string]*big.Rat{}
	goodwill, inFlight, stock := new(big.Rat), new(big.Rat), new(big.Rat)
	for _, entry := range s.data.WalletEntries {
		if entry.TestMode {
			continue
		}
		if balances[entry.InstallationID] == nil {
			balances[entry.InstallationID] = new(big.Rat)
		}
		balances[entry.InstallationID].Add(balances[entry.InstallationID], ratOrZero(entry.Amount))
		if isGoodwillCredit(entry) {
			goodwill.Add(goodwill, ratOrZero(entry.Amount))
		}
	}
	position.addBalances(balances)
	for _, purchase := range s.data.VoucherPurchases {
		if purchase.Status == VoucherPurchasePending && !purchase.TestMode {
			inFlight.Add(inFlight, ratOrZero(purchase.Amount))
		}
	}
	for _, message := range s.data.SMSMessages {
		if !message.TestMode && (message.Status == SMSStatusPending || message.HeldSince != nil) {
			inFlight.Add(inFlight, ratOrZero(message.Price))
		}
	}
	for _, code := range s.data.VoucherStock {
		if code.Status == VoucherStockAvailable {
			stock.Add(stock, ratOrZero(code.Cost))
		}
	}
	manual := map[string]*big.Rat{}
	for _, entry := range s.data.FinanceEntries {
		if entry.VoidedAt == nil {
			addRat(manual, entry.Direction, entry.Amount)
		}
	}
	position.Goodwill = FormatWalletAmount(goodwill)
	position.InFlight = FormatWalletAmount(inFlight)
	position.StockCost = FormatWalletAmount(stock)
	position.Manual = formatRats(manual)
	return position, nil
}

func (s *PostgresStore) FinancePosition(ctx context.Context) (FinancePosition, error) {
	var position FinancePosition
	balances := map[string]*big.Rat{}
	rows, err := s.pool.Query(ctx, `SELECT installation_id, SUM(amount)::text
		FROM relay_wallet_entries WHERE NOT test_mode GROUP BY 1`)
	if err != nil {
		return FinancePosition{}, err
	}
	for rows.Next() {
		var id, amount string
		if err := rows.Scan(&id, &amount); err != nil {
			rows.Close()
			return FinancePosition{}, err
		}
		balances[id] = ratOrZero(amount)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return FinancePosition{}, err
	}
	position.addBalances(balances)

	var goodwill, inFlight, stock string
	err = s.pool.QueryRow(ctx, `SELECT
		(SELECT COALESCE(SUM(amount), 0)::text FROM relay_wallet_entries
			WHERE kind = 'adjustment' AND amount > 0 AND NOT test_mode
				AND starts_with(btrim(description), $1)),
		((SELECT COALESCE(SUM(amount), 0) FROM relay_voucher_purchases
			WHERE status = 'pending' AND NOT test_mode)
		+ (SELECT COALESCE(SUM(price), 0) FROM relay_sms_messages
			WHERE NOT test_mode AND (status = 'pending' OR held_since IS NOT NULL)))::text,
		(SELECT COALESCE(SUM(cost), 0)::text FROM relay_voucher_stock WHERE status = 'available')`,
		GoodwillStatementPrefix,
	).Scan(&goodwill, &inFlight, &stock)
	if err != nil {
		return FinancePosition{}, err
	}
	position.Goodwill = FormatWalletAmount(ratOrZero(goodwill))
	position.InFlight = FormatWalletAmount(ratOrZero(inFlight))
	position.StockCost = FormatWalletAmount(ratOrZero(stock))

	manual := map[string]*big.Rat{}
	rows, err = s.pool.Query(ctx, `SELECT direction, SUM(amount)::text
		FROM relay_finance_entries WHERE voided_at IS NULL GROUP BY 1`)
	if err != nil {
		return FinancePosition{}, err
	}
	for rows.Next() {
		var direction, amount string
		if err := rows.Scan(&direction, &amount); err != nil {
			rows.Close()
			return FinancePosition{}, err
		}
		addRat(manual, direction, amount)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return FinancePosition{}, err
	}
	position.Manual = formatRats(manual)
	return position, nil
}
