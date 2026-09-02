package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"pointy/relay/internal/ai"
	"pointy/relay/internal/control"
	"pointy/relay/internal/limit"
	"pointy/relay/internal/observability"
	"pointy/relay/internal/ratelimit"
)

const defaultAIRequestTimeout = 120 * time.Second

// defaultAIMaxRequestBytes caps the inbound chat JSON (prompt + history + any
// base64 attachments, including recorded voice clips which run larger than
// images).
const defaultAIMaxRequestBytes = 24 << 20

const defaultAIMaxImagesPerPrompt = 5

type aiChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
	// Tool round-trips: an assistant turn carries ToolCalls; a tool-result turn
	// sets Role=="tool" with ToolCallID (+ optional Name) and the result in Content.
	ToolCalls  []ai.ToolCall `json:"tool_calls,omitempty"`
	ToolCallID string        `json:"tool_call_id,omitempty"`
	Name       string        `json:"name,omitempty"`
}

// aiAttachment carries an image or file as a base64 data URI (sent to the model
// per request; the relay does not store it).
type aiAttachment struct {
	Kind    string `json:"kind"` // "image" | "file"
	DataURI string `json:"data_uri"`
	Name    string `json:"name"`
	MIME    string `json:"mime"`
}

type aiChatRequest struct {
	Messages    []aiChatMessage  `json:"messages"`
	Attachments []aiAttachment   `json:"attachments"`
	MaxTokens   int              `json:"max_tokens"`
	Temperature *float64         `json:"temperature"`
	Tools       []map[string]any `json:"tools"`
	// CountUsage gates the per-shop usage charge. Nil/true charges this turn
	// (the user-initiated message); false skips it (internal tool continuations
	// must not drain the user's quota). See the agentic loop in apps/ai.
	CountUsage *bool `json:"count_usage"`
	// RouteTier carries the difficulty tier the relay picked for THIS logical turn
	// on its first (user-initiated) request, so the agentic loop's continuations
	// reuse that one dynamic decision instead of re-classifying every round. Only
	// honoured on a continuation (CountUsage=false); ignored on a user turn (the
	// relay always classifies those itself). Empty → fall back to the default tier.
	RouteTier string `json:"route_tier"`
	// WantTitle asks the relay to generate a short conversation title from the
	// user's first message (a cheap side call) and return it in the done event.
	// Django sets it only on a conversation's first turn.
	WantTitle bool `json:"want_title"`
	// WebSearch carries the user turn's web-search decision onto its continuations
	// (mirrors RouteTier), so an agentic flow that needs the web keeps it on the
	// rounds that combine web info with the model's tools. Only honoured on a
	// continuation; a user turn is classified fresh.
	WebSearch bool `json:"web_search"`
	// ResponseFormat constrains the reply to a JSON schema, passed through to
	// OpenRouter verbatim. Only the json_schema form is accepted; anything else
	// is dropped rather than forwarded, so a client cannot steer the provider
	// call into an unexpected mode.
	ResponseFormat map[string]any `json:"response_format"`
	// Purpose is an optional hint about what this call is for. "extract" picks
	// the extraction model and skips the difficulty router: reading a document
	// into a fixed schema is not a conversation and does not need classifying.
	Purpose string `json:"purpose"`
}

// sanitizedResponseFormat returns the caller's response_format when it is a
// json_schema request, and nil otherwise. Restricting the shape here keeps the
// relay's provider call predictable no matter what a backend sends.
func sanitizedResponseFormat(format map[string]any) map[string]any {
	if len(format) == 0 {
		return nil
	}
	if kind, _ := format["type"].(string); kind != "json_schema" {
		return nil
	}
	if _, ok := format["json_schema"]; !ok {
		return nil
	}
	return format
}

