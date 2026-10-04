// Linux: frames straight out of V4L2, the kernel's video capture API.
//
// Every USB webcam on Linux is a UVC device that the kernel's uvcvideo driver
// shows as /dev/videoN, and this reads it the way Linux camera applications
// do — with no library between the wedge and the kernel:
//  * MEMORY-MAPPED STREAMING (VIDIOC_REQBUFS / QBUF / DQBUF). The driver fills
//    buffers mapped into this process, so a frame costs one copy of its grey
//    plane, as on Windows.
//  * One capture thread per session, waiting in poll() on the camera AND an
//    eventfd. The eventfd is how the session stops it: at once, whatever the
//    driver is doing, and only then is the camera released — so once the
//    session is destroyed, no frame can reach the engine.
//  * The camera's mode is chosen explicitly with the same ranking as the
//    Windows backend (capture/mode_score.h): about 1280x720, 30 fps,
//    uncompressed when the camera can manage that and MJPEG when it cannot.
//  * MJPEG is decoded here (capture/jpeg_decoder.h). Media Foundation decodes
//    for the Windows backend; V4L2 hands frames over exactly as the camera
//    sent them, and at 720p30 most USB 2 webcams send nothing else.
//  * Errors are classified by errno (platform/linux/v4l2_rules.h): EACCES is a
//    permission (the "video" group), EBUSY another program streaming, ENODEV
//    a camera unplugged.
//
// Needs nothing at run time but the kernel: no libv4l, no GStreamer.
#include <dirent.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <sys/eventfd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "capture/capture_backend.h"
#include "capture/device_selection.h"
#include "capture/jpeg_decoder.h"
#include "capture/mode_score.h"
#include "engine/thread_util.h"
#include "platform/linux/v4l2_rules.h"

namespace pcw {
namespace {

using v4l2::FailureFromErrno;
using v4l2::FormatInfo;
using v4l2::FrameInterval;
using v4l2::FrameIntervalRange;
using v4l2::FrameSize;
using v4l2::FrameSizeRange;

// ---------------------------------------------------------------------------
// System helpers.

int Ioctl(int fd, unsigned long request, void* argument) {
  int result;
  do {
    result = ::ioctl(fd, request, argument);
  } while (result == -1 && errno == EINTR);
  return result;
}

class UniqueFd {
 public:
  UniqueFd() = default;
  explicit UniqueFd(int fd) : fd_(fd) {}
  ~UniqueFd() { Reset(); }
  UniqueFd(UniqueFd&& other) noexcept : fd_(std::exchange(other.fd_, -1)) {}
  UniqueFd& operator=(UniqueFd&& other) noexcept {
    if (this != &other) {
      Reset();
      fd_ = std::exchange(other.fd_, -1);
    }
    return *this;
  }
  UniqueFd(const UniqueFd&) = delete;
  UniqueFd& operator=(const UniqueFd&) = delete;

  int get() const { return fd_; }
  explicit operator bool() const { return fd_ >= 0; }
  void Reset() {
    if (fd_ >= 0) ::close(fd_);
    fd_ = -1;
  }

