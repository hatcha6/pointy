package relay

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"pointy/relay/internal/limit"
	"pointy/relay/internal/observability"
)

const (
	// Leaves room for one OpenSERP retry inside the backend's 15 s budget.
	defaultImageSearchRequestTimeout = 12 * time.Second
	// The engines that answer from a server IP. Bing leads: it alone sends real
	// thumbnails and source pages. Google refuses headless traffic almost at
	// once and DuckDuckGo times out, so neither is on by default.
	defaultOpenSERPImageEngines  = "bing,yandex,ecosia"
	defaultOpenSERPImageLanguage = "ar"
	// imageSearchMaxRequestBytes caps the tiny inbound JSON (query + paging).
	imageSearchMaxRequestBytes = 4 << 10
	// imageSearchMaxResponseBytes caps the OpenSERP response we read.
	imageSearchMaxResponseBytes = 2 << 20
	imageSearchMaxPageSize      = 50
)

type imageSearchRequest struct {
	Query    string `json:"query"`
	Page     int    `json:"page"`
	PageSize int    `json:"page_size"`
}

// imageSearchResult is the normalized shape the backend consumes. It mirrors the
// fields the Django ProductImageSearchResult dataclass needs to build a signed
// import token; the relay never stores any of it.
type imageSearchResult struct {
	Title        string `json:"title"`
	ThumbnailURL string `json:"thumbnail_url"`
	ImageURL     string `json:"image_url"`
	SourceURL    string `json:"source_url"`
	SourceName   string `json:"source_name"`
	Width        int    `json:"width,omitempty"`
	Height       int    `json:"height,omitempty"`
}

// handleImageSearch serves relay-hosted product image search. Like the AI chat
// endpoint it does NOT tunnel to the on-prem connector: the relay holds the
// search engine (a self-hosted OpenSERP server, so shops never manage a key),
// gates on the installation's remote-access entitlement (subscription +
// relay_enabled, via ValidateAccessToken), runs the image search, and returns
// the normalized results as JSON.
func (s HTTPServer) handleImageSearch(w http.ResponseWriter, r *http.Request) {
	startedAt := time.Now()
	statusCode := http.StatusOK
	outcome := "image_search_ok"
	defer func() {
		s.metrics().RecordRelayRequest(observability.RelayRequestObservation{
			Outcome:    outcome,
			StatusCode: statusCode,
			Duration:   time.Since(startedAt),
		})
	}()

	if strings.TrimSpace(s.OpenSERPBaseURL) == "" {
		statusCode = http.StatusServiceUnavailable
		outcome = "image_search_unconfigured"
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "relay image search is not configured"})
		return
	}

	rawToken := strings.TrimSpace(r.Header.Get(AccessTokenHeader))
	if rawToken == "" {
		statusCode = http.StatusUnauthorized
		outcome = "credential_rejected"
		s.metrics().RecordCredentialRejected()
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "relay token required"})
		return
	}

	installation, err := s.Store.ValidateAccessToken(r.Context(), rawToken)
	if err != nil {
		statusCode = relayCredentialStatusCode(err)
		outcome = relayCredentialOutcome(err)
		s.recordCredentialError(err)
		writeRelayCredentialError(w, err)
		return
	}

	// Cap concurrent work against the same global slot pool the relay/AI paths
	// use, so image search can't be abused into unbounded outbound load.
	release, ok := limit.TryAcquire(s.RelayLimiter)
	if !ok {
		statusCode = http.StatusTooManyRequests
		outcome = "request_limited"
		s.metrics().RecordRequestLimitRejected()
		writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "relay request limit reached"})
		return
	}
	defer release()

	if limited, limitStatus, limitOutcome := s.enforceRateLimit(
		w,
		r,
		"image_search",
		imageSearchRateLimitKey(installation.ID),
		s.RelayRequestRateLimit,
	); limited {
		statusCode = limitStatus
		outcome = limitOutcome
		return
	}

	var request imageSearchRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, imageSearchMaxRequestBytes)).Decode(&request); err != nil {
		statusCode = http.StatusBadRequest
		outcome = "invalid_request"
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	query := strings.TrimSpace(request.Query)
	if query == "" {
		statusCode = http.StatusBadRequest
		outcome = "invalid_request"
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "query required"})
		return
	}
	page := request.Page
	if page < 1 {
		page = 1
	}
	pageSize := request.PageSize
	if pageSize < 1 {
		pageSize = 1
	}
	if pageSize > imageSearchMaxPageSize {
		pageSize = imageSearchMaxPageSize
	}

	ctx, cancel := context.WithTimeout(r.Context(), s.imageSearchRequestTimeout())
	defer cancel()

	results, err := s.searchImages(ctx, installation.ID, query, page, pageSize)
	if err != nil {
		statusCode = http.StatusBadGateway
		outcome = "image_search_failed"
		s.metrics().RecordBackendFailure()
		s.logger().Warn("relay image search failed", "installation_id", installation.ID, "error", err)
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "image search failed"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"results": results})
}

