# syntax=docker/dockerfile:1

FROM golang:1.25-alpine AS build

WORKDIR /src/relay

COPY relay/go.mod relay/go.sum ./
RUN go mod download

COPY relay/ ./
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w" \
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

ENTRYPOINT ["/usr/local/bin/pointy-relay"]
CMD ["help"]
