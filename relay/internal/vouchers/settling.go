package vouchers

import "context"

type settlingKey struct{}

// WithoutSettling marks a purchase whose buyer follows the order on its own
// (the cards app's order page asks every few seconds): a supplier that would
// wait a few seconds for a just-taken order to finish answers at once
// instead, pending, and the order is read back as it is asked about.
func WithoutSettling(ctx context.Context) context.Context {
	return context.WithValue(ctx, settlingKey{}, false)
}

// Settles reports whether a supplier may wait for a just-taken order to
// finish before answering.
func Settles(ctx context.Context) bool {
	wait, ok := ctx.Value(settlingKey{}).(bool)
	return !ok || wait
}
