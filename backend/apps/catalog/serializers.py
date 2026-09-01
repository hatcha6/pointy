from decimal import Decimal

from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import IntegrityError, transaction
from rest_framework import serializers

from apps.attachments.models import Attachment
from apps.attachments.serializers import AttachmentSummarySerializer
from .identity import (
    BARCODE_FIELD,
    KIND_PAYLOAD,
    KIND_RACE,
    SKU_FIELD,
    TARGET_DEFAULT_VARIANT,
    TARGET_VARIANT,
    TARGET_VARIANTS,
    IdentityConflict,
    find_barcode_conflict,
    find_conflicts,
    find_sku_conflict,
)
from .models import (
    ModifierGroup,
    ModifierOption,
    Product,
    ProductCategory,
    ProductModifierGroup,
    ProductUnit,
    ProductUnitBarcode,
    ProductVariant,
    UnitOfMeasure,
    VariantOption,
    VariantOptionValue,
    normalize_barcode,
    normalize_sku,
    variant_option_signature,
    validate_variant_option_values,
)


def attachment_summaries(owner, *, role, context):
    attachments = owner_attachments(owner, role=role)
    return AttachmentSummarySerializer(
        attachments,
        many=True,
        context=context,
    ).data


def primary_attachment_summary(owner, *, role, context):
    attachments = owner_attachments(owner, role=role)
    primary = next((attachment for attachment in attachments if attachment.is_primary), None)
    if primary is None and attachments:
        primary = attachments[0]
    if primary is None:
        return None
    return AttachmentSummarySerializer(primary, context=context).data


def owner_attachments(owner, *, role):
    manager = getattr(owner, "attachments", None)
    cached = getattr(owner, "_prefetched_objects_cache", {}).get("attachments")
    if cached is not None:
        attachments = cached
    elif manager is not None:
        attachments = list(
            manager.active()
            .filter(role=role)
            .select_related("owner_content_type", "storage_volume", "created_by")
            .order_by("-is_primary", "-created_at", "-id")
        )
        return attachments
    else:
        return []
    return [
        attachment
        for attachment in attachments
        if attachment.role == role and attachment.status == Attachment.Status.ACTIVE
    ]


def raise_serializer_validation(error):
    if hasattr(error, "message_dict"):
        raise serializers.ValidationError(error.message_dict)
    raise serializers.ValidationError(error.messages)


def raise_identity_conflicts(conflicts):
    """Turn duplicate SKU/barcode findings into one per-field 400.

    The detail carries both shapes on purpose: ``{"barcode": [message]}`` (and
    ``{"variants": [{}, {"sku": [...]}]}`` for a generated-variant payload) so
    any DRF client renders something sensible, plus a flat ``conflicts`` list
    the app parses to mark the exact input and name the owning product. DRF runs
    every leaf of the detail through ``force_str``, so the conflict payload is
    stringified deliberately rather than accidentally.
    """
    conflicts = [conflict for conflict in conflicts if conflict is not None]
    if not conflicts:
        return

    detail = {"conflicts": [conflict.as_payload(stringify=True) for conflict in conflicts]}
    variant_rows: dict[int, dict] = {}
    for conflict in conflicts:
        if conflict.target == TARGET_VARIANTS and conflict.index is not None:
            row = variant_rows.setdefault(conflict.index, {})
            row.setdefault(conflict.field, []).append(conflict.message)
        elif conflict.target == TARGET_DEFAULT_VARIANT:
            nested_detail = detail.setdefault(TARGET_DEFAULT_VARIANT, {})
            nested_detail.setdefault(conflict.field, []).append(conflict.message)
        else:
            detail.setdefault(conflict.field, []).append(conflict.message)

    if variant_rows:
        size = max(variant_rows) + 1
        detail[TARGET_VARIANTS] = [variant_rows.get(index, {}) for index in range(size)]

    raise serializers.ValidationError(detail)


def raise_identity_conflict_for_integrity_error(error, *, target):
    """Backstop for the unique index firing after a clean pre-flight check.

    Two cashiers can claim the same barcode in the same second, and a payload
    that moves a code between two of a product's own variants is applied row by
    row. Neither should reach the client as a 500.
    """
    text = str(error).lower()
    if BARCODE_FIELD in text:
        field = BARCODE_FIELD
    elif SKU_FIELD in text:
        field = SKU_FIELD
    else:
        return False
    raise_identity_conflicts(
        [IdentityConflict(field=field, value="", kind=KIND_RACE).at(target)]
    )
    return True


def _normalized_identity(field, value):
    if field == SKU_FIELD:
        return normalize_sku(value)
    return normalize_barcode(value)


def variant_identity_conflicts(data, *, exclude_variant_ids=(), target, index=None):
    """Conflicts for one variant payload's SKU and barcode."""
    conflicts = []
    if SKU_FIELD in data:
        conflict = find_sku_conflict(
            data.get(SKU_FIELD) or "",
            exclude_variant_ids=exclude_variant_ids,
        )
        if conflict is not None:
            conflicts.append(conflict.at(target, index))
    if BARCODE_FIELD in data:
        conflict = find_barcode_conflict(
            data.get(BARCODE_FIELD) or "",
            exclude_variant_ids=exclude_variant_ids,
        )
        if conflict is not None:
            conflicts.append(conflict.at(target, index))
    return conflicts


