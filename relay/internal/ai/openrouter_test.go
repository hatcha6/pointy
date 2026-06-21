package ai

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func collectEvents(t *testing.T, sse string) []Event {
	t.Helper()
	var events []Event
	if err := consumeSSE(strings.NewReader(sse), func(e Event) error {
		events = append(events, e)
		return nil
	}); err != nil {
		t.Fatalf("consumeSSE returned error: %v", err)
	}
	return events
}

func TestConsumeSSEDeltasThenDoneWithUsage(t *testing.T) {
	sse := `data: {"model":"m","choices":[{"delta":{"content":"Hel"}}]}` + "\n\n" +
		`data: {"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}` + "\n\n" +
		`data: {"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}` + "\n\n" +
		"data: [DONE]\n\n"

	events := collectEvents(t, sse)
	if len(events) != 3 {
		t.Fatalf("expected 3 events, got %d: %#v", len(events), events)
	}
	if events[0].Type != EventDelta || events[0].Text != "Hel" {
		t.Fatalf("unexpected first delta: %#v", events[0])
	}
	if events[1].Type != EventDelta || events[1].Text != "lo" {
		t.Fatalf("unexpected second delta: %#v", events[1])
	}
	done := events[2]
	if done.Type != EventDone || done.Model != "m" || done.FinishReason != "stop" {
		t.Fatalf("unexpected done event: %#v", done)
	}
	if done.Usage == nil || done.Usage.TotalTokens != 3 {
		t.Fatalf("expected usage in done event, got %#v", done.Usage)
	}
}

func TestConsumeSSEEndsOnEOFWithoutDoneMarker(t *testing.T) {
	sse := `data: {"choices":[{"delta":{"content":"hi"}}]}` + "\n\n"
	events := collectEvents(t, sse)
	if len(events) != 2 || events[1].Type != EventDone {
		t.Fatalf("expected delta + synthesized done on EOF, got %#v", events)
	}
}

func TestConsumeSSEIgnoresKeepAliveComments(t *testing.T) {
	sse := ": OPENROUTER PROCESSING\n\n" +
		`data: {"choices":[{"delta":{"content":"x"}}]}` + "\n\n" +
		"data: [DONE]\n\n"
	events := collectEvents(t, sse)
	if len(events) != 2 || events[0].Text != "x" || events[1].Type != EventDone {
		t.Fatalf("expected keep-alive comment ignored, got %#v", events)
	}
}

func TestConsumeSSEAssemblesFragmentedToolCalls(t *testing.T) {
	sse := `data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"query_resource","arguments":"{\"reso"}}]}}]}` + "\n\n" +
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"urce\":\"orders\"}"}}]}}]}` + "\n\n" +
		`data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}` + "\n\n" +
		"data: [DONE]\n\n"

	events := collectEvents(t, sse)
	if len(events) != 2 {
		t.Fatalf("expected tool_calls + done, got %d: %#v", len(events), events)
	}
	tc := events[0]
	if tc.Type != EventToolCalls || len(tc.ToolCalls) != 1 {
		t.Fatalf("unexpected tool_calls event: %#v", tc)
	}
	call := tc.ToolCalls[0]
	if call.ID != "call_1" || call.Function.Name != "query_resource" {
		t.Fatalf("unexpected assembled call: %#v", call)
	}
	if call.Function.Arguments != `{"resource":"orders"}` {
		t.Fatalf("expected reassembled arguments, got %q", call.Function.Arguments)
	}
	if events[1].Type != EventDone || events[1].FinishReason != "tool_calls" {
		t.Fatalf("unexpected done: %#v", events[1])
	}
}

func TestConsumeSSEEmitsTextThenToolCallsInOrder(t *testing.T) {
	sse := `data: {"choices":[{"delta":{"content":"let me check "}}]}` + "\n\n" +
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"f0","arguments":"{}"}}]}}]}` + "\n\n" +
		`data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"f1","arguments":"{}"}}]}}]}` + "\n\n" +
		"data: [DONE]\n\n"

	events := collectEvents(t, sse)
	if len(events) != 3 {
		t.Fatalf("expected delta+tool_calls+done, got %d: %#v", len(events), events)
	}
	if events[0].Type != EventDelta || events[0].Text != "let me check " {
		t.Fatalf("unexpected delta: %#v", events[0])
	}
	if events[1].Type != EventToolCalls || len(events[1].ToolCalls) != 2 {
		t.Fatalf("expected 2 assembled calls, got %#v", events[1])
	}
	if events[1].ToolCalls[0].Function.Name != "f0" || events[1].ToolCalls[1].Function.Name != "f1" {
		t.Fatalf("calls out of order: %#v", events[1].ToolCalls)
	}
}

