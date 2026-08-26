// Command pointy-stub stands in for the application containers in the on-prem
// update rehearsal (see ../README.md).
//
// The rehearsal exercises the REAL update engine against REAL Docker using the
// REAL deploy/onprem/docker-compose.yml. What it does not need is Django: the
// engine never looks inside the image, it only cares that a container starts,
// answers /readyz/ through the front door, and can be told apart from the
// version it replaced. So one static binary impersonates every application
// container, and — crucially — can be built to FAIL in specific, chosen ways.
// You cannot ask a real backend to "never become ready" on demand; you can ask
// this one, which is what makes the rollback paths testable at all.
//
// It is FROM scratch and a few MB, so a release bundle built from it saves and
// loads in about a second instead of minutes. That matters: the rehearsal
// builds several bundles per run.
//
// Roles (argv[1], matching the compose commands):
//
//	web        serve :8000 — /readyz/, /healthz/ and a catch-all, every response
//	           carrying X-Pointy-Stub-Version so a test can prove WHICH release
//	           actually served a request through the front door
//	worker     idle (celery-worker)
//	beat       idle (celery-beat)
//	connector  write the relay connector state file, then idle
//	webapp     serve :80 — /healthz-web (the browser front door)
//
// It also impersonates the two commands the compose healthchecks invoke, so the
// shipped compose file can be used verbatim, with no rehearsal-specific edits:
//
//	python /app/backend/docker/healthcheck.py <url>   probe <url>, exit 0/1
//	celery -A pointy inspect ping                     exit 0
//
// Failure injection is baked into the IMAGE at build time (ENV in the
// Dockerfile), never passed through compose — because "release 2.0.0 is broken"
// has to be a property of the release, exactly as it is in production. The
// compose file is identical for the version that works and the one that does
// not.
//
//	POINTY_STUB_VERSION      what this release calls itself
//	POINTY_STUB_BOOT_DELAY   seconds to sleep before listening (a slow boot)
//	POINTY_STUB_FAIL         never_listen | never_ready | crash_on_boot |
//	                         crash_after_serving | ready_then_sick
//	POINTY_STUB_CRASH_AFTER  seconds before crash_after_serving fires
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envSeconds(key string, fallback int) int {
	if v, err := strconv.Atoi(os.Getenv(key)); err == nil {
		return v
	}
	return fallback
}

var (
	version  = env("POINTY_STUB_VERSION", "unknown")
	failMode = os.Getenv("POINTY_STUB_FAIL")
	ready    atomic.Bool
	served   atomic.Int64
)

func main() {
	// Impersonating the healthcheck binaries has to come first: the compose
	// healthcheck runs `python /app/.../healthcheck.py <url>` inside this very
	// container, so argv[0] decides what we are before argv[1] does.
	switch filepath.Base(os.Args[0]) {
	case "python", "python3":
		os.Exit(probe())
	case "celery":
		return // `celery -A pointy inspect ping` — the worker is always fine
	}

	role := "web"
	if len(os.Args) > 1 {
		role = os.Args[1]
	}
	switch role {
	case "loadgen":
		// Host-side only: the rehearsal's traffic generator (see loadgen.go).
		runLoadGen(os.Args[2:])
		return
	case "web":
		serveBackend()
	case "webapp":
		serveWebApp()
	case "worker", "beat":
		idle()
	case "connector":
		runConnector()
	default:
		// The real relay binary takes `connector --relay X --backend Y`; anything
		// unrecognised is treated as the connector so the compose command works
		// verbatim.
		runConnector()
	}
}

