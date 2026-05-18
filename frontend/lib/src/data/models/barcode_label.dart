import 'product.dart';

class BarcodeLabelDraft {
  const BarcodeLabelDraft({
    required this.productName,
    required this.sku,
    required this.barcode,
    required this.unitPrice,
  });

  final String productName;
  final String sku;
  final String barcode;
  final double unitPrice;

  factory BarcodeLabelDraft.fromProduct(Product product) {
    return BarcodeLabelDraft(
      productName: product.name,
      sku: product.sku,
      barcode: product.barcode,
      unitPrice: product.unitPrice,
    );
  }
}

class BarcodeLabelPrintLine {
  const BarcodeLabelPrintLine({required this.label, required this.copies});

  final BarcodeLabelDraft label;
  final int copies;

  factory BarcodeLabelPrintLine.product(Product product, {int copies = 1}) {
    return BarcodeLabelPrintLine(
      label: BarcodeLabelDraft.fromProduct(product),
      copies: copies,
    );
  }
}