// handleAIChat serves relay-hosted AI chat. Unlike the default route it does NOT
// tunnel to the on-prem connector: the relay holds the OpenRouter key, gates on
// the installation's AI entitlement (subscription + ai_enabled, independent of
// remote-access), then streams the model output back as SSE.
func (s HTTPServer) handleAIChat(w http.ResponseWriter, r *http.Request) {
	startedAt := time.Now()
	statusCode := http.StatusOK
	outcome := "ai_chat_ok"
	defer func() {
		s.metrics().RecordRelayRequest(observability.RelayRequestObservation{
			Outcome:    outcome,
			StatusCode: statusCode,
			Duration:   time.Since(startedAt),
		})
	}()

	if strings.TrimSpace(s.OpenRouterAPIKey) == "" {
		statusCode = http.StatusServiceUnavailable
		outcome = "ai_unconfigured"
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "relay AI is not configured"})
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

	installation, err := s.Store.ValidateAIAccessToken(r.Context(), rawToken)
	if err != nil {
		statusCode = aiCredentialStatusCode(err)
		outcome = aiCredentialOutcome(err)
		s.recordAICredentialError(err)
		writeAICredentialError(w, err)
		return
	}

	// Acquire a global concurrency slot first — this caps in-flight work for ALL
	// turns (including tool continuations), so skipping the per-shop anti-burst
	// limit below for continuations can't be abused into unbounded load.
	release, ok := limit.TryAcquire(s.RelayLimiter)
	if !ok {
		statusCode = http.StatusTooManyRequests
		outcome = "request_limited"
		s.metrics().RecordRequestLimitRejected()
		writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "relay request limit reached"})
		return
	}
	defer release()

	var request aiChatRequest
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, s.aiMaxRequestBytes()))
	if err := decoder.Decode(&request); err != nil {
		statusCode = http.StatusBadRequest
		outcome = "invalid_request"
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	if len(request.Messages) == 0 {
		statusCode = http.StatusBadRequest
		outcome = "invalid_request"
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "messages required"})
		return
	}

	// One user message can span several relay turns (the agentic tool loop).
	// Internal continuation turns set count_usage=false: they don't charge usage,
	// don't consume the per-shop anti-burst budget, and skip the difficulty router
	// — so a single question makes far fewer requests and can't 429 itself.
	isContinuation := request.CountUsage != nil && !*request.CountUsage

	if !isContinuation {
		if limited, limitStatus, limitOutcome := s.enforceRateLimit(
			w,
			r,
			"ai_chat",
			aiChatRateLimitKey(installation.ID),
			s.AIChatRateLimit,
		); limited {
			statusCode = limitStatus
			outcome = limitOutcome
			return
		}
	} else {
		// count_usage is supplied by the caller, and the caller is the shop's own
		// on-prem backend — so "this is only an internal continuation" is a claim
		// the relay cannot verify. Left unbounded it makes the per-shop usage
		// limits opt-out: a token holder that marks every turn as a continuation
		// gets metered-free inference on the relay's OpenRouter key. The global
		// concurrency slot above caps in-flight work but neither rate nor cost.
		// Continuations therefore draw on their own generous per-shop window
		// (see aiContinuationPolicy) — invisible to a legitimate agentic loop,
		// but a ceiling rather than no limit at all.
		if limited, limitStatus, limitOutcome := s.enforceRateLimit(
			w,
			r,
			"ai_continuation",
			aiContinuationBudgetKey(installation.ID),
			s.aiContinuationPolicy(),
		); limited {
			statusCode = limitStatus
			outcome = limitOutcome
			return
		}
	}

	// Enforce the per-prompt image cap (also enforced client-side) before
	// consuming a usage unit.
	if maxImages := s.aiMaxImages(); maxImages > 0 && countImageAttachments(request.Attachments) > maxImages {
		statusCode = http.StatusUnprocessableEntity
		outcome = "ai_too_many_images"
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{
			"error": "too many images",
			"limit": maxImages,
		})
		return
	}

	// Per-shop usage limits (5h + weekly). Only the user-initiated turn consumes a
	// unit; continuation turns skip it. The snapshot rides the done event and
	// powers the app's usage ring.
	var usage map[string]any
	if !isContinuation {
		var (
			usageLimited bool
			usageScope   string
			usageResetAt time.Time
		)
		usage, usageLimited, usageScope, usageResetAt = s.consumeAIUsage(r.Context(), installation.ID)
		if usageLimited {
			statusCode = http.StatusTooManyRequests
			outcome = "ai_usage_limited"
			s.metrics().RecordRateLimitRejected()
			w.Header().Set("Retry-After", retryAfterSeconds(usageResetAt, s.clock().Now()))
			writeJSON(w, http.StatusTooManyRequests, map[string]any{
				"error":    "ai usage limit reached",
				"scope":    usageScope,
				"reset_at": usageResetAt,
			})
			return
		}
	}

	// Pick the model. The relay classifies the task's DIFFICULTY once, on the
	// user-initiated turn, and that tier rides the done event so Django can carry
	// it back on the continuations — the whole agentic flow runs on one dynamic
	// decision (an "add expense" stays cheap, a "PO from this invoice" escalates)
	// WITHOUT re-classifying every tool round. `routeTier` is that difficulty
	// classification; `model`/`tier` is what actually runs this turn (an attachment
	// turn must use the multimodal vision model regardless of difficulty).
	hasAttachments := len(request.Attachments) > 0
	hasTools := len(request.Tools) > 0

	// Decide whether this turn needs a live web search (current/external info the
	// shop's own data can't answer). Classified by a cheap model, launched here so
	// it overlaps the difficulty router below — near-zero added latency. Only on a
	// user-initiated, non-attachment turn (an invoice upload never needs the web).
	var webSearchCh chan bool
	if s.AIWebSearchEnabled && !isContinuation && !hasAttachments {
		webSearchCh = make(chan bool, 1)
		go func() { webSearchCh <- s.needsWebSearch(r.Context(), request.Messages) }()
	}

	isExtraction := strings.EqualFold(strings.TrimSpace(request.Purpose), "extract")

	var tier, model, routeTier string
	switch {
	case isExtraction:
		// Reading a document into a fixed schema is not a conversation: there is
		// nothing to classify, and the extraction model is chosen for vision +
		// structured output rather than for reasoning difficulty.
		tier = "extract"
		routeTier = "smart"
		model = s.aiExtractModel()
	case isContinuation:
		// Reuse the difficulty tier picked for this logical turn (carried by
		// Django). No router call — the task hasn't changed.
		routeTier = s.continuationTier(request.RouteTier)
		tier = routeTier
		model = s.resolveAIModel(tier)
	case hasAttachments:
		// Multimodal turn must run on the vision model — or the audio model when a
		// voice clip is attached — but we STILL classify difficulty (factoring in
		// the attachment + tools) so the continuations that follow inherit the
		// right tier.
		routeTier = s.routeAITier(r.Context(), request.Messages, routeSignals{attachments: true, tools: hasTools})
		tier = "vision"
		if hasAudioAttachments(request.Attachments) {
			model = s.aiAudioModel()
		} else {
			model = strings.TrimSpace(s.AIVisionModel)
		}
	case hasTools:
		routeTier = s.routeAITier(r.Context(), request.Messages, routeSignals{tools: true})
		if routeTier == "fast" {
			// Tool-calling needs a capable model; fast/small models fumble it.
			routeTier = "smart"
		}
		tier = routeTier
		model = s.resolveAIModel(tier)
	default:
		routeTier = s.routeAITier(r.Context(), request.Messages, routeSignals{})
		tier = routeTier
		model = s.resolveAIModel(tier)
	}
	if model == "" {
		statusCode = http.StatusServiceUnavailable
		outcome = "ai_unconfigured"
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "no AI model configured"})
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		statusCode = http.StatusInternalServerError
		outcome = "stream_unsupported"
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "streaming is unsupported"})
		return
	}

	// Past this point the response is a committed 200 SSE stream; failures are
	// reported as in-band SSE error events rather than HTTP status codes.
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	messages := buildAIMessages(request.Messages, request.Attachments)
	var plugins []map[string]any
	if hasFileAttachments(request.Attachments) {
		// Let OpenRouter extract text from PDFs/files for non-native models.
		plugins = []map[string]any{
			{"id": "file-parser", "pdf": map[string]any{"engine": "pdf-text"}},
		}
	}
	// Attach OpenRouter's web-search plugin when this turn needs current/external
	// info: a user turn whose classifier said yes, or a continuation that carried
	// the decision from its user turn (so an agentic web+tools flow keeps it). The
	// search_prompt suppresses inline citations — the app shows the sources as
	// favicon avatars instead — and the cited sites come back as annotations.
	webSearched := false
	switch {
	case webSearchCh != nil:
		webSearched = <-webSearchCh
	case isContinuation && s.AIWebSearchEnabled && request.WebSearch:
		webSearched = true
	}
	if webSearched {
		plugins = append(plugins, map[string]any{
			"id":            "web",
			"max_results":   s.aiWebSearchMaxResults(),
			"search_prompt": aiWebSearchResultsPrompt,
		})
	}

	client := ai.Client{
		APIKey:     s.OpenRouterAPIKey,
		BaseURL:    s.OpenRouterBaseURL,
		HTTPClient: s.aiHTTPClient(),
		Referer:    "https://pointy.app",
		Title:      "Pointy",
	}

	ctx, cancel := context.WithTimeout(r.Context(), s.aiRequestTimeout())
	defer cancel()

	// Title generation for a turn that wants one. Prefer the user's own message:
	// it's available now, so the title runs in parallel with the reply (a cheap
	// fast-model call) and is ready by the done event with no added latency.
	// Buffered so the goroutine never leaks if the done handler stops waiting.
	// When the user gave no text — a voice/attachment turn — there's nothing to
	// title from yet, so we fall back to the assistant's reply at done (below).
	userTitlePrompt := latestUserMessage(request.Messages)
	var titleCh chan string
	if request.WantTitle && userTitlePrompt != "" {
		titleCh = make(chan string, 1)
		go func() { titleCh <- s.generateTitle(ctx, userTitlePrompt) }()
	}
	// Accumulates the reply text so a no-user-text turn can still be titled.
	var replyBuf strings.Builder

	streamErr := client.StreamChat(ctx, ai.ChatRequest{
		Model:          model,
		Messages:       messages,
		MaxTokens:      request.MaxTokens,
		Temperature:    request.Temperature,
		Plugins:        plugins,
		Tools:          request.Tools,
		ResponseFormat: sanitizedResponseFormat(request.ResponseFormat),
	}, func(event ai.Event) error {
		switch event.Type {
		case ai.EventDelta:
			replyBuf.WriteString(event.Text)
			return writeSSE(w, flusher, "delta", map[string]string{"text": event.Text})
		case ai.EventReasoning:
			return writeSSE(w, flusher, "reasoning", map[string]string{"text": event.Text})
		case ai.EventToolCalls:
			return writeSSE(w, flusher, "tool_calls", map[string]any{"tool_calls": event.ToolCalls})
		case ai.EventDone:
			payload := map[string]any{
				"model":         event.Model,
				"tier":          tier,
				"route_tier":    routeTier,
				"web_search":    webSearched,
				"finish_reason": event.FinishReason,
			}
			if len(event.Sources) > 0 {
				srcs := make([]map[string]string, 0, len(event.Sources))
				for _, src := range event.Sources {
					srcs = append(srcs, map[string]string{"url": src.URL, "title": src.Title})
				}
				payload["sources"] = srcs
			}
			title := ""
			if titleCh != nil {
				// The title call usually finishes while the reply streams; a short
				// backstop keeps a slow one from holding up the done event.
				select {
				case title = <-titleCh:
				case <-time.After(3 * time.Second):
				}
			}
			// Voice/attachment turn (no user text to title from): title from the
			// assistant's reply instead, so a voice chat still gets a real name
			// rather than the attachment's filename. Generated at done since the
			// reply only exists now; the backend re-requests want_title across the
			// agentic loop until one lands, so a tools-first round is covered too.
			if title == "" && request.WantTitle && userTitlePrompt == "" {
				if reply := strings.TrimSpace(replyBuf.String()); reply != "" {
					titleCtx, titleCancel := context.WithTimeout(ctx, s.aiRouterTimeout())
					title = s.generateTitle(titleCtx, reply)
					titleCancel()
				}
			}
			if title != "" {
				payload["title"] = title
			}
			if usage != nil {
				payload["usage_limits"] = usage
			}
			if event.Usage != nil {
				payload["usage"] = event.Usage
			}
			return writeSSE(w, flusher, "done", payload)
		case ai.EventError:
			return writeSSE(w, flusher, "error", map[string]string{"detail": event.Err})
		}
		return nil
	})
	if streamErr != nil {
		outcome = "ai_stream_failed"
		s.logger().Warn("relay AI stream failed", "installation_id", installation.ID, "error", streamErr)
		// Best-effort in-band error; the client may have already disconnected.
		_ = writeSSE(w, flusher, "error", map[string]string{"detail": "ai stream failed"})
	}
}

