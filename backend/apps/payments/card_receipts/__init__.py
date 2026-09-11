"""Card receipt links, whoever printed them.

One place decides which provider a scanned link belongs to, so adding an
acquirer does not mean hunting down every spot that hardcoded a hostname. The
till, the payment serializer and the account-collection path all come through
here.

The providers do not answer the same question at the same speed -- see
``base`` -- so the split matters to callers:

``parse_receipt_url``   offline, instant, never touches the network. Safe in the
                        checkout path. May return a receipt with no amount.
``verify_receipt_url``  online, slow, may fail because the shop is offline.
                        Belongs in a background task, never in checkout.
"""

from . import madfoatech, moamalat
from .base import (
    CardReceipt,
    CardReceiptError,
    amount_matches,
    quantize_money,
)
from .madfoatech import IssuerUnavailable
from .ocr import normalize_terminal_id, terminal_ids_match

PROVIDERS = (moamalat, madfoatech)

__all__ = [
    "CardReceipt",
    "CardReceiptError",
    "IssuerUnavailable",
    "PROVIDERS",
    "amount_matches",
    "handles",
    "needs_verification",
    "parse_receipt_url",
    "provider_for",
    "quantize_money",
    "terminal_is_trusted",
    "verify_receipt_url",
]


def provider_for(url: str):
    """The provider that recognises this link, or ``None``.

    ``None`` is the ordinary answer at a till: a counter is scanned with product
    barcodes and loyalty cards all shift, and only a receipt link is this
    module's business.
    """
    for provider in PROVIDERS:
        if provider.handles(url or ""):
            return provider
    return None


def handles(url: str) -> bool:
    return provider_for(url) is not None


def needs_verification(url: str) -> bool:
    """Whether proving this link requires asking the issuer."""
    provider = provider_for(url)
    return bool(provider and getattr(provider, "needs_verification", False))


def parse_receipt_url(url: str) -> CardReceipt:
    provider = provider_for(url)
    if provider is None:
        raise CardReceiptError("Receipt must be a recognised card receipt URL.")
    return provider.parse(url)


def verify_receipt_url(url: str, *, fetch=None) -> tuple[CardReceipt, bytes | None]:
    """Prove a receipt as strongly as its provider allows.

    A self-contained provider has nothing to ask, so its offline parse already
    *is* the verification and it returns no image. Only reference providers make
    a network call.
    """
    provider = provider_for(url)
    if provider is None:
        raise CardReceiptError("Receipt must be a recognised card receipt URL.")
    if not getattr(provider, "needs_verification", False):
        return provider.parse(url), None
    return provider.verify(url, fetch=fetch)


def terminal_is_trusted(receipt: CardReceipt, trusted_terminal_ids) -> bool:
    """Whether the slip came off a terminal the shop listed as its own.

    An empty list means the shop has not restricted terminals, which is the
    default and allows any. Both sides are folded through
    ``normalize_terminal_id`` because a terminal id read by OCR cannot be
    trusted glyph-for-glyph -- see that function for why.
    """
    trusted = {
        normalize_terminal_id(terminal_id)
        for terminal_id in (trusted_terminal_ids or [])
        if str(terminal_id).strip()
    }
    if not trusted:
        return True
    terminal_id = normalize_terminal_id(receipt.fields.get("TerminalId"))
    if not terminal_id:
        # Nothing to check against. A receipt whose terminal could not be read
        # is not evidence of a *foreign* terminal, and refusing it would punish
        # the shop for a backend built without OCR.
        return True
    # A terminal id the provider stated is held to the letter; one we read off a
    # picture is allowed a single character of slack. See terminal_ids_match.
    tolerant = receipt.validation_method.endswith("ocr")
    return any(
        terminal_ids_match(terminal_id, candidate, tolerant=tolerant)
        for candidate in trusted
    )
