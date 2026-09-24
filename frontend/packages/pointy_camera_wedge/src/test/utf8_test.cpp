#include <string>

#include "api/utf8.h"
#include "test/check.h"

namespace {

PCW_TEST(valid_utf8_passes_through_untouched) {
  const std::string arabic = "\xD9\x83\xD8\xA7\xD9\x85\xD9\x8A\xD8\xB1\xD8\xA7";  // كاميرا
  CHECK_EQ(pcw::SanitizedUtf8(arabic), arabic);
  CHECK_EQ(pcw::SanitizedUtf8("HUE HD Pro camera"), std::string("HUE HD Pro camera"));
  const std::string emoji = "\xF0\x9F\x93\xB7";
  CHECK_EQ(pcw::SanitizedUtf8(emoji), emoji);
}

PCW_TEST(invalid_bytes_become_replacement_characters) {
  const std::string replacement = "\xEF\xBF\xBD";
  CHECK_EQ(pcw::SanitizedUtf8("a\xFF" "b"), "a" + replacement + "b");
  // Truncated sequence at the end.
  CHECK_EQ(pcw::SanitizedUtf8("x\xD9"), "x" + replacement);
  // Overlong encoding of '/'.
  CHECK_EQ(pcw::SanitizedUtf8("\xC0\xAF"), replacement + replacement);
  // A UTF-16 surrogate encoded as UTF-8 is not UTF-8.
  CHECK_EQ(pcw::SanitizedUtf8("\xED\xA0\x80"), replacement + replacement + replacement);
}

}  // namespace
