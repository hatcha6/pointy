// Windows: frames straight out of Media Foundation.
//
// The previous Windows wedge went through camera_windows, which has no image
// stream: it took a PHOTO about once a second, wrote it as a JPEG into the
// user's Pictures folder, and decoded that. This reads the camera's own video
// stream through the Source Reader instead — the same pipeline Windows' own
// Camera app sits on — so a look at the counter costs one frame (~33 ms at
// 30 fps), nothing touches the disk, and a camera Windows can show is a camera
// this can read: every UVC webcam uses the in-box driver Media Foundation
// talks to.
//
// Shape, all from Microsoft's documentation of the Source Reader:
//  * ASYNCHRONOUS mode (MF_SOURCE_READER_ASYNC_CALLBACK). Frames arrive on a
//    Media Foundation worker thread in ReaderCallback::OnReadSample, which
//    copies the luminance out and asks for the next one. A synchronous
//    ReadSample can block for as long as a broken driver likes; this never
//    blocks anything, so stopping is always possible (Flush, then OnFlush).
//  * The camera's own mode is chosen explicitly (resolution, frame rate,
//    format — see Score) and set as the NATIVE type first; only then is a
//    decoded output type asked for, when the camera only offers MJPEG at a
//    useful size. Setting only an output type leaves the reader free to pick
//    any native mode that converts, which is how a camera ends up at 640x480.
//  * E_ACCESSDENIED from ActivateObject is the Windows camera privacy switch
//    ("Let desktop apps access your camera"), not a broken camera, and is
//    reported as such.
//
// Works back to Windows 7 (the Source Reader's first release): attributes a
// newer Windows understands and an older one does not are simply ignored.
#include <windows.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <strmif.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "capture/capture_backend.h"
#include "capture/device_selection.h"

#ifndef MF_E_VIDEO_DEVICE_LOCKED
#define MF_E_VIDEO_DEVICE_LOCKED _HRESULT_TYPEDEF_(0xC00D4E24L)
#endif

namespace pcw {
namespace {

// Spelled out rather than taken from the SDK headers, which only declare them
// when building for Windows 8 or later (WINVER >= 0x0602) — and a Windows 7
// build is exactly where the OS ignoring them is harmless. Values as in
// mfapi.h / mfreadwrite.h.
constexpr GUID kLowLatency = {0x9c27891a, 0xed7a, 0x40e1,
                              {0x88, 0xe8, 0xb2, 0x27, 0x27, 0xa0, 0x24, 0xee}};
constexpr GUID kAdvancedVideoProcessing = {
    0x0f81da2c, 0xb537, 0x4672, {0xa8, 0xb2, 0xa6, 0x81, 0xb1, 0x73, 0x07, 0xa3}};
// MFVideoFormat_L8: 8-bit luminance, D3DFMT_L8 (50) in the standard base GUID.
constexpr GUID kVideoFormatL8 = {0x00000032, 0x0000, 0x0010,
                                 {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}};

// ---------------------------------------------------------------------------
// Small COM helpers. A minimal owning pointer rather than WRL, so the same
// file builds unchanged with MSVC and with MinGW.

template <typename T>
class ComPtr {
 public:
  ComPtr() = default;
  ComPtr(const ComPtr& other) : ptr_(other.ptr_) {
    if (ptr_) ptr_->AddRef();
  }
  ComPtr(ComPtr&& other) noexcept : ptr_(std::exchange(other.ptr_, nullptr)) {}
  ~ComPtr() { Reset(); }
  ComPtr& operator=(ComPtr other) noexcept {
    std::swap(ptr_, other.ptr_);
    return *this;
  }

  // Takes ownership of an already-counted reference.
  static ComPtr Attach(T* raw) {
    ComPtr result;
    result.ptr_ = raw;
    return result;
  }

