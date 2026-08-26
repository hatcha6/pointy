package main

// The load generator the rehearsal runs THROUGH the LAN front door for the
// whole duration of an update.
//
// "The shop keeps trading" is the entire claim of a live update, and it is not
// something a before/after curl can check: the interesting window is the few
// hundred milliseconds around an nginx reload and a container recreate. So this
// hammers :8000 exactly as a till does — keep-alive connections held open
// across the flip, which is the HARD case, because a reload has to retire old
// upstream connections without dropping the requests already on them.
//
// It records every request's outcome and which release served it, so a scenario
// can assert three separate things: that nothing failed, that traffic genuinely
// moved to the new version, and that it moved exactly once (a flip that flaps
// back and forth would pass a naive before/after check).
//
//	pointy-stub loadgen -url http://127.0.0.1:8000/api/ping -workers 4 -out r.json
//
// SIGTERM makes it write its summary and exit 0, so the caller starts it, runs
// the update, and stops it.

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"sync"
	"syscall"
	"time"
)

type outcome struct {
	Total     int64            `json:"total"`
	OK        int64            `json:"ok"`
	Failed    int64            `json:"failed"`
	Refused   int64            `json:"connection_refused"`
	Timeout   int64            `json:"timeout"`
	HTTPError int64            `json:"http_error"`
	OtherErr  int64            `json:"other_error"`
	Statuses  map[string]int64 `json:"statuses"`
	Versions  map[string]int64 `json:"versions"`
	Upstreams map[string]int64 `json:"upstreams"`
	// The order versions were first seen in, which is how a scenario tells a
	// clean single hand-over from a flip that oscillated.
	VersionOrder  []string `json:"version_order"`
	UpstreamOrder []string `json:"upstream_order"`
	// Every time the (container, release) pair answering changed, in order.
	// First-seen order alone cannot tell a clean single hand-over from a flip
	// that oscillated: both end on the new version and both "saw" two versions.
	// A live update should produce exactly three entries — old backend, standby,
	// rebuilt backend — and never revisit a pair it has already left.
	Transitions []string `json:"transitions"`
	// The longest run of consecutive failures — a single blip and a
	// twelve-second outage both show as "failed > 0" otherwise.
	// When each release and each container was first and last seen, in ms from
	// the start of the run. An nginx reload is graceful, so old workers keep
	// serving the old upstream until their connections retire — two releases
	// answering at once is CORRECT, and the number that matters is for how long.
	// That window is also the window in which two app versions share one
	// database, which is the whole reason migrations must be backward
	// compatible; measuring it turns an assumption into a number.
	FirstSeenMillis map[string]int64 `json:"first_seen_ms"`
	LastSeenMillis  map[string]int64 `json:"last_seen_ms"`
	FinalVersion    string           `json:"final_version"`
	FinalUpstream   string           `json:"final_upstream"`
	LongestFailureStreak int64   `json:"longest_failure_streak"`
	MaxGapMillis         int64   `json:"max_gap_ms"`
	DurationSeconds      float64 `json:"duration_seconds"`
	FirstErrors          []string `json:"first_errors"`
	// When each failure happened, in ms from the start. Without this a non-zero
	// failure count is a mystery: 16 failures spread evenly across a run and 16
	// clustered in one 200ms window are completely different problems, and only
	// one of them is an outage.
	FailureOffsets []int64 `json:"failure_offsets_ms"`
}

