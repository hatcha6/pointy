#include "capture/jpeg_decoder.h"

#include <climits>

#include "capture/stb_image_config.h"

namespace pcw {
namespace {

constexpr uint8_t kMarker = 0xFF;
constexpr uint8_t kStartOfImage = 0xD8;
constexpr uint8_t kEndOfImage = 0xD9;
constexpr uint8_t kStartOfScan = 0xDA;
constexpr uint8_t kHuffmanTables = 0xC4;

// One Huffman table as a DHT segment carries it: class and id, how many codes
// there are of each length 1-16, then the symbols in code order.
struct HuffmanTable {
  uint8_t class_and_id;
  uint8_t counts[16];
  const uint8_t* symbols;
  size_t symbol_count;
};

// JPEG Annex K.3, the tables an MJPEG frame without a DHT segment means.
constexpr uint8_t kDcSymbols[] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11};
constexpr uint8_t kAcLuminanceSymbols[] = {
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06,
    0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
    0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72,
    0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45,
    0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
    0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75,
    0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3,
    0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
    0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9,
    0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4,
    0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa};
constexpr uint8_t kAcChrominanceSymbols[] = {
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41,
    0x51, 0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
    0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15, 0x62, 0x72, 0xd1,
    0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44,
    0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
    0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74,
    0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a,
    0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
    0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7,
    0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4,
    0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa};

constexpr HuffmanTable kStandardTables[] = {
    {0x00, {0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0}, kDcSymbols,
     sizeof(kDcSymbols)},
    {0x10, {0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d}, kAcLuminanceSymbols,
     sizeof(kAcLuminanceSymbols)},
    {0x01, {0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0}, kDcSymbols,
     sizeof(kDcSymbols)},
    {0x11, {0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77},
     kAcChrominanceSymbols, sizeof(kAcChrominanceSymbols)},
};

// The four tables as one DHT segment, marker and length included.
std::vector<uint8_t> StandardHuffmanSegment() {
  std::vector<uint8_t> body;
  for (const auto& table : kStandardTables) {
    body.push_back(table.class_and_id);
    body.insert(body.end(), table.counts, table.counts + 16);
    body.insert(body.end(), table.symbols, table.symbols + table.symbol_count);
  }
  const size_t length = body.size() + 2;
  std::vector<uint8_t> segment = {kMarker, kHuffmanTables,
                                  static_cast<uint8_t>(length >> 8),
                                  static_cast<uint8_t>(length & 0xFF)};
  segment.insert(segment.end(), body.begin(), body.end());
  return segment;
}

}  // namespace

JpegFrameInfo InspectJpeg(const uint8_t* data, size_t size) {
  JpegFrameInfo info;
  if (data == nullptr || size < 4 || data[0] != kMarker ||
      data[1] != kStartOfImage) {
    return info;
  }
  size_t i = 2;
  while (true) {
    if (i >= size || data[i] != kMarker) return info;
    // Any number of 0xFF fill bytes may precede a marker.
    while (i < size && data[i] == kMarker) ++i;
    if (i >= size) return info;
    const uint8_t marker = data[i++];
    if (marker == kStartOfScan) {
      info.scan_offset = i - 2;
      break;
    }
    if (marker == kStartOfImage || marker == kEndOfImage || marker == 0x00) {
      return info;
    }
    // TEM and RST0-7 stand alone; every other marker has a length.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue;
    if (i + 2 > size) return info;
    const size_t length = (static_cast<size_t>(data[i]) << 8) | data[i + 1];
    if (length < 2 || i + length > size) return info;
    if (marker == kHuffmanTables) info.has_huffman_tables = true;
    i += length;
  }
  info.valid = true;
  size_t end = size;
  while (end > info.scan_offset && data[end - 1] == 0x00) --end;
  info.complete = end >= info.scan_offset + 4 && data[end - 2] == kMarker &&
                  data[end - 1] == kEndOfImage;
  return info;
}

void InsertStandardHuffmanTables(const uint8_t* data, size_t size,
                                 size_t scan_offset, std::vector<uint8_t>& out) {
  static const std::vector<uint8_t> segment = StandardHuffmanSegment();
  out.clear();
  out.reserve(size + segment.size());
  out.insert(out.end(), data, data + scan_offset);
  out.insert(out.end(), segment.begin(), segment.end());
  out.insert(out.end(), data + scan_offset, data + size);
}

JpegDecoder::~JpegDecoder() { ReleasePixels(); }

void JpegDecoder::ReleasePixels() {
  if (pixels_ != nullptr) stbi_image_free(pixels_);
  pixels_ = nullptr;
}

bool JpegDecoder::Decode(const uint8_t* data, size_t size, PixelBuffer& out) {
  ReleasePixels();
  out = PixelBuffer{};
  const auto info = InspectJpeg(data, size);
  if (!info.valid) {
    last_error_ = "not a JPEG frame";
    return false;
  }
  if (!info.complete) {
    last_error_ = "the frame was cut short";
    return false;
  }
  const uint8_t* bytes = data;
  size_t length = size;
  if (!info.has_huffman_tables) {
    InsertStandardHuffmanTables(data, size, info.scan_offset, patched_);
    bytes = patched_.data();
    length = patched_.size();
  }
  if (length > static_cast<size_t>(INT_MAX)) {
    last_error_ = "the frame is too large";
    return false;
  }
  int width = 0;
  int height = 0;
  int components = 0;
  pixels_ = stbi_load_from_memory(bytes, static_cast<int>(length), &width,
                                  &height, &components, 1);
  if (pixels_ == nullptr) {
    const char* reason = stbi_failure_reason();
    last_error_ = reason != nullptr ? reason : "the frame could not be decoded";
    return false;
  }
  out.format = PixelFormat::kGray8;
  out.width = width;
  out.height = height;
  out.data = pixels_;
  out.stride = width;
  last_error_.clear();
  return true;
}

}  // namespace pcw
