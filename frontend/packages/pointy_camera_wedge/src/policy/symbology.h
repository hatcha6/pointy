// How much a symbology protects itself, and therefore how many agreeing looks
// a camera needs before a till may believe it.
//
// The same table as the app's camera_wedge_symbology.dart, which covers the
// platforms where the OS decodes (mobile_scanner). Keep the two in step: they
// are one rule implemented twice because the decoders live on either side of
// the FFI boundary.
//
//  * 2-D codes carry Reed-Solomon error CORRECTION: a decode that survives is
//    trustworthy, so one read is believed. This is what makes a payment
//    terminal's receipt QR instant.
//  * Retail 1-D codes carry one check digit, and it is not enough. Measured on
//    a real product (tools/camera-wedge-lab), one EAN-13 read as three
//    different wrong values in 24 scans — 12% — and every wrong value passed
//    the check digit. Two agreeing reads.
//  * Codabar, Code 39, ITF and anything unrecognised carry little or nothing,
//    or have a known partial-read failure (a clipped ITF reads short and
//    clean). Three agreeing reads.
#pragma once

#include <string_view>

namespace pcw {

enum class Trust {
  kErrorCorrected = 1,
  kCheckDigit = 2,
  kUnprotected = 3,
};

// How many agreeing reads a symbology of this trust needs.
constexpr int RequiredAgreement(Trust trust) { return static_cast<int>(trust); }

// Classify a symbology by name, tolerating the spellings different decoders
// use ("QRCode", "qr_code", "QR-CODE"). An unknown name is kUnprotected on
// purpose: being wrong in that direction costs a slower scan, never a wrong
// sale.
Trust ClassifySymbology(std::string_view name);

}  // namespace pcw
