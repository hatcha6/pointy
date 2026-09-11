"""Read the fields off a receipt image the issuer rendered for us.

This is not photo OCR. The bitmap comes straight from Madfoatech's own
renderer — fixed layout, fixed font, no camera, no glare, no skew — which is the
easy end of the problem: every value reads at full confidence in practice. What
does *not* read is the Arabic label beside each value, so nothing here keys on
labels. The values are all ASCII and their order down the slip is fixed, so the
extraction anchors on the patterns that cannot be confused with each other
(``LYD 8.500``, a 12-digit RRN, ``dd/mm/yyyy``) and locates the rest relative to
those.

OCR is optional at runtime, exactly like ``apps.companion.decoding``: a backend
built without tesseract still verifies that a receipt *exists* on the issuer's
server, it just cannot read the amount off it. That degradation is deliberate —
losing the amount check is much better than refusing genuine receipts.
"""

import logging
import re
from decimal import Decimal, InvalidOperation

logger = logging.getLogger(__name__)

# Glyphs tesseract trades for one another in a terminal id. The ids are short,
# uppercase and meaningless, so there is no dictionary or checksum to fall back
# on: "0ZWTOF8E" reads as "OZWTOF8E" and nothing in the string says which is
# right. Rather than guess, both sides of every comparison are folded into one
# representative per confusable class -- so a misread can never reject a
# terminal the shop really owns.
_CONFUSABLE_GLYPHS = str.maketrans(
    {
        "O": "0",
        "Q": "0",
        "D": "0",
        "I": "1",
        "L": "1",
        "|": "1",
        "Z": "2",
        "S": "5",
        "B": "8",
        "G": "6",
    }
)


def normalize_terminal_id(value) -> str:
    """Fold a terminal id to a form that survives OCR.

    Applied to the shop's configured list *and* to what was read off the slip,
    so the two are compared in the same alphabet.
    """
    text = re.sub(r"[^0-9A-Za-z]", "", str(value or "")).upper()
    return text.translate(_CONFUSABLE_GLYPHS)


def terminal_ids_match(read_value: str, configured: str, *, tolerant: bool) -> bool:
    """Whether a terminal id read off a slip is the configured one.

    Exact (after folding) for a provider that hands us the id as data. For one
    we had to OCR, a single edit is allowed as well, because the id is short,
    meaningless and genuinely unstable under OCR: the same bitmap read at two
    preprocessing settings gave "0ZWTOF8E" and "OZWTOFS8E", an inserted
    character that no glyph folding can undo.

    The alternative -- demanding an exact read -- would flag honest sales as
    coming from a foreign terminal, which is the worst failure mode a fraud
    control can have. A shop lists one or two terminals, so the chance that a
    genuinely foreign one sits within a single edit of a trusted id is remote.
    """
    if read_value == configured:
        return True
    if not tolerant:
        return False
    return _within_one_edit(read_value, configured)


def _within_one_edit(a: str, b: str) -> bool:
    """Levenshtein distance of at most one, without building a matrix."""
    if abs(len(a) - len(b)) > 1:
        return False
    if len(a) == len(b):
        return sum(x != y for x, y in zip(a, b)) <= 1
    shorter, longer = (a, b) if len(a) < len(b) else (b, a)
    for index in range(len(longer)):
        if shorter == longer[:index] + longer[index + 1 :]:
            return True
    return False


def ocr_available() -> bool:
    return _engine() is not None


def _engine():
    try:
        import pytesseract
        from PIL import Image  # noqa: F401
    except ImportError:  # pragma: no cover - OCR not installed
        return None
    try:
        pytesseract.get_tesseract_version()
    except Exception:  # pragma: no cover - binary missing
        return None
    return pytesseract


def read_receipt_fields(image_bytes: bytes) -> dict:
    """Extract what we can from a rendered receipt, as ``CardReceipt.fields``.

    Returns ``{}`` when OCR is unavailable or the image will not open; callers
    treat that as "unverified amount", never as "no match".
    """
    lines = _ocr_lines(image_bytes)
    if not lines:
        return {}
    return _fields_from_lines(lines)


def _ocr_lines(image_bytes: bytes) -> list[str]:
    pytesseract = _engine()
    if pytesseract is None:
        return []
    try:
        import io

        from PIL import Image

        with Image.open(io.BytesIO(image_bytes)) as image:
            image = image.convert("L")
            # The slip renders around 309px wide. Tesseract is trained on text
            # far larger than that, and upscaling a crisp synthetic bitmap costs
            # nothing and measurably steadies the digits.
            image = image.resize(
                (image.width * 3, image.height * 3),
                Image.LANCZOS,
            )
            text = pytesseract.image_to_string(
                image,
                lang="eng",
                config="--psm 6",
            )
    except Exception:
        logger.debug("card receipt OCR failed", exc_info=True)
        return []
    return [line.strip() for line in text.splitlines() if line.strip()]


