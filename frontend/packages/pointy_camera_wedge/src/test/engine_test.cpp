// The whole wedge — threads, capture, decoding, confirmation, recovery — on a
// drawn camera. Real time, real threads; the synthetic backend's recipes
// (platform/synthetic/synthetic_backend.cpp) stand in for the counter.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "capture/capture_backend.h"
#include "engine/event_sink.h"
#include "engine/wedge_engine.h"
#include "test/check.h"

namespace {

using pcw::CaptureError;
using pcw::WedgeState;
using std::chrono::milliseconds;

class RecordingSink final : public pcw::EventSink {
 public:
  bool OnStatus(const pcw::StatusEvent& event) override {
    std::lock_guard<std::mutex> lock(mutex_);
    statuses.push_back(event);
    changed_.notify_all();
    return listening;
  }
  bool OnScan(const pcw::Scan& scan) override {
    std::lock_guard<std::mutex> lock(mutex_);
    scans.push_back(scan);
    scans_after_stop += stopped() ? 1 : 0;
    changed_.notify_all();
    return listening;
  }
  bool OnStats(const pcw::StatsEvent& event) override {
    std::lock_guard<std::mutex> lock(mutex_);
    stats.push_back(event);
    changed_.notify_all();
    return listening;
  }
  bool OnPreview(const pcw::LumaImage& frame) override {
    std::lock_guard<std::mutex> lock(mutex_);
    previews.push_back({frame.width, frame.height});
    changed_.notify_all();
    return listening;
  }

  template <typename Predicate>
  bool WaitFor(Predicate predicate, milliseconds timeout) {
    std::unique_lock<std::mutex> lock(mutex_);
    return changed_.wait_for(lock, timeout, [&] { return predicate(*this); });
  }

  // Call with the lock held (from a WaitFor predicate) or after Join.
  bool stopped() const {
    return !statuses.empty() && statuses.back().state == WedgeState::kStopped;
  }
  bool saw(WedgeState state, CaptureError error = CaptureError::kNone) const {
    return std::any_of(statuses.begin(), statuses.end(), [&](const auto& s) {
      return s.state == state && s.failure.code == error;
    });
  }
  int count(WedgeState state) const {
    return static_cast<int>(std::count_if(statuses.begin(), statuses.end(),
                                          [&](const auto& s) { return s.state == state; }));
  }

  std::atomic<bool> listening{true};
  std::vector<pcw::StatusEvent> statuses;
  std::vector<pcw::Scan> scans;
  std::vector<pcw::StatsEvent> stats;
  std::vector<std::pair<int, int>> previews;
  int scans_after_stop = 0;

 private:
  std::mutex mutex_;
  std::condition_variable changed_;
};

struct Rig {
  explicit Rig(const std::string& device, pcw::WedgeEngine::Options options = {}) {
    options.open.device_id = device;
    options.stats_interval = milliseconds(200);
    sink = std::make_shared<RecordingSink>();
    engine = std::make_unique<pcw::WedgeEngine>(pcw::CreatePlatformBackend(), sink,
                                                options);
    engine->Start();
  }
  ~Rig() {
    engine->RequestStop();
    engine->Join();
  }
  void Stop() {
    engine->RequestStop();
    engine->Join();
  }

