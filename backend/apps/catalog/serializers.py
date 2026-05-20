from rest_framework import serializers

from .models import Product, ProductCategory


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


class ProductSerializer(serializers.ModelSerializer):
    quantity_on_hand = serializers.SerializerMethodField()
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
            "sku",
            "barcode",
            "name",
            "description",
            "unit_price",
            "is_active",
            "categories",
            "category_details",
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

    def get_quantity_on_hand(self, product):
        annotated_quantity = getattr(product, "stock_quantity_on_hand", None)
        if annotated_quantity is not None:
            return annotated_quantity
        try:
            return product.stock.quantity_on_hand
        except Product.stock.RelatedObjectDoesNotExist:
            return 0
