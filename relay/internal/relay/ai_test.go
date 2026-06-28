package relay

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/observability"
	"pointy/relay/internal/ratelimit"
)

// stubOpenRouterServer serves both the router's non-streaming classification
// call (returns routedTier) and the streaming chat call (echoes the requested
// model so tests can assert which tier was selected).
func stubOpenRouterServer(t *testing.T, routedTier string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/chat/completions") {
			http.NotFound(w, r)
			return
		}
		var body struct {
			Model  string `json:"model"`
			Stream bool   `json:"stream"`
		}
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)

		if !body.Stream {
			// Router classification call.
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{
				"choices": []map[string]any{
					{"message": map[string]any{"role": "assistant", "content": routedTier}},
				},
			})
			return
		}

		// Streaming chat call: echo the requested model so tests can assert routing.
		w.Header().Set("Content-Type", "text/event-stream")
		flusher, _ := w.(http.Flusher)
		for _, chunk := range []string{
			fmt.Sprintf(`data: {"model":%q,"choices":[{"delta":{"reasoning":"Let me think"}}]}`, body.Model),
			fmt.Sprintf(`data: {"model":%q,"choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}`, body.Model),
			fmt.Sprintf(`data: {"model":%q,"choices":[{"delta":{"content":" world"},"finish_reason":"stop"}]}`, body.Model),
			fmt.Sprintf(`data: {"model":%q,"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}`, body.Model),
			`data: [DONE]`,
		} {
			_, _ = io.WriteString(w, chunk+"\n\n")
			if flusher != nil {
				flusher.Flush()
			}
		}
	}))
}

func newAITestServer(t *testing.T, store control.InstallationStore, openRouterURL string) HTTPServer {
	t.Helper()
	return HTTPServer{
		Store:             store,
		Hub:               NewHub(),
		Logger:            slog.New(slog.NewTextHandler(io.Discard, nil)),
		Metrics:           observability.NewMetrics(),
		OpenRouterAPIKey:  "test-key",
		OpenRouterBaseURL: openRouterURL,
		AIModelTiers: map[string]string{
			"fast":     "test/fast",
			"smart":    "test/smart",
			"frontier": "test/frontier",
		},
		AIDefaultTier: "smart",
	}
}

func provisionAIInstallation(t *testing.T, now time.Time) (control.InstallationStore, control.ProvisionedInstallation) {
	t.Helper()
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), testClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	relayDisabled := false
	provisioned, err := store.ProvisionInstallation(context.Background(), control.ProvisionInstallationRequest{
		RelayEnabled:       &relayDisabled,
		SubscriptionActive: &enabled,
		AIEnabled:          true,
	})
	if err != nil {
		t.Fatal(err)
	}
	return store, provisioned
}

func TestHandleAIChatStreamsForEntitledInstallation(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionAIInstallation(t, now)

	openrouter := stubOpenRouterServer(t, "smart")
	defer openrouter.Close()
	server := newAITestServer(t, store, openrouter.URL)

	// No tier is ever sent; the relay always routes (stub router returns "smart").
	body := strings.NewReader(`{"messages":[{"role":"user","content":"hi"}]}`)
	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", body)
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", response.StatusCode)
	}
	if ct := response.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/event-stream") {
		t.Fatalf("expected SSE content type, got %q", ct)
	}
	payload := recorder.Body.String()
	if !strings.Contains(payload, "event: delta") || !strings.Contains(payload, `"text":"Hello"`) || !strings.Contains(payload, `"text":" world"`) {
		t.Fatalf("expected delta events, got %q", payload)
	}
	if !strings.Contains(payload, "event: reasoning") || !strings.Contains(payload, `"text":"Let me think"`) {
		t.Fatalf("expected reasoning events, got %q", payload)
	}
	if !strings.Contains(payload, "event: done") || !strings.Contains(payload, `"total_tokens":7`) {
		t.Fatalf("expected done event with usage, got %q", payload)
	}
	if !strings.Contains(payload, `"tier":"smart"`) || !strings.Contains(payload, `"model":"test/smart"`) {
		t.Fatalf("expected auto-route to the smart tier, got %q", payload)
	}
	if outcome := server.Metrics.Snapshot().RelayRequestsByOutcome["ai_chat_ok"]; outcome != 1 {
		t.Fatalf("expected ai_chat_ok metric, got %#v", server.Metrics.Snapshot().RelayRequestsByOutcome)
	}
}

