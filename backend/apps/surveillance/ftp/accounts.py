"""FTP credentials: made once when the setup is created, shown to the installer.

The installer types these into the DVR with a mouse on an on-screen keyboard,
often in a store room, so they are built for that:

* **Username** ``cam`` + four digits. Short, unique, obviously ours.
* **Password** twelve characters from lower-case letters and digits with the
  look-alikes removed (``0 o 1 l i``). Lower-case because the keyboard starts
  there and switching case is three clicks; alphanumeric because some firmwares
  refuse punctuation in this field; twelve characters of a 31-letter alphabet
  is ~59 bits, which is ample for a login only accepted from the shop's own
  network and locked out after repeated failures.
"""

from __future__ import annotations

import ipaddress
import re
import secrets

from django.db import IntegrityError, transaction

from ..models import FtpAccount, Recorder

USERNAME_PREFIX = "cam"
PASSWORD_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"
PASSWORD_LENGTH = 12

_HOSTNAME = re.compile(r"^(?=.{1,64}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?)*$")


def generate_password() -> str:
    return "".join(secrets.choice(PASSWORD_ALPHABET) for _ in range(PASSWORD_LENGTH))


def generate_username() -> str:
    """A free ``cam####``, widening to six digits if four ever run out."""
    for digits in (4, 4, 4, 4, 6, 6, 6, 6):
        low = 10 ** (digits - 1)
        candidate = f"{USERNAME_PREFIX}{low + secrets.randbelow(9 * low)}"
        if not FtpAccount.objects.filter(username=candidate).exists():
            return candidate
    raise RuntimeError("could not find a free FTP username")


def normalise_host(value: str) -> str:
    """An address worth announcing to a DVR, or ``""``.

    An IPv4 literal or a plain host name. Loopback is refused: it is what a
    till on the server machine reaches the backend on, and on a DVR it would
    mean the DVR itself.
    """
    text = str(value or "").strip()
    if not text:
        return ""
    try:
        address = ipaddress.ip_address(text)
    except ValueError:
        return text.lower() if _HOSTNAME.match(text) and text.lower() != "localhost" else ""
    if address.version != 4 or address.is_loopback or address.is_unspecified:
        return ""
    return str(address)


@transaction.atomic
def create_account(recorder: Recorder, *, advertised_host: str = "") -> FtpAccount:
    for _ in range(5):
        try:
            with transaction.atomic():
                return FtpAccount.objects.create(
                    recorder=recorder,
                    username=generate_username(),
                    password=generate_password(),
                    advertised_host=normalise_host(advertised_host),
                )
        except IntegrityError:
            # Another setup took the same username between the check and the
            # insert. Vanishingly rare; draw again.
            continue
    raise RuntimeError("could not create FTP credentials")


def regenerate_password(account: FtpAccount) -> FtpAccount:
    account.password = generate_password()
    account.failed_login_count = 0
    account.save(update_fields=["password", "failed_login_count", "updated_at"])
    return account
