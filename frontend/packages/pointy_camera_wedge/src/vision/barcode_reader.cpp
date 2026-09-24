#include "vision/barcode_reader.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <exception>
#include <string>
#include <utility>
#include <vector>

#include "ReadBarcode.h"
#include "vision/transform.h"

namespace pcw {
namespace {

using ZXing::BarcodeFormat;

// The longest edge a rotated attempt is decoded at. Turning a 1280x720 frame
// by 30 degrees makes a 1468x1263 bounding box, which is kept whole; a 1080p
// camera's would be 2202x1895, which is shrunk to fit so an angled pass does
// not cost three straight ones.
constexpr int kMaxRotatedEdge = 1600;

// What a Libyan shop actually meets: retail 1-D on goods, 2-D on payment
// terminal receipts and invoices. Narrower than everything zxing can read on
// purpose: fewer formats is faster and gives stray edges fewer ways to come
// back as a false read. Left out for the same reason: Aztec *runes* (tiny
// one-byte symbols), MaxiCode, and PDF417 — which also cannot be asked for
// without zxing-cpp 3.1's new MicroPDF417 reader, and that reader divides by
// zero on cluttered frames (caught by UBSan in this library's own tests).
// Nothing a till scans at the counter is PDF417.
ZXing::BarcodeFormats LinearFormats() {
  return BarcodeFormat::EANUPC | BarcodeFormat::Code128 |
         BarcodeFormat::Code39 | BarcodeFormat::Code93 | BarcodeFormat::ITF |
         BarcodeFormat::Codabar | BarcodeFormat::DataBar;
}

// QR Model 2 only, not zxing-cpp 3's QRCode family: that family includes
// Micro QR, and a Micro QR finder turns up inside an ordinary QR — the drawn
// sweep read "0123456789" as a Micro QR "567903". A 2-D code is believed on
// one read, so that would have gone straight into the cart. Nothing a till
// scans is Micro QR or rMQR.
ZXing::BarcodeFormats MatrixFormats() {
  return BarcodeFormat::QRCodeModel2 | BarcodeFormat::DataMatrix |
         BarcodeFormat::AztecCode;
}

ZXing::BarcodeFormats WedgeFormats() {
  std::vector<BarcodeFormat> formats;
  for (auto format : LinearFormats()) formats.push_back(format);
  for (auto format : MatrixFormats()) formats.push_back(format);
  return ZXing::BarcodeFormats(std::move(formats));
}

// How many scan lines of one zxing call must agree on a 1-D value (zxing's
// default is 2). With tryHarder and several symbols zxing scans EVERY row of
// a 720p frame, so two agreeing lines are usually two neighbouring rows of
// near-identical pixels, and they agreed on valid-checksum misreads: in the
// drawn sweep (EAN-13, UPC-A, UPC-E at 2-3 px a module, blur, noise, every
// 9 degrees) the misreads that came without the right value beside them
// had 2 or 3 lines, while half the right reads had 27 or more. At 4 no
// EAN-13 or UPC-A misread was left, for 7% of the single-cycle reads of the
// most marginal codes, which get the next frames to read in instead.
constexpr int kMinLines = 4;

// UPC-E is short (51 modules) and its scan lines misread far more: the same
// sweep read real UPC-Es as other valid UPC-Es on up to 5 agreeing lines.
// Rare on Libyan shelves, so it is asked to be plainly legible instead.
constexpr int kMinUpceLines = 8;

// The second 1-D pass reads an image this library has already thresholded
// locally (transform.h, AdaptiveBinarize), so zxing is told to take every
// non-zero pixel as white rather than to work out a threshold of its own.
// 2-D codes stay with zxing's own local binarizer on the grey frame, which
// handles their large solid areas better than a small window would.
ZXing::ReaderOptions BinarizedLinearOptions() {
  ZXing::ReaderOptions options;
  options.setFormats(LinearFormats());
  options.setBinarizer(ZXing::Binarizer::BoolCast);
  options.setTryHarder(true);
  options.setTryRotate(true);
  options.setTryInvert(false);
  options.setTryDownscale(false);
  options.setMaxNumberOfSymbols(4);
  options.setMinLineCount(kMinLines);
  return options;
}

ZXing::ReaderOptions WedgeOptions(bool inverted) {
  ZXing::ReaderOptions options;
  options.setFormats(WedgeFormats());
  // A cashier puts an item down however it lands. With tryHarder off a tilted
  // EAN-13 does not read at all (the linear scanner sweeps a few rows along
  // one axis and nothing crosses the bars); in native code it costs a few
  // milliseconds.
  options.setTryHarder(true);
  options.setTryRotate(true);
  options.setTryInvert(inverted);
  // Lets the 2-D detectors find a large QR in a shrunk copy while the 1-D
  // readers keep the full resolution a narrow bar needs.
  options.setTryDownscale(true);
  // More than one: a box often carries its EAN and a QR side by side, and
  // the policy has to see both to hold each off (confirmation_policy.h).
  options.setMaxNumberOfSymbols(4);
  options.setMinLineCount(kMinLines);
  return options;
}

// One spelling per symbology, the one the app's Dart side already uses, so
// both backends report scans the same way and the trust table in
// policy/symbology.cpp stays a single list of names.
std::string CanonicalName(BarcodeFormat format) {
  switch (format) {
    case BarcodeFormat::EAN13:
    case BarcodeFormat::ISBN:
      return "EAN13";
    case BarcodeFormat::EAN8:
      return "EAN8";
    case BarcodeFormat::UPCA:
      return "UPCA";
    case BarcodeFormat::UPCE:
      return "UPCE";
    case BarcodeFormat::Code128:
      return "Code128";
    case BarcodeFormat::Code93:
      return "Code93";
    case BarcodeFormat::Code39:
    case BarcodeFormat::Code39Std:
    case BarcodeFormat::Code39Ext:
    case BarcodeFormat::Code32:
    case BarcodeFormat::PZN:
      return "Code39";
    case BarcodeFormat::ITF:
    case BarcodeFormat::ITF14:
      return "ITF";
    case BarcodeFormat::Codabar:
      return "Codabar";
    case BarcodeFormat::DataBar:
    case BarcodeFormat::DataBarOmni:
    case BarcodeFormat::DataBarStk:
    case BarcodeFormat::DataBarStkOmni:
    case BarcodeFormat::DataBarLtd:
    case BarcodeFormat::DataBarExp:
    case BarcodeFormat::DataBarExpStk:
      return "DataBar";
    case BarcodeFormat::QRCode:
    case BarcodeFormat::QRCodeModel1:
    case BarcodeFormat::QRCodeModel2:
      return "QRCode";
    case BarcodeFormat::MicroQRCode:
      return "MicroQRCode";
    case BarcodeFormat::RMQRCode:
      return "rMQRCode";
    case BarcodeFormat::DataMatrix:
      return "DataMatrix";
    case BarcodeFormat::Aztec:
    case BarcodeFormat::AztecCode:
    case BarcodeFormat::AztecRune:
      return "Aztec";
    case BarcodeFormat::PDF417:
    case BarcodeFormat::CompactPDF417:
    case BarcodeFormat::MicroPDF417:
      return "PDF417";
    default:
      break;
  }
  // Anything new zxing reports falls through to the least trusted class.
  return std::string(ZXing::Name(format));
}

// What a USB scanner would have typed for this code.
//
// zxing-cpp 3 follows ISO/IEC 15420 and reports every UPC-A and UPC-E as its
// 13-digit EAN-13 form ("0" + the UPC-A digits). A counter scanner, the
// phone decoders and zxing-cpp 2 (the previous Windows wedge) all send UPC-A
// as the 12 digits printed under it, and UPC-E as its 8 — and the catalog
// matches barcodes exactly, so a camera that added a digit would find none of
// the products a scanner had registered. An EAN-13 starting with 0 IS a
// UPC-A (the bars are identical), so it is reported as one.
Reading AsReading(const ZXing::Barcode& barcode) {
  auto text = barcode.text();
  auto name = CanonicalName(barcode.format());
  if (barcode.format() == BarcodeFormat::UPCE) {
    auto printed = barcode.extra(ZXing::BarcodeExtra::UPCE);
    if (!printed.empty()) text = std::move(printed);
  } else if ((barcode.format() == BarcodeFormat::EAN13 ||
              barcode.format() == BarcodeFormat::UPCA) &&
             text.size() == 13 && text.front() == '0') {
    text.erase(0, 1);
    name = "UPCA";
  }
  return {std::move(text), std::move(name), Trust::kUnprotected};
}

// One code as one zxing call found it, before the pass settles conflicts.
struct Found {
  Reading reading;
  ZXing::Position position;
  bool linear = false;
  // Scan lines that agreed on it (1-D only).
  int lines = 0;
};

// Whether the upright boxes around two found codes meet.
bool Overlap(const ZXing::Position& a, const ZXing::Position& b) {
  const auto box = [](const ZXing::Position& corners) {
    std::array<int, 4> ltrb{corners[0].x, corners[0].y, corners[0].x, corners[0].y};
    for (const auto& p : corners) {
      ltrb[0] = std::min(ltrb[0], p.x);
      ltrb[1] = std::min(ltrb[1], p.y);
      ltrb[2] = std::max(ltrb[2], p.x);
      ltrb[3] = std::max(ltrb[3], p.y);
    }
    return ltrb;
  };
  const auto p = box(a);
  const auto q = box(b);
  return p[0] <= q[2] && q[0] <= p[2] && p[1] <= q[3] && q[1] <= p[3];
}

// One pass's finds as readings: each value once, in the order found, and no
// 1-D value lying over the bars of a better-supported one.
//
// Two different 1-D values over the same bars are a right read and a
// misread, and the right one is what more scan lines agree on: in the drawn
// sweep, 64 of the 67 misreads that came beside the right value had fewer
// lines, and summing each value's lines over the pass settles the rest. zxing
// settles this itself, but only within one scan direction of one pyramid
// level of one call, and a pass makes several of each. A tie believes
// neither. Two real codes lying close and tilted can overlap too; the weaker
// then waits until the stronger leaves the view — a delay, never a wrong
// item.
std::vector<Reading> Settle(const std::vector<Found>& found) {
  const auto support = [&](const std::string& text) {
    int lines = 0;
    for (const auto& f : found) {
      if (f.reading.text == text) lines += f.lines;
    }
    return lines;
  };
  std::vector<std::string> beaten;
  for (const auto& a : found) {
    for (const auto& b : found) {
      if (!a.linear || !b.linear || a.reading.text == b.reading.text) continue;
      if (!Overlap(a.position, b.position)) continue;
      if (support(a.reading.text) <= support(b.reading.text)) {
        beaten.push_back(a.reading.text);
      }
    }
  }
  std::vector<Reading> readings;
  for (const auto& f : found) {
    const auto& text = f.reading.text;
    const bool lost = std::find(beaten.begin(), beaten.end(), text) != beaten.end();
    const bool seen = std::any_of(readings.begin(), readings.end(),
                                  [&](const Reading& r) { return r.text == text; });
    if (!lost && !seen) readings.push_back(f.reading);
  }
  return readings;
}

}  // namespace

struct BarcodeReader::Impl {
  ZXing::ReaderOptions normal = WedgeOptions(false);
  ZXing::ReaderOptions inverted = WedgeOptions(true);
  ZXing::ReaderOptions binarized_linear = BinarizedLinearOptions();
  LumaImage rotated;
  LumaImage binarized;
  std::vector<uint32_t> integral;

