// Drawn scenes as JPEG frames, the way a webcam's MJPEG stream carries them.
//
// Test builds only (the synthetic camera, the native tests and the V4L2
// loopback feeder): it encodes with stb_image_write, which the product never
// links. stb_image_write uses the standard Huffman tables, so removing its
// DHT segment gives exactly the frame a UVC camera sends.
#pragma once

#include <cstdint>
#include <vector>

#include "vision/luma_image.h"

namespace pcw {

struct JpegWriteOptions {
  // 1-100. stb_image_write subsamples colour (4:2:0) at 90 and below.
  int quality = 85;
  // Three components (YCbCr, grey picture) like a colour webcam, or one.
  bool color = true;
  // Leave out the DHT segment, as most UVC cameras do.
  bool without_huffman_tables = false;
};

std::vector<uint8_t> EncodeJpeg(const LumaImage& image,
                                const JpegWriteOptions& options = {});

// `jpeg` with every DHT segment removed.
std::vector<uint8_t> WithoutHuffmanTables(const std::vector<uint8_t>& jpeg);

}  // namespace pcw
