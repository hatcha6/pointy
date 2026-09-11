"""What a weighing scale looks like from the outside.

A label-printing scale holds its own little product table — a PLU per item,
with the name and price it will print — and the shop's job every time a price
changes is to get that table to agree with the till again. Doing it by hand is
how a scale ends up selling tomatoes at last month's price, which is a wrong
number nobody can see until a customer argues about a receipt.

The awkward part is that there is no standard. CAS publishes a protocol. Aclas
speaks FTP. Most of what actually sells in Libya is a Chinese label scale whose
PLU table is loaded by a Windows tool reading a text file, and for those there
is nothing to talk to at all. So a driver here is not necessarily a network
client: :class:`ScaleDriver` covers both the ones that can be pushed to over a
wire and the ones that can only be *handed a file*, because a file is the only
thing that works on every scale ever sold.

Three failure modes are named separately, because the shop is told something
different about each: unreachable (wrong address, scale off, different VLAN),
refused (the scale answered and said no), and everything else.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from decimal import Decimal

#: Scales are on the shop's own switch. One that has not answered in this long
#: is off, or is not at that address.
CONNECT_TIMEOUT = 4.0
READ_TIMEOUT = 8.0

#: Most scales in this class hold a few thousand PLUs and accept them one at a
#: time. Pushing more than this in a single job is a sign the shop has selected
#: its whole catalog by mistake, and is refused before it spends ten minutes
#: finding out.
MAX_PLUS_PER_PUSH = 5000


class ScaleError(Exception):
    """Anything that stopped a push, with a message the shop can act on."""


class ScaleUnreachableError(ScaleError):
    """Nothing answered at that address."""


class ScaleRefusedError(ScaleError):
    """The scale answered, and said no."""


@dataclass(frozen=True)
class PluRecord:
    """One row of a scale's product table, vendor-neutral.

    Money is a :class:`~decimal.Decimal` of the shop's currency and weight is in
    grams; each driver converts into whatever its wire format wants. Doing it
    the other way round — storing minor units here because CAS wants them —
    would put one scale's quirk in front of every other driver.
    """

    plu_number: int
    name: str
    price: Decimal
    #: True when the scale should weigh this item; False for a by-the-piece PLU
    #: (a loaf, a box of eggs) that the scale prints a label for without
    #: weighing.
    is_weighed: bool = True
    tare_grams: int = 0
    shelf_life_days: int | None = None
    department: int = 1
    #: The item code the scale prints inside the barcode. Equals the PLU number
    #: for every scale we have met, and is kept separate anyway because the two
    #: are different fields on the wire and a shop may have inherited labels
    #: where they differ.
    item_code: int | None = None

    def __post_init__(self) -> None:
        if self.plu_number <= 0:
            raise ScaleError("A PLU number must be positive.")
        if self.price < 0:
            raise ScaleError("A PLU price cannot be negative.")

    @property
    def effective_item_code(self) -> int:
        return self.item_code if self.item_code is not None else self.plu_number


@dataclass
class PushOutcome:
    """What happened to a push, per PLU where the scale says so."""

    sent: int = 0
    failed: int = 0
    #: ``{plu_number: message}`` for the ones that did not land.
    errors: dict[int, str] = field(default_factory=dict)
    #: For file drivers: the bytes the shop has to carry to the scale, and what
    #: to call them. Empty for drivers that pushed over a wire.
    filename: str = ""
    content: bytes = b""

    @property
    def delivered(self) -> bool:
        """Whether the scale itself now holds these prices.

        False for a file driver even on success: the shop still has to load the
        file. Saying "done" at that point would be the same lie as retyping the
        prices and not checking.
        """

        return not self.filename and self.failed == 0 and self.sent > 0


class ScaleDriver(ABC):
    """One scale dialect.

    ``key`` is what a :class:`~apps.scales.models.Scale` row stores;
    ``needs_address`` says whether the shop has to give an IP for this driver to
    be usable at all, which is what the settings form asks on.
    """

    key: str = ""
    label: str = ""
    needs_address: bool = True
    default_port: int = 0

    def __init__(self, *, host: str = "", port: int = 0, options: dict | None = None):
        self.host = (host or "").strip()
        self.port = int(port or self.default_port)
        self.options = dict(options or {})

    @abstractmethod
    def push(self, records: list[PluRecord]) -> PushOutcome:
        """Get ``records`` onto the scale, or into a file bound for it."""

    def check(self) -> None:
        """Raise if the scale is not reachable. Default: nothing to check."""

        return None
