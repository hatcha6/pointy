package relay

import (
	"context"
	"log/slog"
	"math"
	"slices"
	"time"

	"pointy/relay/internal/observability"
	"pointy/relay/internal/protocol"
)

// Rebalancing hands tunnels from a heavy node to the lightest one. Placement
// keeps new tunnels even, but can't empty a node that is already full: after
// a scale-out, or a node coming back from a restart, the new node starts
// empty and the others stay full until their tunnels happen to reconnect.
const (
	defaultRebalanceInterval = 30 * time.Second
	// defaultRebalanceMinAge leaves a tunnel that just opened alone: it may
	// have just moved, and a shop shouldn't be shuffled twice in a row.
	defaultRebalanceMinAge = 5 * time.Minute
	// A node sheds at most rebalanceShare of its tunnels a round, and never
	// more than rebalanceMaxPerRound, so no node sees a reconnect storm.
	rebalanceShare       = 0.02
	rebalanceMaxPerRound = 20
	// A node sheds only while it is above the average and more than
	// max(rebalanceMinSlack, rebalanceSlackShare of the average) above the
	// lightest node.
	rebalanceMinSlack   = 5
	rebalanceSlackShare = 0.10
)

// shedPlan is how many tunnels self hands over this round, and to which node.
// Zero when the view is stale, self is draining (the drain moves everything),
// no other node takes tunnels, or self is within the slack of the lightest.
//
// Shedding toward the lightest node until the spread is within the slack
// leaves every node within it of the average too: with the gap from heaviest
// to lightest at most 10% of the average, no node can be more than 10% off it.
// A count never above half the gap, nor above what self holds over the
// average, keeps two heavy nodes shedding at once from overshooting.
func shedPlan(self string, nodes []NodeInfo, fresh bool) (int, NodeInfo) {
	if !fresh {
		return 0, NodeInfo{}
	}
	var me *NodeInfo
	var lightest *NodeInfo
	total, serving := 0, 0
	for i := range nodes {
		node := &nodes[i]
		if node.Draining {
			if node.NodeID == self {
				return 0, NodeInfo{}
			}
			continue
		}
		total += node.Tunnels
		serving++
		if node.NodeID == self {
			me = node
		} else if lightest == nil || node.Tunnels < lightest.Tunnels {
			lightest = node
		}
	}
	if me == nil || lightest == nil {
		return 0, NodeInfo{}
	}
	average := float64(total) / float64(serving)
	slack := max(rebalanceMinSlack, int(math.Ceil(rebalanceSlackShare*average)))
	gap := me.Tunnels - lightest.Tunnels
	if float64(me.Tunnels) <= average || gap <= slack {
		return 0, NodeInfo{}
	}
	count := min(
		int(math.Ceil(rebalanceShare*float64(me.Tunnels))),
		rebalanceMaxPerRound,
		gap/2,
		me.Tunnels-int(math.Ceil(average)),
	)
	return max(count, 1), *lightest
}

// Rebalancer sheds tunnels from this node while it holds more than its share.
//
// It only moves a tunnel whose connector moves when asked (never an older
// connector's, which GoAway would disconnect), whose shop has another tunnel
// on a live node other than this one and the target (so the shop stays
// reachable throughout, and its tunnels stay on different nodes), and that has
// been open at least MinAge. Idle tunnels go first.
type Rebalancer struct {
	Hub      *Hub
	Fleet    *Fleet
	Presence ConnectorPresence
	Drain    *NodeDrain
	NodeID   string
	Interval time.Duration
	MinAge   time.Duration
	Logger   *slog.Logger
	Metrics  *observability.Metrics
}

// Run sheds every Interval until ctx ends.
func (b Rebalancer) Run(ctx context.Context) {
	interval := b.Interval
	if interval <= 0 {
		interval = defaultRebalanceInterval
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			b.Round(ctx)
		}
	}
}

// Round sheds once, and returns how many tunnels it asked to move.
func (b Rebalancer) Round(ctx context.Context) int {
	if b.Drain.Draining() || b.Presence == nil {
		return 0
	}
	nodes, fresh := b.Fleet.View()
	count, target := shedPlan(b.NodeID, nodes, fresh)
	if count == 0 {
		return 0
	}
	live := map[string]bool{}
	for _, node := range nodes {
		live[node.NodeID] = true
	}
	minAge := b.MinAge
	if minAge <= 0 {
		minAge = defaultRebalanceMinAge
	}
	type candidate struct {
		HubTunnel
		streams int
	}
	var candidates []candidate
	for _, tunnel := range b.Hub.Tunnels() {
		if tunnel.Moves() && !tunnel.Moving && !tunnel.Retired && time.Since(tunnel.ConnectedAt) >= minAge {
			candidates = append(candidates, candidate{tunnel, tunnel.Session.OpenStreams()})
		}
	}
	slices.SortStableFunc(candidates, func(a, b candidate) int { return a.streams - b.streams })

	moved := 0
	for _, tunnel := range candidates {
		if moved == count || ctx.Err() != nil {
			break
		}
		if !b.shopStaysReachable(ctx, tunnel.InstallationID, target.NodeID, live) {
			continue
		}
		if b.Hub.AskToMove(tunnel.InstallationID, tunnel.Session, protocol.GoAway{
			Reason:  protocol.GoAwayRebalance,
			Connect: target.PublicTunnelURL,
			Node:    target.NodeID,
		}) {
			moved++
			b.Metrics.RecordTunnelMove(protocol.GoAwayRebalance)
		}
	}
	if moved > 0 {
		b.logger().Info(
			"relay node handing tunnels to a lighter node",
			"moved", moved,
			"planned", count,
			"target_node_id", target.NodeID,
		)
	}
	return moved
}

// shopStaysReachable is a shop with a tunnel on another live node than this
// one, and none on the target.
func (b Rebalancer) shopStaysReachable(ctx context.Context, installationID, target string, live map[string]bool) bool {
	records, err := b.Presence.List(ctx, installationID)
	if err != nil {
		return false
	}
	elsewhere := false
	for _, record := range records {
		switch {
		case record.NodeID == target:
			return false
		case record.NodeID != b.NodeID && live[record.NodeID]:
			elsewhere = true
		}
	}
	return elsewhere
}

func (b Rebalancer) logger() *slog.Logger {
	if b.Logger != nil {
		return b.Logger
	}
	return slog.Default()
}