  void Reset() {
    if (ptr_) std::exchange(ptr_, nullptr)->Release();
  }
  T* get() const { return ptr_; }
  T* operator->() const { return ptr_; }
  explicit operator bool() const { return ptr_ != nullptr; }
  T** Out() {
    Reset();
    return &ptr_;
  }
  template <typename U>
  HRESULT As(ComPtr<U>& out) const {
    return ptr_ ? ptr_->QueryInterface(__uuidof(U), reinterpret_cast<void**>(out.Out()))
                : E_POINTER;
  }

 private:
  T* ptr_ = nullptr;
};

std::string Utf8(const wchar_t* wide) {
  if (wide == nullptr || *wide == L'\0') return {};
  const int length = WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
  if (length <= 1) return {};
  std::string out(static_cast<size_t>(length - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide, -1, out.data(), length, nullptr, nullptr);
  return out;
}

std::string Hex(HRESULT hr) {
  char text[16];
  std::snprintf(text, sizeof(text), "0x%08lX", static_cast<unsigned long>(hr));
  return text;
}

// What an HRESULT means to a shop. A table rather than a switch because
// HRESULT_FROM_WIN32 is an inline function, not a constant, when the SDK is
// built with INLINE_HRESULT_FROM_WIN32.
CaptureFailure Failure(HRESULT hr, const char* doing) {
  struct Known {
    HRESULT hr;
    CaptureError code;
  };
  const Known known[] = {
      {E_ACCESSDENIED, CaptureError::kAccessDenied},
      {MF_E_HW_MFT_FAILED_START_STREAMING, CaptureError::kInUse},
      {MF_E_VIDEO_RECORDING_DEVICE_PREEMPTED, CaptureError::kInUse},
      {MF_E_VIDEO_DEVICE_LOCKED, CaptureError::kInUse},
      {HRESULT_FROM_WIN32(ERROR_SHARING_VIOLATION), CaptureError::kInUse},
      {HRESULT_FROM_WIN32(ERROR_BUSY), CaptureError::kInUse},
      {HRESULT_FROM_WIN32(ERROR_DEVICE_IN_USE), CaptureError::kInUse},
      {MF_E_VIDEO_RECORDING_DEVICE_INVALIDATED, CaptureError::kDeviceLost},
      {MF_E_SHUTDOWN, CaptureError::kDeviceLost},
      {HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED), CaptureError::kDeviceLost},
      {HRESULT_FROM_WIN32(ERROR_DEVICE_REMOVED), CaptureError::kDeviceLost},
      {HRESULT_FROM_WIN32(ERROR_GEN_FAILURE), CaptureError::kDeviceLost},
      {HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND), CaptureError::kDeviceLost},
  };
  CaptureError code = CaptureError::kPlatform;
  for (const auto& entry : known) {
    if (entry.hr == hr) {
      code = entry.code;
      break;
    }
  }
  return {code, std::string(doing) + " failed (" + Hex(hr) + ")"};
}

// COM and Media Foundation for one thread, released when the thread is done.
class MfThreadScope final : public ThreadScope {
 public:
  MfThreadScope() {
    com_ = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    mf_ = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
  }
  ~MfThreadScope() override {
    if (SUCCEEDED(mf_)) MFShutdown();
    // S_FALSE (already initialised) must be balanced too; RPC_E_CHANGED_MODE
    // (someone else's apartment) must not.
    if (SUCCEEDED(com_)) CoUninitialize();
  }

