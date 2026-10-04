#!/bin/sh
# The Linux backend against real V4L2 drivers in a real kernel: what CI runs
# on its runner and linux_rig/ runs under QEMU from a Mac.
#
#   vivid         the kernel's own virtual camera (its test driver for V4L2
#                 compliance), at /dev/video10: modes, streaming, and a
#                 simulated USB unplug and replug
#   v4l2loopback  a real V4L2 camera fed by v4l2_loopback_feed, at
#                 /dev/video20: a drawn barcode as YUYV, and as MJPEG with no
#                 Huffman tables (how UVC cameras send it)
#
# Needs root (it changes device permissions), both modules loaded, and
# camera_wedge_probe, v4l2_loopback_feed and v4l2-ctl on PATH. POSIX sh, so
# busybox runs it too. Exits non-zero when any scenario fails. A kernel built
# without vivid (some cloud kernels) skips its scenarios, loudly, when run
# with PCW_NO_VIVID=1; the loopback ones are never skipped.
VIVID=/dev/video10
LOOPBACK=/dev/video20
pass=0
fail=0

check() {
  name=$1
  shift
  if "$@"; then
    echo "PASS $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name"
    fail=$((fail + 1))
  fi
}
count_at_least() { [ "$(grep -c "$1" "$2")" -ge "$3" ]; }
feed() {
  v4l2_loopback_feed --device $LOOPBACK "$@" > /tmp/pcw-feed.txt 2>&1 &
  FEED=$!
  sleep 2
}
unfeed() {
  kill $FEED 2> /dev/null
  wait $FEED 2> /dev/null
}
# Runs the probe; its output goes to the file named first and to the log.
probe() {
  out=$1
  shift
  timeout 120 camera_wedge_probe "$@" > "$out" 2>&1
  status=$?
  cat "$out"
  return $status
}

ls -l /dev/video* /dev/v4l/by-*/ 2> /dev/null
check loopback_present test -c $LOOPBACK

if [ "${PCW_NO_VIVID:-0}" = 1 ]; then
  echo "SKIP vivid: not in this kernel (PCW_NO_VIVID=1)"
else

echo "=== vivid: listed, streams the mode the ranking picks, stops cleanly"
camera_wedge_probe --list | tee /tmp/pcw-list.txt
check vivid_listed grep -q "vivid" /tmp/pcw-list.txt
# The id is a udev link where udev runs (CI), the node itself where it does
# not (the rig); either way it must lead to the camera.
id=$(grep -A1 "vivid" /tmp/pcw-list.txt | sed -n 2p | tr -d ' ')
check vivid_id_leads_to_the_node test "$(readlink -f "$id")" = $VIVID
probe /tmp/pcw-vivid.txt --device "$id" --seconds 8
check vivid_running grep -q "status running" /tmp/pcw-vivid.txt
check vivid_picked_720p grep -qE "running \| vivid 1280x720" /tmp/pcw-vivid.txt
check vivid_frames_arrive grep -qE "stats ([1-9][0-9]*|0\.[1-9])[0-9.]* fps" /tmp/pcw-vivid.txt
check vivid_stops_cleanly grep -q "status stopped" /tmp/pcw-vivid.txt

echo "=== vivid: unplugged mid-stream, noticed, and back on its own"
# vivid's Disconnect simulates a USB unplug and replug (kernel log:
# "disconnect", "reconnect").
timeout 60 camera_wedge_probe --device "$id" --seconds 12 > /tmp/pcw-unplug.txt 2>&1 &
PROBE=$!
sleep 4
v4l2-ctl -d $VIVID -c disconnect=1
wait $PROBE
cat /tmp/pcw-unplug.txt
check unplug_noticed grep -q "recovering: disconnected" /tmp/pcw-unplug.txt
check unplug_reopened count_at_least "status running" /tmp/pcw-unplug.txt 2
check unplug_stops_cleanly grep -q "status stopped" /tmp/pcw-unplug.txt

fi

echo "=== loopback: a barcode as YUYV is scanned"
feed --format yuyv --ean13 3600523434725 --size 1280x720 --fps 15 --seconds 120
camera_wedge_probe --list | tee /tmp/pcw-list2.txt
check loopback_listed grep -q "PointyLoopback" /tmp/pcw-list2.txt
probe /tmp/pcw-yuyv.txt --device $LOOPBACK --seconds 60 --expect 3600523434725
check yuyv_ean13_scanned test $? -eq 0
check yuyv_format_reported grep -q "YUYV" /tmp/pcw-yuyv.txt
unfeed

echo "=== loopback: MJPEG without Huffman tables, as UVC cameras send it"
feed --format mjpeg_nodht --qr pay://receipt/9f2 --size 1280x720 --fps 15 --seconds 120
probe /tmp/pcw-mjpeg-qr.txt --device $LOOPBACK --seconds 60 --expect pay://receipt/9f2
check mjpeg_qr_scanned test $? -eq 0
check mjpeg_decoded_to_grey grep -q "MJPG>GRAY8" /tmp/pcw-mjpeg-qr.txt
unfeed
feed --format mjpeg_nodht --ean13 3600523434725 --size 1280x720 --fps 15 --seconds 120
probe /tmp/pcw-mjpeg-ean.txt --device $LOOPBACK --seconds 60 --expect 3600523434725
check mjpeg_ean13_scanned test $? -eq 0
unfeed

echo "=== loopback: a camera that goes quiet is restarted by the watchdog"
feed --format yuyv --qr quiet --size 640x480 --fps 15 --frames 30 --seconds 60
probe /tmp/pcw-stall.txt --device $LOOPBACK --seconds 14
check stall_detected grep -q "stopped sending pictures" /tmp/pcw-stall.txt
unfeed

echo "=== a user who may not open the cameras is told so"
# The loopback only shows as a camera while it is fed.
feed --format yuyv --qr denied --size 640x480 --fps 15 --seconds 60
chmod 600 /dev/video*
# A copy nobody can reach (su resets PATH, and a CI checkout's home may be
# closed to other users).
cp "$(command -v camera_wedge_probe)" /tmp/pcw-probe
chmod 755 /tmp/pcw-probe
timeout 30 su -s /bin/sh nobody -c "id; /tmp/pcw-probe --seconds 3" > /tmp/pcw-denied.txt 2>&1
cat /tmp/pcw-denied.txt
check access_denied_reported grep -q "may not open the camera" /tmp/pcw-denied.txt
check access_denied_backs_off grep -q "retry in 5000 ms" /tmp/pcw-denied.txt
chmod 666 /dev/video*
unfeed

echo "=== RESULT pass=$pass fail=$fail"
[ $fail -eq 0 ]