// handleAIUsage returns the installation's current 5h + weekly usage WITHOUT
// consuming quota, so the app can render the usage ring on load.
func (s HTTPServer) handleAIUsage(w http.ResponseWriter, r *http.Request) {
	if strings.TrimSpace(s.OpenRouterAPIKey) == "" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "relay AI is not configured"})
		return
	}
	rawToken := strings.TrimSpace(r.Header.Get(AccessTokenHeader))
	if rawToken == "" {
		s.metrics().RecordCredentialRejected()
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "relay token required"})
		return
	}
	installation, err := s.Store.ValidateAIAccessToken(r.Context(), rawToken)
	if err != nil {
		s.recordAICredentialError(err)
		writeAICredentialError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"five_hour": s.peekAIWindow(r.Context(), aiUsageKey5H(installation.ID), s.AILimit5H),
		"weekly":    s.peekAIWindow(r.Context(), aiUsageKeyWeekly(installation.ID), s.AILimitWeekly),
	})
}

func (s HTTPServer) peekAIWindow(ctx context.Context, key string, policy ratelimit.Policy) map[string]any {
	if !policy.Enabled() || s.RateLimiter == nil {
		return aiWindowSnapshot(0, policy.Limit, nil)
	}
	decision, err := s.RateLimiter.Peek(ctx, key, policy)
	if err != nil {
		s.logger().Error("ai usage peek failed", "error", err)
		return aiWindowSnapshot(0, policy.Limit, nil)
	}
	used := policy.Limit - decision.Remaining
	if used < 0 {
		used = 0
	}
	reset := decision.ResetAt
	return aiWindowSnapshot(used, policy.Limit, &reset)
}

