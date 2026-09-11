"""Aclas LS2 / LS2X over FTP.

The LS2 family speaks both FTP and a TCP handshake (Aclas call it Link32). The
handshake is not published; FTP is, and it is what the vendor's own tool falls
back to. So this driver writes the PLU file into the scale's FTP root and lets
the scale pick it up, which is the same operation the shop's technician does by
hand today with a USB stick — minus the stick.

That makes it a file driver with a delivery mechanism rather than a protocol
client, and :attr:`PushOutcome.delivered` says so honestly: the bytes reached
the scale's filesystem, and the scale imports on its own schedule.
"""

from __future__ import annotations

import io
from ftplib import FTP, all_errors

from .base import (
    CONNECT_TIMEOUT,
    PluRecord,
    PushOutcome,
    ScaleDriver,
    ScaleError,
    ScaleUnreachableError,
)
from .file_export import FileExportDriver

DEFAULT_PORT = 21
DEFAULT_FILENAME = "plu.txt"


class AclasFtpDriver(ScaleDriver):
    key = "aclas_ftp"
    label = "Aclas LS2 (FTP)"
    needs_address = True
    default_port = DEFAULT_PORT

    def push(self, records: list[PluRecord]) -> PushOutcome:
        exported = FileExportDriver(options=self.options).push(records)
        filename = str(self.options.get("filename") or DEFAULT_FILENAME)
        with self._connect() as ftp:
            directory = str(self.options.get("directory") or "").strip("/")
            if directory:
                try:
                    ftp.cwd(directory)
                except all_errors as error:
                    raise ScaleError(
                        f"The scale has no folder '{directory}'."
                    ) from error
            try:
                ftp.storbinary(f"STOR {filename}", io.BytesIO(exported.content))
            except all_errors as error:
                raise ScaleError(f"The scale refused the file: {error}") from error
        # The file is on the scale, which is further than the export driver gets
        # but still not the same as the scale having imported it.
        return PushOutcome(sent=len(records), filename=filename)

    def check(self) -> None:
        self._connect().quit()

    def _connect(self) -> FTP:
        if not self.host:
            raise ScaleError("This scale has no address.")
        ftp = FTP()
        try:
            ftp.connect(self.host, self.port or DEFAULT_PORT, timeout=CONNECT_TIMEOUT)
            ftp.login(
                user=str(self.options.get("username") or "anonymous"),
                passwd=str(self.options.get("password") or ""),
            )
        except all_errors as error:
            raise ScaleUnreachableError(
                f"Could not sign in to the scale at {self.host}."
            ) from error
        return ftp
