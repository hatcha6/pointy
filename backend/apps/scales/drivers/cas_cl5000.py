"""CAS CL5000 / CL5200 / CL5500 / CL7200 over Ethernet.

Built from the CAS *CL5000 Series Network Manual* (rev. 2006-08-31), which is
the only scale protocol in this class that is actually published. The scale
listens on TCP **20304** and takes four command prefixes — ``R`` read, ``W``
write, ``C`` command, ``I`` information. A PLU is written with::

    W02A<pluno>,<deptno>L<size>:<data blocks><bcc>
    <data block> := "F="<ptype>"."<stype>","<size>":"<data>
    <bcc>        := XOR over the data blocks

where ``ptype`` selects the field (name, price, tare…), ``stype`` its storage
class — ``S`` text, ``B`` one byte, ``W`` two, ``L`` four — and the reply is an
error line of the shape ``W<xx>:E<code>`` when the scale refuses.

**One thing here is not verified against hardware.** The manual's only worked
example of a numeric field is PLU 1000 in a four-byte field, given as bytes
``03 E8 00 00`` — the value big-endian in the leading bytes, zero-padded to the
right, which is neither plain big- nor little-endian. That is what
``byte_order="cas"`` writes, because it is what the document says. A shop whose
scale disagrees can switch the option to ``big`` or ``little`` without a code
change, and the first real CL5000 we put this in front of settles it. Nothing
else in the format is ambiguous.
"""

from __future__ import annotations

import socket

from .base import (
    CONNECT_TIMEOUT,
    READ_TIMEOUT,
    PluRecord,
    PushOutcome,
    ScaleDriver,
    ScaleError,
    ScaleRefusedError,
    ScaleUnreachableError,
)

DEFAULT_PORT = 20304

#: How long to listen for a complaint after writing one PLU.
#:
#: The manual documents an error line but never an acknowledgement, so a scale
#: that is happy may say nothing at all. Blocking for the full read timeout on
#: every PLU would turn a 400-item produce catalog into a fifty-minute push, so
#: the write waits only this long: bytes inside the window are a refusal to
#: report, silence is acceptance. A scale that *does* ack lands inside the same
#: window and is parsed the same way, so one implementation covers both.
ACK_WINDOW = 0.3

# ptype, stype, byte width. From the manual's field table.
FIELD_DEPARTMENT = (1, "W", 2)
FIELD_PLU_NUMBER = (2, "L", 4)
FIELD_PLU_TYPE = (4, "B", 1)
FIELD_NAME = (10, "S", 40)
FIELD_UNIT_WEIGHT = (5, "B", 1)
FIELD_PRICE = (6, "L", 4)
FIELD_ITEM_CODE = (11, "L", 4)
FIELD_TARE = (13, "L", 4)

#: PLU type: 1 = weighed by the scale, 2 = sold by the piece.
PLU_TYPE_WEIGHED = 1
PLU_TYPE_BY_COUNT = 2

#: The scale's own name field is fixed width and single byte. Arabic does not
#: survive it on most units; see ``ScalePlu.label_name`` for where a shop puts
#: the name its scale can actually print.
NAME_ENCODING = "cp1256"


