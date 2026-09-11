"""What every card-receipt provider has to produce, and the two shapes they come in.

A receipt link is the shop's proof that a card payment happened on a terminal it
owns, for the amount it is claiming. Providers deliver that proof in two
fundamentally different ways, and the difference decides what a till can promise
the cashier:

* **Self-contained** (Moamalat) — the QR *is* the receipt. Every field travels
  inside the link, so a till decodes it offline, instantly, and can refuse a
  wrong amount before the sale closes. No network, works in a power cut.

* **Reference** (Madfoatech) — the QR is an opaque token and nothing else. The
  fields live on the issuer's server, so nothing about the amount can be known
  without a round trip. In exchange the proof is *stronger*: a forged token
  returns nothing, which no amount of cleverness can fake, whereas a
  self-contained payload is only as trustworthy as its (absent) signature.

So the interface below splits what a provider knows *now* from what it can only
learn *later*, rather than pretending both kinds answer the same question at the
same speed. ``parse`` is the offline half and must never touch the network;
``verify`` is the online half and only exists for providers that need it.
"""

from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation

MONEY_PLACES = Decimal("0.01")

# Where a receipt stands with its issuer. Stored on the payment so an unsettled
# slip can be found and chased rather than quietly looking like a settled one.
PENDING = "pending"
SETTLED = "settled"
#: The issuer answered and disowned the receipt. This is the fraud signal.
REJECTED = "rejected"
#: The issuer proved the receipt, but it is not this payment's receipt.
MISMATCH = "mismatch"
#: We could not reach the issuer. Says nothing about the receipt.
UNAVAILABLE = "unavailable"


class CardReceiptError(ValueError):
    """A receipt link that cannot stand for a payment, with a reason to show."""


@dataclass(frozen=True)
class CardReceipt:
    """One card receipt, however it was obtained.

    ``amount`` is ``None`` when the provider genuinely does not know it yet — a
    reference receipt that has been recognised but not fetched. That is a
    different state from "the amount is zero", and the callers that match a
    receipt to a payment have to treat it as such, so it is modelled as absence
    rather than a default.
    """

    provider: str
    source_url: str
    receipt_id: str
    validation_method: str
    server_validated: bool
    amount: Decimal | None = None
    transaction_type: str = ""
    language: str = ""
    fields: dict = field(default_factory=dict)

    @property
    def is_verified(self) -> bool:
        """Whether this receipt carries the fields needed to match a payment."""
        return self.amount is not None

    @property
    def verification_state(self) -> str:
        """Whether anything is still owed on this receipt.

        ``pending`` means a background task has to finish the job before the
        slip proves anything. It is written onto the payment so that state is
        visible in the data rather than inferred from which fields happen to be
        blank -- a payment nobody ever settled must be findable.
        """
        return SETTLED if self.is_verified else PENDING

    @property
    def reference(self) -> str:
        for key in ("RRN", "STAN", "AuthorizationCode", "InvoiceNumber"):
            value = self.fields.get(key)
            if value:
                return str(value).strip()
        return self.receipt_id

    def to_payment_data(self) -> dict:
        """The JSON stored on ``Payment.card_receipt_data``.

        Two layers, and both matter:

        ``raw_fields``   everything the provider gave us, verbatim, under its
                         own key names. Nothing is dropped. This is what a
                         reconciliation against an acquirer's own statement
                         needs months later, when the question is whatever that
                         statement happens to be keyed on -- and it is not for
                         us to decide today which of those fields will turn out
                         to matter. An earlier allow-list here silently
                         discarded the cardholder name for a year.

        everything else  a normalised view with one spelling per concept, so
                         ``card_fingerprint``, the card linking and the
                         cashier-facing detail read one shape regardless of
                         which terminal printed the slip.

        The PAN is whatever the terminal printed, which is always masked -- a
        full card number never reaches us and must never be stored here.
        """
        return {
            "raw_fields": dict(self.fields),
            "provider": self.provider,
            "validation_method": self.validation_method,
            "server_validated": self.server_validated,
            "verification_state": self.verification_state,
            # Kept because a reference receipt can only be re-proved by asking
            # the issuer again, and the token is the only thing that identifies
            # it. For a self-contained provider it is redundant but harmless.
            "source_url": self.source_url,
            "receipt_id": self.receipt_id,
            "language": self.language,
            "transaction_type": self.transaction_type,
            "amount": "" if self.amount is None else f"{self.amount:.2f}",
            "amount_label": clean_string(self.fields.get("Amount")),
            "transaction_status": clean_string(self.fields.get("TransactionStatus")),
            "merchant_name": clean_string(self.fields.get("MerchantName")),
            "terminal_city": clean_string(self.fields.get("TerminalCity")),
            "terminal_id": clean_string(self.fields.get("TerminalId")),
            "card_type": clean_string(self.fields.get("CardType")),
            "masked_pan": clean_string(self.fields.get("PAN")),
            "aid": clean_string(self.fields.get("AID")),
            # Both providers print the cardholder, under different keys:
            # Moamalat states it as ``CardHolder`` in its payload, Madfoatech
            # only on the slip we OCR. Read from either so one code path serves
            # both, while ``fields`` keeps each payload exactly as it arrived.
            "cardholder_name": clean_string(
                self.fields.get("CardholderName") or self.fields.get("CardHolder")
            ),
            "authorization_code": clean_string(self.fields.get("AuthorizationCode")),
            "rrn": clean_string(self.fields.get("RRN")),
            "stan": clean_string(self.fields.get("STAN")),
            "batch": clean_string(self.fields.get("BATCH")),
            "invoice_number": clean_string(self.fields.get("InvoiceNumber")),
            "transaction_datetime": clean_string(self.fields.get("DateTime")),
        }


def receipt_is_successful(fields: dict) -> bool:
    """Whether a receipt's status field says the transaction went through.

    Terminals in Libya print the outcome in Arabic, English, or both depending
    on the acquirer and the language the cardholder picked, so all three
    spellings a shop actually meets are accepted.
    """
    status = str(fields.get("TransactionStatus", "")).strip().lower()
    return "بنجاح" in status or "success" in status or "approved" in status


def quantize_money(value) -> Decimal:
    return Decimal(value).quantize(MONEY_PLACES)


def amount_matches(amount, receipt: CardReceipt) -> bool:
    """Whether ``amount`` is the amount this receipt proves.

    An unverified receipt matches nothing: it has no amount to compare, and
    silently treating "unknown" as "fine" is exactly how an unchecked slip would
    come to stand for a payment it never covered.
    """
    if receipt.amount is None:
        return False
    try:
        expected = quantize_money(amount)
    except (InvalidOperation, TypeError):
        return False
    return expected == quantize_money(receipt.amount)


def clean_string(value) -> str:
    return str(value or "").strip()