 private:
  HRESULT com_ = E_FAIL;
  HRESULT mf_ = E_FAIL;
};

// ---------------------------------------------------------------------------
// Devices.

struct MfDevice {
  DeviceInfo info;
  ComPtr<IMFActivate> activate;
};

std::string AllocatedString(IMFActivate* activate, REFGUID key) {
  WCHAR* value = nullptr;
  UINT32 length = 0;
  if (FAILED(activate->GetAllocatedString(key, &value, &length))) return {};
  auto text = Utf8(value);
  CoTaskMemFree(value);
  return text;
}

HRESULT EnumerateDevices(std::vector<MfDevice>& out) {
  out.clear();
  ComPtr<IMFAttributes> attributes;
  HRESULT hr = MFCreateAttributes(attributes.Out(), 1);
  if (FAILED(hr)) return hr;
  hr = attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                           MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  if (FAILED(hr)) return hr;
  IMFActivate** devices = nullptr;
  UINT32 count = 0;
  hr = MFEnumDeviceSources(attributes.get(), &devices, &count);
  if (FAILED(hr)) return hr;
  for (UINT32 i = 0; i < count; ++i) {
    auto activate = ComPtr<IMFActivate>::Attach(devices[i]);
    MfDevice device;
    device.info.id = AllocatedString(
        activate.get(), MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK);
    device.info.label =
        AllocatedString(activate.get(), MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME);
    if (device.info.id.empty()) continue;
    if (device.info.label.empty()) device.info.label = device.info.id;
    device.activate = std::move(activate);
    out.push_back(std::move(device));
  }
  CoTaskMemFree(devices);
  return S_OK;
}

// ---------------------------------------------------------------------------
// Formats.

// {FOURCC-0000-0010-8000-00AA00389B71}: how Media Foundation names a video
// subtype that has a FourCC. Y800 has no MFVideoFormat_ constant of its own.
GUID SubtypeFromFourCC(DWORD fourcc) {
  return GUID{fourcc, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}};
}
constexpr DWORD FourCC(char a, char b, char c, char d) {
  return static_cast<DWORD>(static_cast<unsigned char>(a)) |
         (static_cast<DWORD>(static_cast<unsigned char>(b)) << 8) |
         (static_cast<DWORD>(static_cast<unsigned char>(c)) << 16) |
         (static_cast<DWORD>(static_cast<unsigned char>(d)) << 24);
}

// A subtype this library reads directly (its luminance is right there).
PixelFormat DirectFormat(const GUID& subtype) {
  if (subtype == MFVideoFormat_NV12) return PixelFormat::kNV12;
  if (subtype == MFVideoFormat_YUY2) return PixelFormat::kYUY2;
  if (subtype == MFVideoFormat_UYVY) return PixelFormat::kUYVY;
  if (subtype == MFVideoFormat_I420 || subtype == MFVideoFormat_IYUV) {
    return PixelFormat::kI420;
  }
  if (subtype == MFVideoFormat_YV12) return PixelFormat::kYV12;
  if (subtype == kVideoFormatL8 ||
      subtype == SubtypeFromFourCC(FourCC('Y', '8', '0', '0')) ||
      subtype == SubtypeFromFourCC(FourCC('G', 'R', 'E', 'Y'))) {
    return PixelFormat::kGray8;
  }
  if (subtype == MFVideoFormat_RGB32 || subtype == MFVideoFormat_ARGB32) {
    return PixelFormat::kRGB32;
  }
  if (subtype == MFVideoFormat_RGB24) return PixelFormat::kRGB24;
  return PixelFormat::kUnknown;
}

std::string SubtypeName(const GUID& subtype) {
  const auto direct = DirectFormat(subtype);
  if (direct != PixelFormat::kUnknown) return PixelFormatName(direct);
  if (subtype == MFVideoFormat_MJPG) return "MJPG";
  // Any other FourCC subtype: print its four characters.
  const auto fourcc = subtype.Data1;
  if (subtype == SubtypeFromFourCC(fourcc)) {
    std::string name;
    for (int shift = 0; shift < 32; shift += 8) {
      const char c = static_cast<char>((fourcc >> shift) & 0xFF);
      name.push_back(c >= 32 && c < 127 ? c : '?');
    }
    return name;
  }
  return "other";
}

struct Mode {
  ComPtr<IMFMediaType> type;
  GUID subtype{};
  UINT32 width = 0;
  UINT32 height = 0;
  double fps = 0;
  double score = 0;
};

double FrameRate(IMFMediaType* type) {
  UINT32 numerator = 0;
  UINT32 denominator = 0;
  if (FAILED(MFGetAttributeRatio(type, MF_MT_FRAME_RATE, &numerator, &denominator)) ||
      denominator == 0) {
    return 0;
  }
  return static_cast<double>(numerator) / denominator;
}

