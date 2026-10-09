package relay

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	_ "image/jpeg" // registered for image.DecodeConfig
	_ "image/png"  // registered for image.DecodeConfig
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// Operator logos are copied, never linked. The supplier's logo URL names the
// supplier (its host), so a shop must never be handed one: the relay fetches the
// picture once, keeps it in the voucher image store under its SHA-256 and the
// services directory carries only that reference ("sha256:<hex>"), served from
// GET /v1/services/logos/{sha256}.
const (
	maxServiceLogoBytes   = 512 << 10
	maxServiceLogoSide    = 1024
	maxServiceLogosAtOnce = 8
	serviceLogoTimeout    = 10 * time.Second
	serviceLogoRetryAfter = 10 * time.Minute
)

// ServiceLogos is the relay's copy of the operator logos: the supplier URL it
// was fetched from, and the image reference the shops are given.
type ServiceLogos struct {
	// Client fetches a logo; nil uses a client that refuses private addresses.
	Client *http.Client

	mu       sync.Mutex
	refs     map[string]string
	failed   map[string]time.Time
	fetching bool
	version  int
	now      func() time.Time
}

// NewServiceLogos makes an empty cache.
func NewServiceLogos() *ServiceLogos {
	return &ServiceLogos{refs: map[string]string{}, failed: map[string]time.Time{}, now: time.Now}
}

// Snapshot is the copies made so far and a key that moves whenever it grows.
func (l *ServiceLogos) Snapshot() (map[string]string, string) {
	if l == nil {
		return nil, ""
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	copied := make(map[string]string, len(l.refs))
	for k, v := range l.refs {
		copied[k] = v
	}
	return copied, fmt.Sprintf("logos:%d", l.version)
}

// Want starts copying, in the background, the logos not copied yet.
func (l *ServiceLogos) Want(store control.VoucherStore, urls []string) {
	if l == nil || len(urls) == 0 {
		return
	}
	l.mu.Lock()
	if l.fetching {
		l.mu.Unlock()
		return
	}
	now := l.now()
	var due []string
	for _, u := range urls {
		if _, ok := l.refs[u]; ok {
			continue
		}
		if at, bad := l.failed[u]; bad && now.Sub(at) < serviceLogoRetryAfter {
			continue
		}
		due = append(due, u)
	}
	sort.Strings(due)
	if len(due) > maxServiceLogosAtOnce {
		due = due[:maxServiceLogosAtOnce]
	}
	if len(due) == 0 {
		l.mu.Unlock()
		return
	}
	l.fetching = true
	l.mu.Unlock()
	go func() {
		l.Fill(context.Background(), store, due)
		l.mu.Lock()
		l.fetching = false
		l.mu.Unlock()
	}()
}

// Fill copies these logos now.
func (l *ServiceLogos) Fill(ctx context.Context, store control.VoucherStore, urls []string) {
	for _, u := range urls {
		ref, err := l.copyOne(ctx, store, u)
		l.mu.Lock()
		if err != nil {
			l.failed[u] = l.now()
		} else {
			l.refs[u] = ref
			delete(l.failed, u)
			l.version++
		}
		l.mu.Unlock()
	}
}

func (l *ServiceLogos) copyOne(ctx context.Context, store control.VoucherStore, raw string) (string, error) {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" {
		return "", errors.New("not an https URL")
	}
	ctx, cancel := context.WithTimeout(ctx, serviceLogoTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, raw, nil)
	if err != nil {
		return "", err
	}
	client := l.Client
	if client == nil {
		client = publicOnlyClient()
	}
	response, err := client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("status %d", response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, maxServiceLogoBytes+1))
	if err != nil {
		return "", err
	}
	if len(data) == 0 || len(data) > maxServiceLogoBytes {
		return "", errors.New("empty or too large")
	}
	contentType := http.DetectContentType(data)
	width, height := 0, 0
	switch contentType {
	case "image/png", "image/jpeg":
		config, _, err := image.DecodeConfig(bytes.NewReader(data))
		if err != nil {
			return "", err
		}
		width, height = config.Width, config.Height
		if width > maxServiceLogoSide || height > maxServiceLogoSide {
			return "", errors.New("too large a picture")
		}
	case "image/webp":
	default:
		return "", errors.New("not an image: " + contentType)
	}
	sum := sha256.Sum256(data)
	stored, _, err := store.PutVoucherImage(ctx, control.VoucherImage{
		SHA256: hex.EncodeToString(sum[:]), ContentType: contentType, Data: data, Width: width, Height: height,
	})
	if err != nil {
		return "", err
	}
	return vouchers.ImagePrefix + stored.SHA256, nil
}

// publicOnlyClient refuses to connect to a private, loopback or link-local
// address, so a supplier's logo URL can never aim the relay at its own network.
func publicOnlyClient() *http.Client {
	dialer := &net.Dialer{
		Timeout: 5 * time.Second,
		Control: func(_, address string, _ syscall.RawConn) error {
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return err
			}
			ip := net.ParseIP(host)
			if ip == nil || ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() || ip.IsMulticast() {
				return errors.New("address not allowed")
			}
			return nil
		},
	}
	return &http.Client{
		Timeout:   serviceLogoTimeout,
		Transport: &http.Transport{DialContext: dialer.DialContext, Proxy: nil},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 3 || req.URL.Scheme != "https" {
				return http.ErrUseLastResponse
			}
			return nil
		},
	}
}

// handleServiceLogo serves GET /v1/services/logos/{sha256}: a logo the relay
// copied, from the same store as the card shop's pictures.
func (s HTTPServer) handleServiceLogo(w http.ResponseWriter, r *http.Request, sum string) {
	s.handleVoucherImage(w, r, strings.TrimSuffix(sum, "/"))
}
