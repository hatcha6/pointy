import 'package:flutter/widgets.dart';

/// The marks of the Dafa payment methods, as Dafa's own dashboard shows them,
/// keyed by Dafa's provider id (the `provider` the relay lists with each
/// method). Local bank cards (`moamalat`) show Moamalat's ribbon, the
/// network every Libyan bank card is paid through (from docs.moamalat.net).
abstract final class PaymentMethodMarks {
  static const Set<String> _providers = {
    'moamalat',
    'sadad',
    'edfali',
    'mobicash',
    'yussor-pay',
    'masrafi-pay',
    'sahara-pay',
  };

  /// The mark of a provider, or null when it has none.
  static AssetImage? of(String provider) {
    if (!_providers.contains(provider)) {
      return null;
    }
    return AssetImage(
      'assets/payment_methods/$provider.png',
      package: 'pointy_brand',
    );
  }
}

/// The company's logos.
abstract final class PointyLogos {
  /// The Daftar master mark (the folded page and pencil).
  static const AssetImage daftar = AssetImage(
    'assets/branding/daftar_logo.png',
    package: 'pointy_brand',
  );
}
