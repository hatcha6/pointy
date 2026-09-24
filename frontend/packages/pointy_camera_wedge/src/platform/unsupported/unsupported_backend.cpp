// Every platform without a camera backend yet. Linux will replace this with
// platform/linux/ (see README.md); until then the app reports "unsupported"
// rather than offering a switch that does nothing.
#include "capture/capture_backend.h"

namespace pcw {
namespace {

class UnsupportedBackend final : public CaptureBackend {
 public:
  bool supported() const override { return false; }

  std::unique_ptr<ThreadScope> EnterThread() override {
    return std::make_unique<ThreadScope>();
  }

  std::vector<DeviceInfo> ListDevices(CaptureFailure& failure) override {
    failure = {CaptureError::kUnsupported, "no camera backend on this platform"};
    return {};
  }

  std::unique_ptr<CaptureSession> Open(const OpenRequest&, FrameSink&,
                                       CaptureFailure& failure) override {
    failure = {CaptureError::kUnsupported, "no camera backend on this platform"};
    return nullptr;
  }
};

}  // namespace

std::unique_ptr<CaptureBackend> CreatePlatformBackend() {
  return std::make_unique<UnsupportedBackend>();
}

}  // namespace pcw
