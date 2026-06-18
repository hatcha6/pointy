/// How a bulk reprice adjusts each selected product's default-variant price.
enum ProductBulkRepriceMode {
  set('set'),
  increasePercent('increase_percent'),
  decreasePercent('decrease_percent'),
  increaseAmount('increase_amount'),
  decreaseAmount('decrease_amount');

  const ProductBulkRepriceMode(this.apiValue);

  final String apiValue;

  bool get isPercent =>
      this == increasePercent || this == decreasePercent;
}

/// How a bulk categorize change is applied to the selection's categories.
enum ProductBulkCategorizeMode {
  replace('replace'),
  add('add'),
  remove('remove');

  const ProductBulkCategorizeMode(this.apiValue);

  final String apiValue;
}
