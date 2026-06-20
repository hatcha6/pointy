// Package ai contains the relay-hosted AI client. The relay is the only place
// that holds the OpenRouter API key and the tier->model catalog, so AI billing
// and model routing stay company-controlled and never reach customer devices or
// the on-prem backend.
package ai

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// maxStreamAttempts is the total number of times StreamChat will try a request
// (1 initial + retries) when the provider returns a transient error.
const maxStreamAttempts = 3

const defaultBaseURL = "https://openrouter.ai/api/v1"

// Message is one chat turn sent to the model. When Parts is non-empty the
// message is multimodal (text + images/files) and Content is ignored. Tool
// round-trips reuse this type: an assistant turn may carry ToolCalls, and a
// tool-result turn sets Role=="tool" with ToolCallID + Content (the result).
type Message struct {
	Role       string
	Content    string
	Parts      []ContentPart
	ToolCalls  []ToolCall // assistant turn requesting tool calls
	ToolCallID string     // tool-result turn: which call it answers
	Name       string     // tool-result turn: the tool's name (optional)
}

// ContentPart is one piece of a multimodal message (OpenAI content-array form).
type ContentPart struct {
	Type     string // "text" | "image_url" | "file"
	Text     string // Type == "text"
	ImageURL string // Type == "image_url" (a data: URI)
	FileName string // Type == "file"
	FileData string // Type == "file" (a data: URI)
}

// ToolCall is one function call the model wants executed (OpenAI shape).
// Arguments is a JSON string the caller parses.
type ToolCall struct {
	ID       string           `json:"id"`
	Type     string           `json:"type"`
	Function ToolCallFunction `json:"function"`
}

// ToolCallFunction is the function name + JSON-string arguments of a ToolCall.
type ToolCallFunction struct {
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}

// ChatRequest is a normalized, vendor-agnostic chat completion request.
type ChatRequest struct {
	Model       string
	Messages    []Message
	MaxTokens   int
	Temperature *float64
	// Plugins is an optional OpenRouter plugins array (e.g. the file-parser for
	// PDFs), passed through verbatim.
	Plugins []map[string]any
	// Tools is an optional OpenAI tool/function-calling array, passed through
	// verbatim. When set the model may answer with tool calls.
	Tools []map[string]any
}

// Usage reports token accounting for a completion when the provider returns it.
type Usage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

// EventType discriminates the normalized streaming events.
type EventType string

const (
	EventDelta     EventType = "delta"
	EventReasoning EventType = "reasoning"
	EventToolCalls EventType = "tool_calls"
	EventDone      EventType = "done"
	EventError     EventType = "error"
)

// Event is a single normalized streaming event. Callers translate these into
// whatever wire format they expose downstream (the relay emits SSE).
type Event struct {
	Type         EventType
	Text         string     // EventDelta / EventReasoning
	Model        string     // EventDone
	FinishReason string     // EventDone
	Usage        *Usage     // EventDone (nil when the provider omits usage)
	ToolCalls    []ToolCall // EventToolCalls (assembled from streamed fragments)
	Err          string     // EventError
}

// Client talks to an OpenRouter-compatible (OpenAI-style) chat completions API.
type Client struct {
	APIKey     string
	BaseURL    string
	HTTPClient *http.Client
	// Referer and Title are sent as OpenRouter ranking headers; both optional.
	Referer string
	Title   string
}

type wireMessage struct {
	Role       string     `json:"role"`
	Content    any        `json:"content"`
	ToolCalls  []ToolCall `json:"tool_calls,omitempty"`
	ToolCallID string     `json:"tool_call_id,omitempty"`
	Name       string     `json:"name,omitempty"`
}

