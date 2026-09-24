#include "engine/wedge_engine.h"

#include <algorithm>
#include <utility>

#include "engine/thread_util.h"
#include "vision/barcode_reader.h"
#include "vision/luma_extract.h"
#include "vision/transform.h"

namespace pcw {
namespace {

using std::chrono::milliseconds;

int64_t NowNanos() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             Clock::now().time_since_epoch())
      .count();
}

}  // namespace

WedgeEngine::WedgeEngine(std::shared_ptr<CaptureBackend> backend,
                         std::shared_ptr<EventSink> sink, Options options)
    : backend_(std::move(backend)),
      sink_(std::move(sink)),
      options_(std::move(options)) {}

WedgeEngine::~WedgeEngine() {
  RequestStop();
  Join();
}

void WedgeEngine::Start() {
  if (capture_thread_.joinable()) return;
  capture_thread_ = std::thread(&WedgeEngine::CaptureLoop, this);
}

void WedgeEngine::RequestStop() {
  stop_requested_.store(true, std::memory_order_release);
  {
    std::lock_guard<std::mutex> lock(supervisor_mutex_);
  }
  supervisor_wake_.notify_all();
  mailbox_.Wake();
}

void WedgeEngine::Join() {
  if (capture_thread_.joinable() &&
      capture_thread_.get_id() != std::this_thread::get_id()) {
    capture_thread_.join();
  }
}

void WedgeEngine::SetPreview(int max_edge, milliseconds interval) {
  preview_interval_ms_.store(std::max<int64_t>(interval.count(), 16));
  preview_max_edge_.store(std::max(0, max_edge));
}

bool WedgeEngine::WaitForStop(milliseconds duration) {
  std::unique_lock<std::mutex> lock(supervisor_mutex_);
  return supervisor_wake_.wait_for(lock, duration, [&] {
    return stop_requested_.load(std::memory_order_acquire);
  });
}

milliseconds WedgeEngine::RetryDelay(const CaptureFailure& failure,
                                     int consecutive_failures) const {
  const int n = std::min(consecutive_failures, 3);
  switch (failure.code) {
    case CaptureError::kNoCamera:
    case CaptureError::kDeviceNotFound:
      // Waiting for someone to plug it in: look often, it is cheap.
      return milliseconds(2000);
    case CaptureError::kAccessDenied:
      // Only a person changing a Windows setting fixes this, and asking the
      // OS over and over is not free (newer builds notify the user when an
      // app is refused the camera). Back off.
      return milliseconds(n == 0 ? 5000 : n == 1 ? 10000 : 30000);
    case CaptureError::kInUse:
      return milliseconds(3000);
    case CaptureError::kDeviceLost:
    case CaptureError::kStalled:
      // Usually a USB hiccup: come straight back, then slow down.
      return milliseconds(1000 * (n + 1));
    case CaptureError::kNone:
      return milliseconds(1000);
    case CaptureError::kNoUsableFormat:
    case CaptureError::kPlatform:
    case CaptureError::kUnsupported:
      break;
  }
  return milliseconds(n == 0 ? 3000 : n == 1 ? 6000 : 10000);
}

void WedgeEngine::Report(WedgeState state, const CaptureFailure& failure,
                         const StreamInfo& stream, milliseconds retry_in) {
  StatusEvent event;
  event.state = state;
  event.failure = failure;
  event.stream = stream;
  event.retry_in = retry_in;
  if (!sink_->OnStatus(event)) RequestStop();
}

void WedgeEngine::OnFrame(const PixelBuffer& frame) {
  if (stop_requested_.load(std::memory_order_acquire)) return;
  const bool published = mailbox_.Publish(
      [&](LumaImage& destination) { return ExtractLuma(frame, destination); });
  if (!published) return;
  frames_captured_.fetch_add(1, std::memory_order_relaxed);
  last_frame_ns_.store(NowNanos(), std::memory_order_release);
  if (!first_frame_seen_.exchange(true)) {
    {
      std::lock_guard<std::mutex> lock(supervisor_mutex_);
    }
    supervisor_wake_.notify_all();
  }
}

void WedgeEngine::OnStreamFailure(const CaptureFailure& failure) {
  {
    std::lock_guard<std::mutex> lock(supervisor_mutex_);
    if (!stream_failure_) stream_failure_ = failure;
  }
  supervisor_wake_.notify_all();
}

