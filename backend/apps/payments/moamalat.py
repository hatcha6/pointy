import base64
import binascii
import json
import re
import zlib
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from urllib.parse import parse_qs, urlparse


MONEY_PLACES = Decimal("0.01")
MOAMALAT_RECEIPT_HOST = "receipt.moamalat.net"


class MoamalatReceiptError(ValueError):
    pass


@dataclass(frozen=True)
class MoamalatReceipt:
    receipt_id: str
    language: str
    transaction_type: str
    amount: Decimal
    fields: dict

    @property
    def reference(self) -> str:
        for key in ("RRN", "STAN", "AuthorizationCode", "InvoiceNumber"):
            value = self.fields.get(key)
            if value:
                return str(value).strip()
        return self.receipt_id

    @property
    def is_successful(self) -> bool:
        status = str(self.fields.get("TransactionStatus", "")).strip().lower()
        return "بنجاح" in status or "success" in status or "approved" in status

    def to_payment_data(self) -> dict:
        return {
            "provider": "moamalat",
            "validation_method": "decoded_receipt_payload",
            "server_validated": False,
            "receipt_id": self.receipt_id,
            "language": self.language,
            "transaction_type": self.transaction_type,
            "amount": f"{self.amount:.2f}",
            "amount_label": _clean_string(self.fields.get("Amount")),
            "transaction_status": _clean_string(
                self.fields.get("TransactionStatus")
            ),
            "merchant_name": _clean_string(self.fields.get("MerchantName")),
            "terminal_city": _clean_string(self.fields.get("TerminalCity")),
            "terminal_id": _clean_string(self.fields.get("TerminalId")),
            "card_type": _clean_string(self.fields.get("CardType")),
            "masked_pan": _clean_string(self.fields.get("PAN")),
            "aid": _clean_string(self.fields.get("AID")),
            "authorization_code": _clean_string(
                self.fields.get("AuthorizationCode")
            ),
            "rrn": _clean_string(self.fields.get("RRN")),
            "stan": _clean_string(self.fields.get("STAN")),
            "batch": _clean_string(self.fields.get("BATCH")),
            "invoice_number": _clean_string(self.fields.get("InvoiceNumber")),
            "transaction_datetime": _clean_string(self.fields.get("DateTime")),
        }


def parse_moamalat_receipt_url(url: str) -> MoamalatReceipt:
    parsed = urlparse(url.strip())
    if parsed.scheme != "https" or parsed.hostname != MOAMALAT_RECEIPT_HOST:
        raise MoamalatReceiptError("Receipt must be a Moamalat HTTPS receipt URL.")

    encoded_query = _receipt_query_param(parsed)
    text = _inflate_query_payload(encoded_query)
    parts = text.split(";", 3)
    if len(parts) != 4:
        raise MoamalatReceiptError("Receipt payload has an unsupported format.")

    try:
        fields = json.loads(parts[3])
    except json.JSONDecodeError as exc:
        raise MoamalatReceiptError("Receipt payload is not valid JSON.") from exc
    if not isinstance(fields, dict):
        raise MoamalatReceiptError("Receipt payload is not an object.")

    amount = _parse_amount(fields.get("Amount"))
    transaction_type = _clean_string(fields.get("TransactionType")) or parts[1].strip()
    receipt = MoamalatReceipt(
        receipt_id=parts[0].strip(),
        transaction_type=transaction_type,
        language=parts[2].strip(),
        amount=amount,
        fields=fields,
    )
    if not receipt.is_successful:
        raise MoamalatReceiptError("Receipt transaction is not marked successful.")
    if not receipt.fields.get("PAN") or not receipt.reference:
        raise MoamalatReceiptError("Receipt is missing card or reference details.")
    return receipt


def payment_amount_matches_receipt(amount, receipt: MoamalatReceipt) -> bool:
    try:
        expected = Decimal(amount).quantize(MONEY_PLACES)
    except (InvalidOperation, TypeError):
        return False
    return expected == receipt.amount.quantize(MONEY_PLACES)


def _receipt_query_param(parsed):
    query_string = parsed.query
    if not query_string and "?" in parsed.fragment:
        query_string = parsed.fragment.split("?", 1)[1]
    query = parse_qs(query_string).get("query", [""])[0].strip()
    if not query:
        raise MoamalatReceiptError("Receipt URL is missing the query payload.")
    return query


def _inflate_query_payload(encoded_query):
    payload = encoded_query.replace(" ", "+")
    payload += "=" * ((4 - len(payload) % 4) % 4)
    try:
        compressed = base64.b64decode(payload, validate=True)
        return zlib.decompress(compressed).decode("utf-8")
    except (binascii.Error, ValueError, zlib.error, UnicodeDecodeError) as exc:
        raise MoamalatReceiptError("Receipt payload could not be decoded.") from exc


def _parse_amount(value):
    match = re.search(r"\d+(?:[.,]\d+)*", str(value or ""))
    if match is None:
        raise MoamalatReceiptError("Receipt is missing a payment amount.")
    amount_text = match.group(0).replace(",", ".")
    amount_parts = amount_text.split(".")
    if len(amount_parts) > 2:
        amount_text = "".join(amount_parts[:-1]) + "." + amount_parts[-1]
    try:
        return Decimal(amount_text).quantize(MONEY_PLACES)
    except InvalidOperation as exc:
        raise MoamalatReceiptError("Receipt payment amount is invalid.") from exc


def _clean_string(value):
    return str(value or "").strip()
