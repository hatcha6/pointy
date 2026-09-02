"""Read a photographed supplier invoice into a fixed JSON shape.

This is the one genuinely fuzzy step of invoice intake: everything downstream —
matching, pricing, the purchase order — is deterministic and testable. So the
model's job here is narrow and the output is constrained by a JSON schema rather
than parsed out of prose.

Two things make the result trustworthy rather than merely plausible:

* the relay is told ``purpose="extract"``, so the call runs on the extraction
  model and skips the difficulty router;
* the arithmetic is checked afterwards, and any line whose quantity times cost
  does not equal its printed total is re-read in a second, targeted pass.

A line the model still cannot read comes back flagged, never guessed at.
"""

from __future__ import annotations

import json
import logging

from apps.core.relay import RelayControlClient, RelayControlError
from apps.invoice_intake.checks import arithmetic_checks
from apps.invoice_intake.schemas import INVOICE_EXTRACTION_SCHEMA

from .relay_stream import iter_relay_sse

logger = logging.getLogger(__name__)

# Reading a dense invoice is a long generation: every line costs tokens.
EXTRACTION_MAX_TOKENS = 8000

_SYSTEM_PROMPT = (
    "أنت تقرأ فاتورة مورّد مصوّرة وتحوّلها إلى JSON منظّم. "
    "انسخ ما هو مكتوب فعلًا على الورقة، ولا تخمّن أبدًا: "
    "إذا كان رقم غير واضح أو مقصوص، اترك الحقل فارغًا وأضف ملاحظة في notes بدل "
    "أن تضع رقمًا تقريبيًا. "
    "الكمية والتكلفة كما هما مطبوعتان (تكلفة الوحدة أو العبوة كما وردت). "
    "احتفظ باسم الصنف بالحروف نفسها التي كُتب بها، ولا تترجمه ولا تصحّحه، "
    "لأن الاسم الحرفي هو ما نطابق به مع أصناف المتجر. "
    "إن ذُكر حجم العبوة (كرتونة ١٢، شدّ ٦) فضعه في unit_label و pack_size. "
    "أعد JSON فقط دون أي شرح."
)

_RETRY_PROMPT = (
    "بعض السطور لم تتطابق حسابيًا (الكمية × التكلفة لا تساوي إجمالي السطر). "
    "أعد قراءة هذه السطور فقط من الصورة بأرقامها المطبوعة: {indexes}. "
    "أعد نفس بنية JSON كاملة مع تصحيح تلك السطور فقط."
)


def _response_format():
    return {
        "type": "json_schema",
        "json_schema": {
            "name": "invoice_extraction",
            "strict": True,
            "schema": INVOICE_EXTRACTION_SCHEMA,
        },
    }


def _collect(response):
    """Drain the relay SSE stream into the model's raw text."""
    chunks = []
    try:
        for event in iter_relay_sse(response):
            if event.get("event") == "delta":
                text = (event.get("data") or {}).get("text", "")
                if text:
                    chunks.append(text)
            elif event.get("event") == "error":
                detail = (event.get("data") or {}).get("detail", "extraction failed")
                raise RelayControlError(detail)
    finally:
        close = getattr(response, "close", None)
        if callable(close):
            close()
    return "".join(chunks)


def _parse(raw):
    """Parse the model's reply, tolerating a fenced block or surrounding prose."""
    text = (raw or "").strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except ValueError:
        pass
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end <= start:
        return None
    try:
        return json.loads(text[start : end + 1])
    except ValueError:
        return None


def _messages(prompt, attachments):
    return [
        {"role": "system", "content": _SYSTEM_PROMPT},
        {"role": "user", "content": prompt},
    ]


def extract_invoice(*, installation, attachments, client=None, max_passes=2):
    """Read ``attachments`` (invoice page images/PDFs) into the extraction shape.

    Returns ``(extraction, problems)``: the raw model JSON and the arithmetic
    problems still outstanding. Raises :class:`RelayControlError` when the relay
    itself refuses, and :class:`ValueError` when the model returns nothing
    parseable — both of which the caller turns into a failed intake the user can
    retry with a better photo.
    """
    if not attachments:
        raise ValueError("no invoice pages to read")

    client = client or RelayControlClient()
    prompt = "اقرأ هذه الفاتورة وأعد بياناتها بصيغة JSON."
    extraction = None
    problems = {}

    for attempt in range(max_passes):
        response = client.open_ai_stream(
            access_token=installation.access_token,
            messages=_messages(prompt, attachments),
            attachments=list(attachments),
            count_usage=(attempt == 0),
            max_tokens=EXTRACTION_MAX_TOKENS,
            temperature=0,
            response_format=_response_format(),
            purpose="extract",
        )
        parsed = _parse(_collect(response))
        if parsed is None:
            if extraction is not None:
                # The re-read failed; keep the first pass rather than losing it.
                break
            raise ValueError("the model returned no readable invoice data")
        extraction = parsed
        problems = arithmetic_checks(parsed)
        bad_lines = problems.get("line_indexes") or []
        if not bad_lines:
            break
        if attempt + 1 >= max_passes:
            break
        # Targeted second pass: name the lines that did not add up and ask for
        # those again. Cheaper and far more accurate than re-reading blind.
        prompt = _RETRY_PROMPT.format(
            indexes=", ".join(str(index) for index in bad_lines[:20])
        )
        logger.info("invoice extraction: re-reading %d line(s)", len(bad_lines))

    return extraction, problems
