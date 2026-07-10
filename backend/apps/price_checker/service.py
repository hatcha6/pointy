"""Shared, synchronous scan handling.

Both the HTTP endpoint and the socket daemon funnel through here so audit
logging and device bookkeeping stay identical regardless of transport. Kept
sync (plain Django ORM) and side-effect-contained so it is trivially unit
testable; the async daemon calls it via ``asyncio.to_thread``.
"""

from __future__ import annotations

import time
from collections.abc import Callable

from django.conf import settings

from . import discovery, drivers
from .formatting import profile_from_device
from .models import PriceCheckerDevice, PriceCheckEvent
from .pricing import PriceResult


def _currency() -> str:
    return str(getattr(settings, "POINTY_CURRENCY_SUFFIX", "د.ل"))


def log_scan(
    *,
    device: PriceCheckerDevice | None,
    barcode: str,
    result: PriceResult,
    source_address: str = "",
    latency_ms: int | None = None,
    response_text: str = "",
    error: str = "",
) -> PriceCheckEvent:
    if error:
        outcome = PriceCheckEvent.Result.ERROR
    elif result.found:
        outcome = PriceCheckEvent.Result.FOUND
    else:
        outcome = PriceCheckEvent.Result.NOT_FOUND

    return PriceCheckEvent.objects.create(
        device=device,
        device_identifier=device.identifier if device else "",
        barcode=barcode or "",
        result=outcome,
        variant_id=result.variant_id if result.found else None,
        product_name=result.product_name if result.found else "",
        original_price=result.original_price if result.found else None,
        final_price=result.final_price if result.found else None,
        discount_total=result.discount_total if result.found else None,
        currency=_currency() if result.found else "",
        response_text=response_text,
        source_address=source_address or "",
        latency_ms=latency_ms,
        metadata={"error": error} if error else {},
    )


def perform_lookup(
    barcode: str | None,
    *,
    device: PriceCheckerDevice | None = None,
    source_address: str = "",
    render_lines: Callable[[PriceResult], list[str]] | None = None,
    with_image: bool = False,
) -> tuple[PriceResult, PriceCheckEvent]:
    """Canonical "look up + touch device + audit" path for every transport.

    ``with_image`` is opt-in so byte-oriented socket scanners (which only render
    text) never pay for the extra attachment query — only HTTP/web kiosks do.
    """
    started = time.perf_counter()
    # Cached behind the catalog + discount versions (see cache.py); the audit
    # event below is still written for every scan.
    from .cache import lookup_price_cached

    result = (
        lookup_price_cached(barcode, with_image=with_image)
        if barcode
        else PriceResult.not_found("")
    )
    latency_ms = int((time.perf_counter() - started) * 1000)

    if device is not None:
        device.mark_seen(address=source_address or None)

    response_text = "\n".join(render_lines(result)) if render_lines else ""
    event = log_scan(
        device=device,
        barcode=barcode or "",
        result=result,
        source_address=source_address,
        latency_ms=latency_ms,
        response_text=response_text,
    )
    return result, event


def process_socket_scan(
    raw: bytes,
    *,
    peer_ip: str,
    transport: str,
    local_port: int | None = None,
) -> bytes:
    """End-to-end handler for a byte-oriented scan: bytes in, wire bytes out.

    Resolves (or self-registers) the device, picks its driver, prices the
    barcode, logs the scan, and renders the reply for the device's display.
    """
    default_driver_key = discovery.driver_for_port(local_port) if local_port else None
    device = discovery.resolve_device_for_peer(
        peer_ip,
        transport,
        default_driver_key=default_driver_key,
    )
    if device is not None:
        driver = drivers.driver_for_device(device)
        profile = profile_from_device(device)
    else:
        driver = drivers.get_driver(default_driver_key or "") or drivers.get_driver(
            drivers.DEFAULT_DRIVER_KEY
        )
        profile = driver.profile()

    barcode = driver.parse_request(raw)
    result, _ = perform_lookup(
        barcode,
        device=device,
        source_address=peer_ip,
        render_lines=lambda r: driver.display_lines(r, profile),
    )
    return driver.encode_response(result, profile)