// toWireMessages maps normalized messages to the wire shape, carrying tool-call
// and tool-result fields through untouched.
func toWireMessages(msgs []Message) []wireMessage {
	out := make([]wireMessage, 0, len(msgs))
	for _, m := range msgs {
		wm := wireMessage{Role: m.Role, Content: wireContent(m)}
		if len(m.ToolCalls) > 0 {
			wm.ToolCalls = m.ToolCalls
		}
		if strings.TrimSpace(m.ToolCallID) != "" {
			wm.ToolCallID = m.ToolCallID
		}
		if strings.TrimSpace(m.Name) != "" {
			wm.Name = m.Name
		}
		out = append(out, wm)
	}
	return out
}

type streamOptions struct {
	IncludeUsage bool `json:"include_usage"`
}

type wireRequest struct {
	Model         string           `json:"model"`
	Messages      []wireMessage    `json:"messages"`
	MaxTokens     int              `json:"max_tokens,omitempty"`
	Temperature   *float64         `json:"temperature,omitempty"`
	Stream        bool             `json:"stream"`
	StreamOptions *streamOptions   `json:"stream_options,omitempty"`
	Plugins       []map[string]any `json:"plugins,omitempty"`
	Tools         []map[string]any `json:"tools,omitempty"`
}

// wireContent renders a message as either a plain string (text-only) or an
// OpenAI content-array (multimodal).
func wireContent(msg Message) any {
	if len(msg.Parts) == 0 {
		return msg.Content
	}
	parts := make([]map[string]any, 0, len(msg.Parts))
	for _, p := range msg.Parts {
		switch p.Type {
		case "text":
			parts = append(parts, map[string]any{"type": "text", "text": p.Text})
		case "image_url":
			parts = append(parts, map[string]any{
				"type":      "image_url",
				"image_url": map[string]any{"url": p.ImageURL},
			})
		case "file":
			parts = append(parts, map[string]any{
				"type": "file",
				"file": map[string]any{"filename": p.FileName, "file_data": p.FileData},
			})
		}
	}
	return parts
}

type streamChunk struct {
	Model   string `json:"model"`
	Choices []struct {
		Delta struct {
			Content string `json:"content"`
			// Reasoning models stream their thinking separately from content.
			Reasoning        string `json:"reasoning"`
			ReasoningContent string `json:"reasoning_content"`
			// Tool calls stream fragmented across chunks, keyed by index.
			ToolCalls []struct {
				Index    int    `json:"index"`
				ID       string `json:"id"`
				Type     string `json:"type"`
				Function struct {
					Name      string `json:"name"`
					Arguments string `json:"arguments"`
				} `json:"function"`
			} `json:"tool_calls"`
		} `json:"delta"`
		FinishReason *string `json:"finish_reason"`
	} `json:"choices"`
	Usage *Usage `json:"usage"`
	Error *struct {
		Message string `json:"message"`
	} `json:"error"`
}

func (c Client) baseURL() string {
	base := strings.TrimRight(strings.TrimSpace(c.BaseURL), "/")
	if base == "" {
		return defaultBaseURL
	}
	return base
}

func (c Client) httpClient() *http.Client {
	if c.HTTPClient != nil {
		return c.HTTPClient
	}
	return &http.Client{Timeout: 120 * time.Second}
}

