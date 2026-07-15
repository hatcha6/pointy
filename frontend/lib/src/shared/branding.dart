// Brand identity shown on everything Pointy prints — PDF documents, business
// reports, and thermal receipts. Change the wording here and every printed
// artifact follows.
//
// The closing stamp is a small pun: دَوَّن ("to enter into a ledger") on
// دفتر ("ledger/notebook", the customer-facing brand). Read together it says
// "recorded in Daftar" — our quiet mark of authorship at the foot of the slip.
// The logo (assets/branding/logo_black.png) sits between the two words wherever
// the medium can render an inline image (PDF); the thermal path stacks the mark
// above the line since ESC/POS can't inline an image mid-text.
//
// Voweling note: the verb carries a damma + shadda (دُوّن). We deliberately keep
// one mark per letter — the PDF text shaper drops a kasra tucked under a shadda,
// so the fuller دُوِّنَ mis-renders; this form stays crisp everywhere while still
// showing the tashdeed that makes the word read as "recorded".

/// Leading half of the tagline (verb + preposition). The brand name follows the
/// inline logo, so this is kept as its own run.
const String pointyPrintTaglineLead = 'دُوّن في';

/// The brand name, left unvoweled so it reads as a clean, bold wordmark.
const String pointyPrintBrandName = 'دفتر';

/// Plain-text form of the tagline, used where no inline logo is available
/// (thermal fallback, and any surface that renders the credit as one string).
const String pointyPrintTagline =
    '$pointyPrintTaglineLead $pointyPrintBrandName';

/// Back-compatible alias: the printed credit line is now the brand tagline.
const String pointyPrintCreditLine = pointyPrintTagline;
