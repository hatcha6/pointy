package connector

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"pointy/relay/internal/limit"
	"pointy/relay/internal/protocol"
)

// A tunnel that shares a node with another of the shop's tunnels looks for a
// node of its own after spreadCheckFirst, then less and less often, up to 15
// times that, while the relay keeps placing it there (most likely the only
// live node).
const (
	spreadCheckFirst  = 2 * time.Minute
	spreadCheckGrowth = 15
)

// A tunnel that was replaced is closed once its last stream ends. retireGrace
// bounds the wait on a relay that keeps opening streams on it (one that
// predates Retire); once the relay has answered Retire nothing new arrives,
// and retiredGrace only stops a stream that never ends (a camera feed) from
// holding the old tunnel open for good.
const (
	retireGrace  = 30 * time.Second
	retiredGrace = 10 * time.Minute
	// retireAnswerWait bounds the wait for the relay's answer to Retire.
	retireAnswerWait = 5 * time.Second
)

// A tunnel asked to move whose replacement can't be opened yet keeps serving
// and tries again, after moveRetryFirst, doubling up to moveRetryMax.
const (
	moveRetryFirst = time.Second
	moveRetryMax   = 30 * time.Second
)

// tunnelSet is a connector's tunnels: one to begin with, then as many as the
// relay's HelloAck asks for. Each runs its own reconnect loop, so losing one
// node leaves the shop served by its tunnel on another.
type tunnelSet struct {
	client  Client
	book    *endpointBook
	limiter *limit.Limiter

	mu sync.Mutex
	// want is how many tunnels the relay last asked for.
	want int
	// changed is closed, and replaced, whenever want changes.
	changed chan struct{}
	// nodes is the relay node each open tunnel is on, by slot.
	nodes map[int]string
	// attempts counts each slot's tries since its tunnel last opened.
	attempts map[int]int
	// spreadDelay is each slot's current wait before looking for a node of
	// its own.
	spreadDelay map[int]time.Duration
	// leaving is the node a slot is moving off, which its replacement avoids.
	leaving map[int]string
	// moving lets one slot move at a time, so each move sees where the
	// others landed (a lock that a stopped watcher gives up on).
	moving chan struct{}

	connectedMu sync.Mutex
}

func newTunnelSet(client Client, book *endpointBook) *tunnelSet {
	return &tunnelSet{
		client:      client,
		book:        book,
		limiter:     limit.New(client.MaxConcurrentRequests),
		want:        1,
		changed:     make(chan struct{}),
		nodes:       map[int]string{},
		attempts:    map[int]int{},
		spreadDelay: map[int]time.Duration{},
		leaving:     map[int]string{},
		moving:      make(chan struct{}, 1),
	}
}

// run starts slot 0, and each further slot as the relay asks for it, until
// ctx ends.
func (t *tunnelSet) run(ctx context.Context) error {
	var wg sync.WaitGroup
	started := 0
	for {
		t.mu.Lock()
		want, changed := t.want, t.changed
		t.mu.Unlock()
		for ; started < want; started++ {
			slot := started
			wg.Add(1)
			go func() {
				defer wg.Done()
				_ = t.client.run(ctx, func(ctx context.Context) error {
					return t.runOnce(ctx, slot)
				}, t.waitFor(slot))
			}()
		}
		select {
		case <-ctx.Done():
			wg.Wait()
			return ctx.Err()
		case <-changed:
		}
	}
}

// waitFor is a slot's reconnect wait. A slot beyond what the relay asks for
// (it asked for fewer, or it is an older relay) also waits until it is wanted
// again.
func (t *tunnelSet) waitFor(slot int) reconnectWaitFunc {
	return func(ctx context.Context, wait time.Duration) error {
		if err := sleepContext(ctx, wait); err != nil {
			return err
		}
		for {
			t.mu.Lock()
			wanted, changed := slot < t.want, t.changed
			t.mu.Unlock()
			if wanted {
				return nil
			}
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-changed:
			}
		}
	}
}

