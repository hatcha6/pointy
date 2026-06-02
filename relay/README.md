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

For production connector mTLS, provide the relay CA and connector client cert:

```sh
POINTY_RELAY_TLS_CA=/etc/pointy/relay-ca.crt \
POINTY_RELAY_TLS_CERT=/etc/pointy/connector.crt \
POINTY_RELAY_TLS_KEY=/etc/pointy/connector.key \
POINTY_RELAY_TLS_SERVER_NAME=relay.example.com \
POINTY_RELAY_CONNECTOR_SETUP_TOKEN=connector-setup-secret \
go run ./cmd/pointy-relay connector
```

The backend discovery response contains only non-secret metadata. Connector
bootstrap still requires `POINTY_RELAY_CONNECTOR_SETUP_TOKEN`, and the connector
sends a heartbeat to the backend so Django can report whether the local tunnel
was seen recently.

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

Route a remote request with a short-lived relay ticket:

```sh
curl \
  -H 'X-Pointy-Relay-Token: ptt1.<installation-id>.<secret>' \
  http://127.0.0.1:8091/api/shop-settings/
```

The relay also accepts `/r/<relay-ticket>/api/...` for clients that cannot send
custom headers, but only for `ptt1...` ticket tokens. Long-lived `ptr1...`
access tokens are rejected in URL paths and should remain server-side.

## State

The relay uses PostgreSQL for durable installation state. Run
`pointy-relay migrate` before provisioning or starting a fresh server. The
PostgreSQL store keeps token hashes, shop names, subscription state, AI
entitlement state, and connector heartbeat metadata.

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
connector token should stay only on the on-prem server. Long-lived access
tokens should stay in backend-controlled storage. Mobile devices should ask the
Pointy backend for pairing; the backend exchanges its access token for a
short-lived per-device relay ticket and returns only that ticket to the phone.

## Tests

```sh
go test ./...
go vet ./...
```

The integration tests run without binding local ports; they use in-memory
protocol sessions to verify relay, connector, subscription, and HTTP behavior.
