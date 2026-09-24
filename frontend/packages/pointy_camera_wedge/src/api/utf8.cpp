#include "api/utf8.h"

#include <cstdint>

namespace pcw {

std::string SanitizedUtf8(const std::string& text) {
  std::string out;
  out.reserve(text.size());
  const auto* bytes = reinterpret_cast<const unsigned char*>(text.data());
  const size_t size = text.size();
  size_t i = 0;
  while (i < size) {
    const unsigned char lead = bytes[i];
    size_t length = 0;
    uint32_t minimum = 0;
    uint32_t code_point = 0;
    if (lead < 0x80) {
      out.push_back(static_cast<char>(lead));
      ++i;
      continue;
    } else if ((lead & 0xE0) == 0xC0) {
      length = 2;
      minimum = 0x80;
      code_point = lead & 0x1F;
    } else if ((lead & 0xF0) == 0xE0) {
      length = 3;
      minimum = 0x800;
      code_point = lead & 0x0F;
    } else if ((lead & 0xF8) == 0xF0) {
      length = 4;
      minimum = 0x10000;
      code_point = lead & 0x07;
    }
    bool valid = length > 0 && i + length <= size;
    for (size_t k = 1; valid && k < length; ++k) {
      const unsigned char next = bytes[i + k];
      if ((next & 0xC0) != 0x80) {
        valid = false;
      } else {
        code_point = (code_point << 6) | (next & 0x3F);
      }
    }
    valid = valid && code_point >= minimum && code_point <= 0x10FFFF &&
            !(code_point >= 0xD800 && code_point <= 0xDFFF);
    if (valid) {
      out.append(text, i, length);
      i += length;
    } else {
      out.append("\xEF\xBF\xBD");
      ++i;
    }
  }
  return out;
}

}  // namespace pcw
