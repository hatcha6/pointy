#pragma once

namespace pcw {

// Run the calling thread below normal priority.
//
// The decoder is the one thread that can use a whole core, and on a till the
// thing that must never stutter is the till itself. Below-normal means the UI
// and the local server always win a contested core; the decoder then takes
// whatever is left, which on anything but a saturated machine is all of it.
void LowerCurrentThreadPriority();

}  // namespace pcw
