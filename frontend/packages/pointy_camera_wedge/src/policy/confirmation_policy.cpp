#include "policy/confirmation_policy.h"

#include <algorithm>

namespace pcw {

std::string Trimmed(const std::string& text) {
  const auto is_space = [](char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' ||
           c == '\v';
  };
  size_t begin = 0;
  size_t end = text.size();
  while (begin < end && is_space(text[begin])) ++begin;
  while (end > begin && is_space(text[end - 1])) --end;
  return text.substr(begin, end - begin);
}

ConfirmationPolicy::ConfirmationPolicy(Options options) : options_(options) {}

ConfirmationPolicy::Held* ConfirmationPolicy::FindHeld(const std::string& text) {
  for (auto& held : held_) {
    if (held.text == text) return &held;
  }
  return nullptr;
}

std::optional<Scan> ConfirmationPolicy::OfferFrame(
    const std::vector<Reading>& readings, TimePoint now) {
  // A code that has been out of sight for the whole holdoff is a new sale
  // when it comes back; one still in view keeps its hold refreshed below.
  held_.erase(std::remove_if(held_.begin(), held_.end(),
                             [&](const Held& held) {
                               return now - held.last_seen >=
                                      options_.reread_holdoff;
                             }),
              held_.end());

  struct Candidate {
    std::string text;
    const Reading* reading;
  };
  std::vector<Candidate> candidates;
  for (const auto& reading : readings) {
    auto text = Trimmed(reading.text);
    if (text.empty()) continue;
    if (auto* held = FindHeld(text)) {
      // Still looking at something already sold. Refresh rather than let the
      // hold expire under a stationary item, or a box left on the counter is
      // rung up twice.
      held->last_seen = now;
      ++suppressed_rereads_;
      continue;
    }
    const bool duplicate =
        std::any_of(candidates.begin(), candidates.end(),
                    [&](const Candidate& c) { return c.text == text; });
    if (!duplicate) candidates.push_back({std::move(text), &reading});
  }
  if (candidates.empty()) return std::nullopt;

  const Candidate* chosen = &candidates.front();
  if (pending_count_ > 0) {
    for (const auto& candidate : candidates) {
      if (candidate.text == pending_text_) {
        chosen = &candidate;
        break;
      }
    }
  }

  const bool within_window =
      pending_at_ && now - *pending_at_ <= options_.agreement_window;
  if (pending_count_ > 0 && within_window && chosen->text == pending_text_) {
    ++pending_count_;
  } else {
    // A DIFFERENT value inside the window is the misread case, and the only
    // one worth counting: a pending entry that simply timed out is an item
    // being taken away, not a decoder being wrong.
    if (pending_count_ > 0 && within_window) ++rejected_disagreements_;
    pending_text_ = chosen->text;
    pending_symbology_ = chosen->reading->symbology;
    pending_count_ = 1;
  }
  pending_at_ = now;

  if (pending_count_ < RequiredAgreement(chosen->reading->trust)) {
    return std::nullopt;
  }

  Scan scan{pending_text_, pending_symbology_, pending_count_};
  held_.push_back({pending_text_, now});
  pending_text_.clear();
  pending_symbology_.clear();
  pending_count_ = 0;
  pending_at_.reset();
  return scan;
}

void ConfirmationPolicy::Reset() {
  pending_text_.clear();
  pending_symbology_.clear();
  pending_count_ = 0;
  pending_at_.reset();
  held_.clear();
}

}  // namespace pcw
