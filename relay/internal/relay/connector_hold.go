package relay

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"pointy/relay/internal/protocol"
)

// connectorHoldPoll is how often a held request looks for the shop's tunnel.
const connectorHoldPoll = 250 * time.Millisecond

// maxReplayedBodyBytes is the largest request body held in memory so the
// request can be sent again when the node it was forwarded to turns out to
// hold no tunnel. Phone requests are well under it; a larger upload is
// forwarded once, as before.
const maxReplayedBodyBytes = 64 << 10

// shopRoute is how a request reached the shop: a stream on one of its tunnels
// here, or an answer that a node holding one already wrote.
type shopRoute struct {
	stream  *protocol.Stream
	proxied bool
	status  int
	outcome string
}

// forwardFunc sends r to a node holding the shop's tunnel. proxied is false
// when nothing reached the shop and nothing was written, so r can go again.
type forwardFunc func(r *http.Request) (proxied bool, status int, outcome string)

// reachShop opens a stream on the shop's tunnel here, or forwards r to a node
// that holds one (forward, nil when r may not be forwarded).
//
// When neither works, the shop is most likely between tunnels: one closed and
// its replacement is on the way (a node went down, a tunnel is moving). The
// request then waits for one, looking every 250 ms for up to ConnectorHold,
// before it is answered as offline. A try is only ever repeated when the one
// before reached no tunnel: the stream couldn't open, or no node took the
// request. A request forwarded here from another node never waits: that node
// is the one that knows every node, and it waits instead.
func (s HTTPServer) reachShop(r *http.Request, installationID string, forward forwardFunc) (shopRoute, error) {
	hold := s.ConnectorHold
	if strings.TrimSpace(r.Header.Get(NodeProxyMarkerHeader)) != "" {
		hold = 0
	}
	if forward != nil {
		replayableBody(r)
	}
	startedAt := time.Now()
	waited := false
	finish := func(outcome string) {
		if waited {
			s.metrics().RecordHeldRequest(outcome, time.Since(startedAt))
		}
	}
	for {
		openCtx, cancel := context.WithTimeout(r.Context(), s.streamOpenTimeout())
		stream, err := s.Hub.OpenStream(openCtx, installationID)
		cancel()
		if err == nil {
			finish("served")
			return shopRoute{stream: stream}, nil
		}
		if !errors.Is(err, ErrConnectorOffline) {
			return shopRoute{}, err
		}
		if forward != nil {
			if proxied, status, outcome := forward(r); proxied {
				finish("served")
				return shopRoute{proxied: true, status: status, outcome: outcome}, nil
			}
		}
		if time.Since(startedAt)+connectorHoldPoll > hold || r.Context().Err() != nil {
			finish("offline")
			return shopRoute{}, ErrConnectorOffline
		}
		waited = true
		select {
		case <-r.Context().Done():
		case <-time.After(connectorHoldPoll):
		}
	}
}

// replayableBody holds a small request body in memory, so that it can be sent
// to a second node (GetBody) and still be read in full here.
func replayableBody(r *http.Request) {
	if r.Body == nil || r.Body == http.NoBody || r.GetBody != nil ||
		r.ContentLength <= 0 || r.ContentLength > maxReplayedBodyBytes {
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, r.ContentLength))
	if err != nil {
		// What was read is still the request's; the rest fails where it
		// would have.
		r.Body = io.NopCloser(io.MultiReader(bytes.NewReader(body), failedReader{err}))
		return
	}
	r.Body = io.NopCloser(bytes.NewReader(body))
	r.GetBody = func() (io.ReadCloser, error) {
		return io.NopCloser(bytes.NewReader(body)), nil
	}
}

type failedReader struct{ err error }

func (f failedReader) Read([]byte) (int, error) { return 0, f.err }