func (t *tunnelSet) setWant(want int) {
	if want < 1 {
		want = 1
	}
	limit := protocol.MaxTunnels
	if t.client.MaxTunnels > 0 {
		limit = min(limit, t.client.MaxTunnels)
	}
	want = min(want, limit)
	t.mu.Lock()
	defer t.mu.Unlock()
	if want == t.want {
		return
	}
	t.want = want
	close(t.changed)
	t.changed = make(chan struct{})
}

// openedTunnel is a tunnel the relay accepted, not yet serving.
type openedTunnel struct {
	session  *protocol.Session
	endpoint Endpoint
	ack      protocol.HelloAckInfo
	// moves is a relay that may ask this tunnel to move, and answers Retire.
	moves bool
}

// runOnce opens a slot's tunnel and serves it until it ends.
func (t *tunnelSet) runOnce(ctx context.Context, slot int) error {
	opened, err := t.open(ctx, slot, nil)
	if err != nil {
		return err
	}
	t.mu.Lock()
	wanted := slot < t.want
	t.mu.Unlock()
	if !wanted {
		// The relay that took it keeps one tunnel per shop (or now asks for
		// fewer): a second would close the first. Leave it to the first.
		_ = opened.session.Close()
		return nil
	}
	return t.serve(ctx, slot, opened)
}

// open walks the addresses in order until one carries a tunnel the relay
// accepts. A transport failure moves on to the next address in the same
// attempt (a WebSocket the balancer won't upgrade falls back to TCP); an
// answer from the relay itself ends the attempt, since every address reaches
// the same relay and would hear the same answer. A redirect to another node is
// followed once; if that node can't be reached, the same address is dialled
// again with the attempt count raised, which the relay takes from the third.
//
// via, when set, is a node's own address to try first, as if the first
// address had redirected there (a relay asking the tunnel to move names one).
func (t *tunnelSet) open(ctx context.Context, slot int, via *Endpoint) (openedTunnel, error) {
	c := t.client
	var failures []error
	for i, endpoint := range t.book.order() {
		target, direct := endpoint, false
		if i == 0 && via != nil {
			target, direct = *via, true
		}
		var err error
		for hops := 0; ; hops++ {
			var opened openedTunnel
			opened, err = t.dialTunnel(ctx, slot, endpoint, target, direct)
			if err == nil {
				return opened, nil
			}
			if ctx.Err() != nil {
				return openedTunnel{}, ctx.Err()
			}
			var redirect *RelayRedirectError
			var rejected *RelayRejectedError
			var busy *RelayBusyError
			redirected := errors.As(err, &redirect)
			// A node over its handshake rate (429) takes the tunnel in a
			// moment: wait as told, wherever it was. Placement's 503 is "not
			// here".
			limited := errors.As(err, &busy) && busy.StatusCode == http.StatusTooManyRequests
			// A redirect, or the rate, is an answer, not a failed try;
			// anything else, including the node a redirect named failing,
			// raises the count the relay reads.
			if (!redirected || direct) && !limited {
				t.bumpAttempt(slot)
			}
			switch {
			case redirected && !direct:
				c.logger().Info("relay node sent the tunnel to another node",
					"tunnel", slot, "from", endpoint.String(), "to", redirect.Target.String())
				target, direct = redirect.Target, true
				continue
			case direct && !limited && !errors.As(err, &rejected) && hops < 2*protocol.MaxPlacementAttempts:
				c.logger().Warn("relay node named by a redirect could not be reached; back to the shared address",
					"tunnel", slot, "endpoint", target.String(), "error", err)
				target, direct = endpoint, false
				continue
			}
			break
		}
		var busy *RelayBusyError
		var rejected *RelayRejectedError
		if errors.As(err, &busy) || errors.As(err, &rejected) {
			return openedTunnel{}, err
		}
		c.logger().Warn("relay tunnel address failed", "tunnel", slot, "endpoint", endpoint.String(), "error", err)
		failures = append(failures, fmt.Errorf("%s: %w", endpoint.String(), err))
	}
	return openedTunnel{}, errors.Join(failures...)
}

