// A counter with a barcode on it, drawn rather than photographed.
//
// For tests and for the synthetic backend only: it lets the whole pipeline —
// frame format conversion, rotation, zxing, the confirmation policy, the
// threads, the Dart port — be exercised on a machine with no camera. The
// barcode is encoded by zxing-cpp's own writer, so what is drawn is exactly
// what the symbology specifies.
#pragma once

#include <cstdint>
#include <string>

#include "vision/luma_image.h"

namespace pcw {

struct SceneSpec {
  // Canonical symbology name ("EAN13", "QRCode", ...). Empty text draws an
  // empty counter.
  std::string format = "EAN13";
  std::string text;
  // Counter-clockwise tilt of the code on the counter.
  int angle = 0;
  // Pixels per module (narrowest bar or smallest square).
  int module = 3;
  int width = 1280;
  int height = 720;
  // Counter grey level, and +/- amplitude of deterministic sensor noise.
  uint8_t background = 150;
  int noise = 0;
  // Box blur radius in pixels (0 = sharp), for an out-of-focus camera.
  int blur = 0;
};

// Draw `spec`: a white label with the code on it, turned by `angle`, in the
// middle of a grey counter.
LumaImage RenderScene(const SceneSpec& spec);

}  // namespace pcw
