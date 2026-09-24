// camera_wedge_probe: the wedge's engine on its own, in a console.
//
// For checking a real camera on a real till without building or installing
// the app. The same capture backend, decoder and confirmation policy the app
// loads; a sink that prints instead of posting to Dart.
//
//   camera_wedge_probe --list
//   camera_wedge_probe [--device N|ID] [--seconds S] [--size 1280x720]
//                      [--snapshot frame.pgm]
//
// Every confirmed scan is printed as it happens, with how long after the
// previous one it came; a stats line every second shows frames delivered and
// decoded, how long a decode pass takes, and what was rejected. --snapshot
// writes the newest frame as a greyscale PGM (any image viewer opens it), to
// see whether the camera is aimed and in focus.
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>

#include "capture/capture_backend.h"
#include "engine/event_sink.h"
#include "engine/wedge_engine.h"

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

namespace {

using std::chrono::milliseconds;

const char* StateName(pcw::WedgeState state) {
  switch (state) {
    case pcw::WedgeState::kStarting:
      return "starting";
    case pcw::WedgeState::kRunning:
      return "running";
    case pcw::WedgeState::kRecovering:
      return "recovering";
    case pcw::WedgeState::kStopped:
      return "stopped";
  }
  return "?";
}

const char* ErrorName(pcw::CaptureError error) {
  switch (error) {
    case pcw::CaptureError::kNone:
      return "none";
    case pcw::CaptureError::kNoCamera:
      return "no camera";
    case pcw::CaptureError::kDeviceNotFound:
      return "chosen camera not connected";
    case pcw::CaptureError::kAccessDenied:
      return "blocked by the Windows camera privacy setting";
    case pcw::CaptureError::kInUse:
      return "in use by another program";
    case pcw::CaptureError::kDeviceLost:
      return "disconnected";
    case pcw::CaptureError::kNoUsableFormat:
      return "no usable format";
    case pcw::CaptureError::kStalled:
      return "stopped sending frames";
    case pcw::CaptureError::kPlatform:
      return "platform error";
    case pcw::CaptureError::kUnsupported:
      return "unsupported platform";
  }
  return "?";
}

class PrintingSink final : public pcw::EventSink {
 public:
  explicit PrintingSink(std::string snapshot_path)
      : snapshot_path_(std::move(snapshot_path)) {}

  bool OnStatus(const pcw::StatusEvent& event) override {
    std::lock_guard<std::mutex> lock(mutex_);
    std::cout << Stamp() << "status " << StateName(event.state);
    if (event.failure) {
      std::cout << ": " << ErrorName(event.failure.code) << " (" << event.failure.message
                << ")";
    }
    if (!event.stream.device_label.empty()) {
      std::cout << " | " << event.stream.device_label << " " << event.stream.width << "x"
                << event.stream.height << " @" << event.stream.fps << "fps "
                << event.stream.pixel_format
                << (event.stream.substituted ? " (substituted)" : "");
    }
    if (event.retry_in.count() > 0) {
      std::cout << " | retry in " << event.retry_in.count() << " ms";
    }
    std::cout << std::endl;
    return true;
  }

  bool OnScan(const pcw::Scan& scan) override {
    std::lock_guard<std::mutex> lock(mutex_);
    std::cout << Stamp() << "SCAN " << scan.symbology << " \"" << scan.text << "\" ("
              << scan.confirmations << " look" << (scan.confirmations == 1 ? "" : "s")
              << ")" << std::endl;
    return true;
  }

  bool OnStats(const pcw::StatsEvent& stats) override {
    std::lock_guard<std::mutex> lock(mutex_);
    std::printf(
        "%sstats %.1f fps | decoded %llu of %llu | %.1f ms/pass | hits %llu | "
        "scans %llu | disagreements rejected %llu | re-reads held %llu | %s\n",
        Stamp().c_str(), stats.capture_fps,
        static_cast<unsigned long long>(stats.frames_decoded),
        static_cast<unsigned long long>(stats.frames_captured), stats.decode_ms_average,
        static_cast<unsigned long long>(stats.decode_hits),
        static_cast<unsigned long long>(stats.scans),
        static_cast<unsigned long long>(stats.rejected_disagreements),
        static_cast<unsigned long long>(stats.suppressed_rereads),
        stats.active ? "active" : "idle");
    std::fflush(stdout);
    return true;
  }