def _fields_from_lines(lines: list[str]) -> dict:
    """Pick values out of the OCR'd lines by shape, then by position.

    Order down the slip is fixed: terminal, merchant, PAN, scheme, batch,
    receipt number, date, time, RRN, auth code, amount. Only the unambiguous
    shapes are anchored on; the ambiguous six-digit runs (batch / receipt /
    auth) are placed relative to those anchors rather than by counting from the
    top, so an extra or missing line does not shift every field after it.
    """
    joined = "\n".join(lines)
    fields: dict = {}

    # Every pattern here spells digits as [0-9] rather than \d. Python's \d is
    # Unicode-aware and matches Arabic-Indic digits, so a garbled Arabic label
    # sharing a line with a value would satisfy a \D anchor and shift a field.
    amount_match = re.search(
        r"\b(LYD|USD|EUR)\s*([0-9]+(?:[.,][0-9]{1,3})?)", joined
    ) or re.search(r"\b([A-Z]{3})\s*([0-9]+[.,][0-9]{2,3})\b", joined)
    if amount_match:
        fields["Currency"] = amount_match.group(1)
        fields["Amount"] = amount_match.group(2).replace(",", ".")

    status = _first_match(r"\b(APPROVED|DECLINED|REJECTED)\b", joined)
    if status:
        fields["TransactionStatus"] = status

    pan = _first_match(r"([*Xx#]{3,}\s*[0-9]{4})", joined)
    if pan:
        fields["PAN"] = re.sub(r"\s+", "", pan)

    rrn_index = _line_index(lines, r"(?<![0-9])[0-9]{12}(?![0-9])")
    if rrn_index is not None:
        fields["RRN"] = _first_match(r"((?<![0-9])[0-9]{12}(?![0-9]))", lines[rrn_index])
        # The authorisation code is the six-digit run directly beneath the RRN.
        for line in lines[rrn_index + 1 :]:
            auth = _six_digit_run(line)
            if auth:
                fields["AuthorizationCode"] = auth
                break

    date_index = _line_index(lines, r"[0-9]{2}/[0-9]{2}/[0-9]{4}")
    if date_index is not None:
        date_text = _first_match(r"([0-9]{2}/[0-9]{2}/[0-9]{4})", lines[date_index])
        time_text = ""
        for line in lines[date_index:]:
            time_text = _first_match(r"((?<![0-9])[0-9]{2}:[0-9]{2}(?::[0-9]{2})?)", line)
            if time_text:
                break
        fields["DateTime"] = f"{date_text} {time_text}".strip()
        # Batch then receipt number are the two six-digit runs above the date --
        # and only if BOTH are found. They are told apart by their order, so
        # when one of them fails to read there is no way to know which survived,
        # and recording the receipt number as the batch number is worse than
        # recording neither. Observed: "000029" reads as "aooo29" and vanishes,
        # leaving the receipt number sitting where the batch should be.
        above = [
            value
            for line in lines[:date_index]
            if (value := _six_digit_run(line))
        ]
        if len(above) > 1:
            fields["BATCH"] = above[0]
            fields["InvoiceNumber"] = above[1]

    # The terminal id is the only short run carrying BOTH letters and digits.
    # That is what separates it from everything around it: the merchant name
    # above ("SUFYAN") is letters only, the merchant number below is a long run
    # of digits only, and "APPROVED" further down is letters only.
    terminal = _first_match(
        r"(?<![0-9A-Z])(?=[0-9A-Z]{6,10}(?![0-9A-Z]))"
        r"(?=[0-9A-Z]*[A-Z])(?=[0-9A-Z]*[0-9])([0-9A-Z]{6,10})",
        joined,
    )
    if terminal:
        fields["TerminalId"] = terminal

    scheme = _first_match(r"\b(NUMO|VISA|MASTERCARD|MADA|LOCAL|AMEX)\b", joined.upper())
    if scheme:
        fields["CardType"] = scheme

    # Cardholder names print as SURNAME/FORENAME. Not anchored to the line ends:
    # an Arabic label garbled onto the same line would break that anchor.
    cardholder = _first_match(r"([A-Z][A-Z .'-]{1,30}/[A-Z][A-Z .'-]{1,30})", joined)
    if cardholder:
        fields["CardholderName"] = cardholder.strip()

    return fields


def _six_digit_run(line: str) -> str:
    """A line whose only number is exactly six digits, e.g. a batch or auth code."""
    return _first_match(r"(?<![0-9])([0-9]{6})(?![0-9])", line)


def _first_match(pattern: str, text: str, flags: int = 0) -> str:
    match = re.search(pattern, text, flags)
    return match.group(1).strip() if match else ""


def _line_index(lines: list[str], pattern: str):
    for index, line in enumerate(lines):
        if re.search(pattern, line):
            return index
    return None


def parse_ocr_amount(value) -> Decimal | None:
    """The amount as money, or ``None`` when OCR did not produce a usable one.

    Libyan dinar prints three decimals (``LYD 8.500``) while payments are stored
    to two, so the value is quantized the same way every other money figure in
    the codebase is rather than carrying a third place only this provider has.
    """
    text = re.sub(r"[^0-9.]", "", str(value or ""))
    if not text or text.count(".") > 1:
        return None
    try:
        return Decimal(text).quantize(Decimal("0.01"))
    except (InvalidOperation, ValueError):
        return None
