package relay

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"pointy/relay/internal/observability"
	"pointy/relay/internal/protocol"
)

// NodeDrain is a node's switch from serving to shutting down. Once on, the
// node reports not ready, takes no new tunnel, and the registry tells the
// other nodes, so placement sends tunnels elsewhere. A nil NodeDrain is a node
// that never drains.
type NodeDrain struct {
	mu      sync.Mutex
	on      bool
	started chan struct{}
}

// Begin turns draining on. It never turns off: a draining node exits.
func (d *NodeDrain) Begin() {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !d.on {
		d.on = true
		close(d.startedLocked())
	}
}

// Draining reports whether the node is shutting down.
func (d *NodeDrain) Draining() bool {
	if d == nil {
		return false
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.on
}

// Started is closed once draining begins.
func (d *NodeDrain) Started() <-chan struct{} {
	if d == nil {
		return nil
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.startedLocked()
}

func (d *NodeDrain) startedLocked() chan struct{} {
	if d.started == nil {
		d.started = make(chan struct{})
	}
	return d.started
}

const (
	defaultDrainTimeout = 20 * time.Second
	drainPoll           = 250 * time.Millisecond
)

// Drainer moves a node's tunnels to other nodes before it exits, so a deploy
// or a scale-in fails no request.
type Drainer struct {
	Hub   *Hub
	Drain *NodeDrain
	// Fleet, when set, is told at once, so the other nodes stop placing
	// tunnels here before the next regular publish.
	Fleet *Fleet
	// Timeout bounds the whole drain. Keep it below the platform's grace
	// between its stop signal and its kill.
	Timeout time.Duration
	Logger  *slog.Logger
	Metrics *observability.Metrics
}

// DrainResult is how a drain went.
type DrainResult struct {
	// Moved is the tunnels asked to move.
	Moved int
	// Left is the tunnels still open when the drain ended, which the caller
	// closes: tunnels of connectors that can't move, and any that didn't
	// finish moving in time.
	Left int
	// TimedOut is a drain that hit Timeout with streams still open.
	TimedOut bool
}

// Run drains the node:
//
//  1. turns draining on, which /readyz, placement and the registry report;
//  2. asks every tunnel whose connector moves to move (GoAway). Each opens
//     its replacement on another node, retires this one, and closes it once
//     its last stream ends;
//  3. waits until every tunnel that could move has, and no stream is open on
//     the rest, or until Timeout.
//
// Closing what is left is the caller's, along with the HTTP server: a tunnel
// of an older connector is served to the end, then closed, and its connector
// reconnects as it always has.
func (d Drainer) Run(ctx context.Context) DrainResult {
	timeout := d.Timeout
	if timeout <= 0 {
		timeout = defaultDrainTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	d.Drain.Begin()
	if d.Fleet != nil {
		d.Fleet.Refresh(ctx)
	}
	logger := d.logger()
	logger.Info("relay node draining", "tunnels", d.Hub.TunnelCount(), "timeout", timeout.String())

	var result DrainResult
	ticker := time.NewTicker(drainPoll)
	defer ticker.Stop()
	for {
		pending := false
		// With no other node to take them (a single node, or the last one),
		// moving tunnels would only send them round to this one: they are
		// served to the end like any other.
		canMove := d.Fleet.otherNodeServing()
		for _, tunnel := range d.Hub.Tunnels() {
			if canMove && tunnel.Moves() {
				pending = true
				// A connector that had not yet said it moves when the drain
				// began is asked on a later pass.
				if !tunnel.Moving && !tunnel.Retired && d.Hub.AskToMove(
					tunnel.InstallationID,
					tunnel.Session,
					protocol.GoAway{Reason: protocol.GoAwayDrain},
				) {
					result.Moved++
					d.Metrics.RecordTunnelMove(protocol.GoAwayDrain)
				}
			} else if tunnel.Session.OpenStreams() > 0 {
				pending = true
			}
		}
		if !pending {
			break
		}
		select {
		case <-ctx.Done():
			result.TimedOut = true
		case <-ticker.C:
			continue
		}
		break
	}
	result.Left = len(d.Hub.Tunnels())
	logger.Info(
		"relay node drained",
		"moved", result.Moved,
		"left", result.Left,
		"timed_out", result.TimedOut,
	)
	return result
}

func (d Drainer) logger() *slog.Logger {
	if d.Logger != nil {
		return d.Logger
	}
	return slog.Default()
}