  bool OnPreview(const pcw::LumaImage& frame) override {
    if (snapshot_path_.empty() || snapshot_written_.exchange(true)) return true;
    std::ofstream out(snapshot_path_, std::ios::binary);
    out << "P5\n" << frame.width << " " << frame.height << "\n255\n";
    out.write(reinterpret_cast<const char*>(frame.pixels.data()),
              static_cast<std::streamsize>(frame.pixels.size()));
    std::lock_guard<std::mutex> lock(mutex_);
    std::cout << Stamp() << "wrote " << frame.width << "x" << frame.height << " frame to "
              << snapshot_path_ << std::endl;
    return true;
  }

 private:
  std::string Stamp() const {
    const auto ms = std::chrono::duration_cast<milliseconds>(
                        std::chrono::steady_clock::now() - started_)
                        .count();
    char text[32];
    std::snprintf(text, sizeof(text), "[%7.3fs] ", ms / 1000.0);
    return text;
  }

  const std::chrono::steady_clock::time_point started_ = std::chrono::steady_clock::now();
  std::string snapshot_path_;
  std::atomic<bool> snapshot_written_{false};
  std::mutex mutex_;
};

int ListDevices(pcw::CaptureBackend& backend) {
  const auto scope = backend.EnterThread();
  pcw::CaptureFailure failure;
  const auto devices = backend.ListDevices(failure);
  if (failure) {
    std::cout << "could not list cameras: " << failure.message << std::endl;
    return 1;
  }
  if (devices.empty()) std::cout << "no cameras found" << std::endl;
  for (size_t i = 0; i < devices.size(); ++i) {
    std::cout << i << ": " << devices[i].label << "\n   " << devices[i].id << std::endl;
  }
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
#if defined(_WIN32)
  SetConsoleOutputCP(CP_UTF8);
#endif
  std::string device;
  std::string snapshot;
  int seconds = 60;
  pcw::WedgeEngine::Options options;
  auto backend = std::shared_ptr<pcw::CaptureBackend>(pcw::CreatePlatformBackend());

  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    const bool has_value = i + 1 < argc;
    if (arg == "--list") return ListDevices(*backend);
    if (arg == "--device" && has_value) device = argv[++i];
    else if (arg == "--seconds" && has_value) seconds = std::atoi(argv[++i]);
    else if (arg == "--snapshot" && has_value) snapshot = argv[++i];
    else if (arg == "--size" && has_value) {
      const std::string size = argv[++i];
      const auto x = size.find('x');
      if (x != std::string::npos) {
        options.open.preferred_width = std::atoi(size.substr(0, x).c_str());
        options.open.preferred_height = std::atoi(size.substr(x + 1).c_str());
      }
    } else {
      std::cout << "usage: camera_wedge_probe --list\n"
                   "       camera_wedge_probe [--device N|ID] [--seconds S] "
                   "[--size WxH] [--snapshot frame.pgm]\n";
      return arg == "--help" ? 0 : 2;
    }
  }

  // A number picks from --list's order; anything else is an id.
  if (!device.empty() && device.find_first_not_of("0123456789") == std::string::npos) {
    const auto scope = backend->EnterThread();
    pcw::CaptureFailure failure;
    const auto devices = backend->ListDevices(failure);
    const auto index = static_cast<size_t>(std::atoi(device.c_str()));
    if (index >= devices.size()) {
      std::cout << "no camera number " << index << " (see --list)" << std::endl;
      return 2;
    }
    device = devices[index].id;
  }
  options.open.device_id = device;

  auto sink = std::make_shared<PrintingSink>(snapshot);
  pcw::WedgeEngine engine(backend, sink, options);
  if (!snapshot.empty()) engine.SetPreview(1 << 14, milliseconds(1000));
  engine.Start();
  std::cout << "watching for " << seconds << " s; put barcodes under the camera" << std::endl;
  std::this_thread::sleep_for(std::chrono::seconds(seconds));
  engine.RequestStop();
  engine.Join();
  return 0;
}
