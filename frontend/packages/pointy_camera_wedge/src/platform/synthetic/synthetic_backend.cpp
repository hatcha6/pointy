// A camera made of drawn frames, for test builds (PCW_SYNTHETIC_BACKEND).
//
// A device id is a small recipe, so a test anywhere — C++, or Dart through
// the real C ABI — can ask for exactly the counter it needs:
//
//   synthetic:ean13=3600523434725;angle=30;pixel=yuy2
//   synthetic:qr=hello;fps=15
//   synthetic:blank
//   synthetic:fail=access_denied        open fails the way Windows would
//   synthetic:ean13=...;lose_after=20   unplugged after 20 frames
//   synthetic:ean13=...;stall_after=5   stops sending frames after 5
//
// It never ships: the product build uses the platform's real backend.
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <sstream>
#include <thread>
#include <vector>

#include "capture/capture_backend.h"
#include "capture/device_selection.h"
#include "platform/synthetic/scene.h"

namespace pcw {
namespace {

constexpr char kPrefix[] = "synthetic:";

struct Recipe {
  SceneSpec scene;
  int fps = 30;
  std::string fail;
  int lose_after = 0;
  int stall_after = 0;
  PixelFormat pixel = PixelFormat::kNV12;
  bool bottom_up = false;
};

bool StartsWith(const std::string& text, const std::string& prefix) {
  return text.compare(0, prefix.size(), prefix) == 0;
}

int ToInt(const std::string& value, int fallback) {
  try {
    return std::stoi(value);
  } catch (...) {
    return fallback;
  }
}

Recipe Parse(const std::string& id) {
  Recipe recipe;
  recipe.scene.text.clear();
  std::stringstream stream(id.substr(sizeof(kPrefix) - 1));
  std::string part;
  while (std::getline(stream, part, ';')) {
    const auto eq = part.find('=');
    const auto key = part.substr(0, eq);
    const auto value = eq == std::string::npos ? "" : part.substr(eq + 1);
    static const std::pair<const char*, const char*> kFormats[] = {
        {"ean13", "EAN13"},     {"ean8", "EAN8"},     {"upca", "UPCA"},
        {"upce", "UPCE"},       {"code128", "Code128"}, {"code93", "Code93"},
        {"code39", "Code39"},   {"itf", "ITF"},       {"codabar", "Codabar"},
        {"qr", "QRCode"},       {"datamatrix", "DataMatrix"},
        {"aztec", "Aztec"},     {"pdf417", "PDF417"},
    };
    bool matched = false;
    for (const auto& [short_name, format] : kFormats) {
      if (key == short_name) {
        recipe.scene.format = format;
        recipe.scene.text = value;
        matched = true;
      }
    }
    if (matched || key == "blank") continue;
    if (key == "angle") recipe.scene.angle = ToInt(value, 0);
    if (key == "module") recipe.scene.module = ToInt(value, 3);
    if (key == "noise") recipe.scene.noise = ToInt(value, 0);
    if (key == "blur") recipe.scene.blur = ToInt(value, 0);
    if (key == "width") recipe.scene.width = ToInt(value, 1280);
    if (key == "height") recipe.scene.height = ToInt(value, 720);
    if (key == "fps") recipe.fps = std::max(1, ToInt(value, 30));
    if (key == "fail") recipe.fail = value;
    if (key == "lose_after") recipe.lose_after = ToInt(value, 0);
    if (key == "stall_after") recipe.stall_after = ToInt(value, 0);
    if (key == "pixel") {
      if (value == "gray") recipe.pixel = PixelFormat::kGray8;
      if (value == "nv12") recipe.pixel = PixelFormat::kNV12;
      if (value == "yuy2") recipe.pixel = PixelFormat::kYUY2;
      if (value == "uyvy") recipe.pixel = PixelFormat::kUYVY;
      if (value == "rgb24") recipe.pixel = PixelFormat::kRGB24;
      if (value == "rgb32") recipe.pixel = PixelFormat::kRGB32;
      if (value == "rgb32_bottom_up") {
        recipe.pixel = PixelFormat::kRGB32;
        recipe.bottom_up = true;
      }
    }
  }
  return recipe;
}

CaptureError FailureFor(const std::string& name) {
  if (name == "access_denied") return CaptureError::kAccessDenied;
  if (name == "in_use") return CaptureError::kInUse;
  if (name == "no_format") return CaptureError::kNoUsableFormat;
  if (name == "no_camera") return CaptureError::kNoCamera;
  return CaptureError::kPlatform;
}

// The grey scene packed into the frame format a real driver would hand over.
struct EncodedFrame {
  std::vector<uint8_t> bytes;
  PixelBuffer buffer;
};

EncodedFrame Encode(const LumaImage& luma, PixelFormat format, bool bottom_up) {
  EncodedFrame frame;
  const int w = luma.width;
  const int h = luma.height;
  int bytes_per_pixel = 1;
  switch (format) {
    case PixelFormat::kYUY2:
    case PixelFormat::kUYVY:
      bytes_per_pixel = 2;
      break;
    case PixelFormat::kRGB24:
      bytes_per_pixel = 3;
      break;
    case PixelFormat::kRGB32:
      bytes_per_pixel = 4;
      break;
    default:
      break;
  }
  // Pad rows like real drivers do, so stride handling is exercised.
  const int stride = w * bytes_per_pixel + 32;
  const bool planar = format == PixelFormat::kNV12 ||
                      format == PixelFormat::kI420 ||
                      format == PixelFormat::kYV12;
  frame.bytes.assign(static_cast<size_t>(stride) * h * (planar ? 3 : 2) / 2 +
                         static_cast<size_t>(stride),
                     128);
  for (int y = 0; y < h; ++y) {
    // Bottom-up images store the top row last.
    const int stored_row = bottom_up ? h - 1 - y : y;
    uint8_t* out = frame.bytes.data() + static_cast<size_t>(stored_row) * stride;
    const uint8_t* in = luma.row(y);
    for (int x = 0; x < w; ++x) {
      switch (format) {
        case PixelFormat::kGray8:
        case PixelFormat::kNV12:
        case PixelFormat::kI420:
        case PixelFormat::kYV12:
          out[x] = in[x];
          break;
        case PixelFormat::kYUY2:
          out[2 * x] = in[x];
          out[2 * x + 1] = 128;
          break;
        case PixelFormat::kUYVY:
          out[2 * x] = 128;
          out[2 * x + 1] = in[x];
          break;
        case PixelFormat::kRGB24:
          out[3 * x] = out[3 * x + 1] = out[3 * x + 2] = in[x];
          break;
        case PixelFormat::kRGB32:
          out[4 * x] = out[4 * x + 1] = out[4 * x + 2] = in[x];
          out[4 * x + 3] = 255;
          break;
        case PixelFormat::kUnknown:
          break;
      }
    }
  }
  frame.buffer.format = format;
  frame.buffer.width = w;
  frame.buffer.height = h;
  frame.buffer.stride = bottom_up ? -stride : stride;
  frame.buffer.data = bottom_up
                          ? frame.bytes.data() + static_cast<size_t>(h - 1) * stride
                          : frame.bytes.data();
  return frame;
}

class SyntheticSession final : public CaptureSession {
 public:
  SyntheticSession(const Recipe& recipe, StreamInfo info, FrameSink& sink)
      : info_(std::move(info)),
        sink_(sink),
        frame_(Encode(RenderScene(recipe.scene), recipe.pixel, recipe.bottom_up)),
        recipe_(recipe) {
    thread_ = std::thread(&SyntheticSession::Run, this);
  }