func TestHandleAIChatAutoRoutesWhenNoTier(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionAIInstallation(t, now)

	// The router classifies the prompt as "frontier".
	openrouter := stubOpenRouterServer(t, "frontier")
	defer openrouter.Close()
	server := newAITestServer(t, store, openrouter.URL)

	// No tier supplied -> the relay routes by difficulty.
	body := strings.NewReader(`{"messages":[{"role":"user","content":"Prove the Riemann hypothesis."}]}`)
	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", body)
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", response.StatusCode)
	}
	payload := recorder.Body.String()
	if !strings.Contains(payload, `"tier":"frontier"`) || !strings.Contains(payload, `"model":"test/frontier"`) {
		t.Fatalf("expected auto-route to the frontier tier, got %q", payload)
	}
}

func TestHandleAIChatRejectsUnentitledInstallation(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), testClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	provisioned, err := store.ProvisionInstallation(context.Background(), control.ProvisionInstallationRequest{
		SubscriptionActive: &enabled,
		AIEnabled:          false,
	})
	if err != nil {
		t.Fatal(err)
	}

	server := newAITestServer(t, store, "http://openrouter.invalid")
	body := strings.NewReader(`{"messages":[{"role":"user","content":"hi"}]}`)
	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", body)
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusPaymentRequired {
		t.Fatalf("expected 402, got %d", response.StatusCode)
	}
	if outcome := server.Metrics.Snapshot().RelayRequestsByOutcome["ai_not_entitled"]; outcome != 1 {
		t.Fatalf("expected ai_not_entitled metric, got %#v", server.Metrics.Snapshot().RelayRequestsByOutcome)
	}
}

func TestHandleAIChatRequiresToken(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), testClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	server := newAITestServer(t, store, "http://openrouter.invalid")

	body := strings.NewReader(`{"messages":[{"role":"user","content":"hi"}]}`)
	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", body)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", response.StatusCode)
	}
}

func TestNormalizeTier(t *testing.T) {
	tiers := map[string]string{"fast": "f", "smart": "s", "frontier": "fr"}
	cases := map[string]string{
		"fast":                     "fast",
		"  SMART ":                 "smart",
		"frontier.":                "frontier",
		"I think this is frontier": "frontier",
		"nonsense":                 "smart", // fallback
		"":                         "smart", // fallback
	}
	for input, want := range cases {
		if got := normalizeTier(input, "smart", tiers); got != want {
			t.Fatalf("normalizeTier(%q) = %q, want %q", input, got, want)
		}
	}
	// An unconfigured tier falls back even if named.
	if got := normalizeTier("frontier", "fast", map[string]string{"fast": "f"}); got != "fast" {
		t.Fatalf("expected fallback when tier unconfigured, got %q", got)
	}
}

func TestLatestUserMessage(t *testing.T) {
	messages := []aiChatMessage{
		{Role: "system", Content: "sys"},
		{Role: "user", Content: "first"},
		{Role: "assistant", Content: "reply"},
		{Role: "user", Content: "  second  "},
	}
	if got := latestUserMessage(messages); got != "second" {
		t.Fatalf("latestUserMessage = %q, want %q", got, "second")
	}
	if got := latestUserMessage(nil); got != "" {
		t.Fatalf("expected empty for no messages, got %q", got)
	}
}