 private:
  int fd_ = -1;
};

// Non-blocking, so a DQBUF never waits (poll does the waiting), and closed on
// exec, so a program the app starts never inherits the camera.
UniqueFd OpenNode(const std::string& path) {
  return UniqueFd(::open(path.c_str(), O_RDWR | O_NONBLOCK | O_CLOEXEC));
}

std::string TrimSpace(std::string text) {
  const auto not_space = [](unsigned char c) { return c > ' '; };
  text.erase(text.begin(), std::find_if(text.begin(), text.end(), not_space));
  text.erase(std::find_if(text.rbegin(), text.rend(), not_space).base(), text.end());
  return text;
}

// The first line of a small file (a sysfs attribute), trimmed.
std::string ReadLine(const std::string& path) {
  std::ifstream in(path);
  std::string line;
  std::getline(in, line);
  return TrimSpace(line);
}

struct FreeDeleter {
  void operator()(char* p) const { std::free(p); }
};
struct DirCloser {
  void operator()(DIR* d) const { ::closedir(d); }
};

std::string RealPath(const std::string& path) {
  const std::unique_ptr<char, FreeDeleter> resolved(::realpath(path.c_str(), nullptr));
  return resolved ? std::string(resolved.get()) : std::string();
}

std::vector<std::string> DirectoryEntries(const std::string& directory) {
  std::vector<std::string> names;
  const std::unique_ptr<DIR, DirCloser> dir(::opendir(directory.c_str()));
  if (!dir) return names;
  while (const dirent* entry = ::readdir(dir.get())) {
    const std::string name = entry->d_name;
    if (name != "." && name != "..") names.push_back(name);
  }
  return names;
}

// ---------------------------------------------------------------------------
// Finding cameras.

struct Node {
  std::string path;  // /dev/videoN
  int number = 0;
  std::string label;
  v4l2::NodeIdentity identity;
};

struct Discovery {
  // Capture nodes offering at least one format the wedge reads.
  std::vector<Node> cameras;
  std::vector<DeviceInfo> infos;
  // Nodes this user may not open, and capture nodes with nothing readable:
  // when there are no cameras, they say why better than "none connected".
  std::string denied;
  std::string unreadable;
};

// udev's /dev/v4l/by-id and /dev/v4l/by-path links, keyed by the node each
// resolves to. When a node has more than one (systemd adds "-usbv2-" by-path
// links beside the classic ones) the shortest name is kept: the classic one,
// which every systemd version creates.
std::map<std::string, std::string> LinksByNode(const std::string& directory) {
  std::map<std::string, std::string> links;
  auto names = DirectoryEntries(directory);
  std::sort(names.begin(), names.end(), [](const std::string& a, const std::string& b) {
    return a.size() != b.size() ? a.size() < b.size() : a < b;
  });
  for (const auto& name : names) {
    const auto link = directory + "/" + name;
    const auto node = RealPath(link);
    if (!node.empty()) links.emplace(node, link);
  }
  return links;
}

// The USB device a node belongs to, from sysfs: the nearest ancestor of the
// node's device that has a USB vendor id.
void ReadUsbIdentity(const std::string& node_name, v4l2::NodeIdentity& identity) {
  auto directory = RealPath("/sys/class/video4linux/" + node_name + "/device");
  while (directory.size() > std::strlen("/sys/devices")) {
    const auto vendor = ReadLine(directory + "/idVendor");
    if (!vendor.empty()) {
      identity.usb_device = directory;
      identity.usb_model = vendor + ":" + ReadLine(directory + "/idProduct");
      identity.usb_serial = ReadLine(directory + "/serial");
      return;
    }
    directory.erase(directory.rfind('/'));
  }
}

uint32_t DeviceCapabilities(const v4l2_capability& capability) {
  return (capability.capabilities & V4L2_CAP_DEVICE_CAPS) ? capability.device_caps
                                                          : capability.capabilities;
}

std::vector<uint32_t> PixelFormats(int fd) {
  std::vector<uint32_t> formats;
  for (uint32_t index = 0;; ++index) {
    v4l2_fmtdesc description{};
    description.index = index;
    description.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (Ioctl(fd, VIDIOC_ENUM_FMT, &description) < 0) break;
    formats.push_back(description.pixelformat);
  }
  return formats;
}

Discovery Discover() {
  Discovery discovery;
  std::vector<std::pair<int, std::string>> candidates;
  for (const auto& name : DirectoryEntries("/dev")) {
    if (name.size() <= 5 || name.compare(0, 5, "video") != 0) continue;
    const auto digits = name.substr(5);
    if (digits.find_first_not_of("0123456789") != std::string::npos) continue;
    candidates.emplace_back(std::atoi(digits.c_str()), name);
  }
  // videoN numbering follows the order things were plugged in; listing in
  // that order makes "the first camera" the same one every time.
  std::sort(candidates.begin(), candidates.end());

  const auto by_id = LinksByNode("/dev/v4l/by-id");
  const auto by_path = LinksByNode("/dev/v4l/by-path");

  for (const auto& [number, name] : candidates) {
    Node node;
    node.path = "/dev/" + name;
    node.number = number;
    auto fd = OpenNode(node.path);
    if (!fd) {
      if ((errno == EACCES || errno == EPERM) && discovery.denied.empty()) {
        discovery.denied = node.path + " (" + v4l2::ErrnoName(errno) + ")";
      }
      continue;
    }
    v4l2_capability capability{};
    if (Ioctl(fd.get(), VIDIOC_QUERYCAP, &capability) < 0) continue;
    const auto caps = DeviceCapabilities(capability);
    // Metadata nodes (every UVC camera has one beside its video node),
    // outputs, and memory-to-memory codecs are not cameras.
    if (!(caps & V4L2_CAP_VIDEO_CAPTURE) || (caps & V4L2_CAP_VIDEO_M2M)) continue;
    char card[sizeof(capability.card) + 1] = {};
    std::memcpy(card, capability.card, sizeof(capability.card));
    node.label = TrimSpace(card);
    if (node.label.empty()) node.label = ReadLine("/sys/class/video4linux/" + name + "/name");
    if (node.label.empty()) node.label = name;

    const auto formats = PixelFormats(fd.get());
    const bool readable =
        (caps & V4L2_CAP_STREAMING) &&
        std::any_of(formats.begin(), formats.end(),
                    [](uint32_t f) { return v4l2::DescribeFormat(f).has_value(); });
    if (!readable) {
      if (discovery.unreadable.empty()) {
        discovery.unreadable = node.label + " offers";
        for (const auto format : formats) discovery.unreadable += " " + v4l2::FourCCName(format);
        if (formats.empty()) discovery.unreadable += " no formats";
        if (!(caps & V4L2_CAP_STREAMING)) discovery.unreadable += ", without streaming";
      }
      continue;
    }

    node.identity.node = node.path;
    if (const auto link = by_id.find(node.path); link != by_id.end()) {
      node.identity.by_id = link->second;
    }
    if (const auto link = by_path.find(node.path); link != by_path.end()) {
      node.identity.by_path = link->second;
    }
    ReadUsbIdentity(name, node.identity);
    discovery.cameras.push_back(std::move(node));
  }

  std::vector<v4l2::NodeIdentity> identities;
  for (const auto& camera : discovery.cameras) identities.push_back(camera.identity);
  const auto ids = v4l2::StableIds(identities);
  for (size_t i = 0; i < discovery.cameras.size(); ++i) {
    discovery.infos.push_back({ids[i], discovery.cameras[i].label});
  }
  return discovery;
}

// When nothing usable was found, what to say instead of "no camera".
CaptureFailure NothingUsable(const Discovery& discovery) {
  if (!discovery.denied.empty()) {
    return {CaptureError::kAccessDenied,
            "this user may not open the camera: " + discovery.denied};
  }
  if (!discovery.unreadable.empty()) {
    return {CaptureError::kNoUsableFormat,
            "no camera offers a format the wedge reads: " + discovery.unreadable};
  }
  return {CaptureError::kNoCamera, "no video capture device"};
}

// ---------------------------------------------------------------------------
// The session.

struct Mode {
  uint32_t fourcc = 0;
  FormatInfo format;
  FrameSize size;
  FrameInterval interval;
  double score = 0;
};

class V4l2Session final : public CaptureSession {
 public:
  V4l2Session(FrameSink& sink, UniqueFd fd, StreamInfo info)
      : sink_(sink), fd_(std::move(fd)), info_(std::move(info)) {}

