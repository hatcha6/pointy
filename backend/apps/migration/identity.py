"""The identity resolver — idempotency and cross-entity FK resolution.

Wraps :class:`~apps.migration.models.MigrationIdentityMap` with an in-process
cache. During an **import** it persists ``source_key -> Pointy row`` mappings so
re-runs update instead of duplicate, and later entities resolve their foreign
keys through it. During a **dry run** nothing is persisted: ``remember`` only
populates the in-memory shadow (the just-inserted rows live inside the
about-to-be-rolled-back transaction), so children still resolve their parents
while the database is left untouched.
"""

from __future__ import annotations

from django.contrib.contenttypes.models import ContentType

from .models import MigrationIdentityMap


class IdentityResolver:
    def __init__(self, source, run, *, dry_run: bool):
        self.source = source
        self.run = run
        self.dry_run = dry_run
        # (entity_type, source_key) -> target pk
        self._cache: dict[tuple[str, str], int] = {}

    @staticmethod
    def _key(entity_type: str, source_key) -> tuple[str, str]:
        return (entity_type, str(source_key))

    def remember(self, entity_type: str, source_key, instance) -> None:
        """Record that a source record became ``instance``."""
        self._cache[self._key(entity_type, source_key)] = instance.pk
        if self.dry_run:
            return
        content_type = ContentType.objects.get_for_model(type(instance))
        mapping, created = MigrationIdentityMap.objects.get_or_create(
            source=self.source,
            entity_type=entity_type,
            source_key=str(source_key),
            defaults={
                "target_content_type": content_type,
                "target_object_id": instance.pk,
                "first_run": self.run,
                "last_seen_run": self.run,
            },
        )
        if not created:
            mapping.target_content_type = content_type
            mapping.target_object_id = instance.pk
            mapping.last_seen_run = self.run
            mapping.save(
                update_fields=[
                    "target_content_type",
                    "target_object_id",
                    "last_seen_run",
                    "updated_at",
                ]
            )

    def resolve(self, entity_type: str, source_key) -> int | None:
        """Return the Pointy pk a source record maps to, or ``None``."""
        if source_key in (None, ""):
            return None
        cache_key = self._key(entity_type, source_key)
        if cache_key in self._cache:
            return self._cache[cache_key]
        mapping = (
            MigrationIdentityMap.objects.filter(
                source=self.source,
                entity_type=entity_type,
                source_key=str(source_key),
            )
            .values_list("target_object_id", flat=True)
            .first()
        )
        if mapping is not None:
            self._cache[cache_key] = mapping
        return mapping

    def existing(self, model, entity_type: str, source_key):
        """The mapped model instance for re-run updates, or ``None``."""
        pk = self.resolve(entity_type, source_key)
        if pk is None:
            return None
        return model.objects.filter(pk=pk).first()
