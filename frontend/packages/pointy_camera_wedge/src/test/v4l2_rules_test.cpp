// The Linux backend's decisions (platform/linux/v4l2_rules.h), on what V4L2
// drivers actually report. No kernel needed: the system calls live in
// v4l2_backend.cpp, and CI runs that against real V4L2 devices.
#include <cerrno>
#include <string>
#include <vector>

#include "platform/linux/v4l2_rules.h"
#include "test/check.h"

namespace {

using pcw::CaptureError;
using pcw::ModeEncoding;
using pcw::PixelFormat;
using namespace pcw::v4l2;

bool Contains(const std::vector<FrameSize>& sizes, FrameSize size) {
  for (const auto& s : sizes) {
    if (s == size) return true;
  }
  return false;
}

PCW_TEST(v4l2_formats_are_read_where_their_luminance_is) {
  struct Case {
    uint32_t fourcc;
    PixelFormat pixel;
    ModeEncoding encoding;
  };
  const Case cases[] = {
      {FourCC('Y', 'U', 'Y', 'V'), PixelFormat::kYUY2, ModeEncoding::kRaw},
      {FourCC('Y', 'V', 'Y', 'U'), PixelFormat::kYUY2, ModeEncoding::kRaw},
      {FourCC('U', 'Y', 'V', 'Y'), PixelFormat::kUYVY, ModeEncoding::kRaw},
      {FourCC('G', 'R', 'E', 'Y'), PixelFormat::kGray8, ModeEncoding::kRaw},
      {FourCC('N', 'V', '1', '2'), PixelFormat::kNV12, ModeEncoding::kRaw},
      {FourCC('N', 'V', '2', '1'), PixelFormat::kNV12, ModeEncoding::kRaw},
      {FourCC('Y', 'U', '1', '2'), PixelFormat::kI420, ModeEncoding::kRaw},
      {FourCC('Y', 'V', '1', '2'), PixelFormat::kYV12, ModeEncoding::kRaw},
      {FourCC('B', 'G', 'R', '3'), PixelFormat::kRGB24, ModeEncoding::kRaw},
      {FourCC('X', 'R', '2', '4'), PixelFormat::kRGB32, ModeEncoding::kRaw},
      {FourCC('M', 'J', 'P', 'G'), PixelFormat::kGray8, ModeEncoding::kMjpeg},
      {FourCC('J', 'P', 'E', 'G'), PixelFormat::kGray8, ModeEncoding::kMjpeg},
  };
  for (const auto& c : cases) {
    const auto info = DescribeFormat(c.fourcc);
    if (!info) pcwtest::Fail(__FILE__, __LINE__, "not readable: " + FourCCName(c.fourcc));
    CHECK(info->pixel == c.pixel);
    CHECK(info->encoding == c.encoding);
  }
}

PCW_TEST(formats_the_wedge_cannot_read_are_refused) {
  // H.264 needs a decoder a till should not run; RGB24 is R, G, B, not the
  // B, G, R the RGB layouts mean; Bayer and 10-bit grey are sensor formats.
  for (const auto fourcc : {FourCC('H', '2', '6', '4'), FourCC('R', 'G', 'B', '3'),
                            FourCC('B', 'A', '8', '1'), FourCC('Y', '1', '0', ' ')}) {
    CHECK(!DescribeFormat(fourcc).has_value());
  }
}

PCW_TEST(format_names_read_like_v4l2_ctl_prints_them) {
  CHECK_EQ(FourCCName(FourCC('Y', 'U', 'Y', 'V')), std::string("YUYV"));
  CHECK_EQ(FourCCName(FourCC('M', 'J', 'P', 'G')), std::string("MJPG"));
  CHECK_EQ(FourCCName(FourCC('Y', '1', '6', ' ')), std::string("Y16"));
}

PCW_TEST(every_discrete_size_is_a_candidate) {
  const std::vector<FrameSizeRange> ranges = {
      {{640, 480}, {640, 480}, {1, 1}},
      {{1280, 720}, {1280, 720}, {1, 1}},
      {{1920, 1080}, {1920, 1080}, {1, 1}},
  };
  const auto sizes = CandidateSizes(ranges, 1280, 720);
  CHECK_EQ(sizes.size(), static_cast<size_t>(3));
  CHECK(Contains(sizes, {640, 480}));
  CHECK(Contains(sizes, {1920, 1080}));
}

PCW_TEST(a_size_range_offers_the_preferred_size_on_its_steps) {
  const std::vector<FrameSizeRange> ranges = {{{160, 120}, {1920, 1080}, {16, 8}}};
  const auto exact = CandidateSizes(ranges, 1280, 720);
  CHECK(Contains(exact, {1280, 720}));
  CHECK(Contains(exact, {1920, 1080}));
  // 1000x700 is not on the grid: the step below it is.
  const auto snapped = CandidateSizes(ranges, 1000, 700);
  CHECK(Contains(snapped, {992, 696}));
}

PCW_TEST(a_size_range_never_offers_a_size_outside_it) {
  const std::vector<FrameSizeRange> ranges = {{{320, 240}, {640, 480}, {1, 1}}};
  for (const auto& size : CandidateSizes(ranges, 1280, 720)) {
    CHECK(size.width >= 320 && size.width <= 640);
    CHECK(size.height >= 240 && size.height <= 480);
  }
}

PCW_TEST(every_discrete_interval_is_a_candidate) {
  const std::vector<FrameIntervalRange> ranges = {
      {{1, 30}, {1, 30}}, {{1, 15}, {1, 15}}, {{2, 15}, {2, 15}}};
  const auto intervals = CandidateIntervals(ranges);
  CHECK_EQ(intervals.size(), static_cast<size_t>(3));
  CHECK_EQ(intervals[0].fps(), 30.0);
  CHECK_EQ(intervals[2].fps(), 7.5);
}

PCW_TEST(an_interval_range_offers_30_fps_and_its_fastest) {
  const auto wide = CandidateIntervals({{{1, 60}, {1, 5}}});
  CHECK_EQ(wide.size(), static_cast<size_t>(2));
  CHECK_EQ(wide[0].fps(), 30.0);
  CHECK_EQ(wide[1].fps(), 60.0);
  // 30 fps is not inside a 1-15 fps range.
  const auto slow = CandidateIntervals({{{1, 15}, {1, 1}}});
  CHECK_EQ(slow.size(), static_cast<size_t>(1));
  CHECK_EQ(slow[0].fps(), 15.0);
  CHECK_EQ(FrameInterval{}.fps(), 0.0);
}

NodeIdentity Camera(const std::string& node, const std::string& usb_device,
                    const std::string& serial, const std::string& index = "0") {
  NodeIdentity identity;
  identity.node = node;
  identity.usb_device = usb_device;
  identity.usb_model = "046d:082d";
  identity.usb_serial = serial;
  identity.by_id = "/dev/v4l/by-id/usb-046d_HD_Pro_Webcam_C920" +
                   (serial.empty() ? std::string() : "_" + serial) + "-video-index" + index;
  identity.by_path = "/dev/v4l/by-path/pci-0000:00:14.0-usb-0:" + usb_device.substr(usb_device.size() - 1) +
                     ":1.0-video-index" + index;
  return identity;
}

PCW_TEST(a_camera_with_its_own_serial_is_stored_by_id) {
  // Follows the camera to whichever USB port it is plugged into.
  const auto ids = StableIds({Camera("/dev/video0", "/sys/devices/usb1/1-2", "A1B2C3D4")});
  CHECK_EQ(ids[0], std::string("/dev/v4l/by-id/usb-046d_HD_Pro_Webcam_C920_A1B2C3D4-video-index0"));
}

PCW_TEST(a_camera_without_a_serial_is_stored_by_port) {
  auto twin = Camera("/dev/video0", "/sys/devices/usb1/1-2", "");
  const auto ids = StableIds({twin});
  CHECK_EQ(ids[0], twin.by_path);
}

PCW_TEST(identical_cameras_sharing_one_serial_are_stored_by_port) {
  // Cheap webcams often report the same serial on every unit: both would
  // claim one by-id link, and udev gives it to whichever came last.
  const auto a = Camera("/dev/video0", "/sys/devices/usb1/1-2", "0001");
  const auto b = Camera("/dev/video2", "/sys/devices/usb1/1-3", "0001");
  const auto ids = StableIds({a, b});
  CHECK_EQ(ids[0], a.by_path);
  CHECK_EQ(ids[1], b.by_path);
  CHECK(ids[0] != ids[1]);
}

PCW_TEST(two_cameras_inside_one_device_keep_their_serial_ids) {
  // A laptop's colour and infrared cameras are one USB device, one serial,
  // two nodes — not a conflict.
  const auto colour = Camera("/dev/video0", "/sys/devices/usb1/1-5", "SN42", "0");
  const auto infrared = Camera("/dev/video2", "/sys/devices/usb1/1-5", "SN42", "2");
  const auto ids = StableIds({colour, infrared});
  CHECK_EQ(ids[0], colour.by_id);
  CHECK_EQ(ids[1], infrared.by_id);
}

PCW_TEST(a_node_without_udev_links_is_stored_as_itself) {
  NodeIdentity bare;
  bare.node = "/dev/video4";
  const auto ids = StableIds({bare});
  CHECK_EQ(ids[0], std::string("/dev/video4"));
}

PCW_TEST(errno_values_say_what_a_shop_can_do_about_them) {
  const auto denied = FailureFromErrno(EACCES, "opening /dev/video0");
  CHECK(denied.code == CaptureError::kAccessDenied);
  CHECK_EQ(denied.message, std::string("opening /dev/video0 failed (EACCES)"));
  CHECK(FailureFromErrno(EPERM, "x").code == CaptureError::kAccessDenied);
  CHECK(FailureFromErrno(EBUSY, "x").code == CaptureError::kInUse);
  CHECK(FailureFromErrno(ENODEV, "x").code == CaptureError::kDeviceLost);
  CHECK(FailureFromErrno(ENOENT, "x").code == CaptureError::kDeviceLost);
  const auto other = FailureFromErrno(EINVAL, "setting the format");
  CHECK(other.code == CaptureError::kPlatform);
  CHECK_EQ(other.message, std::string("setting the format failed (EINVAL)"));
  CHECK_EQ(ErrnoName(9999), std::string("errno 9999"));
}

}  // namespace
