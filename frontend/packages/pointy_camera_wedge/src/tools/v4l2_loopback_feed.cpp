// v4l2_loopback_feed: a drawn barcode, played into a v4l2loopback camera.
//
// v4l2loopback is a kernel module whose devices are real V4L2 cameras to
// anything that reads them, fed by whatever writes into them. This writes a
// counter with a barcode on it, so the wedge's Linux backend can be tested
// end to end — the kernel driver, mmap streaming, the format chosen, MJPEG
// as a UVC camera sends it — on a machine with no camera (CI does exactly
// this; see .github/workflows/camera-wedge.yml).
//
//   v4l2_loopback_feed --device /dev/video20 [--format yuyv|mjpeg|mjpeg_nodht]
//                      [--ean13 DIGITS | --qr TEXT] [--size 1280x720]
//                      [--fps 30] [--seconds S] [--frames N]
//
// --frames stops writing after N frames but keeps the device open: a camera
// that went quiet, for the stall watchdog.
#include <fcntl.h>
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "platform/synthetic/jpeg_writer.h"
#include "platform/synthetic/scene.h"

namespace {

int Usage() {
  std::fprintf(stderr,
               "usage: v4l2_loopback_feed --device /dev/videoN [--format yuyv|mjpeg|mjpeg_nodht]\n"
               "                          [--ean13 DIGITS | --qr TEXT] [--size WxH] [--fps N]\n"
               "                          [--seconds S] [--frames N]\n");
  return 2;
}

}  // namespace

int main(int argc, char** argv) {
  std::string device;
  std::string format = "yuyv";
  pcw::SceneSpec scene;
  scene.format = "EAN13";
  scene.text = "3600523434725";
  scene.noise = 3;
  int fps = 30;
  int seconds = 60;
  long frames_limit = -1;

  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    const bool has_value = i + 1 < argc;
    if (arg == "--device" && has_value) device = argv[++i];
    else if (arg == "--format" && has_value) format = argv[++i];
    else if (arg == "--ean13" && has_value) { scene.format = "EAN13"; scene.text = argv[++i]; }
    else if (arg == "--qr" && has_value) { scene.format = "QRCode"; scene.text = argv[++i]; }
    else if (arg == "--fps" && has_value) fps = std::max(1, std::atoi(argv[++i]));
    else if (arg == "--seconds" && has_value) seconds = std::atoi(argv[++i]);
    else if (arg == "--frames" && has_value) frames_limit = std::atol(argv[++i]);
    else if (arg == "--size" && has_value) {
      const std::string size = argv[++i];
      const auto x = size.find('x');
      if (x == std::string::npos) return Usage();
      scene.width = std::atoi(size.substr(0, x).c_str());
      scene.height = std::atoi(size.substr(x + 1).c_str());
    } else {
      return Usage();
    }
  }
  const bool mjpeg = format == "mjpeg" || format == "mjpeg_nodht";
  if (device.empty() || (!mjpeg && format != "yuyv")) return Usage();

  const auto luma = pcw::RenderScene(scene);
  std::vector<uint8_t> frame;
  if (mjpeg) {
    pcw::JpegWriteOptions options;
    options.without_huffman_tables = format == "mjpeg_nodht";
    frame = pcw::EncodeJpeg(luma, options);
  } else {
    frame.resize(luma.pixels.size() * 2);
    for (size_t i = 0; i < luma.pixels.size(); ++i) {
      frame[2 * i] = luma.pixels[i];
      frame[2 * i + 1] = 128;
    }
  }

  const int fd = ::open(device.c_str(), O_RDWR | O_CLOEXEC);
  if (fd < 0) {
    std::fprintf(stderr, "opening %s: %s\n", device.c_str(), std::strerror(errno));
    return 1;
  }
  v4l2_format f{};
  f.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
  f.fmt.pix.width = static_cast<uint32_t>(luma.width);
  f.fmt.pix.height = static_cast<uint32_t>(luma.height);
  f.fmt.pix.pixelformat = mjpeg ? V4L2_PIX_FMT_MJPEG : V4L2_PIX_FMT_YUYV;
  f.fmt.pix.field = V4L2_FIELD_NONE;
  f.fmt.pix.bytesperline = mjpeg ? 0 : static_cast<uint32_t>(luma.width * 2);
  // Room for any MJPEG frame of this size.
  f.fmt.pix.sizeimage = static_cast<uint32_t>(luma.width * luma.height * 2);
  if (::ioctl(fd, VIDIOC_S_FMT, &f) < 0) {
    std::fprintf(stderr, "setting the output format: %s\n", std::strerror(errno));
    return 1;
  }
  v4l2_streamparm parm{};
  parm.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
  parm.parm.output.timeperframe.numerator = 1;
  parm.parm.output.timeperframe.denominator = static_cast<uint32_t>(fps);
  ::ioctl(fd, VIDIOC_S_PARM, &parm);  // best effort: the frame pacing below is what counts

  std::printf("feeding %s %dx%d %s \"%s\" (%zu bytes a frame) at %d fps\n", device.c_str(),
              luma.width, luma.height, format.c_str(), scene.text.c_str(), frame.size(), fps);
  std::fflush(stdout);

  const auto interval = std::chrono::microseconds(1000000 / fps);
  const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
  auto next = std::chrono::steady_clock::now();
  long written = 0;
  while (std::chrono::steady_clock::now() < until) {
    if (frames_limit < 0 || written < frames_limit) {
      if (::write(fd, frame.data(), frame.size()) < 0) {
        std::fprintf(stderr, "writing a frame: %s\n", std::strerror(errno));
        return 1;
      }
      if (++written == frames_limit) {
        std::printf("stopped writing after %ld frames\n", written);
        std::fflush(stdout);
      }
    }
    next += interval;
    std::this_thread::sleep_until(next);
  }
  ::close(fd);
  return 0;
}
