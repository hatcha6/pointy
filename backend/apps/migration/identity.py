"""The identity resolver — idempotency and cross-entity FK resolution.

Wraps :class:`~apps.migration.models.MigrationIdentityMap` with an in-process
cache, tuned for large imports:

* **One preload query** loads every existing mapping for the source up front, so
  ``resolve``/``resolve_pk`` are pure in-memory lookups (no per-record query).
* ``remember`` writes a single ``INSERT`` for a newly-seen source key and does
  **nothing** on a re-run (the mapping is stable), self-healing only if the
  target row's pk actually changed (e.g. the mapped row was deleted and
  re-created). The insert stays inside the loader's per-record transaction, so a
  committed row always has its mapping — re-runs never duplicate.

During a **dry run** nothing is persisted: ``remember`` only updates the
in-memory cache (the just-inserted rows live inside the about-to-be-rolled-back
transaction), so children still resolve their parents while the database is left
untouched.
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
        # keys that already have a row in MigrationIdentityMap
        self._persisted: set[tuple[str, str]] = set()
        # ContentType is looked up once per model, not per record
        self._content_types: dict[type, ContentType] = {}
        self._preload()

    def _preload(self) -> None:
        rows = MigrationIdentityMap.objects.filter(source=self.source).values_list(
            "entity_type", "source_key", "target_object_id"
        )
        for entity_type, source_key, target_pk in rows.iterator():
            key = (entity_type, source_key)
            self._cache[key] = target_pk
            self._persisted.add(key)

    @staticmethod
    def _key(entity_type: str, source_key) -> tuple[str, str]:
        return (entity_type, str(source_key))

    def resolve(self, entity_type: str, source_key) -> int | None:
        """The Pointy pk a source record maps to (in-memory), or ``None``."""
        if source_key in (None, ""):
            return None
        return self._cache.get(self._key(entity_type, source_key))

    # FK-only callers use this name for clarity; it returns the pk.
    resolve_pk = resolve

    def existing(self, model, entity_type: str, source_key):
        """The mapped model instance for re-run updates, or ``None``.

        Issues a query only on a re-run (when the key resolves); a first-ever
        import resolves to ``None`` in memory and never hits the database.
        """
        pk = self.resolve(entity_type, source_key)
        if pk is None:
            return None
        return model.objects.filter(pk=pk).first()

    def remember(self, entity_type: str, source_key, instance) -> None:
        """Record that a source record became ``instance``."""
        key = self._key(entity_type, source_key)
        previous = self._cache.get(key)
        self._cache[key] = instance.pk
        if self.dry_run:
            return
        if key not in self._persisted:
            MigrationIdentityMap.objects.create(
                source=self.source,
                entity_type=entity_type,
                source_key=key[1],
                target_content_type=self._content_type_for(type(instance)),
                target_object_id=instance.pk,
                first_run=self.run,
                last_seen_run=self.run,
            )
            self._persisted.add(key)
        elif previous != instance.pk:
            # The mapped row changed (it was deleted and re-created); repoint it.
            MigrationIdentityMap.objects.filter(
                source=self.source,
                entity_type=entity_type,
                source_key=key[1],
            ).update(target_object_id=instance.pk, last_seen_run=self.run)

    def _content_type_for(self, model) -> ContentType:
        content_type = self._content_types.get(model)
        if content_type is None:
            content_type = ContentType.objects.get_for_model(model)
            self._content_types[model] = content_type
        return content_type
