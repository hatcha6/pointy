package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"pointy/relay/internal/limit"
	"pointy/relay/internal/observability"
)

const (
	defaultImageSearchRequestTimeout = 8 * time.Second
	defaultSerperImagesEndpoint      = "https://google.serper.dev/images"
	defaultSerperImageLanguage       = "ar"
	defaultSerperImageCountry        = "us"
	// imageSearchMaxRequestBytes caps the tiny inbound JSON (query + paging).
	imageSearchMaxRequestBytes = 4 << 10
	// imageSearchMaxResponseBytes caps the Serper response we read.
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
// Serper.dev key (so shops never manage one), gates on the installation's
// remote-access entitlement (subscription + relay_enabled, via
// ValidateAccessToken), runs the Serper image search, and returns the
// normalized results as JSON.
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

	if strings.TrimSpace(s.SerperAPIKey) == "" {
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

	results, err := s.fetchSerperImages(ctx, query, page, pageSize)
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

// fetchSerperImages calls Serper.dev's image search and maps the response into
// the normalized result shape, deduping by image URL and capping to pageSize.
func (s HTTPServer) fetchSerperImages(
	ctx context.Context,
	query string,
	page int,
	pageSize int,
) ([]imageSearchResult, error) {
	body, err := json.Marshal(map[string]any{
		"q":    query,
		"page": page,
		"num":  pageSize,
		"hl":   s.serperImageLanguage(),
		"gl":   s.serperImageCountry(),
	})
	if err != nil {
		return nil, err
	}
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		s.serperEndpoint(),
		bytes.NewReader(body),
	)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")
	request.Header.Set("X-API-KEY", strings.TrimSpace(s.SerperAPIKey))

	response, err := s.imageSearchHTTPClient().Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(response.Body, imageSearchMaxResponseBytes))
	if err != nil {
		return nil, err
	}
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return nil, fmt.Errorf("serper returned %d", response.StatusCode)
	}

	var parsed struct {
		Images  []map[string]any `json:"images"`
		Error   string           `json:"error"`
		Message string           `json:"message"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return nil, err
	}
	if msg := firstNonEmpty(parsed.Error, parsed.Message); msg != "" {
		return nil, errors.New(msg)
	}

	results := make([]imageSearchResult, 0, pageSize)
	seen := make(map[string]struct{}, pageSize)
	for _, item := range parsed.Images {
		imageURL := firstString(item, "imageUrl", "image_url", "original")
		if !isSupportedImageURL(imageURL) {
			continue
		}
		key := strings.ToLower(imageURL)
		if _, dup := seen[key]; dup {
			continue
		}
		thumbnailURL := firstString(item, "thumbnailUrl", "thumbnail_url", "thumbnail")
		if thumbnailURL == "" {
			thumbnailURL = imageURL
		}
		sourceURL := firstString(item, "link", "sourceUrl")
		results = append(results, imageSearchResult{
			Title:        firstString(item, "title"),
			ThumbnailURL: thumbnailURL,
			ImageURL:     imageURL,
			SourceURL:    sourceURL,
			SourceName:   serperSourceName(item, sourceURL),
			Width:        firstInt(item, "imageWidth", "image_width", "width", "original_width"),
			Height:       firstInt(item, "imageHeight", "image_height", "height", "original_height"),
		})
		seen[key] = struct{}{}
		if len(results) >= pageSize {
			break
		}
	}
	return results, nil
}

func (s HTTPServer) serperEndpoint() string {
	if endpoint := strings.TrimSpace(s.SerperBaseURL); endpoint != "" {
		return endpoint
	}
	return defaultSerperImagesEndpoint
}

func (s HTTPServer) serperImageLanguage() string {
	if value := strings.TrimSpace(s.SerperImageLanguage); value != "" {
		return value
	}
	return defaultSerperImageLanguage
}

func (s HTTPServer) serperImageCountry() string {
	if value := strings.TrimSpace(s.SerperImageCountry); value != "" {
		return value
	}
	return defaultSerperImageCountry
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

// serperSourceName prefers Serper's own source/domain label, falling back to the
// host of the result link.
func serperSourceName(item map[string]any, sourceURL string) string {
	if name := firstString(item, "source", "domain"); name != "" {
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

// firstString returns the first non-empty string value among the given keys,
// tolerating the mixed casing Serper uses across response shapes.
func firstString(item map[string]any, keys ...string) string {
	for _, key := range keys {
		if value, ok := item[key].(string); ok && strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

// firstInt returns the first parseable integer among the given keys. JSON
// numbers decode as float64; some Serper fields arrive as numeric strings.
func firstInt(item map[string]any, keys ...string) int {
	for _, key := range keys {
		switch value := item[key].(type) {
		case float64:
			return int(value)
		case json.Number:
			if parsed, err := value.Int64(); err == nil {
				return int(parsed)
			}
		case string:
			if parsed, err := strconv.Atoi(strings.TrimSpace(value)); err == nil {
				return parsed
			}
		}
	}
	return 0
}
