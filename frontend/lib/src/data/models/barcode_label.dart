import 'product.dart';
import 'product_variant.dart';
import 'stock_batch.dart';
import 'stock_unit.dart';

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

  /// One identified article. Its own number is the barcode — scanned at the
  /// till, the IMEI lookup selects exactly this handset rather than asking
  /// which one — and its own asking price is the price, because two used
  /// handsets of one variant rarely sell for the same money.
  factory BarcodeLabelDraft.fromStockUnit(StockUnit unit) {
    final name = unit.variantName.isNotEmpty
        ? unit.variantName
        : unit.productName;
    return BarcodeLabelDraft(
      variantId: unit.variantId,
      displayName: name,
      productName: unit.productName,
      variantName: name,
      sku: unit.code,
      barcode: unit.code,
      unitPrice: unit.listPrice ?? unit.askingPrice ?? 0,
    );
  }

  /// A lot's shelf sticker: the product's own scan code and price. The lot's
  /// date rides on the print line ([BarcodeLabelPrintLine.lot]).
  factory BarcodeLabelDraft.fromStockBatch(StockBatch batch) {
    return BarcodeLabelDraft(
      variantId: batch.variantId,
      displayName: batch.variantName.isNotEmpty
          ? batch.variantName
          : batch.productName,
      productName: batch.productName,
      variantName: batch.variantName,
      sku: batch.variantSku,
      barcode: batch.variantBarcode,
      unitPrice: batch.variantPrice ?? 0,
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
    this.caption,
  });

  final BarcodeLabelDraft label;
  final int copies;
  final bool includePrice;
  final DateTime? expiryDate;

  /// A line printed where a product label puts its price — for stickers that
  /// are not products, such as the one a repair job puts on the customer's
  /// phone. Takes the place of the price and expiry when set.
  final String? caption;

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

  /// A handset's sticker; a serial-in-lot pack also carries its lot's date.
  factory BarcodeLabelPrintLine.unit(
    StockUnit unit, {
    int copies = 1,
    bool includePrice = true,
  }) {
    return BarcodeLabelPrintLine(
      label: BarcodeLabelDraft.fromStockUnit(unit),
      copies: copies,
      includePrice: includePrice,
      expiryDate: unit.batchExpiryDate,
    );
  }

  /// Stickers for a lot's goods, dated with the lot's own expiry.
  factory BarcodeLabelPrintLine.lot(
    StockBatch batch, {
    required int copies,
    bool includePrice = true,
  }) {
    return BarcodeLabelPrintLine(
      label: BarcodeLabelDraft.fromStockBatch(batch),
      copies: copies,
      includePrice: includePrice,
      expiryDate: batch.expiryDate,
    );
  }
}