class CasCl5000Driver(ScaleDriver):
    key = "cas_cl5000"
    label = "CAS CL5000 / CL7200"
    needs_address = True
    default_port = DEFAULT_PORT

    def push(self, records: list[PluRecord]) -> PushOutcome:
        outcome = PushOutcome()
        with self._connect() as connection:
            for record in records:
                try:
                    self._write_plu(connection, record)
                except ScaleRefusedError as error:
                    # This PLU was refused; the rest may still land, and the
                    # shop is told which ones did not.
                    outcome.failed += 1
                    outcome.errors[record.plu_number] = str(error)
                else:
                    outcome.sent += 1
                # An unreachable scale is deliberately *not* caught: the socket
                # is gone, so carrying on would spend a minute per item proving
                # it four hundred more times.
        return outcome

    def check(self) -> None:
        self._connect().close()

    # --- wire ---------------------------------------------------------------
    def _connect(self) -> socket.socket:
        if not self.host:
            raise ScaleError("This scale has no address.")
        try:
            connection = socket.create_connection(
                (self.host, self.port or DEFAULT_PORT),
                timeout=CONNECT_TIMEOUT,
            )
        except OSError as error:
            raise ScaleUnreachableError(
                f"Could not reach the scale at {self.host}:{self.port or DEFAULT_PORT}."
            ) from error
        connection.settimeout(READ_TIMEOUT)
        return connection

    def _write_plu(self, connection: socket.socket, record: PluRecord) -> None:
        blocks = b"".join(self._blocks(record))
        header = (
            f"W02A{record.plu_number},{record.department}"
            f"L{len(blocks)}:"
        ).encode("ascii")
        payload = header + blocks + bytes([_bcc(blocks)])
        try:
            connection.sendall(payload)
        except OSError as error:
            raise ScaleUnreachableError("The scale stopped answering.") from error
        _raise_for_reply(self._read_complaint(connection), record.plu_number)

    def _read_complaint(self, connection: socket.socket) -> bytes:
        """Whatever the scale had to say in the moment after a write.

        Empty means it said nothing, which is what a contented CL5000 does.
        """

        window = float(self.options.get("ack_window", ACK_WINDOW))
        connection.settimeout(max(window, 0.05))
        try:
            return connection.recv(256)
        except TimeoutError:
            return b""
        except OSError as error:
            raise ScaleUnreachableError("The scale stopped answering.") from error
        finally:
            connection.settimeout(READ_TIMEOUT)

    def _blocks(self, record: PluRecord) -> list[bytes]:
        price_scale = int(self.options.get("price_scale", 100))
        blocks = [
            _block(FIELD_DEPARTMENT, self._number(record.department, 2)),
            _block(FIELD_PLU_NUMBER, self._number(record.plu_number, 4)),
            _block(
                FIELD_PLU_TYPE,
                self._number(
                    PLU_TYPE_WEIGHED if record.is_weighed else PLU_TYPE_BY_COUNT, 1
                ),
            ),
            _block(FIELD_NAME, _text(record.name, FIELD_NAME[2])),
            _block(
                FIELD_PRICE,
                self._number(int((record.price * price_scale).to_integral_value()), 4),
            ),
            _block(FIELD_ITEM_CODE, self._number(record.effective_item_code, 4)),
        ]
        if record.tare_grams:
            blocks.append(_block(FIELD_TARE, self._number(record.tare_grams, 4)))
        return blocks

    def _number(self, value: int, width: int) -> bytes:
        order = str(self.options.get("byte_order") or "cas").lower()
        if value < 0:
            raise ScaleError("Negative values cannot be written to a scale.")
        if order == "little":
            return int(value).to_bytes(width, "little", signed=False)
        if order == "big":
            return int(value).to_bytes(width, "big", signed=False)
        # The manual's own layout: the value big-endian in as few bytes as it
        # needs, then zero padding out to the field width.
        significant = max(1, (int(value).bit_length() + 7) // 8)
        if significant > width:
            raise ScaleError(f"{value} does not fit in {width} bytes.")
        return int(value).to_bytes(significant, "big") + bytes(width - significant)


def _block(field: tuple[int, str, int], data: bytes) -> bytes:
    ptype, stype, _width = field
    return f"F={ptype}.{stype},{len(data)}:".encode("ascii") + data


def _text(value: str, width: int) -> bytes:
    encoded = (value or "").encode(NAME_ENCODING, errors="replace")[:width]
    return encoded.ljust(width, b"\x00")


def _bcc(data: bytes) -> int:
    checksum = 0
    for byte in data:
        checksum ^= byte
    return checksum


def _raise_for_reply(reply: bytes, plu_number: int) -> None:
    """The scale only speaks up when it is unhappy.

    An error line is ``W<xx>:E<code>``; ``0x82`` is the PLU mismatch the manual
    calls out and ``FE`` a checksum error, which is a bug on our side rather
    than the shop's and is worth saying so.
    """

    text = (reply or b"").decode("ascii", errors="replace").strip()
    if ":E" not in text:
        return
    code = text.split(":E", 1)[1].strip()[:2].upper()
    if code.upper() in {"FE"}:
        raise ScaleRefusedError(
            f"PLU {plu_number}: the scale rejected the message as corrupt."
        )
    raise ScaleRefusedError(f"PLU {plu_number}: the scale refused it (error {code}).")
