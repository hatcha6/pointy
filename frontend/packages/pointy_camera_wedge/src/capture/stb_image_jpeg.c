/*
 * stb_image's implementation, compiled once, as stb_image_config.h sets it up.
 *
 * A file of its own so its warnings stay out of ours: CMakeLists.txt silences
 * them for this file alone. It is vendored code, not code this library reads.
 */
#define STB_IMAGE_IMPLEMENTATION
#include "capture/stb_image_config.h"