  ~V4l2Session() override {
    if (thread_.joinable()) {
      const uint64_t one = 1;
      // The thread exits as soon as poll() sees this; nothing it does
      // blocks for longer than one frame.
      [[maybe_unused]] const auto written = ::write(wake_.get(), &one, sizeof(one));
      thread_.join();
    }
    StopStreaming();
    ReleaseBuffers();
    fd_.Reset();
  }

  const StreamInfo& info() const override { return info_; }

  bool Start(const OpenRequest& request, CaptureFailure& failure);

 private:
  struct Buffer {
    void* start = MAP_FAILED;
    size_t length = 0;
  };

  std::vector<Mode> ListModes(const OpenRequest& request,
                              std::vector<uint32_t>& offered) const;
  // Sets one mode and starts streaming. `next` says whether a later mode in
  // the ranking may still work after a failure.
  bool TryMode(const Mode& mode, CaptureFailure& failure, bool& next);
  bool MapBuffers(CaptureFailure& failure);
  void StopStreaming();
  void ReleaseBuffers();
  void EnableAutoFocus();
  void Run();
  void Deliver(const uint8_t* data, size_t length);
  void Fail(const CaptureFailure& failure) {
    if (failed_) return;
    failed_ = true;
    sink_.OnStreamFailure(failure);
  }