func TestBuildAIMessagesAttachesToLastUser(t *testing.T) {
	msgs := []aiChatMessage{
		{Role: "system", Content: "sys"},
		{Role: "user", Content: "first"},
		{Role: "assistant", Content: "reply"},
		{Role: "user", Content: "look at this"},
	}
	attachments := []aiAttachment{
		{Kind: "image", DataURI: "data:image/jpeg;base64,AAAA", Name: "a.jpg"},
		{Kind: "file", DataURI: "data:application/pdf;base64,BBBB", Name: "b.pdf"},
	}
	out := buildAIMessages(msgs, attachments)
	if len(out) != 4 {
		t.Fatalf("expected 4 messages, got %d", len(out))
	}
	if out[1].Content != "first" || len(out[1].Parts) != 0 {
		t.Fatalf("non-last user message should stay text: %#v", out[1])
	}
	last := out[3]
	if len(last.Parts) != 3 {
		t.Fatalf("expected text + 2 attachment parts, got %#v", last.Parts)
	}
	if last.Parts[0].Type != "text" || last.Parts[0].Text != "look at this" {
		t.Fatalf("first part should be the text: %#v", last.Parts[0])
	}
	if last.Parts[1].Type != "image_url" || last.Parts[1].ImageURL == "" {
		t.Fatalf("expected image part: %#v", last.Parts[1])
	}
	if last.Parts[2].Type != "file" || last.Parts[2].FileName != "b.pdf" {
		t.Fatalf("expected file part: %#v", last.Parts[2])
	}
}

func TestBuildAIMessagesAudioPart(t *testing.T) {
	msgs := []aiChatMessage{{Role: "user", Content: ""}}
	attachments := []aiAttachment{
		{Kind: "audio", DataURI: "data:audio/wav;base64,QUJD", Name: "voice-message.wav", MIME: "audio/wav"},
	}
	out := buildAIMessages(msgs, attachments)
	if len(out) != 1 {
		t.Fatalf("expected 1 message, got %d", len(out))
	}
	last := out[0]
	if len(last.Parts) != 2 {
		t.Fatalf("expected text + audio part, got %#v", last.Parts)
	}
	audio := last.Parts[1]
	if audio.Type != "input_audio" {
		t.Fatalf("expected input_audio part, got %#v", audio)
	}
	// OpenAI's input_audio wants the bare base64, NOT the data: URI.
	if audio.AudioData != "QUJD" {
		t.Fatalf("expected stripped base64 payload, got %q", audio.AudioData)
	}
	if audio.AudioFormat != "wav" {
		t.Fatalf("expected wav format, got %q", audio.AudioFormat)
	}
}

func TestDecodeAudioDataURI(t *testing.T) {
	cases := []struct {
		name     string
		dataURI  string
		mime     string
		wantData string
		wantFmt  string
	}{
		{"wav data uri", "data:audio/wav;base64,QUJD", "audio/wav", "QUJD", "wav"},
		{"mpeg media type", "data:audio/mpeg;base64,ZZZ", "", "ZZZ", "mp3"},
		{"bare base64 uses mime", "QUJD", "audio/mpeg", "QUJD", "mp3"},
		{"unknown defaults to wav", "data:application/octet-stream;base64,QQ", "", "QQ", "wav"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			data, format := decodeAudioDataURI(tc.dataURI, tc.mime)
			if data != tc.wantData || format != tc.wantFmt {
				t.Fatalf("decodeAudioDataURI(%q,%q) = (%q,%q), want (%q,%q)",
					tc.dataURI, tc.mime, data, format, tc.wantData, tc.wantFmt)
			}
		})
	}
}

func TestHasFileAttachmentsExcludesImageAndAudio(t *testing.T) {
	if hasFileAttachments([]aiAttachment{{Kind: "audio"}}) {
		t.Fatal("audio must not count as a file attachment (no PDF parser plugin)")
	}
	if hasFileAttachments([]aiAttachment{{Kind: "image"}}) {
		t.Fatal("image must not count as a file attachment")
	}
	if !hasFileAttachments([]aiAttachment{{Kind: "file"}}) {
		t.Fatal("a file attachment must be detected")
	}
}

