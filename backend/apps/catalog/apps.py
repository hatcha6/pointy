from django.apps import AppConfig


class CatalogConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.catalog"

    def ready(self):
        from django.db.backends.signals import connection_created

        from . import signals  # noqa: F401 — catalog-version bump receivers
        from .search_sql import register_sqlite_functions

        # The search functions are SQL on PostgreSQL (migration 0034); SQLite
        # gets their Python twins on every connection instead.
        connection_created.connect(
            register_sqlite_functions, dispatch_uid="catalog.search_sqlite_functions"
        )