func writeSSE(w http.ResponseWriter, flusher http.Flusher, event string, data any) error {
	payload, err := json.Marshal(data)
	if err != nil {
		return err
	}
	if _, err := fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, payload); err != nil {
		return err
	}
	flusher.Flush()
	return nil
}

// resolveAIModel maps a client-supplied abstract tier to a concrete model id.
// The tier->model catalog is company config; clients only choose tiers.
func (s HTTPServer) resolveAIModel(tier string) string {
	tier = strings.ToLower(strings.TrimSpace(tier))
	if tier == "" {
		tier = strings.ToLower(strings.TrimSpace(s.AIDefaultTier))
	}
	if model := strings.TrimSpace(s.AIModelTiers[tier]); model != "" {
		return model
	}
	if fallback := strings.ToLower(strings.TrimSpace(s.AIDefaultTier)); fallback != "" && fallback != tier {
		if model := strings.TrimSpace(s.AIModelTiers[fallback]); model != "" {
			return model
		}
	}
	return ""
}

// aiAudioModel returns the model used for turns carrying a recorded voice clip.
// Audio input needs an audio-capable model; this defaults to the vision model
// (the common Gemini-class multimodal models already accept audio) unless a
// dedicated POINTY_RELAY_AI_AUDIO_MODEL is configured.
// aiExtractModel is the model used for structured document extraction. Falls
// back to the vision model, which is what read the document before this existed.
func (s HTTPServer) aiExtractModel() string {
	if model := strings.TrimSpace(s.AIExtractModel); model != "" {
		return model
	}
	return strings.TrimSpace(s.AIVisionModel)
}

