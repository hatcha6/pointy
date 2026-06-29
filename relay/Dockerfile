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

FROM alpine:3.22 AS runtime

# A minimal real OS userland, NOT `FROM scratch`: the Jelastic/Virtuozzo Docker
# engine inspects the image to pick an OS template ("jem docker getpcstemplate")
# and rejects images it can't identify — scratch has no /etc/os-release or
# shell, so detection fails ("OS template cannot be detected"). Alpine is
# detected fine and costs ~8 MB. The relay binary is static (CGO_ENABLED=0), so
# Alpine only serves to satisfy the platform and ship CA roots + tzdata; there
# is no libc dependency.
RUN apk add --no-cache ca-certificates tzdata \
    && adduser -D -H -u 65532 pointy \
    && mkdir -p /var/lib/pointy \
    && chown -R 65532:65532 /var/lib/pointy

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
