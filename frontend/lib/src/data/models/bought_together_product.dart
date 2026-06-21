import 'attachment_summary.dart';

/// A product frequently sold in the same order as the one being viewed, as
/// ranked by the `products/{id}/bought-together/` endpoint. Carries only the
/// fields the product-detail "bought together" panel renders.
class BoughtTogetherProduct {
  const BoughtTogetherProduct({
    required this.productId,
    required this.name,
    required this.ordersTogether,
    this.unitPrice = 0,
    this.primaryImage,
  });

  final int productId;
  final String name;

  /// How many paid orders contain both this product and the viewed one.
  final int ordersTogether;
  final double unitPrice;
  final AttachmentSummary? primaryImage;

  factory BoughtTogetherProduct.fromJson(Map<String, Object?> json) {
    final image = json['primary_image'];
    return BoughtTogetherProduct(
      productId: _intFromJson(json['id']),
      name: json['name']?.toString() ?? '',
      ordersTogether: _intFromJson(json['orders_together']),
      unitPrice: _doubleFromJson(json['unit_price']),
      primaryImage: image is Map<String, Object?>
          ? AttachmentSummary.fromJson(image)
          : null,
    );
  }
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse((value ?? 0).toString()) ?? 0;
}

double _doubleFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse((value ?? '').toString()) ?? 0;
}
