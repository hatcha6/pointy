#include "api/dart_port_sink.h"

#include <cmath>
#include <deque>

#include "api/utf8.h"
#include "dart_api_dl.h"
#include "include/pointy_camera_wedge.h"

namespace pcw {

// A Dart List under construction. Owns every object and string it points
// at, so the graph stays valid until Dart_PostCObject has copied it.
class DartPortSink::Message {
 public:
  Message& Int(int64_t value) {
    auto& object = New();
    object.type = Dart_CObject_kInt64;
    object.value.as_int64 = value;
    return *this;
  }

  Message& String(const std::string& value) {
    strings_.push_back(SanitizedUtf8(value));
    auto& object = New();
    object.type = Dart_CObject_kString;
    object.value.as_string = strings_.back().c_str();
    return *this;
  }

  Message& Bytes(const uint8_t* data, size_t length) {
    auto& object = New();
    object.type = Dart_CObject_kTypedData;
    object.value.as_typed_data.type = Dart_TypedData_kUint8;
    object.value.as_typed_data.length = static_cast<intptr_t>(length);
    object.value.as_typed_data.values = data;
    return *this;
  }

  // Appends `nested` as a List element. `nested` must outlive the post.
  Message& List(Message& nested) {
    auto& object = New();
    object = *nested.Root();
    return *this;
  }

  Dart_CObject* Root() {
    pointers_.clear();
    for (auto& element : elements_) pointers_.push_back(&element);
    root_.type = Dart_CObject_kArray;
    root_.value.as_array.length = static_cast<intptr_t>(pointers_.size());
    root_.value.as_array.values = pointers_.data();
    return &root_;
  }

 private:
  Dart_CObject& New() {
    elements_.emplace_back();
    return elements_.back();
  }

  // deques: appending never moves what is already there.
  std::deque<Dart_CObject> elements_;
  std::deque<std::string> strings_;
  std::vector<Dart_CObject*> pointers_;
  Dart_CObject root_{};
};

bool DartPortSink::Post(Message& message) {
  if (!alive_.load(std::memory_order_acquire)) return false;
  if (Dart_PostCObject_DL(port_, message.Root())) return true;
  // Rejected. Tell a closed port apart from a message the VM refused: a bare
  // integer always serialises, so if that fails too, nobody is listening.
  if (Dart_PostInteger_DL(port_, 0)) return true;
  alive_.store(false, std::memory_order_release);
  return false;
}

bool DartPortSink::Alive() {
  if (!alive_.load(std::memory_order_acquire)) return false;
  if (Dart_PostInteger_DL(port_, 0)) return true;
  alive_.store(false, std::memory_order_release);
  return false;
}

bool DartPortSink::OnStatus(const StatusEvent& event) {
  Message message;
  message.Int(PCW_MSG_STATUS)
      .Int(static_cast<int64_t>(event.state))
      .Int(static_cast<int64_t>(event.failure.code))
      .String(event.failure.message)
      .String(event.stream.device_id)
      .String(event.stream.device_label)
      .Int(event.stream.width)
      .Int(event.stream.height)
      .Int(std::llround(event.stream.fps * 1000))
      .String(event.stream.pixel_format)
      .Int(event.stream.substituted ? 1 : 0)
      .Int(event.retry_in.count());
  return Post(message);
}

bool DartPortSink::OnScan(const Scan& scan) {
  Message message;
  message.Int(PCW_MSG_SCAN)
      .String(scan.text)
      .String(scan.symbology)
      .Int(scan.confirmations);
  return Post(message);
}

bool DartPortSink::OnStats(const StatsEvent& stats) {
  Message message;
  message.Int(PCW_MSG_STATS)
      .Int(static_cast<int64_t>(stats.frames_captured))
      .Int(static_cast<int64_t>(stats.frames_decoded))
      .Int(static_cast<int64_t>(stats.decode_hits))
      .Int(static_cast<int64_t>(stats.scans))
      .Int(static_cast<int64_t>(stats.rejected_disagreements))
      .Int(static_cast<int64_t>(stats.suppressed_rereads))
      .Int(std::llround(stats.capture_fps * 1000))
      .Int(std::llround(stats.decode_ms_average * 1000))
      .Int(stats.active ? 1 : 0);
  return Post(message);
}

bool DartPortSink::OnPreview(const LumaImage& frame) {
  if (frame.empty()) return true;
  Message message;
  message.Int(PCW_MSG_PREVIEW)
      .Int(frame.width)
      .Int(frame.height)
      .Bytes(frame.pixels.data(), frame.pixels.size());
  return Post(message);
}

bool DartPortSink::PostDevices(const std::vector<DeviceInfo>& devices,
                               const CaptureFailure& failure) {
  Message list;
  for (const auto& device : devices) {
    list.String(device.id).String(device.label);
  }
  Message message;
  message.Int(PCW_MSG_DEVICES)
      .Int(static_cast<int64_t>(failure.code))
      .String(failure.message)
      .List(list);
  return Post(message);
}

}  // namespace pcw
