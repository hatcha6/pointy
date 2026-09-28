"""Decide every due FTP upload now, and tidy the archive — for support.

The FTP service does this on its own every few seconds; this is for looking at
what it would do (``--dry-run`` is deliberately absent: the decision deletes
files, and a dry run that disagreed with the real one would be a lie).

    python manage.py ingest_footage [--housekeeping]
"""

from django.core.management.base import BaseCommand

from apps.surveillance.archive import housekeeping, ingest


class Command(BaseCommand):
    help = "Decide due FTP uploads now; optionally run archive housekeeping."

    def add_arguments(self, parser):
        parser.add_argument(
            "--housekeeping",
            action="store_true",
            help="Also apply retention and the disk budget.",
        )

    def handle(self, *args, **options):
        report = ingest.run_pass()
        self.stdout.write(
            f"decided {report.claimed}: kept {report.kept} ({report.clips} clips), "
            f"discarded {report.discarded}, unreadable {report.unreadable}, retried {report.retried}"
        )
        for error in report.errors:
            self.stdout.write(f"  ! {error}")
        if options["housekeeping"]:
            result = housekeeping.run()
            self.stdout.write(
                f"housekeeping: expired {result.expired}, pruned for space {result.pruned_for_space}, "
                f"adopted {result.adopted}, missing rows {result.missing_rows}, leftovers {result.orphan_dirs}"
            )
