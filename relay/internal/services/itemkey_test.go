package services

import "testing"

// A replayed request is compared with the row its key already names. The row
// carries the plan the amount RESOLVED to; the request, when it named the plan
// by its amount alone, does not.
func TestARequestAndTheRowItResolvedToAreTheSameItem(t *testing.T) {
	for _, c := range []struct {
		name            string
		stored, request string
		same            bool
	}{
		{"an airtime order", "airtime:289:5000:XOF", "airtime:289:5000:XOF", true},
		{"another amount", "airtime:289:5000:XOF", "airtime:289:2000:XOF", false},
		{"another operator", "airtime:289:5000:XOF", "airtime:290:5000:XOF", false},
		{"another currency", "airtime:289:5000:XOF", "airtime:289:5000:USD", false},
		{"a range bill", "bill:26:5000:XOF", "bill:26:5000:XOF", true},
		{"a plan named by id", "bill:27:10000:XOF:3", "bill:27:10000:XOF:3", true},
		{"a plan named by its amount alone", "bill:27:10000:XOF:3", "bill:27:10000:XOF", true},
		{"another plan", "bill:27:10000:XOF:3", "bill:27:10000:XOF:7", false},
		{"another plan amount", "bill:27:10000:XOF:3", "bill:27:11000:XOF", false},
		{"another amount with the same plan id", "bill:27:10000:XOF:3", "bill:27:11000:XOF:3", false},
		{"another biller", "bill:27:10000:XOF:3", "bill:28:10000:XOF", false},
		{"a range biller given a plan id that means nothing", "bill:26:5000:XOF", "bill:26:5000:XOF:9", true},
		{"a bill and an airtime", "bill:26:5000:XOF", "airtime:26:5000:XOF", false},
		{"an airtime with a plan", "airtime:289:5000:XOF", "airtime:289:5000:XOF:3", false},
		{"a card's key", "itunes-us-10", "bill:26:5000:XOF", false},
		{"nothing", "", "bill:26:5000:XOF", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := SameItem(c.stored, c.request); got != c.same {
				t.Fatalf("SameItem(%q, %q) = %v", c.stored, c.request, got)
			}
		})
	}
}
