# Pointy Relay

Standalone relay server and on-prem connector for remote Pointy access.

## Shape

```text
mobile/client
  -> Pointy Relay HTTP listener
  -> multiplexed stream on the on-prem connector tunnel
  -> local Pointy Django backend
```

The relay only decides whether a request may reach an installation: valid
ticket/access credential, active relay entitlement, active subscription, and
online connector. The on-prem backend still owns Pointy login, sessions, CSRF,
roles, permissions, and audit.

## Commands

Apply PostgreSQL migrations:

```sh
POINTY_RELAY_DATABASE_URL='postgres://postgres:postgres@127.0.0.1:5432/pointy?sslmode=disable' \
go run ./cmd/pointy-relay migrate
```

For local development, run the relay with explicit insecure listener flags:

```sh
POINTY_RELAY_ADMIN_TOKEN=local-admin \
POINTY_RELAY_DATABASE_URL='postgres://postgres:postgres@127.0.0.1:5432/pointy?sslmode=disable' \
POINTY_RELAY_REDIS_URL='redis://127.0.0.1:6379/0' \
POINTY_RELAY_TICKET_REFRESH_TTL=168h \
POINTY_RELAY_MAX_REQUEST_BODY_BYTES=10485760 \
POINTY_RELAY_MAX_RESPONSE_BODY_BYTES=52428800 \
POINTY_RELAY_MAX_CONCURRENT_REQUESTS=512 \
POINTY_RELAY_ALLOW_INSECURE_HTTP=true \
POINTY_RELAY_ALLOW_INSECURE_CONNECTOR=true \
go run ./cmd/pointy-relay server
```

In production, omit the insecure flags and provide TLS material:

```sh
POINTY_RELAY_ADMIN_TOKEN=local-admin \
POINTY_RELAY_DATABASE_URL='postgres://postgres:postgres@127.0.0.1:5432/pointy?sslmode=disable' \
POINTY_RELAY_REDIS_URL='redis://127.0.0.1:6379/0' \
POINTY_RELAY_HTTP_TLS_CERT=/etc/pointy/relay-http.crt \
POINTY_RELAY_HTTP_TLS_KEY=/etc/pointy/relay-http.key \
POINTY_RELAY_CONNECTOR_TLS_CERT=/etc/pointy/relay-connector.crt \
POINTY_RELAY_CONNECTOR_TLS_KEY=/etc/pointy/relay-connector.key \
POINTY_RELAY_CONNECTOR_CLIENT_CA=/etc/pointy/connector-ca.crt \
POINTY_RELAY_CONNECTOR_CLIENT_CA_KEY=/etc/pointy/connector-ca.key \
POINTY_RELAY_REQUIRE_ADMIN_CLIENT_CERT=true \
POINTY_RELAY_HTTP_CLIENT_CA=/etc/pointy/backend-ca.crt \
go run ./cmd/pointy-relay server
```

The connector can bootstrap from the local Django backend instead of receiving
a token on the command line. When `--backend` is omitted, it probes localhost
and then uses Pointy LAN discovery to find the backend automatically:

```sh
POINTY_RELAY_ALLOW_INSECURE_CONNECTOR=true \
POINTY_RELAY_CONNECTOR_SETUP_TOKEN=local-connector-setup \
go run ./cmd/pointy-relay connector
```

For production connector mTLS, provide the relay CA and a one-time setup token.
The connector generates its private key locally, sends a CSR to the backend,
receives the issued client certificate, and persists the resulting state:

```sh
POINTY_RELAY_TLS_CA=/etc/pointy/relay-ca.crt \
POINTY_RELAY_TLS_SERVER_NAME=relay.example.com \
POINTY_RELAY_CONNECTOR_SETUP_TOKEN=connector-setup-secret \
POINTY_RELAY_CONNECTOR_REQUEST_TIMEOUT=30s \
POINTY_RELAY_CONNECTOR_MAX_CONCURRENT_REQUESTS=64 \
POINTY_RELAY_CONNECTOR_STATE_FILE=/var/lib/pointy/relay-connector.json \
go run ./cmd/pointy-relay connector
```

The backend discovery response contains only non-secret metadata. Connector
bootstrap still requires `POINTY_RELAY_CONNECTOR_SETUP_TOKEN`, but the backend
consumes that token once. After bootstrap, the connector reuses its state file
and sends heartbeats authenticated with the connector token so Django can report
whether the local tunnel was seen recently.

Manual provisioning still exists for local/admin testing. New installations
default to remote access disabled and subscription inactive unless these flags
are explicitly set:

