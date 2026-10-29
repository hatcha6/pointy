package observability

import (
	"sync"
	"time"
)

// The requests a node took in lately, for the console's system view: how
// many are being served right now, and the last few minutes in
// 10-second steps. Steps sit on whole multiples of 10 s since the epoch, so
// every node's steps line up and the console can add them together.
const (
	TrafficStep  = 10 * time.Second
	trafficSteps = 30
)

type trafficBucket struct {
	step      int64
	requests  int
	failed    int
	latencyMS int64
	maxMS     int64
}

type traffic struct {
	mu       sync.Mutex
	inFlight int
	buckets  [trafficSteps]trafficBucket
}

// TrafficSnapshot is a node's request traffic, as the registry publishes it.
type TrafficSnapshot struct {
	// InFlight is the requests being served right now.
	InFlight int `json:"in_flight"`
	// Start is the first step's start (unix seconds); each is StepSeconds
	// long, the last one still filling.
	Start       int64 `json:"start"`
	StepSeconds int   `json:"step_seconds"`
	Requests    []int `json:"requests"`
	// Failed is the answers of 500 and over (the shop's, or the relay's own
	// when it couldn't reach the shop).
	Failed []int `json:"failed"`
	// LastMinute sums the last six steps.
	LastMinute TrafficWindow `json:"last_minute"`
}

type TrafficWindow struct {
	Requests int   `json:"requests"`
	Failed   int   `json:"failed"`
	AvgMS    int64 `json:"avg_ms"`
	MaxMS    int64 `json:"max_ms"`
}

// RequestStarted counts a request as in flight, and returns the func that
// records how it ended. Count each request on the node it reached first: one
// forwarded here from another node is that node's.
func (m *Metrics) RequestStarted() func(statusCode int) {
	if m == nil {
		return func(int) {}
	}
	startedAt := time.Now()
	m.traffic.mu.Lock()
	m.traffic.inFlight++
	m.traffic.mu.Unlock()
	var once sync.Once
	return func(statusCode int) {
		once.Do(func() {
			m.traffic.finish(time.Now(), time.Since(startedAt), statusCode == 0 || statusCode >= 500)
		})
	}
}

func (t *traffic) finish(now time.Time, took time.Duration, failed bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.inFlight = max(t.inFlight-1, 0)
	step := now.Unix() / int64(TrafficStep/time.Second)
	bucket := &t.buckets[step%trafficSteps]
	if bucket.step != step {
		*bucket = trafficBucket{step: step}
	}
	ms := took.Milliseconds()
	bucket.requests++
	bucket.latencyMS += ms
	bucket.maxMS = max(bucket.maxMS, ms)
	if failed {
		bucket.failed++
	}
}

// Traffic is the node's request traffic now and over the last five minutes.
func (m *Metrics) Traffic() TrafficSnapshot {
	if m == nil {
		return (&Metrics{}).Traffic()
	}
	return m.traffic.snapshot(time.Now())
}

func (t *traffic) snapshot(now time.Time) TrafficSnapshot {
	t.mu.Lock()
	defer t.mu.Unlock()
	stepSeconds := int64(TrafficStep / time.Second)
	last := now.Unix() / stepSeconds
	first := last - trafficSteps + 1
	snapshot := TrafficSnapshot{
		InFlight:    t.inFlight,
		Start:       first * stepSeconds,
		StepSeconds: int(stepSeconds),
		Requests:    make([]int, trafficSteps),
		Failed:      make([]int, trafficSteps),
	}
	var latency int64
	for i := range trafficSteps {
		step := first + int64(i)
		bucket := t.buckets[step%trafficSteps]
		if bucket.step != step {
			continue
		}
		snapshot.Requests[i] = bucket.requests
		snapshot.Failed[i] = bucket.failed
		if i >= trafficSteps-6 {
			snapshot.LastMinute.Requests += bucket.requests
			snapshot.LastMinute.Failed += bucket.failed
			snapshot.LastMinute.MaxMS = max(snapshot.LastMinute.MaxMS, bucket.maxMS)
			latency += bucket.latencyMS
		}
	}
	if snapshot.LastMinute.Requests > 0 {
		snapshot.LastMinute.AvgMS = latency / int64(snapshot.LastMinute.Requests)
	}
	return snapshot
}