// probe implements the healthcheck shim: argv is (python, <script>, <url>).
func probe() int {
	url := ""
	for _, arg := range os.Args[1:] {
		if strings.HasPrefix(arg, "http") {
			url = arg
		}
	}
	if url == "" {
		return 1
	}
	client := &http.Client{Timeout: 4 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 200 && resp.StatusCode < 400 {
		return 0
	}
	return 1
}

// Blocking on a signal rather than `select {}`: an empty select is exactly the
// case Go's runtime reports as "all goroutines are asleep - deadlock!" and exits
// 2 for, which under compose's `restart: always` is an endless restart loop.
// Waiting on a signal also lets `docker stop` end the container promptly instead
// of waiting out its stop_grace_period.
func idle() {
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	<-signals
}

func runConnector() {
	// The update agent reads this shop's relay token straight out of the
	// container filesystem with `docker compose cp`, which is why the real
	// connector image can be FROM scratch. Same here.
	stateFile := env("POINTY_RELAY_CONNECTOR_STATE_FILE", "/var/lib/pointy/relay-connector.json")
	_ = os.MkdirAll(filepath.Dir(stateFile), 0o755)
	state := map[string]string{
		"installation_id": env("POINTY_STUB_INSTALLATION_ID", "inst_rehearsal"),
		"connector_token": env("POINTY_RELAY_CONNECTOR_SETUP_TOKEN", ""),
	}
	blob, _ := json.Marshal(state)
	if err := os.WriteFile(stateFile, blob, 0o600); err != nil {
		fmt.Fprintf(os.Stderr, "stub connector: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("stub connector %s: wrote %s\n", version, stateFile)
	idle()
}

func serveWebApp() {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz-web", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-Pointy-Stub-Version", version)
		fmt.Fprintln(w, "ok")
	})
	listenAndServe(":80", mux)
}

// countStart records, in a volume that survives a container being replaced, how
// many times a backend of this deployment has started. It is what makes the
// post-switchover rollback testable at all: the standby and the rebuilt backend
// run the SAME image from the SAME service definition, so nothing about the
// container itself can distinguish them — but their ORDER can. Start 1 is the
// install, 2 is the standby, 3 is the managed backend being rebuilt on the new
// release. A release that fails only at start 3 fails after traffic has already
// moved, which is the one path pu_rollback_live exists for.
func countStart() int {
	path := env("POINTY_STUB_START_COUNTER", "/var/lib/pointy/media/stub-starts")
	count := 0
	if blob, err := os.ReadFile(path); err == nil {
		count, _ = strconv.Atoi(strings.TrimSpace(string(blob)))
	}
	count++
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	_ = os.WriteFile(path, []byte(strconv.Itoa(count)), 0o644)
	return count
}

