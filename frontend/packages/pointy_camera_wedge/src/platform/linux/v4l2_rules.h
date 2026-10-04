// The parts of the V4L2 backend that are decisions rather than system calls:
// what a pixel format means to the wedge, which of a camera's sizes and frame
// rates are worth trying, which name finds a camera again after a reboot,
// and what an errno means to a shop.
//
// No Linux headers in here, on purpose: these rules are tested on every
// platform the library builds on (test/v4l2_rules_test.cpp), and the backend
// (v4l2_backend.cpp) only feeds them what the kernel reports.
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "capture/capture_backend.h"
#include "capture/mode_score.h"
#include "capture/pixel_format.h"

namespace pcw::v4l2 {

// A V4L2 pixel format code, spelled as linux/videodev2.h spells it.
constexpr uint32_t FourCC(char a, char b, char c, char d) {
  return static_cast<uint32_t>(static_cast<unsigned char>(a)) |
         (static_cast<uint32_t>(static_cast<unsigned char>(b)) << 8) |
         (static_cast<uint32_t>(static_cast<unsigned char>(c)) << 16) |
         (static_cast<uint32_t>(static_cast<unsigned char>(d)) << 24);
}

// "YUYV", "MJPG": how v4l2-ctl and every support page write a format.
std::string FourCCName(uint32_t fourcc);

// What the wedge does with a pixel format.
struct FormatInfo {
  // The layout the luminance is read out of. For MJPEG, what decoding gives.
  PixelFormat pixel = PixelFormat::kUnknown;
  ModeEncoding encoding = ModeEncoding::kRaw;
};

// Null for a format the wedge cannot read: H.264 (no decoder here, and too
// heavy for a till), Bayer, 10-bit and the like. A webcam always offers YUYV
// or MJPEG besides.
std::optional<FormatInfo> DescribeFormat(uint32_t fourcc);

struct FrameSize {
  int width = 0;
  int height = 0;
  bool operator==(const FrameSize& other) const {
    return width == other.width && height == other.height;
  }
};

// One answer of VIDIOC_ENUM_FRAMESIZES: a single size (min == max), or a
// range a driver accepts any step of (stepwise or continuous).
struct FrameSizeRange {
  FrameSize min;
  FrameSize max;
  FrameSize step;
};

// The sizes worth trying. Every discrete size is kept, since the ranking
// decides between them; a range is narrowed to the preferred size and a few
// usual ones, snapped onto the range's steps.
std::vector<FrameSize> CandidateSizes(const std::vector<FrameSizeRange>& ranges,
                                      int preferred_width, int preferred_height);

// A frame interval in seconds, numerator / denominator: 1/30 is 30 fps.
struct FrameInterval {
  uint32_t numerator = 0;
  uint32_t denominator = 0;
  // 0 when unknown.
  double fps() const;
  bool operator==(const FrameInterval& other) const {
    return numerator == other.numerator && denominator == other.denominator;
  }
};

// One answer of VIDIOC_ENUM_FRAMEINTERVALS: a single interval (min == max),
// or a range from the fastest (min) to the slowest (max).
struct FrameIntervalRange {
  FrameInterval min;
  FrameInterval max;
};

// The intervals worth trying: every discrete one; from a range, 1/30 when it
// is inside and the fastest the range allows.
std::vector<FrameInterval> CandidateIntervals(
    const std::vector<FrameIntervalRange>& ranges);

// What identifies one video node, gathered from /dev and sysfs.
struct NodeIdentity {
  // "/dev/video0". Its number follows plug-in order, so it is a fallback.
  std::string node;
  // The udev links that resolve to `node`, when they exist:
  // /dev/v4l/by-id/usb-<vendor>_<model>[_<serial>]-video-index<N> and
  // /dev/v4l/by-path/<bus path>-video-index<N>.
  std::string by_id;
  std::string by_path;
  // The USB device the node belongs to: its sysfs path (one per physical
  // device), "vendor:product", and its serial number (empty when it reports
  // none). All empty for a node that is not on USB.
  std::string usb_device;
  std::string usb_model;
  std::string usb_serial;
};

// The id each node is stored under, in the same order.
//
// The by-id link, when the camera's serial number makes it unique: it then
// follows the camera to any USB port. Many cheap webcams have no serial, or
// one every unit shares, and two of them would both claim the same by-id
// link — whichever udev processed last gets it, which can change at every
// boot, and the till would quietly read off the cashier's webcam. Those get
// the by-path link: tied to the port, never to the wrong camera. Without
// udev (a container) the node itself.
std::vector<std::string> StableIds(const std::vector<NodeIdentity>& nodes);

// "EACCES" for logs and support calls; "errno 123" for anything unlisted.
std::string ErrnoName(int error);

// What an errno from opening or streaming a camera means to a shop.
//  EACCES/EPERM   the user may not open /dev/video* (not in the "video"
//                 group, or not the seat's active session)
//  EBUSY          another program is streaming from the camera
//  ENODEV/ENXIO/  the camera is gone: unplugged, or reset by the USB bus
//  ENOENT
// Everything else is a platform error carrying the errno's name.
CaptureFailure FailureFromErrno(int error, const std::string& doing);

}  // namespace pcw::v4l2
