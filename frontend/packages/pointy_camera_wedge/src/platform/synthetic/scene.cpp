#include "platform/synthetic/scene.h"

#include <algorithm>
#include <cmath>
#include <vector>

#include "BitMatrix.h"
#include "MultiFormatWriter.h"

namespace pcw {
namespace {

ZXing::BarcodeFormat FormatFromName(const std::string& name) {
  using ZXing::BarcodeFormat;
  if (name == "EAN13") return BarcodeFormat::EAN13;
  if (name == "EAN8") return BarcodeFormat::EAN8;
  if (name == "UPCA") return BarcodeFormat::UPCA;
  if (name == "UPCE") return BarcodeFormat::UPCE;
  if (name == "Code128") return BarcodeFormat::Code128;
  if (name == "Code93") return BarcodeFormat::Code93;
  if (name == "Code39") return BarcodeFormat::Code39;
  if (name == "ITF") return BarcodeFormat::ITF;
  if (name == "Codabar") return BarcodeFormat::Codabar;
  if (name == "DataMatrix") return BarcodeFormat::DataMatrix;
  if (name == "Aztec") return BarcodeFormat::AztecCode;
  if (name == "PDF417") return BarcodeFormat::PDF417;
  return BarcodeFormat::QRCode;
}

// The code's modules as a grid: `dark[y * columns + x]`.
struct Modules {
  int columns = 0;
  int rows = 0;
  bool linear = false;
  std::vector<bool> dark;
};

Modules Encode(const SceneSpec& spec) {
  Modules modules;
#if defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
#elif defined(_MSC_VER)
#pragma warning(push)
#pragma warning(disable : 4996)
#endif
  // The "old" writer: it needs no third-party encoder library, which keeps
  // this test-only code from pulling one into the build.
  ZXing::MultiFormatWriter writer(FormatFromName(spec.format));
#if defined(__GNUC__)
#pragma GCC diagnostic pop
#elif defined(_MSC_VER)
#pragma warning(pop)
#endif
  writer.setMargin(0);
  const auto matrix = writer.encode(spec.text, 0, 0);
  modules.columns = matrix.width();
  modules.linear = matrix.height() == 1;
  // A retail barcode is about 0.7 of its width tall; enough bars for any scan
  // line that crosses the code at less than ~35 degrees to see all of them.
  modules.rows = modules.linear
                     ? std::max(1, static_cast<int>(modules.columns * 0.7))
                     : matrix.height();
  modules.dark.resize(static_cast<size_t>(modules.columns) * modules.rows);
  for (int y = 0; y < modules.rows; ++y) {
    for (int x = 0; x < modules.columns; ++x) {
      modules.dark[static_cast<size_t>(y) * modules.columns + x] =
          matrix.get(x, modules.linear ? 0 : y);
    }
  }
  return modules;
}

void BoxBlur(LumaImage& image, int radius) {
  if (radius <= 0 || image.empty()) return;
  LumaImage copy = image;
  for (int y = 0; y < image.height; ++y) {
    for (int x = 0; x < image.width; ++x) {
      int sum = 0;
      int count = 0;
      for (int dy = -radius; dy <= radius; ++dy) {
        const int yy = std::clamp(y + dy, 0, image.height - 1);
        for (int dx = -radius; dx <= radius; ++dx) {
          const int xx = std::clamp(x + dx, 0, image.width - 1);
          sum += copy.row(yy)[xx];
          ++count;
        }
      }
      image.row(y)[x] = static_cast<uint8_t>(sum / count);
    }
  }
}

}  // namespace

LumaImage RenderScene(const SceneSpec& spec) {
  LumaImage frame;
  frame.Resize(spec.width, spec.height);
  std::fill(frame.pixels.begin(), frame.pixels.end(), spec.background);

  if (!spec.text.empty()) {
    const auto modules = Encode(spec);
    // A white label around the code: its quiet zone, as a sticker has.
    const int quiet_x = modules.linear ? 11 : 4;
    const int quiet_y = 4;
    const int module = std::max(1, spec.module);
    const double label_w = (modules.columns + 2 * quiet_x) * module;
    const double label_h = (modules.rows + 2 * quiet_y) * module;

    constexpr double kPi = 3.14159265358979323846;
    const double radians = spec.angle * kPi / 180.0;
    const double cos_t = std::cos(radians);
    const double sin_t = std::sin(radians);
    const double cx = spec.width / 2.0;
    const double cy = spec.height / 2.0;
    for (int y = 0; y < spec.height; ++y) {
      uint8_t* row = frame.row(y);
      for (int x = 0; x < spec.width; ++x) {
        // Inverse-rotate this frame pixel into label coordinates.
        const double dx = x + 0.5 - cx;
        const double dy = y + 0.5 - cy;
        const double lx = cos_t * dx + sin_t * dy + label_w / 2.0;
        const double ly = -sin_t * dx + cos_t * dy + label_h / 2.0;
        if (lx < 0 || ly < 0 || lx >= label_w || ly >= label_h) continue;
        const int mx = static_cast<int>(lx / module) - quiet_x;
        const int my = static_cast<int>(ly / module) - quiet_y;
        const bool dark = mx >= 0 && my >= 0 && mx < modules.columns &&
                          my < modules.rows &&
                          modules.dark[static_cast<size_t>(my) * modules.columns + mx];
        row[x] = dark ? 25 : 235;
      }
    }
  }

  BoxBlur(frame, spec.blur);

  if (spec.noise > 0) {
    // Deterministic, so a failing test fails the same way every run.
    uint32_t state = 0x9E3779B9u;
    for (auto& pixel : frame.pixels) {
      state ^= state << 13;
      state ^= state >> 17;
      state ^= state << 5;
      const int delta =
          static_cast<int>(state % (2 * spec.noise + 1)) - spec.noise;
      pixel = static_cast<uint8_t>(std::clamp(pixel + delta, 0, 255));
    }
  }
  return frame;
}

}  // namespace pcw