func (s HTTPServer) aiAudioModel() string {
	if model := strings.TrimSpace(s.AIAudioModel); model != "" {
		return model
	}
	return strings.TrimSpace(s.AIVisionModel)
}

func (s HTTPServer) aiRequestTimeout() time.Duration {
	if s.AIRequestTimeout > 0 {
		return s.AIRequestTimeout
	}
	return defaultAIRequestTimeout
}

func (s HTTPServer) aiHTTPClient() *http.Client {
	if s.AIHTTPClient != nil {
		return s.AIHTTPClient
	}
	return &http.Client{Timeout: s.aiRequestTimeout()}
}

const defaultAIRouterTimeout = 20 * time.Second

// aiRouterSystemPrompt instructs a small model to classify request difficulty
// and reply with a single tier word.
const aiRouterSystemPrompt = "You are a routing classifier for an AI assistant. " +
	"Read the user's request and decide how much model capability it needs, based " +
	"only on difficulty. Reply with EXACTLY ONE WORD, lowercase, no punctuation: " +
	"\"fast\" for greetings, simple facts, or short trivial requests; " +
	"\"smart\" for everyday reasoning, writing, summaries, or moderate multi-step tasks; " +
	"\"frontier\" for complex reasoning, deep analysis, tricky math or logic, long or " +
	"intricate code, or expert-level problems. " +
	"A [Context] note may say the user attached a document/image to read or that " +
	"answering needs a multi-step tool task — weigh it: reading a document then " +
	"reconciling and creating records (e.g. a purchase order from an invoice) is " +
	"\"frontier\"; a single straightforward create/lookup is \"smart\". " +
	"Output only one of: fast, smart, frontier."

// routeSignals are non-text hints about a turn that inform difficulty: an attached
// document/image to read, and whether answering will use a multi-step tool flow.
type routeSignals struct {
	attachments bool
	tools       bool
}

func (rs routeSignals) describe() string {
	var parts []string
	if rs.attachments {
		parts = append(parts, "the user attached a document or image to read and act on")
	}
	if rs.tools {
		parts = append(parts, "answering may require a multi-step task using tools (querying or creating shop records)")
	}
	if len(parts) == 0 {
		return ""
	}
	return "\n\n[Context: " + strings.Join(parts, "; ") + ".]"
}

// routeAITier asks a small, cheap model to classify the request — the latest user
// message plus any non-text signals — and returns the chosen tier. Any failure
// falls back to the default tier so a router hiccup never blocks the actual reply.
func (s HTTPServer) routeAITier(ctx context.Context, messages []aiChatMessage, signals routeSignals) string {
	fallback := s.aiDefaultTier()
	// With attachments the user text may be empty; the signals alone still let the
	// classifier judge difficulty, so build the input from both.
	prompt := strings.TrimSpace(latestUserMessage(messages) + signals.describe())
	routerModel := s.aiRouterModel()
	if prompt == "" || routerModel == "" {
		return fallback
	}

	routerCtx, cancel := context.WithTimeout(ctx, s.aiRouterTimeout())
	defer cancel()

	client := ai.Client{
		APIKey:     s.OpenRouterAPIKey,
		BaseURL:    s.OpenRouterBaseURL,
		HTTPClient: s.aiHTTPClient(),
		Referer:    "https://pointy.app",
		Title:      "Pointy",
	}
	temperature := 0.0
	out, err := client.Complete(routerCtx, ai.ChatRequest{
		Model: routerModel,
		// Enough headroom for a reasoning model to think briefly and still emit
		// the tier word; normalizeTier extracts it from anywhere in the reply.
		MaxTokens:   24,
		Temperature: &temperature,
		Messages: []ai.Message{
			{Role: "system", Content: aiRouterSystemPrompt},
			{Role: "user", Content: prompt},
		},
	})
	if err != nil {
		s.logger().Warn("relay AI router failed; using default tier", "tier", fallback, "error", err)
		return fallback
	}
	return normalizeTier(out, fallback, s.AIModelTiers)
}

// aiTitleSystemPrompt instructs a small model to name a conversation.
const aiTitleSystemPrompt = "Generate a very short title for a chat conversation " +
	"from the user's first message. Reply with ONLY the title text: 2 to 5 words, " +
	"no surrounding quotes, no trailing punctuation, in the SAME language as the " +
	"user's message. Summarize the topic concisely; do not answer the message."

