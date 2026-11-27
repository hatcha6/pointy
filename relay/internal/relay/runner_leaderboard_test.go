package relay

import (
	"net/http"
	"strings"
	"testing"
)

func TestTheWaitingGameKeepsAWeeklyAndAllTimeBoard(t *testing.T) {
	h := newOrderHarness(t)
	ada := h.customer("0911000001")
	bea := h.customer("0911000002")

	run := func(token string, score, coins, seconds int) (int, map[string]any) {
		return h.do(http.MethodPost, "/v1/customers/me/runner", token,
			map[string]any{"score": score, "coins": coins, "seconds": seconds})
	}
	if status, body := run(ada, 640, 4, 40); status != http.StatusOK || body["best"] != true {
		t.Fatalf("first run: %d %v", status, body)
	}
	if _, body := run(ada, 300, 0, 30); body["best"] != false {
		t.Fatalf("a worse run is not a best: %v", body)
	}
	run(bea, 900, 10, 50)

	// Far more points than the game can give in that time: refused, unsaved.
	if status, body := run(bea, 50000, 0, 10); status != http.StatusUnprocessableEntity || body["code"] != "implausible_run" {
		t.Fatalf("forged run: %d %v", status, body)
	}
	if status, _ := run(bea, 100, 200, 10); status != http.StatusUnprocessableEntity {
		t.Fatal("more coin points than the score")
	}

	for _, period := range []string{"week", "all"} {
		status, body := h.do(http.MethodGet, "/v1/customers/runner/leaderboard?period="+period, ada, nil)
		if status != http.StatusOK {
			t.Fatalf("%s board: %d %v", period, status, body)
		}
		entries := body["entries"].([]any)
		if len(entries) != 2 {
			t.Fatalf("%s entries = %v", period, entries)
		}
		top := entries[0].(map[string]any)
		second := entries[1].(map[string]any)
		if top["score"] != float64(900) || top["me"] != false || second["me"] != true {
			t.Fatalf("%s order = %v", period, entries)
		}
		me := body["me"].(map[string]any)
		if me["rank"] != float64(2) || me["score"] != float64(640) {
			t.Fatalf("%s me = %v", period, me)
		}
		// An alias, never a phone number.
		name := top["name"].(string)
		if name == "" || strings.ContainsAny(name, "0123456789") || name != RunnerAlias(customerIDOf(t, h, bea)) {
			t.Fatalf("alias = %q", name)
		}
	}

	if status, _ := h.do(http.MethodGet, "/v1/customers/runner/leaderboard?period=year", ada, nil); status != http.StatusBadRequest {
		t.Fatal("an unknown period")
	}
	if status, _ := h.do(http.MethodGet, "/v1/customers/runner/leaderboard", "", nil); status != http.StatusUnauthorized {
		t.Fatal("the board is for signed-in customers")
	}

	// Deleting the account takes its runs off the board.
	if status, _ := h.do(http.MethodDelete, "/v1/customers/me", bea, nil); status != http.StatusNoContent {
		t.Fatal("delete")
	}
	_, body := h.do(http.MethodGet, "/v1/customers/runner/leaderboard?period=all", ada, nil)
	if entries := body["entries"].([]any); len(entries) != 1 {
		t.Fatalf("after deletion = %v", entries)
	}
}

func TestRunnerAliasesAreStableAndVaried(t *testing.T) {
	if RunnerAlias("c-1") != RunnerAlias("c-1") {
		t.Fatal("the same customer, the same name")
	}
	seen := map[string]bool{}
	for _, id := range []string{"a", "b", "c", "d", "e", "f", "g", "h"} {
		seen[RunnerAlias(id)] = true
	}
	if len(seen) < 6 {
		t.Fatalf("aliases barely vary: %v", seen)
	}
}