// dialTunnel dials target (endpoint, or the node it redirected to) and runs
// the Hello exchange.
func (t *tunnelSet) dialTunnel(
	ctx context.Context,
	slot int,
	endpoint, target Endpoint,
	direct bool,
) (openedTunnel, error) {
	c := t.client
	var header http.Header
	if target.WebSocket {
		header = t.placementHeader(slot, direct)
	}
	conn, err := c.dial(ctx, target, header)
	if err != nil {
		return openedTunnel{}, err
	}
	session, ack, fromNewRelay, err := c.hello(conn, uint64(slot)+1)
	if err != nil {
		_ = conn.Close()
		return openedTunnel{}, err
	}
	moves := fromNewRelay && ack.Moves
	if moves {
		// Before the session runs, so it is the first thing the relay reads.
		if err := session.SendCapabilities(protocol.Capabilities{GoAway: true}); err != nil {
			_ = session.Close()
			return openedTunnel{}, err
		}
	}
	// The address worth keeping is the one dialled first: a node's own
	// address is only good while that node lives.
	t.book.connected(endpoint, ack, fromNewRelay)
	want := 1
	if fromNewRelay && ack.Tunnels > 0 {
		want = ack.Tunnels
	}
	t.setWant(want)
	t.mu.Lock()
	t.nodes[slot] = ack.NodeID
	delete(t.attempts, slot)
	t.mu.Unlock()
	c.logger().Info(
		"relay tunnel open",
		"tunnel", slot,
		"endpoint", target.String(),
		"node_id", ack.NodeID,
	)
	if c.OnConnected != nil {
		t.connectedMu.Lock()
		c.OnConnected(Connected{
			Tunnel:          slot,
			Endpoint:        endpoint.String(),
			NodeID:          ack.NodeID,
			RelayAdvertised: fromNewRelay,
			Advertised:      t.book.advertisedStrings(),
		})
		t.connectedMu.Unlock()
	}
	return openedTunnel{session: session, endpoint: endpoint, ack: ack, moves: moves}, nil
}

// placementHeader steers where the relay places this tunnel: away from the
// nodes holding the shop's other tunnels, taken wherever it lands from the
// third try, and without placing it again when it follows a redirect.
func (t *tunnelSet) placementHeader(slot int, direct bool) http.Header {
	t.mu.Lock()
	defer t.mu.Unlock()
	header := http.Header{}
	header.Set(protocol.TunnelAttemptHeader, strconv.Itoa(t.attempts[slot]+1))
	var avoid []string
	for other, node := range t.nodes {
		if other != slot && node != "" && !containsString(avoid, node) {
			avoid = append(avoid, node)
		}
	}
	if node := t.leaving[slot]; node != "" && !containsString(avoid, node) {
		avoid = append(avoid, node)
	}
	if len(avoid) > 0 {
		header.Set(protocol.TunnelAvoidHeader, strings.Join(avoid, ","))
	}
	if direct {
		header.Set(protocol.TunnelDirectHeader, "1")
	}
	return header
}

func containsString(list []string, value string) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}

func (t *tunnelSet) resetAttempts(slot int) {
	t.mu.Lock()
	delete(t.attempts, slot)
	t.mu.Unlock()
}

func (t *tunnelSet) bumpAttempt(slot int) {
	t.mu.Lock()
	t.attempts[slot]++
	t.mu.Unlock()
}

// serve serves a slot's tunnel until it ends. Meanwhile it moves the tunnel
// when the relay asks (GoAway), or when it shares a node with another of the
// shop's tunnels: it opens the replacement first, serves on it, and lets the
// old tunnel finish its streams before closing it.
func (t *tunnelSet) serve(ctx context.Context, slot int, opened openedTunnel) error {
	for {
		session := opened.session
		served := make(chan error, 1)
		go func() { served <- t.client.serveSession(ctx, session, t.limiter) }()
		moved := make(chan openedTunnel, 1)
		stopMoves := t.watchMoves(ctx, slot, opened, moved)
		select {
		case err := <-served:
			stopMoves()
			select {
			case next := <-moved:
				// A replacement opened just as this tunnel ended: serve it.
				opened = next
				continue
			default:
			}
			t.mu.Lock()
			delete(t.nodes, slot)
			t.mu.Unlock()
			return err
		case next := <-moved:
			stopMoves()
			go retire(opened)
			opened = next
		}
	}
}

