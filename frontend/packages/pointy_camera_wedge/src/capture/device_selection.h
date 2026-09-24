// Which camera to open, decided the same way on every platform.
#pragma once

#include <string>
#include <vector>

#include "capture/capture_backend.h"

namespace pcw {

struct DeviceChoice {
  // Index into the device list, or -1 with `failure` set.
  int index = -1;
  // The picked camera was absent and the only other one was used instead.
  bool substituted = false;
  CaptureFailure failure;
};

// Picks the camera to open for `requested_id`.
//
// No id means the first camera. A picked camera that is absent is replaced
// only when there is exactly ONE other to replace it with — the shop that
// swapped its camera for a different model. With two or more there is no
// safe guess: a till usually has a webcam facing the cashier as well as the
// one on a stand facing the counter, and reading off the wrong one is the
// whole feature failing, so it reports kDeviceNotFound and keeps waiting for
// the camera it was told to use.
DeviceChoice ChooseDevice(const std::vector<DeviceInfo>& devices,
                          const std::string& requested_id);

// The id part of a stored camera id.
//
// Tills that picked a camera before the native wedge stored camera_windows'
// "Display Name <symbolic link>" string; the symbolic link inside it is
// exactly the id this library uses, so an old choice keeps working.
std::string NormalizeDeviceId(const std::string& id);

// Device ids are symbolic links on Windows, which the OS compares without
// regard to case.
bool SameDeviceId(const std::string& a, const std::string& b);

}  // namespace pcw
