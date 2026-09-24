// zxing-cpp, configured for a counter camera.
//
// The same engine the backend runs (apps/companion/decoding.py) and the camera
// lab measured (tools/camera-wedge-lab, zxing-wasm 3.1.x), so what the lab
// found transfers exactly. This is the only file that includes zxing headers.
#pragma once

#include <memory>
#include <vector>

#include "policy/confirmation_policy.h"
#include "vision/luma_image.h"

namespace pcw {

// One pass over a frame. The decoder cycles through a few of these rather
// than trying everything on every frame: each pass stays cheap, and the
// camera supplies the next frame long before a person notices.
struct DecodeAttempt {
  // Degrees to turn the frame first (clockwise on screen). zxing already
  // tries 90-degree steps; this covers what lies between them.
  int angle = 0;
  // Also look for light-on-dark codes (a QR on a phone in dark mode).
  bool inverted = false;
};

class BarcodeReader {
 public:
  BarcodeReader();
  ~BarcodeReader();
  BarcodeReader(const BarcodeReader&) = delete;
  BarcodeReader& operator=(const BarcodeReader&) = delete;

  // Every code found in `frame`, in zxing's order. Never throws.
  std::vector<Reading> Read(const LumaImage& frame, const DecodeAttempt& attempt);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace pcw