void WedgeEngine::CaptureLoop() {
  const auto scope = backend_->EnterThread();
  decoder_thread_ = std::thread(&WedgeEngine::DecoderLoop, this);

  int consecutive_failures = 0;
  while (!stop_requested_.load(std::memory_order_acquire)) {
    Report(WedgeState::kStarting, {}, {}, milliseconds(0));
    {
      std::lock_guard<std::mutex> lock(supervisor_mutex_);
      stream_failure_.reset();
    }
    first_frame_seen_.store(false);

    CaptureFailure failure;
    StreamInfo stream;
    auto session = backend_->Open(options_.open, *this, failure);
    if (session) {
      stream = session->info();
      const auto opened_at = Clock::now();
      bool running_reported = false;
      while (!stop_requested_.load(std::memory_order_acquire)) {
        {
          std::unique_lock<std::mutex> lock(supervisor_mutex_);
          supervisor_wake_.wait_for(lock, milliseconds(250), [&] {
            return stop_requested_.load(std::memory_order_acquire) ||
                   stream_failure_.has_value() ||
                   (first_frame_seen_.load() && !running_reported);
          });
          if (stream_failure_) {
            failure = *stream_failure_;
            break;
          }
        }
        if (stop_requested_.load(std::memory_order_acquire)) break;
        if (first_frame_seen_.load() && !running_reported) {
          running_reported = true;
          consecutive_failures = 0;
          Report(WedgeState::kRunning, {}, stream, milliseconds(0));
          continue;
        }
        // The watchdog: a camera that opened and then went quiet is broken
        // in a way that reports nothing, and a quiet camera looks exactly
        // like an empty counter unless something checks.
        const auto now = Clock::now();
        if (!first_frame_seen_.load()) {
          if (now - opened_at > options_.first_frame_timeout) {
            failure = {CaptureError::kStalled,
                       "the camera opened but sent no picture"};
            break;
          }
        } else {
          const auto last =
              TimePoint(std::chrono::duration_cast<Clock::duration>(
                  std::chrono::nanoseconds(
                      last_frame_ns_.load(std::memory_order_acquire))));
          if (now - last > options_.frame_gap_timeout) {
            failure = {CaptureError::kStalled,
                       "the camera stopped sending pictures"};
            break;
          }
        }
      }
      // Releases the device. The backend guarantees no frame arrives after
      // this returns, so a reopened camera never mixes with a closed one.
      session.reset();
    }
    if (stop_requested_.load(std::memory_order_acquire)) break;

    if (failure.code == CaptureError::kUnsupported) {
      // No backend on this platform: nothing will change by retrying.
      Report(WedgeState::kRecovering, failure, stream, milliseconds(0));
      while (!WaitForStop(milliseconds(60000))) {
      }
      break;
    }
    if (!failure) {
      failure = {CaptureError::kPlatform, "the camera closed unexpectedly"};
    }
    const auto delay = RetryDelay(failure, consecutive_failures++);
    Report(WedgeState::kRecovering, failure, stream, delay);
    WaitForStop(delay);
  }

  stop_requested_.store(true, std::memory_order_release);
  mailbox_.Wake();
  if (decoder_thread_.joinable()) decoder_thread_.join();
  // Always last: once the app sees kStopped it releases this engine.
  Report(WedgeState::kStopped, {}, {}, milliseconds(0));
}

void WedgeEngine::DecoderLoop() {
  LowerCurrentThreadPriority();

  BarcodeReader reader;
  ConfirmationPolicy policy(options_.policy);
  DecodeScheduler scheduler(options_.scheduler);
  MotionDetector motion;
  LumaImage frame;
  LumaImage preview;

  StatsEvent stats;
  uint64_t frames_at_last_stats = 0;
  uint64_t decodes_in_interval = 0;
  double decode_ms_in_interval = 0;
  auto last_stats_at = Clock::now();
  auto next_stats_at = last_stats_at + options_.stats_interval;
  TimePoint last_preview_at{};

  while (!stop_requested_.load(std::memory_order_acquire)) {
    const auto wait_until =
        std::min(next_stats_at, Clock::now() + milliseconds(250));
    const bool got = mailbox_.WaitTake(frame, wait_until, stop_requested_);
    const auto now = Clock::now();

    if (now >= next_stats_at) {
      const auto frames = frames_captured_.load(std::memory_order_relaxed);
      const double seconds =
          std::chrono::duration<double>(now - last_stats_at).count();
      stats.frames_captured = frames;
      stats.capture_fps =
          seconds > 0 ? (frames - frames_at_last_stats) / seconds : 0;
      stats.decode_ms_average =
          decodes_in_interval ? decode_ms_in_interval / decodes_in_interval : 0;
      stats.rejected_disagreements = policy.rejected_disagreements();
      stats.suppressed_rereads = policy.suppressed_rereads();
      stats.active = scheduler.active(now);
      if (!sink_->OnStats(stats)) RequestStop();
      frames_at_last_stats = frames;
      decodes_in_interval = 0;
      decode_ms_in_interval = 0;
      last_stats_at = now;
      next_stats_at = now + options_.stats_interval;
    }
    if (!got) continue;

    const int preview_edge = preview_max_edge_.load();
    if (preview_edge > 0 &&
        now - last_preview_at >=
            milliseconds(preview_interval_ms_.load())) {
      Downscale(frame, preview_edge, preview);
      if (!sink_->OnPreview(preview)) RequestStop();
      last_preview_at = now;
    }

    if (motion.Update(frame)) scheduler.OnMotion(now);
    if (!scheduler.ShouldDecode(now)) continue;

    const auto attempt = scheduler.NextAttempt();
    const auto started = Clock::now();
    const auto readings = reader.Read(frame, attempt);
    const auto finished = Clock::now();

    ++stats.frames_decoded;
    ++decodes_in_interval;
    decode_ms_in_interval +=
        std::chrono::duration<double, std::milli>(finished - started).count();
    if (!readings.empty()) ++stats.decode_hits;
    scheduler.OnDecoded(finished, !readings.empty());

    if (auto scan = policy.OfferFrame(readings, frame.captured_at)) {
      ++stats.scans;
      if (!sink_->OnScan(*scan)) RequestStop();
    }
  }
}

}  // namespace pcw
