"""Re-encode stored product images the clients cannot decode.

Product images imported before server-side normalization landed were stored in
whatever format the remote host served -- AVIF, TIFF, an ICO -- which saves
without complaint and then renders as nothing, because Flutter's decoder only
handles JPEG/PNG/GIF/WebP/BMP. Fixing the import path only helps new images, so
this backfills the ones a shop already has: it is the difference between "new
images work now" and "the images I saved last month finally appear".
"""

import json

from django.core.management.base import BaseCommand
from django.core.files.uploadedfile import SimpleUploadedFile

from apps.attachments.image_normalization import normalize_image_bytes
from apps.attachments.models import Attachment
from apps.attachments.services import (
    AttachmentStorageError,
    open_attachment,
    replace_attachment_file,
)


class Command(BaseCommand):
    help = "Re-encode stored product images into formats every client can render."

    def add_arguments(self, parser):
        parser.add_argument(
            "--dry-run",
            action="store_true",
            help="Report what would be re-encoded without writing anything.",
        )
        parser.add_argument(
            "--role",
            default=Attachment.Role.PRODUCT_IMAGE,
            help="Attachment role to sweep (default: product_image).",
        )

    def handle(self, *args, **options):
        dry_run = options["dry_run"]
        queryset = (
            Attachment.objects.active()
            .filter(role=options["role"])
            .select_related("storage_volume")
            .order_by("pk")
        )

        summary = {"scanned": 0, "already_renderable": 0, "reencoded": 0, "unreadable": 0}
        for attachment in queryset.iterator():
            summary["scanned"] += 1
            try:
                with open_attachment(attachment) as handle:
                    data = handle.read()
            except (AttachmentStorageError, OSError) as exc:
                # A missing or unreadable file is a storage problem, not an
                # encoding one; report it and leave the row alone.
                summary["unreadable"] += 1
                self.stderr.write(f"attachment {attachment.pk}: unreadable ({exc})")
                continue

            normalized = normalize_image_bytes(data)
            if normalized is None:
                summary["unreadable"] += 1
                self.stderr.write(
                    f"attachment {attachment.pk}: not a decodable image, left as-is"
                )
                continue
            if normalized.data == data:
                summary["already_renderable"] += 1
                continue

            summary["reencoded"] += 1
            self.stdout.write(
                f"attachment {attachment.pk}: {attachment.content_type or 'unknown'} "
                f"-> {normalized.content_type}"
                + (" (dry run)" if dry_run else "")
            )
            if dry_run:
                continue

            stem = (attachment.original_filename or "product-image").rsplit(".", 1)[0]
            replace_attachment_file(
                attachment,
                SimpleUploadedFile(
                    f"{stem or 'product-image'}{normalized.extension}",
                    normalized.data,
                    content_type=normalized.content_type,
                ),
            )

        self.stdout.write(
            self.style.SUCCESS(
                "Dry run complete; nothing written." if dry_run else "Stored images normalized."
            )
        )
        self.stdout.write(json.dumps(summary, indent=2, sort_keys=True))
