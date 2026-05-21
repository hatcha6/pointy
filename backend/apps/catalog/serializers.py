from rest_framework import serializers

from .models import (
    Product,
    ProductCategory,
    ProductVariant,
    VariantOption,
    VariantOptionValue,
)


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
    class Meta:
        model = VariantOptionValue
        fields = [
            "id",
            "option",
            "code",
            "name",
            "display_order",
            "is_active",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at")


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


class ProductSummarySerializer(serializers.ModelSerializer):
    category_details = ProductCategorySerializer(
        source="categories",
        many=True,
        read_only=True,
    )

    class Meta:
        model = Product
        fields = [
            "id",
            "name",
            "description",
            "is_active",
            "categories",
            "category_details",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at")


class DefaultProductVariantInputSerializer(serializers.Serializer):
    name = serializers.CharField(required=False, allow_blank=True, trim_whitespace=True)
    sku = serializers.CharField(required=False, allow_blank=False, trim_whitespace=True)
    barcode = serializers.CharField(
        required=False,
        allow_blank=True,
        trim_whitespace=True,
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
    product_detail = ProductSummarySerializer(source="product", read_only=True)
    display_name = serializers.CharField(read_only=True)
    full_name = serializers.CharField(read_only=True)
    quantity_on_hand = serializers.IntegerField(read_only=True)
    option_values = serializers.PrimaryKeyRelatedField(
        queryset=VariantOptionValue.objects.all(),
        many=True,
        required=False,
    )

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
            "is_default",
            "option_values",
            "quantity_on_hand",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at")

    def validate_unit_price(self, value):
        if value < 0:
            raise serializers.ValidationError("Unit price cannot be negative.")
        return value

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
        return attrs


class ProductSerializer(serializers.ModelSerializer):
    quantity_on_hand = serializers.SerializerMethodField()
    variants = ProductVariantSerializer(many=True, read_only=True)
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

    class Meta:
        model = Product
        fields = [
            "id",
            "name",
            "description",
            "is_active",
            "default_variant",
            "variants",
            "categories",
            "category_details",
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

    def create(self, validated_data):
        categories = validated_data.pop("categories", [])
        default_variant_data = validated_data.pop("default_variant", None)
        product = Product.objects.create(**validated_data)
        if categories:
            product.categories.set(categories)
        self._apply_default_variant_data(product, default_variant_data)
        return product

    def update(self, instance, validated_data):
        categories = validated_data.pop("categories", None)
        default_variant_data = validated_data.pop("default_variant", None)
        for field, value in validated_data.items():
            setattr(instance, field, value)
        instance.save()
        if categories is not None:
            instance.categories.set(categories)
        self._apply_default_variant_data(instance, default_variant_data)
        return instance

    def _apply_default_variant_data(self, product, default_variant_data):
        if default_variant_data is None:
            return
        variant_data = dict(default_variant_data)
        option_values = variant_data.pop("option_values", None)
        variant = product.ensure_default_variant(**variant_data)
        if option_values is not None:
            variant.option_values.set(option_values)
