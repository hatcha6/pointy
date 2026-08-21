#!/usr/bin/env bash
#
# Build the Pointy WSL distro image (CI).
#
#   bash deploy/onprem/wsl/build-rootfs.sh [output.tar.gz]
#
# Produces a root-filesystem tarball that `wsl --import` consumes, with Docker
# Engine, Compose v2 and every dependency the deploy scripts need already
# installed — so the shop's install needs no internet at all.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-${HERE}/pointy-wsl-rootfs.tar.gz}"
IMAGE="pointy-wsl-rootfs:build"

echo "==> Building ${IMAGE}…"
# linux/amd64 explicitly: WSL2 on the shop PCs is x64, and a CI runner on arm64
# would otherwise produce a rootfs that cannot execute a single binary.
docker build --platform linux/amd64 -t "${IMAGE}" "${HERE}/rootfs"

echo "==> Exporting the root filesystem…"
cid="$(docker create --platform linux/amd64 "${IMAGE}")"
trap 'docker rm -f "${cid}" >/dev/null 2>&1 || true' EXIT

# `docker export` writes the flattened filesystem — precisely wsl --import's
# input format. Piping straight into gzip avoids staging a ~1.5 GB tar.
docker export "${cid}" | gzip -9 > "${OUT}"

echo "==> ${OUT}"
ls -lh "${OUT}" | awk '{print "    size: " $5}'
sha256sum "${OUT}" 2>/dev/null || shasum -a 256 "${OUT}"
