// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppLocalizationsAr extends AppLocalizations {
  AppLocalizationsAr([String locale = 'ar']) : super(locale);

  @override
  String get appTitle => 'نقطة البيع';

  @override
  String get refreshCatalogTooltip => 'تحديث المنتجات';

  @override
  String get catalogTitle => 'المنتجات';

  @override
  String get sampleCatalogNotice =>
      'يتم عرض منتجات تجريبية إلى أن يعمل الخادم.';

  @override
  String get emptyCatalog => 'لا توجد منتجات';

  @override
  String get currentSaleTitle => 'البيع الحالي';

  @override
  String get clearCartTooltip => 'مسح السلة';

  @override
  String get emptyCart => 'لا توجد عناصر في السلة';

  @override
  String payAmount(String amount) {
    return 'ادفع $amount';
  }

  @override
  String unitPriceEach(String amount) {
    return '$amount للقطعة';
  }

  @override
  String get removeOneTooltip => 'إنقاص عنصر';

  @override
  String get addOneTooltip => 'إضافة عنصر';

  @override
  String get subtotal => 'المجموع الفرعي';

  @override
  String get tax => 'الضريبة';

  @override
  String get total => 'الإجمالي';
}
