// Motion JPEG frames to grey, for camera APIs that hand frames over compressed.
//
// Media Foundation decodes MJPEG itself (the Windows backend asks it for NV12).
// V4L2 does not: a Linux webcam's MJPEG frames arrive exactly as the camera
// sent them. And most USB 2 webcams only reach 1280x720 at 30 fps in MJPEG —
// uncompressed 720p does not fit through USB 2 at that rate — so on Linux this
// is the common path, not a fallback.
//
// stb_image does the decoding (third_party/stb, JPEG only), straight to grey.
// Measured against libjpeg-turbo on webcam-like 720p frames (4:2:2, noise),
// grey output, Apple M-series: 1.4 ms against 0.7 ms on a typical 75 KB frame,
// 4.6 ms against 3.3 ms on a noisy 470 KB one, and never more than one grey
// level apart. libjpeg-turbo is faster, but it is a system library under two
// incompatible sonames (libjpeg.so.8 on Ubuntu and Mint, .62 on Debian), and
// a missing soname would stop the whole library loading; stb_image is one
// header that builds and is tested everywhere this library is.
//
// Two things a camera needs that stb_image does not do, done here:
//  * Huffman tables. UVC cameras usually leave the DHT segment out of every
//    frame and rely on the standard tables (JPEG Annex K.3), the convention
//    MJPEG inherited from AVI. libjpeg-turbo fills them in; stb_image decodes
//    such a frame without any error into garbage (measured: grey levels off
//    by up to 128). A frame with no tables gets the standard ones spliced in
//    before its scan.
//  * Truncation. A frame cut short by a USB hiccup decodes as zeros past the
//    break, again without an error. A frame that does not end in its EOI
//    marker is dropped instead; the next one is 33 ms away.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "capture/pixel_format.h"

namespace pcw {

// The structure of one JPEG frame, as far as decoding it needs.
struct JpegFrameInfo {
  // Starts with SOI and its segments are well formed up to the scan.
  bool valid = false;
  bool has_huffman_tables = false;
  // Offset of the SOS marker (its 0xFF), when valid.
  size_t scan_offset = 0;
  // Ends with EOI, after any zero padding a driver left behind it.
  bool complete = false;
};

// Reads the frame's segment headers; never touches the entropy-coded data
// except to find the EOI marker at its end.
JpegFrameInfo InspectJpeg(const uint8_t* data, size_t size);

// `data` with the standard Huffman tables inserted at `scan_offset` (from
// InspectJpeg), written to `out`.
void InsertStandardHuffmanTables(const uint8_t* data, size_t size,
                                 size_t scan_offset, std::vector<uint8_t>& out);

class JpegDecoder {
 public:
  JpegDecoder() = default;
  ~JpegDecoder();
  JpegDecoder(const JpegDecoder&) = delete;
  JpegDecoder& operator=(const JpegDecoder&) = delete;

  // Decodes the frame to 8-bit grey. On success `out` points into this
  // decoder's memory and stays valid until the next call. The size is the
  // frame's own, which is not always the size the driver was asked for.
  bool Decode(const uint8_t* data, size_t size, PixelBuffer& out);

  // Why the last frame was refused, for logs and the probe.
  const std::string& last_error() const { return last_error_; }

 private:
  void ReleasePixels();

  std::vector<uint8_t> patched_;
  uint8_t* pixels_ = nullptr;
  std::string last_error_;
};

}  // namespace pcw