  ~SyntheticSession() override {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stop_ = true;
    }
    wake_.notify_all();
    thread_.join();
  }

  const StreamInfo& info() const override { return info_; }

 private:
  void Run() {
    const auto interval = std::chrono::microseconds(1000000 / recipe_.fps);
    auto next = std::chrono::steady_clock::now();
    int delivered = 0;
    while (true) {
      next += interval;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        if (wake_.wait_until(lock, next, [&] { return stop_; })) return;
      }
      ++delivered;
      if (recipe_.lose_after > 0 && delivered > recipe_.lose_after) {
        sink_.OnStreamFailure({CaptureError::kDeviceLost, "synthetic unplug"});
        return;
      }
      if (recipe_.stall_after > 0 && delivered > recipe_.stall_after) continue;
      sink_.OnFrame(frame_.buffer);
    }
  }

  StreamInfo info_;
  FrameSink& sink_;
  EncodedFrame frame_;
  Recipe recipe_;
  std::mutex mutex_;
  std::condition_variable wake_;
  bool stop_ = false;
  std::thread thread_;
};

class SyntheticBackend final : public CaptureBackend {
 public:
  bool supported() const override { return true; }

  std::unique_ptr<ThreadScope> EnterThread() override {
    return std::make_unique<ThreadScope>();
  }

  std::vector<DeviceInfo> ListDevices(CaptureFailure&) override {
    return {
        {"synthetic:ean13=3600523434725", "Synthetic EAN-13"},
        {"synthetic:qr=pointy-synthetic-qr", "Synthetic QR"},
        {"synthetic:blank", "Synthetic empty counter"},
    };
  }

  std::unique_ptr<CaptureSession> Open(const OpenRequest& request,
                                       FrameSink& sink,
                                       CaptureFailure& failure) override {
    DeviceInfo device;
    bool substituted = false;
    if (StartsWith(request.device_id, kPrefix)) {
      device = {request.device_id, "Synthetic camera"};
    } else {
      CaptureFailure list_failure;
      const auto devices = ListDevices(list_failure);
      const auto choice = ChooseDevice(devices, request.device_id);
      if (choice.failure) {
        failure = choice.failure;
        return nullptr;
      }
      device = devices[static_cast<size_t>(choice.index)];
      substituted = choice.substituted;
    }
    const auto recipe = Parse(device.id);
    if (!recipe.fail.empty()) {
      failure = {FailureFor(recipe.fail), "synthetic failure: " + recipe.fail};
      return nullptr;
    }
    StreamInfo info;
    info.device_id = device.id;
    info.device_label = device.label;
    info.width = recipe.scene.width;
    info.height = recipe.scene.height;
    info.fps = recipe.fps;
    info.pixel_format = PixelFormatName(recipe.pixel);
    info.substituted = substituted;
    return std::make_unique<SyntheticSession>(recipe, std::move(info), sink);
  }
};

}  // namespace

std::unique_ptr<CaptureBackend> CreatePlatformBackend() {
  return std::make_unique<SyntheticBackend>();
}

}  // namespace pcw
