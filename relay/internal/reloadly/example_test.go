package reloadly_test

import (
	"context"
	"fmt"
	"math/big"
	"time"

	"pointy/relay/internal/reloadly"
)

// A top-up done the way every purchase here is done: one identifier per
// purchase, one attempt, and a read-back when the outcome is unknown.
func ExampleClient_Topup() {
	client, err := reloadly.New(reloadly.Config{ClientID: "id", ClientSecret: "secret", Sandbox: true})
	if err != nil {
		fmt.Println(err)
		return
	}
	ctx := context.Background()

	// Price it first. The operator comes from Operators/Operator/DetectOperator.
	var operator reloadly.Operator
	amount := big.NewRat(2000, 1) // 2000 XOF, ordered in the local currency
	cost, ok := reloadly.AirtimeCost(operator, amount, true)
	if !ok {
		fmt.Println("the operator does not sell this amount")
		return
	}
	_ = cost // what the company will be debited, in USD

	request := reloadly.TopupRequest{
		OperatorID:       operator.Key(),
		Amount:           reloadly.NumFromRat(amount, 5),
		UseLocalAmount:   true,
		CustomIdentifier: "pointy-4f1c9a", // unique to the purchase; never reused concurrently
		RecipientPhone:   reloadly.Phone{CountryCode: "ML", Number: "76123456"},
	}
	started := time.Now()
	result, err := client.Topup(ctx, request)
	switch {
	case err == nil && result.Status.Succeeded():
		// Done: result.Balance.Cost is the debit.
	case err == nil && result.Status.InProgress():
		// Accepted, not final: poll client.TopupStatus(ctx, result.TransactionID).
	case err == nil:
		// REFUNDED or FAILED: nothing was delivered or charged.
	case reloadly.IsInsufficientBalance(err):
		// The company's balance at Reloadly is too low: nothing happened.
	case reloadly.Definite(err):
		// Reloadly refused it (or it never left): give the shop its money back.
	default:
		// Unknown outcome. Read it back by the identifier before deciding;
		// do NOT send the purchase again while it may still be running.
		found, findErr := client.FindTopups(ctx, request.CustomIdentifier, started, time.Now())
		_, _ = found, findErr // none: nothing was done; one: its Status says
	}
}

// Prices are exact rationals; the Num of a catalog row converts without a float.
func ExampleNum_Rat() {
	rate := reloadly.Num("505.00000000000")
	value, _ := rate.Rat()
	fmt.Println(value.RatString(), reloadly.NumFromRat(new(big.Rat).Quo(big.NewRat(2000, 1), value), 5))
	// Output: 505 3.9604
}