// watchMoves hands a replacement for the slot's tunnel over on moved when the
// relay asks it to move, or when it shares a node with a lower slot's (only
// the higher slot moves, so two tunnels never swap places).
func (t *tunnelSet) watchMoves(life context.Context, slot int, opened openedTunnel, moved chan<- openedTunnel) (stop func()) {
	ctx, cancel := context.WithCancel(life)
	done := make(chan struct{})
	jitter := t.client.jitter
	if jitter == nil {
		jitter = jitterWait
	}
	go func() {
		defer close(done)
		for {
			// Only a higher slot looks for a node of its own.
			var spreadCheck <-chan time.Time
			if slot > 0 {
				spreadCheck = time.After(jitter(t.spreadWait(slot)))
			}
			select {
			case <-ctx.Done():
				return
			case <-opened.session.Done():
				return
			case goAway := <-opened.session.GoAway():
				if next, ok := t.move(life, ctx, slot, opened, goAway, jitter); ok {
					moved <- next
				}
				return
			case <-spreadCheck:
				if next, ok := t.spread(life, ctx, slot); ok {
					moved <- next
					return
				}
			}
		}
	}()
	return func() {
		cancel()
		<-done
	}
}

// move opens the replacement the relay asked for, away from the node the
// tunnel is on, starting at the node it named. Until one opens, the tunnel
// keeps serving and move tries again; it gives up when the tunnel ends.
func (t *tunnelSet) move(
	life, ctx context.Context,
	slot int,
	opened openedTunnel,
	goAway protocol.GoAway,
	jitter func(time.Duration) time.Duration,
) (openedTunnel, bool) {
	if !t.lockMoves(ctx) {
		return openedTunnel{}, false
	}
	defer t.unlockMoves()
	var via *Endpoint
	if target, err := ParseEndpoint(goAway.Connect); err == nil && target.WebSocket {
		via = &target
	}
	t.client.logger().Info("relay asked the tunnel to move",
		"tunnel", slot, "node_id", opened.ack.NodeID, "reason", goAway.Reason, "connect", goAway.Connect)
	t.mu.Lock()
	t.leaving[slot] = opened.ack.NodeID
	for other, node := range t.nodes {
		if other != slot && node != "" && node == goAway.Node {
			// Another tunnel of this shop is there already; the relay steers
			// this one elsewhere.
			via = nil
		}
	}
	t.mu.Unlock()
	defer func() {
		t.mu.Lock()
		delete(t.leaving, slot)
		t.mu.Unlock()
	}()
	// A fresh count, kept across this move's tries (a node takes the third
	// wherever it lands), and cleared after: it says nothing about the next
	// redial.
	t.resetAttempts(slot)
	defer t.resetAttempts(slot)
	wait := moveRetryFirst
	for {
		next, err := t.openReplacement(life, ctx, slot, via)
		if err == nil {
			return next, true
		}
		t.client.logger().Warn("relay tunnel replacement failed; the tunnel keeps serving",
			"tunnel", slot, "error", err)
		// A node that turned it away (draining, or a full one with no
		// lighter address to name) says when to come back; the balancer
		// picks again then. Anything else backs off.
		pause := wait
		var busy *RelayBusyError
		if errors.As(err, &busy) && busy.RetryAfter > 0 {
			pause = busy.RetryAfter
		} else {
			wait = min(2*wait, moveRetryMax)
		}
		select {
		case <-ctx.Done():
			return openedTunnel{}, false
		case <-opened.session.Done():
			return openedTunnel{}, false
		case <-time.After(jitter(pause)):
		}
		// The node named may be gone: from the second try, dial as usual.
		via = nil
	}
}

func (t *tunnelSet) lockMoves(ctx context.Context) bool {
	select {
	case t.moving <- struct{}{}:
		return true
	case <-ctx.Done():
		return false
	}
}

func (t *tunnelSet) unlockMoves() {
	<-t.moving
}