  void Collect(const LumaImage& image, const ZXing::ReaderOptions& options,
               std::vector<Found>& found) {
    const ZXing::ImageView view(image.pixels.data(), image.width, image.height,
                                ZXing::ImageFormat::Lum);
    for (const auto& barcode : ZXing::ReadBarcodes(view, options)) {
      if (!barcode.isValid()) continue;
      const bool linear = barcode.format() <= BarcodeFormat::AllLinear;
      const int lines = linear ? barcode.lineCount() : 0;
      if (barcode.format() == BarcodeFormat::UPCE && lines < kMinUpceLines) continue;
      auto reading = AsReading(barcode);
      reading.trust = ClassifySymbology(reading.symbology);
      found.push_back({std::move(reading), barcode.position(), linear, lines});
    }
  }
};

BarcodeReader::BarcodeReader() : impl_(std::make_unique<Impl>()) {}

BarcodeReader::~BarcodeReader() = default;

std::vector<Reading> BarcodeReader::Read(const LumaImage& frame,
                                         const DecodeAttempt& attempt) {
  if (frame.empty()) return {};

  const LumaImage* image = &frame;
  const int angle = ((attempt.angle % 360) + 360) % 360;
  if (angle != 0) {
    constexpr double kPi = 3.14159265358979323846;
    const double radians = angle * kPi / 180.0;
    const double grown =
        std::max(frame.width, frame.height) *
        (std::abs(std::cos(radians)) + std::abs(std::sin(radians)));
    const double scale = std::min(1.0, kMaxRotatedEdge / grown);
    // White corners: they meet a code's quiet zone the way the paper around
    // it would, where black ones would read as an extra bar.
    RotateScaled(frame, angle, scale, 255, impl_->rotated);
    image = &impl_->rotated;
  }

  std::vector<Found> found;
  try {
    if (attempt.inverted) {
      impl_->Collect(*image, impl_->inverted, found);
    } else {
      // zxing as it comes, then 1-D again on a locally thresholded copy for
      // the soft barcode on a big plain counter that the first pass cannot
      // separate from it (transform.h, AdaptiveBinarize).
      impl_->Collect(*image, impl_->normal, found);
      const int radius = std::max(12, std::max(image->width, image->height) / 32);
      AdaptiveBinarize(*image, radius, impl_->binarized, impl_->integral);
      impl_->Collect(impl_->binarized, impl_->binarized_linear, found);
    }
  } catch (const std::exception&) {
    // zxing throws on malformed input only; a frame is not worth a crash.
    return {};
  }
  return Settle(found);
}

}  // namespace pcw