// searchImages asks every configured OpenSERP engine at once and merges their
// answers into one list: round-robin by rank in the configured engine order,
// deduped by image URL, capped to pageSize. An engine that is blocked or slow
// only drops out; the search fails only when every engine does.
//
// It answers one page only. OpenSERP's offsets do not page reliably (Bing and
// Ecosia hand back the same images for a later start, and /mega/image ignores
// start altogether), so page 2 would only repeat page 1. Returning nothing for
// it ends the app's "load more" after the first, merged page.
func (s HTTPServer) searchImages(
	ctx context.Context,
	installationID string,
	query string,
	page int,
	pageSize int,
) ([]imageSearchResult, error) {
	if page > 1 {
		return []imageSearchResult{}, nil
	}
	engines := s.openSERPEngines()
	answers := make([][]imageSearchResult, len(engines))
	errs := make([]error, len(engines))
	var wg sync.WaitGroup
	for i, engine := range engines {
		wg.Add(1)
		go func(i int, engine string) {
			defer wg.Done()
			answers[i], errs[i] = s.fetchOpenSERPImages(ctx, engine, query, pageSize)
		}(i, engine)
	}
	wg.Wait()

	var firstErr error
	answered := 0
	for i, err := range errs {
		if err == nil {
			answered++
			continue
		}
		if firstErr == nil {
			firstErr = err
		}
		s.logger().Info("image search engine failed", "installation_id", installationID, "engine", engines[i], "error", err)
	}
	if answered == 0 {
		return nil, firstErr
	}
	return mergeImageResults(answers, pageSize), nil
}

// mergeImageResults interleaves the engines' answers rank by rank so every
// engine shows near the top. When two engines found the same image, the first
// one kept gains the other's thumbnail and source page if it lacked them
// (only Bing sends real thumbnails). A result left without a thumbnail shows
// the image itself.
func mergeImageResults(answers [][]imageSearchResult, limit int) []imageSearchResult {
	merged := make([]imageSearchResult, 0, limit)
	index := make(map[string]int, limit)
	for rank := 0; ; rank++ {
		more := false
		for _, answer := range answers {
			if rank >= len(answer) {
				continue
			}
			more = true
			item := answer[rank]
			key := strings.ToLower(item.ImageURL)
			if at, dup := index[key]; dup {
				kept := &merged[at]
				if kept.ThumbnailURL == "" {
					kept.ThumbnailURL = item.ThumbnailURL
				}
				if kept.SourceURL == "" || kept.SourceURL == kept.ImageURL {
					kept.SourceURL, kept.SourceName = item.SourceURL, item.SourceName
				}
				continue
			}
			if len(merged) < limit {
				index[key] = len(merged)
				merged = append(merged, item)
			}
		}
		if !more {
			break
		}
	}
	for i := range merged {
		if merged[i].ThumbnailURL == "" {
			merged[i].ThumbnailURL = merged[i].ImageURL
		}
	}
	return merged
}