class ProductCategorySerializer(serializers.ModelSerializer):
    parent_name = serializers.CharField(source="parent.name", read_only=True)
    children_count = serializers.IntegerField(read_only=True)
    product_count = serializers.IntegerField(read_only=True)

    class Meta:
        model = ProductCategory
        fields = [
            "id",
            "name",
            "description",
            "parent",
            "parent_name",
            "children_count",
            "product_count",
            "is_active",
            "is_quick_access",
            "display_order",
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "created_at",
            "updated_at",
            "children_count",
            "product_count",
        )

    def validate_name(self, value):
        return value.strip()

    def validate(self, attrs):
        parent = attrs.get("parent", getattr(self.instance, "parent", None))
        name = attrs.get("name", getattr(self.instance, "name", "")).strip()
        if self.instance is not None and parent is not None:
            if parent.pk == self.instance.pk:
                raise serializers.ValidationError(
                    {"parent": "A category cannot be its own parent."}
                )
            ancestor = parent.parent
            while ancestor is not None:
                if ancestor.pk == self.instance.pk:
                    raise serializers.ValidationError(
                        {"parent": "A category cannot be moved under its descendant."}
                    )
                ancestor = ancestor.parent

        sibling_queryset = ProductCategory.objects.filter(parent=parent, name=name)
        if self.instance is not None:
            sibling_queryset = sibling_queryset.exclude(pk=self.instance.pk)
        if sibling_queryset.exists():
            raise serializers.ValidationError(
                {"name": "A category with this name already exists at this level."}
            )
        attrs["name"] = name
        return attrs


