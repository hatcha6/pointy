"""The identity resolver — idempotency and cross-entity FK resolution.

Wraps :class:`~apps.migration.models.MigrationIdentityMap` with an in-process
cache, tuned for large imports:

* **One preload query** loads every existing mapping for the source up front, so
  ``resolve``/``resolve_pk`` are pure in-memory lookups (no per-record query).
* ``remember`` queues a newly-seen source key and does **nothing** on a re-run
  (the mapping is stable), self-healing only if the target row's pk actually
  changed (e.g. the mapped row was deleted and re-created). The queue is
  written by ``flush`` inside the same batch transaction as its rows, so a
  committed row always has its mapping — re-runs never duplicate.

During a **dry run** nothing is persisted: ``remember`` only updates the
in-memory cache (the just-inserted rows live inside the about-to-be-rolled-back
transaction), so children still resolve their parents while the database is left
untouched.
"""

from __future__ import annotations

from django.contrib.contenttypes.models import ContentType

from .models import MigrationIdentityMap

_ABSENT = object()


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
        # (key, previous pk or _ABSENT, was persisted) per remember(), so a
        # record that fails can be forgotten again (``rollback_to``).
        self._journal: list[tuple[tuple[str, str], object, bool]] = []
        # New mappings not yet written: one INSERT per batch (``flush``), not
        # one per record. Keyed so a record remembered twice before a flush
        # writes its latest target.
        self._pending: dict[tuple[str, str], MigrationIdentityMap] = {}
        #: Set by the engine while a commit batch is open. Outside one a row
        #: commits on its own, so its mapping is written with it, at once.
        self.buffering = False
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

    def worker_view(self) -> IdentityResolver:
        """A resolver for one worker thread, sharing this one's map.

        The worker reads every key earlier entities resolved and adds its own;
        its undo journal and its unwritten mappings stay its own, because they
        belong to its connection's open batch.
        """
        view = IdentityResolver.__new__(IdentityResolver)
        view.source, view.run, view.dry_run = self.source, self.run, self.dry_run
        view._cache = self._cache
        view._persisted = self._persisted
        view._content_types = self._content_types
        view._journal, view._pending, view.buffering = [], {}, False
        return view

    def mark(self) -> int:
        """A point to come back to if the record about to load fails."""
        return len(self._journal)

    def rollback_to(self, mark: int) -> None:
        """Forget what was remembered since ``mark``: its rows were rolled back."""
        while len(self._journal) > mark:
            key, previous, was_persisted = self._journal.pop()
            if previous is _ABSENT:
                self._cache.pop(key, None)
            else:
                self._cache[key] = previous
            if not was_persisted:
                self._persisted.discard(key)
                self._pending.pop(key, None)
            elif key in self._pending:
                self._pending[key].target_object_id = previous

    def flush(self) -> None:
        """Write the mappings remembered since the last flush.

        Called inside the batch that wrote their rows, before it commits, so a
        committed row still always has its mapping.
        """
        if not self._pending:
            return
        MigrationIdentityMap.objects.bulk_create(list(self._pending.values()))
        self._pending.clear()

    def keep(self, mark: int) -> None:
        """The record since ``mark`` loaded: nothing of it to take back."""
        del self._journal[mark:]

    def remember(self, entity_type: str, source_key, instance) -> None:
        """Record that a source record became ``instance``."""
        key = self._key(entity_type, source_key)
        previous = self._cache.get(key)
        self._journal.append((key, self._cache.get(key, _ABSENT), key in self._persisted))
        self._cache[key] = instance.pk
        if self.dry_run:
            return
        if key not in self._persisted:
            self._pending[key] = MigrationIdentityMap(
                source=self.source,
                entity_type=entity_type,
                source_key=key[1],
                target_content_type=self._content_type_for(type(instance)),
                target_object_id=instance.pk,
                first_run=self.run,
                last_seen_run=self.run,
            )
            self._persisted.add(key)
            if not self.buffering:
                self.flush()
        elif key in self._pending:
            self._pending[key].target_object_id = instance.pk
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
