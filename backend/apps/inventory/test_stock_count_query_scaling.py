"""Query-cost regression tests for the stock-count read endpoints.

``reconciliation`` embeds the full ``ProductVariantSerializer`` as
``variant_detail`` (the finish screen renders the product name, unit and image),
but assembled its own prefetch list — a plausible-looking subset of the one
``ProductVariantViewSet`` uses — so every relation it omitted cost a query per
row: 15 of them, i.e. ~754 queries on a full 50-line page. And the session list
annotated ``counted_line_count`` but not ``variance_line_count``, so the
serializer's fallback fired a COUNT per row.

These tests keep both flat as the row count grows, and prove the prefetches
changed only *where* the payload comes from, never what it says.
"""

from decimal import Decimal
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.contrib.contenttypes.models import ContentType
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from django.utils import timezone
from rest_framework.request import Request
from rest_framework.test import APIClient, APIRequestFactory

from apps.attachments.models import Attachment, StorageVolume
from apps.catalog.models import (
    ModifierGroup,
    ModifierOption,
    Product,
    ProductCategory,
    ProductVariant,
    VariantOption,
    VariantOptionValue,
)
from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import StockCount, StockCountLine, StockItem
from .stock_count_serializers import (
    StockCountReconciliationLineSerializer,
    StockCountSerializer,
)


# ---------------------------------------------------------------------------
# Signed-URL normalisation
# ---------------------------------------------------------------------------
#
# ``AttachmentSummarySerializer.content_url`` appends ``?token=<signed>``, and
# ``django.core.signing.dumps`` embeds a base62 timestamp. This test serialises
# the same row twice; when the two calls straddle a second boundary the tokens
# differ and a naive dict comparison fails at random — which is exactly what it
# did in a full-suite run, with a diff whose only difference was
# ``1x08B9`` vs ``1x08BA``.
#
# Stripping the token keeps the assertion honest: the point being proved is that
# the prefetch did not change the payload, and a token that is *designed* to
# differ between two calls is not part of that claim. The caller separately
# asserts a token is present on both sides, so the field cannot silently vanish.


def _strip_content_token(url: str) -> str:
    parsed = urlsplit(url)
    kept = [
        (key, value)
        for key, value in parse_qsl(parsed.query, keep_blank_values=True)
        if key != "token"
    ]
    return urlunsplit(parsed._replace(query=urlencode(kept)))


def _without_content_tokens(payload):
    """A deep copy of ``payload`` with every ``content_url`` token removed."""
    if isinstance(payload, dict):
        return {
            key: (
                _strip_content_token(value)
                if key == "content_url" and isinstance(value, str)
                else _without_content_tokens(value)
            )
            for key, value in payload.items()
        }
    if isinstance(payload, (list, tuple)):
        return [_without_content_tokens(item) for item in payload]
    return payload


def _content_urls(payload):
    """Every ``content_url`` string anywhere in ``payload``."""
    found = []
    if isinstance(payload, dict):
        for key, value in payload.items():
            if key == "content_url" and isinstance(value, str):
                found.append(value)
            else:
                found.extend(_content_urls(value))
    elif isinstance(payload, (list, tuple)):
        for item in payload:
            found.extend(_content_urls(item))
    return found


class ContentTokenNormalisationTests(TestCase):
    """The normaliser must hide the rotating token and nothing else."""

    def test_two_payloads_differing_only_in_the_token_compare_equal(self):
        # The exact shape that failed a full-suite run: consecutive signing
        # timestamps on an otherwise identical payload.
        first = {"variant_detail": {"image": {"content_url": "/a/1/?token=1x08B9:aaa"}}}
        second = {"variant_detail": {"image": {"content_url": "/a/1/?token=1x08BA:bbb"}}}

        self.assertNotEqual(first, second)
        self.assertEqual(_without_content_tokens(first), _without_content_tokens(second))

    def test_a_real_difference_still_fails(self):
        # Stripping the token must not also mask the URL it is attached to.
        first = {"image": {"content_url": "/a/1/?token=x", "id": 1}}
        second = {"image": {"content_url": "/a/2/?token=x", "id": 1}}

        self.assertNotEqual(_without_content_tokens(first), _without_content_tokens(second))

    def test_other_query_parameters_survive(self):
        stripped = _strip_content_token("/a/1/?size=thumb&token=x&v=2")

        self.assertIn("size=thumb", stripped)
        self.assertIn("v=2", stripped)
        self.assertNotIn("token=", stripped)

    def test_content_urls_finds_them_at_any_depth(self):
        payload = {"rows": [{"a": {"content_url": "/x/?token=1"}}, {"b": 2}]}

        self.assertEqual(_content_urls(payload), ["/x/?token=1"])

