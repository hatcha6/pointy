from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import transaction
from rest_framework import serializers

from apps.attachments.models import Attachment
from apps.attachments.serializers import AttachmentSummarySerializer
from .models import (
    Product,
    ProductCategory,
    ProductVariant,
    VariantOption,
    VariantOptionValue,
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


class ProductCategorySerializer(serializers.ModelSerializer):
    parent_name = serializers.CharField(source="parent.name", read_only=True)
    children_count = serializers.IntegerField(read_only=True)

    class Meta:
        model = ProductCategory
        fields = [
            "id",
            "name",
            "description",
            "parent",
            "parent_name",
            "children_count",
            "is_active",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at", "children_count")

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

    class Meta:
        model = Product
        fields = [
            "id",
            "name",
            "description",
            "is_active",
            "tracks_expiry",
            "is_service",
            "is_prepared",
            "unit",
            "categories",
            "category_details",
            "variant_options",
            "variant_option_details",
            "primary_image",
            "image_attachments",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at")

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
        return ProductVariantSerializer(value, context=self.context).data

    def to_internal_value(self, data):
        if not isinstance(data, dict):
            raise serializers.ValidationError("Expected an object.")
        serializer = DefaultProductVariantInputSerializer(
            data=data,
            context=self.context,
        )
        serializer.is_valid(raise_exception=True)
        return serializer.validated_data


class ProductVariantSerializer(serializers.ModelSerializer):
    product = serializers.PrimaryKeyRelatedField(
        queryset=Product.objects.all(),
        required=False,
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
            "unit_price",
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
        read_only_fields = ("created_at", "updated_at")

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
                variant = ProductVariant.objects.create(**validated_data)
                if option_values:
                    variant.option_values.set(option_values)
                    variant.refresh_from_db(fields=["option_signature"])
                return variant
        except DjangoValidationError as error:
            raise_serializer_validation(error)

    def update(self, instance, validated_data):
        option_values = validated_data.pop("option_values", None)
        try:
            with transaction.atomic():
                if validated_data.get("is_default") is True:
                    ProductVariant.objects.filter(
                        product=instance.product,
                        is_default=True,
                    ).exclude(pk=instance.pk).update(is_default=False)
                for field, value in validated_data.items():
                    setattr(instance, field, value)
                instance.save()
                if option_values is not None:
                    instance.option_values.set(option_values)
                    instance.refresh_from_db(fields=["option_signature"])
                return instance
        except DjangoValidationError as error:
            raise_serializer_validation(error)


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
        return ProductVariantSerializer(
            queryset,
            many=True,
            context=self.context,
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
    primary_image = serializers.SerializerMethodField()
    image_attachments = serializers.SerializerMethodField()

    class Meta:
        model = Product
        fields = [
            "id",
            "name",
            "description",
            "is_active",
            "tracks_expiry",
            "is_service",
            "is_prepared",
            "unit",
            "default_variant",
            "variants",
            "categories",
            "category_details",
            "variant_options",
            "variant_option_details",
            "primary_image",
            "image_attachments",
            "quantity_on_hand",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at")

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

    def create(self, validated_data):
        categories = validated_data.pop("categories", [])
        variant_options = validated_data.pop("variant_options", None)
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
                if variants_data is not None:
                    self._apply_variants_data(product, variants_data)
                else:
                    self._apply_default_variant_data(product, default_variant_data)
                return product
        except DjangoValidationError as error:
            raise_serializer_validation(error)

    def update(self, instance, validated_data):
        categories = validated_data.pop("categories", None)
        variant_options = validated_data.pop("variant_options", None)
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
                if variants_data is not None:
                    self._apply_variants_data(instance, variants_data)
                else:
                    self._apply_default_variant_data(instance, default_variant_data)
                return instance
        except DjangoValidationError as error:
            raise_serializer_validation(error)

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
        variant = product.ensure_default_variant(**variant_data)
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
        variant.option_values.set(option_values)