  FrameSink& sink_;
  UniqueFd fd_;
  UniqueFd wake_;
  StreamInfo info_;
  std::vector<Buffer> buffers_;
  bool streaming_ = false;
  std::thread thread_;
  bool failed_ = false;

  // Layout of what the driver delivers.
  PixelFormat format_ = PixelFormat::kUnknown;
  bool mjpeg_ = false;
  int width_ = 0;
  int height_ = 0;
  int stride_ = 0;
  JpegDecoder jpeg_;
};

std::vector<Mode> V4l2Session::ListModes(const OpenRequest& request,
                                         std::vector<uint32_t>& offered) const {
  std::vector<Mode> modes;
  offered = PixelFormats(fd_.get());
  for (const auto fourcc : offered) {
    const auto format = v4l2::DescribeFormat(fourcc);
    if (!format) continue;

    std::vector<FrameSizeRange> ranges;
    for (uint32_t index = 0;; ++index) {
      v4l2_frmsizeenum size{};
      size.index = index;
      size.pixel_format = fourcc;
      if (Ioctl(fd_.get(), VIDIOC_ENUM_FRAMESIZES, &size) < 0) break;
      if (size.type == V4L2_FRMSIZE_TYPE_DISCRETE) {
        const FrameSize discrete{static_cast<int>(size.discrete.width),
                                 static_cast<int>(size.discrete.height)};
        ranges.push_back({discrete, discrete, {1, 1}});
      } else {
        const auto& s = size.stepwise;
        ranges.push_back({{static_cast<int>(s.min_width), static_cast<int>(s.min_height)},
                          {static_cast<int>(s.max_width), static_cast<int>(s.max_height)},
                          {static_cast<int>(s.step_width), static_cast<int>(s.step_height)}});
        break;  // a range is the only answer
      }
    }
    auto sizes = v4l2::CandidateSizes(ranges, request.preferred_width,
                                      request.preferred_height);
    // A driver that lists no sizes takes whatever it is given and adjusts it.
    if (sizes.empty()) sizes.push_back({request.preferred_width, request.preferred_height});

    for (const auto& size : sizes) {
      std::vector<FrameIntervalRange> interval_ranges;
      for (uint32_t index = 0;; ++index) {
        v4l2_frmivalenum interval{};
        interval.index = index;
        interval.pixel_format = fourcc;
        interval.width = static_cast<uint32_t>(size.width);
        interval.height = static_cast<uint32_t>(size.height);
        if (Ioctl(fd_.get(), VIDIOC_ENUM_FRAMEINTERVALS, &interval) < 0) break;
        if (interval.type == V4L2_FRMIVAL_TYPE_DISCRETE) {
          const FrameInterval discrete{interval.discrete.numerator,
                                       interval.discrete.denominator};
          interval_ranges.push_back({discrete, discrete});
        } else {
          interval_ranges.push_back(
              {{interval.stepwise.min.numerator, interval.stepwise.min.denominator},
               {interval.stepwise.max.numerator, interval.stepwise.max.denominator}});
          break;
        }
      }
      auto intervals = v4l2::CandidateIntervals(interval_ranges);
      // Unknown rate: ranked as slow, so a mode that says it is fast wins.
      if (intervals.empty()) intervals.push_back({});
      for (const auto& interval : intervals) {
        Mode mode;
        mode.fourcc = fourcc;
        mode.format = *format;
        mode.size = size;
        mode.interval = interval;
        mode.score = ScoreMode({size.width, size.height, interval.fps(), format->encoding},
                               request.preferred_width, request.preferred_height);
        modes.push_back(mode);
      }
    }
  }
  std::stable_sort(modes.begin(), modes.end(),
                   [](const Mode& a, const Mode& b) { return a.score < b.score; });
  return modes;
}

bool V4l2Session::TryMode(const Mode& mode, CaptureFailure& failure, bool& next) {
  next = true;
  v4l2_format format{};
  format.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  format.fmt.pix.width = static_cast<uint32_t>(mode.size.width);
  format.fmt.pix.height = static_cast<uint32_t>(mode.size.height);
  format.fmt.pix.pixelformat = mode.fourcc;
  format.fmt.pix.field = V4L2_FIELD_ANY;
  if (Ioctl(fd_.get(), VIDIOC_S_FMT, &format) < 0) {
    failure = FailureFromErrno(errno, "setting the camera's format");
    // EBUSY: another program is streaming; no other mode will do better.
    next = failure.code != CaptureError::kInUse && failure.code != CaptureError::kDeviceLost;
    return false;
  }
  // The driver may have adjusted any of it; what it set is what arrives.
  const auto& pix = format.fmt.pix;
  const auto actual = v4l2::DescribeFormat(pix.pixelformat);
  if (!actual || pix.width == 0 || pix.height == 0) {
    failure = {CaptureError::kNoUsableFormat,
               "the camera switched to " + v4l2::FourCCName(pix.pixelformat)};
    return false;
  }
  mjpeg_ = actual->encoding == ModeEncoding::kMjpeg;
  format_ = actual->pixel;
  width_ = static_cast<int>(pix.width);
  height_ = static_cast<int>(pix.height);
  const int bytes_per_pixel = format_ == PixelFormat::kRGB32   ? 4
                              : format_ == PixelFormat::kRGB24 ? 3
                              : (format_ == PixelFormat::kYUY2 || format_ == PixelFormat::kUYVY)
                                  ? 2
                                  : 1;
  stride_ = pix.bytesperline > 0 ? static_cast<int>(pix.bytesperline)
                                 : width_ * bytes_per_pixel;

  double fps = mode.interval.fps();
  v4l2_streamparm parameters{};
  parameters.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  if (mode.interval.denominator != 0 && Ioctl(fd_.get(), VIDIOC_G_PARM, &parameters) == 0 &&
      (parameters.parm.capture.capability & V4L2_CAP_TIMEPERFRAME)) {
    parameters.parm.capture.timeperframe.numerator = mode.interval.numerator;
    parameters.parm.capture.timeperframe.denominator = mode.interval.denominator;
    if (Ioctl(fd_.get(), VIDIOC_S_PARM, &parameters) == 0) {
      const auto& set = parameters.parm.capture.timeperframe;
      const double reported = FrameInterval{set.numerator, set.denominator}.fps();
      if (reported > 0) fps = reported;
    }
  }

  if (!MapBuffers(failure)) {
    next = failure.code != CaptureError::kInUse && failure.code != CaptureError::kDeviceLost;
    return false;
  }
  int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  if (Ioctl(fd_.get(), VIDIOC_STREAMON, &type) < 0) {
    const int error = errno;
    ReleaseBuffers();
    if (error == ENOSPC) {
      // Not enough USB bandwidth left for this mode — usually another camera
      // or a headset on the same controller. A compressed or smaller mode
      // needs less, so keep going down the ranking.
      failure = {CaptureError::kPlatform,
                 "the USB port has no bandwidth left for the camera (ENOSPC); "
                 "plug it into another port"};
      return false;
    }
    failure = FailureFromErrno(error, "starting the camera");
    next = failure.code != CaptureError::kInUse && failure.code != CaptureError::kDeviceLost;
    return false;
  }
  streaming_ = true;

  info_.width = width_;
  info_.height = height_;
  info_.fps = fps;
  const auto name = v4l2::FourCCName(pix.pixelformat);
  info_.pixel_format = mjpeg_ ? name + ">" + PixelFormatName(PixelFormat::kGray8) : name;
  return true;
}

bool V4l2Session::MapBuffers(CaptureFailure& failure) {
  // Four: one being filled, one in flight to the engine, and slack so a
  // slow moment on the till drops frames instead of stalling the camera.
  v4l2_requestbuffers request{};
  request.count = 4;
  request.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  request.memory = V4L2_MEMORY_MMAP;
  if (Ioctl(fd_.get(), VIDIOC_REQBUFS, &request) < 0) {
    failure = FailureFromErrno(errno, "allocating the camera's buffers");
    return false;
  }
  if (request.count < 2) {
    failure = {CaptureError::kPlatform, "the camera gave too few buffers"};
    ReleaseBuffers();
    return false;
  }
  buffers_.resize(request.count);
  for (uint32_t index = 0; index < request.count; ++index) {
    v4l2_buffer buffer{};
    buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buffer.memory = V4L2_MEMORY_MMAP;
    buffer.index = index;
    if (Ioctl(fd_.get(), VIDIOC_QUERYBUF, &buffer) < 0) {
      failure = FailureFromErrno(errno, "reading the camera's buffers");
      ReleaseBuffers();
      return false;
    }
    void* start = ::mmap(nullptr, buffer.length, PROT_READ | PROT_WRITE, MAP_SHARED,
                         fd_.get(), buffer.m.offset);
    if (start == MAP_FAILED) {
      failure = FailureFromErrno(errno, "mapping the camera's buffers");
      ReleaseBuffers();
      return false;
    }
    buffers_[index] = {start, buffer.length};
    if (Ioctl(fd_.get(), VIDIOC_QBUF, &buffer) < 0) {
      failure = FailureFromErrno(errno, "queueing the camera's buffers");
      ReleaseBuffers();
      return false;
    }
  }
  return true;
}

void V4l2Session::StopStreaming() {
  if (!streaming_) return;
  int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  // Fails with ENODEV on a camera that was unplugged, which is fine: the
  // kernel has stopped it already.
  Ioctl(fd_.get(), VIDIOC_STREAMOFF, &type);
  streaming_ = false;
}

void V4l2Session::ReleaseBuffers() {
  for (auto& buffer : buffers_) {
    if (buffer.start != MAP_FAILED) ::munmap(buffer.start, buffer.length);
  }
  buffers_.clear();
  v4l2_requestbuffers request{};
  request.count = 0;
  request.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  request.memory = V4L2_MEMORY_MMAP;
  Ioctl(fd_.get(), VIDIOC_REQBUFS, &request);
}

// Many webcams remember a manual focus some other program left them in, and a
// counter camera stuck focused at a metre reads nothing at twenty
// centimetres. Best effort: a camera without the control is left alone.
void V4l2Session::EnableAutoFocus() {
  v4l2_queryctrl query{};
  query.id = V4L2_CID_FOCUS_AUTO;
  if (Ioctl(fd_.get(), VIDIOC_QUERYCTRL, &query) < 0 ||
      (query.flags & (V4L2_CTRL_FLAG_DISABLED | V4L2_CTRL_FLAG_READ_ONLY))) {
    return;
  }
  v4l2_control control{};
  control.id = V4L2_CID_FOCUS_AUTO;
  if (Ioctl(fd_.get(), VIDIOC_G_CTRL, &control) == 0 && control.value != 0) return;
  control.value = 1;
  Ioctl(fd_.get(), VIDIOC_S_CTRL, &control);
}

bool V4l2Session::Start(const OpenRequest& request, CaptureFailure& failure) {
  std::vector<uint32_t> offered;
  const auto modes = ListModes(request, offered);
  if (modes.empty()) {
    std::string formats;
    for (const auto fourcc : offered) formats += " " + v4l2::FourCCName(fourcc);
    failure = {CaptureError::kNoUsableFormat,
               "the camera offers nothing the wedge reads:" +
                   (formats.empty() ? std::string(" no formats") : formats)};
    return false;
  }

  // Try the best few: some drivers list modes they then refuse.
  const size_t attempts = std::min<size_t>(modes.size(), 8);
  bool started = false;
  for (size_t i = 0; i < attempts && !started; ++i) {
    bool next = true;
    started = TryMode(modes[i], failure, next);
    if (!started && !next) return false;
  }
  if (!started) {
    if (!failure || failure.code == CaptureError::kNoUsableFormat) {
      const auto& best = modes.front();
      failure = {CaptureError::kNoUsableFormat,
                 "none of the camera's " + std::to_string(modes.size()) +
                     " modes could be started (best: " + v4l2::FourCCName(best.fourcc) +
                     " " + std::to_string(best.size.width) + "x" +
                     std::to_string(best.size.height) + ")"};
    }
    return false;
  }
  EnableAutoFocus();

  wake_ = UniqueFd(::eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK));
  if (!wake_) {
    failure = FailureFromErrno(errno, "preparing the capture thread");
    return false;
  }
  thread_ = std::thread(&V4l2Session::Run, this);
  return true;
}

void V4l2Session::Deliver(const uint8_t* data, size_t length) {
  if (mjpeg_) {
    PixelBuffer frame;
    // A frame the decoder refuses (cut short, corrupt) is skipped; the next
    // is one frame interval away.
    if (jpeg_.Decode(data, length, frame)) sink_.OnFrame(frame);
    return;
  }
  // Only the first plane is read, so that is all the buffer has to hold.
  if (length < static_cast<size_t>(stride_) * static_cast<size_t>(height_)) return;
  sink_.OnFrame({format_, width_, height_, data, stride_});
}

void V4l2Session::Run() {
  // Decoding MJPEG happens on this thread, and the till comes first.
  LowerCurrentThreadPriority();
  pollfd fds[2] = {{fd_.get(), POLLIN, 0}, {wake_.get(), POLLIN, 0}};
  while (true) {
    const int ready = ::poll(fds, 2, 1000);
    if (ready < 0) {
      if (errno == EINTR) continue;
      Fail(FailureFromErrno(errno, "waiting for a frame"));
      return;
    }
    if (fds[1].revents != 0) return;  // stopping
    // Nothing for a second: not this thread's call. The engine's watchdog
    // decides when a quiet camera is a stalled one.
    if (ready == 0) continue;
    const bool trouble = (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) != 0;

    v4l2_buffer buffer{};
    buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buffer.memory = V4L2_MEMORY_MMAP;
    if (Ioctl(fd_.get(), VIDIOC_DQBUF, &buffer) < 0) {
      const int error = errno;
      if (error == EAGAIN && !trouble) continue;
      if (error == EAGAIN || error == EIO) {
        // The queue is in an error state (uvcvideo puts it there on a USB
        // failure, before the node goes away): only restarting the stream
        // recovers it, and the engine does that.
        Fail({CaptureError::kDeviceLost,
              "the camera stopped streaming (" + v4l2::ErrnoName(error) + ")"});
      } else if (error == ENODEV) {
        Fail({CaptureError::kDeviceLost, "the camera was disconnected"});
      } else {
        Fail(FailureFromErrno(error, "receiving a frame"));
      }
      return;
    }
    // A frame the driver marked damaged (a USB transfer lost part of it) is
    // handed back unread.
    if (!(buffer.flags & V4L2_BUF_FLAG_ERROR) && buffer.bytesused > 0 &&
        buffer.index < buffers_.size()) {
      const auto& mapped = buffers_[buffer.index];
      Deliver(static_cast<const uint8_t*>(mapped.start),
              std::min<size_t>(buffer.bytesused, mapped.length));
    }
    if (Ioctl(fd_.get(), VIDIOC_QBUF, &buffer) < 0) {
      const int error = errno;
      Fail(error == ENODEV ? CaptureFailure{CaptureError::kDeviceLost,
                                            "the camera was disconnected"}
                           : FailureFromErrno(error, "returning a buffer to the camera"));
      return;
    }
  }
}

// ---------------------------------------------------------------------------
// The backend.

class V4l2Backend final : public CaptureBackend {
 public:
  bool supported() const override { return true; }