func serveBackend() {
	// Counted on EVERY backend start, whatever the release, so the ordinal means
	// the same thing across an update: the healthy release that installed the
	// shop is #1, the standby is #2, and the managed backend rebuilt on the new
	// release is #3. Counting only in the failing release would make #1 the
	// standby and the failure would never land after the switchover.
	start := countStart()
	if failMode == "never_ready_at_start" {
		want := envSeconds("POINTY_STUB_FAIL_AT_START", 3)
		fmt.Fprintf(os.Stderr, "stub %s: backend start #%d (fails at #%d)\n", version, start, want)
		if start == want {
			failMode = "never_ready"
		} else {
			failMode = ""
		}
	}
	switch failMode {
	case "crash_on_boot":
		// A release whose migrations fail: the container starts and dies. The
		// engine has to notice the exit rather than wait out its full timeout.
		fmt.Fprintf(os.Stderr, "stub %s: simulated boot failure\n", version)
		os.Exit(1)
	case "never_listen":
		// A backend wedged before it binds — a migration waiting on a lock.
		fmt.Fprintf(os.Stderr, "stub %s: simulated hang before listening\n", version)
		idle()
	}

	if delay := envSeconds("POINTY_STUB_BOOT_DELAY", 0); delay > 0 {
		time.Sleep(time.Duration(delay) * time.Second)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/readyz/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-Pointy-Stub-Version", version)
		if !ready.Load() {
			// Listening but not ready: the case where a TCP check would pass and
			// only a real readiness probe catches it.
			http.Error(w, "not ready\n", http.StatusServiceUnavailable)
			return
		}
		fmt.Fprintf(w, "ready %s\n", version)
	})
	mux.HandleFunc("/healthz/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-Pointy-Stub-Version", version)
		fmt.Fprintln(w, "ok")
	})
	// A request that is deliberately still in flight when the front door is
	// reloaded. A graceful reload must finish it on the old worker; anything
	// less and a till loses a sale mid-checkout.
	mux.HandleFunc("/slow", func(w http.ResponseWriter, r *http.Request) {
		ms := 1000
		if v, err := strconv.Atoi(r.URL.Query().Get("ms")); err == nil {
			ms = v
		}
		w.Header().Set("X-Pointy-Stub-Version", version)
		w.WriteHeader(http.StatusOK)
		if f, ok := w.(http.Flusher); ok {
			fmt.Fprintf(w, "begin %s\n", version)
			f.Flush()
		}
		time.Sleep(time.Duration(ms) * time.Millisecond)
		fmt.Fprintf(w, "end %s\n", version)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-Pointy-Stub-Version", version)
		if !ready.Load() {
			// An unready backend fails real work too, not just its probe. A
			// stand-in that kept answering the API while reporting itself unready
			// would let a scenario measure a readiness blip where a shop would
			// have had a genuine outage.
			http.Error(w, "not ready\n", http.StatusServiceUnavailable)
			return
		}
		n := served.Add(1)
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, "{\"version\":%q,\"served\":%d}\n", version, n)
	})

	if failMode == "never_ready" {
		// Serving 503s from /readyz/ forever: the release that boots fine and is
		// still not fit to take traffic.
		fmt.Fprintf(os.Stderr, "stub %s: simulated permanent unreadiness\n", version)
	} else {
		ready.Store(true)
	}

	if failMode == "crash_after_serving" {
		go func() {
			time.Sleep(time.Duration(envSeconds("POINTY_STUB_CRASH_AFTER", 5)) * time.Second)
			fmt.Fprintf(os.Stderr, "stub %s: simulated crash after serving\n", version)
			os.Exit(1)
		}()
	}
	if failMode == "ready_then_sick" {
		// Passes the readiness gate, then starts failing: the update completes
		// and the shop is broken afterwards. The engine's own final health check
		// is the only thing that can catch this.
		go func() {
			time.Sleep(time.Duration(envSeconds("POINTY_STUB_CRASH_AFTER", 5)) * time.Second)
			fmt.Fprintf(os.Stderr, "stub %s: simulated sickness after readiness\n", version)
			ready.Store(false)
		}()
	}

	listenAndServe(":8000", mux)
}

func listenAndServe(addr string, mux *http.ServeMux) {
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "stub %s: listen %s: %v\n", version, addr, err)
		os.Exit(1)
	}
	fmt.Printf("stub %s: serving %s\n", version, addr)
	server := &http.Server{Handler: mux}

	// Drain on SIGTERM instead of dying on it, because that is what the real
	// backend does (uvicorn's graceful shutdown, POINTY_ASGI_GRACEFUL_TIMEOUT).
	// It matters to what this rehearsal can honestly claim: a live update
	// REPLACES the managed backend container while the standby serves, and a
	// stand-in that dropped its in-flight requests on SIGTERM would make the
	// engine look like it loses a cashier's checkout when it does not — or, far
	// worse, hide the day it really does. Compose sends SIGTERM and waits out
	// stop_grace_period, so an update that gives the old container that time
	// keeps every request it was already serving.
	done := make(chan struct{})
	go func() {
		signals := make(chan os.Signal, 1)
		signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
		<-signals
		fmt.Printf("stub %s: draining\n", version)
		ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
		close(done)
	}()

	if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
		fmt.Fprintf(os.Stderr, "stub %s: serve: %v\n", version, err)
		os.Exit(1)
	}
	<-done
	fmt.Printf("stub %s: drained\n", version)
}