// generateTitle asks the cheap fast model for a short conversation title from
// “prompt“ — the user's first message when they typed one, or the assistant's
// reply when they didn't (a voice/attachment turn), so a chat always gets a real
// name. Returns "" on any failure so the caller can fall back to a truncated
// title — a missing title must never block or break a reply.
func (s HTTPServer) generateTitle(ctx context.Context, prompt string) string {
	prompt = strings.TrimSpace(prompt)
	model := s.aiRouterModel()
	if prompt == "" || model == "" {
		return ""
	}
	titleCtx, cancel := context.WithTimeout(ctx, s.aiRouterTimeout())
	defer cancel()

	client := ai.Client{
		APIKey:     s.OpenRouterAPIKey,
		BaseURL:    s.OpenRouterBaseURL,
		HTTPClient: s.aiHTTPClient(),
		Referer:    "https://pointy.app",
		Title:      "Pointy",
	}
	temperature := 0.3
	out, err := client.Complete(titleCtx, ai.ChatRequest{
		Model:       model,
		MaxTokens:   24,
		Temperature: &temperature,
		Messages: []ai.Message{
			{Role: "system", Content: aiTitleSystemPrompt},
			{Role: "user", Content: prompt},
		},
	})
	if err != nil {
		s.logger().Warn("relay AI title generation failed", "error", err)
		return ""
	}
	return cleanTitle(out)
}

// cleanTitle normalizes a model's title reply: first line, no wrapping quotes or
// label prefix, collapsed whitespace, capped length.
func cleanTitle(raw string) string {
	title := strings.TrimSpace(raw)
	if idx := strings.IndexAny(title, "\r\n"); idx >= 0 {
		title = strings.TrimSpace(title[:idx])
	}
	// Drop a leading "Title:" / "العنوان:" style label.
	if idx := strings.Index(title, ":"); idx >= 0 && idx <= 12 {
		title = strings.TrimSpace(title[idx+1:])
	}
	title = strings.Trim(title, " \t\"'`«»“”.،,")
	title = strings.Join(strings.Fields(title), " ")
	const maxRunes = 60
	if runes := []rune(title); len(runes) > maxRunes {
		title = strings.TrimSpace(string(runes[:maxRunes]))
	}
	return title
}

// aiWebSearchSystemPrompt instructs a small model to decide if a query needs the web.
const aiWebSearchSystemPrompt = "You decide whether answering a user's message needs a live web search for " +
	"current, external information. The assistant is a point-of-sale shop assistant whose own tools already cover " +
	"the shop's data (sales, products, inventory, customers, expenses, suppliers, employees). Reply with EXACTLY " +
	"ONE WORD, lowercase: \"yes\" if the answer needs up-to-date or general knowledge from the web that the shop's " +
	"database cannot provide — current events, news, prices or exchange rates, weather, public facts, anything " +
	"time-sensitive or about the outside world; \"no\" for greetings, small talk, or anything about the shop's own " +
	"data. Output only yes or no."

// aiWebSearchResultsPrompt is inserted before the injected web results. It tells
// the model to answer cleanly WITHOUT inline citations — the app surfaces the
// cited sites (from the response annotations) as favicon avatars instead.
const aiWebSearchResultsPrompt = "A web search was run for the user's question; relevant results follow. " +
	"Use them to answer accurately and concisely in the user's language. Write a clean, natural answer with NO " +
	"inline citations, footnote markers, bracketed numbers, source lists, or raw URLs — the sources are shown to " +
	"the user separately."

// needsWebSearch asks the cheap router model whether the latest user message needs
// a live web search. Fails CLOSED (no search) on any error, so a classifier hiccup
// never adds an unwanted search or blocks the reply.
func (s HTTPServer) needsWebSearch(ctx context.Context, messages []aiChatMessage) bool {
	prompt := latestUserMessage(messages)
	model := s.aiRouterModel()
	if prompt == "" || model == "" {
		return false
	}
	searchCtx, cancel := context.WithTimeout(ctx, s.aiRouterTimeout())
	defer cancel()

	client := ai.Client{
		APIKey:     s.OpenRouterAPIKey,
		BaseURL:    s.OpenRouterBaseURL,
		HTTPClient: s.aiHTTPClient(),
		Referer:    "https://pointy.app",
		Title:      "Pointy",
	}
	temperature := 0.0
	out, err := client.Complete(searchCtx, ai.ChatRequest{
		Model:       model,
		MaxTokens:   16,
		Temperature: &temperature,
		Messages: []ai.Message{
			{Role: "system", Content: aiWebSearchSystemPrompt},
			{Role: "user", Content: prompt},
		},
	})
	if err != nil {
		s.logger().Warn("relay AI web-search classifier failed; skipping search", "error", err)
		return false
	}
	return strings.Contains(strings.ToLower(out), "yes")
}

func (s HTTPServer) aiWebSearchMaxResults() int {
	if s.AIWebSearchMaxResults > 0 {
		return s.AIWebSearchMaxResults
	}
	return 3
}

func latestUserMessage(messages []aiChatMessage) string {
	for i := len(messages) - 1; i >= 0; i-- {
		if strings.EqualFold(strings.TrimSpace(messages[i].Role), "user") {
			return strings.TrimSpace(messages[i].Content)
		}
	}
	return ""
}

// normalizeTier extracts a configured tier from the router's free-form reply,
// preferring the most capable tier mentioned.
func normalizeTier(raw string, fallback string, tiers map[string]string) string {
	lower := strings.ToLower(raw)
	for _, tier := range []string{"frontier", "smart", "fast"} {
		if strings.Contains(lower, tier) {
			if _, ok := tiers[tier]; ok {
				return tier
			}
		}
	}
	return fallback
}