// Lower is better. The ideal is the preferred size (1280x720 by default: the
// camera lab's working resolution, fine enough for a narrow bar at counter
// distance and cheap enough to decode every frame), at least 15 frames a
// second, in a format read directly. Smaller than asked costs twice what
// larger does — resolution is what a 1-D barcode lives or dies by — and a
// frame rate under 15 costs most of all: agreement between looks has to
// arrive inside 600 ms.
double Score(const Mode& mode, int preferred_width, int preferred_height) {
  const double preferred_area =
      static_cast<double>(std::max(1, preferred_width)) * std::max(1, preferred_height);
  const double ratio = static_cast<double>(mode.width) * mode.height / preferred_area;
  double score = ratio >= 1 ? (ratio - 1) : (1 / std::max(ratio, 1e-6) - 1) * 2;
  if (mode.fps < 14.5) {
    score += 8 + (15 - mode.fps);
  } else {
    score += (30 - std::min(mode.fps, 30.0)) / 30 * 0.6;
  }
  if (DirectFormat(mode.subtype) != PixelFormat::kUnknown) {
    // Read as delivered: no decoder, no copy.
  } else if (mode.subtype == MFVideoFormat_MJPG) {
    // Decoding MJPEG costs CPU; worth it only when the camera cannot send
    // the size uncompressed fast enough (USB 2 cannot, at 720p30).
    score += 0.25;
  } else {
    // H.264 and friends: possible, but the decode is heavy for a till.
    score += 5;
  }
  return score;
}

// ---------------------------------------------------------------------------
// The session.

class MfSession;

// Receives the Source Reader's asynchronous results. COM reference counted;
// may outlive the session briefly, so everything it touches of the session
// goes through `owner_`, cleared under the lock before the session dies.
class ReaderCallback final : public IMFSourceReaderCallback {
 public:
  STDMETHODIMP QueryInterface(REFIID iid, void** out) override {
    if (out == nullptr) return E_POINTER;
    if (iid == __uuidof(IUnknown) || iid == __uuidof(IMFSourceReaderCallback)) {
      *out = static_cast<IMFSourceReaderCallback*>(this);
      AddRef();
      return S_OK;
    }
    *out = nullptr;
    return E_NOINTERFACE;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return ++references_; }
  STDMETHODIMP_(ULONG) Release() override {
    const ULONG remaining = --references_;
    if (remaining == 0) delete this;
    return remaining;
  }

  STDMETHODIMP OnReadSample(HRESULT status, DWORD stream_index, DWORD flags,
                            LONGLONG timestamp, IMFSample* sample) override;
  STDMETHODIMP OnFlush(DWORD) override {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      flushed_ = true;
    }
    flush_done_.notify_all();
    return S_OK;
  }
  STDMETHODIMP OnEvent(DWORD, IMFMediaEvent* event) override;

  void Attach(MfSession* owner) {
    std::lock_guard<std::mutex> lock(mutex_);
    owner_ = owner;
  }
  // No more ReadSample requests from here on.
  void BeginStopping() {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
  }
  bool WaitFlushed(std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(mutex_);
    return flush_done_.wait_for(lock, timeout, [&] { return flushed_; });
  }
  // Waits out a callback in progress (it holds the lock), then makes every
  // later one a no-op.
  void Detach() {
    std::lock_guard<std::mutex> lock(mutex_);
    owner_ = nullptr;
  }

 private:
  ~ReaderCallback() = default;

  std::atomic<ULONG> references_{1};
  std::mutex mutex_;
  std::condition_variable flush_done_;
  MfSession* owner_ = nullptr;
  bool stopping_ = false;
  bool flushed_ = false;
};

