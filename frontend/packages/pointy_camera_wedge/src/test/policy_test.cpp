// The confirmation policy, case for case with the app's
// camera_wedge_policy_test.dart — the same rule on the other side of the FFI
// boundary — plus the frames-with-two-codes cases only a whole frame exposes.
//
// The misread these tests exist for was measured, not imagined: pointing a
// camera at one product (tools/camera-wedge-lab), zxing-cpp read its EAN-13
// as three different wrong values in 24 scans, and every one passed the
// EAN-13 check digit.
#include <optional>
#include <string>
#include <vector>

#include "policy/confirmation_policy.h"
#include "policy/symbology.h"
#include "test/check.h"

namespace {

using pcw::ConfirmationPolicy;
using pcw::Reading;
using pcw::Scan;
using std::chrono::milliseconds;

const std::string kTruth = "3600523434725";
// All three measured, all three checksum-valid, all three wrong.
const std::vector<std::string> kMisreads = {"9660323434725", "0608713434725",
                                            "9620723434725"};

struct Harness {
  ConfirmationPolicy policy;
  pcw::TimePoint now = pcw::TimePoint(std::chrono::hours(1000));

  void Tick(int ms = 13) { now += milliseconds(ms); }

  std::optional<Scan> Read(const std::string& value,
                           const std::string& symbology = "EAN13") {
    return policy.OfferFrame(
        {Reading{value, symbology, pcw::ClassifySymbology(symbology)}}, now);
  }