  std::shared_ptr<RecordingSink> sink;
  std::unique_ptr<pcw::WedgeEngine> engine;
};

bool Running(const RecordingSink& s) { return s.saw(WedgeState::kRunning); }

PCW_TEST(a_barcode_under_the_camera_is_scanned_exactly_once) {
  Rig rig("synthetic:ean13=3600523434725;angle=20;pixel=yuy2");
  CHECK(rig.sink->WaitFor(Running, milliseconds(3000)));
  CHECK(rig.sink->WaitFor([](const RecordingSink& s) { return !s.scans.empty(); },
                          milliseconds(3000)));
  // It keeps sitting there, being read many times a second.
  std::this_thread::sleep_for(milliseconds(1200));
  rig.Stop();
  auto& sink = *rig.sink;
  CHECK_EQ(sink.scans.size(), static_cast<size_t>(1));
  CHECK_EQ(sink.scans.front().text, std::string("3600523434725"));
  CHECK_EQ(sink.scans.front().symbology, std::string("EAN13"));
  CHECK(sink.scans.front().confirmations >= 2);
  CHECK(sink.statuses.front().state == WedgeState::kStarting);
  CHECK(sink.stopped());
  CHECK_EQ(sink.scans_after_stop, 0);
}

PCW_TEST(a_qr_is_scanned_on_the_first_look) {
  Rig rig("synthetic:qr=pay://receipt/9f2");
  CHECK(rig.sink->WaitFor([](const RecordingSink& s) { return !s.scans.empty(); },
                          milliseconds(3000)));
  rig.Stop();
  CHECK_EQ(rig.sink->scans.front().text, std::string("pay://receipt/9f2"));
  CHECK_EQ(rig.sink->scans.front().confirmations, 1);
}

PCW_TEST(every_pixel_format_reaches_the_decoder) {
  for (const char* pixel :
       {"gray", "nv12", "yuy2", "uyvy", "rgb24", "rgb32", "rgb32_bottom_up"}) {
    Rig rig(std::string("synthetic:qr=format-") + pixel + ";pixel=" + pixel);
    const bool read = rig.sink->WaitFor(
        [](const RecordingSink& s) { return !s.scans.empty(); }, milliseconds(3000));
    rig.Stop();
    if (!read) pcwtest::Fail(__FILE__, __LINE__, std::string("nothing read as ") + pixel);
    CHECK_EQ(rig.sink->scans.front().text, std::string("format-") + pixel);
  }
}

PCW_TEST(an_empty_counter_scans_nothing_and_decodes_at_the_idle_pace) {
  Rig rig("synthetic:blank;noise=3");
  CHECK(rig.sink->WaitFor(Running, milliseconds(3000)));
  std::this_thread::sleep_for(milliseconds(2000));
  rig.Stop();
  auto& sink = *rig.sink;
  CHECK(sink.scans.empty());
  CHECK(!sink.stats.empty());
  const auto& last = sink.stats.back();
  // 30 fps delivered, ~5 decoded a second: the till's CPU is left alone.
  CHECK(last.frames_captured >= 30);
  CHECK(last.frames_decoded * 3 < last.frames_captured);
}

PCW_TEST(an_unplugged_camera_comes_back_on_its_own) {
  Rig rig("synthetic:qr=replug;lose_after=10");
  CHECK(rig.sink->WaitFor(
      [](const RecordingSink& s) {
        return s.saw(WedgeState::kRecovering, CaptureError::kDeviceLost) &&
               s.count(WedgeState::kRunning) >= 2;
      },
      milliseconds(6000)));
  rig.Stop();
}

PCW_TEST(a_camera_that_goes_quiet_is_restarted) {
  pcw::WedgeEngine::Options options;
  options.frame_gap_timeout = milliseconds(400);
  Rig rig("synthetic:qr=quiet;stall_after=5", options);
  CHECK(rig.sink->WaitFor(
      [](const RecordingSink& s) {
        return s.saw(WedgeState::kRecovering, CaptureError::kStalled);
      },
      milliseconds(4000)));
  rig.Stop();
}

PCW_TEST(a_refused_camera_says_why_and_keeps_trying_slowly) {
  Rig rig("synthetic:fail=access_denied");
  CHECK(rig.sink->WaitFor(
      [](const RecordingSink& s) {
        return s.saw(WedgeState::kRecovering, CaptureError::kAccessDenied);
      },
      milliseconds(3000)));
  rig.Stop();
  const auto recovering = std::find_if(
      rig.sink->statuses.begin(), rig.sink->statuses.end(),
      [](const auto& s) { return s.state == WedgeState::kRecovering; });
  CHECK(recovering->retry_in >= milliseconds(5000));
  CHECK(rig.sink->stopped());
}

PCW_TEST(a_missing_pick_among_several_cameras_is_not_guessed) {
  Rig rig("\\\\?\\usb#vid_0000&pid_0000#gone");
  CHECK(rig.sink->WaitFor(
      [](const RecordingSink& s) {
        return s.saw(WedgeState::kRecovering, CaptureError::kDeviceNotFound);
      },
      milliseconds(3000)));
  rig.Stop();
  CHECK(rig.sink->scans.empty());
}

PCW_TEST(stop_is_prompt_and_nothing_follows_stopped) {
  Rig rig("synthetic:ean13=3600523434725");
  CHECK(rig.sink->WaitFor(Running, milliseconds(3000)));
  const auto started = std::chrono::steady_clock::now();
  rig.Stop();
  const auto took = std::chrono::steady_clock::now() - started;
  CHECK(took < milliseconds(1500));
  CHECK(rig.sink->stopped());
  CHECK_EQ(rig.sink->count(WedgeState::kStopped), 1);
}

PCW_TEST(nobody_listening_releases_the_camera_on_its_own) {
  // The app exited or hot-restarted without stopping the wedge: every post
  // fails from then on, and the camera must not stay held by nobody.
  Rig rig("synthetic:qr=orphan");
  CHECK(rig.sink->WaitFor(Running, milliseconds(3000)));
  rig.sink->listening = false;
  CHECK(rig.sink->WaitFor([](const RecordingSink& s) { return s.stopped(); },
                          milliseconds(3000)));
}

PCW_TEST(preview_frames_flow_only_while_asked_for) {
  Rig rig("synthetic:blank");
  CHECK(rig.sink->WaitFor(Running, milliseconds(3000)));
  std::this_thread::sleep_for(milliseconds(300));
  CHECK(rig.sink->WaitFor([](const RecordingSink& s) { return s.previews.empty(); },
                          milliseconds(10)));
  rig.engine->SetPreview(160, milliseconds(50));
  CHECK(rig.sink->WaitFor([](const RecordingSink& s) { return s.previews.size() >= 3; },
                          milliseconds(2000)));
  rig.engine->SetPreview(0, milliseconds(50));
  std::this_thread::sleep_for(milliseconds(150));
  size_t before = 0;
  rig.sink->WaitFor(
      [&](const RecordingSink& s) {
        before = s.previews.size();
        return true;
      },
      milliseconds(10));
  std::this_thread::sleep_for(milliseconds(400));
  rig.Stop();
  CHECK_EQ(rig.sink->previews.size(), before);
  CHECK_EQ(rig.sink->previews.front().first, 160);
  CHECK_EQ(rig.sink->previews.front().second, 90);
}

}  // namespace
