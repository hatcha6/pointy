package ratelimit

import (
	"context"
	"testing"
	"time"
)

func TestMemoryLimiterAllowsUntilLimitThenResets(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	limiter := NewMemoryLimiter(func() time.Time { return now })
	policy := Policy{Limit: 2, Window: time.Minute}

	first, err := limiter.Allow(context.Background(), "install-1", policy)
	if err != nil {
		t.Fatal(err)
	}
	second, err := limiter.Allow(context.Background(), "install-1", policy)
	if err != nil {
		t.Fatal(err)
	}
	third, err := limiter.Allow(context.Background(), "install-1", policy)
	if err != nil {
		t.Fatal(err)
	}

	if !first.Allowed || first.Remaining != 1 {
		t.Fatalf("unexpected first decision %#v", first)
	}
	if !second.Allowed || second.Remaining != 0 {
		t.Fatalf("unexpected second decision %#v", second)
	}
	if third.Allowed || third.Remaining != 0 {
		t.Fatalf("unexpected third decision %#v", third)
	}

	now = now.Add(time.Minute)
	reset, err := limiter.Allow(context.Background(), "install-1", policy)
	if err != nil {
		t.Fatal(err)
	}
	if !reset.Allowed || reset.Remaining != 1 {
		t.Fatalf("expected limiter to reset, got %#v", reset)
	}
}

func TestMemoryLimiterTracksKeysIndependently(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	limiter := NewMemoryLimiter(func() time.Time { return now })
	policy := Policy{Limit: 1, Window: time.Minute}

	if decision, err := limiter.Allow(context.Background(), "install-1", policy); err != nil || !decision.Allowed {
		t.Fatalf("expected first key to be allowed, decision=%#v err=%v", decision, err)
	}
	if decision, err := limiter.Allow(context.Background(), "install-2", policy); err != nil || !decision.Allowed {
		t.Fatalf("expected second key to be allowed, decision=%#v err=%v", decision, err)
	}
}

func TestMemoryLimiterPeekDoesNotConsume(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	limiter := NewMemoryLimiter(func() time.Time { return now })
	policy := Policy{Limit: 3, Window: time.Minute}

	peek, err := limiter.Peek(context.Background(), "i", policy)
	if err != nil {
		t.Fatal(err)
	}
	if !peek.Allowed || peek.Remaining != 3 {
		t.Fatalf("unexpected empty peek %#v", peek)
	}

	if _, err := limiter.Allow(context.Background(), "i", policy); err != nil {
		t.Fatal(err)
	}
	// Peeking repeatedly must not change the count.
	for range 2 {
		peek, err = limiter.Peek(context.Background(), "i", policy)
		if err != nil {
			t.Fatal(err)
		}
		if peek.Remaining != 2 {
			t.Fatalf("peek changed usage: %#v", peek)
		}
	}

	next, err := limiter.Allow(context.Background(), "i", policy)
	if err != nil {
		t.Fatal(err)
	}
	if next.Remaining != 1 {
		t.Fatalf("expected remaining 1 after one consume + peeks, got %#v", next)
	}
}
