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
access token, active relay entitlement, and online connector. The on-prem
backend still owns Pointy login, sessions, CSRF, roles, permissions, and audit.

## Commands

Apply PostgreSQL migrations:

```sh
POINTY_RELAY_DATABASE_URL='postgres://postgres:postgres@127.0.0.1:5432/pointy?sslmode=disable' \
go run ./cmd/pointy-relay migrate
```

Provision an installation:

```sh
POINTY_RELAY_DATABASE_URL='postgres://postgres:postgres@127.0.0.1:5432/pointy?sslmode=disable' \
go run ./cmd/pointy-relay provision
```

Run the relay:

```sh
POINTY_RELAY_ADMIN_TOKEN=local-admin \
POINTY_RELAY_DATABASE_URL='postgres://postgres:postgres@127.0.0.1:5432/pointy?sslmode=disable' \
POINTY_RELAY_REDIS_URL='redis://127.0.0.1:6379/0' \
go run ./cmd/pointy-relay server
```

Run an on-prem connector beside Django:

```sh
POINTY_RELAY_CONNECTOR_TOKEN='ptc1.<installation-id>.<secret>' \
go run ./cmd/pointy-relay connector --backend http://127.0.0.1:8000
```

Route a remote request:

```sh
curl \
  -H 'X-Pointy-Relay-Token: ptr1.<installation-id>.<secret>' \
  http://127.0.0.1:8091/api/shop-settings/
```

Issue a short-lived per-device relay ticket:

```sh
curl \
  -X POST \
  -H 'X-Pointy-Relay-Token: ptr1.<installation-id>.<secret>' \
  -H 'Content-Type: application/json' \
  -d '{"device_id":"register-1","device_name":"front register"}' \
  http://127.0.0.1:8091/v1/relay-tickets
```

## State

The relay uses PostgreSQL for durable installation state. Run
`pointy-relay migrate` before provisioning or starting a fresh server. The
PostgreSQL store keeps token hashes, subscription state, AI entitlement state,
and connector heartbeat metadata.

Redis is used as an operational layer for:

- hot installation cache entries for token validation,
- connector presence with TTL refreshes,
- relay-node ownership hints for connected installations,
- short-lived per-device relay tickets,
- future rate limits.

Do not put live request bodies or tunnel bytes in Redis.

## Tokens

Tokens include the installation id:

```text
ptc1.<installation-id>.<secret>  connector token
ptr1.<installation-id>.<secret>  remote access token
ptt1.<installation-id>.<secret>  short-lived relay ticket
```

The installation id lets the relay route directly to the right connector
without asking all connected installations where a phone wants to go. The
connector token should stay only on the on-prem server. Mobile devices should
exchange access tokens for short-lived per-device relay tickets and use the
ticket for normal remote API traffic.

## Tests

```sh
go test ./...
go vet ./...
```

The integration tests run without binding local ports; they use in-memory
protocol sessions to verify relay, connector, subscription, and HTTP behavior.