@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class StockCountQueryScalingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(username="u", password="p")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.volume = StorageVolume.objects.create(name="vol", path="/tmp/vol")
        self.product_ct = ContentType.objects.get_for_model(Product)
        self.variant_ct = ContentType.objects.get_for_model(ProductVariant)
        self._seq = 0
        self.stock_count = self._new_count()

    def _new_count(self, **kwargs):
        return StockCount.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
            scope=StockCount.Scope.FULL,
            **kwargs,
        )

    def _add_image(self, content_type, object_id, path):
        Attachment.objects.create(
            owner_content_type=content_type,
            owner_object_id=object_id,
            role=Attachment.Role.PRODUCT_IMAGE,
            storage_volume=self.volume,
            relative_path=path,
            original_filename=path,
            original_size=10,
            stored_size=10,
            checksum_sha256="x",
            is_primary=True,
            created_by=self.user,
        )

    def _add_lines(self, count, stock_count=None, variance=True):
        """Each line = its own product/variant with the full tree the variant
        serializer walks (category, image, options, modifier group, stock)."""
        stock_count = stock_count or self.stock_count
        for _ in range(count):
            self._seq += 1
            i = self._seq
            category = ProductCategory.objects.create(name=f"cat{i}")
            group = ModifierGroup.objects.create(name=f"grp{i}")
            ModifierOption.objects.create(
                group=group, name=f"opt{i}", price_delta=Decimal("1")
            )
            product = Product.objects.create(name=f"p{i}", is_active=True)
            product.categories.add(category)
            product.modifier_groups.add(group)
            self._add_image(self.product_ct, product.id, f"p/{i}.jpg")
            option = VariantOption.objects.create(code=f"size{i}", name=f"size{i}")
            product.variant_options.add(option)
            option_value = VariantOptionValue.objects.create(
                option=option, code=f"L{i}", name=f"L{i}"
            )
            variant = ProductVariant.objects.create(
                product=product,
                name="",
                sku=f"S{i}",
                unit_price=Decimal("5"),
                is_active=True,
                is_default=True,
            )
            variant.option_values.add(option_value)
            self._add_image(self.variant_ct, variant.id, f"v/{i}.jpg")
            StockItem.objects.create(variant=variant, quantity_on_hand=Decimal("7"))
            StockCountLine.objects.create(
                stock_count=stock_count,
                variant=variant,
                counted_quantity=Decimal("5") if variance else Decimal("7"),
                expected_quantity=Decimal("7"),
                counted_by=self.user,
                counted_at=timezone.now(),
            )

    def _measure(self, url):
        # Warm the per-request caches (permissions, content types) so the
        # measured request reflects steady-state cost only.
        self.client.get(url)
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        return len(ctx.captured_queries), response

    def test_reconciliation_query_count_does_not_grow_with_lines(self):
        url = reverse("stock-count-reconciliation", args=[self.stock_count.pk])
        self._add_lines(3)
        small, _ = self._measure(url)
        self._add_lines(3)
        large, response = self._measure(url)
        self.assertEqual(response.data["count"], 6)
        self.assertEqual(
            small,
            large,
            f"reconciliation scaled with lines: {small} -> {large} queries (N+1)",
        )

    def test_reconciliation_payload_matches_an_unprefetched_serializer(self):
        """The prefetch changes where the payload comes from, not what it says."""
        self._add_lines(2)
        url = reverse("stock-count-reconciliation", args=[self.stock_count.pk])
        rows = {row["id"]: row for row in self.client.get(url).data["results"]}
        self.assertEqual(len(rows), 2)
        for line in StockCountLine.objects.filter(stock_count=self.stock_count):
            request = APIRequestFactory().get(url)
            request.user = self.user
            cold = StockCountReconciliationLineSerializer(
                StockCountLine.objects.get(pk=line.pk),
                context={"request": Request(request)},
            ).data
            self.assertEqual(
                _without_content_tokens(rows[line.pk]),
                _without_content_tokens(dict(cold)),
            )
            # The token is excluded from the comparison above, not from the
            # payload: both sides must still carry one.
            self._assert_content_tokens_present(rows[line.pk])
            self._assert_content_tokens_present(dict(cold))
            self.assertEqual(rows[line.pk]["variant_detail"]["sku"], line.variant.sku)

    def _assert_content_tokens_present(self, payload):
        urls = _content_urls(payload)
        self.assertTrue(urls, "payload carried no attachment content_url to check")
        for url in urls:
            self.assertIn("token=", url)

    def test_session_list_query_count_does_not_grow_with_rows(self):
        url = reverse("stock-count-list")
        self._add_lines(1)
        small, _ = self._measure(url)
        for _ in range(5):
            self._add_lines(
                1,
                stock_count=self._new_count(status=StockCount.Status.CANCELLED),
            )
        large, response = self._measure(url)
        self.assertEqual(response.data["count"], 6)
        self.assertEqual(
            small,
            large,
            f"stock-count-list scaled with rows: {small} -> {large} queries (N+1)",
        )

    def test_annotated_variance_count_matches_the_unannotated_fallback(self):
        """The annotation must reproduce the property's selection rule exactly."""
        self._add_lines(2, variance=True)
        self._add_lines(3, variance=False)
        url = reverse("stock-count-list")
        row = self.client.get(url).data["results"][0]
        cold = StockCountSerializer(
            StockCount.objects.get(pk=self.stock_count.pk)
        ).data
        self.assertEqual(row["variance_line_count"], cold["variance_line_count"])
        self.assertEqual(row["counted_line_count"], cold["counted_line_count"])
        self.assertEqual(row["variance_line_count"], 2)
        self.assertEqual(row["counted_line_count"], 5)
