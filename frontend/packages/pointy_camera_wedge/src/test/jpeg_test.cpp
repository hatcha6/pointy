// The MJPEG path (capture/jpeg_decoder.h): drawn counters encoded the way a
// webcam encodes them, and every way a camera's frame can be odd — no
// Huffman tables, cut short, padded, corrupt — against what the decoder
// makes of it. The fuzz cases matter most under the sanitizer builds in CI.
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "capture/jpeg_decoder.h"
#include "engine/decode_scheduler.h"
#include "platform/synthetic/jpeg_writer.h"
#include "platform/synthetic/scene.h"
#include "test/check.h"
#include "vision/barcode_reader.h"
#include "vision/luma_extract.h"

namespace {

using pcw::JpegDecoder;
using pcw::JpegWriteOptions;
using pcw::LumaImage;
using pcw::PixelBuffer;

LumaImage Counter(const std::string& format, const std::string& text, int angle = 0,
                  int noise = 4) {
  pcw::SceneSpec spec;
  spec.format = format;
  spec.text = text;
  spec.angle = angle;
  spec.noise = noise;
  return pcw::RenderScene(spec);
}

std::vector<uint8_t> Jpeg(const LumaImage& image, int quality, bool color,
                          bool without_tables = false) {
  JpegWriteOptions options;
  options.quality = quality;
  options.color = color;
  options.without_huffman_tables = without_tables;
  return pcw::EncodeJpeg(image, options);
}

LumaImage Decoded(const std::vector<uint8_t>& jpeg) {
  JpegDecoder decoder;
  PixelBuffer frame;
  if (!decoder.Decode(jpeg.data(), jpeg.size(), frame)) {
    pcwtest::Fail(__FILE__, __LINE__, "refused: " + decoder.last_error());
  }
  LumaImage image;
  CHECK(pcw::ExtractLuma(frame, image));
  return image;
}

double MeanDifference(const LumaImage& a, const LumaImage& b) {
  CHECK_EQ(a.width, b.width);
  CHECK_EQ(a.height, b.height);
  double sum = 0;
  for (size_t i = 0; i < a.pixels.size(); ++i) sum += std::abs(a.pixels[i] - b.pixels[i]);
  return sum / static_cast<double>(a.pixels.size());
}

// Every distinct value one full decode cycle reads.
std::vector<std::string> ReadCycle(const LumaImage& frame) {
  pcw::BarcodeReader reader;
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

bool Reads(const LumaImage& frame, const std::string& text) {
  for (const auto& value : ReadCycle(frame)) {
    if (value == text) return true;
  }
  return false;
}

// Deterministic, so a failure reproduces.
struct XorShift {
  uint64_t state = 0x9E3779B97F4A7C15ull;
  uint64_t Next() {
    state ^= state << 13;
    state ^= state >> 7;
    state ^= state << 17;
    return state;
  }
  size_t Below(size_t n) { return static_cast<size_t>(Next() % n); }
};

PCW_TEST(a_jpeg_frame_decodes_to_the_picture_it_was_made_from) {
  const auto scene = Counter("EAN13", "3600523434725", 0, /*noise=*/0);
  for (const bool color : {true, false}) {
    for (const int quality : {50, 85, 95}) {
      const auto decoded = Decoded(Jpeg(scene, quality, color));
      const double difference = MeanDifference(decoded, scene);
      if (difference > (quality < 80 ? 6.0 : 3.0)) {
        pcwtest::Fail(__FILE__, __LINE__,
                      "quality " + std::to_string(quality) + (color ? " colour" : " grey") +
                          " is " + std::to_string(difference) + " grey levels off");
      }
    }
  }
}

PCW_TEST(a_frame_without_huffman_tables_decodes_exactly_like_one_with_them) {
  // stb_image would decode it without complaint into garbage; the standard
  // tables are what a UVC camera means by leaving them out.
  const auto scene = Counter("QRCode", "pay://receipt/9f2");
  for (const bool color : {true, false}) {
    // 4:2:0 at 90 and below, 4:4:4 above, in stb_image_write.
    for (const int quality : {75, 95}) {
      const auto with = Jpeg(scene, quality, color);
      const auto without = Jpeg(scene, quality, color, /*without_tables=*/true);
      CHECK(pcw::InspectJpeg(with.data(), with.size()).has_huffman_tables);
      CHECK(!pcw::InspectJpeg(without.data(), without.size()).has_huffman_tables);
      CHECK(without.size() < with.size());
      CHECK(Decoded(without).pixels == Decoded(with).pixels);
    }
  }
}

PCW_TEST(a_frame_from_a_webcam_encoder_decodes_and_reads) {
  // Encoded by ffmpeg the way UVC firmware encodes: 4:2:2, the standard
  // Huffman tables, and then the DHT segment left out (test/data/README.md).
  std::ifstream in(std::string(PCW_TEST_DATA_DIR) + "/uvc_422_nodht_ean13.jpg",
                   std::ios::binary);
  const std::vector<uint8_t> jpeg((std::istreambuf_iterator<char>(in)),
                                  std::istreambuf_iterator<char>());
  CHECK(!jpeg.empty());
  const auto info = pcw::InspectJpeg(jpeg.data(), jpeg.size());
  CHECK(info.valid);
  CHECK(info.complete);
  CHECK(!info.has_huffman_tables);
  CHECK(Reads(Decoded(jpeg), "3600523434725"));
}

PCW_TEST(barcodes_survive_webcam_compression) {
  // Quality 75 with 4:2:0 colour is rougher than any webcam's MJPEG.
  CHECK(Reads(Decoded(Jpeg(Counter("EAN13", "3600523434725"), 75, true, true)),
              "3600523434725"));
  CHECK(Reads(Decoded(Jpeg(Counter("EAN13", "3600523434725", 30), 75, true, true)),
              "3600523434725"));
  CHECK(Reads(Decoded(Jpeg(Counter("QRCode", "pay://receipt/9f2"), 75, true, true)),
              "pay://receipt/9f2"));
}

PCW_TEST(a_frame_cut_short_is_refused_rather_than_decoded_as_zeros) {
  const auto jpeg = Jpeg(Counter("EAN13", "3600523434725"), 85, true);
  for (const size_t keep : {jpeg.size() / 4, jpeg.size() / 2, jpeg.size() - 3, jpeg.size() - 1}) {
    JpegDecoder decoder;
    PixelBuffer frame;
    CHECK(!decoder.Decode(jpeg.data(), keep, frame));
    CHECK_EQ(decoder.last_error(), std::string("the frame was cut short"));
    CHECK(frame.data == nullptr);
  }
}

PCW_TEST(zero_padding_after_the_end_marker_is_accepted) {
  // Some drivers report the whole buffer as used.
  auto jpeg = Jpeg(Counter("QRCode", "padded"), 85, true, true);
  const auto plain = Decoded(jpeg);
  jpeg.insert(jpeg.end(), 4096, 0);
  CHECK(Decoded(jpeg).pixels == plain.pixels);
}

PCW_TEST(things_that_are_not_jpeg_frames_are_refused) {
  JpegDecoder decoder;
  PixelBuffer frame;
  const std::vector<std::vector<uint8_t>> refused = {
      {},
      {'h', 'e', 'l', 'l', 'o'},
      {0xFF, 0xD8, 0xFF, 0xD9},              // SOI then EOI: no scan
      {0xFF, 0xD8, 0xFF, 0xDB, 0x40, 0x00},  // a segment longer than the frame
      {0x00, 0xFF, 0xD8, 0xFF, 0xDA},        // not starting with SOI
  };
  for (const auto& bytes : refused) {
    CHECK(!decoder.Decode(bytes.data(), bytes.size(), frame));
    CHECK(frame.data == nullptr);
  }
  XorShift random;
  std::vector<uint8_t> noise(4096);
  for (auto& byte : noise) byte = static_cast<uint8_t>(random.Next());
  CHECK(!decoder.Decode(noise.data(), noise.size(), frame));
}

PCW_TEST(a_frame_claiming_an_impossible_size_is_refused_before_allocating) {
  auto jpeg = Jpeg(Counter("QRCode", "big"), 85, false);
  // Patch the SOF0 header to 20000x20000.
  bool patched = false;
  for (size_t i = 0; i + 9 < jpeg.size(); ++i) {
    if (jpeg[i] == 0xFF && jpeg[i + 1] == 0xC0) {
      jpeg[i + 5] = 0x4E;
      jpeg[i + 6] = 0x20;
      jpeg[i + 7] = 0x4E;
      jpeg[i + 8] = 0x20;
      patched = true;
      break;
    }
  }
  CHECK(patched);
  JpegDecoder decoder;
  PixelBuffer frame;
  CHECK(!decoder.Decode(jpeg.data(), jpeg.size(), frame));
}

PCW_TEST(corrupt_frames_never_crash_the_decoder) {
  // A USB hiccup that the driver does not flag: bytes changed anywhere, the
  // end marker intact. Any outcome is fine except a crash, a hang, or (under
  // the sanitizers) a bad memory access.
  const auto source = Counter("EAN13", "3600523434725");
  const std::vector<std::vector<uint8_t>> originals = {
      Jpeg(source, 85, true, true), Jpeg(source, 95, true), Jpeg(source, 85, false)};
  XorShift random;
  JpegDecoder decoder;
  int decoded = 0;
  for (int round = 0; round < 1500; ++round) {
    auto jpeg = originals[static_cast<size_t>(round) % originals.size()];
    const size_t scan = pcw::InspectJpeg(jpeg.data(), jpeg.size()).scan_offset;
    // Mostly the entropy-coded data, sometimes the headers too.
    const size_t from = round % 4 == 0 ? 2 : scan;
    const int flips = 1 + static_cast<int>(random.Below(24));
    for (int f = 0; f < flips; ++f) {
      jpeg[from + random.Below(jpeg.size() - 2 - from)] = static_cast<uint8_t>(random.Next());
    }
    PixelBuffer frame;
    if (decoder.Decode(jpeg.data(), jpeg.size(), frame)) {
      ++decoded;
      CHECK(frame.width > 0 && frame.width <= 8192);
      CHECK(frame.height > 0 && frame.height <= 8192);
      CHECK(frame.data != nullptr);
    }
  }
  // Damage in the scan mostly still decodes: the frame arrives, wrong in
  // places, and the confirmation policy deals with what zxing makes of it.
  CHECK(decoded > 0);
}

PCW_TEST(inspect_finds_the_scan_tables_and_end) {
  const auto jpeg = Jpeg(Counter("QRCode", "inspect"), 85, true);
  const auto info = pcw::InspectJpeg(jpeg.data(), jpeg.size());
  CHECK(info.valid);
  CHECK(info.complete);
  CHECK(info.has_huffman_tables);
  CHECK_EQ(static_cast<int>(jpeg[info.scan_offset]), 0xFF);
  CHECK_EQ(static_cast<int>(jpeg[info.scan_offset + 1]), 0xDA);
}

}  // namespace