// StreamChat issues a streaming chat completion and invokes emit for each
// normalized event (delta, then exactly one done — or error). emit may return
// an error to abort early (e.g. the downstream client disconnected), which is
// returned to the caller. A done event is always emitted on a clean finish.
func (c Client) StreamChat(ctx context.Context, req ChatRequest, emit func(Event) error) error {
	if strings.TrimSpace(c.APIKey) == "" {
		return errors.New("openrouter api key is required")
	}
	if strings.TrimSpace(req.Model) == "" {
		return errors.New("model is required")
	}

	body, err := json.Marshal(wireRequest{
		Model:         req.Model,
		Messages:      toWireMessages(req.Messages),
		MaxTokens:     req.MaxTokens,
		Temperature:   req.Temperature,
		Stream:        true,
		StreamOptions: &streamOptions{IncludeUsage: true},
		Plugins:       req.Plugins,
		Tools:         req.Tools,
	})
	if err != nil {
		return err
	}

	// Free-tier / provider rate limits (429) and transient gateway errors
	// (502/503) are frequently momentary — back off and retry a couple of times
	// before surfacing the failure. The retry happens before any bytes stream, so
	// re-issuing the request is safe.
	backoff := 700 * time.Millisecond
	for attempt := 1; ; attempt++ {
		httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL()+"/chat/completions", bytes.NewReader(body))
		if err != nil {
			return err
		}
		httpReq.Header.Set("Content-Type", "application/json")
		httpReq.Header.Set("Accept", "text/event-stream")
		httpReq.Header.Set("Authorization", "Bearer "+strings.TrimSpace(c.APIKey))
		if strings.TrimSpace(c.Referer) != "" {
			httpReq.Header.Set("HTTP-Referer", strings.TrimSpace(c.Referer))
		}
		if strings.TrimSpace(c.Title) != "" {
			httpReq.Header.Set("X-Title", strings.TrimSpace(c.Title))
		}

		resp, err := c.httpClient().Do(httpReq)
		if err != nil {
			return err
		}

		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			streamErr := consumeSSE(resp.Body, emit)
			resp.Body.Close()
			return streamErr
		}

		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
		wait := retryAfterDelay(resp.Header, backoff)
		resp.Body.Close()
		message := parseErrorBody(raw)

		if isRetryableStatus(resp.StatusCode) && attempt < maxStreamAttempts {
			select {
			case <-time.After(wait):
			case <-ctx.Done():
				_ = emit(Event{Type: EventError, Err: message})
				return ctx.Err()
			}
			backoff *= 2
			continue
		}

		_ = emit(Event{Type: EventError, Err: message})
		return fmt.Errorf("openrouter returned status %d: %s", resp.StatusCode, message)
	}
}

// isRetryableStatus reports whether an OpenRouter HTTP status is worth retrying
// after a backoff (rate limits + transient gateway errors).
func isRetryableStatus(code int) bool {
	return code == http.StatusTooManyRequests ||
		code == http.StatusBadGateway ||
		code == http.StatusServiceUnavailable
}

// retryAfterDelay honours a Retry-After header (seconds) when present, capped so
// a turn never hangs; otherwise it uses the caller's backoff.
func retryAfterDelay(header http.Header, fallback time.Duration) time.Duration {
	if v := strings.TrimSpace(header.Get("Retry-After")); v != "" {
		if secs, err := strconv.Atoi(v); err == nil && secs > 0 {
			delay := time.Duration(secs) * time.Second
			if delay > 10*time.Second {
				delay = 10 * time.Second
			}
			return delay
		}
	}
	return fallback
}

type completionResponse struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
	Error *struct {
		Message string `json:"message"`
	} `json:"error"`
}

// Complete issues a non-streaming chat completion and returns the assistant's
// text. Used by the relay's tier router for a quick one-word classification.
func (c Client) Complete(ctx context.Context, req ChatRequest) (string, error) {
	if strings.TrimSpace(c.APIKey) == "" {
		return "", errors.New("openrouter api key is required")
	}
	if strings.TrimSpace(req.Model) == "" {
		return "", errors.New("model is required")
	}

	body, err := json.Marshal(wireRequest{
		Model:       req.Model,
		Messages:    toWireMessages(req.Messages),
		MaxTokens:   req.MaxTokens,
		Temperature: req.Temperature,
		Stream:      false,
		Plugins:     req.Plugins,
		Tools:       req.Tools,
	})
	if err != nil {
		return "", err
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL()+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json")
	httpReq.Header.Set("Authorization", "Bearer "+strings.TrimSpace(c.APIKey))
	if strings.TrimSpace(c.Referer) != "" {
		httpReq.Header.Set("HTTP-Referer", strings.TrimSpace(c.Referer))
	}
	if strings.TrimSpace(c.Title) != "" {
		httpReq.Header.Set("X-Title", strings.TrimSpace(c.Title))
	}

	resp, err := c.httpClient().Do(httpReq)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("openrouter returned status %d: %s", resp.StatusCode, parseErrorBody(raw))
	}

	var parsed completionResponse
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return "", err
	}
	if parsed.Error != nil && strings.TrimSpace(parsed.Error.Message) != "" {
		return "", fmt.Errorf("openrouter completion error: %s", parsed.Error.Message)
	}
	if len(parsed.Choices) == 0 {
		return "", errors.New("openrouter returned no choices")
	}
	return strings.TrimSpace(parsed.Choices[0].Message.Content), nil
}

