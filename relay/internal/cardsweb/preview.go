package cardsweb

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"image"
	"log/slog"
	"sync"
	"time"
)

// Link previews: a cards.dftr.ly link pasted into WhatsApp or Telegram shows
// the brand's own picture and name. Those apps read the page's og: tags and
// never run its code, so the relay writes them into index.html itself (see
// page.go), from the same catalog the app is shown.
//
// A preview is only shown if its picture arrives within a few seconds, so no
// picture is ever drawn while an app waits: every brand's is drawn ahead, when
// the catalog is first read and again for any brand whose art changes, and
// kept in memory (a few dozen kilobytes each).

// Source is the shelf link previews describe.
type Source interface {
	// PreviewCatalog is every brand and category the web build sells.
	PreviewCatalog(ctx context.Context) (PreviewCatalog, error)
	// PreviewArt is the image a brand's Art names.
	PreviewArt(ctx context.Context, ref string) ([]byte, error)
}

// PreviewCatalog is what previews say about the shelf.
type PreviewCatalog struct {
	// Brands by key.
	Brands map[string]PreviewBrand
	// Categories are names by key.
	Categories map[string]string
}

// PreviewBrand is one brand as its preview shows it.
type PreviewBrand struct {
	Name     string
	Category string
	// Art is the brand's card art ("sha256:…"); empty draws its colours.
	Art string
}

const (
	// catalogFresh is how long a reading of the catalog stands before the
	// next page asks for another (and is answered from this one meanwhile).
	catalogFresh = time.Minute
	// catalogFirstWait is how long a page waits for the very first reading;
	// past it the page goes out with the shelf's own preview.
	catalogFirstWait = 2 * time.Second
	// catalogRetry spaces readings after one fails.
	catalogRetry = 10 * time.Second
	// bannerWait is how long a picture request waits on a drawing still
	// under way before it is sent the shelf's picture instead.
	bannerWait = 3 * time.Second
	// rendererVersion changes every picture's address when the drawing does.
	rendererVersion = "1"
)

type previews struct {
	source Source
	logger *slog.Logger

	mu         sync.Mutex
	catalog    PreviewCatalog
	readAt     time.Time
	retryAt    time.Time
	refreshing chan struct{}
	banners    map[string]*banner
	site       func() *banner
}

// banner is one brand's picture: waiting its turn, being drawn, or drawn.
type banner struct {
	id    string
	key   string
	brand PreviewBrand
	once  sync.Once
	done  chan struct{}
	jpeg  []byte
	err   error
}

func (b *banner) failed() bool {
	select {
	case <-b.done:
		return b.err != nil
	default:
		return false
	}
}

func newPreviews(source Source, logger *slog.Logger) *previews {
	if logger == nil {
		logger = slog.Default()
	}
	p := &previews{source: source, logger: logger, banners: map[string]*banner{}}
	p.site = sync.OnceValue(func() *banner {
		b := &banner{id: bannerID("site"), done: make(chan struct{})}
		b.jpeg, b.err = renderSiteBanner()
		close(b.done)
		return b
	})
	if source != nil {
		p.mu.Lock()
		p.refreshLocked()
		p.mu.Unlock()
	}
	return p
}

// shelf is the catalog as last read, and whether there is one. It never
// waits on a reading except the very first.
func (p *previews) shelf(ctx context.Context) (PreviewCatalog, bool) {
	if p.source == nil {
		return PreviewCatalog{}, false
	}
	p.mu.Lock()
	if p.readAt.IsZero() {
		if time.Now().Before(p.retryAt) {
			p.mu.Unlock()
			return PreviewCatalog{}, false
		}
		reading := p.refreshLocked()
		p.mu.Unlock()
		timer := time.NewTimer(catalogFirstWait)
		defer timer.Stop()
		select {
		case <-reading:
		case <-timer.C:
		case <-ctx.Done():
		}
		p.mu.Lock()
		defer p.mu.Unlock()
		return p.catalog, !p.readAt.IsZero()
	}
	if time.Since(p.readAt) > catalogFresh && time.Now().After(p.retryAt) {
		p.refreshLocked()
	}
	defer p.mu.Unlock()
	return p.catalog, true
}

