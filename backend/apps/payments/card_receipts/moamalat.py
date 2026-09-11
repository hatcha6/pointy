"""Moamalat receipt links: the whole receipt travels inside the QR.

``https://receipt.moamalat.net/...#/digital/ticket?query=<payload>`` where the
payload is ``receiptId;type;version;{json}``, deflated and base64'd. Everything a
till needs is in there, so this provider never touches the network and works in
a power cut — which is the reason the amount check can be live at the counter.

What it cannot do is prove the payload is genuine. Nothing in the link is
signed, so a well-formed forgery decodes just as cleanly as a real slip. That is
why ``server_validated`` is False here and why the trusted-terminal list matters:
the terminal id is the only thing tying a receipt to *this* shop.
"""

import base64
import binascii
import json
import re
import zlib
from decimal import Decimal, InvalidOperation
from urllib.parse import parse_qs, urlparse

from .base import (
    MONEY_PLACES,
    CardReceipt,
    CardReceiptError,
    clean_string,
    receipt_is_successful,
)

KEY = "moamalat"
RECEIPT_HOST = "receipt.moamalat.net"


def handles(url: str) -> bool:
    """Whether this is a Moamalat receipt link at all.

    The question a till has to answer before it can react to a scan: a counter
    meets product barcodes, loyalty cards and the odd stray QR, and only
    something addressed to the receipt host is worth treating — or complaining
    about — as a card receipt.
    """
    try:
        parsed = urlparse(url.strip())
    except ValueError:
        return False
    return parsed.scheme == "https" and parsed.hostname == RECEIPT_HOST


def parse(url: str) -> CardReceipt:
    parsed = urlparse(url.strip())
    if parsed.scheme != "https" or parsed.hostname != RECEIPT_HOST:
        raise CardReceiptError("Receipt must be a Moamalat HTTPS receipt URL.")

    encoded_query = _receipt_query_param(parsed)
    text = _inflate_query_payload(encoded_query)
    parts = text.split(";", 3)
    if len(parts) != 4:
        raise CardReceiptError("Receipt payload has an unsupported format.")

    try:
        fields = json.loads(parts[3])
    except json.JSONDecodeError as exc:
        raise CardReceiptError("Receipt payload is not valid JSON.") from exc
    if not isinstance(fields, dict):
        raise CardReceiptError("Receipt payload is not an object.")

    amount = _parse_amount(fields.get("Amount"))
    transaction_type = clean_string(fields.get("TransactionType")) or parts[1].strip()
    receipt = CardReceipt(
        provider=KEY,
        source_url=url.strip(),
        receipt_id=parts[0].strip(),
        validation_method="decoded_receipt_payload",
        server_validated=False,
        amount=amount,
        transaction_type=transaction_type,
        language=parts[2].strip(),
        fields=fields,
    )
    if not receipt_is_successful(fields):
        raise CardReceiptError("Receipt transaction is not marked successful.")
    if not fields.get("PAN") or not receipt.reference:
        raise CardReceiptError("Receipt is missing card or reference details.")
    return receipt


def _receipt_query_param(parsed):
    query_string = parsed.query
    if not query_string and "?" in parsed.fragment:
        query_string = parsed.fragment.split("?", 1)[1]
    query = parse_qs(query_string).get("query", [""])[0].strip()
    if not query:
        raise CardReceiptError("Receipt URL is missing the query payload.")
    return query


def _inflate_query_payload(encoded_query):
    payload = encoded_query.replace(" ", "+")
    payload += "=" * ((4 - len(payload) % 4) % 4)
    try:
        compressed = base64.b64decode(payload, validate=True)
        return zlib.decompress(compressed).decode("utf-8")
    except (binascii.Error, ValueError, zlib.error, UnicodeDecodeError) as exc:
        raise CardReceiptError("Receipt payload could not be decoded.") from exc


def _parse_amount(value):
    match = re.search(r"\d+(?:[.,]\d+)*", str(value or ""))
    if match is None:
        raise CardReceiptError("Receipt is missing a payment amount.")
    amount_text = match.group(0).replace(",", ".")
    amount_parts = amount_text.split(".")
    if len(amount_parts) > 2:
        amount_text = "".join(amount_parts[:-1]) + "." + amount_parts[-1]
    try:
        return Decimal(amount_text).quantize(MONEY_PLACES)
    except InvalidOperation as exc:
        raise CardReceiptError("Receipt payment amount is invalid.") from exc
