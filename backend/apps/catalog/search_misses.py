"""Searches that found nothing, and what the owner says they meant.

Recorded by the product and variant searches once every fallback has come up
empty (``search_filters``). The worklist (``SearchMissViewSet``) lists them by
how often they were typed; resolving one teaches the catalogue the word as an
alias of the product that was meant, so the next search finds it.
"""

from __future__ import annotations

from django.db import IntegrityError, transaction
from django.db.models import Case, F, Value, When
from django.utils import timezone
from rest_framework import mixins, serializers, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.permissions import HasPointyPermission

from . import search_text
from .models import Product, ProductAlias, SearchMiss
from .search_terms import normalize_term

# Fewer letters than this, a miss is a keystroke, not a word.
MIN_RECORDED_LENGTH = 3
_MAX_LENGTH = SearchMiss._meta.get_field("normalized").max_length


def recordable_key(term) -> str | None:
    """The row a miss for ``term`` counts toward, or ``None`` if it is not
    worth recording: too short, no letters (a code or a barcode — the scan
    paths have their own unmatched lists), or a phone number, which is
    somebody's personal data typed into the wrong box."""
    if search_text.looks_like_phone(term):
        return None
    key = search_text.fold(term)[:_MAX_LENGTH].strip()
    if search_text.letter_count(key) < MIN_RECORDED_LENGTH:
        return None
    return key


def record_search_miss(term, *, surface=SearchMiss.Surface.OTHER):
    """Count one empty search for ``term``. Two small writes at most; a row
    that was resolved but misses again reopens (the alias was removed, or the
    product archived), while a dismissed one stays dismissed."""
    key = recordable_key(term)
    if key is None:
        return
    term = (term or "").strip()[: SearchMiss._meta.get_field("term").max_length]
    if surface not in SearchMiss.Surface.values:
        surface = SearchMiss.Surface.OTHER
    now = timezone.now()
    updates = {
        "count": F("count") + 1,
        "last_seen_at": now,
        "updated_at": now,
        "term": term,
        "surface": surface,
        "status": Case(
            When(status=SearchMiss.Status.RESOLVED, then=Value(SearchMiss.Status.OPEN)),
            default=F("status"),
        ),
    }
    if SearchMiss.objects.filter(normalized=key).update(**updates):
        return
    try:
        with transaction.atomic():
            SearchMiss.objects.create(
                term=term, normalized=key, surface=surface, last_seen_at=now
            )
    except IntegrityError:
        # Another till recorded the same word a moment ago.
        SearchMiss.objects.filter(normalized=key).update(**updates)


def _teach_alias(product, term):
    """Record ``term`` as a name of ``product``; the alias if this created one.

    Nothing to learn when the word already reads as the product's own name (it
    missed for another reason: the product was archived, or out of stock) or
    the product already has it as an alias.
    """
    normalized = normalize_term(term)
    if not normalized or normalized == normalize_term(product.name):
        return None
    alias, created = ProductAlias.objects.get_or_create(
        product=product,
        normalized=normalized,
        defaults={
            "alias": (term or "").strip()[:255],
            "source": ProductAlias.Source.MANUAL,
        },
    )
    return alias if created else None


class SearchMissSerializer(serializers.ModelSerializer):
    product_name = serializers.CharField(
        source="product.name", read_only=True, default=None
    )

    class Meta:
        model = SearchMiss
        fields = (
            "id",
            "term",
            "normalized",
            "surface",
            "count",
            "last_seen_at",
            "status",
            "product",
            "product_name",
            "resolved_at",
        )
        read_only_fields = fields


class SearchMissResolveSerializer(serializers.Serializer):
    product = serializers.PrimaryKeyRelatedField(
        queryset=Product.objects.filter(archived_at__isnull=True)
    )

    def validate_product(self, product):
        if product.is_system:
            raise serializers.ValidationError(
                "A product a feature owns keeps the names it was given.",
                code="system_product",
            )
        return product


class SearchMissViewSet(mixins.ListModelMixin, viewsets.GenericViewSet):
    """The owner's worklist of words the catalogue does not know yet.

    ``GET ?status=open|resolved|dismissed|all`` (default ``open``), most typed
    first. Teaching the catalogue a word is editing products, so every action
    asks for ``catalog.change_product``.
    """

    serializer_class = SearchMissSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("catalog.change_product",),
        "resolve": ("catalog.change_product",),
        "dismiss": ("catalog.change_product",),
        "reopen": ("catalog.change_product",),
    }
    filter_backends = ()

    def get_queryset(self):
        queryset = SearchMiss.objects.select_related("product")
        if self.action == "list":
            wanted = self.request.query_params.get("status") or SearchMiss.Status.OPEN
            if wanted != "all":
                queryset = queryset.filter(status=wanted)
        return queryset.order_by("-count", "-last_seen_at", "id")

    @action(detail=True, methods=["post"])
    def resolve(self, request, pk=None):
        miss = self.get_object()
        payload = SearchMissResolveSerializer(data=request.data)
        payload.is_valid(raise_exception=True)
        product = payload.validated_data["product"]
        with transaction.atomic():
            miss.alias = _teach_alias(product, miss.term)
            miss.status = SearchMiss.Status.RESOLVED
            miss.product = product
            miss.resolved_by = request.user
            miss.resolved_at = timezone.now()
            miss.save(
                update_fields=[
                    "status",
                    "product",
                    "alias",
                    "resolved_by",
                    "resolved_at",
                    "updated_at",
                ]
            )
        return Response(self.get_serializer(miss).data)

    @action(detail=True, methods=["post"])
    def dismiss(self, request, pk=None):
        miss = self.get_object()
        miss.status = SearchMiss.Status.DISMISSED
        miss.resolved_by = request.user
        miss.resolved_at = timezone.now()
        miss.save(update_fields=["status", "resolved_by", "resolved_at", "updated_at"])
        return Response(self.get_serializer(miss).data)

    @action(detail=True, methods=["post"])
    def reopen(self, request, pk=None):
        miss = self.get_object()
        with transaction.atomic():
            # Undo what resolving taught the catalogue — only the alias it
            # created, never one that was already there.
            if miss.alias_id is not None:
                ProductAlias.objects.filter(pk=miss.alias_id).delete()
            miss.status = SearchMiss.Status.OPEN
            miss.product = None
            miss.alias = None
            miss.resolved_by = None
            miss.resolved_at = None
            miss.save(
                update_fields=[
                    "status",
                    "product",
                    "alias",
                    "resolved_by",
                    "resolved_at",
                    "updated_at",
                ]
            )
        return Response(self.get_serializer(miss).data, status=status.HTTP_200_OK)
