// Geometry on greyscale frames: the few transforms the wedge needs, done
// directly rather than through an imaging library it would otherwise not use.
#pragma once

#include <cstdint>
#include <vector>

#include "vision/luma_image.h"

namespace pcw {

// Rotate `src` by `degrees` (clockwise as seen on screen, where y runs down)
// and scale it by `scale`, into
// a `dst` sized to the rotated bounding box so a code near the edge is turned
// rather than cropped. Corners outside the source are filled with `fill`.
//
// Why the wedge rotates at all: zxing's `tryRotate` only covers 90-degree
// steps, and a 1-D barcode is only read when one scan line crosses every bar.
// With a tilt between those steps nothing crosses them — the camera lab
// measured an EAN-13 sitting sharp and still for 14.7 s without a read — so
// the decoder cycles through 0/30/60 degrees itself (see engine/
// decode_scheduler.h). Nearest-neighbour is enough: rotation by an arbitrary
// angle blurs no more than the camera already has.
void RotateScaled(const LumaImage& src, int degrees, double scale,
                  uint8_t fill, LumaImage& dst);

// Shrink `src` so its longer edge is at most `max_edge`, averaging the source
// pixels each output pixel covers. Copies unchanged when already small enough.
void Downscale(const LumaImage& src, int max_edge, LumaImage& dst);

// Threshold `src` against its own neighbourhood: 0 where a pixel is darker
// than the mean of the (2 * radius + 1)^2 square around it by a clear margin,
// 255 everywhere else — including flat areas, so a plain counter comes out
// white rather than as noise.
//
// This exists because zxing reads 1-D codes with ONE threshold per scan line,
// taken from the histogram of the whole line. When the line is mostly counter
// (a grey mid-tone) with a small white label on it, the counter and the label
// are the two tallest peaks, the threshold lands between them, and a slightly
// soft barcode's bars merge into the counter: measured on a drawn EAN-13 at
// 3 px a module with the mildest blur, zxing read nothing at any angle while
// this image of the same frame read at every one. A fixed-focus webcam over a
// counter produces exactly that picture. `scratch` is reused between calls.
void AdaptiveBinarize(const LumaImage& src, int radius, LumaImage& dst,
                      std::vector<uint32_t>& scratch);

// A tiny block-averaged thumbnail (`columns` x `rows`) for noticing that the
// scene changed. Sampled sparsely inside each block: it only has to rank
// frames against each other, not look like anything.
void Thumbnail(const LumaImage& src, int columns, int rows,
               std::vector<uint8_t>& out);

// Mean absolute difference between two thumbnails of the same size, 0-255.
double MeanAbsoluteDifference(const std::vector<uint8_t>& a,
                              const std::vector<uint8_t>& b);

}  // namespace pcw
