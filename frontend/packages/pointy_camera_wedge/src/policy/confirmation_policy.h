// Turns a stream of decoder guesses into scans a till may act on.
//
// A camera is not a scanner. A scanner reads a code once with dedicated
// optics; a camera reads a PICTURE of a code many times a second, and some of
// those reads are wrong in ways the symbology cannot see (see
// policy/symbology.h for the measured 12%). So nothing is reported until
// enough independent looks agree, with "enough" bought per symbology.
//
// The app's camera_wedge_policy.dart implements the same rule for the
// platforms where the OS decodes. Keep them in step.
#pragma once

#include <chrono>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "policy/symbology.h"
#include "vision/luma_image.h"

namespace pcw {

// One decode, as the decoder reported it. Not yet a scan.
struct Reading {
  std::string text;
  // Canonical name ("EAN13", "QRCode", ...), see vision/barcode_reader.h.
  std::string symbology;
  Trust trust = Trust::kUnprotected;
};

// A reading the policy is willing to stand behind.
struct Scan {
  std::string text;
  std::string symbology;
  // How many agreeing looks it took; carried for telemetry and support.
  int confirmations = 0;
};

class ConfirmationPolicy {
 public:
  struct Options {
    // How far apart agreeing looks may be. Two reads further apart are not
    // corroboration: the item may have been swapped. At a live stream's
    // cadence honest agreement arrives in tens of milliseconds.
    std::chrono::milliseconds agreement_window{600};
    // How long a value that was just scanned is ignored. A camera stares at an
    // item continuously; a till expects a scanner's read-once behaviour.
    std::chrono::milliseconds reread_holdoff{1500};
  };

  ConfirmationPolicy() : ConfirmationPolicy(Options{}) {}
  explicit ConfirmationPolicy(Options options);

  // Offer everything one frame was read as. Returns the scan to act on, or
  // nothing to keep looking. At most one scan per frame.
  //
  // A frame can hold several codes — a product's EAN beside a QR on the same
  // box, say. Each code that has been scanned is held off on its own, for as
  // long as it stays in view; a single "last scanned" value (which the first
  // Dart version had) lets two codes in view take turns re-emitting each
  // other forever, which is the same box rung up again every second. Of the
  // codes not held off, the one already being corroborated is preferred, so a
  // second code in the picture cannot keep interrupting its agreement.
  std::optional<Scan> OfferFrame(const std::vector<Reading>& readings,
                                 TimePoint now);

  // Forget everything in flight and everything held off.
  void Reset();

  // Reads thrown away because a second look disagreed. Every one is a wrong
  // product that did not reach a cart.
  uint64_t rejected_disagreements() const { return rejected_disagreements_; }
  // Reads thrown away as a re-read of something already scanned.
  uint64_t suppressed_rereads() const { return suppressed_rereads_; }

 private:
  struct Held {
    std::string text;
    TimePoint last_seen;
  };

  Held* FindHeld(const std::string& text);

  Options options_;

  std::string pending_text_;
  std::string pending_symbology_;
  int pending_count_ = 0;
  std::optional<TimePoint> pending_at_;

  std::vector<Held> held_;

  uint64_t rejected_disagreements_ = 0;
  uint64_t suppressed_rereads_ = 0;
};

// `text` with leading and trailing ASCII whitespace removed.
std::string Trimmed(const std::string& text);

}  // namespace pcw