class VariantOptionValueSerializer(serializers.ModelSerializer):
    option_name = serializers.CharField(source="option.name", read_only=True)

    class Meta:
        model = VariantOptionValue
        fields = [
            "id",
            "option",
            "option_name",
            "code",
            "name",
            "display_order",
            "is_active",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at")

    def validate_code(self, value):
        return value.strip().lower()

    def validate_name(self, value):
        return value.strip()


class VariantOptionSerializer(serializers.ModelSerializer):
    values = VariantOptionValueSerializer(many=True, read_only=True)

    class Meta:
        model = VariantOption
        fields = [
            "id",
            "code",
            "name",
            "display_order",
            "is_active",
            "values",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at")

    def validate_code(self, value):
        return value.strip().lower()

    def validate_name(self, value):
        return value.strip()


class ModifierOptionSerializer(serializers.ModelSerializer):
    id = serializers.IntegerField(required=False)

    class Meta:
        model = ModifierOption
        fields = [
            "id",
            "name",
            "price_delta",
            "max_quantity",
            "is_default",
            "display_order",
            "is_active",
        ]


class ModifierGroupSerializer(serializers.ModelSerializer):
    options = ModifierOptionSerializer(many=True)

    class Meta:
        model = ModifierGroup
        fields = [
            "id",
            "name",
            "min_select",
            "max_select",
            "display_order",
            "is_active",
            "options",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at")

    def validate(self, attrs):
        min_select = attrs.get(
            "min_select",
            getattr(self.instance, "min_select", 0),
        )
        max_select = attrs.get(
            "max_select",
            getattr(self.instance, "max_select", 1),
        )
        if max_select is not None and max_select < max(min_select, 1):
            raise serializers.ValidationError(
                {"max_select": "Max selectable must be at least the minimum (and at least 1)."}
            )
        return attrs

    @transaction.atomic
    def create(self, validated_data):
        options = validated_data.pop("options", [])
        group = ModifierGroup.objects.create(**validated_data)
        self._sync_options(group, options)
        return group

    @transaction.atomic
    def update(self, instance, validated_data):
        options = validated_data.pop("options", None)
        for field, value in validated_data.items():
            setattr(instance, field, value)
        instance.save()
        if options is not None:
            self._sync_options(instance, options)
        return instance

    def _sync_options(self, group, options_data):
        kept_ids = []
        for index, data in enumerate(options_data):
            fields = {
                "name": data["name"],
                "price_delta": data.get("price_delta", Decimal("0.00")),
                "max_quantity": data.get("max_quantity", 1),
                "is_default": data.get("is_default", False),
                "display_order": data.get("display_order", index),
                "is_active": data.get("is_active", True),
            }
            option_id = data.get("id")
            if option_id and group.options.filter(pk=option_id).exists():
                group.options.filter(pk=option_id).update(**fields)
                kept_ids.append(option_id)
            else:
                created = group.options.create(**fields)
                kept_ids.append(created.id)
        # Options dropped from the payload are removed; SET_NULL keeps historical
        # OrderLineModifier snapshots intact.
        group.options.exclude(id__in=kept_ids).delete()


def product_modifier_group_details(product, context=None):
    """Resolved modifier groups for a product, in the per-product order."""
    # Reuse the prefetched links when the caller prefetched
    # "modifier_group_links__group__options" (list serializers do) so the catalog
    # list doesn't fire a modifier query per product; sort in Python to match the
    # stored order. Fall back to a scoped query for un-prefetched single instances.
    if "modifier_group_links" in getattr(product, "_prefetched_objects_cache", {}):
        links = sorted(
            product.modifier_group_links.all(),
            key=lambda link: (link.display_order, link.id),
        )
    else:
        links = (
            product.modifier_group_links.select_related("group")
            .prefetch_related("group__options")
            .order_by("display_order", "id")
        )
    return ModifierGroupSerializer(
        [link.group for link in links],
        many=True,
        context=context,
    ).data


class UnitOfMeasureSerializer(serializers.ModelSerializer):
    # How many products use this unit — surfaced so the management UI can show
    # usage and explain why an in-use unit cannot be deleted.
    product_count = serializers.SerializerMethodField()

    class Meta:
        model = UnitOfMeasure
        fields = [
            "id",
            "code",
            "name",
            "abbreviation",
            "dimension",
            "reference_factor",
            "allows_fractional",
            "is_system",
            "is_active",
            "display_order",
            "product_count",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at", "is_system")

    def get_product_count(self, unit):
        annotated = getattr(unit, "product_count", None)
        if annotated is not None:
            return annotated
        return unit.product_units.count()

    def validate_code(self, value):
        return value.strip().lower()


class ProductUnitSerializer(serializers.ModelSerializer):
    # Referenced by code so the frontend never juggles UnitOfMeasure ids.
    unit = serializers.SlugRelatedField(
        slug_field="code",
        queryset=UnitOfMeasure.objects.active(),
    )
    unit_detail = UnitOfMeasureSerializer(source="unit", read_only=True)
    # Packaging barcodes for this unit (the carton EAN). Scanning one rings up
    # this unit instead of one base unit. Omitting the key on write keeps the
    # stored barcodes; sending a list replaces them. Write-only because the
    # model field is a reverse relation — reads are filled in by
    # ``to_representation`` as a plain list of strings.
    barcodes = serializers.ListField(
        child=serializers.CharField(max_length=64, allow_blank=False),
        required=False,
        write_only=True,
    )

    class Meta:
        model = ProductUnit
        fields = [
            "id",
            "unit",
            "unit_detail",
            "factor_to_base",
            # Base currency, like every other stored price.
            "price",
            # The frozen foreign price for a pack priced per box rather than
            # per piece; read-only for the same reason as the variant's.
            "price_amount",
            "price_rate",
            "price_rate_at",
            "is_sellable",
            "is_purchasable",
            "display_order",
            "barcodes",
        ]
        read_only_fields = ("price_rate", "price_rate_at")

    def to_representation(self, instance):
        data = super().to_representation(instance)
        data["barcodes"] = [entry.barcode for entry in instance.barcodes.all()]
        return data

    def validate_barcodes(self, value):
        cleaned: list[str] = []
        for code in value:
            code = normalize_barcode(code)
            if code and code not in cleaned:
                cleaned.append(code)
        return cleaned


class ProductUnitListField(serializers.Field):
    """Read+write the per-product unit list inline on the product, mirroring
    ``ProductVariantListField``."""

    def to_representation(self, value):
        units = value.all() if hasattr(value, "all") else value
        return ProductUnitSerializer(units, many=True, context=self.context).data

    def to_internal_value(self, data):
        if not isinstance(data, list):
            raise serializers.ValidationError("Expected a list of units.")
        serializer = ProductUnitSerializer(data=data, many=True, context=self.context)
        serializer.is_valid(raise_exception=True)
        validated = serializer.validated_data
        codes = [entry["unit"].code for entry in validated]
        duplicates = sorted({code for code in codes if codes.count(code) > 1})
        if duplicates:
            raise serializers.ValidationError(
                f"Each unit can be listed once. Duplicated: {', '.join(duplicates)}."
            )
        return validated


class ProductCatalogSummarySerializer(serializers.ModelSerializer):
    variant_options = serializers.PrimaryKeyRelatedField(many=True, read_only=True)
    variant_option_details = VariantOptionSerializer(
        source="variant_options",
        many=True,
        read_only=True,
    )
    category_details = ProductCategorySerializer(
        source="categories",
        many=True,
        read_only=True,
    )
    primary_image = serializers.SerializerMethodField()
    image_attachments = serializers.SerializerMethodField()
    modifier_group_details = serializers.SerializerMethodField()
    units = serializers.SerializerMethodField()
    is_archived = serializers.BooleanField(read_only=True)

    class Meta:
        model = Product
        fields = [
            "id",
            "name",
            "description",
            "is_active",
            "is_archived",
            "archived_at",
            "tracks_expiry",
            "is_service",
            "is_prepared",
            "unit",
            # The currency this product's price sheet is written in. NULL (the
            # default, and every existing product) means the shop's own.
            "pricing_currency",
            "default_sale_unit",
            "default_purchase_unit",
            "units",
            "categories",
            "category_details",
            "variant_options",
            "variant_option_details",
            "modifier_group_details",
            "primary_image",
            "image_attachments",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at", "archived_at")

    def get_primary_image(self, product):
        return primary_attachment_summary(
            product,
            role=Attachment.Role.PRODUCT_IMAGE,
            context=self.context,
        )

    def get_image_attachments(self, product):
        return attachment_summaries(
            product,
            role=Attachment.Role.PRODUCT_IMAGE,
            context=self.context,
        )

    def get_modifier_group_details(self, product):
        return product_modifier_group_details(product, self.context)

    def get_units(self, product):
        return ProductUnitSerializer(
            product.units.all(),
            many=True,
            context=self.context,
        ).data


class DefaultProductVariantInputSerializer(serializers.Serializer):
    name = serializers.CharField(
        required=False,
        allow_blank=True,
        trim_whitespace=True,
        default="",
    )
    sku = serializers.CharField(required=False, allow_blank=False, trim_whitespace=True)
    barcode = serializers.CharField(
        required=False,
        allow_blank=True,
        trim_whitespace=True,
        default="",
    )
    unit_price = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        required=False,
        min_value=0,
    )
    # The price as written in the product's own pricing currency. When present
    # it DERIVES ``unit_price`` (see ``_derive_base_price``) rather than sitting
    # beside it, so a client never has to send both and cannot send two numbers
    # that disagree.
    price_amount = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        required=False,
        allow_null=True,
        min_value=0,
    )
    is_active = serializers.BooleanField(required=False)
    option_values = serializers.PrimaryKeyRelatedField(
        queryset=VariantOptionValue.objects.all(),
        many=True,
        required=False,
    )

    def validate_sku(self, value):
        return value.strip().upper()

    def validate_barcode(self, value):
        return value.strip()


class DefaultProductVariantField(serializers.Field):
    def to_representation(self, value):
        if value is None:
            return None
        # catalog_list drops the redundant per-variant product_detail (the parent
        # product is the list item itself). See ProductVariantSerializer.__init__.
        context = {**self.context, "catalog_list": True}
        return ProductVariantSerializer(value, context=context).data

    def to_internal_value(self, data):
        if not isinstance(data, dict):
            raise serializers.ValidationError("Expected an object.")
        serializer = DefaultProductVariantInputSerializer(
            data=data,
            context=self.context,
        )
        serializer.is_valid(raise_exception=True)
        return serializer.validated_data


def _derive_base_price(target, foreign_amount):
    """Turn a written foreign price into this row's stored base price.

    Called after the row exists so the product (and therefore its pricing
    currency) is resolvable. A ``None`` amount means the client did not touch the
    foreign price and the base price it sent stands; a product with no pricing
    currency is left entirely alone, which is every product that existed before
    multi-currency.

    Returning quietly when no rate resolves is deliberate: the foreign number is
    still recorded, so the row reprices itself the moment a rate arrives, and the
    price on the shelf until then is the last one somebody agreed to.
    """
    if foreign_amount is None:
        return
    from apps.catalog.pricing import set_foreign_price

    set_foreign_price(target, foreign_amount)


class ProductVariantSerializer(serializers.ModelSerializer):
    product = serializers.PrimaryKeyRelatedField(
        queryset=Product.objects.all(),
        required=False,
    )
    # Uniqueness is checked in validate() instead of by the model-derived
    # UniqueValidator: DRF's stock message ("product variant with this barcode
    # already exists") never says which product owns the code, and the client
    # needs the structured conflict to mark the right input.
    sku = serializers.CharField(max_length=64, validators=[])
    barcode = serializers.CharField(
        max_length=64,
        required=False,
        allow_blank=True,
        validators=[],
    )
    product_name = serializers.CharField(source="product.name", read_only=True)
    product_detail = ProductCatalogSummarySerializer(source="product", read_only=True)
    tracks_expiry = serializers.BooleanField(
        source="product.tracks_expiry",
        read_only=True,
    )
    is_service = serializers.BooleanField(source="product.is_service", read_only=True)
    is_prepared = serializers.BooleanField(
        source="product.is_prepared",
        read_only=True,
    )
    unit = serializers.CharField(source="product.unit", read_only=True)
    display_name = serializers.CharField(read_only=True)
    full_name = serializers.CharField(read_only=True)
    quantity_on_hand = serializers.FloatField(read_only=True)
    option_values = serializers.PrimaryKeyRelatedField(
        queryset=VariantOptionValue.objects.all(),
        many=True,
        required=False,
    )
    option_value_details = VariantOptionValueSerializer(
        source="option_values",
        many=True,
        read_only=True,
    )
    primary_image = serializers.SerializerMethodField()
    image_attachments = serializers.SerializerMethodField()

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Inside the catalog list/detail the parent product IS the surrounding
        # object, so serializing a full product_detail copy onto every variant is
        # pure redundancy — a product with N variants ships its data N+1×, which
        # dominated the response size. Drop it there; the client re-attaches the
        # parent. The standalone /product-variants/ endpoint keeps product_detail.
        if self.context.get("catalog_list"):
            self.fields.pop("product_detail", None)
        # The POS catalog card shows only the primary image; the full
        # image_attachments gallery is re-fetched with the product on open. Drop
        # it from the (heavily paged, per-variant) catalog LIST payload.
        if self.context.get("catalog_summary"):
            self.fields.pop("image_attachments", None)

    class Meta:
        model = ProductVariant
        fields = [
            "id",
            "product",
            "product_name",
            "product_detail",
            "name",
            "display_name",
            "full_name",
            "sku",
            "barcode",
            # Always the shop's base currency — see ProductVariant.unit_price.
            "unit_price",
            # The foreign price this row is maintained in, and the frozen rate
            # that produced ``unit_price`` from it. Read-only: a price is set by
            # writing ``price_amount``, which derives the base price through
            # apps.catalog.pricing rather than letting a client post both and
            # have them disagree.
            "price_amount",
            "price_rate",
            "price_rate_at",
            "is_active",
            "tracks_expiry",
            "is_service",
            "is_prepared",
            "unit",
            "is_default",
            "option_values",
            "option_value_details",
            "primary_image",
            "image_attachments",
            "quantity_on_hand",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at", "price_rate", "price_rate_at")

    def validate_unit_price(self, value):
        if value < 0:
            raise serializers.ValidationError("Unit price cannot be negative.")
        return value

    def get_primary_image(self, variant):
        return primary_attachment_summary(
            variant,
            role=Attachment.Role.PRODUCT_IMAGE,
            context=self.context,
        )

    def get_image_attachments(self, variant):
        return attachment_summaries(
            variant,
            role=Attachment.Role.PRODUCT_IMAGE,
            context=self.context,
        )

    def validate_sku(self, value):
        return value.strip().upper()

    def validate_barcode(self, value):
        return value.strip()

    def validate(self, attrs):
        scoped_product = self.context.get("product")
        product = attrs.get("product", getattr(self.instance, "product", None))
        if scoped_product is not None:
            if product is not None and product.pk != scoped_product.pk:
                raise serializers.ValidationError(
                    {"product": "Variant does not belong to the selected product."}
                )
            product = scoped_product
        if product is None:
            raise serializers.ValidationError({"product": "Product is required."})
        attrs["product"] = product

        if "option_values" in attrs:
            option_values = attrs["option_values"]
        elif self.instance is not None:
            option_values = list(self.instance.option_values.select_related("option"))
        else:
            option_values = []

        try:
            validate_variant_option_values(product, option_values, variant=self.instance)
        except DjangoValidationError as error:
            raise_serializer_validation(error)

        raise_identity_conflicts(
            variant_identity_conflicts(
                attrs,
                exclude_variant_ids=[getattr(self.instance, "pk", None)],
                target=TARGET_VARIANT,
            )
        )
        return attrs

    def create(self, validated_data):
        option_values = validated_data.pop("option_values", [])
        try:
            with transaction.atomic():
                if validated_data.get("is_default"):
                    ProductVariant.objects.filter(
                        product=validated_data["product"],
                        is_default=True,
                    ).update(is_default=False)
                foreign_amount = validated_data.pop("price_amount", None)
                variant = ProductVariant.objects.create(**validated_data)
                _derive_base_price(variant, foreign_amount)
                if option_values:
                    variant.option_values.set(option_values)
                    variant.refresh_from_db(fields=["option_signature"])
                return variant
        except DjangoValidationError as error:
            raise_serializer_validation(error)
        except IntegrityError as error:
            if not raise_identity_conflict_for_integrity_error(
                error,
                target=TARGET_VARIANT,
            ):
                raise

    def update(self, instance, validated_data):
        option_values = validated_data.pop("option_values", None)
        try:
            with transaction.atomic():
                if validated_data.get("is_default") is True:
                    ProductVariant.objects.filter(
                        product=instance.product,
                        is_default=True,
                    ).exclude(pk=instance.pk).update(is_default=False)
                foreign_amount = validated_data.pop("price_amount", None)
                for field, value in validated_data.items():
                    setattr(instance, field, value)
                instance.save()
                _derive_base_price(instance, foreign_amount)
                if option_values is not None:
                    instance.option_values.set(option_values)
                    instance.refresh_from_db(fields=["option_signature"])
                return instance
        except DjangoValidationError as error:
            raise_serializer_validation(error)
        except IntegrityError as error:
            if not raise_identity_conflict_for_integrity_error(
                error,
                target=TARGET_VARIANT,
            ):
                raise


class ProductVariantInputSerializer(serializers.Serializer):
    id = serializers.IntegerField(required=False)
    name = serializers.CharField(
        required=False,
        allow_blank=True,
        trim_whitespace=True,
        default="",
    )
    sku = serializers.CharField(required=True, allow_blank=False, trim_whitespace=True)
    barcode = serializers.CharField(
        required=False,
        allow_blank=True,
        trim_whitespace=True,
        default="",
    )
    unit_price = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        required=True,
        min_value=0,
    )
    # The price as written in the product's own pricing currency. When present
    # it DERIVES ``unit_price`` (see ``_derive_base_price``) rather than sitting
    # beside it, so a client never has to send both and cannot send two numbers
    # that disagree.
    price_amount = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        required=False,
        allow_null=True,
        min_value=0,
    )
    is_active = serializers.BooleanField(required=False, default=True)
    is_default = serializers.BooleanField(required=False, default=False)
    option_values = serializers.PrimaryKeyRelatedField(
        queryset=VariantOptionValue.objects.select_related("option"),
        many=True,
        required=False,
    )

    def validate_sku(self, value):
        return value.strip().upper()

    def validate_barcode(self, value):
        return value.strip()


class ProductVariantListField(serializers.Field):
    def to_representation(self, value):
        queryset = value.all() if hasattr(value, "all") else value
        # catalog_list drops the redundant per-variant product_detail (a product
        # with N variants would otherwise ship its full data N+1×). The client
        # re-attaches the parent it was listed under.
        context = {**self.context, "catalog_list": True}
        return ProductVariantSerializer(
            queryset,
            many=True,
            context=context,
        ).data

    def to_internal_value(self, data):
        if not isinstance(data, list):
            raise serializers.ValidationError("Expected a list.")
        serializer = ProductVariantInputSerializer(
            data=data,
            many=True,
            context=self.context,
        )
        serializer.is_valid(raise_exception=True)
        return serializer.validated_data


class ProductCatalogSerializer(serializers.ModelSerializer):
    quantity_on_hand = serializers.SerializerMethodField()
    variants = ProductVariantListField(required=False)
    default_variant = DefaultProductVariantField(required=False)
    units = ProductUnitListField(required=False)
    categories = serializers.PrimaryKeyRelatedField(
        queryset=ProductCategory.objects.all(),
        many=True,
        required=False,
    )
    category_details = ProductCategorySerializer(
        source="categories",
        many=True,
        read_only=True,
    )
    variant_options = serializers.PrimaryKeyRelatedField(
        queryset=VariantOption.objects.all(),
        many=True,
        required=False,
    )
    variant_option_details = VariantOptionSerializer(
        source="variant_options",
        many=True,
        read_only=True,
    )
    modifier_groups = serializers.PrimaryKeyRelatedField(
        queryset=ModifierGroup.objects.all(),
        many=True,
        required=False,
    )
    modifier_group_details = serializers.SerializerMethodField()
    primary_image = serializers.SerializerMethodField()
    image_attachments = serializers.SerializerMethodField()
    is_archived = serializers.BooleanField(read_only=True)

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Catalog LIST rows show only the primary image; the full
        # image_attachments gallery is re-fetched with the product on open, so
        # drop it (and each nested variant's — see ProductVariantSerializer) from
        # the paged list payload. The retrieve/detail action leaves it in.
        if self.context.get("catalog_summary"):
            self.fields.pop("image_attachments", None)

    class Meta:
        model = Product
        fields = [
            "id",
            "name",
            "description",
            "is_active",
            "is_archived",
            "archived_at",
            "tracks_expiry",
            "is_service",
            "is_prepared",
            "unit",
            # The currency this product's price sheet is written in. NULL (the
            # default, and every existing product) means the shop's own.
            "pricing_currency",
            "default_sale_unit",
            "default_purchase_unit",
            "units",
            "default_variant",
            "variants",
            "categories",
            "category_details",
            "variant_options",
            "variant_option_details",
            "modifier_groups",
            "modifier_group_details",
            "primary_image",
            "image_attachments",
            "quantity_on_hand",
            # Denormalized "most bought" score (recomputed nightly). Exposed so the
            # client can sort/label by demand; it never accepts a written value.
            "popularity",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at", "archived_at", "popularity")

    def validate_unit(self, value):
        value = (value or "").strip()
        if value and not UnitOfMeasure.objects.filter(code=value, is_active=True).exists():
            raise serializers.ValidationError(f"Unknown base unit '{value}'.")
        return value

    def validate(self, attrs):
        base_unit = attrs.get("unit") or getattr(self.instance, "unit", None) or "piece"
        units_payload = attrs.get("units")
        if units_payload is not None:
            available = {entry["unit"].code for entry in units_payload}
        elif self.instance is not None:
            available = {
                product_unit.unit.code for product_unit in self.instance.units.all()
            }
        else:
            available = set()
        available.add(base_unit)
        for field in ("default_sale_unit", "default_purchase_unit"):
            if field in attrs:
                code = attrs[field]
            elif self.instance is not None:
                code = getattr(self.instance, field, "")
            else:
                code = ""
            if code and code not in available:
                raise serializers.ValidationError(
                    {field: "Default must be the base unit or one of the product's units."}
                )
        raise_identity_conflicts(self._identity_conflicts(attrs))
        return attrs

    def _identity_conflicts(self, attrs):
        """Duplicate SKUs/barcodes anywhere in a product write.

        Checked here rather than left to the unique index so the response names
        the offending field, the offending row, and the product that already
        owns the code — a duplicate barcode used to surface as a 500.
        """
        variants_data = attrs.get("variants")
        # create()/update() apply "variants" *or* "default_variant", never both.
        default_variant_data = None if variants_data is not None else attrs.get("default_variant")

        # Every variant this request rewrites is excluded from the "already
        # taken" lookup: the payload describes the state after the write, so a
        # code that moves between rows of the same product is not a clash.
        excluded_ids = [data.get("id") for data in (variants_data or []) if data.get("id")]
        if default_variant_data is not None and self.instance is not None:
            # ensure_default_variant() writes the default variant, falling back
            # to the oldest one — the same row this payload will overwrite.
            existing_default = (
                self.instance.default_variant
                or self.instance.variants.order_by("id").first()
            )
            if existing_default is not None:
                excluded_ids.append(existing_default.pk)

        # Every code in the payload paired with where it sits, so the whole
        # request resolves in one batched lookup instead of two queries a row.
        entries = [
            (TARGET_VARIANTS, index, field, value)
            for index, data in enumerate(variants_data or [])
            for field in (SKU_FIELD, BARCODE_FIELD)
            if (value := _normalized_identity(field, data.get(field)))
        ]
        if default_variant_data is not None:
            entries.extend(
                (TARGET_DEFAULT_VARIANT, None, field, value)
                for field in (SKU_FIELD, BARCODE_FIELD)
                if (value := _normalized_identity(field, default_variant_data.get(field)))
            )

        taken = find_conflicts(
            skus=[value for _, _, field, value in entries if field == SKU_FIELD],
            barcodes=[
                value for _, _, field, value in entries if field == BARCODE_FIELD
            ],
            exclude_variant_ids=excluded_ids,
        )

        conflicts = []
        seen: dict[tuple[str, str], int] = {}
        for target, index, field, value in entries:
            if (field, value) in seen:
                conflicts.append(
                    IdentityConflict(
                        field=field,
                        value=value,
                        kind=KIND_PAYLOAD,
                    ).at(target, index)
                )
                continue
            seen[(field, value)] = index
            conflict = taken.get((field, value))
            if conflict is not None:
                conflicts.append(conflict.at(target, index))

        # A code that resolves to both a variant and a packaging unit is
        # ambiguous at the scanner, so the two lists in one payload must not
        # overlap either (the DB half of this lives in _validate_unit_barcodes).
        unit_barcodes = {
            normalize_barcode(code)
            for data in (attrs.get("units") or [])
            for code in (data.get("barcodes") or [])
        }
        for target, index, field, value in entries:
            if field == BARCODE_FIELD and value in unit_barcodes:
                conflicts.append(
                    IdentityConflict(
                        field=field,
                        value=value,
                        kind=KIND_PAYLOAD,
                    ).at(target, index)
                )
        return conflicts

    def get_quantity_on_hand(self, product):
        annotated_quantity = getattr(product, "stock_quantity_on_hand", None)
        if annotated_quantity is not None:
            return annotated_quantity
        return product.quantity_on_hand

    def get_primary_image(self, product):
        return primary_attachment_summary(
            product,
            role=Attachment.Role.PRODUCT_IMAGE,
            context=self.context,
        )

    def get_image_attachments(self, product):
        return attachment_summaries(
            product,
            role=Attachment.Role.PRODUCT_IMAGE,
            context=self.context,
        )

    def get_modifier_group_details(self, product):
        return product_modifier_group_details(product, self.context)

    def _sync_modifier_groups(self, product, groups):
        # modifier_groups uses a through model (ProductModifierGroup) so the
        # per-product order is preserved; rebuild the links in payload order.
        product.modifier_group_links.all().delete()
        for index, group in enumerate(groups):
            ProductModifierGroup.objects.create(
                product=product,
                group=group,
                display_order=index,
            )

    def _apply_units_data(self, product, units_data):
        # Rebuild the per-product unit list. Transaction lines snapshot the unit
        # code + factor, so dropping/recreating ProductUnit rows never rewrites
        # history. A row matching the base unit is dropped (the base is implicit).
        # Packaging barcodes survive the rebuild: a payload that omits the
        # "barcodes" key keeps the unit's stored codes (clients that predate unit
        # barcodes must not wipe them); sending a list replaces them.
        existing_barcodes = {
            product_unit.unit_id: [entry.barcode for entry in product_unit.barcodes.all()]
            for product_unit in product.units.all()
        }
        self._validate_unit_barcodes(product, units_data)
        product.units.all().delete()
        for index, data in enumerate(units_data):
            unit = data["unit"]
            if unit.code == product.unit:
                continue
            product_unit = ProductUnit.objects.create(
                product=product,
                unit=unit,
                factor_to_base=data["factor_to_base"],
                price=data.get("price"),
                is_sellable=data.get("is_sellable", True),
                is_purchasable=data.get("is_purchasable", True),
                display_order=data.get("display_order", index),
            )
            # A pack priced from a foreign price sheet derives its base price
            # the same way a variant does, rather than storing the foreign
            # number with nothing to sell at.
            _derive_base_price(product_unit, data.get("price_amount"))
            barcodes = data.get("barcodes")
            if barcodes is None:
                barcodes = existing_barcodes.get(unit.pk, [])
            ProductUnitBarcode.objects.bulk_create(
                ProductUnitBarcode(product_unit=product_unit, barcode=code)
                for code in barcodes
            )

    def _validate_unit_barcodes(self, product, units_data):
        # One code, one meaning: a unit barcode may not repeat across the payload,
        # collide with another product's unit barcodes, or shadow a variant
        # barcode (a code resolving to both a variant and a unit is ambiguous).
        codes: list[str] = []
        for data in units_data:
            codes.extend(data.get("barcodes") or [])
        duplicated = sorted({code for code in codes if codes.count(code) > 1})
        if duplicated:
            raise serializers.ValidationError(
                {"units": f"Barcodes repeated across units: {', '.join(duplicated)}."}
            )
        if not codes:
            return
        variant_clash = list(
            ProductVariant.objects.filter(barcode__in=codes).values_list("barcode", flat=True)
        )
        if variant_clash:
            raise serializers.ValidationError(
                {"units": f"Barcodes already used by products: {', '.join(sorted(variant_clash))}."}
            )
        unit_clash_query = ProductUnitBarcode.objects.filter(barcode__in=codes)
        if product.pk:
            unit_clash_query = unit_clash_query.exclude(product_unit__product=product)
        unit_clash = list(unit_clash_query.values_list("barcode", flat=True))
        if unit_clash:
            raise serializers.ValidationError(
                {"units": f"Barcodes already used by other units: {', '.join(sorted(unit_clash))}."}
            )

    def create(self, validated_data):
        categories = validated_data.pop("categories", [])
        variant_options = validated_data.pop("variant_options", None)
        modifier_groups = validated_data.pop("modifier_groups", None)
        units_data = validated_data.pop("units", None)
        variants_data = validated_data.pop("variants", None)
        default_variant_data = validated_data.pop("default_variant", None)
        variant_options = self._variant_options_for_payload(
            variant_options,
            variants_data,
            default_variant_data,
        )
        try:
            with transaction.atomic():
                product = Product.objects.create(**validated_data)
                if categories:
                    product.categories.set(categories)
                if variant_options is not None:
                    product.variant_options.set(variant_options)
                if modifier_groups is not None:
                    self._sync_modifier_groups(product, modifier_groups)
                if units_data is not None:
                    self._apply_units_data(product, units_data)
                if variants_data is not None:
                    self._apply_variants_data(product, variants_data)
                else:
                    self._apply_default_variant_data(product, default_variant_data)
                return product
        except DjangoValidationError as error:
            raise_serializer_validation(error)
        except IntegrityError as error:
            if not raise_identity_conflict_for_integrity_error(
                error,
                target=TARGET_VARIANTS,
            ):
                raise

    def update(self, instance, validated_data):
        categories = validated_data.pop("categories", None)
        variant_options = validated_data.pop("variant_options", None)
        modifier_groups = validated_data.pop("modifier_groups", None)
        units_data = validated_data.pop("units", None)
        variants_data = validated_data.pop("variants", None)
        default_variant_data = validated_data.pop("default_variant", None)
        variant_options = self._variant_options_for_payload(
            variant_options,
            variants_data,
            default_variant_data,
        )
        try:
            with transaction.atomic():
                for field, value in validated_data.items():
                    setattr(instance, field, value)
                instance.save()
                if categories is not None:
                    instance.categories.set(categories)
                if variant_options is not None:
                    instance.variant_options.set(variant_options)
                if modifier_groups is not None:
                    self._sync_modifier_groups(instance, modifier_groups)
                if units_data is not None:
                    self._apply_units_data(instance, units_data)
                if variants_data is not None:
                    self._apply_variants_data(instance, variants_data)
                else:
                    self._apply_default_variant_data(instance, default_variant_data)
                return instance
        except DjangoValidationError as error:
            raise_serializer_validation(error)
        except IntegrityError as error:
            if not raise_identity_conflict_for_integrity_error(
                error,
                target=TARGET_VARIANTS,
            ):
                raise

    def _variant_options_for_payload(
        self,
        variant_options,
        variants_data,
        default_variant_data,
    ):
        if variant_options is not None:
            return variant_options

        option_ids = []
        for variant_data in variants_data or []:
            for option_value in variant_data.get("option_values", []):
                option_ids.append(option_value.option_id)
        for option_value in (default_variant_data or {}).get("option_values", []):
            option_ids.append(option_value.option_id)

        if not option_ids:
            return None
        return list(
            VariantOption.objects.filter(pk__in=option_ids).order_by(
                "display_order",
                "name",
            )
        )

    def _apply_default_variant_data(self, product, default_variant_data):
        if default_variant_data is None:
            return
        variant_data = dict(default_variant_data)
        option_values = variant_data.pop("option_values", None)
        # ``ensure_default_variant`` writes the row directly rather than through
        # ProductVariantSerializer, so the foreign price has to be applied here
        # or a product created in one request would store the dollar figure and
        # never derive a dinar one.
        foreign_amount = variant_data.pop("price_amount", None)
        variant = product.ensure_default_variant(**variant_data)
        _derive_base_price(variant, foreign_amount)
        if option_values is not None:
            validate_variant_option_values(product, option_values, variant=variant)
            variant.option_values.set(option_values)

    def _apply_variants_data(self, product, variants_data):
        if not variants_data:
            return
        default_count = sum(1 for data in variants_data if data.get("is_default"))
        if default_count > 1:
            raise serializers.ValidationError(
                {"variants": "Only one variant can be marked as default."}
            )
        if default_count == 0 and not product.variants.filter(is_default=True).exists():
            variants_data[0]["is_default"] = True

        self._validate_variant_payload_combinations(variants_data)

        for variant_data in variants_data:
            self._upsert_product_variant(product, variant_data)

    def _validate_variant_payload_combinations(self, variants_data):
        signatures = set()
        for variant_data in variants_data:
            signature = variant_option_signature(
                variant_data.get("option_values", [])
            )
            if not signature:
                continue
            if signature in signatures:
                raise serializers.ValidationError(
                    {
                        "variants": (
                            "Generated variants cannot contain duplicate "
                            "option value combinations."
                        )
                    }
                )
            signatures.add(signature)

    def _upsert_product_variant(self, product, variant_data):
        data = dict(variant_data)
        variant_id = data.pop("id", None)
        option_values = data.pop("option_values", [])
        # Same reason as the default-variant path: this writes the model
        # directly, so the derivation has to happen explicitly.
        foreign_amount = data.pop("price_amount", None)

        if variant_id is None:
            variant = None
        else:
            try:
                variant = product.variants.get(pk=variant_id)
            except ProductVariant.DoesNotExist as error:
                raise serializers.ValidationError(
                    {"variants": "Variant does not belong to the selected product."}
                ) from error

        validate_variant_option_values(product, option_values, variant=variant)
        if data.get("is_default") is True:
            queryset = ProductVariant.objects.filter(
                product=product,
                is_default=True,
            )
            if variant is not None:
                queryset = queryset.exclude(pk=variant.pk)
            queryset.update(is_default=False)

        if variant is None:
            variant = ProductVariant.objects.create(product=product, **data)
        else:
            for field, value in data.items():
                setattr(variant, field, value)
            variant.save()
        _derive_base_price(variant, foreign_amount)
        variant.option_values.set(option_values)


class ProductBulkActionSerializer(serializers.Serializer):
    """Shared input for the products-list bulk actions: the selected ids."""

    ids = serializers.ListField(
        child=serializers.IntegerField(min_value=1),
        allow_empty=False,
    )


class ProductBulkArchiveSerializer(ProductBulkActionSerializer):
    # True archives the selection, False restores it.
    archived = serializers.BooleanField()


class ProductBulkRepriceSerializer(ProductBulkActionSerializer):
    MODE_CHOICES = (
        "set",
        "increase_percent",
        "decrease_percent",
        "increase_amount",
        "decrease_amount",
    )
    mode = serializers.ChoiceField(choices=MODE_CHOICES)
    value = serializers.DecimalField(
        max_digits=12,
        decimal_places=2,
        min_value=Decimal("0"),
    )

    def validate(self, attrs):
        if attrs["mode"] == "decrease_percent" and attrs["value"] > Decimal("100"):
            raise serializers.ValidationError(
                {"value": "A percentage decrease cannot exceed 100%."}
            )
        return attrs


class ProductBulkCategorizeSerializer(ProductBulkActionSerializer):
    MODE_CHOICES = ("replace", "add", "remove")
    category_ids = serializers.ListField(
        child=serializers.IntegerField(min_value=1),
        allow_empty=True,
    )
    mode = serializers.ChoiceField(choices=MODE_CHOICES)

    def validate(self, attrs):
        if attrs["mode"] in {"add", "remove"} and not attrs["category_ids"]:
            raise serializers.ValidationError(
                {"category_ids": "Select at least one category."}
            )
        return attrs


class ProductBulkFlagsSerializer(ProductBulkActionSerializer):
    FLAG_FIELDS = ("is_active", "tracks_expiry", "is_service", "is_prepared")
    is_active = serializers.BooleanField(required=False)
    tracks_expiry = serializers.BooleanField(required=False)
    is_service = serializers.BooleanField(required=False)
    is_prepared = serializers.BooleanField(required=False)

    def validate(self, attrs):
        if not any(field in attrs for field in self.FLAG_FIELDS):
            raise serializers.ValidationError(
                "Provide at least one flag to change."
            )
        return attrs


class ProductSetVariantPricesSerializer(serializers.Serializer):
    """Input for the "Change prices" dialogs (product details, and the purchase
    draft's pricing sheet).

    Writes explicit new selling prices in one atomic request: per variant (the
    base-unit price) and per **product unit** — the carton/box/sack price, which
    a shop may set below a straight multiple of the piece price. A unit entry
    with a null ``price`` hands that pack back to the derived
    ``variant price x factor``, which is how a pack stops having a price of its
    own without deleting the unit.

    At least one of the two lists must carry an entry; a request that changes
    nothing is a client bug, not a no-op worth writing a transaction for.
    """

    class _PriceEntrySerializer(serializers.Serializer):
        variant = serializers.IntegerField(min_value=1)
        unit_price = serializers.DecimalField(
            max_digits=10,
            decimal_places=2,
            min_value=Decimal("0"),
        )

    class _UnitPriceEntrySerializer(serializers.Serializer):
        # By unit CODE, matching every other unit-facing payload — the client
        # never juggles ProductUnit ids.
        unit = serializers.CharField(max_length=32)
        price = serializers.DecimalField(
            max_digits=10,
            decimal_places=2,
            min_value=Decimal("0"),
            allow_null=True,
        )

    prices = serializers.ListField(
        child=_PriceEntrySerializer(),
        required=False,
        allow_empty=True,
        default=list,
    )
    unit_prices = serializers.ListField(
        child=_UnitPriceEntrySerializer(),
        required=False,
        allow_empty=True,
        default=list,
    )

    def validate(self, attrs):
        if not attrs.get("prices") and not attrs.get("unit_prices"):
            raise serializers.ValidationError(
                {"prices": "Send at least one variant price or unit price."}
            )
        duplicates = _duplicated(
            entry["variant"] for entry in attrs.get("prices") or []
        )
        if duplicates:
            raise serializers.ValidationError(
                {"prices": f"Variant listed more than once: {duplicates}."}
            )
        duplicates = _duplicated(
            entry["unit"].strip() for entry in attrs.get("unit_prices") or []
        )
        if duplicates:
            raise serializers.ValidationError(
                {"unit_prices": f"Unit listed more than once: {duplicates}."}
            )
        return attrs


def _duplicated(values):
    """The values appearing more than once, as a sorted comma-joined string."""
    seen = set()
    repeated = set()
    for value in values:
        if value in seen:
            repeated.add(str(value))
        seen.add(value)
    return ", ".join(sorted(repeated))


class BoughtTogetherProductSerializer(serializers.Serializer):
    """Compact product card for the "frequently bought together" panel.

    Reads each entry as ``{"product": Product, "orders_together": int}``. Only
    the fields the panel renders are exposed — name, primary image, price, and
    how many orders pair it with the product being viewed.
    """

    id = serializers.IntegerField(source="product.id", read_only=True)
    name = serializers.CharField(source="product.name", read_only=True)
    orders_together = serializers.IntegerField(read_only=True)
    unit_price = serializers.SerializerMethodField()
    primary_image = serializers.SerializerMethodField()

    def get_unit_price(self, entry):
        variant = self._default_variant(entry["product"])
        return str(variant.unit_price) if variant is not None else None

    def get_primary_image(self, entry):
        return primary_attachment_summary(
            entry["product"],
            role=Attachment.Role.PRODUCT_IMAGE,
            context=self.context,
        )

    @staticmethod
    def _default_variant(product):
        # Read from the prefetched ``variants`` so the panel stays at one query
        # for the whole list rather than one per card.
        variants = list(product.variants.all())
        for variant in variants:
            if variant.is_default:
                return variant
        return variants[0] if variants else None