func consumeSSE(body io.Reader, emit func(Event) error) error {
	reader := bufio.NewReader(body)
	var (
		model  string
		finish string
		usage  *Usage
	)
	// Tool calls stream as fragments keyed by index (id/name in the first chunk,
	// arguments string fragments after); assemble them and emit once at the end.
	toolCalls := map[int]*ToolCall{}
	toolOrder := []int{}

	finishTurn := func() error {
		if len(toolOrder) > 0 {
			assembled := make([]ToolCall, 0, len(toolOrder))
			for _, idx := range toolOrder {
				assembled = append(assembled, *toolCalls[idx])
			}
			if emitErr := emit(Event{Type: EventToolCalls, ToolCalls: assembled}); emitErr != nil {
				return emitErr
			}
		}
		return emit(Event{Type: EventDone, Model: model, FinishReason: finish, Usage: usage})
	}

	for {
		line, readErr := reader.ReadString('\n')
		if trimmed := strings.TrimRight(line, "\r\n"); trimmed != "" && !strings.HasPrefix(trimmed, ":") {
			if data, ok := strings.CutPrefix(trimmed, "data:"); ok {
				data = strings.TrimSpace(data)
				if data == "[DONE]" {
					return finishTurn()
				}
				var chunk streamChunk
				if json.Unmarshal([]byte(data), &chunk) == nil {
					if chunk.Error != nil {
						_ = emit(Event{Type: EventError, Err: chunk.Error.Message})
						return fmt.Errorf("openrouter stream error: %s", chunk.Error.Message)
					}
					if chunk.Model != "" {
						model = chunk.Model
					}
					for _, choice := range chunk.Choices {
						reasoning := choice.Delta.Reasoning
						if reasoning == "" {
							reasoning = choice.Delta.ReasoningContent
						}
						if reasoning != "" {
							if emitErr := emit(Event{Type: EventReasoning, Text: reasoning}); emitErr != nil {
								return emitErr
							}
						}
						if choice.Delta.Content != "" {
							if emitErr := emit(Event{Type: EventDelta, Text: choice.Delta.Content}); emitErr != nil {
								return emitErr
							}
						}
						for _, tc := range choice.Delta.ToolCalls {
							call, exists := toolCalls[tc.Index]
							if !exists {
								call = &ToolCall{Type: "function"}
								toolCalls[tc.Index] = call
								toolOrder = append(toolOrder, tc.Index)
							}
							if tc.ID != "" {
								call.ID = tc.ID
							}
							if tc.Type != "" {
								call.Type = tc.Type
							}
							if tc.Function.Name != "" {
								call.Function.Name = tc.Function.Name
							}
							call.Function.Arguments += tc.Function.Arguments
						}
						if choice.FinishReason != nil && *choice.FinishReason != "" {
							finish = *choice.FinishReason
						}
					}
					if chunk.Usage != nil {
						usage = chunk.Usage
					}
				}
			}
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				// Some providers end the stream without an explicit [DONE].
				return finishTurn()
			}
			return readErr
		}
	}
}

func parseErrorBody(body []byte) string {
	var payload struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &payload) == nil && strings.TrimSpace(payload.Error.Message) != "" {
		return strings.TrimSpace(payload.Error.Message)
	}
	message := strings.TrimSpace(string(body))
	if message == "" {
		return "openrouter request failed"
	}
	return message
}
