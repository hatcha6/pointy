# Relay tunnel: horizontal scaling and failover

Status: **phases 1, 2, 3 and 4 built** (2026-10-15), none deployed or released.

- Phase 1 (relay): serves `GET /v1/connector/tunnel` (WebSocket, inner mTLS
  through the same `ConnectorServer` path as TCP), names the node in
  `X-Pointy-Relay-Node` on `/healthz` and `/readyz`, limits new tunnels per
  node (`POINTY_RELAY_CONNECTOR_HANDSHAKE_RATE`/`_BURST`, default 50/s, burst
  100, shared by TCP and WebSocket) and counts open tunnels per transport
  (`active_connectors_by_transport` in `/v1/status`).
- Phase 2 (connector, plus the relay's `HelloAck` payload): see sections 2
  and 4. The relay advertises `POINTY_RELAY_CONNECTOR_ENDPOINTS` (default: the
  tunnel over HTTPS on `POINTY_RELAY_PUBLIC_URL`); the connector saves it,
  dials `wss://my.dftr.ly/v1/connector/tunnel` by default when its TCP address
  is `tunnel.dftr.ly`, falls back to TCP in the same attempt, jitters every
  wait, honours `Retry-After`, and detects a dead tunnel in 30 s.
- Phase 3 (relay and connector): sections 3 and 3b. Two tunnels per shop
  (`POINTY_RELAY_CONNECTOR_TUNNELS`, default 2), presence as a set, the hub
  choosing by open streams, forwarding that tries the next node only when the
  first couldn't be connected to, the node registry with self-verified
  addresses and dead-node cleanup, and placement with redirects
  (`POINTY_RELAY_TUNNEL_REDIRECT`, `POINTY_RELAY_NODE_PUBLIC_URL_TEMPLATE`).
  End-to-end tests 1, 3, 4 and 5 pass (`make relay-fleet-test`).
- Phase 4 (relay and connector): sections 5, 6 and the rebalancing in 3b.
  SIGTERM drains the node (`POINTY_RELAY_DRAIN_TIMEOUT`, 20 s): tunnels move
  with `GoAway`, make-before-break, and a `Retire` handshake guarantees no new
  stream lands on the old tunnel. Requests wait up to 8 s for a shop between
  tunnels (`POINTY_RELAY_CONNECTOR_HOLD`). Heavy nodes hand tunnels to the
  lightest every 30 s (`POINTY_RELAY_REBALANCE`). End-to-end tests 2 and 6
  pass, and all six run in `make relay-fleet-test`.
- Next: find the platform's stop grace period (question 4) and keep
  `POINTY_RELAY_DRAIN_TIMEOUT` + 5 s below it; deploy the relay, then probe
  the upgrade through our NGINX balancer on `my.dftr.ly`, check each node's
  startup line "relay node placement" and whether its address verified, and
  hold a test tunnel for 24 h; redeploy once more under traffic and check
  `/v1/status` for failed requests (phase 4's last bar); then cut an on-prem
  release.

**What phase 4 settled differently from the draft below:**

- **Retire.** "Close the old tunnel once the replacement is up and it has no
  open streams" never happens while the relay keeps opening streams on it.
  After its replacement is up, the connector sends `Retire`; the relay stops
  opening streams on that tunnel, drops its presence record, and answers
  `Retire`. Frames keep their order, so after the answer nothing new arrives,
  and the old tunnel closes when its last stream ends (10 minutes at most, for
  a camera feed). A request in flight finishes where it started.
- **Who may get `GoAway`.** The relay says `"moves": true` in its `HelloAck`,
  and the connector sends `Capabilities` only to a relay that does; the
  draft keyed this on `"tunnels"`, which a phase 3 relay also sends but whose
  session would end on the unknown frame.
- **Rebalancing rule.** Shedding above 1.20× the average can't meet test 6's
  ±15%: with three nodes, two held at 1.2× leave the third at 0.6×. A node now
  sheds while it is above the average and more than max(5, 10% of the
  average) above the lightest node. Settling within that gap of each other
  keeps every node within 10% of the average. Each round sheds 2% of the
  node's tunnels (at least 1, at most 20) and never more than half the gap or
  its excess over the average, so two heavy nodes shedding at once don't
  overshoot.
- **Two nodes, one target.** End-to-end test 6 caught two nodes shedding in
  the same second, each moving one of a shop's tunnels to the new node. A
  `GoAway` now names the target node; the connector moves one tunnel at a
  time, and doesn't follow a `GoAway` to a node that holds its other tunnel.
  It dials as usual instead, steering away from it.
- **Drain details.** A node drains only toward another node that takes
  tunnels; alone, it just waits for open streams. A draining node redirects a
  tunnel beside the shop's other one when no third node exists: two on one
  node beat one on a node about to close. A replacement turned away waits the
  `Retry-After` it was given, not the exponential backoff. The stop takes the
  drain timeout plus up to 5 s for the HTTP server.
- **Holding requests.** A node forwarded a request it has no tunnel for
  answers at once with `X-Pointy-Relay-No-Tunnel`, and the forwarding node tries
  the next node, then waits; it is the one that knows every node. Bodies up to
  64 KiB are kept in memory so the request can go again; a larger upload is
  forwarded once.
- **Phase 3 bug fixed.** The connector dialled a replacement tunnel under the
  context of the goroutine watching for moves, and a WebSocket lives as long
  as the context it was dialled with: moving off a shared node closed the new
  tunnel at once, and only the ordinary reconnect put it right. Replacements
  are now dialled under the connector's own lifetime, and one that opens just
  as the old tunnel dies is served instead of leaked.
- **Test speed.** End-to-end test 6 runs rounds every second instead of every
  30 s, on tunnels at least 3 s old instead of 5 minutes, with 300 shops (600
  tunnels). The new node reaches the average ±15% in about 15 s, which is
  about 7¾ minutes at 30 s rounds (the bar is 20 minutes).

**Phase 4 results** (2026-10-15):

- Test 2, two nodes, 60 shops: all 60 tunnels on the drained node moved, none
  left; about 10,500 requests (7,700 during the drain), none failed; 20
  requests taking 1.5 s, in flight when the drain began, all completed.
- Test 6: node-c joined two nodes holding 300 tunnels each and reached the
  average ±15% in about 15.5 s; node-b drained (211 tunnels moved, none left)
  and restarted, and was back within ±15% in about 15.5 s. About 50,000
  requests, none failed; no shop was ever without a tunnel. Three runs, all
  green; also under `-race` with 150 shops.
- Real binaries, two nodes behind NGINX (`nginx:1.29-alpine`, round robin,
  `proxy_next_upstream error`): SIGTERM to a node under requests every 20 ms.
  The node exited 1.3 s later; 373 requests, none failed.

**What phase 3 settled differently from the draft below:**

- A connector numbers its tunnels (1, 2, …) in the Hello frame's stream
  field, which relays before ignored; old connectors send 0 and keep the old
  rule of one session per shop. The number works on TCP too, where there are
  no headers. It only opens a second tunnel once a `HelloAck` asks for it.
- The whoami nonce lives in the node's memory, not Redis: a call that comes
  back with this process's nonce reached this process, which is all the check
  needs.
- A node over its handshake rate now answers `429`, not `503`. `503` is
  placement's "not here", which counts toward the third-try rule; `429` is
  "in a moment" and doesn't. With both as `503`, a herd hitting the limit of
  the node it was redirected to used up its tries and settled beside its
  other tunnel (seen in end-to-end test 3, 4 of 500 shops).
- Only a connector that sends the placement headers is ever redirected; one
  without them is turned away with `503`, which every WebSocket connector
  already waits on.
- When both tunnels end up on one node (it was the only live one), the second
  looks for a node of its own after 2 minutes, then less often (doubling, up to
  30 minutes) while the relay keeps placing it there. It opens the new tunnel
  first and closes the old one once its streams finish; the relay does the same
  with a numbered tunnel replaced by its own reconnect. This is the
  make-before-break that `GoAway` will reuse in phase 4.
- Presence still writes the single key older relays read, so a rolling deploy
  keeps forwarding between old and new nodes. A node drops another's records
  only once it has seen that node leave the registry, never for a node that
  never registered (an older relay mid-deploy).
- Fixed on the way: node-to-node forwarding built a new HTTP transport per
  request and never closed it, leaving an idle connection open on both nodes
  for every forwarded request. It now shares one.
- The end-to-end balancer is a Go reverse proxy over plain HTTP that retries a
  refused connection on the next node, like NGINX's `proxy_next_upstream
  error`; it doesn't end an outer TLS. The tunnel's own mTLS runs as in
  production.

**Correction to the original draft:** the tunnel over HTTPS lives on
`my.dftr.ly`, not `tunnel.dftr.ly`. `tunnel.dftr.ly` is a CNAME to node
11166's TCP endpoint and isn't bound as a custom domain, so a WebSocket to it
would reach one node, if it got a certificate at all. It keeps its job as the
legacy TCP address.

The hosted relay now runs on two JPaaS nodes (11166 at 10.7.4.229 and 12033 at
10.7.4.244, both image 0.8.6). Phone, console and API traffic already spreads
across them. The shop tunnels do not: every connector dials
`tunnel.dftr.ly:11061`, a JPaaS TCP endpoint fixed to node 11166. If that node
dies, every shop drops off the relay, however many other nodes are healthy.

This plan makes the tunnel scale and fail over the way HTTP already does, with
no per-node setup. It also keeps mTLS end to end.

## Goals

- Any node accepts any shop's tunnel. Scaling out or in needs no balancer or
  endpoint edits.
- A node crash causes no visible outage. A deploy or scale-in drops no tunnels
  and no requests.
- The connector's mTLS ends at the relay process. The balancer is never
  trusted with a shop's identity.
- Field shops move over without anyone editing their `.env`.
- Old connectors keep working throughout.

Out of scope: the compat/win8 branch (till app only; the connector ships in the
on-prem bundle built from main), multi-region relays.

## Where we are today

```text
Phone ─HTTPS 443─► shared balancer ─┬─► node 11166 ─┐
                                    └─► node 12033 ─┤  Redis: "shop X is on node N"
                                                    │  forward between nodes over the
                                                    │  private network (shared token)
Shop connector ─raw TCP+mTLS─► node11166-…:11061 ─► node 11166 only
```

What already works and stays:

- **Who holds each tunnel.** `RedisConnectorPresence`
  ([redis_presence.go](relay/internal/relay/redis_presence.go)) keeps one
  record per shop with a TTL. Refresh and close are Lua checks on
  `node_id` + `connection_id`, so a stale node can never overwrite a newer
  tunnel.
- **Forwarding between nodes.** A node without the tunnel forwards the phone
  request to the node that has it (`withNodeProxy` in
  [http_server.go](relay/internal/relay/http_server.go)). The `paas` profile
  sets this up by itself: the shared secret comes from the admin token and each
  node advertises its private IP.
- **Tunnel liveness.** The connector pings every 20 s and drops the tunnel after
  60 s of silence. Zombie streams are cancelled.
- **The protocol inside the tunnel.** Framed and multiplexed over one
  connection ([internal/protocol](relay/internal/protocol)). It doesn't care
  what carries it.

What's missing:

| Gap | Effect |
|---|---|
| Tunnel endpoint fixed to one node | That node is a single point of failure for every shop. |
| One tunnel per shop | Any node loss means a 5–30 s gap while shops reconnect. |
| Reconnect delay has no jitter ([client.go:534](relay/internal/connector/client.go:534)) | Every shop on a dead node reconnects at the same instants. |
| `Draining` is a boot-time setting | Deploys and scale-in drop tunnels and in-flight requests. |
| No wait when a shop is briefly offline | Phone requests fail at once while the shop reconnects. |
| Tunnel address lives only in each shop's `.env` | Moving shops to a new endpoint needs a visit or an update per shop. |

## How others do it

| Product | Design | What we take from it |
|---|---|---|
| Teleport | Agents dial out to a pool of proxies. The backend stores which proxy holds each agent, and proxies forward to each other ("proxy peering"). Teleport recommends 2+ tunnels per agent for high availability. | Our design already matches. Add a second tunnel. |
| Cloudflare Tunnel | Each connector holds 4 outbound connections to at least 2 data centres. | Several tunnels per site, on different servers. |
| ngrok | One outbound TLS session on 443 with heartbeats and automatic reconnect. | Outbound on 443 is the norm. |
| chisel / inlets | Tunnel carried over WebSocket, often behind NGINX. Chisel runs SSH inside the WebSocket and verifies the server key there. | mTLS inside a WebSocket is an established pattern. |

Sources are listed at the end.

## Shared balancer: what we measured

Probed `my.dftr.ly` from one IP on 2026-10-15 (probe script kept in the session
scratchpad; nothing was changed on the platform).

| Question | Result |
|---|---|
| HTTP/1.1 through the balancer (WebSocket needs it) | Yes. ALPN `http/1.1` answers `HTTP/1.1 200`. The balancer also offers HTTP/2 and HTTP/3. |
| Idle timeout on a kept-alive connection | **75 s** (closed by the balancer). Our 20 s ping is well inside it. |
| Concurrent connections from one IP | 20, 49, 60, 80, 150 and 250 all served with `200`. A 50-per-IP cap reported for some Jelastic hosts **does not apply here**, at least up to 250. |
| Stickiness | The balancer sets `UPSTREAMID` and `SRVGROUP` cookies. Ten cookie-less requests all got the same `UPSTREAMID`. That value may identify the environment rather than a node, so it doesn't yet show how new connections are spread. |
| Connection capacity (load test, owner-approved, 2026-10-15) | Idle connections held open from one IP. **1,800: all fine.** At **2,500** every connection still opened and a fresh connection still got `200`, but 70 of 250 sampled held connections had been reset, all among the ~710 opened first. About 1,800 survived. A separate test showed 160 idle connections all surviving 30 s, so the resets come from the count, not from time. |

**Reading the capacity result.** The balancer didn't refuse new connections.
It closed the oldest idle ones to make room. That matches how NGINX behaves when
it runs out of `worker_connections`: it reclaims connections that are waiting
for a request, oldest first. The environment has its **own dedicated NGINX
balancer node** (owner, 2026-10-15), so the limit is most likely that node's
`worker_connections × worker_processes`, a setting we control. The platform's
shared front balancer may also sit in the path if our balancer node has no
public IP, so confirm on the node itself:

- `nginx.conf` on the balancer: `worker_processes` and `worker_connections`. If
  the product is around 2,000, that's the limit we hit.
- The balancer's error log during the test (2026-10-15, about 06:50–07:10 UTC):
  look for `worker_connections are not enough`.

Found on the balancer node (2026-10-15): `worker_processes auto`,
`worker_connections 2048`, `worker_rlimit_nofile 2048`. That is the stock JPaaS
file, and its 2,048 per worker matches where the test started losing
connections. Raise both (Phase 0).

**Rerun after raising the limits (2026-10-15, `worker_connections 16384`,
`worker_rlimit_nofile 65535`):**

| Run | Result |
|---|---|
| Fast (50 TLS handshakes at a time) | 2,500 / 4,000 / 6,000 all clean. At 8,000, 5 new connections and the fresh check connection timed out after 20 s, but no held connection was lost. That points at handshake CPU, not a connection limit. |
| Slow (8 handshakes at a time) | 6,000 / 7,000 / 8,000 all clean. At ~8,900, 133 opens timed out and 56 of 254 sampled held connections were reset, spread across the whole set rather than oldest-first. |

So: about **8,000 concurrent connections** hold today, and a burst of new TLS
handshakes stalls the balancer earlier than that. The failure near 9,000 looks
different from the original one. Spread-out resets fit a balancer worker
dying (out of memory) or a NAT table filling on the test side (one home
connection holding 9,000 sessions). Check the balancer's memory graph, `dmesg`
for OOM kills and the error log around 07:05–07:13 UTC. Either way, the
balancer's CPU and memory now set the ceiling, which is what the handshake
limit (design step 4) and the second balancer node protect against.

Why it matters for tunnels:

- An upgraded WebSocket isn't idle in NGINX's terms, so it can't be reclaimed.
  Once the pool is full, new connections fail instead.
- Each proxied tunnel uses two pool slots (the shop side and the relay side).

**Conclusion:** raise `worker_connections` (and `worker_rlimit_nofile` to at
least twice it) on the balancer. NGINX holds idle WebSocket connections
cheaply, so tens of thousands on one node is ordinary. Then rerun the load test
to confirm the new ceiling. Run **two balancer nodes** for redundancy (see
"Balancer layer" below).

### Balancer layer: scaling and redundancy

- The platform scales any layer horizontally, the balancer included. Automatic
  triggers work per layer on CPU, memory, network or disk averages, checked
  every minute. Confirm the balancer layer appears in the trigger drop-down.
- New balancer nodes are created **stateful**: they clone the first node's
  files, so a customised `nginx.conf` carries over. Edits made *after* scaling
  are not copied, so make every config change on each balancer node (or script
  it).
- JPaaS keeps each balancer's HTTP/WebSocket upstreams in step when the relay
  layer scales, so relay scaling stays hands-off.
- **Recommendation:** two fixed balancer nodes rather than autoscaling them.
  Connection count, not CPU, is what limits a tunnel balancer, and the triggers
  don't measure it. Scaling a balancer in also cuts every tunnel on it. Two
  well-sized nodes give redundancy; autoscaling adds churn without adding
  capacity we need.

Not measurable from outside, so still open:

1. **Does the balancer pass WebSocket upgrades?** Jelastic documents WebSocket
   support on its shared balancer, but we have no endpoint to prove it yet.
   Phase 1 starts with that check.
2. **Whether the connection limit is per customer or for the whole
   balancer.** The load test above found roughly 1,800–2,500 connections
   before eviction, but it can't tell which. Ask LibyanSpider.
3. **Read timeout on an upgraded connection** (NGINX `proxy_read_timeout`,
   default 60 s). The 20 s ping stays inside it, but ask for the value.
4. **How new connections are spread across nodes.** If the balancer hashes by
   client IP, a shop's two tunnels would always land on the same node. Phase 1
   adds an `X-Pointy-Relay-Node` header to `/readyz` so this can be measured.

### Questions for LibyanSpider support

> Our environment env-9493505 (domains my.dftr.ly, shop.dftr.ly, tunnel.dftr.ly)
> will carry long-lived WebSocket connections through the shared load balancer:
> 1. Is there a limit on concurrent connections per environment or per account
>    through the shared load balancer? If so, what is it, and can it be raised?
> 2. Are WebSocket upgrades passed through on 443, and what is the read/idle
>    timeout on an upgraded connection?
> 3. How does the shared balancer pick a node for a new connection: round-robin,
>    least connections, or client-IP hash? Does the `UPSTREAMID` cookie make it
>    sticky?
> 4. When we scale the app layer in, how long does a node get between the stop
>    signal and being killed?

Most of these can now be answered on our own balancer node: its `nginx.conf`
shows the upgrade headers, timeouts and balancing method (to check, not to change). Nothing in the design depends on changing that file. Ask LibyanSpider
only about the platform's front balancer, if traffic passes through it before
reaching ours.

## Design

### 1. Tunnel over WebSocket on 443, mTLS inside

```text
Connector ── wss://my.dftr.ly/v1/connector/tunnel ──► balancer (ends outer TLS)
    │                                                        │
    └──── inner TLS 1.2+, client certificate ───────────────►  any relay node
                                                               (ends inner TLS,
                                                                same handshake as today)
```

- New public route `GET /v1/connector/tunnel`, WebSocket subprotocol
  `pointy-tunnel.v1`, binary messages only.
- The relay wraps the WebSocket as a `net.Conn` (`github.com/coder/websocket`,
  `websocket.NetConn`), runs `tls.Server` over it with the same certificate
  setup as the TCP listener, and hands the result to the existing
  `ConnectorServer.handleConn`. Token check, certificate fingerprint check
  (`validateConnectorCertificate`), presence and the session protocol are all
  reused unchanged.
- The connector does the mirror image: dial the WebSocket, wrap it, run
  `tls.Client` with its client certificate, then the existing Hello exchange.
- Encrypting twice costs little on hardware with AES support. It will be
  measured in the end-to-end test.
- Before the inner handshake the upgrade is anonymous, so it gets the same
  10 s handshake deadline as today plus the handshake limit in step 4.
- The raw TCP listener (8092 and the `11061` endpoint) stays up for old
  connectors and as a fallback.

### 2. Shops learn tunnel addresses from the relay

- The connector accepts an ordered list, `POINTY_RELAY_CONNECTOR_URLS`, for
  example `wss://my.dftr.ly/v1/connector/tunnel,tls://tunnel.dftr.ly:11061`.
  The existing `POINTY_RELAY_CONNECTOR_ADDR` still works and becomes the last
  entry.
- The relay's `HelloAck` gains a JSON payload:
  `{"node_id", "endpoints": [...], "tunnels": 2}`. The connector saves
  `endpoints` to its state directory and dials from that list next time. That
  way the relay moves the fleet onto WebSocket without anyone editing `.env`.
  Old connectors ignore the payload (they only check the frame type), and a
  new connector treats an empty payload as "old relay".
- Dial order: the WebSocket address that last worked first, then the relay's
  list, then the connector's own, TCP last. A failed WebSocket dial falls back
  to TCP in the same attempt. TCP never jumps the queue even when it last
  worked: one WebSocket blip would otherwise pin the shop to the TCP node for
  good. A `503` ends the attempt (wait `Retry-After`) rather than hopping to
  TCP, which would land the refused herd on one node.

### 3. Two tunnels per shop, on different nodes

- The connector keeps `tunnels` connections open (2 by default, taken from the
  `HelloAck`). Each runs its own loop and reconnect timer.
- **Landing on different nodes:** the connector sends its installation id
  with the upgrade request, so the receiving node knows where the shop's other
  tunnel is and places this one on a different node (step 3b). The `HelloAck`
  confirms which node it reached. Both tunnels on one node is accepted only
  when no other node is live.
- **Presence becomes a set.** One Redis key per tunnel,
  `presence:<installation>:<connection_id>`, with a TTL, plus a set
  `presence-index:<installation>` naming the live connections. Refresh and
  close keep their Lua ownership checks. A read prunes index entries whose key
  has expired. (Per-field TTLs on a hash need Redis 7.4; this layout doesn't
  depend on the Redis version.)
- **Hub:** each node's `Hub` holds a list of sessions per shop and picks the one
  with fewest open streams. A new tunnel no longer closes the shop's other
  tunnel on the same node. It replaces it only when it carries the same
  connection id.
- **Routing a phone request:** use a local tunnel if there is one. Otherwise
  forward to a node from the presence set. If that hop can't connect within 2 s,
  try the next node and drop the stale record.
- Spreading requests over two tunnels also eases the existing problem of one
  large export slowing a shop's small requests behind it.

### 3b. The nodes decide where tunnels live

No balancer setting is relied on. The relay nodes coordinate through Redis
and decide among themselves which node holds each tunnel. Any number of nodes
works, and JPaaS autoscaling needs no extra steps.

**Why the balancer can't do this.** Round-robin or least-connections only
chooses a node when a connection opens, and tunnels stay open for days. A node
added by a scale-out gets only new tunnels. A node that restarts comes back
empty while its shops pile onto the others. Customising the balancer's
generated config (`nginx-jelastic.conf`) to do better is fragile.

**Each node has its own public address.** JPaaS gives every app node a
public HTTPS name, `node<node-id>-env-9493505.tip2.libyanspider.cloud` (its own hostname; `docker<node-id>-…` is an alias),
served by the platform's front balancer (openresty, 102.213.182.141/142) with
a valid `*.tip2.libyanspider.cloud` certificate. Checked 2026-10-15:
`docker11166-…` and `docker12034-…` both answer `/readyz`, and each one's
`slb_route` cookie matches the `UPSTREAMID` our own balancer uses for that
node, so the name reaches that node and no other. So nodes can send a shop
straight to a chosen node.

Two entry paths, then:

- **Stable entry** `wss://my.dftr.ly/v1/connector/tunnel`, through our NGINX
  balancer, which round-robins across nodes (20 cookie-less requests split
  10/10 on 2026-10-15). Every shop knows this address. It's the first contact
  and the fallback.
- **Direct node address** `wss://node<id>-env-…/v1/connector/tunnel`, which
  the nodes hand out from the registry. Platform-generated and changes with
  every scale event, so it's never stored in a shop's `.env`. It's only used
  as a pointer the relay gives out at that moment.

#### Node registry

- Every node writes `node:<node_id>` to Redis every 5 s with a 15 s TTL:
  `{tunnels, draining, started_at, public_tunnel_url}`. The live nodes are
  exactly the keys that exist.
- **Learning its own public address, verified.** The container hostname is the
  JPaaS node name. Checked 2026-10-15: `hostname` prints
  `node12034-env-9493505.tip2.libyanspider.cloud` on node 12034 and
  `node11166-env-9493505.tip2.libyanspider.cloud` on node 11166. The
  hostname is itself a public HTTPS name that reaches that node through the
  front balancer (checked 2026-10-15: `node11166-…` and `node12034-…` return
  `/readyz` 200 with the same `slb_route` as their `docker<id>-…` aliases), so
  the node advertises `https://<hostname>` as is, with no rewriting. Reverse
  DNS of the private IP is the second source, and
  `POINTY_RELAY_NODE_PUBLIC_URL_TEMPLATE` (with `{hostname}`) overrides
  both. Before advertising the address, the node calls
  `GET <address>/v1/node/whoami` and checks that the answer is a random nonce
  it put in Redis for itself, then repeats the check every few minutes. If the
  check fails (a different scheme, or the front balancer not wired up yet for
  a new node), the node advertises no address, and steering falls back to
  turning tunnels away (below). The startup log names the source used and the
  address advertised, next to `node_internal_url`.
- **A node that dies** (crash, OOM, or JPaaS removing it) stops writing, and
  its key expires within 15 s. The other nodes then:
  - drop it from the fleet average;
  - delete the presence records that point at it, so phone requests stop being
    forwarded to a dead address;
  - expect its shops back. The shops' connectors notice the dead tunnel
    themselves (connection reset, or 30 s without a ping) and redial through
    the balancer, which JPaaS has already updated. The relay never needs to
    reach out to a shop.
- **A new node** (JPaaS scale-out) registers on start. The average drops, the
  heavier nodes start handing tunnels over (below), and the new node fills up.
- **A node told to stop** (deploy, JPaaS scale-in) marks itself `draining` and
  runs the graceful drain in step 5.

#### Placement: the receiving node chooses where the tunnel goes

When a tunnel arrives, by either path, the node checks the registry before the
inner TLS handshake, so the decision is cheap:

1. **Stay** if this node is among the lightest: its count is at most
   lightest + max(5, 5% of the average). Accept.
2. **Redirect** otherwise: answer the upgrade with
   `409 {"connect": "wss://node<id>-…/v1/connector/tunnel"}`, naming the
   lightest live node that has a verified address and isn't draining. (When
   two tunnels of the same shop are involved, that also means a node other
   than the one holding the shop's other tunnel.) The connector dials that
   address at once.
3. **Turn away** if the lighter nodes have no verified address: `503` +
   `Retry-After: 1` (jittered). The connector redials the stable entry, and
   the round-robin balancer lands it elsewhere.

**Never stuck:**
- A redirect is followed at most once. A connection that arrives on a direct
  address, or carries `X-Pointy-Tunnel-Attempt` ≥ 3, is always accepted
  (unless that node is draining).
- If a redirect target can't be reached, the connector goes back to the stable
  entry with the attempt count raised.
- If Redis can't be read, or the registry is older than 15 s, the node
  accepts. Spreading is a preference, never a reason to keep a shop out.
- A draining node never accepts. It redirects or turns away.

**Lighter work for our balancer.** Once a shop has been redirected, its tunnel
runs through the platform's front balancer, not ours. Our NGINX then only
carries phone traffic and first contacts. The front balancer is shared with
LibyanSpider's other customers and its limits are unknown, so its capacity
must be confirmed with LibyanSpider. **Don't load-test it**: that would hit
other customers. If it turns out to be limited, turn the redirect off with one
setting (`POINTY_RELAY_TUNNEL_REDIRECT=false`), and steering falls back to
turning tunnels away through our own balancer.

#### Rebalancing: heavy nodes hand tunnels over

Placement alone can't empty a node that is already overfull, for example after
a scale-out or when a node returns from a restart. So every 30 s each node
compares itself with the average. Above **average × 1.20** (and at least 5
over), it moves some of its tunnels:

- **Make-before-break:** it sends `GoAway{reason: "rebalance", connect: <lightest node's address>}`.
  The connector opens the replacement there first.
  The old tunnel closes once the new one is up and the old one has no open
  streams.
- **The shop stays reachable:** a node only moves a tunnel whose shop has its
  other tunnel on a different node.
- **Gently:** at most 2% of the node's tunnels per round (and no more than 20),
  idle ones first, none opened in the last 5 minutes.
- **No ping-pong:** a node only sheds above 1.20× the average, while it sends
  new tunnels to the lightest node, so a moved tunnel doesn't bounce straight
  back.
- **Expected:** after a scale-out, the new node reaches the average within
  roughly 10–20 minutes, without a reconnect storm.
- Old connectors (no `GoAway`) are never moved. They spread out as shops update.

#### What JPaaS autoscaling looks like end to end

| Event | What happens, automatically |
|---|---|
| Scale-out (new node) | It registers and verifies its public address; new tunnels are redirected to it; heavy nodes shed toward it until even. |
| Scale-in / deploy (SIGTERM) | The node marks itself draining, tells its connectors to move, waits for in-flight requests, and exits. Placement sends new tunnels elsewhere. |
| Crash (no warning) | Its key expires in ≤ 15 s; peers clean its presence records; its shops' other tunnels keep serving; replacements are redirected to the lightest nodes. |
| Node comes back | It registers empty and fills up through placement and rebalancing. |

**What counts as load.** The tunnel count, to begin with. If the figures later
show a few shops making most of the requests, weight each tunnel by its recent
request rate. The rule stays the same; only the number changes.

**Already confirmed (2026-10-15):** our balancer spreads cookie-less
connections round-robin, not by client IP (10/10 across the two nodes), and
the per-node names reach their own node. Still open for phase 1: whether the
front balancer passes WebSocket upgrades on the per-node names, its idle
timeout, and its connection limits (ask LibyanSpider).

### 4. Calm reconnects

- Reconnect delay: exponential, capped, then randomised to 50–100% of the value.
- Exactly one pending reconnect per tunnel. All failure paths go through one
  scheduler.
- **Handshake limit on each node:** a token bucket on tunnel handshakes (for
  example 50/s with a burst of 100). Over the limit, the node answers
  `503` + `Retry-After` and the connector waits that long, plus jitter. A
  restarted node then isn't flooded by every shop at once.
- Dead-tunnel detection tightens from 60 s of silence to 30 s, checked every
  10 s. The ping stays at 20 s. The protocol has no flow control, so on a slow
  uplink a long response can hold the relay's pong back past 30 s; the
  connector's own data frames finishing their writes count as a sign of life
  too (a write only finishes once the relay is acknowledging).

### 5. Graceful drain

On SIGTERM a node:

1. turns `/readyz` to 503 and refuses new tunnels with `503`, so they land on
   another node;
2. sends `FrameGoAway` on each tunnel to connectors that announced support for
   it (a capabilities frame the new connector sends right after `HelloAck`).
   On `GoAway` the connector dials a replacement tunnel at once, and closes the
   old one once the replacement is up or the old one has no open streams;
3. waits for in-flight streams to finish, up to a deadline set below the
   platform's kill grace period (question 4 above);
4. closes the rest and exits.

Old connectors don't get `GoAway`. An unknown frame type ends their session
(`UnexpectedFrameError`), so they are simply closed at step 4 and reconnect
under their own backoff.

### 6. Hold requests while a shop reconnects

When a phone request finds no live tunnel, or every recorded node fails, the
relay waits for one to appear: it polls presence every 250 ms for up to 8 s,
then answers `503` (the existing "shop offline" response).

The relay retries a request only when it is certain the request never reached
the shop: the stream couldn't open, or the hop to the other node couldn't
connect. Once any request bytes have gone into a tunnel, it never retries, for
every method. The phone app already retries reads and keyed writes itself.

### 7. Redis stops being a single point of failure

Every node serves its own tunnels without Redis, so a Redis outage only breaks
forwarding between nodes. Run Redis with a replica (JPaaS can cluster Redis),
or move to a managed one. This is a platform task.

### 8. Visibility

- Per node: open tunnels, the fleet average and each node's share, tunnels moved by rebalancing, new tunnels refused because the node was busy, tunnels by transport (WebSocket or TCP), handshakes
  refused by the limit, requests forwarded to another node, requests that
  waited for a reconnect and how long, requests answered 503 after the wait.
- `X-Pointy-Relay-Node` header on `/readyz` (the node id, nothing sensitive), to
  check how the balancer spreads connections.
- The operator CLI's `installations status` shows each tunnel's node and
  transport.

## Tests

- **Unit:** jitter range; one pending reconnect per tunnel; the presence set
  (add, refresh, close, expiry pruning, stale-node ownership); hub choice by
  open streams; placement (stay / redirect / turn away, attempt cap, Redis-down accept), address self-check, shedding threshold; tunnels redialled when they land on the same node; retry only
  before any bytes were sent.
- **End-to-end (`relay/internal/e2e`):** two relay nodes behind an NGINX that
  ends the outer TLS, Redis, and several connectors:
  1. Kill one node under steady phone traffic. Assert no request fails beyond
     the hold window, and every shop is back to two tunnels within 30 s.
  2. Gracefully drain one node under traffic. Assert zero failed requests.
  3. Restart a node holding 500 tunnels. Assert the handshake limit holds and
     every tunnel is back within the backoff cap.
  4. An old connector (TCP, no `GoAway`) next to new ones throughout.
  5. Throughput and latency of WebSocket+inner TLS against raw TCP, including
     a large export running beside small requests.
  6. Scale from 2 to 3 nodes with 600 tunnels. Assert the new node reaches the
     average ±15% within 20 minutes, no shop ever has zero live tunnels, and no
     request fails. Then restart one node and assert the same recovery.
- Backend tests stay on Postgres (`make backend-test-pg`) for the shop-side
  settings change.

## Rollout

| Phase | What ships | Done when |
|---|---|---|
| 0 | Raise `worker_connections` / `worker_rlimit_nofile` on the balancer and add a second balancer node. Rerun the load test. Ask LibyanSpider the remaining questions. | The load test holds 10,000 idle connections with none reset. |
| 1 | Relay: WebSocket route, `/readyz` node header, handshake limit. Deploy. Probe upgrades and spreading through the balancer. | A test connector holds a tunnel over 443 through the real balancer for 24 h, and new connections land on both nodes. |
| 2 | Connector: URL list, WebSocket dial with fallback, jitter, single scheduler, saved endpoints from `HelloAck`. On-prem release. | Shops that updated show tunnels over WebSocket on both nodes. |
| 3 | Two tunnels per shop, presence set, hub choice, forwarding retry. Node registry in Redis with verified public addresses, dead-node cleanup, placement with redirects. | End-to-end tests 1, 3, 4 and 5 pass. |
| 4 | Graceful drain with `GoAway`; hold requests while reconnecting; rebalancing. | End-to-end tests 2 and 6 pass. A real deploy shows no failed requests. |
| 5 | Redis with a replica. | A Redis failover causes no lost tunnels. |
| Later | Once the legacy TCP listener has had no traffic for 30 days, retire the `11061` endpoint. Keep the old `env-9493505` host bound forever (field clients and printed links use it). | — |

Each phase works with the one before it: a new relay with old connectors, and
a new connector with an old relay (empty `HelloAck`, so it stays on its saved
or configured address).

## Sources

- [Cloudflare Tunnel availability and failover](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/run-tunnel/deploy-cloudflared-replicas/)
- [Teleport proxy peering](https://goteleport.com/docs/zero-trust-access/management/proxy-peering/)
- [ngrok agent: how it works](https://ngrok.com/docs/gateway/agent/how-it-works)
- [chisel overview](https://www.linuxlinks.com/chisel-fast-tcp-udp-tunnel/)
- [WebSocket support on Jelastic-based platforms (AccuWeb)](https://accuweb.cloud/resource/articles/websockets-support)
- [Shared vs dedicated load balancer (StackHarbor)](https://stackharbor.com/en/knowledge-base/paas-net-shared-vs-dedicated-lb/)
- [Per-IP limit on shared load balancers (AccuWeb FAQ)](https://accuweb.cloud/resource/wp-json/wp/v2/faq/41157)
- [WebSocket reconnection guide](https://websocket.org/guides/reconnection/)
- [Reconnect backoff and jitter (eSeGeCe)](https://www.esegece.com/community/blog/sgcwebsockets-reconnect-retry-backoff/)
