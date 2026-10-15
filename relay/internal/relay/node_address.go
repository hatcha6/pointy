package relay

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"pointy/relay/internal/protocol"
)

// NodeWhoAmIPath answers which node a request reached. A node calls it on its
// own public address before handing that address out.
const NodeWhoAmIPath = "/v1/node/whoami"

const defaultAddressRecheck = 5 * time.Minute

// NodeAddress is this node's own public address: the name that reaches this
// node and no other, so other nodes can send a shop's tunnel straight here.
//
// The address is only handed out once the node has called it and got its own
// random nonce back. A name that leads elsewhere (another node, a scheme the
// front balancer doesn't serve, a balancer not wired up for a new node yet)
// is never advertised; placement then turns tunnels away instead of
// redirecting them, which still spreads them through the round-robin balancer.
type NodeAddress struct {
	NodeID string
	// Candidate is the origin to verify, e.g. https://node1-env.example.
	Candidate string
	// Source names where Candidate came from, for the startup log.
	Source string
	Client *http.Client
	// Recheck is how often the address is verified again.
	Recheck time.Duration
	Logger  *slog.Logger

	nonceOnce sync.Once
	nonce     string
	mu        sync.RWMutex
	verified  string
}

// TunnelURL is the verified tunnel address, or empty.
func (a *NodeAddress) TunnelURL() string {
	if a == nil {
		return ""
	}
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.verified
}

// Run verifies the address now and every Recheck until ctx ends.
func (a *NodeAddress) Run(ctx context.Context) {
	if a == nil || a.Candidate == "" {
		return
	}
	recheck := a.Recheck
	if recheck <= 0 {
		recheck = defaultAddressRecheck
	}
	for {
		a.Verify(ctx)
		// A failed first check is retried sooner: a new node's front-balancer
		// route may simply not be up yet.
		wait := recheck
		if a.TunnelURL() == "" {
			wait = min(recheck, 30*time.Second)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
	}
}

// Verify checks the candidate once and records the outcome.
func (a *NodeAddress) Verify(ctx context.Context) {
	err := a.check(ctx)
	tunnelURL := ""
	if err == nil {
		tunnelURL = tunnelURLFor(a.Candidate)
	}
	a.mu.Lock()
	previous := a.verified
	a.verified = tunnelURL
	a.mu.Unlock()
	switch {
	case err == nil && previous == "":
		a.logger().Info("relay node public address verified",
			"public_tunnel_url", tunnelURL, "source", a.Source)
	case err != nil && previous != "":
		a.logger().Warn("relay node public address stopped answering; no longer advertised",
			"candidate", a.Candidate, "source", a.Source, "error", err)
	case err != nil:
		a.logger().Info("relay node public address not verified; not advertised",
			"candidate", a.Candidate, "source", a.Source, "error", err)
	}
}

func (a *NodeAddress) check(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, a.Candidate+NodeWhoAmIPath, nil)
	if err != nil {
		return err
	}
	client := a.Client
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("whoami answered HTTP %d", response.StatusCode)
	}
	var answer nodeWhoAmI
	if err := json.NewDecoder(io.LimitReader(response.Body, 4096)).Decode(&answer); err != nil {
		return fmt.Errorf("whoami answer unreadable: %w", err)
	}
	if answer.Nonce != a.Nonce() {
		return fmt.Errorf("address reaches another node (%s)", answer.NodeID)
	}
	return nil
}

// tunnelURLFor is the tunnel address on an origin: wss:// on https, and ws://
// on a plain-http origin (a local test fleet; production only verifies https).
func tunnelURLFor(origin string) string {
	if rest, ok := strings.CutPrefix(origin, "http://"); ok {
		return "ws://" + rest + protocol.TunnelPath
	}
	return "wss://" + strings.TrimPrefix(origin, "https://") + protocol.TunnelPath
}

// Nonce is this process's random answer to whoami.
func (a *NodeAddress) Nonce() string {
	a.nonceOnce.Do(func() {
		buffer := make([]byte, 16)
		_, _ = rand.Read(buffer)
		a.nonce = hex.EncodeToString(buffer)
	})
	return a.nonce
}

type nodeWhoAmI struct {
	NodeID string `json:"node_id"`
	Nonce  string `json:"nonce"`
}

func (a *NodeAddress) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, nodeWhoAmI{NodeID: a.NodeID, Nonce: a.Nonce()})
}

func (a *NodeAddress) logger() *slog.Logger {
	if a.Logger != nil {
		return a.Logger
	}
	return slog.Default()
}

// WithNodeWhoAmI serves the whoami route ahead of next, outside every other
// wrapper, like the tunnel route: it must answer on the node's own name
// whatever mode the rest of the routes run in.
func WithNodeWhoAmI(next http.Handler, address *NodeAddress) http.Handler {
	if address == nil {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == NodeWhoAmIPath {
			address.ServeHTTP(w, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// NodePublicAddressCandidate works out the address to verify:
//
//   - template, when set, with {hostname} replaced ("none" turns the address
//     off);
//   - otherwise https://<hostname>, when the container hostname is a full DNS
//     name (on JPaaS it is the node's public name);
//   - otherwise https://<reverse DNS of the node's private address>.
//
// It returns the origin and the source it came from, or empty when there is
// no candidate.
func NodePublicAddressCandidate(template string) (string, string, error) {
	hostname, _ := os.Hostname()
	hostname = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(hostname), "."))
	template = strings.TrimSpace(template)
	if strings.EqualFold(template, "none") {
		return "", "disabled", nil
	}
	if template != "" {
		origin, err := httpsNodeOrigin(strings.ReplaceAll(template, "{hostname}", hostname))
		if err != nil {
			return "", "", fmt.Errorf("POINTY_RELAY_NODE_PUBLIC_URL_TEMPLATE: %w", err)
		}
		return origin, "template", nil
	}
	if strings.Contains(hostname, ".") {
		if origin, err := httpsNodeOrigin("https://" + hostname); err == nil {
			return origin, "hostname", nil
		}
	}
	if name := reverseDNSName(); name != "" {
		if origin, err := httpsNodeOrigin("https://" + name); err == nil {
			return origin, "reverse_dns", nil
		}
	}
	return "", "none", nil
}

func httpsNodeOrigin(raw string) (string, error) {
	parsed, err := url.Parse(strings.TrimRight(strings.TrimSpace(raw), "/"))
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" ||
		(parsed.Path != "" && parsed.Path != "/") || parsed.RawQuery != "" || parsed.User != nil {
		return "", errors.New("must be an https origin, e.g. https://{hostname}")
	}
	return "https://" + strings.ToLower(parsed.Host), nil
}

// reverseDNSName is the DNS name of the node's first private IPv4 address.
func reverseDNSName() string {
	addresses, err := net.InterfaceAddrs()
	if err != nil {
		return ""
	}
	for _, address := range addresses {
		network, ok := address.(*net.IPNet)
		if !ok || network.IP.To4() == nil || !network.IP.IsPrivate() {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		names, err := net.DefaultResolver.LookupAddr(ctx, network.IP.String())
		cancel()
		if err == nil && len(names) > 0 {
			name := strings.ToLower(strings.TrimSuffix(names[0], "."))
			if strings.Contains(name, ".") {
				return name
			}
		}
	}
	return ""
}