class MfSession final : public CaptureSession {
 public:
  MfSession(FrameSink& sink, MfDevice device, ComPtr<IMFMediaSource> source)
      : sink_(sink), device_(std::move(device)), source_(std::move(source)) {
    callback_ = ComPtr<ReaderCallback>::Attach(new ReaderCallback());
  }

  ~MfSession() override {
    callback_->BeginStopping();
    if (reader_ && SUCCEEDED(reader_->Flush(MF_SOURCE_READER_ALL_STREAMS))) {
      // Windows 7 calls OnFlush early (a documented bug); the Detach below is
      // what actually guarantees no frame is delivered after this returns.
      callback_->WaitFlushed(std::chrono::milliseconds(3000));
    }
    callback_->Detach();
    // Releasing the reader shuts the media source down with it (unless
    // MF_SOURCE_READER_DISCONNECT_MEDIASOURCE_ON_SHUTDOWN is set, and it is
    // not); the explicit calls make the camera free NOW, not whenever COM
    // gets round to the last reference.
    reader_.Reset();
    if (source_) source_->Shutdown();
    if (device_.activate) device_.activate->ShutdownObject();
    source_.Reset();
  }

  const StreamInfo& info() const override { return info_; }

  bool Start(const OpenRequest& request, bool substituted, CaptureFailure& failure);

  // --- called by ReaderCallback, under its lock ---
  void Deliver(IMFSample* sample);
  void Fail(const CaptureFailure& failure) {
    if (failed_) return;
    failed_ = true;
    sink_.OnStreamFailure(failure);
  }
  HRESULT RequestNext() {
    return reader_->ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, nullptr,
                               nullptr, nullptr, nullptr);
  }
  // The driver changed format mid-stream (some do on a resolution or
  // exposure switch). Only the fields Deliver reads are updated: info() was
  // handed to the engine when the session opened and is not touched again.
  void RefreshLayout() { ReadLayout(/*describe=*/false); }

 private:
  bool ChooseMode(const OpenRequest& request, CaptureFailure& failure);
  bool ReadLayout(bool describe = true);
  void EnableAutoFocus();

  FrameSink& sink_;
  MfDevice device_;
  ComPtr<IMFMediaSource> source_;
  ComPtr<IMFSourceReader> reader_;
  ComPtr<ReaderCallback> callback_;
  StreamInfo info_;
  std::string native_name_;

  // Layout of the frames the reader delivers.
  PixelFormat format_ = PixelFormat::kUnknown;
  int width_ = 0;
  int height_ = 0;
  int stride_ = 0;
  bool failed_ = false;
};

STDMETHODIMP ReaderCallback::OnReadSample(HRESULT status, DWORD, DWORD flags,
                                          LONGLONG, IMFSample* sample) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (owner_ == nullptr) return S_OK;
  if (FAILED(status)) {
    owner_->Fail(Failure(status, "reading a frame"));
    return S_OK;
  }
  if (flags & MF_SOURCE_READERF_ERROR) {
    owner_->Fail({CaptureError::kDeviceLost, "the camera reported a stream error"});
    return S_OK;
  }
  if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
    // A live camera has no end; this is the device going away.
    owner_->Fail({CaptureError::kDeviceLost, "the camera ended its stream"});
    return S_OK;
  }
  if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) owner_->RefreshLayout();
  if (sample != nullptr) owner_->Deliver(sample);
  if (!stopping_) {
    const HRESULT hr = owner_->RequestNext();
    if (FAILED(hr) && hr != MF_E_NOTACCEPTING) {
      owner_->Fail(Failure(hr, "asking for the next frame"));
    }
  }
  return S_OK;
}

STDMETHODIMP ReaderCallback::OnEvent(DWORD, IMFMediaEvent* event) {
  if (event == nullptr) return S_OK;
  MediaEventType type = MEUnknown;
  HRESULT status = S_OK;
  event->GetType(&type);
  event->GetStatus(&status);
  std::lock_guard<std::mutex> lock(mutex_);
  if (owner_ == nullptr) return S_OK;
  if (type == MEVideoCaptureDeviceRemoved) {
    owner_->Fail({CaptureError::kDeviceLost, "the camera was disconnected"});
  } else if (type == MEVideoCaptureDevicePreempted) {
    owner_->Fail({CaptureError::kInUse, "another program took the camera"});
  } else if (type == MEError && FAILED(status)) {
    owner_->Fail(Failure(status, "the camera"));
  }
  return S_OK;
}

