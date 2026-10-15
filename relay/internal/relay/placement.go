package relay

import (
	"math"
	"net/http"
	"slices"
	"strconv"
	"strings"

	"pointy/relay/internal/protocol"
)

// Where a node sends a tunnel that arrives on it.
const (
	placementStay     = "stay"
	placementRedirect = "redirect"
	placementTurnAway = "turn_away"
)

// placementSlack is how far above the lightest node a node may be and still
// take a tunnel: max(placementMinSlack, placementSlackShare of the average).
const (
	placementMinSlack   = 5
	placementSlackShare = 0.05
)

type tunnelPlacementRequest struct {
	// attempt is the connector's try count for this tunnel, from 1.
	attempt int
	// avoid is the nodes holding the shop's other tunnels.
	avoid []string
	// direct is a dial to the address a node redirected to.
	direct bool
	// followsRedirects is a connector that sent the placement headers. One
	// before them reads a 409 as a broken address and falls back to TCP, so
	// it is only ever turned away.
	followsRedirects bool
}

type tunnelPlacement struct {
	outcome string
	// connect is the redirect target's tunnel address.
	connect string
}

func placementRequestFrom(r *http.Request) tunnelPlacementRequest {
	rawAttempt := strings.TrimSpace(r.Header.Get(protocol.TunnelAttemptHeader))
	attempt, _ := strconv.Atoi(rawAttempt)
	var avoid []string
	for _, id := range strings.Split(r.Header.Get(protocol.TunnelAvoidHeader), ",") {
		if id = strings.TrimSpace(id); id != "" && len(avoid) < protocol.MaxTunnels {
			avoid = append(avoid, id)
		}
	}
	return tunnelPlacementRequest{
		attempt:          max(attempt, 1),
		avoid:            avoid,
		direct:           r.Header.Get(protocol.TunnelDirectHeader) == "1",
		followsRedirects: rawAttempt != "",
	}
}

// placeTunnel decides, before any handshake, whether this node takes an
// arriving tunnel, sends it to a lighter node, or turns it away so the
// balancer lands it elsewhere:
//
//   - Stay when this node is among the lightest: at most the lightest count
//     plus max(5, 5% of the average). Never stay on a node holding the shop's
//     other tunnel while another node is live.
//   - Redirect to the lightest other node that has a verified address.
//   - Turn away when no such node has one (or redirects are off).
//
// It never keeps a shop out: a stale or missing view, a dial to a redirect
// target, or the third try is accepted wherever it lands. Only a draining node
// never accepts.
func placeTunnel(
	self string,
	nodes []NodeInfo,
	fresh bool,
	redirect bool,
	request tunnelPlacementRequest,
) tunnelPlacement {
	redirect = redirect && request.followsRedirects
	var me NodeInfo
	for _, node := range nodes {
		if node.NodeID == self {
			me = node
		}
	}
	if me.Draining {
		if placement := elsewhere(self, nodes, request.avoid, redirect); placement.outcome == placementRedirect {
			return placement
		}
		// Every other node holds one of the shop's tunnels already: two on
		// one of them beat one here, which is about to close.
		return elsewhere(self, nodes, nil, redirect)
	}
	if !fresh || request.direct || request.attempt >= protocol.MaxPlacementAttempts {
		return tunnelPlacement{outcome: placementStay}
	}

	var serving []NodeInfo
	for _, node := range nodes {
		if !node.Draining {
			serving = append(serving, node)
		}
	}
	var eligible []NodeInfo
	for _, node := range serving {
		if !slices.Contains(request.avoid, node.NodeID) {
			eligible = append(eligible, node)
		}
	}
	if !slices.Contains(request.avoid, self) {
		lightest := me.Tunnels
		total := 0
		for _, node := range eligible {
			lightest = min(lightest, node.Tunnels)
		}
		for _, node := range serving {
			total += node.Tunnels
		}
		average := float64(total) / float64(max(len(serving), 1))
		slack := max(placementMinSlack, int(math.Ceil(placementSlackShare*average)))
		if me.Tunnels <= lightest+slack {
			return tunnelPlacement{outcome: placementStay}
		}
	} else if len(eligible) == 0 {
		// This node holds the shop's other tunnel, but no other node is live:
		// two tunnels here still beat one.
		return tunnelPlacement{outcome: placementStay}
	}
	return elsewhere(self, eligible, nil, redirect)
}

// elsewhere sends the tunnel to the lightest other node with a verified
// address, or turns it away when there is none to name.
func elsewhere(self string, nodes []NodeInfo, avoid []string, redirect bool) tunnelPlacement {
	if redirect {
		var target *NodeInfo
		for i := range nodes {
			node := &nodes[i]
			if node.NodeID == self || node.Draining || node.PublicTunnelURL == "" ||
				slices.Contains(avoid, node.NodeID) {
				continue
			}
			if target == nil || node.Tunnels < target.Tunnels {
				target = node
			}
		}
		if target != nil {
			return tunnelPlacement{outcome: placementRedirect, connect: target.PublicTunnelURL}
		}
	}
	return tunnelPlacement{outcome: placementTurnAway}
}