func TestConsumeSSECollectsWebSearchSources(t *testing.T) {
	sse := `data: {"choices":[{"delta":{"content":"The price rose.","annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com/a","title":"Site A"}}]}}]}` + "\n\n" +
		`data: {"choices":[{"delta":{"annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com/a","title":"Site A"}},{"type":"url_citation","url_citation":{"url":"https://news.test/b","title":"Site B"}}]}}]}` + "\n\n" +
		`data: {"choices":[{"delta":{},"finish_reason":"stop"}]}` + "\n\n" +
		"data: [DONE]\n\n"

	events := collectEvents(t, sse)
	done := events[len(events)-1]
	if done.Type != EventDone {
		t.Fatalf("expected a done event last, got %#v", done)
	}
	// Two distinct sources; the repeated URL is de-duplicated.
	if len(done.Sources) != 2 {
		t.Fatalf("expected 2 deduped sources, got %#v", done.Sources)
	}
	if done.Sources[0].URL != "https://example.com/a" || done.Sources[0].Title != "Site A" {
		t.Fatalf("unexpected first source: %#v", done.Sources[0])
	}
	if done.Sources[1].URL != "https://news.test/b" {
		t.Fatalf("unexpected second source: %#v", done.Sources[1])
	}
}

func TestToWireMessagesCarriesToolFields(t *testing.T) {
	msgs := []Message{
		{
			Role: "assistant",
			ToolCalls: []ToolCall{{
				ID:       "c1",
				Type:     "function",
				Function: ToolCallFunction{Name: "query_resource", Arguments: `{"resource":"orders"}`},
			}},
		},
		{Role: "tool", ToolCallID: "c1", Name: "query_resource", Content: `{"ok":true}`},
	}

	raw, err := json.Marshal(toWireMessages(msgs))
	if err != nil {
		t.Fatal(err)
	}
	got := string(raw)
	for _, want := range []string{
		`"role":"assistant"`,
		`"tool_calls":[{"id":"c1","type":"function","function":{"name":"query_resource","arguments":"{\"resource\":\"orders\"}"}}]`,
		`"role":"tool"`,
		`"tool_call_id":"c1"`,
		`"name":"query_resource"`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("wire JSON missing %s:\n%s", want, got)
		}
	}
}

func TestConsumeSSESurfacesStreamError(t *testing.T) {
	sse := `data: {"error":{"message":"boom"}}` + "\n\n"
	var events []Event
	err := consumeSSE(strings.NewReader(sse), func(e Event) error {
		events = append(events, e)
		return nil
	})
	if err == nil {
		t.Fatal("expected an error from a stream error chunk")
	}
	if len(events) != 1 || events[0].Type != EventError || events[0].Err != "boom" {
		t.Fatalf("expected a single error event, got %#v", events)
	}
}

func TestStreamChatRetriesTransient429(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if atomic.AddInt32(&calls, 1) < 2 {
			// First attempt: a transient provider rate limit.
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = io.WriteString(w, `{"error":{"message":"Provider returned error"}}`)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, `data: {"choices":[{"delta":{"content":"hi"},"finish_reason":"stop"}]}`+"\n\n")
		_, _ = io.WriteString(w, "data: [DONE]\n\n")
	}))
	defer srv.Close()

	client := Client{APIKey: "k", BaseURL: srv.URL}
	var events []Event
	err := client.StreamChat(
		context.Background(),
		ChatRequest{Model: "m", Messages: []Message{{Role: "user", Content: "hi"}}},
		func(e Event) error { events = append(events, e); return nil },
	)
	if err != nil {
		t.Fatalf("expected success after one retry, got %v", err)
	}
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Fatalf("expected 2 attempts (1 retry), got %d", got)
	}
	if len(events) != 2 || events[0].Type != EventDelta || events[1].Type != EventDone {
		t.Fatalf("expected delta+done, got %#v", events)
	}
}

func TestStreamChatSurfacesErrorAfterExhaustingRetries(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = io.WriteString(w, `{"error":{"message":"Provider returned error"}}`)
	}))
	defer srv.Close()

	client := Client{APIKey: "k", BaseURL: srv.URL}
	errEvents := 0
	err := client.StreamChat(
		context.Background(),
		ChatRequest{Model: "m", Messages: []Message{{Role: "user", Content: "hi"}}},
		func(e Event) error {
			if e.Type == EventError {
				errEvents++
			}
			return nil
		},
	)
	if err == nil {
		t.Fatal("expected an error after exhausting retries")
	}
	if got := atomic.LoadInt32(&calls); got != maxStreamAttempts {
		t.Fatalf("expected %d attempts, got %d", maxStreamAttempts, got)
	}
	if errEvents != 1 {
		t.Fatalf("expected exactly one error event, got %d", errEvents)
	}
}
