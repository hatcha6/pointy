#pragma once

#include <string>

namespace pcw {

// `text` with every invalid UTF-8 sequence replaced by U+FFFD. The Dart VM
// refuses a message carrying invalid UTF-8, and a refused post looks exactly
// like a closed port — which would stop the wedge over one odd byte in a
// camera's name.
std::string SanitizedUtf8(const std::string& text);

}  // namespace pcw