void MfSession::Deliver(IMFSample* sample) {
  if (format_ == PixelFormat::kUnknown) return;
  DWORD count = 0;
  if (FAILED(sample->GetBufferCount(&count)) || count == 0) return;
  ComPtr<IMFMediaBuffer> buffer;
  const HRESULT got = count == 1 ? sample->GetBufferByIndex(0, buffer.Out())
                                 : sample->ConvertToContiguousBuffer(buffer.Out());
  if (FAILED(got)) return;

  // A 2-D buffer knows its own pitch and where the top row is, which beats
  // any stride worked out from the media type.
  ComPtr<IMF2DBuffer> buffer_2d;
  if (SUCCEEDED(buffer.As(buffer_2d))) {
    BYTE* top = nullptr;
    LONG pitch = 0;
    if (SUCCEEDED(buffer_2d->Lock2D(&top, &pitch))) {
      sink_.OnFrame({format_, width_, height_, top, static_cast<int>(pitch)});
      buffer_2d->Unlock2D();
      return;
    }
  }

  BYTE* data = nullptr;
  DWORD max_length = 0;
  DWORD length = 0;
  if (FAILED(buffer->Lock(&data, &max_length, &length))) return;
  const size_t row_bytes = static_cast<size_t>(std::abs(stride_));
  // Only the first plane is read, so that is all the buffer has to hold.
  if (stride_ != 0 && length >= row_bytes * static_cast<size_t>(height_)) {
    const BYTE* top = stride_ < 0 ? data + row_bytes * static_cast<size_t>(height_ - 1) : data;
    sink_.OnFrame({format_, width_, height_, top, stride_});
  }
  buffer->Unlock();
}

bool MfSession::ReadLayout(bool describe) {
  ComPtr<IMFMediaType> current;
  if (FAILED(reader_->GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM,
                                          current.Out()))) {
    return false;
  }
  GUID subtype{};
  UINT32 width = 0;
  UINT32 height = 0;
  if (FAILED(current->GetGUID(MF_MT_SUBTYPE, &subtype)) ||
      FAILED(MFGetAttributeSize(current.get(), MF_MT_FRAME_SIZE, &width, &height))) {
    return false;
  }
  const auto format = DirectFormat(subtype);
  if (format == PixelFormat::kUnknown || width == 0 || height == 0) return false;

  // Microsoft's GetDefaultStride: the attribute when set, otherwise the
  // minimum stride for the format and width.
  UINT32 stride_attribute = 0;
  LONG stride = 0;
  if (SUCCEEDED(current->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride_attribute))) {
    stride = static_cast<LONG>(static_cast<INT32>(stride_attribute));
  } else if (FAILED(MFGetStrideForBitmapInfoHeader(subtype.Data1, width, &stride))) {
    const int bytes = format == PixelFormat::kRGB32   ? 4
                      : format == PixelFormat::kRGB24 ? 3
                      : (format == PixelFormat::kYUY2 || format == PixelFormat::kUYVY)
                          ? 2
                          : 1;
    stride = static_cast<LONG>(width) * bytes;
  }

  format_ = format;
  width_ = static_cast<int>(width);
  height_ = static_cast<int>(height);
  stride_ = static_cast<int>(stride);
  if (!describe) return true;
  info_.width = width_;
  info_.height = height_;
  const double fps = FrameRate(current.get());
  if (fps > 0) info_.fps = fps;
  const auto output_name = SubtypeName(subtype);
  info_.pixel_format = output_name == native_name_ ? output_name
                                                   : native_name_ + ">" + output_name;
  return true;
}

