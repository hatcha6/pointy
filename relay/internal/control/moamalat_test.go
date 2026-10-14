package control

import (
	"context"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Runs against a real PostgreSQL when POINTY_RELAY_TEST_DATABASE_URL names a
// scratch database. The queue is the part a file store cannot prove: several
// instances claiming at once must each get a different row, every time.
func TestPostgresMoamalatQueue(t *testing.T) {
	url := os.Getenv("POINTY_RELAY_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("POINTY_RELAY_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err := MigratePostgres(ctx, pool); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `DELETE FROM relay_moamalat_links`); err != nil {
		t.Fatal(err)
	}
	store := &PostgresStore{pool: pool, clock: &fixedClock{now: time.Now()}}

	shops := []string{"inst-a", "inst-b", "inst-c", "inst-d", "inst-e", "inst-f"}
	for _, id := range shops {
		if _, err := store.PutMoamalatLink(ctx, MoamalatLink{InstallationID: id, MID: "m", TokenID: "t-" + id, SealedToken: "v1:x"}); err != nil {
			t.Fatal(err)
		}
	}

	// Four instances claim at once: every due row goes to exactly one.
	var mu sync.Mutex
	seen := map[string]int{}
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			claims, err := store.ClaimMoamalatPokes(ctx, 2, time.Minute)
			if err != nil {
				t.Error(err)
				return
			}
			mu.Lock()
			defer mu.Unlock()
			for _, claim := range claims {
				seen[claim.Link.InstallationID]++
			}
		}()
	}
	wg.Wait()
	for id, count := range seen {
		if count != 1 {
			t.Fatalf("%s claimed %d times", id, count)
		}
	}
	if len(seen) != len(shops) {
		t.Fatalf("claimed %d of %d", len(seen), len(shops))
	}
	// Leased: nothing is due until the lease runs out.
	if again, _ := store.ClaimMoamalatPokes(ctx, 50, time.Minute); len(again) != 0 {
		t.Fatalf("leased rows claimed again: %d", len(again))
	}

	// A poke result for a replaced token is dropped.
	if _, err := store.PutMoamalatLink(ctx, MoamalatLink{InstallationID: "inst-a", MID: "m", TokenID: "t-a2", SealedToken: "v1:y"}); err != nil {
		t.Fatal(err)
	}
	if _, applied, err := store.RecordMoamalatPoke(ctx, MoamalatPoke{InstallationID: "inst-a", TokenID: "t-inst-a", Outcome: "alive", NextIn: 4 * time.Minute}); err != nil || applied {
		t.Fatalf("stale poke applied=%v err=%v", applied, err)
	}
	if _, applied, err := store.MarkMoamalatDead(ctx, "inst-a", "t-inst-a", "relay"); err != nil || applied {
		t.Fatalf("stale death applied=%v err=%v", applied, err)
	}
	link, applied, err := store.RecordMoamalatPoke(ctx, MoamalatPoke{InstallationID: "inst-b", TokenID: "t-inst-b", Outcome: "transient", NextIn: 20 * time.Second, Error: "timeout"})
	if err != nil || !applied || link.Failures != 1 || link.LastError != "timeout" || !link.LastOKAt.IsZero() {
		t.Fatalf("transient %+v %v %v", link, applied, err)
	}
	link, applied, err = store.RecordMoamalatPoke(ctx, MoamalatPoke{InstallationID: "inst-b", TokenID: "t-inst-b", Outcome: "alive", NextIn: 4 * time.Minute})
	if err != nil || !applied || link.Failures != 0 || link.LastOKAt.IsZero() {
		t.Fatalf("alive %+v %v %v", link, applied, err)
	}
	dead, applied, err := store.MarkMoamalatDead(ctx, "inst-b", "t-inst-b", "relay")
	if err != nil || !applied || dead.State != MoamalatNeedsReauth || dead.SealedToken != "" {
		t.Fatalf("dead %+v %v %v", dead, applied, err)
	}
	// The re-linked shop is due at once; the dead one never is.
	claims, err := store.ClaimMoamalatPokes(ctx, 50, time.Minute)
	if err != nil || len(claims) != 1 || claims[0].Link.InstallationID != "inst-a" || claims[0].Link.TokenID != "t-a2" {
		t.Fatalf("after re-link %+v %v", claims, err)
	}
	if count, err := store.DeleteAllMoamalatLinks(ctx); err != nil || count != len(shops) {
		t.Fatalf("kill switch deleted %d %v", count, err)
	}
}
