"""Protocol drivers for price-checker hardware.

There is no universal price-checker protocol, but real devices cluster into a
few families. A :class:`Driver` captures one family: its transport, default
display capabilities, how to pull a barcode out of an inbound message, and how
to render a :class:`~apps.price_checker.pricing.PriceResult` back to it.

Supporting a new make is then a small subclass — usually just default
capabilities and the line terminator/framing — not a new subsystem. The base
class already lays out a sensible name/price/discount screen in Arabic or Latin.
"""

from __future__ import annotations

from dataclasses import dataclass

from .formatting import (
    DisplayProfile,
    encode_text,
    format_money,
    layout_lines,
    plan_for_support,
)
from .models import PriceCheckerDevice
from .pricing import PriceResult


@dataclass(frozen=True, slots=True)
class Labels:
    not_found: str
    was: str
    save: str
    out_of_stock: str


LABELS_EN = Labels("Not found", "Was", "Save", "Out of stock")
LABELS_AR = Labels("غير موجود", "بدلاً من", "وفّر", "غير متوفر")


class Driver:
    """Base driver. Subclasses set capabilities and, if needed, framing."""

    key: str = ""
    label: str = ""
    make: str = ""
    model: str = ""
    transport: str = PriceCheckerDevice.Transport.TCP

    default_rows: int = 5
    default_cols: int = 20
    default_arabic: str = PriceCheckerDevice.ArabicSupport.UNICODE
    default_encoding: str = "utf-8"
    default_port: int | None = None

    # Line terminator and optional framing for byte-oriented transports.
    line_terminator: str = "\r\n"
    frame_prefix: bytes = b""
    frame_suffix: bytes = b""

    # ----- registration helpers -------------------------------------------
    def profile(self) -> DisplayProfile:
        """Display profile from this driver's defaults (no device record)."""
        return DisplayProfile(
            rows=max(1, self.default_rows),
            cols=max(1, self.default_cols),
            plan=plan_for_support(self.default_arabic),
            encoding=self.default_encoding,
        )

    def default_device_fields(self) -> dict:
        return {
            "driver": self.key,
            "make": self.make,
            "model": self.model,
            "transport": self.transport,
            "display_rows": self.default_rows,
            "display_cols": self.default_cols,
            "arabic_support": self.default_arabic,
            "encoding": self.default_encoding,
            "port": self.default_port,
        }

    # ----- inbound --------------------------------------------------------
    def parse_request(self, data: bytes) -> str | None:
        """Extract a barcode from a raw inbound socket message.

        Default: decode as ASCII and keep alphanumerics, which discards typical
        STX/ETX/CR/LF framing and whitespace. Override for exotic framing.
        """
        if not data:
            return None
        text = data.decode("ascii", errors="ignore")
        cleaned = "".join(ch for ch in text if ch.isalnum())
        return cleaned or None

    # ----- outbound -------------------------------------------------------
    def display_lines(self, result: PriceResult, profile: DisplayProfile) -> list[str]:
        """Logical (un-shaped) lines for the screen, Arabic or Latin."""
        labels = LABELS_AR if profile.allow_arabic else LABELS_EN
        allow = profile.allow_arabic
        if not result.found:
            return [labels.not_found]

        lines = [result.product_name]
        if result.variant_name and result.variant_name != result.product_name:
            lines.append(result.variant_name)
        lines.append(format_money(result.final_price, allow_arabic=allow))
        if result.has_discount:
            lines.append(
                f"{labels.was} {format_money(result.original_price, allow_arabic=allow)}"
            )
            if result.discount_percent > 0:
                lines.append(f"{labels.save} {result.discount_percent}%")
            else:
                lines.append(
                    f"{labels.save} "
                    f"{format_money(result.discount_total, allow_arabic=allow)}"
                )
        if not result.in_stock:
            lines.append(labels.out_of_stock)
        return lines

    def encode_response(self, result: PriceResult, profile: DisplayProfile) -> bytes:
        """Full wire payload for a byte-oriented transport."""
        laid_out = layout_lines(self.display_lines(result, profile), profile)
        body = encode_text(self.line_terminator.join(laid_out), profile)
        return self.frame_prefix + body + self.frame_suffix


class GenericHttpDriver(Driver):
    """Web-kiosk / Windows / Android devices that GET a URL and render HTML.

    These are the Arabic-friendly ones: the browser/OS shapes and reorders, so
    we hand back logical UTF-8 (the view returns structured JSON the kiosk page
    renders with ``dir="rtl"``).
    """

    key = "generic_http"
    label = "Generic HTTP / web kiosk"
    make = "Generic"
    model = "Web kiosk"
    transport = PriceCheckerDevice.Transport.HTTP
    default_rows = 8
    default_cols = 40
    default_arabic = PriceCheckerDevice.ArabicSupport.UNICODE
    default_encoding = "utf-8"


class ScantechShuttleDriver(Driver):
    """Scantech-ID Shuttle (SG-15 family) — TCP, ~5x20 mono display.

    The mono unit ships a CP1256 Arabic font that shapes letters but does not
    reorder RTL, so we send base letters in visual order. The Colour model can
    take Unicode; flip ``arabic_support`` to ``unicode`` per-device for those.
    """

    key = "scantech_shuttle"
    label = "Scantech-ID Shuttle (SG-15)"
    make = "Scantech-ID"
    model = "Shuttle SG-15"
    transport = PriceCheckerDevice.Transport.TCP
    default_rows = 5
    default_cols = 20
    default_arabic = PriceCheckerDevice.ArabicSupport.CP1256
    default_encoding = "cp1256"
    default_port = 9101
    line_terminator = "\r"


class GenericTcpDriver(Driver):
    """Catch-all socket verifier: barcode in, newline-delimited text back."""

    key = "generic_tcp"
    label = "Generic TCP verifier"
    make = "Generic"
    model = "TCP verifier"
    transport = PriceCheckerDevice.Transport.TCP
    default_port = 9100
    default_arabic = PriceCheckerDevice.ArabicSupport.UNICODE


class GenericUdpDriver(Driver):
    """UDP verifier: one datagram in (barcode), one datagram out (text)."""

    key = "generic_udp"
    label = "Generic UDP verifier"
    make = "Generic"
    model = "UDP verifier"
    transport = PriceCheckerDevice.Transport.UDP
    default_port = 9100
    default_arabic = PriceCheckerDevice.ArabicSupport.UNICODE


_DRIVERS: dict[str, Driver] = {}


def register(driver: Driver) -> Driver:
    _DRIVERS[driver.key] = driver
    return driver


for _driver in (
    GenericHttpDriver(),
    ScantechShuttleDriver(),
    GenericTcpDriver(),
    GenericUdpDriver(),
):
    register(_driver)


DEFAULT_DRIVER_KEY = GenericHttpDriver.key


def get_driver(key: str) -> Driver | None:
    return _DRIVERS.get(key)


def driver_for_device(device: PriceCheckerDevice) -> Driver:
    return _DRIVERS.get(device.driver) or _DRIVERS[DEFAULT_DRIVER_KEY]


def all_drivers() -> list[Driver]:
    return list(_DRIVERS.values())


def driver_keys() -> list[str]:
    return list(_DRIVERS.keys())