bool MfSession::ChooseMode(const OpenRequest& request, CaptureFailure& failure) {
  std::vector<Mode> modes;
  for (DWORD index = 0;; ++index) {
    Mode mode;
    const HRESULT hr = reader_->GetNativeMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM,
                                                   index, mode.type.Out());
    if (hr == MF_E_NO_MORE_TYPES) break;
    if (FAILED(hr)) {
      failure = Failure(hr, "listing the camera's formats");
      return false;
    }
    if (FAILED(mode.type->GetGUID(MF_MT_SUBTYPE, &mode.subtype)) ||
        FAILED(MFGetAttributeSize(mode.type.get(), MF_MT_FRAME_SIZE, &mode.width,
                                  &mode.height)) ||
        mode.width == 0 || mode.height == 0) {
      continue;
    }
    mode.fps = FrameRate(mode.type.get());
    mode.score = Score(mode, request.preferred_width, request.preferred_height);
    modes.push_back(std::move(mode));
  }
  if (modes.empty()) {
    failure = {CaptureError::kNoUsableFormat, "the camera reports no video formats"};
    return false;
  }
  std::stable_sort(modes.begin(), modes.end(),
                   [](const Mode& a, const Mode& b) { return a.score < b.score; });

  // Try the best few: some drivers list modes they then refuse.
  const size_t attempts = std::min<size_t>(modes.size(), 8);
  for (size_t i = 0; i < attempts; ++i) {
    const auto& mode = modes[i];
    if (FAILED(reader_->SetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr,
                                            mode.type.get()))) {
      continue;
    }
    native_name_ = SubtypeName(mode.subtype);
    info_.fps = mode.fps;
    if (DirectFormat(mode.subtype) != PixelFormat::kUnknown) {
      if (ReadLayout()) return true;
      continue;
    }
    // Compressed at the source: ask the reader to decode it, keeping the
    // native mode just set. NV12 first (its luminance plane is the first
    // thing in the buffer), then what older decoders offer.
    for (const GUID& output : {MFVideoFormat_NV12, MFVideoFormat_YUY2, MFVideoFormat_RGB32}) {
      ComPtr<IMFMediaType> decoded;
      if (FAILED(MFCreateMediaType(decoded.Out()))) continue;
      // Fully described, as a decoder would describe its own output: some
      // drivers' pipelines refuse a type that leaves these to be guessed.
      decoded->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
      decoded->SetGUID(MF_MT_SUBTYPE, output);
      decoded->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
      decoded->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
      MFSetAttributeRatio(decoded.get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
      MFSetAttributeSize(decoded.get(), MF_MT_FRAME_SIZE, mode.width, mode.height);
      UINT32 numerator = 0;
      UINT32 denominator = 0;
      if (SUCCEEDED(MFGetAttributeRatio(mode.type.get(), MF_MT_FRAME_RATE, &numerator,
                                        &denominator))) {
        MFSetAttributeRatio(decoded.get(), MF_MT_FRAME_RATE, numerator, denominator);
      }
      if (SUCCEEDED(reader_->SetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM,
                                                 nullptr, decoded.get())) &&
          ReadLayout()) {
        return true;
      }
    }
  }
  failure = {CaptureError::kNoUsableFormat,
             "none of the camera's " + std::to_string(modes.size()) +
                 " formats could be turned into grey (best: " +
                 SubtypeName(modes.front().subtype) + " " +
                 std::to_string(modes.front().width) + "x" +
                 std::to_string(modes.front().height) + ")"};
  return false;
}

// Many webcams remember a manual focus some other program left them in, and a
// counter camera stuck focused at a metre reads nothing at twenty
// centimetres. Best effort: a camera without the control is left alone.
void MfSession::EnableAutoFocus() {
  ComPtr<IAMCameraControl> control;
  if (FAILED(source_.As(control))) return;
  long minimum = 0;
  long maximum = 0;
  long step = 0;
  long fallback = 0;
  long capabilities = 0;
  if (FAILED(control->GetRange(CameraControl_Focus, &minimum, &maximum, &step, &fallback,
                               &capabilities)) ||
      !(capabilities & CameraControl_Flags_Auto)) {
    return;
  }
  long value = fallback;
  long flags = 0;
  if (SUCCEEDED(control->Get(CameraControl_Focus, &value, &flags)) &&
      (flags & CameraControl_Flags_Auto)) {
    return;
  }
  control->Set(CameraControl_Focus, value, CameraControl_Flags_Auto);
}