// refreshLocked reads the catalog again in the background, unless a reading
// is already under way; either way it returns that reading's end.
func (p *previews) refreshLocked() chan struct{} {
	if p.refreshing != nil {
		return p.refreshing
	}
	reading := make(chan struct{})
	p.refreshing = reading
	go func() {
		defer close(reading)
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		catalog, err := p.source.PreviewCatalog(ctx)
		p.mu.Lock()
		defer p.mu.Unlock()
		p.refreshing = nil
		if err != nil {
			p.retryAt = time.Now().Add(catalogRetry)
			p.logger.Warn("card link previews: the catalog could not be read", "error", err)
			return
		}
		p.catalog, p.readAt = catalog, time.Now()
		// Every brand's picture drawn ahead, one at a time (the relay has
		// other work); an unchanged one is kept, a failed one tried again.
		ahead := []*banner{}
		for key, brand := range catalog.Brands {
			if b := p.banners[key]; b != nil && b.failed() {
				delete(p.banners, key)
			}
			b := p.brandLocked(key, brand)
			select {
			case <-b.done:
			default:
				ahead = append(ahead, b)
			}
		}
		go func() {
			for _, b := range ahead {
				p.drawNow(b)
			}
		}()
	}()
	return reading
}

// brandBanner is brand key's picture for a page or a picture request: one
// still waiting its turn is drawn at once, ahead of the rest.
func (p *previews) brandBanner(key string, brand PreviewBrand) *banner {
	p.mu.Lock()
	b := p.brandLocked(key, brand)
	p.mu.Unlock()
	select {
	case <-b.done:
	default:
		go p.drawNow(b)
	}
	return b
}

// brandLocked is key's banner, a new one (not yet drawn) when its brand's
// picture would differ.
func (p *previews) brandLocked(key string, brand PreviewBrand) *banner {
	id := bannerID("brand", key, brand.Category, brand.Art)
	if b := p.banners[key]; b != nil && b.id == id {
		return b
	}
	b := &banner{id: id, key: key, brand: brand, done: make(chan struct{})}
	p.banners[key] = b
	return b
}

// drawNow draws b unless it is drawn or being drawn, and returns once it is.
func (p *previews) drawNow(b *banner) {
	b.once.Do(func() {
		defer close(b.done)
		b.jpeg, b.err = p.draw(b.key, b.brand)
	})
}

func (p *previews) draw(key string, brand PreviewBrand) ([]byte, error) {
	var art image.Image
	if brand.Art != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		data, err := p.source.PreviewArt(ctx, brand.Art)
		cancel()
		if err == nil {
			art, _, err = image.Decode(bytes.NewReader(data))
		}
		if err != nil {
			// The shelf's picture stands in until the next reading.
			p.logger.Warn("card link previews: a brand's art could not be read", "brand", key, "error", err)
			return nil, err
		}
	}
	started := time.Now()
	jpeg, err := renderBrandBanner(art, brand.Category)
	if err != nil {
		p.logger.Error("card link previews: a picture could not be drawn", "brand", key, "error", err)
		return nil, err
	}
	p.logger.Debug("card link preview drawn", "brand", key, "bytes", len(jpeg), "took", time.Since(started))
	return jpeg, nil
}

// picture is the JPEG for b, waiting a little on a drawing under way; the
// shelf's own picture stands in (own false) for one that fails or is slow.
func (p *previews) picture(ctx context.Context, b *banner) (jpeg []byte, own bool) {
	if b != nil {
		timer := time.NewTimer(bannerWait)
		defer timer.Stop()
		select {
		case <-b.done:
			if b.err == nil {
				return b.jpeg, true
			}
		case <-timer.C:
		case <-ctx.Done():
		}
	}
	return p.site().jpeg, false
}

func bannerID(parts ...string) string {
	sum := sha256.New()
	sum.Write([]byte(rendererVersion))
	for _, part := range parts {
		sum.Write([]byte{0})
		sum.Write([]byte(part))
	}
	return hex.EncodeToString(sum.Sum(nil))[:16]
}