func (s HTTPServer) aiDefaultTier() string {
	if tier := strings.ToLower(strings.TrimSpace(s.AIDefaultTier)); tier != "" {
		return tier
	}
	return "smart"
}

// continuationTier resolves the difficulty tier a tool-loop continuation should
// ride: the tier Django carried from this turn's first request (the relay's own
// earlier classification), validated against the configured tiers. An agentic
// continuation never rides the fast tier (fast models fumble tool-calling); an
// empty/unknown hint falls back to "smart" — the prior behaviour.
func (s HTTPServer) continuationTier(hint string) string {
	hint = strings.ToLower(strings.TrimSpace(hint))
	if _, ok := s.AIModelTiers[hint]; ok && hint != "fast" {
		return hint
	}
	return "smart"
}

func (s HTTPServer) aiRouterModel() string {
	if model := strings.TrimSpace(s.AIRouterModel); model != "" {
		return model
	}
	// Default to the fast tier — cheap and quick for a one-word classification.
	if model := strings.TrimSpace(s.AIModelTiers["fast"]); model != "" {
		return model
	}
	return s.resolveAIModel(s.aiDefaultTier())
}

func (s HTTPServer) aiRouterTimeout() time.Duration {
	if s.AIRequestTimeout > 0 && s.AIRequestTimeout < defaultAIRouterTimeout {
		return s.AIRequestTimeout
	}
	return defaultAIRouterTimeout
}

func (s HTTPServer) aiMaxRequestBytes() int64 {
	if s.AIMaxRequestBytes > 0 {
		return s.AIMaxRequestBytes
	}
	return defaultAIMaxRequestBytes
}

func (s HTTPServer) aiMaxImages() int {
	if s.AIMaxImagesPerPrompt > 0 {
		return s.AIMaxImagesPerPrompt
	}
	return defaultAIMaxImagesPerPrompt
}

func countImageAttachments(attachments []aiAttachment) int {
	count := 0
	for _, a := range attachments {
		if strings.EqualFold(strings.TrimSpace(a.Kind), "image") {
			count++
		}
	}
	return count
}

// hasFileAttachments reports whether any attachment is a document/file (not an
// image and not audio), gating the OpenRouter file-parser plugin so an
// audio-only turn doesn't drag in PDF parsing it can't use.
func hasFileAttachments(attachments []aiAttachment) bool {
	for _, a := range attachments {
		kind := strings.TrimSpace(a.Kind)
		if !strings.EqualFold(kind, "image") && !strings.EqualFold(kind, "audio") {
			return true
		}
	}
	return false
}

func hasAudioAttachments(attachments []aiAttachment) bool {
	for _, a := range attachments {
		if strings.EqualFold(strings.TrimSpace(a.Kind), "audio") {
			return true
		}
	}
	return false
}

// decodeAudioDataURI splits a base64 audio data URI into its raw base64 payload
// (OpenAI's input_audio part wants the payload WITHOUT the "data:...;base64,"
// prefix) and a short format token ("wav"/"mp3"), derived from the URI's media
// type and falling back to the attachment MIME.
func decodeAudioDataURI(dataURI, mime string) (string, string) {
	payload := dataURI
	mediaType := strings.TrimSpace(mime)
	if strings.HasPrefix(dataURI, "data:") {
		if comma := strings.IndexByte(dataURI, ','); comma >= 0 {
			header := dataURI[len("data:"):comma]
			payload = dataURI[comma+1:]
			if semi := strings.IndexByte(header, ';'); semi >= 0 {
				mediaType = header[:semi]
			} else {
				mediaType = header
			}
		}
	}
	return payload, audioFormatFromMediaType(mediaType)
}

// audioFormatFromMediaType maps an audio media type to the format token an
// input_audio part expects. Defaults to "wav" — the format the app records.
func audioFormatFromMediaType(mediaType string) string {
	switch strings.ToLower(strings.TrimSpace(mediaType)) {
	case "audio/mpeg", "audio/mp3":
		return "mp3"
	default:
		return "wav"
	}
}

// buildAIMessages converts the wire messages to ai.Message, attaching any
// images/files to the last user turn as multimodal content parts.
func buildAIMessages(msgs []aiChatMessage, attachments []aiAttachment) []ai.Message {
	lastUser := -1
	for i, m := range msgs {
		if strings.EqualFold(strings.TrimSpace(m.Role), "user") {
			lastUser = i
		}
	}
	out := make([]ai.Message, 0, len(msgs))
	for i, m := range msgs {
		if i != lastUser || len(attachments) == 0 {
			out = append(out, ai.Message{
				Role:       m.Role,
				Content:    m.Content,
				ToolCalls:  m.ToolCalls,
				ToolCallID: m.ToolCallID,
				Name:       m.Name,
			})
			continue
		}
		parts := []ai.ContentPart{{Type: "text", Text: m.Content}}
		for _, a := range attachments {
			switch {
			case strings.EqualFold(strings.TrimSpace(a.Kind), "image"):
				parts = append(parts, ai.ContentPart{Type: "image_url", ImageURL: a.DataURI})
			case strings.EqualFold(strings.TrimSpace(a.Kind), "audio"):
				data, format := decodeAudioDataURI(a.DataURI, a.MIME)
				parts = append(parts, ai.ContentPart{Type: "input_audio", AudioData: data, AudioFormat: format})
			default:
				name := strings.TrimSpace(a.Name)
				if name == "" {
					name = "file"
				}
				parts = append(parts, ai.ContentPart{Type: "file", FileName: name, FileData: a.DataURI})
			}
		}
		out = append(out, ai.Message{Role: m.Role, Parts: parts})
	}
	return out
}

