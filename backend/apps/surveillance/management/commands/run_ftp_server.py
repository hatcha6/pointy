"""Run the FTP server DVRs upload footage to, with its ingest.

The ``ftp`` role of the backend image runs this. See SURVEILLANCE_FTP_PLAN.md.

    python manage.py run_ftp_server [--port 2121] [--bind 0.0.0.0]
"""

import logging

from django.core.management.base import BaseCommand

from apps.surveillance.ftp.service import FtpService


class Command(BaseCommand):
    help = "Run the FTP server recorders upload footage to, and decide what to keep."

    def add_arguments(self, parser):
        parser.add_argument("--port", type=int, default=None, help="Listen port (default POINTY_FTP_PORT).")
        parser.add_argument("--bind", default=None, help="Listen address (default POINTY_FTP_BIND).")

    def handle(self, *args, **options):
        if not logging.root.handlers:
            # This process's log is what an installer reads over a support
            # call — "logged in from 192.168.1.108", "kept 3, discarded 40" —
            # so its own INFO lines have to reach stdout.
            logging.basicConfig(
                level=logging.INFO,
                format="[%(levelname).1s %(asctime)s] %(name)s: %(message)s",
            )
        FtpService(host=options["bind"], port=options["port"]).serve_forever()
