package relay

import (
	"context"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"net/http"
	"path"
	"strconv"
	"strings"
	"time"

	"pointy/relay/internal/control"
)

// The app stores' review account (customer_review.go) always sees bundles, so
// a reviewer meets the feature whether or not any bundle is on sale: the
// stored ones when there are any, else the demo set below. The shelf's rules
// for each build still apply, so the iPhone build shows only the bundle of
// services used outside the app (App Store 3.1.3(e)), never a game card's
// (3.1.1). A reviewer's order of one is simulated like their other orders.
//
// The catalog takes the customer's Bearer token when one is sent; without it,
// or with any token but the review account's, the answer is the public one.

//go:embed assets/bundles/*.png
var demoBundleArtFiles embed.FS

// demoBundleArt is the demo set's artwork by SHA-256, served under
// /v1/customers/images/ like any uploaded image.
var demoBundleArt = func() map[string][]byte {
	out := map[string][]byte{}
	entries, _ := demoBundleArtFiles.ReadDir("assets/bundles")
	for _, entry := range entries {
		data, err := demoBundleArtFiles.ReadFile(path.Join("assets/bundles", entry.Name()))
		if err != nil {
			continue
		}
		sum := sha256.Sum256(data)
		out[hex.EncodeToString(sum[:])] = data
	}
	return out
}()

// demoArtRef is the image reference of an embedded artwork ("pubg-libyana").
func demoArtRef(name string) string {
	data, err := demoBundleArtFiles.ReadFile("assets/bundles/" + name + ".png")
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(data)
	return "sha256:" + hex.EncodeToString(sum[:])
}

// demoBundles is what the review account sees while no bundle is stored. The
// items are the live shelf's: a size whose card the shelf lacks is left out
// as for any bundle.
var demoBundles = func() []control.CustomerBundle {
	credit := func(value string, networks ...string) []string {
		out := []string{}
		for _, network := range networks {
			out = append(out, network+"-"+value+"lyd")
		}
		return out
	}
	art := func(prefix string, networks ...string) map[string]string {
		out := map[string]string{}
		for _, network := range networks {
			if ref := demoArtRef(prefix + "-" + network); ref != "" {
				out[network] = ref
			}
		}
		return out
	}
	stamp := time.Date(2026, 11, 28, 0, 0, 0, 0, time.UTC)
	return []control.CustomerBundle{
		{
			Key: "gamer", Name: "باقة اللاعب", Tagline: "شدّات ببجي مع رصيد خطك", Rank: 1,
			Art: art("pubg", "libyana", "almadar", "ltt"),
			Tiers: []control.CustomerBundleTier{
				{Key: "gamer-60", Saving: "0.750", Parts: [][]string{{"pubg-ww-60uc"}, credit("5", "libyana", "almadar", "ltt")}},
				{Key: "gamer-325", Saving: "2.250", Parts: [][]string{{"pubg-ww-325uc"}, credit("10", "libyana", "almadar", "ltt")}},
				{Key: "gamer-660", Saving: "4.250", Parts: [][]string{{"pubg-ww-660uc"}, credit("10", "libyana", "almadar", "ltt")}},
			},
			Actor: "demo", UpdatedAt: stamp,
		},
		{
			Key: "connect", Name: "باقة الاتصال والإنترنت", Tagline: "إنترنت ليبيا للاتصالات مع رصيد خطك", Rank: 2,
			Art: art("ltt", "libyana", "almadar"),
			Tiers: []control.CustomerBundleTier{
				{Key: "connect-10", Saving: "0.250", Parts: [][]string{{"ltt-10lyd"}, credit("5", "libyana", "almadar")}},
				{Key: "connect-20", Saving: "0.500", Parts: [][]string{{"ltt-20lyd"}, credit("10", "libyana", "almadar")}},
			},
			Actor: "demo", UpdatedAt: stamp,
		},
	}
}()

// bundlesFor is the bundles a customer is offered: the stored ones, and for
// the review account the demo set while none is stored.
func (s HTTPServer) bundlesFor(ctx context.Context, review bool) []control.CustomerBundle {
	stored := s.customerBundles(ctx)
	if review && len(stored) == 0 {
		return demoBundles
	}
	return stored
}

// catalogReviewer reports whether a catalog request carries the review
// account's access token. Anything else (no token, a bad or expired one,
// another customer's) is a public request: the catalog never refuses a
// token it cannot read.
func (s HTTPServer) catalogReviewer(r *http.Request) bool {
	raw, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	raw = strings.TrimSpace(raw)
	if !ok || !strings.HasPrefix(raw, customerAccessTokenPrefix+".") || s.Customers.ReviewCode == "" {
		return false
	}
	store, ok := s.Store.(control.CustomerStore)
	if !ok {
		return false
	}
	customer, _, err := store.CustomerByAccessToken(r.Context(), control.TokenHash(raw))
	return err == nil && s.Customers.isReviewPhone(customer.Phone)
}

// writeDemoBundleArt serves an embedded demo artwork; false when sum is not one.
func writeDemoBundleArt(w http.ResponseWriter, sum string) bool {
	data, ok := demoBundleArt[strings.TrimPrefix(strings.ToLower(strings.TrimSpace(sum)), "sha256:")]
	if !ok {
		return false
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	w.Header().Set("ETag", `"`+sum+`"`)
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
	return true
}
