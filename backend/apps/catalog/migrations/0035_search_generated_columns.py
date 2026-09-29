"""Store the folded names search matches against (see migration 0034).

Generated STORED columns: the database fills them on every insert and update
— through the ORM, a bulk import or a backup restore alike — so they cannot
drift from the name they are computed from. Old code never names them, so a
release still serving during a live update keeps working (expand-only). Each
table is rewritten once to fill the column; the catalogue tables are small
(tens of thousands of rows), so the lock lasts about a second.

The expressions import ``apps.catalog.search_sql``; those classes must stay
importable under that path for this migration to keep loading.
"""

import apps.catalog.search_sql
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("catalog", "0034_search_fold_functions"),
    ]

    operations = [
        migrations.AddField(
            model_name="product",
            name="search_name",
            field=models.GeneratedField(
                db_persist=True,
                expression=apps.catalog.search_sql.SearchFold("name"),
                output_field=models.TextField(),
            ),
        ),
        migrations.AddField(
            model_name="product",
            name="search_skeleton",
            field=models.GeneratedField(
                db_persist=True,
                expression=apps.catalog.search_sql.SearchSkeleton("name"),
                output_field=models.TextField(),
            ),
        ),
        migrations.AddField(
            model_name="productalias",
            name="search_alias",
            field=models.GeneratedField(
                db_persist=True,
                expression=apps.catalog.search_sql.SearchFold("alias"),
                output_field=models.TextField(),
            ),
        ),
        migrations.AddField(
            model_name="productvariant",
            name="search_name",
            field=models.GeneratedField(
                db_persist=True,
                expression=apps.catalog.search_sql.SearchFold("name"),
                output_field=models.TextField(),
            ),
        ),
    ]