// openReplacement opens a replacement tunnel for slot. A tunnel lives as long
// as the context it was dialled with (a WebSocket is bound to it), so it is
// dialled under life, the connector's; watch, the watcher's, only abandons it
// while it is still opening.
func (t *tunnelSet) openReplacement(life, watch context.Context, slot int, via *Endpoint) (openedTunnel, error) {
	openCtx, cancel := context.WithCancel(life)
	stopWatching := context.AfterFunc(watch, cancel)
	opened, err := t.open(openCtx, slot, via)
	if !stopWatching() {
		// The watcher ended first.
		if err == nil {
			_ = opened.session.Close()
			err = context.Canceled
		}
		cancel()
		return openedTunnel{}, err
	}
	if err != nil {
		cancel()
		return openedTunnel{}, err
	}
	go func() {
		<-opened.session.Done()
		cancel()
	}()
	return opened, nil
}

// spread opens a replacement for a slot's tunnel that shares a node with a
// lower slot's.
func (t *tunnelSet) spread(life, ctx context.Context, slot int) (openedTunnel, bool) {
	if !t.lockMoves(ctx) {
		return openedTunnel{}, false
	}
	defer t.unlockMoves()
	node, shared := t.sharesNode(slot)
	if !shared {
		t.setSpreadWait(slot, t.spreadFirst())
		return openedTunnel{}, false
	}
	t.client.logger().Info("relay tunnel shares a node with another; looking for its own",
		"tunnel", slot, "node_id", node)
	// A fresh count: these tries say nothing about the next redial.
	t.resetAttempts(slot)
	opened, err := t.openReplacement(life, ctx, slot, nil)
	t.resetAttempts(slot)
	if err != nil {
		t.backOffSpread(slot)
		return openedTunnel{}, false
	}
	if opened.ack.NodeID == node {
		// The relay put it back: most likely the only live node. It replaced
		// the old tunnel there, so serve the new one.
		t.backOffSpread(slot)
	} else {
		t.setSpreadWait(slot, t.spreadFirst())
	}
	return opened, true
}

func (t *tunnelSet) spreadFirst() time.Duration {
	if t.client.SpreadCheckInterval > 0 {
		return t.client.SpreadCheckInterval
	}
	return spreadCheckFirst
}

func (t *tunnelSet) spreadWait(slot int) time.Duration {
	t.mu.Lock()
	defer t.mu.Unlock()
	if wait := t.spreadDelay[slot]; wait > 0 {
		return wait
	}
	return t.spreadFirst()
}

func (t *tunnelSet) backOffSpread(slot int) {
	t.setSpreadWait(slot, min(2*t.spreadWait(slot), spreadCheckGrowth*t.spreadFirst()))
}

func (t *tunnelSet) setSpreadWait(slot int, wait time.Duration) {
	t.mu.Lock()
	t.spreadDelay[slot] = wait
	t.mu.Unlock()
}

// sharesNode reports whether slot's tunnel is on the same node as a lower
// slot's, and which node.
func (t *tunnelSet) sharesNode(slot int) (string, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	node := t.nodes[slot]
	if node == "" {
		return "", false
	}
	for other := 0; other < slot; other++ {
		if t.nodes[other] == node {
			return node, true
		}
	}
	return "", false
}

// retire closes a tunnel that was replaced. A relay that answers Retire
// opens nothing on it from then on, so it closes when its last stream ends;
// an older one may go on opening streams, so it closes after a short grace.
func retire(old openedTunnel) {
	grace := retireGrace
	if old.moves {
		ctx, cancel := context.WithTimeout(context.Background(), retireAnswerWait)
		if old.session.Retire(ctx) == nil {
			grace = retiredGrace
		}
		cancel()
	}
	retireSession(old.session, grace)
}

// retireSession closes a tunnel that was replaced, once it carries no stream
// or after grace.
func retireSession(session *protocol.Session, grace time.Duration) {
	deadline := time.Now().Add(grace)
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for session.OpenStreams() > 0 && time.Now().Before(deadline) {
		select {
		case <-session.Done():
			return
		case <-ticker.C:
		}
	}
	_ = session.Close()
}
