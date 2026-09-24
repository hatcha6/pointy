// zxing-cpp as the wedge configures it, on drawn counters.
//
// The orientation test is the one that matters: the camera lab watched a
// tilted EAN-13 sit unread for 14.7 seconds because nothing crossed its bars.
// The decode cycle (engine/decode_scheduler.h) claims to cover every angle in
// four passes; this proves it, five degrees at a time, all the way round.
#include <chrono>
#include <iostream>
#include <string>
#include <vector>

#include "engine/decode_scheduler.h"
#include "platform/synthetic/scene.h"
#include "policy/symbology.h"
#include "test/check.h"
#include "vision/barcode_reader.h"

namespace {

using pcw::BarcodeReader;
using pcw::DecodeAttempt;
using pcw::SceneSpec;

SceneSpec Scene(const std::string& format, const std::string& text, int angle = 0,
                int module = 3) {
  SceneSpec spec;
  spec.format = format;
  spec.text = text;
  spec.angle = angle;
  spec.module = module;
  spec.noise = 4;
  return spec;
}

// Runs one full decode cycle and returns every distinct value read.
std::vector<std::string> ReadCycle(BarcodeReader& reader, const pcw::LumaImage& frame) {
  std::vector<std::string> values;
  for (const auto& attempt : pcw::DecodeScheduler::kCycle) {
    for (const auto& reading : reader.Read(frame, attempt)) {
      bool seen = false;
      for (const auto& v : values) seen = seen || v == reading.text;
      if (!seen) values.push_back(reading.text);
    }
  }
  return values;
}

PCW_TEST(every_symbology_the_wedge_reads_is_read_straight_on) {
  struct Case {
    const char* format;
    const char* text;
    pcw::Trust trust;
  };
  const Case cases[] = {
      {"EAN13", "3600523434725", pcw::Trust::kCheckDigit},
      {"EAN8", "96385074", pcw::Trust::kCheckDigit},
      // Reported as a counter scanner types them, not as zxing-cpp 3's
      // 13-digit normal form: the catalog matches barcodes exactly.
      {"UPCA", "036000291452", pcw::Trust::kCheckDigit},
      {"UPCE", "01234565", pcw::Trust::kCheckDigit},
      {"Code128", "POINTY-128", pcw::Trust::kCheckDigit},
      {"Code39", "POINTY39", pcw::Trust::kUnprotected},
      {"ITF", "12345678901231", pcw::Trust::kUnprotected},
      {"Codabar", "A123456A", pcw::Trust::kUnprotected},
      {"QRCode", "pay://receipt/9f2", pcw::Trust::kErrorCorrected},
      {"DataMatrix", "DM-12345", pcw::Trust::kErrorCorrected},
      {"Aztec", "AZTEC-1", pcw::Trust::kErrorCorrected},
  };
  BarcodeReader reader;
  for (const auto& c : cases) {
    const auto frame = pcw::RenderScene(Scene(c.format, c.text));
    const auto readings = reader.Read(frame, DecodeAttempt{0, false});
    if (readings.empty()) {
      pcwtest::Fail(__FILE__, __LINE__, std::string("nothing read for ") + c.format);
    }
    CHECK_EQ(readings.front().symbology, std::string(c.format));
    // Codabar keeps its start/stop characters or not depending on the
    // decoder; the payload is what has to survive.
    if (std::string(c.format) != "Codabar") {
      CHECK_EQ(readings.front().text, std::string(c.text));
    }
    CHECK(readings.front().trust == c.trust);
  }
}

PCW_TEST(one_decode_cycle_reads_an_ean13_at_every_angle) {
  BarcodeReader reader;
  const std::string truth = "3600523434725";
  std::vector<int> missed;
  for (int angle = 0; angle < 360; angle += 5) {
    const auto frame = pcw::RenderScene(Scene("EAN13", truth, angle));
    const auto values = ReadCycle(reader, frame);
    bool found = false;
    for (const auto& value : values) {
      if (value == truth) found = true;
      // A clean drawn code must never read as anything else.
      CHECK_EQ(value, truth);
    }
    if (!found) missed.push_back(angle);
  }
  if (!missed.empty()) {
    std::string list;
    for (int angle : missed) list += std::to_string(angle) + " ";
    pcwtest::Fail(__FILE__, __LINE__, "angles never read: " + list);
  }
}

PCW_TEST(one_decode_cycle_reads_a_qr_at_every_angle) {
  BarcodeReader reader;
  const std::string truth = "https://pay.example/r/9f2c";
  for (int angle = 0; angle < 360; angle += 15) {
    const auto frame = pcw::RenderScene(Scene("QRCode", truth, angle));
    const auto values = ReadCycle(reader, frame);
    CHECK(values.size() == 1 && values.front() == truth);
  }
}

PCW_TEST(a_small_soft_barcode_still_reads) {
  // Two pixels a module and a camera slightly out of focus: roughly an
  // EAN-13 a third of a metre under a 720p webcam.
  BarcodeReader reader;
  auto spec = Scene("EAN13", "6111245701233", 0, 2);
  spec.blur = 1;
  spec.noise = 6;
  const auto frame = pcw::RenderScene(spec);
  const auto values = ReadCycle(reader, frame);
  CHECK(values.size() == 1 && values.front() == "6111245701233");
}

// Frames the drawn sweep once misread, each as a value with a valid check
// digit (or, for the QR, error correction) that a till would have rung up.
// Reading the right value is not the point here: reading nothing else is.
void CheckReadsNothingBut(const SceneSpec& spec, const std::string& truth) {
  BarcodeReader reader;
  for (const auto& value : ReadCycle(reader, pcw::RenderScene(spec))) {
    if (value != truth) {
      pcwtest::Fail(__FILE__, __LINE__, spec.format + " " + truth + " misread as " + value);
    }
  }
}

SceneSpec Exact(const std::string& format, const std::string& text, int module,
                int blur, int noise, int angle) {
  auto spec = Scene(format, text, angle, module);
  spec.blur = blur;
  spec.noise = noise;
  return spec;
}

PCW_TEST(two_neighbouring_scan_lines_are_not_enough_for_a_1d_value) {
  // Digits 7 and 9 trade places: equal weights, so the check digit cannot
  // see it. Two to three agreeing lines of the thresholded pass.
  CheckReadsNothingBut(Exact("EAN13", "6281007014359", 2, 1, 0, 27), "6281007014359");
  CheckReadsNothingBut(Exact("EAN13", "3600523434725", 2, 1, 8, 72), "3600523434725");
}

PCW_TEST(a_misread_beside_the_right_value_loses_to_it) {
  // zxing returned the right UPC-E on 27 lines AND two other valid UPC-Es on
  // 2-3 lines over the same bars, from different scan directions.
  CheckReadsNothingBut(Exact("UPCE", "06543217", 3, 0, 0, 108), "06543217");
  CheckReadsNothingBut(Exact("UPCE", "04252614", 3, 0, 16, 0), "04252614");
}

PCW_TEST(a_qr_is_not_read_as_the_micro_qr_inside_it) {
  CheckReadsNothingBut(Exact("QRCode", "0123456789", 4, 2, 16, 0), "0123456789");
  BarcodeReader reader;
  const auto values =
      ReadCycle(reader, pcw::RenderScene(Exact("QRCode", "0123456789", 4, 0, 0, 0)));
  CHECK(values.size() == 1 && values.front() == "0123456789");
}

PCW_TEST(an_empty_counter_reads_nothing) {
  BarcodeReader reader;
  auto spec = Scene("EAN13", "");
  spec.noise = 10;
  const auto frame = pcw::RenderScene(spec);
  CHECK(ReadCycle(reader, frame).empty());
}

PCW_TEST(an_inverted_qr_is_read_by_the_inverted_pass) {
  // White modules on black, as on a phone in dark mode.
  BarcodeReader reader;
  auto frame = pcw::RenderScene(Scene("QRCode", "dark-mode-qr"));
  for (auto& pixel : frame.pixels) pixel = static_cast<uint8_t>(255 - pixel);
  CHECK(reader.Read(frame, DecodeAttempt{0, false}).empty());
  const auto inverted = reader.Read(frame, DecodeAttempt{0, true});
  CHECK(inverted.size() == 1 && inverted.front().text == "dark-mode-qr");
}

PCW_TEST(decode_cost_per_pass_at_720p) {
  // Informational (the numbers are machine-dependent) with a generous
  // ceiling that only a pathological regression would reach.
  BarcodeReader reader;
  const auto frame = pcw::RenderScene(Scene("EAN13", "3600523434725", 20));
  for (const auto& attempt : pcw::DecodeScheduler::kCycle) {
    constexpr int kRuns = 5;
    const auto started = std::chrono::steady_clock::now();
    for (int i = 0; i < kRuns; ++i) reader.Read(frame, attempt);
    const double ms = std::chrono::duration<double, std::milli>(
                          std::chrono::steady_clock::now() - started)
                          .count() /
                      kRuns;
    std::cout << "    pass angle=" << attempt.angle
              << (attempt.inverted ? " inverted" : "") << ": " << ms << " ms\n";
    CHECK(ms < 1000.0);
  }
}

}  // namespace
