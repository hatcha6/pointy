// The one seam that differs per operating system.
//
// Everything a wedge does with a frame — turning it grey, decoding it,
// deciding whether to believe it — is platform-agnostic and lives in vision/,
// policy/ and engine/. What is not is getting frames out of a camera at all:
// Media Foundation on Windows, V4L2 on Linux. A backend implements the three
// calls below and nothing else, so adding Linux is one new file under
// platform/linux/ plus a line in CMakeLists.txt (see README.md).
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "capture/pixel_format.h"

namespace pcw {

// A camera the OS can see. `id` is whatever the backend needs to find it
// again (a Media Foundation symbolic link on Windows) and is never shown;
// `label` is the name a shop recognises.
struct DeviceInfo {
  std::string id;
  std::string label;
};

// Why a camera is not running. The numbers are the PCW_ERROR_* values of the
// C ABI; Dart turns them into messages a cashier can act on.
enum class CaptureError : int32_t {
  kNone = 0,
  kNoCamera = 1,
  kDeviceNotFound = 2,
  kAccessDenied = 3,
  kInUse = 4,
  kDeviceLost = 5,
  kNoUsableFormat = 6,
  kStalled = 7,
  kPlatform = 8,
  kUnsupported = 9,
};

struct CaptureFailure {
  CaptureError code = CaptureError::kNone;
  // For logs and support calls, not for cashiers: it carries raw codes.
  std::string message;

  explicit operator bool() const { return code != CaptureError::kNone; }
};

// What an open camera is actually delivering, which is not always what was
// asked for.
struct StreamInfo {
  std::string device_id;
  std::string device_label;
  int width = 0;
  int height = 0;
  double fps = 0;
  // "MJPG>NV12" when the camera sends one format and it is decoded to
  // another; shown in settings so a support call can see what the driver did.
  std::string pixel_format;
  // The picked camera was absent and the only other one was used instead.
  bool substituted = false;
};

struct OpenRequest {
  // Empty means "the first camera".
  std::string device_id;
  int preferred_width = 1280;
  int preferred_height = 720;
};

// Where a session delivers its frames. Called on the backend's own threads;
// implementations must be quick (copy, don't decode) and thread-safe.
class FrameSink {
 public:
  virtual ~FrameSink() = default;
  virtual void OnFrame(const PixelBuffer& frame) = 0;
  // The stream broke after it opened (unplugged, reset, taken by another
  // program). The session will not deliver more frames.
  virtual void OnStreamFailure(const CaptureFailure& failure) = 0;
};

// An open, streaming camera. Destroying it stops the stream and releases the
// device; once the destructor returns the sink is never called again.
class CaptureSession {
 public:
  virtual ~CaptureSession() = default;
  virtual const StreamInfo& info() const = 0;
};

// Per-thread platform set-up (COM and Media Foundation on Windows). Held for
// as long as a thread talks to the backend.
class ThreadScope {
 public:
  virtual ~ThreadScope() = default;
};

class CaptureBackend {
 public:
  virtual ~CaptureBackend() = default;

  // False when this build has no way to reach a camera on this platform.
  virtual bool supported() const = 0;

  virtual std::unique_ptr<ThreadScope> EnterThread() = 0;

  virtual std::vector<DeviceInfo> ListDevices(CaptureFailure& failure) = 0;

  // Opens and starts streaming, or returns null with `failure` filled in.
  virtual std::unique_ptr<CaptureSession> Open(const OpenRequest& request,
                                               FrameSink& sink,
                                               CaptureFailure& failure) = 0;
};

// The backend this build was compiled with: Media Foundation on Windows,
// synthetic frames in test builds, and "unsupported" everywhere else.
std::unique_ptr<CaptureBackend> CreatePlatformBackend();

}  // namespace pcw
