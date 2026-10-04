#include "platform/synthetic/jpeg_writer.h"

#define STBI_WRITE_NO_STDIO
#include "third_party/stb/stb_image_write.h"

namespace pcw {
namespace {

void Append(void* context, void* data, int size) {
  auto* out = static_cast<std::vector<uint8_t>*>(context);
  const auto* bytes = static_cast<const uint8_t*>(data);
  out->insert(out->end(), bytes, bytes + size);
}

}  // namespace

std::vector<uint8_t> EncodeJpeg(const LumaImage& image,
                                const JpegWriteOptions& options) {
  std::vector<uint8_t> jpeg;
  if (image.empty()) return jpeg;
  if (options.color) {
    std::vector<uint8_t> rgb;
    rgb.reserve(image.pixels.size() * 3);
    for (const auto value : image.pixels) rgb.insert(rgb.end(), {value, value, value});
    stbi_write_jpg_to_func(&Append, &jpeg, image.width, image.height, 3, rgb.data(),
                           options.quality);
  } else {
    stbi_write_jpg_to_func(&Append, &jpeg, image.width, image.height, 1,
                           image.pixels.data(), options.quality);
  }
  return options.without_huffman_tables ? WithoutHuffmanTables(jpeg) : jpeg;
}

std::vector<uint8_t> WithoutHuffmanTables(const std::vector<uint8_t>& jpeg) {
  if (jpeg.size() < 4) return jpeg;
  std::vector<uint8_t> out(jpeg.begin(), jpeg.begin() + 2);
  size_t i = 2;
  while (i + 4 <= jpeg.size() && jpeg[i] == 0xFF) {
    const uint8_t marker = jpeg[i + 1];
    if (marker == 0xDA) break;  // the scan and everything after it is kept
    const size_t length = (static_cast<size_t>(jpeg[i + 2]) << 8) | jpeg[i + 3];
    if (i + 2 + length > jpeg.size()) break;
    if (marker != 0xC4) {
      out.insert(out.end(), jpeg.begin() + static_cast<ptrdiff_t>(i),
                 jpeg.begin() + static_cast<ptrdiff_t>(i + 2 + length));
    }
    i += 2 + length;
  }
  out.insert(out.end(), jpeg.begin() + static_cast<ptrdiff_t>(i), jpeg.end());
  return out;
}

}  // namespace pcw
