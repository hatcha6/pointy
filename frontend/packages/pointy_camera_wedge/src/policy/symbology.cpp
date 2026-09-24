#include "policy/symbology.h"

#include <array>
#include <cctype>
#include <string>

namespace pcw {
namespace {

constexpr std::array<std::string_view, 7> kErrorCorrected = {
    "qrcode", "qr", "microqrcode", "rmqrcode", "datamatrix", "aztec", "pdf417",
};

constexpr std::array<std::string_view, 6> kCheckDigit = {
    "ean13", "ean8", "upca", "upce",
    // Mandatory mod-103; stronger than EAN's mod-10, but still one check over
    // a code a camera may have read half of.
    "code128",
    // Two check characters.
    "code93",
};

template <size_t N>
bool Contains(const std::array<std::string_view, N>& set, std::string_view key) {
  for (const auto& entry : set) {
    if (entry == key) return true;
  }
  return false;
}

}  // namespace

Trust ClassifySymbology(std::string_view name) {
  // Lower-case with every separator removed, which is what makes "qr_code",
  // "QR-CODE" and "QRCode" the same key.
  std::string key;
  key.reserve(name.size());
  for (const char c : name) {
    if (c == '_' || c == '-' || c == ' ' || c == '/') continue;
    key.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
  }
  if (Contains(kErrorCorrected, key)) return Trust::kErrorCorrected;
  if (Contains(kCheckDigit, key)) return Trust::kCheckDigit;
  return Trust::kUnprotected;
}

}  // namespace pcw