func TestHandleAIChatRoutesAttachmentsToVisionModel(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionAIInstallation(t, now)
	openrouter := stubOpenRouterServer(t, "smart") // router result is unused for attachments
	defer openrouter.Close()
	server := newAITestServer(t, store, openrouter.URL)
	server.AIVisionModel = "test/vision"

	body := strings.NewReader(`{"messages":[{"role":"user","content":"what is this?"}],"attachments":[{"kind":"image","data_uri":"data:image/png;base64,AAAA","name":"x.png"}]}`)
	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", body)
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", response.StatusCode)
	}
	payload := recorder.Body.String()
	if !strings.Contains(payload, `"tier":"vision"`) || !strings.Contains(payload, `"model":"test/vision"`) {
		t.Fatalf("expected vision routing, got %q", payload)
	}
}

func TestHandleAIChatRoutesAudioToAudioModel(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionAIInstallation(t, now)
	openrouter := stubOpenRouterServer(t, "smart")
	defer openrouter.Close()
	server := newAITestServer(t, store, openrouter.URL)
	server.AIVisionModel = "test/vision"
	server.AIAudioModel = "test/audio"

	body := strings.NewReader(`{"messages":[{"role":"user","content":""}],"attachments":[{"kind":"audio","data_uri":"data:audio/wav;base64,AAAA","name":"voice-message.wav","mime":"audio/wav"}]}`)
	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", body)
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", response.StatusCode)
	}
	payload := recorder.Body.String()
	if !strings.Contains(payload, `"model":"test/audio"`) {
		t.Fatalf("expected audio routing to test/audio, got %q", payload)
	}
}

func TestHandleAIChatAudioFallsBackToVisionModel(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionAIInstallation(t, now)
	openrouter := stubOpenRouterServer(t, "smart")
	defer openrouter.Close()
	server := newAITestServer(t, store, openrouter.URL)
	server.AIVisionModel = "test/vision"
	// No AIAudioModel configured → audio rides the vision model.

	body := strings.NewReader(`{"messages":[{"role":"user","content":""}],"attachments":[{"kind":"audio","data_uri":"data:audio/wav;base64,AAAA","mime":"audio/wav"}]}`)
	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", body)
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	payload := recorder.Body.String()
	if !strings.Contains(payload, `"model":"test/vision"`) {
		t.Fatalf("expected audio to fall back to the vision model, got %q", payload)
	}
}

func TestHandleAIChatContinuationInheritsCarriedTier(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionAIInstallation(t, now)
	// The router would say "fast"; a continuation must NOT route — it rides the
	// tier carried from the turn's first request (the relay's earlier decision).
	openrouter := stubOpenRouterServer(t, "fast")
	defer openrouter.Close()
	server := newAITestServer(t, store, openrouter.URL)

	body := strings.NewReader(`{"messages":[{"role":"user","content":"continue"}],"count_usage":false,"route_tier":"frontier"}`)
	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", body)
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", response.StatusCode)
	}
	payload := recorder.Body.String()
	if !strings.Contains(payload, `"tier":"frontier"`) || !strings.Contains(payload, `"model":"test/frontier"`) {
		t.Fatalf("expected continuation to inherit the carried frontier tier, got %q", payload)
	}
}

func TestHandleAIChatContinuationFloorsAndDefaults(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionAIInstallation(t, now)
	openrouter := stubOpenRouterServer(t, "frontier")
	defer openrouter.Close()
	server := newAITestServer(t, store, openrouter.URL)

	// An unhinted continuation defaults to smart; a "fast" hint floors to smart
	// (agentic continuations never ride the tool-fumbling fast tier).
	for _, hint := range []string{`""`, `"fast"`, `"bogus"`} {
		body := strings.NewReader(`{"messages":[{"role":"user","content":"x"}],"count_usage":false,"route_tier":` + hint + `}`)
		request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", body)
		request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
		recorder := httptest.NewRecorder()
		server.ServeHTTP(recorder, request)
		payload := recorder.Body.String()
		if !strings.Contains(payload, `"tier":"smart"`) || !strings.Contains(payload, `"model":"test/smart"`) {
			t.Fatalf("hint %s: expected smart, got %q", hint, payload)
		}
	}
}

