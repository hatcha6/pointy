# syntax=docker/dockerfile:1
#
# Builds the Flutter web bundle and serves it from nginx, reverse-proxying the
# backend API on the same origin. Self-contained (no host Flutter needed), so
# `docker compose build web` works locally and in CI alike.
#
# FLUTTER_VERSION is pinned to the repo's toolchain and overridden by the release
# workflow from its single source of truth (the workflow `env`).

ARG FLUTTER_VERSION=3.38.6

FROM debian:bookworm-slim AS build
ARG FLUTTER_VERSION
ENV DEBIAN_FRONTEND=noninteractive \
    CI=true \
    PATH="/opt/flutter/bin:${PATH}"

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" -o /tmp/flutter.tar.xz; \
    tar -xJf /tmp/flutter.tar.xz -C /opt; \
    rm /tmp/flutter.tar.xz; \
    git config --global --add safe.directory /opt/flutter; \
    flutter --version; \
    flutter precache --web

WORKDIR /app
COPY frontend ./
RUN flutter pub get && flutter build web --release

FROM nginx:alpine AS runtime
RUN rm -f /etc/nginx/conf.d/default.conf
COPY deploy/onprem/web/nginx.conf /etc/nginx/conf.d/pointy.conf
COPY --from=build /app/build/web /usr/share/nginx/html
EXPOSE 80
