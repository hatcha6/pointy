package relay

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
)

// NodeInfo is what each relay node publishes about itself, every few seconds.
type NodeInfo struct {
	NodeID   string `json:"node_id"`
	Tunnels  int    `json:"tunnels"`
	Draining bool   `json:"draining"`
	// PublicTunnelURL is this node's own tunnel address, which reaches this
	// node and no other. Empty until the node has checked it really does.
	PublicTunnelURL string    `json:"public_tunnel_url,omitempty"`
	StartedAt       time.Time `json:"started_at"`
	UpdatedAt       time.Time `json:"updated_at"`
	// Stats is what the console's system view shows of the node. Nodes
	// before it publish none.
	Stats *NodeStats `json:"stats,omitempty"`
}

// NodeRegistry is the live relay nodes. A node is live while its record
// exists: it stops refreshing when it dies, and the record expires.
type NodeRegistry interface {
	Publish(ctx context.Context, info NodeInfo, ttl time.Duration) error
	Nodes(ctx context.Context) ([]NodeInfo, error)
	Leave(ctx context.Context, nodeID string) error
}

// RedisNodeRegistry keeps <prefix>:node:<id> per node, with a TTL, and the set
// <prefix>:nodes naming them; a read drops names whose record expired.
type RedisNodeRegistry struct {
	client    redis.Cmdable
	keyPrefix string
}

func NewRedisNodeRegistry(client redis.Cmdable, keyPrefix string) *RedisNodeRegistry {
	keyPrefix = strings.TrimRight(strings.TrimSpace(keyPrefix), ":")
	if keyPrefix == "" {
		keyPrefix = "pointy:relay"
	}
	return &RedisNodeRegistry{client: client, keyPrefix: keyPrefix}
}

func (r *RedisNodeRegistry) Publish(ctx context.Context, info NodeInfo, ttl time.Duration) error {
	content, err := json.Marshal(info)
	if err != nil {
		return err
	}
	_, err = r.client.Pipelined(ctx, func(pipe redis.Pipeliner) error {
		pipe.Set(ctx, r.nodeKey(info.NodeID), content, ttl)
		pipe.SAdd(ctx, r.indexKey(), info.NodeID)
		return nil
	})
	return err
}

func (r *RedisNodeRegistry) Nodes(ctx context.Context) ([]NodeInfo, error) {
	ids, err := r.client.SMembers(ctx, r.indexKey()).Result()
	if err != nil && !errors.Is(err, redis.Nil) {
		return nil, err
	}
	gets := make([]*redis.StringCmd, len(ids))
	_, err = r.client.Pipelined(ctx, func(pipe redis.Pipeliner) error {
		for i, id := range ids {
			gets[i] = pipe.Get(ctx, r.nodeKey(id))
		}
		return nil
	})
	if err != nil && !errors.Is(err, redis.Nil) {
		return nil, err
	}
	var nodes []NodeInfo
	var gone []any
	for i, get := range gets {
		content, err := get.Bytes()
		var info NodeInfo
		if err != nil || json.Unmarshal(content, &info) != nil || info.NodeID == "" {
			gone = append(gone, ids[i])
			continue
		}
		nodes = append(nodes, info)
	}
	if len(gone) > 0 {
		_ = r.client.SRem(ctx, r.indexKey(), gone...).Err()
	}
	sort.Slice(nodes, func(i, j int) bool { return nodes[i].NodeID < nodes[j].NodeID })
	return nodes, nil
}

func (r *RedisNodeRegistry) Leave(ctx context.Context, nodeID string) error {
	_, err := r.client.Pipelined(ctx, func(pipe redis.Pipeliner) error {
		pipe.Del(ctx, r.nodeKey(nodeID))
		pipe.SRem(ctx, r.indexKey(), nodeID)
		return nil
	})
	return err
}

func (r *RedisNodeRegistry) nodeKey(nodeID string) string {
	return r.keyPrefix + ":node:" + nodeID
}

func (r *RedisNodeRegistry) indexKey() string {
	return r.keyPrefix + ":nodes"
}

const (
	defaultFleetInterval = 5 * time.Second
	defaultFleetTTL      = 15 * time.Second
)

// Fleet is this node's part in the registry: it publishes the node's load
// and address every Interval, and keeps the last list of live nodes it read,
// which placement and forwarding consult without a Redis round trip.
type Fleet struct {
	Registry NodeRegistry
	NodeID   string
	Hub      *Hub
	Drain    *NodeDrain
	// Stats, when set, is published with each refresh (NodeStatsOf).
	Stats func() *NodeStats
	// Address is this node's verified tunnel address, if any.
	Address  *NodeAddress
	Interval time.Duration
	// TTL is how long a node's record outlives its last refresh, and how old
	// the list read here may get before placement stops trusting it.
	TTL    time.Duration
	Logger *slog.Logger

	startOnce sync.Once
	startedAt time.Time
	mu        sync.RWMutex
	nodes     []NodeInfo
	readAt    time.Time
	// gone is the nodes that were in the registry and left it, and when. A
	// node that vanished must be told apart from one that never registered (a
	// relay older than the registry, mid-deploy, whose tunnels are fine).
	gone map[string]time.Time
}