func TestHandleAIChatGeneratesTitleOnFirstTurn(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionAIInstallation(t, now)
	// The stub returns this for any non-streaming Complete call (router + title).
	openrouter := stubOpenRouterServer(t, "topic")
	defer openrouter.Close()
	server := newAITestServer(t, store, openrouter.URL)

	body := strings.NewReader(`{"messages":[{"role":"user","content":"أكثر المنتجات مبيعًا"}],"want_title":true}`)
	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", body)
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)

	payload := recorder.Body.String()
	if !strings.Contains(payload, `"title":"topic"`) {
		t.Fatalf("expected a generated title in the done event, got %q", payload)
	}
}

func TestHandleAIChatTitlesVoiceTurnFromReply(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionAIInstallation(t, now)
	// The stub returns this for any non-streaming Complete call (the title here).
	openrouter := stubOpenRouterServer(t, "topic")
	defer openrouter.Close()
	server := newAITestServer(t, store, openrouter.URL)
	server.AIVisionModel = "test/vision" // audio defaults to the vision model

	// A voice turn: no user text, only an audio attachment. The title can't come
	// from the (empty) user message, so it's generated from the assistant reply.
	body := strings.NewReader(`{"messages":[{"role":"user","content":""}],` +
		`"attachments":[{"kind":"audio","data_uri":"data:audio/wav;base64,QUJD","name":"voice-message.wav","mime":"audio/wav"}],` +
		`"want_title":true}`)
	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", body)
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)

	payload := recorder.Body.String()
	if !strings.Contains(payload, `"title":"topic"`) {
		t.Fatalf("expected a reply-derived title for the voice turn, got %q", payload)
	}
}

func TestHandleAIChatSkipsTitleWhenNotRequested(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionAIInstallation(t, now)
	openrouter := stubOpenRouterServer(t, "smart")
	defer openrouter.Close()
	server := newAITestServer(t, store, openrouter.URL)

	// want_title omitted → no title side call, no title in the done event.
	body := strings.NewReader(`{"messages":[{"role":"user","content":"hi"}]}`)
	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", body)
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)

	if payload := recorder.Body.String(); strings.Contains(payload, `"title"`) {
		t.Fatalf("did not expect a title, got %q", payload)
	}
}

func TestCleanTitle(t *testing.T) {
	cases := map[string]string{
		`"أكثر المنتجات مبيعًا"`:    "أكثر المنتجات مبيعًا",
		"Title: Sales report":      "Sales report",
		"  spaced   out  title  ":  "spaced out title",
		"line one\nline two":       "line one",
		"trailing punctuation.":    "trailing punctuation",
	}
	for in, want := range cases {
		if got := cleanTitle(in); got != want {
			t.Errorf("cleanTitle(%q) = %q, want %q", in, got, want)
		}
	}
	long := strings.Repeat("ا", 100)
	if got := cleanTitle(long); len([]rune(got)) != 60 {
		t.Errorf("expected a 60-rune cap, got %d runes", len([]rune(got)))
	}
}

// recordingOpenRouterServer captures the streaming request body so a test can
// assert which plugins were attached; non-streaming (classifier) calls return
// classifierReply.
func recordingOpenRouterServer(t *testing.T, classifierReply string, captured *string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/chat/completions") {
			http.NotFound(w, r)
			return
		}
		raw, _ := io.ReadAll(r.Body)
		var body struct {
			Model  string `json:"model"`
			Stream bool   `json:"stream"`
		}
		_ = json.Unmarshal(raw, &body)
		if !body.Stream {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{
				"choices": []map[string]any{
					{"message": map[string]any{"role": "assistant", "content": classifierReply}},
				},
			})
			return
		}
		*captured = string(raw)
		w.Header().Set("Content-Type", "text/event-stream")
		flusher, _ := w.(http.Flusher)
		for _, chunk := range []string{
			fmt.Sprintf(`data: {"model":%q,"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}`, body.Model),
			`data: [DONE]`,
		} {
			_, _ = io.WriteString(w, chunk+"\n\n")
			if flusher != nil {
				flusher.Flush()
			}
		}
	}))
}

