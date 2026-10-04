/*
 * stb_image_write's implementation, for test builds only (see jpeg_writer.h).
 * A file of its own so CMakeLists.txt can silence its warnings alone.
 */
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include "third_party/stb/stb_image_write.h"
