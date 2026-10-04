#!/bin/bash
# Turns a plain ubuntu:24.04 container into the Linux rig (see boot.sh): the
# Makefile runs this and `docker commit`s the result.
#
# Committed, not built from a Dockerfile, so that nothing outlives the image:
# a Docker build also keeps every layer in the builder's cache, where
# deleting the image does not reach it — 1.3 GB per build of this rig, on a
# machine that ran out of disk that way. `docker image rm` frees all of this.
#
#   vivid         from linux-modules-extra: the kernel's virtual camera
#   v4l2loopback  built by DKMS against that same kernel
#   v4l2-ctl      to pull vivid's simulated USB plug
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
kernel=$(apt-cache depends linux-image-generic \
  | awk '/Depends: linux-image-[0-9]/ { sub("linux-image-", "", $2); print $2 }')
case "$(dpkg --print-architecture)" in
  arm64) qemu=qemu-system-arm ;;
  *) qemu=qemu-system-x86 ;;
esac
apt-get install -y --no-install-recommends \
  "$qemu" busybox-static cpio zstd kmod ca-certificates \
  build-essential cmake ninja-build v4l-utils dkms \
  "linux-image-$kernel" "linux-modules-$kernel" "linux-modules-extra-$kernel" \
  "linux-headers-$kernel"
apt-get install -y --no-install-recommends v4l2loopback-dkms
ls "/lib/modules/$kernel/updates/dkms/"v4l2loopback.ko* >/dev/null 2>&1 \
  || dkms autoinstall -k "$kernel"
echo "$kernel" > /etc/pcw-kernel
# What the image needs is installed; the package lists and downloaded
# archives it was installed from are not.
apt-get clean
rm -rf /var/lib/apt/lists/*
