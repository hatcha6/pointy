#pragma once

#include "capture/pixel_format.h"
#include "vision/luma_image.h"

namespace pcw {

// Copy the luminance of `frame` into `out`, resizing it to fit.
//
// This is the only per-frame copy the wedge makes, and it is the whole of
// what happens on the camera's own thread: a planar format is a row memcpy,
// a packed one a strided byte copy, RGB a weighted sum. Decoding happens
// later, on the wedge's decoder thread, on whichever frame is newest.
//
// Returns false (and leaves `out` alone) for a format it cannot read or a
// frame whose geometry makes no sense.
bool ExtractLuma(const PixelBuffer& frame, LumaImage& out);

}  // namespace pcw
