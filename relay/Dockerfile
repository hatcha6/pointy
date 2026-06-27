# syntax=docker/dockerfile:1

FROM golang:1.25-alpine AS build

# Build version, injected into the binary so the connector heartbeat + `version`
# command report the real release. Defaults to "dev" for local builds.
ARG POINTY_VERSION=dev

WORKDIR /src/relay

COPY relay/go.mod relay/go.sum ./
RUN go mod download

COPY relay/ ./
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w -X main.version=${POINTY_VERSION}" \
    -o /out/pointy-relay \
    ./cmd/pointy-relay

FROM alpine:3.22 AS certs

RUN apk add --no-cache ca-certificates tzdata \
    && mkdir -p /var/lib/pointy \
    && chown -R 65532:65532 /var/lib/pointy

FROM scratch AS runtime

COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=certs /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=certs --chown=65532:65532 /var/lib/pointy /var/lib/pointy
COPY --from=build /out/pointy-relay /usr/local/bin/pointy-relay

USER 65532:65532
WORKDIR /var/lib/pointy

# 8091: public HTTP (phones, relay, admin) — put the platform TLS terminator in
# front. 8092: on-prem connector tunnel (raw TCP + mTLS) — needs L4 passthrough.
EXPOSE 8091 8092

ENTRYPOINT ["/usr/local/bin/pointy-relay"]
# Defaults to the relay server for hosted deployments. Override the command for
# one-off tasks, e.g. `docker run … pointy-relay gen-token`.
CMD ["server"]
