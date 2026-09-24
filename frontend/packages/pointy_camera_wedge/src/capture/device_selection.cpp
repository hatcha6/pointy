#include "capture/device_selection.h"

#include <cctype>

namespace pcw {

std::string NormalizeDeviceId(const std::string& id) {
  // camera_windows' CaptureDeviceInfo::GetUniqueDeviceName is
  // `display_name + " <" + device_id + ">"`, and its own parser splits at the
  // LAST " <". Mirror that exactly; anything else is already an id.
  if (id.size() < 3 || id.back() != '>') return id;
  const auto open = id.rfind(" <");
  if (open == std::string::npos) return id;
  const auto inner = id.substr(open + 2, id.size() - open - 3);
  return inner.empty() ? id : inner;
}

bool SameDeviceId(const std::string& a, const std::string& b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); ++i) {
    const auto left = static_cast<unsigned char>(a[i]);
    const auto right = static_cast<unsigned char>(b[i]);
    if (std::tolower(left) != std::tolower(right)) return false;
  }
  return true;
}

DeviceChoice ChooseDevice(const std::vector<DeviceInfo>& devices,
                          const std::string& requested_id) {
  DeviceChoice choice;
  if (devices.empty()) {
    choice.failure = {CaptureError::kNoCamera, "no video capture device"};
    return choice;
  }
  const auto wanted = NormalizeDeviceId(requested_id);
  if (wanted.empty()) {
    choice.index = 0;
    return choice;
  }
  for (size_t i = 0; i < devices.size(); ++i) {
    if (SameDeviceId(devices[i].id, wanted)) {
      choice.index = static_cast<int>(i);
      return choice;
    }
  }
  if (devices.size() == 1) {
    choice.index = 0;
    choice.substituted = true;
    return choice;
  }
  choice.failure = {CaptureError::kDeviceNotFound,
                    "the chosen camera is not connected"};
  return choice;
}

}  // namespace pcw
