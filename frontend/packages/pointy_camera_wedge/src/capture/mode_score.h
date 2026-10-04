// Which of a camera's modes to open, decided the same way on every platform.
//
// A webcam offers dozens of modes — every size it can send, at every frame
// rate, in each of its formats — and the one a backend opens decides most of
// how well the wedge reads. Media Foundation and V4L2 list them differently,
// but the preference is one rule, here, so a camera picked on a Windows till
// and the same camera on a Linux till run the same way.
#pragma once

namespace pcw {

// How a mode's frames reach the decoder.
enum class ModeEncoding {
  // Uncompressed: the luminance is read straight out of the frame.
  kRaw,
  // Motion JPEG, decoded first — by Media Foundation on Windows, by this
  // library on Linux (capture/jpeg_decoder.h).
  kMjpeg,
  // H.264 and friends: Media Foundation can decode them, at a cost a till
  // feels. The Linux backend does not offer them at all.
  kOtherCompressed,
};

struct ModeCandidate {
  int width = 0;
  int height = 0;
  // 0 when the driver does not say.
  double fps = 0;
  ModeEncoding encoding = ModeEncoding::kRaw;
};

// Lower is better. The ideal is the preferred size (1280x720 by default: the
// camera lab's working resolution, fine enough for a narrow bar at counter
// distance and cheap enough to decode every frame), at 30 frames a second, in
// a format read directly. Smaller than asked costs twice what larger does —
// resolution is what a 1-D barcode lives or dies by — and a frame rate under
// 15 costs most of all: agreement between looks has to arrive inside 600 ms.
// Faster than 30 buys nothing (the decoder, not the camera, sets the pace on
// a till) and costs a little, so between two otherwise equal modes the 30 fps
// one wins: at 60 fps a till copies, and for MJPEG decodes, every frame twice.
double ScoreMode(const ModeCandidate& mode, int preferred_width,
                 int preferred_height);

}  // namespace pcw
