package protocol

import "encoding/json"

// Moving a tunnel without dropping a request.
//
// A relay node that is shutting down, or holds more than its share of tunnels,
// asks a connector to move a tunnel with GoAway. The connector opens the
// replacement first, then sends Retire on the old tunnel; the relay stops
// opening streams on it and answers with Retire. Frames on a connection keep
// their order, so once the connector reads that answer no new stream can
// arrive, and it closes the old tunnel when its last stream ends.
//
// Every one of these frames ends the session of a peer that predates them, so
// a connector only sends Capabilities to a relay whose HelloAck says Moves,
// and the relay only sends GoAway once Capabilities said the connector moves.

// Capabilities is what a connector tells the relay it can do, sent once, right
// after the HelloAck.
type Capabilities struct {
	// GoAway is a connector that moves a tunnel when asked.
	GoAway bool `json:"go_away"`
}

// GoAway asks a connector to move a tunnel.
type GoAway struct {
	// Reason is why (GoAwayDrain, GoAwayRebalance), for the logs.
	Reason string `json:"reason"`
	// Connect is the tunnel address of the node to move to, when the relay
	// has one; dialled like a redirect. Empty: dial as usual.
	Connect string `json:"connect,omitempty"`
	// Node is the id of the node at Connect. A connector whose other tunnel
	// is there already dials as usual instead: two nodes shedding at once
	// may each pick the same target for the shop's two tunnels.
	Node string `json:"node,omitempty"`
}

// Why a relay asks a tunnel to move.
const (
	GoAwayDrain     = "drain"
	GoAwayRebalance = "rebalance"
)

func encodeJSON(value any) []byte {
	payload, err := json.Marshal(value)
	if err != nil {
		return nil
	}
	return payload
}