```sh
POINTY_RELAY_DATABASE_URL='postgres://postgres:postgres@127.0.0.1:5432/pointy?sslmode=disable' \
go run ./cmd/pointy-relay provision \
  --shop-name 'متجر الاختبار' \
  --relay-enabled \
  --subscription-active
```

## Company Admin

Relay subscription and entitlement changes are company-owned cloud operations,
not Pointy customer-app settings. Do not add these controls to the Flutter POS
or the on-prem Django admin UI.

The relay exposes admin APIs and a small `/admin` console from the Go relay
service. They are protected by the normal relay admin bearer token and, in
production, should also sit behind company SSO/reverse-proxy controls and admin
client certificates:

```sh
curl \
  -X PATCH \
  -H 'Authorization: Bearer <admin-token>' \
  -H 'Content-Type: application/json' \
  -d '{
    "relay_enabled": true,
    "subscription_active": true,
    "subscription_ends_at": "2026-12-31T23:59:59Z",
    "actor": "ops@example.com",
    "reason": "paid annual subscription"
  }' \
  http://127.0.0.1:8091/v1/installations/<installation-id>/subscription
```

The same path is available through the operator CLI:

```sh
POINTY_RELAY_ADMIN_TOKEN=local-admin \
go run ./cmd/pointy-relay subscription update \
  --allow-insecure-control=true \
  --installation-id '<installation-id>' \
  --actor 'ops@example.com' \
  --reason 'paid annual subscription' \
  --relay-enabled=true \
  --subscription-active=true \
  --subscription-ends-at '2026-12-31T23:59:59Z'
```

Every subscription update requires an actor and reason and writes a relay admin
audit event with before/after subscription state. Audit state deliberately
excludes connector token hashes, access token hashes, bearer tokens, and
certificate PEM. Read recent relay-admin audit events with:

```sh
curl \
  -H 'Authorization: Bearer <admin-token>' \
  http://127.0.0.1:8091/v1/installations/<installation-id>/audit-events
```

Customer backends learn about these cloud-side changes through their existing
relay sync path. Remote access remains disabled/not subscribed by default until
this relay-admin workflow changes it.

Route a remote request with a short-lived relay ticket:

```sh
curl \
  -H 'X-Pointy-Relay-Token: ptt1.<installation-id>.<secret>' \
  http://127.0.0.1:8091/api/shop-settings/
```

The relay also accepts `/r/<relay-ticket>/api/...` for clients that cannot send
custom headers, but only for `ptt1...` ticket tokens. Long-lived `ptr1...`
access tokens and `ptrf1...` refresh tokens are rejected in URL paths and
should remain outside request URLs.

Refresh an already-paired device ticket when LAN is unavailable:

```sh
curl \
  -X POST \
  -H 'X-Pointy-Relay-Refresh-Token: ptrf1.<installation-id>.<secret>' \
  -H 'Content-Type: application/json' \
  -d '{"device_id":"phone-1"}' \
  http://127.0.0.1:8091/v1/relay-ticket-refresh
```

Refresh tokens are issued only as part of authenticated LAN pairing through the
backend. They are stored hash-only in Redis, consumed atomically on refresh, and
rotated with the newly issued `ptt1...` relay ticket. The relay rechecks the
installation's relay entitlement and subscription before every refresh. If a
device's refresh token expires while LAN is unavailable, it cannot remotely
pair again; it must return to LAN pairing.

## State

The relay uses PostgreSQL for durable installation state. Run
`pointy-relay migrate` before provisioning or starting a fresh server. The
PostgreSQL store keeps token hashes, shop names, subscription state, AI
entitlement state, connector certificate binding metadata, and connector
heartbeat metadata.

Redis is used as an operational layer for:

- hot installation cache entries for token validation,
- connector presence with TTL refreshes,
- relay-node ownership hints for connected installations,
- short-lived per-device relay tickets,
- rotating per-device refresh tokens for already-paired phones,
- distributed rate-limit counters.

Do not put live request bodies or tunnel bytes in Redis.

## Multi-Node Routing

When the relay runs behind a load balancer, phones can hit a different relay
node than the one holding the connector TCP session. Redis presence records the
connector's owning node. To route those requests instead of returning offline,
configure each relay node with:

- `POINTY_RELAY_NODE_ID`: stable unique node id.
- `POINTY_RELAY_NODE_INTERNAL_URL`: direct HTTPS URL other relay nodes can
  reach for this node.
- `POINTY_RELAY_NODE_PROXY_TOKEN`: shared high-entropy secret required on
  node-to-node relay requests.

The internal URL must be HTTPS unless `POINTY_RELAY_ALLOW_INSECURE_NODE_PROXY`
is enabled for local development. Keep this URL on a private network and rotate
the node proxy token through the deployment secret manager. Node proxy headers
are stripped before requests reach the on-prem backend.