bool MfSession::Start(const OpenRequest& request, bool substituted,
                      CaptureFailure& failure) {
  info_.device_id = device_.info.id;
  info_.device_label = device_.info.label;
  info_.substituted = substituted;

  ComPtr<IMFAttributes> attributes;
  HRESULT hr = MFCreateAttributes(attributes.Out(), 4);
  if (FAILED(hr)) {
    failure = Failure(hr, "preparing the camera");
    return false;
  }
  attributes->SetUnknown(MF_SOURCE_READER_ASYNC_CALLBACK, callback_.get());
  // Windows 8+: lets the reader insert any decoder or converter needed.
  // Windows 7 ignores it and still inserts decoders.
  attributes->SetUINT32(kAdvancedVideoProcessing, TRUE);
  // Keep the pipeline shallow: a queue of old frames is latency.
  attributes->SetUINT32(kLowLatency, TRUE);

  hr = MFCreateSourceReaderFromMediaSource(source_.get(), attributes.get(), reader_.Out());
  if (FAILED(hr)) {
    failure = Failure(hr, "opening the camera stream");
    return false;
  }
  reader_->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS, FALSE);
  hr = reader_->SetStreamSelection(MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);
  if (FAILED(hr)) {
    failure = Failure(hr, "selecting the camera's video stream");
    return false;
  }
  if (!ChooseMode(request, failure)) return false;
  EnableAutoFocus();

  callback_->Attach(this);
  hr = RequestNext();
  if (FAILED(hr)) {
    failure = Failure(hr, "starting the camera");
    return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// The backend.

class MfBackend final : public CaptureBackend {
 public:
  bool supported() const override { return true; }

  std::unique_ptr<ThreadScope> EnterThread() override {
    return std::make_unique<MfThreadScope>();
  }

  std::vector<DeviceInfo> ListDevices(CaptureFailure& failure) override {
    std::vector<MfDevice> devices;
    const HRESULT hr = EnumerateDevices(devices);
    if (FAILED(hr)) {
      failure = Failure(hr, "listing cameras");
      return {};
    }
    std::vector<DeviceInfo> infos;
    for (auto& device : devices) infos.push_back(device.info);
    return infos;
  }

  std::unique_ptr<CaptureSession> Open(const OpenRequest& request, FrameSink& sink,
                                       CaptureFailure& failure) override {
    std::vector<MfDevice> devices;
    HRESULT hr = EnumerateDevices(devices);
    if (FAILED(hr)) {
      failure = Failure(hr, "listing cameras");
      return nullptr;
    }
    std::vector<DeviceInfo> infos;
    for (const auto& device : devices) infos.push_back(device.info);
    const auto choice = ChooseDevice(infos, request.device_id);
    if (choice.failure) {
      failure = choice.failure;
      return nullptr;
    }
    auto& device = devices[static_cast<size_t>(choice.index)];

    ComPtr<IMFMediaSource> source;
    hr = device.activate->ActivateObject(__uuidof(IMFMediaSource),
                                         reinterpret_cast<void**>(source.Out()));
    if (FAILED(hr)) {
      failure = Failure(hr, "opening the camera");
      return nullptr;
    }
    auto session = std::make_unique<MfSession>(sink, std::move(device), std::move(source));
    if (!session->Start(request, choice.substituted, failure)) return nullptr;
    return session;
  }
};

}  // namespace

std::unique_ptr<CaptureBackend> CreatePlatformBackend() {
  return std::make_unique<MfBackend>();
}

}  // namespace pcw