func runLoadGen(args []string) {
	flags := flag.NewFlagSet("loadgen", flag.ExitOnError)
	url := flags.String("url", "http://127.0.0.1:8000/healthz/", "URL to hammer")
	workers := flags.Int("workers", 4, "concurrent workers")
	duration := flags.Duration("duration", 0, "stop after this long (0 = until SIGTERM)")
	interval := flags.Duration("interval", 20*time.Millisecond, "pause between a worker's requests")
	timeout := flags.Duration("timeout", 5*time.Second, "per-request timeout")
	out := flags.String("out", "", "write the JSON summary here (default stdout)")
	_ = flags.Parse(args)

	var mu sync.Mutex
	result := outcome{
		Statuses:        map[string]int64{},
		Versions:        map[string]int64{},
		Upstreams:       map[string]int64{},
		FirstSeenMillis: map[string]int64{},
		LastSeenMillis:  map[string]int64{},
	}
	begun := time.Now()
	mark := func(key string) {
		offset := time.Since(begun).Milliseconds()
		if _, seen := result.FirstSeenMillis[key]; !seen {
			result.FirstSeenMillis[key] = offset
		}
		result.LastSeenMillis[key] = offset
	}
	// Track the failure streak globally rather than per worker: what matters is
	// whether the SHOP was down, not whether one goroutine had a bad moment.
	var currentStreak int64
	var lastSuccess time.Time
	lastPair := ""

	note := func(status string, version string, upstream string, err error) {
		mu.Lock()
		defer mu.Unlock()
		result.Total++
		if err != nil || status == "" {
			result.Failed++
			if len(result.FailureOffsets) < 200 {
				result.FailureOffsets = append(result.FailureOffsets, time.Since(begun).Milliseconds())
			}
			currentStreak++
			if currentStreak > result.LongestFailureStreak {
				result.LongestFailureStreak = currentStreak
			}
			switch {
			case err == nil:
				result.OtherErr++
			case errors.Is(err, syscall.ECONNREFUSED):
				result.Refused++
			case os.IsTimeout(err):
				result.Timeout++
			default:
				var netErr net.Error
				if errors.As(err, &netErr) && netErr.Timeout() {
					result.Timeout++
				} else {
					result.OtherErr++
				}
			}
			if err != nil && len(result.FirstErrors) < 8 {
				result.FirstErrors = append(result.FirstErrors, err.Error())
			}
			return
		}
		result.Statuses[status]++
		if status[0] == '2' || status[0] == '3' {
			result.OK++
			now := time.Now()
			if !lastSuccess.IsZero() {
				if gap := now.Sub(lastSuccess).Milliseconds(); gap > result.MaxGapMillis {
					result.MaxGapMillis = gap
				}
			}
			lastSuccess = now
			currentStreak = 0
		} else {
			result.Failed++
			result.HTTPError++
			if len(result.FailureOffsets) < 200 {
				result.FailureOffsets = append(result.FailureOffsets, time.Since(begun).Milliseconds())
			}
			currentStreak++
			if currentStreak > result.LongestFailureStreak {
				result.LongestFailureStreak = currentStreak
			}
			if len(result.FirstErrors) < 8 {
				result.FirstErrors = append(result.FirstErrors, "HTTP "+status)
			}
		}
		if version != "" {
			if result.Versions[version] == 0 {
				result.VersionOrder = append(result.VersionOrder, version)
			}
			result.Versions[version]++
			mark("version:" + version)
			result.FinalVersion = version
		}
		if upstream != "" {
			if result.Upstreams[upstream] == 0 {
				result.UpstreamOrder = append(result.UpstreamOrder, upstream)
			}
			result.Upstreams[upstream]++
			mark("upstream:" + upstream)
			result.FinalUpstream = upstream
		}
		if pair := upstream + "/" + version; upstream != "" && pair != lastPair {
			result.Transitions = append(result.Transitions, pair)
			lastPair = pair
		}
	}

	// Keep-alive ON and shared, because that is what a till does. Retiring these
	// connections gracefully across a reload is the whole difficulty.
	transport := &http.Transport{
		MaxIdleConns:        *workers * 2,
		MaxIdleConnsPerHost: *workers * 2,
		IdleConnTimeout:     30 * time.Second,
	}
	client := &http.Client{Timeout: *timeout, Transport: transport}

	stop := make(chan struct{})
	var once sync.Once
	closeStop := func() { once.Do(func() { close(stop) }) }

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	go func() { <-signals; closeStop() }()
	if *duration > 0 {
		go func() { time.Sleep(*duration); closeStop() }()
	}

	started := begun
	var wg sync.WaitGroup
	for i := 0; i < *workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				resp, err := client.Get(*url)
				if err != nil {
					note("", "", "", err)
				} else {
					version := resp.Header.Get("X-Pointy-Stub-Version")
					upstream := resp.Header.Get("X-Pointy-Upstream")
					status := fmt.Sprintf("%d", resp.StatusCode)
					resp.Body.Close()
					note(status, version, upstream, nil)
				}
				select {
				case <-stop:
					return
				case <-time.After(*interval):
				}
			}
		}()
	}
	wg.Wait()
	result.DurationSeconds = time.Since(started).Seconds()
	sort.Strings(result.FirstErrors)

	blob, _ := json.MarshalIndent(result, "", "  ")
	blob = append(blob, '\n')
	if *out != "" {
		_ = os.WriteFile(*out, blob, 0o644)
	} else {
		os.Stdout.Write(blob)
	}
}
