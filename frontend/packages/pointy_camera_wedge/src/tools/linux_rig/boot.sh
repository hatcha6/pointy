#!/bin/bash
# What the Linux rig container runs (setup.sh makes the image; `make
# frontend-camera-wedge-linux` does both).
#
# Builds the library, the probe and the loopback feeder from /pkg/src the way
# they ship (dynamically linked, checked for portability), packs them with
# busybox, v4l2-ctl and the vivid + v4l2loopback modules into an initramfs,
# boots the image's Ubuntu kernel under QEMU, and runs v4l2_scenarios.sh in
# it. Exits 0 only if every scenario passed. Everything it writes stays in
# the container (`--rm` takes it away); mount /work to keep the build.
#
#   docker run --rm -v <package>:/pkg:ro -v <this folder>:/rig:ro <image> bash /rig/boot.sh
#
# PCW_RIG_CMAKE_ARGS adds CMake arguments (split on spaces). Compiler flags
# go in CFLAGS/CXXFLAGS/LDFLAGS, which CMake reads itself — a sanitizer build
# of the probe and feeder, whose reports then appear in the scenario output:
#   -e CFLAGS=-fsanitize=thread -e CXXFLAGS=-fsanitize=thread -e LDFLAGS=-fsanitize=thread
set -euo pipefail
kernel=$(cat /etc/pcw-kernel)
work=/work
root=$work/root
mkdir -p "$work"
rm -rf "$root" && mkdir -p "$root"/{bin,dev,proc,sys,tmp,etc,root}

echo "==> building (kernel $kernel, $(uname -m))"
# shellcheck disable=SC2086 # the extra arguments are meant to split
cmake -S /pkg/src -B $work/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DPCW_BUILD_PROBE=ON -DPCW_BUILD_LOOPBACK_FEED=ON ${PCW_RIG_CMAKE_ARGS:-} > $work/cmake.log
cmake --build $work/build > $work/build.log || { tail -40 $work/build.log; exit 1; }
sh /pkg/src/tools/check_linux_library.sh $work/build/libpointy_camera_wedge.so

# A binary and every shared library it loads, at their own paths.
copy_with_libraries() {
  cp "$1" "$root/bin/"
  ldd "$1" | grep -oE '/[^ ]+' | while read -r library; do
    mkdir -p "$root$(dirname "$library")"
    cp -L "$library" "$root$library"
  done
}
copy_with_libraries $work/build/camera_wedge_probe
copy_with_libraries $work/build/v4l2_loopback_feed
copy_with_libraries "$(command -v v4l2-ctl)"

cp /bin/busybox "$root/bin/busybox"
for applet in $(/bin/busybox --list); do
  [ -e "$root/bin/$applet" ] || ln -s busybox "$root/bin/$applet"
done

# The modules, decompressed (busybox's insmod takes plain .ko), with what
# the scenarios expect: vivid at /dev/video10, the loopback at /dev/video20.
: > "$root/load-modules.sh"
for module in vivid v4l2loopback; do
  modprobe -S "$kernel" --show-depends $module | awk '{ print $2 }'
done | awk '!seen[$0]++' | while read -r path; do
  plain=${path%.zst}
  mkdir -p "$root$(dirname "$plain")"
  case "$path" in
    *.zst) zstd -dqf "$path" -o "$root$plain" ;;
    *) cp "$path" "$root$plain" ;;
  esac
  case "$plain" in
    */vivid.ko) options="n_devs=1 node_types=0x1 multiplanar=1 vid_cap_nr=10" ;;
    */v4l2loopback.ko) options="devices=1 video_nr=20 exclusive_caps=1 card_label=PointyLoopback" ;;
    *) options="" ;;
  esac
  echo "insmod $plain $options" >> "$root/load-modules.sh"
done

printf 'root:x:0:0:root:/root:/bin/sh\nnobody:x:65534:65534:nobody:/:/bin/sh\n' > "$root/etc/passwd"
printf 'root:x:0:\nnogroup:x:65534:\nvideo:x:44:\n' > "$root/etc/group"
cp /pkg/src/tools/v4l2_scenarios.sh "$root/scenarios.sh"
cp /rig/init.sh "$root/init"
chmod +x "$root/init"
(cd "$root" && find . | cpio -o -H newc --quiet | gzip -1 > $work/initrd.gz)

# KVM when the host passes /dev/kvm through (a Linux machine); otherwise
# emulation, which is slower but changes nothing the scenarios look at.
accel=(-cpu max)
if [ -w /dev/kvm ]; then accel=(-enable-kvm -cpu host); fi
case "$(uname -m)" in
  aarch64)
    zcat "/boot/vmlinuz-$kernel" > $work/kernel
    qemu=(qemu-system-aarch64 -M virt "${accel[@]}")
    console=ttyAMA0
    ;;
  *)
    cp "/boot/vmlinuz-$kernel" $work/kernel
    qemu=(qemu-system-x86_64 -M q35 "${accel[@]}")
    console=ttyS0
    ;;
esac

# ThreadSanitizer cannot map its shadow memory under the address space
# randomisation of recent kernels ("unexpected memory mapping"): a sanitizer
# build boots without it.
cmdline="console=$console rdinit=/init panic=-1 loglevel=4"
case "${CXXFLAGS:-} ${PCW_RIG_CMAKE_ARGS:-}" in *sanitize=thread*) cmdline="$cmdline norandmaps" ;; esac

# 1.5 GB is several times what the scenarios touch, and stays well inside
# Docker Desktop's default 2 GB VM, where other containers live too.
echo "==> booting"
timeout 1500 "${qemu[@]}" -smp 4 -m 1536 -nographic -no-reboot -nic none \
  -kernel $work/kernel -initrd $work/initrd.gz -append "$cmdline" | tee $work/console.log
grep -q "=== RESULT pass=[0-9]* fail=0" $work/console.log
