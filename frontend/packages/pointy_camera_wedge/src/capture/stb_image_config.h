/*
 * How this library builds stb_image (third_party/stb): JPEG only, decoded
 * from memory. Included by the one file that compiles it (stb_image_jpeg.c)
 * and by the one that calls it (jpeg_decoder.cpp), so both agree.
 */
#ifndef PCW_STB_IMAGE_CONFIG_H_
#define PCW_STB_IMAGE_CONFIG_H_

#define STBI_ONLY_JPEG
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_NO_HDR
/* A frame claiming to be larger than any webcam sends is refused before
 * anything is allocated for it. */
#define STBI_MAX_DIMENSIONS 8192
/* Its one assertion in the JPEG path checks a table it built itself; a frame
 * that trips it decodes wrong, and a wrong frame is only a frame without a
 * barcode. Aborting the till over it is not an option, in any build type. */
#define STBI_ASSERT(x) ((void)0)
/* SSE2 is used on its own on x86-64, which every till is. NEON, which it
 * would have to be told about, is left off on purpose: no till is ARM, and
 * GCC's NEON intrinsics spell the IDCT's wrapping 16-bit adds as signed C
 * arithmetic that a corrupt frame overflows (UBSan, on the fuzz test). The
 * plain C path an ARM build gets instead is the one the sanitizers check. */

#include "third_party/stb/stb_image.h"

#endif /* PCW_STB_IMAGE_CONFIG_H_ */