func webSearchStreamBody(t *testing.T, classifierReply string, configure func(*HTTPServer), reqBody string) string {
	t.Helper()
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionAIInstallation(t, now)
	var captured string
	openrouter := recordingOpenRouterServer(t, classifierReply, &captured)
	defer openrouter.Close()
	server := newAITestServer(t, store, openrouter.URL)
	server.AIWebSearchEnabled = true
	if configure != nil {
		configure(&server)
	}
	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", strings.NewReader(reqBody))
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	return captured
}

func TestHandleAIChatAddsWebSearchPluginWhenNeeded(t *testing.T) {
	body := webSearchStreamBody(
		t, "yes", nil,
		`{"messages":[{"role":"user","content":"كم سعر صرف الدولار اليوم؟"}]}`,
	)
	if !strings.Contains(body, `"id":"web"`) {
		t.Fatalf("expected the web plugin to be attached, got %q", body)
	}
	// The search_prompt suppresses inline citations (the app shows favicons).
	if !strings.Contains(body, `"search_prompt"`) {
		t.Fatalf("expected a citation-suppressing search_prompt, got %q", body)
	}
}

func TestHandleAIChatCarriesWebSearchOntoContinuation(t *testing.T) {
	// A continuation doesn't classify — it rides the web decision carried from its
	// user turn, so an agentic web+tools flow keeps searching on the answer round.
	body := webSearchStreamBody(
		t, "no", nil,
		`{"messages":[{"role":"user","content":"x"}],"count_usage":false,"web_search":true}`,
	)
	if !strings.Contains(body, `"id":"web"`) {
		t.Fatalf("expected the web plugin carried onto the continuation, got %q", body)
	}
}

func TestHandleAIChatSkipsWebSearchWhenNotNeeded(t *testing.T) {
	body := webSearchStreamBody(
		t, "no", nil,
		`{"messages":[{"role":"user","content":"كم مبيعات اليوم؟"}]}`,
	)
	if strings.Contains(body, `"id":"web"`) {
		t.Fatalf("did not expect the web plugin, got %q", body)
	}
}

func TestHandleAIChatSkipsWebSearchOnContinuation(t *testing.T) {
	// A continuation never web-searches (and the classifier isn't even consulted).
	body := webSearchStreamBody(
		t, "yes", nil,
		`{"messages":[{"role":"user","content":"x"}],"count_usage":false}`,
	)
	if strings.Contains(body, `"id":"web"`) {
		t.Fatalf("a continuation must not web-search, got %q", body)
	}
}

func TestHandleAIChatSkipsWebSearchWhenDisabled(t *testing.T) {
	body := webSearchStreamBody(
		t, "yes",
		func(s *HTTPServer) { s.AIWebSearchEnabled = false },
		`{"messages":[{"role":"user","content":"كم سعر الذهب؟"}]}`,
	)
	if strings.Contains(body, `"id":"web"`) {
		t.Fatalf("web search disabled, got %q", body)
	}
}

func TestHandleAIChatRejectsTooManyImages(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionAIInstallation(t, now)
	server := newAITestServer(t, store, "http://openrouter.invalid")
	server.AIVisionModel = "test/vision"
	server.AIMaxImagesPerPrompt = 1

	body := strings.NewReader(`{"messages":[{"role":"user","content":"hi"}],"attachments":[{"kind":"image","data_uri":"data:image/png;base64,AAAA"},{"kind":"image","data_uri":"data:image/png;base64,BBBB"}]}`)
	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", body)
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422, got %d", response.StatusCode)
	}
}

