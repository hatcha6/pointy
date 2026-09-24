#include <cctype>
#include <string>
#include <vector>

#include "capture/device_selection.h"
#include "test/check.h"

namespace {

using pcw::CaptureError;
using pcw::DeviceInfo;

const std::string kHueLink =
    "\\\\?\\usb#vid_0c45&pid_636b&mi_00#7&2d3f1a0&0&0000#{e5323777-f976-4f5b-9b55-b94699c46e44}\\global";
const std::string kDellLink =
    "\\\\?\\usb#vid_1bcf&pid_2b94&mi_00#6&316f151d&0&0000#{e5323777-f976-4f5b-9b55-b94699c46e44}\\global";

std::vector<DeviceInfo> TwoCameras() {
  return {{kDellLink, "Integrated Webcam"}, {kHueLink, "HUE HD Pro camera"}};
}

PCW_TEST(no_id_means_the_first_camera) {
  const auto choice = pcw::ChooseDevice(TwoCameras(), "");
  CHECK_EQ(choice.index, 0);
  CHECK(!choice.substituted);
}

PCW_TEST(the_picked_camera_is_found_whatever_the_case) {
  std::string upper = kHueLink;
  for (auto& c : upper) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
  const auto choice = pcw::ChooseDevice(TwoCameras(), upper);
  CHECK_EQ(choice.index, 1);
}

PCW_TEST(a_camera_windows_id_from_the_old_wedge_still_finds_its_camera) {
  // What tills stored before this library: "display name <symbolic link>".
  const auto stored = "HUE HD Pro camera <" + kHueLink + ">";
  CHECK_EQ(pcw::NormalizeDeviceId(stored), kHueLink);
  const auto choice = pcw::ChooseDevice(TwoCameras(), stored);
  CHECK_EQ(choice.index, 1);
}

PCW_TEST(an_id_without_the_old_shape_is_left_alone) {
  CHECK_EQ(pcw::NormalizeDeviceId("synthetic:ean13=123"), std::string("synthetic:ean13=123"));
  CHECK_EQ(pcw::NormalizeDeviceId("Camera <>"), std::string("Camera <>"));
  CHECK_EQ(pcw::NormalizeDeviceId(""), std::string(""));
}

PCW_TEST(an_absent_pick_with_one_other_camera_uses_it_and_says_so) {
  const auto choice = pcw::ChooseDevice({{kHueLink, "HUE HD Pro camera"}}, kDellLink);
  CHECK_EQ(choice.index, 0);
  CHECK(choice.substituted);
}

PCW_TEST(an_absent_pick_with_two_others_is_not_guessed) {
  // One of them is almost certainly the webcam facing the cashier.
  const auto choice = pcw::ChooseDevice(TwoCameras(), "\\\\?\\usb#gone");
  CHECK_EQ(choice.index, -1);
  CHECK(choice.failure.code == CaptureError::kDeviceNotFound);
}

PCW_TEST(no_cameras_at_all_is_its_own_failure) {
  const auto choice = pcw::ChooseDevice({}, "");
  CHECK(choice.failure.code == CaptureError::kNoCamera);
}

}  // namespace
