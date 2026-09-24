// The C ABI: include/pointy_camera_wedge.h.
#include "include/pointy_camera_wedge.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include "api/dart_port_sink.h"
#include "capture/capture_backend.h"
#include "dart_api_dl.h"
#include "engine/wedge_engine.h"

struct pcw_wedge {
  std::shared_ptr<pcw::DartPortSink> sink;
  std::unique_ptr<pcw::WedgeEngine> engine;
};

namespace {

std::atomic<bool> g_initialized{false};

// Every wedge not yet released, so one whose Dart side vanished without
// releasing it (a hot restart, an isolate that died) can be found and shut
// down before a new one asks for the same camera.
std::mutex g_registry_mutex;
std::vector<pcw_wedge*> g_wedges;

// A field of pcw_options the caller's struct actually contains.
#define PCW_HAS_FIELD(options, field)                                 \
  (static_cast<size_t>((options)->struct_size) >=                     \
   offsetof(pcw_options, field) + sizeof((options)->field))

int32_t OrDefault(int32_t value, int32_t fallback) {
  return value > 0 ? value : fallback;
}

pcw::WedgeEngine::Options EngineOptions(const pcw_options* options) {
  pcw::WedgeEngine::Options engine;
  if (options == nullptr) return engine;
  if (PCW_HAS_FIELD(options, device_id) && options->device_id != nullptr) {
    engine.open.device_id = options->device_id;
  }
  if (PCW_HAS_FIELD(options, preferred_width)) {
    engine.open.preferred_width = OrDefault(options->preferred_width, 1280);
  }
  if (PCW_HAS_FIELD(options, preferred_height)) {
    engine.open.preferred_height = OrDefault(options->preferred_height, 720);
  }
  if (PCW_HAS_FIELD(options, agreement_window_ms)) {
    engine.policy.agreement_window =
        std::chrono::milliseconds(OrDefault(options->agreement_window_ms, 600));
  }
  if (PCW_HAS_FIELD(options, reread_holdoff_ms)) {
    engine.policy.reread_holdoff =
        std::chrono::milliseconds(OrDefault(options->reread_holdoff_ms, 1500));
  }
  if (PCW_HAS_FIELD(options, stats_interval_ms)) {
    engine.stats_interval =
        std::chrono::milliseconds(OrDefault(options->stats_interval_ms, 1000));
  }
  return engine;
}

void Destroy(pcw_wedge* wedge) {
  wedge->engine->RequestStop();
  wedge->engine->Join();
  delete wedge;
}

// Shut down every wedge whose port is closed. Called before a new wedge
// starts: after a hot restart the old isolate is gone but its camera is still
// open, and the new wedge would otherwise find it in use.
void ReapOrphans() {
  std::vector<pcw_wedge*> orphans;
  {
    std::lock_guard<std::mutex> lock(g_registry_mutex);
    auto alive_end = std::partition(
        g_wedges.begin(), g_wedges.end(),
        [](pcw_wedge* wedge) { return wedge->sink->Alive(); });
    orphans.assign(alive_end, g_wedges.end());
    g_wedges.erase(alive_end, g_wedges.end());
  }
  for (auto* orphan : orphans) Destroy(orphan);
}

}  // namespace

extern "C" {

PCW_API int32_t pcw_abi_version(void) { return PCW_ABI_VERSION; }

PCW_API int32_t pcw_initialize(void* dart_api_dl_data) {
  if (dart_api_dl_data == nullptr) return -1;
  if (Dart_InitializeApiDL(dart_api_dl_data) != 0) return -1;
  g_initialized.store(true, std::memory_order_release);
  return 0;
}

PCW_API int32_t pcw_is_supported(void) {
  return pcw::CreatePlatformBackend()->supported() ? 1 : 0;
}

PCW_API int32_t pcw_list_devices(int64_t reply_port) {
  if (!g_initialized.load(std::memory_order_acquire)) return -1;
  // Enumerating can take a while on some drivers and needs the platform's
  // per-thread set-up (COM), so it never runs on the caller's thread.
  std::thread([reply_port] {
    auto backend = pcw::CreatePlatformBackend();
    pcw::CaptureFailure failure;
    std::vector<pcw::DeviceInfo> devices;
    if (backend->supported()) {
      const auto scope = backend->EnterThread();
      devices = backend->ListDevices(failure);
    } else {
      failure = {pcw::CaptureError::kUnsupported,
                 "no camera backend on this platform"};
    }
    pcw::DartPortSink(reply_port).PostDevices(devices, failure);
  }).detach();
  return 0;
}

PCW_API pcw_wedge* pcw_start(const pcw_options* options, int64_t event_port) {
  if (!g_initialized.load(std::memory_order_acquire)) return nullptr;
  ReapOrphans();

  auto* wedge = new pcw_wedge;
  wedge->sink = std::make_shared<pcw::DartPortSink>(event_port);
  wedge->engine = std::make_unique<pcw::WedgeEngine>(
      pcw::CreatePlatformBackend(), wedge->sink, EngineOptions(options));
  {
    std::lock_guard<std::mutex> lock(g_registry_mutex);
    g_wedges.push_back(wedge);
  }
  wedge->engine->Start();
  return wedge;
}

PCW_API void pcw_set_preview(pcw_wedge* wedge, int32_t max_edge,
                             int32_t interval_ms) {
  if (wedge == nullptr) return;
  wedge->engine->SetPreview(
      max_edge, std::chrono::milliseconds(OrDefault(interval_ms, 100)));
}

PCW_API void pcw_stop(pcw_wedge* wedge) {
  if (wedge == nullptr) return;
  wedge->engine->RequestStop();
}

PCW_API void pcw_release(pcw_wedge* wedge) {
  if (wedge == nullptr) return;
  {
    std::lock_guard<std::mutex> lock(g_registry_mutex);
    g_wedges.erase(std::remove(g_wedges.begin(), g_wedges.end(), wedge),
                   g_wedges.end());
  }
  Destroy(wedge);
}

}  // extern "C"