func TestHandleAIChatUsageLimitRejects(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionAIInstallation(t, now)
	openrouter := stubOpenRouterServer(t, "smart")
	defer openrouter.Close()
	server := newAITestServer(t, store, openrouter.URL)
	server.RateLimiter = ratelimit.NewMemoryLimiter(func() time.Time { return now })
	server.AILimit5H = ratelimit.Policy{Limit: 1, Window: time.Hour}

	send := func() int {
		body := strings.NewReader(`{"messages":[{"role":"user","content":"hi"}]}`)
		req := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", body)
		req.Header.Set(AccessTokenHeader, provisioned.AccessToken)
		rec := httptest.NewRecorder()
		server.ServeHTTP(rec, req)
		return rec.Result().StatusCode
	}

	if code := send(); code != http.StatusOK {
		t.Fatalf("first request expected 200, got %d", code)
	}
	if code := send(); code != http.StatusTooManyRequests {
		t.Fatalf("second request (over limit) expected 429, got %d", code)
	}
}

func TestHandleAIUsageEndpoint(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionAIInstallation(t, now)
	server := newAITestServer(t, store, "http://openrouter.invalid")
	server.RateLimiter = ratelimit.NewMemoryLimiter(func() time.Time { return now })
	server.AILimit5H = ratelimit.Policy{Limit: 30, Window: 5 * time.Hour}
	server.AILimitWeekly = ratelimit.Policy{Limit: 200, Window: 168 * time.Hour}

	request := httptest.NewRequest(http.MethodGet, "http://relay.test/v1/ai/usage", nil)
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", response.StatusCode)
	}
	var snapshot struct {
		FiveHour struct {
			Used, Limit, Remaining int
		} `json:"five_hour"`
		Weekly struct {
			Limit int
		} `json:"weekly"`
	}
	if err := json.NewDecoder(response.Body).Decode(&snapshot); err != nil {
		t.Fatal(err)
	}
	if snapshot.FiveHour.Limit != 30 || snapshot.FiveHour.Used != 0 || snapshot.FiveHour.Remaining != 30 {
		t.Fatalf("unexpected five_hour snapshot %#v", snapshot.FiveHour)
	}
	if snapshot.Weekly.Limit != 200 {
		t.Fatalf("unexpected weekly snapshot %#v", snapshot.Weekly)
	}
}