  std::unique_ptr<ThreadScope> EnterThread() override {
    return std::make_unique<ThreadScope>();
  }

  std::vector<DeviceInfo> ListDevices(CaptureFailure& failure) override {
    auto discovery = Discover();
    if (discovery.infos.empty()) {
      const auto why = NothingUsable(discovery);
      // An empty list is an answer, not a failure — unless something says
      // why it is empty.
      if (why.code != CaptureError::kNoCamera) failure = why;
    }
    return std::move(discovery.infos);
  }

  std::unique_ptr<CaptureSession> Open(const OpenRequest& request, FrameSink& sink,
                                       CaptureFailure& failure) override {
    const auto discovery = Discover();
    if (discovery.infos.empty()) {
      failure = NothingUsable(discovery);
      return nullptr;
    }
    const auto choice = ChooseDevice(discovery.infos, request.device_id);
    if (choice.failure) {
      failure = choice.failure;
      return nullptr;
    }
    const auto index = static_cast<size_t>(choice.index);
    const auto& node = discovery.cameras[index];
    auto fd = OpenNode(node.path);
    if (!fd) {
      failure = FailureFromErrno(errno, "opening " + node.path);
      return nullptr;
    }
    StreamInfo info;
    info.device_id = discovery.infos[index].id;
    info.device_label = discovery.infos[index].label;
    info.substituted = choice.substituted;
    auto session = std::make_unique<V4l2Session>(sink, std::move(fd), std::move(info));
    if (!session->Start(request, failure)) return nullptr;
    return session;
  }
};

}  // namespace

std::unique_ptr<CaptureBackend> CreatePlatformBackend() {
  return std::make_unique<V4l2Backend>();
}

}  // namespace pcw
