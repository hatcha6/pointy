#include "platform/linux/v4l2_rules.h"

#include <algorithm>
#include <cerrno>
#include <map>
#include <utility>

namespace pcw::v4l2 {
namespace {

struct KnownFormat {
  uint32_t fourcc;
  FormatInfo info;
};

// Each format by where its luminance sits, which is all the wedge reads:
// YVYU keeps Y where YUYV does, NV21 and NV16 start with a whole Y plane like
// NV12. V4L2's BGR24/BGR32/XBGR32/ABGR32 are B, G, R in memory, the order
// PixelFormat's RGB layouts mean. (RGB24 is R, G, B and is not listed: no
// webcam offers it without YUYV beside it.)
constexpr KnownFormat kFormats[] = {
    {FourCC('Y', 'U', 'Y', 'V'), {PixelFormat::kYUY2, ModeEncoding::kRaw}},
    {FourCC('Y', 'V', 'Y', 'U'), {PixelFormat::kYUY2, ModeEncoding::kRaw}},
    {FourCC('U', 'Y', 'V', 'Y'), {PixelFormat::kUYVY, ModeEncoding::kRaw}},
    {FourCC('V', 'Y', 'U', 'Y'), {PixelFormat::kUYVY, ModeEncoding::kRaw}},
    {FourCC('G', 'R', 'E', 'Y'), {PixelFormat::kGray8, ModeEncoding::kRaw}},
    {FourCC('N', 'V', '1', '2'), {PixelFormat::kNV12, ModeEncoding::kRaw}},
    {FourCC('N', 'V', '2', '1'), {PixelFormat::kNV12, ModeEncoding::kRaw}},
    {FourCC('N', 'V', '1', '6'), {PixelFormat::kNV12, ModeEncoding::kRaw}},
    {FourCC('N', 'V', '6', '1'), {PixelFormat::kNV12, ModeEncoding::kRaw}},
    {FourCC('Y', 'U', '1', '2'), {PixelFormat::kI420, ModeEncoding::kRaw}},
    {FourCC('Y', 'V', '1', '2'), {PixelFormat::kYV12, ModeEncoding::kRaw}},
    {FourCC('B', 'G', 'R', '3'), {PixelFormat::kRGB24, ModeEncoding::kRaw}},
    {FourCC('B', 'G', 'R', '4'), {PixelFormat::kRGB32, ModeEncoding::kRaw}},
    {FourCC('X', 'R', '2', '4'), {PixelFormat::kRGB32, ModeEncoding::kRaw}},
    {FourCC('A', 'R', '2', '4'), {PixelFormat::kRGB32, ModeEncoding::kRaw}},
    {FourCC('M', 'J', 'P', 'G'), {PixelFormat::kGray8, ModeEncoding::kMjpeg}},
    {FourCC('J', 'P', 'E', 'G'), {PixelFormat::kGray8, ModeEncoding::kMjpeg}},
};

// Steps `value` onto the grid min + k * step, never past max.
int Snap(int value, int min, int max, int step) {
  value = std::clamp(value, min, std::max(min, max));
  if (step <= 1) return value;
  return min + (value - min) / step * step;
}

// a < b for two intervals (a shorter interval is a faster camera).
bool Shorter(const FrameInterval& a, const FrameInterval& b) {
  return static_cast<uint64_t>(a.numerator) * b.denominator <
         static_cast<uint64_t>(b.numerator) * a.denominator;
}

}  // namespace

std::string FourCCName(uint32_t fourcc) {
  std::string name;
  for (int shift = 0; shift < 32; shift += 8) {
    const char c = static_cast<char>((fourcc >> shift) & 0x7F);
    name.push_back(c >= 32 && c < 127 ? c : '?');
  }
  // Trailing spaces pad short codes ("Y16 ").
  while (!name.empty() && name.back() == ' ') name.pop_back();
  return name;
}

std::optional<FormatInfo> DescribeFormat(uint32_t fourcc) {
  for (const auto& known : kFormats) {
    if (known.fourcc == fourcc) return known.info;
  }
  return std::nullopt;
}

std::vector<FrameSize> CandidateSizes(const std::vector<FrameSizeRange>& ranges,
                                      int preferred_width, int preferred_height) {
  std::vector<FrameSize> sizes;
  const auto add = [&](FrameSize size) {
    if (size.width <= 0 || size.height <= 0) return;
    if (std::find(sizes.begin(), sizes.end(), size) == sizes.end()) {
      sizes.push_back(size);
    }
  };
  for (const auto& range : ranges) {
    if (range.min == range.max) {
      add(range.min);
      continue;
    }
    const FrameSize targets[] = {
        {preferred_width, preferred_height}, {1280, 720}, {1920, 1080},
        {640, 480}, range.max};
    for (const auto& target : targets) {
      add({Snap(target.width, range.min.width, range.max.width, range.step.width),
           Snap(target.height, range.min.height, range.max.height,
                range.step.height)});
    }
  }
  return sizes;
}

double FrameInterval::fps() const {
  if (numerator == 0 || denominator == 0) return 0;
  return static_cast<double>(denominator) / numerator;
}

std::vector<FrameInterval> CandidateIntervals(
    const std::vector<FrameIntervalRange>& ranges) {
  std::vector<FrameInterval> intervals;
  const auto add = [&](FrameInterval interval) {
    if (interval.numerator == 0 || interval.denominator == 0) return;
    if (std::find(intervals.begin(), intervals.end(), interval) == intervals.end()) {
      intervals.push_back(interval);
    }
  };
  for (const auto& range : ranges) {
    if (range.min == range.max) {
      add(range.min);
      continue;
    }
    const FrameInterval thirty{1, 30};
    if (!Shorter(thirty, range.min) && !Shorter(range.max, thirty)) add(thirty);
    add(range.min);
  }
  return intervals;
}

std::vector<std::string> StableIds(const std::vector<NodeIdentity>& nodes) {
  // How many different physical devices claim each model + serial.
  std::map<std::pair<std::string, std::string>, std::vector<std::string>> claims;
  for (const auto& node : nodes) {
    if (node.usb_serial.empty()) continue;
    auto& devices = claims[{node.usb_model, node.usb_serial}];
    if (std::find(devices.begin(), devices.end(), node.usb_device) == devices.end()) {
      devices.push_back(node.usb_device);
    }
  }
  std::vector<std::string> ids;
  ids.reserve(nodes.size());
  for (const auto& node : nodes) {
    const bool unique_serial =
        !node.usb_serial.empty() &&
        claims[{node.usb_model, node.usb_serial}].size() == 1;
    if (!node.by_id.empty() && unique_serial) {
      ids.push_back(node.by_id);
    } else if (!node.by_path.empty()) {
      ids.push_back(node.by_path);
    } else {
      ids.push_back(node.node);
    }
  }
  return ids;
}

std::string ErrnoName(int error) {
  switch (error) {
    case EACCES:
      return "EACCES";
    case EPERM:
      return "EPERM";
    case EBUSY:
      return "EBUSY";
    case ENODEV:
      return "ENODEV";
    case ENXIO:
      return "ENXIO";
    case ENOENT:
      return "ENOENT";
    case ENOSPC:
      return "ENOSPC";
    case EINVAL:
      return "EINVAL";
    case EIO:
      return "EIO";
    case ENOMEM:
      return "ENOMEM";
    case EAGAIN:
      return "EAGAIN";
    case EINTR:
      return "EINTR";
    case ENOTTY:
      return "ENOTTY";
    case EPIPE:
      return "EPIPE";
    case ETIMEDOUT:
      return "ETIMEDOUT";
    case EMFILE:
      return "EMFILE";
    default:
      break;
  }
  return "errno " + std::to_string(error);
}

CaptureFailure FailureFromErrno(int error, const std::string& doing) {
  CaptureError code = CaptureError::kPlatform;
  switch (error) {
    case EACCES:
    case EPERM:
      code = CaptureError::kAccessDenied;
      break;
    case EBUSY:
      code = CaptureError::kInUse;
      break;
    case ENODEV:
    case ENXIO:
    case ENOENT:
      code = CaptureError::kDeviceLost;
      break;
    default:
      break;
  }
  return {code, doing + " failed (" + ErrnoName(error) + ")"};
}

}  // namespace pcw::v4l2
