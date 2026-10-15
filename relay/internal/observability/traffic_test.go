package observability

import (
	"testing"
	"time"
)

func TestTrafficCountsInFlightAndTheLastMinute(t *testing.T) {
	m := NewMetrics()
	done := m.PhoneRequestStarted()
	other := m.PhoneRequestStarted()
	if got := m.Traffic().InFlight; got != 2 {
		t.Fatalf("expected 2 in flight, got %d", got)
	}
	done(200)
	done(200) // once only
	other(503)
	snapshot := m.Traffic()
	if snapshot.InFlight != 0 || snapshot.LastMinute.Requests != 2 || snapshot.LastMinute.Failed != 1 {
		t.Fatalf("unexpected traffic %+v", snapshot.LastMinute)
	}
	if len(snapshot.Requests) != trafficSteps || snapshot.Requests[trafficSteps-1] != 2 {
		t.Fatalf("expected both in the last step, got %v", snapshot.Requests)
	}
}

func TestTrafficForgetsOldSteps(t *testing.T) {
	var tr traffic
	now := time.Unix(1_000_000, 0)
	tr.inFlight = 1
	tr.finish(now, time.Millisecond, false)
	later := now.Add(trafficSteps * TrafficStep)
	snapshot := tr.snapshot(later)
	for _, n := range snapshot.Requests {
		if n != 0 {
			t.Fatalf("a step older than the window came back: %v", snapshot.Requests)
		}
	}
	if got := tr.snapshot(now).Requests[trafficSteps-1]; got != 1 {
		t.Fatalf("expected the request in its step, got %d", got)
	}
	if start := tr.snapshot(now).Start; start%10 != 0 {
		t.Fatalf("steps must sit on whole multiples of 10 s, start %d", start)
	}
}