// fetchOpenSERPImages runs one engine's image search on the company's
// self-hosted OpenSERP server (GET /{engine}/image) and maps its answer into
// the normalized result shape. ThumbnailURL stays empty when the engine sent
// none, so the merge can take one from another engine.
func (s HTTPServer) fetchOpenSERPImages(
	ctx context.Context,
	engine string,
	query string,
	limit int,
) ([]imageSearchResult, error) {
	endpoint, err := url.Parse(strings.TrimRight(strings.TrimSpace(s.OpenSERPBaseURL), "/") + "/" + url.PathEscape(engine) + "/image")
	if err != nil {
		return nil, err
	}
	params := url.Values{}
	params.Set("text", query)
	params.Set("limit", strconv.Itoa(limit))
	params.Set("lang", s.openSERPLanguage())
	if region := strings.TrimSpace(s.OpenSERPRegion); region != "" {
		params.Set("region", region)
	}
	endpoint.RawQuery = params.Encode()

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Accept", "application/json")

	response, err := s.imageSearchHTTPClient().Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(response.Body, imageSearchMaxResponseBytes))
	if err != nil {
		return nil, err
	}

	var parsed struct {
		Results []struct {
			Title string `json:"title"`
			Image struct {
				URL       string `json:"url"`
				Thumbnail string `json:"thumbnail"`
				Width     int    `json:"width"`
				Height    int    `json:"height"`
			} `json:"image"`
			Source struct {
				PageURL string `json:"page_url"`
				Domain  string `json:"domain"`
			} `json:"source"`
		} `json:"results"`
		// Errors come back as {"error": "<code>", "message": "..."}, e.g.
		// "captcha_detected" or "blocked" when the engine refuses us.
		Error   string `json:"error"`
		Message string `json:"message"`
	}
	decodeErr := json.Unmarshal(raw, &parsed)
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		if detail := firstNonEmpty(parsed.Error, parsed.Message); decodeErr == nil && detail != "" {
			return nil, fmt.Errorf("openserp %s returned %d: %s", engine, response.StatusCode, detail)
		}
		return nil, fmt.Errorf("openserp %s returned %d", engine, response.StatusCode)
	}
	if decodeErr != nil {
		return nil, decodeErr
	}

	results := make([]imageSearchResult, 0, len(parsed.Results))
	for _, item := range parsed.Results {
		imageURL := strings.TrimSpace(item.Image.URL)
		if !isSupportedImageURL(imageURL) {
			continue
		}
		thumbnailURL := strings.TrimSpace(item.Image.Thumbnail)
		if !isSupportedImageURL(thumbnailURL) {
			thumbnailURL = ""
		}
		sourceURL := strings.TrimSpace(item.Source.PageURL)
		results = append(results, imageSearchResult{
			Title:        strings.TrimSpace(item.Title),
			ThumbnailURL: thumbnailURL,
			ImageURL:     imageURL,
			SourceURL:    sourceURL,
			SourceName:   imageSourceName(item.Source.Domain, sourceURL),
			Width:        item.Image.Width,
			Height:       item.Image.Height,
		})
	}
	return results, nil
}

// openSERPEngines is the configured engine list, in merge order.
func (s HTTPServer) openSERPEngines() []string {
	var engines []string
	seen := map[string]struct{}{}
	for _, engine := range strings.Split(s.OpenSERPEngines, ",") {
		engine = strings.ToLower(strings.TrimSpace(engine))
		if _, dup := seen[engine]; engine == "" || dup {
			continue
		}
		seen[engine] = struct{}{}
		engines = append(engines, engine)
	}
	if len(engines) == 0 {
		return strings.Split(defaultOpenSERPImageEngines, ",")
	}
	return engines
}

func (s HTTPServer) openSERPLanguage() string {
	if value := strings.TrimSpace(s.OpenSERPLanguage); value != "" {
		return value
	}
	return defaultOpenSERPImageLanguage
}

func (s HTTPServer) imageSearchRequestTimeout() time.Duration {
	if s.ImageSearchRequestTimeout > 0 {
		return s.ImageSearchRequestTimeout
	}
	return defaultImageSearchRequestTimeout
}

func (s HTTPServer) imageSearchHTTPClient() *http.Client {
	if s.ImageSearchHTTPClient != nil {
		return s.ImageSearchHTTPClient
	}
	return &http.Client{Timeout: s.imageSearchRequestTimeout()}
}

func imageSearchRateLimitKey(installationID string) string {
	return "image-search:" + strings.TrimSpace(installationID)
}

// imageSourceName prefers OpenSERP's own domain label, falling back to the
// host of the result page.
func imageSourceName(domain, sourceURL string) string {
	if name := strings.TrimSpace(domain); name != "" {
		return name
	}
	if parsed, err := url.Parse(strings.TrimSpace(sourceURL)); err == nil {
		return parsed.Hostname()
	}
	return ""
}

func isSupportedImageURL(raw string) bool {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return false
	}
	return (parsed.Scheme == "http" || parsed.Scheme == "https") && parsed.Host != ""
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}