  std::optional<Scan> ReadFrame(std::vector<std::pair<std::string, std::string>> codes) {
    std::vector<Reading> readings;
    for (auto& [value, symbology] : codes) {
      readings.push_back({value, symbology, pcw::ClassifySymbology(symbology)});
    }
    return policy.OfferFrame(readings, now);
  }
};

// --- a 1-D read is never believed on its own ---------------------------------

PCW_TEST(one_look_at_a_barcode_emits_nothing) {
  Harness h;
  CHECK(!h.Read(kTruth));
}

PCW_TEST(two_agreeing_looks_emit_it) {
  Harness h;
  CHECK(!h.Read(kTruth));
  h.Tick();
  const auto scan = h.Read(kTruth);
  CHECK(scan.has_value());
  CHECK_EQ(scan->text, kTruth);
  CHECK_EQ(scan->confirmations, 2);
}

PCW_TEST(a_measured_misread_between_two_good_reads_emits_nothing) {
  // The interleaving the lab recorded: a hit, a disagreeing hit, more hits.
  // Nothing may reach the cart until two IN A ROW agree.
  Harness h;
  CHECK(!h.Read(kTruth));
  h.Tick();
  CHECK(!h.Read(kMisreads[0]));
  h.Tick();
  CHECK(!h.Read(kTruth));
  h.Tick();
  const auto scan = h.Read(kTruth);
  CHECK(scan.has_value());
  CHECK_EQ(scan->text, kTruth);
  CHECK_EQ(h.policy.rejected_disagreements(), 2u);
}

PCW_TEST(every_measured_misread_is_rejected_when_read_alone) {
  for (const auto& wrong : kMisreads) {
    Harness h;
    CHECK(!h.Read(wrong));
  }
}

PCW_TEST(two_agreeing_looks_far_apart_are_not_corroboration) {
  // The item may have been taken away and another put down.
  Harness h;
  CHECK(!h.Read(kTruth));
  h.Tick(5000);
  CHECK(!h.Read(kTruth));
}

// --- a 2-D read is believed at once ------------------------------------------

PCW_TEST(one_look_at_a_qr_emits_it) {
  Harness h;
  const auto scan = h.Read("pay://x/9f2", "QRCode");
  CHECK(scan.has_value());
  CHECK_EQ(scan->confirmations, 1);
}

PCW_TEST(data_matrix_aztec_and_pdf417_are_trusted_the_same_way) {
  for (const char* symbology : {"DataMatrix", "Aztec", "PDF417", "MicroQRCode"}) {
    Harness h;
    CHECK(h.Read("x", symbology).has_value());
  }
}

// --- unknown or unprotected symbologies are trusted least --------------------

PCW_TEST(codabar_needs_three_agreeing_looks) {
  Harness h;
  CHECK(!h.Read("A123A", "Codabar"));
  h.Tick();
  CHECK(!h.Read("A123A", "Codabar"));
  h.Tick();
  CHECK(h.Read("A123A", "Codabar").has_value());
}

PCW_TEST(a_symbology_never_heard_of_gets_the_most_suspicion) {
  CHECK(pcw::ClassifySymbology("SomethingNewIn2030") == pcw::Trust::kUnprotected);
}

PCW_TEST(spelling_differences_between_decoders_do_not_change_trust) {
  for (const char* spelling : {"QRCode", "qr_code", "QR-CODE", "qrcode", "QR Code"}) {
    CHECK(pcw::ClassifySymbology(spelling) == pcw::Trust::kErrorCorrected);
  }
  for (const char* spelling : {"EAN13", "ean_13", "EAN-13"}) {
    CHECK(pcw::ClassifySymbology(spelling) == pcw::Trust::kCheckDigit);
  }
}

// --- a camera stares; a scanner reads once -----------------------------------

PCW_TEST(an_item_left_under_the_camera_is_not_rung_up_twice) {
  Harness h;
  h.Read(kTruth);
  h.Tick();
  CHECK(h.Read(kTruth).has_value());
  for (int i = 0; i < 100; ++i) {
    h.Tick();
    CHECK(!h.Read(kTruth));
  }
  CHECK_EQ(h.policy.suppressed_rereads(), 100u);
}

PCW_TEST(the_holdoff_runs_from_the_last_look_not_the_first) {
  Harness h;
  h.Read(kTruth);
  h.Tick();
  CHECK(h.Read(kTruth).has_value());
  for (int i = 0; i < 30; ++i) {
    h.Tick(100);  // 3 seconds, well past the 1.5 s holdoff
    CHECK(!h.Read(kTruth));
  }
}

PCW_TEST(the_same_item_presented_again_after_a_pause_is_a_new_sale) {
  Harness h;
  h.Read(kTruth);
  h.Tick();
  CHECK(h.Read(kTruth).has_value());
  h.Tick(2000);  // taken away, brought back
  CHECK(!h.Read(kTruth));
  h.Tick();
  CHECK(h.Read(kTruth).has_value());
}

PCW_TEST(a_different_product_under_the_camera_is_not_held_off) {
  Harness h;
  h.Read(kTruth);
  h.Tick();
  CHECK(h.Read(kTruth).has_value());
  h.Tick();
  CHECK(!h.Read("5449000000996"));
  h.Tick();
  CHECK(h.Read("5449000000996").has_value());
}

PCW_TEST(reset_forgets_everything_in_flight) {
  Harness h;
  CHECK(!h.Read(kTruth));
  h.policy.Reset();
  h.Tick();
  CHECK(!h.Read(kTruth));
}

PCW_TEST(a_blank_read_is_not_a_read) {
  Harness h;
  CHECK(!h.Read("   "));
  h.Tick();
  CHECK(!h.Read("   "));
}

// --- two codes in one frame --------------------------------------------------

PCW_TEST(two_codes_in_view_are_each_scanned_exactly_once) {
  // A box with its EAN beside a QR, sitting under the camera. With a single
  // "last scanned" value the two take turns being new, and the box is rung
  // up again every other second for as long as it sits there.
  Harness h;
  int ean = 0;
  int qr = 0;
  for (int i = 0; i < 200; ++i) {
    if (auto scan = h.ReadFrame({{kTruth, "EAN13"}, {"https://brand.example/p/1", "QRCode"}})) {
      if (scan->text == kTruth) ++ean;
      if (scan->text == "https://brand.example/p/1") ++qr;
    }
    h.Tick(33);
  }
  CHECK_EQ(ean, 1);
  CHECK_EQ(qr, 1);
}

PCW_TEST(a_second_code_does_not_interrupt_the_first_ones_agreement) {
  Harness h;
  CHECK(!h.ReadFrame({{kTruth, "EAN13"}}));
  h.Tick();
  // The QR now appears too, and is listed first; the EAN being corroborated
  // must still be the one that advances.
  const auto scan = h.ReadFrame({{"pay://x", "QRCode"}, {kTruth, "EAN13"}});
  CHECK(scan.has_value());
  CHECK_EQ(scan->text, kTruth);
  CHECK_EQ(h.policy.rejected_disagreements(), 0u);
}

PCW_TEST(a_code_repeated_within_one_frame_counts_once) {
  Harness h;
  CHECK(!h.ReadFrame({{kTruth, "EAN13"}, {kTruth, "EAN13"}}));
}

PCW_TEST(an_empty_frame_changes_nothing) {
  Harness h;
  CHECK(!h.Read(kTruth));
  h.Tick();
  CHECK(!h.ReadFrame({}));
  h.Tick();
  CHECK(h.Read(kTruth).has_value());
}

}  // namespace
