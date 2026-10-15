package protocol

// A shop keeps more than one tunnel open, each on its own relay node, so losing
// a node never takes the shop offline. Each tunnel is numbered from 1 in the
// Hello frame's StreamID, a field relays before this ignored: a relay keeps one
// session per shop and tunnel number, and an old connector's 0 keeps the old
// rule of one session per shop.
const (
	// MaxTunnels caps the tunnels a relay may ask a shop to keep.
	MaxTunnels = 4
	// LegacyTunnelID is what a connector that numbers no tunnels sends.
	LegacyTunnelID uint64 = 0
)

// Headers a connector sends with the tunnel's WebSocket upgrade. They only
// steer where the tunnel is placed: identity is proven inside, by the inner
// TLS and the token, so a forged header can at worst land a tunnel on a node
// the relay wouldn't have picked.
const (
	// TunnelAttemptHeader counts this tunnel's tries since it last opened,
	// from 1. From MaxPlacementAttempts on the node takes it wherever it lands.
	TunnelAttemptHeader = "X-Pointy-Tunnel-Attempt"
	// TunnelAvoidHeader names the nodes holding the shop's other tunnels,
	// comma-separated, so this one lands elsewhere.
	TunnelAvoidHeader = "X-Pointy-Tunnel-Avoid"
	// TunnelDirectHeader marks a dial to the address a node redirected to:
	// that node takes it without placing it again, so a redirect is followed
	// at most once.
	TunnelDirectHeader = "X-Pointy-Tunnel-Direct"
)

// MaxPlacementAttempts is the try from which a node stops steering a tunnel
// elsewhere. Spreading tunnels evenly is a preference; it never keeps a shop
// out for long.
const MaxPlacementAttempts = 3

// TunnelRedirect is the body of a node's 409 answer to a tunnel upgrade: dial
// Connect, another node's own address, instead.
type TunnelRedirect struct {
	Connect string `json:"connect"`
}
