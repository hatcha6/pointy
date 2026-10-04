#!/bin/sh
# /init of the rig's VM (see boot.sh): load the camera drivers, run the
# scenarios, power off. The result line is what boot.sh reads.
export PATH=/bin
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
mkdir -p /tmp
echo "=== kernel $(uname -r), $(nproc) cpus"
sh /load-modules.sh
sleep 1
sh /scenarios.sh
dmesg | grep -iE "vivid|v4l2loopback" | tail -n 6
poweroff -f