func aiUsageKey5H(installationID string) string {
	return "ai-usage-5h:" + strings.TrimSpace(installationID)
}

func aiUsageKeyWeekly(installationID string) string {
	return "ai-usage-week:" + strings.TrimSpace(installationID)
}

// consumeAIUsage charges one unit against the 5h + weekly windows and returns a
// snapshot (for the done event) plus whether either window is now exhausted.
// Limiter errors fail open (a Redis blip must not block paying shops).
func (s HTTPServer) consumeAIUsage(
	ctx context.Context,
	installationID string,
) (map[string]any, bool, string, time.Time) {
	usage := map[string]any{}
	limited := false
	scope := ""
	var resetAt time.Time

	charge := func(name, key string, policy ratelimit.Policy) {
		if !policy.Enabled() || s.RateLimiter == nil {
			usage[name] = aiWindowSnapshot(0, policy.Limit, nil)
			return
		}
		decision, err := s.RateLimiter.Allow(ctx, key, policy)
		if err != nil {
			s.logger().Error("ai usage limiter failed", "scope", name, "error", err)
			usage[name] = aiWindowSnapshot(0, policy.Limit, nil)
			return
		}
		used := policy.Limit - decision.Remaining
		if used < 0 {
			used = 0
		}
		reset := decision.ResetAt
		usage[name] = aiWindowSnapshot(used, policy.Limit, &reset)
		if !decision.Allowed && !limited {
			limited = true
			scope = name
			resetAt = decision.ResetAt
		}
	}

	charge("five_hour", aiUsageKey5H(installationID), s.AILimit5H)
	charge("weekly", aiUsageKeyWeekly(installationID), s.AILimitWeekly)
	return usage, limited, scope, resetAt
}

func aiWindowSnapshot(used, limit int, resetAt *time.Time) map[string]any {
	snapshot := map[string]any{
		"used":      used,
		"limit":     limit,
		"remaining": max(limit-used, 0),
	}
	if resetAt != nil {
		snapshot["reset_at"] = *resetAt
	}
	return snapshot
}

func aiChatRateLimitKey(installationID string) string {
	return "ai-chat:" + strings.TrimSpace(installationID)
}

func aiContinuationBudgetKey(installationID string) string {
	return "ai-continuation:" + strings.TrimSpace(installationID)
}

// aiContinuationBudgetMultiple sizes the unmetered continuation window relative
// to the metered 5h limit. Django caps one question at MAX_TOOL_ITERS (10)
// continuation turns, and the daily dashboard digest adds a handful more, so
// 20x the metered allowance clears the worst legitimate case with room to spare
// while keeping the unmetered path bounded.
const aiContinuationBudgetMultiple = 20

// aiContinuationPolicy is the window continuation turns draw on. It rides the
// metered 5h policy so it needs no separate configuration, and stays disabled
// whenever usage metering itself is disabled (unlimited plans keep behaving
// exactly as before).
func (s HTTPServer) aiContinuationPolicy() ratelimit.Policy {
	if !s.AILimit5H.Enabled() {
		return ratelimit.Policy{}
	}
	return ratelimit.Policy{
		Limit:  s.AILimit5H.Limit * aiContinuationBudgetMultiple,
		Window: s.AILimit5H.Window,
	}
}

func aiCredentialStatusCode(err error) int {
	if errors.Is(err, control.ErrAINotEntitled) || errors.Is(err, control.ErrSubscriptionInactive) {
		return http.StatusPaymentRequired
	}
	return http.StatusUnauthorized
}

func aiCredentialOutcome(err error) string {
	switch {
	case errors.Is(err, control.ErrAINotEntitled):
		return "ai_not_entitled"
	case errors.Is(err, control.ErrSubscriptionInactive):
		return "subscription_rejected"
	default:
		return "credential_rejected"
	}
}

func (s HTTPServer) recordAICredentialError(err error) {
	if errors.Is(err, control.ErrAINotEntitled) || errors.Is(err, control.ErrSubscriptionInactive) {
		s.metrics().RecordSubscriptionRejected()
		return
	}
	s.metrics().RecordCredentialRejected()
}

func writeAICredentialError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, control.ErrAINotEntitled):
		writeJSON(w, http.StatusPaymentRequired, map[string]string{"error": "relay AI not entitled"})
	case errors.Is(err, control.ErrSubscriptionInactive):
		writeJSON(w, http.StatusPaymentRequired, map[string]string{"error": "relay subscription inactive"})
	default:
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "relay token rejected"})
	}
}