To drain a node for deployment or maintenance, set `POINTY_RELAY_DRAINING=true`.
The node keeps `/healthz` healthy, returns `503` from `/readyz`, reports the
drain state in `/v1/status`, and rejects new connector handshakes so connectors
can reconnect to another relay node. Existing sessions remain bounded by the
normal relay and connector request timeouts.

## Operational Limits

The relay server applies bounded defaults to the remote HTTP path:

- `POINTY_RELAY_STREAM_OPEN_TIMEOUT` defaults to `5s`.
- `POINTY_RELAY_REQUEST_TIMEOUT` defaults to `60s`.
- `POINTY_RELAY_MAX_REQUEST_BODY_BYTES` defaults to `10485760`.
- `POINTY_RELAY_MAX_RESPONSE_BODY_BYTES` defaults to `52428800`.
- `POINTY_RELAY_MAX_CONCURRENT_REQUESTS` defaults to `512`.
- `POINTY_RELAY_RATE_LIMIT_WINDOW` defaults to `1m`.
- `POINTY_RELAY_RATE_LIMIT_RELAY_REQUESTS` defaults to `600` per installation/window.
- `POINTY_RELAY_RATE_LIMIT_TICKET_ISSUE` defaults to `60` per installation/device/window.
- `POINTY_RELAY_RATE_LIMIT_TICKET_REFRESH` defaults to `120` per refresh token/window.

The connector applies its own backend-forwarding guardrails:

- `POINTY_RELAY_CONNECTOR_REQUEST_TIMEOUT` defaults to `30s`.
- `POINTY_RELAY_CONNECTOR_MAX_CONCURRENT_REQUESTS` defaults to `64`.

Set a byte, concurrency, or rate limit to `0` only for controlled testing.
Production deployments should keep explicit limits so slow clients, oversized
uploads, stuck backend requests, and runaway clients cannot consume unbounded
relay or connector resources. Redis must be configured for these rate limits to
apply consistently across multiple relay nodes.

## Observability

Admin-support endpoints are protected by the normal relay admin token and, when
enabled, the admin client certificate requirement:

```sh
curl \
  -H 'Authorization: Bearer <admin-token>' \
  http://127.0.0.1:8091/v1/status

curl \
  -H 'Authorization: Bearer <admin-token>' \
  http://127.0.0.1:8091/v1/installations/<installation-id>/status
```

`/v1/status` includes the relay node id, configured guardrails, and aggregate
metrics for active connectors, relay request counts and latency, ticket
issuance, refreshes, offline installations, subscription rejections, backend
failures, credential rejections, body/concurrency-limit rejections, and
rate-limit rejections/failures.

`/v1/installations/<id>/status` is intended for support diagnostics. It returns
shop name, relay/subscription state, local connector state, Redis presence, last
connector heartbeat time, and connector certificate expiry metadata. It does
not include connector/access token hashes or bearer credentials.

## Tokens

Tokens include the installation id:

```text
ptc1.<installation-id>.<secret>  connector token
ptr1.<installation-id>.<secret>  remote access token
ptt1.<installation-id>.<secret>  short-lived relay ticket
ptrf1.<installation-id>.<secret> rotating relay ticket refresh token
```

The installation id lets the relay route directly to the right connector
without asking all connected installations where a phone wants to go. The
connector token should stay only on the on-prem server. Long-lived access
tokens should stay in backend-controlled storage. Mobile devices should ask the
Pointy backend for pairing; the backend exchanges its access token for a
short-lived per-device relay ticket plus a rotating refresh token and returns
only those per-device credentials to the phone. Phones refresh tickets by
repeating authenticated LAN pairing when LAN is available. If LAN is unavailable
after first pairing, phones may call `/v1/relay-ticket-refresh` with the
rotating refresh token. Remote first-time pairing remains blocked.

## Tests

```sh
go test ./...
go vet ./...
```

The integration tests run without binding local ports; they use in-memory
protocol sessions to verify relay, connector, subscription, and HTTP behavior.

Production E2E is opt-in because it requires reachable PostgreSQL and Redis.
It applies relay migrations, uses PostgreSQL for installation/admin-audit state,
uses Redis for cache, presence, tickets, refresh tokens, and rate limits, then
exercises a two-node relay path where a phone request enters node A and routes
to the connector on node B:

```sh
make postgres redis
make relay-production-test
```

Override the service URLs when needed:

```sh
make relay-production-test \
  RELAY_E2E_DATABASE_URL='postgres://postgres:postgres@127.0.0.1:5432/pointy?sslmode=disable' \
  RELAY_E2E_REDIS_URL='redis://127.0.0.1:6379/0'
```
