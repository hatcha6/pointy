import 'product.dart';
import 'product_variant.dart';

class BarcodeLabelDraft {
  const BarcodeLabelDraft({
    required this.displayName,
    required this.sku,
    required this.barcode,
    required this.unitPrice,
    this.productId,
    this.variantId,
    this.productName = '',
    this.variantName = '',
  });

  final int? productId;
  final int? variantId;
  final String displayName;
  final String productName;
  final String variantName;
  final String sku;
  final String barcode;
  final double unitPrice;

  factory BarcodeLabelDraft.fromVariant(ProductVariant variant) {
    return BarcodeLabelDraft(
      productId: variant.productId,
      variantId: variant.id,
      displayName: variant.displayLabel,
      productName: variant.productLabel,
      variantName: variant.variantLabel,
      sku: variant.sku,
      barcode: variant.barcode,
      unitPrice: variant.unitPrice,
    );
  }

  factory BarcodeLabelDraft.fromProduct(Product product) {
    final variant = product.defaultVariant;
    if (variant != null) {
      return BarcodeLabelDraft.fromVariant(variant);
    }
    return BarcodeLabelDraft(
      productId: product.id,
      variantId: product.variantId,
      displayName: product.sellableName,
      productName: product.name,
      variantName: product.sellableName == product.name
          ? ''
          : product.sellableName,
      sku: product.effectiveSku,
      barcode: product.effectiveBarcode,
      unitPrice: product.effectiveUnitPrice,
    );
  }
}

class BarcodeLabelPrintLine {
  const BarcodeLabelPrintLine({
    required this.label,
    required this.copies,
    this.includePrice = true,
    this.expiryDate,
  });

  final BarcodeLabelDraft label;
  final int copies;
  final bool includePrice;
  final DateTime? expiryDate;

  bool get includeExpiryDate => expiryDate != null;

  factory BarcodeLabelPrintLine.product(
    Product product, {
    int copies = 1,
    bool includePrice = true,
    DateTime? expiryDate,
  }) {
    return BarcodeLabelPrintLine(
      label: BarcodeLabelDraft.fromProduct(product),
      copies: copies,
      includePrice: includePrice,
      expiryDate: expiryDate,
    );
  }

  factory BarcodeLabelPrintLine.variant(
    ProductVariant variant, {
    int copies = 1,
    bool includePrice = true,
    DateTime? expiryDate,
  }) {
    return BarcodeLabelPrintLine(
      label: BarcodeLabelDraft.fromVariant(variant),
      copies: copies,
      includePrice: includePrice,
      expiryDate: expiryDate,
    );
  }
}