// goneNodeMemory is how long a departed node is remembered.
const goneNodeMemory = 10 * time.Minute

func (f *Fleet) wasLive(nodeID string) bool {
	for _, node := range f.nodes {
		if node.NodeID == nodeID {
			return true
		}
	}
	return false
}

// Run publishes and reads until ctx ends, then takes the node out of the
// registry so placement stops counting it at once.
func (f *Fleet) Run(ctx context.Context) {
	ticker := time.NewTicker(f.interval())
	defer ticker.Stop()
	for {
		f.Refresh(ctx)
		select {
		case <-ctx.Done():
			f.Leave()
			return
		case <-ticker.C:
		}
	}
}

// Leave takes the node out of the registry. Nil-safe.
func (f *Fleet) Leave() {
	if f == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_ = f.Registry.Leave(ctx, f.NodeID)
}

// Refresh publishes this node's record and reads the fleet once.
func (f *Fleet) Refresh(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, f.interval())
	defer cancel()
	now := time.Now().UTC()
	f.startOnce.Do(func() { f.startedAt = now })
	info := NodeInfo{
		NodeID:          f.NodeID,
		Tunnels:         f.localTunnels(),
		Draining:        f.Drain.Draining(),
		PublicTunnelURL: f.Address.TunnelURL(),
		StartedAt:       f.startedAt,
		UpdatedAt:       now,
	}
	if f.Stats != nil {
		info.Stats = f.Stats()
	}
	if err := f.Registry.Publish(ctx, info, f.ttl()); err != nil {
		f.logger().Warn("relay node registry publish failed", "error", err)
		return
	}
	nodes, err := f.Registry.Nodes(ctx)
	if err != nil {
		f.logger().Warn("relay node registry read failed", "error", err)
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.gone == nil {
		f.gone = map[string]time.Time{}
	}
	live := map[string]bool{}
	for _, node := range nodes {
		live[node.NodeID] = true
		if node.NodeID != f.NodeID && !f.wasLive(node.NodeID) {
			f.logger().Info("relay node joined the fleet", "node_id", node.NodeID, "public_tunnel_url", node.PublicTunnelURL)
		}
		delete(f.gone, node.NodeID)
	}
	for _, node := range f.nodes {
		if !live[node.NodeID] {
			f.logger().Warn("relay node left the fleet", "node_id", node.NodeID)
			f.gone[node.NodeID] = now
		}
	}
	// Records of a departed node all expire within their TTL; long after
	// that, there is nothing left to drop.
	for id, at := range f.gone {
		if now.Sub(at) > goneNodeMemory {
			delete(f.gone, id)
		}
	}
	f.nodes = nodes
	f.readAt = now
}

// View is the live nodes as last read, with this node's own count taken
// live, and whether the read is recent enough to steer by.
func (f *Fleet) View() ([]NodeInfo, bool) {
	if f == nil {
		return nil, false
	}
	f.mu.RLock()
	nodes := append([]NodeInfo(nil), f.nodes...)
	fresh := !f.readAt.IsZero() && time.Since(f.readAt) <= f.ttl()
	f.mu.RUnlock()
	self := -1
	for i := range nodes {
		if nodes[i].NodeID == f.NodeID {
			self = i
		}
	}
	if self < 0 {
		nodes = append(nodes, NodeInfo{NodeID: f.NodeID})
		self = len(nodes) - 1
	}
	nodes[self].Tunnels = f.localTunnels()
	nodes[self].Draining = f.Drain.Draining()
	nodes[self].PublicTunnelURL = f.Address.TunnelURL()
	return nodes, fresh
}

// otherNodeServing reports a fresh view with another node that takes tunnels.
func (f *Fleet) otherNodeServing() bool {
	nodes, fresh := f.View()
	if !fresh {
		return false
	}
	for _, node := range nodes {
		if node.NodeID != f.NodeID && !node.Draining {
			return true
		}
	}
	return false
}

// NodeGone reports a node that was in the registry and has left it: its
// records point at a dead address.
func (f *Fleet) NodeGone(nodeID string) bool {
	if f == nil {
		return false
	}
	f.mu.RLock()
	defer f.mu.RUnlock()
	_, gone := f.gone[nodeID]
	return gone
}

func (f *Fleet) localTunnels() int {
	if f.Hub == nil {
		return 0
	}
	return f.Hub.TunnelCount()
}

func (f *Fleet) interval() time.Duration {
	if f.Interval > 0 {
		return f.Interval
	}
	return defaultFleetInterval
}

func (f *Fleet) ttl() time.Duration {
	if f.TTL > 0 {
		return f.TTL
	}
	return defaultFleetTTL
}

func (f *Fleet) logger() *slog.Logger {
	if f.Logger != nil {
		return f.Logger
	}
	return slog.Default()
}