func stubToolCallOpenRouterServer(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Stream bool `json:"stream"`
		}
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		if !body.Stream {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{
				"choices": []map[string]any{
					{"message": map[string]any{"role": "assistant", "content": "smart"}},
				},
			})
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		flusher, _ := w.(http.Flusher)
		for _, chunk := range []string{
			`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"query_resource","arguments":"{\"resource\":\"orders\"}"}}]}}]}`,
			`data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
			`data: [DONE]`,
		} {
			_, _ = io.WriteString(w, chunk+"\n\n")
			if flusher != nil {
				flusher.Flush()
			}
		}
	}))
}

func TestHandleAIChatEmitsToolCallsEvent(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionAIInstallation(t, now)
	openrouter := stubToolCallOpenRouterServer(t)
	defer openrouter.Close()
	server := newAITestServer(t, store, openrouter.URL)

	body := strings.NewReader(`{"messages":[{"role":"user","content":"sales today"}],"tools":[{"type":"function","function":{"name":"query_resource"}}]}`)
	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", body)
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", response.StatusCode)
	}
	payload := recorder.Body.String()
	if !strings.Contains(payload, "event: tool_calls") || !strings.Contains(payload, `"name":"query_resource"`) {
		t.Fatalf("expected tool_calls SSE frame, got %q", payload)
	}
}

func TestHandleAIChatCountUsageFalseSkipsCharge(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionAIInstallation(t, now)
	openrouter := stubOpenRouterServer(t, "smart")
	defer openrouter.Close()
	server := newAITestServer(t, store, openrouter.URL)
	server.RateLimiter = ratelimit.NewMemoryLimiter(func() time.Time { return now })
	server.AILimit5H = ratelimit.Policy{Limit: 1, Window: time.Hour}

	send := func(countUsage string) int {
		body := strings.NewReader(`{"messages":[{"role":"user","content":"hi"}],"count_usage":` + countUsage + `}`)
		req := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", body)
		req.Header.Set(AccessTokenHeader, provisioned.AccessToken)
		rec := httptest.NewRecorder()
		server.ServeHTTP(rec, req)
		return rec.Result().StatusCode
	}

	// Tool-continuation turns (count_usage=false) never charge, so they always pass.
	for i := 0; i < 3; i++ {
		if code := send("false"); code != http.StatusOK {
			t.Fatalf("count_usage=false request %d expected 200, got %d", i, code)
		}
	}
	// The user-initiated turn charges; with limit 1 the first passes, the next 429s.
	if code := send("true"); code != http.StatusOK {
		t.Fatalf("first count_usage=true expected 200, got %d", code)
	}
	if code := send("true"); code != http.StatusTooManyRequests {
		t.Fatalf("second count_usage=true (over limit) expected 429, got %d", code)
	}
}

func TestHandleAIChatContinuationSkipsAntiBurstLimit(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionAIInstallation(t, now)
	openrouter := stubOpenRouterServer(t, "smart")
	defer openrouter.Close()
	server := newAITestServer(t, store, openrouter.URL)
	server.RateLimiter = ratelimit.NewMemoryLimiter(func() time.Time { return now })
	server.AIChatRateLimit = ratelimit.Policy{Limit: 1, Window: time.Minute}

	send := func(countUsage string) int {
		body := strings.NewReader(`{"messages":[{"role":"user","content":"hi"}],"count_usage":` + countUsage + `}`)
		req := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", body)
		req.Header.Set(AccessTokenHeader, provisioned.AccessToken)
		rec := httptest.NewRecorder()
		server.ServeHTTP(rec, req)
		return rec.Result().StatusCode
	}

	// Tool-continuation turns never consume the per-shop anti-burst budget, so the
	// agentic loop can fire many of them without 429-ing itself.
	for i := 0; i < 5; i++ {
		if code := send("false"); code != http.StatusOK {
			t.Fatalf("continuation %d expected 200, got %d", i, code)
		}
	}
	// User-initiated turns do consume it: limit 1 → first passes, next 429s.
	if code := send("true"); code != http.StatusOK {
		t.Fatalf("first user turn expected 200, got %d", code)
	}
	if code := send("true"); code != http.StatusTooManyRequests {
		t.Fatalf("second user turn (over anti-burst) expected 429, got %d", code)
	}
}

func TestHandleAIChatContinuationSkipsRouterCall(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionAIInstallation(t, now)
	var routerCalls, streamCalls int32
	openrouter := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Stream bool `json:"stream"`
		}
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		if !body.Stream {
			atomic.AddInt32(&routerCalls, 1)
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{
				"choices": []map[string]any{{"message": map[string]any{"content": "smart"}}},
			})
			return
		}
		atomic.AddInt32(&streamCalls, 1)
		w.Header().Set("Content-Type", "text/event-stream")
		flusher, _ := w.(http.Flusher)
		_, _ = io.WriteString(w, `data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}`+"\n\n")
		_, _ = io.WriteString(w, "data: [DONE]\n\n")
		if flusher != nil {
			flusher.Flush()
		}
	}))
	defer openrouter.Close()
	server := newAITestServer(t, store, openrouter.URL)

	send := func(countUsage string) {
		body := strings.NewReader(`{"messages":[{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"f"}}],"count_usage":` + countUsage + `}`)
		req := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/ai/chat", body)
		req.Header.Set(AccessTokenHeader, provisioned.AccessToken)
		rec := httptest.NewRecorder()
		server.ServeHTTP(rec, req)
		_ = rec.Result()
	}

	// A user turn routes (one router call); a continuation reuses smart and makes
	// none — halving the OpenRouter calls in the tool loop.
	send("true")
	send("false")
	if got := atomic.LoadInt32(&routerCalls); got != 1 {
		t.Fatalf("expected exactly 1 router call (user turn only), got %d", got)
	}
	if got := atomic.LoadInt32(&streamCalls); got != 2 {
		t.Fatalf("expected 2 stream calls, got %d", got)
	}
}
