// Dev-only: shared shapes for the per-area sweep scripts.
import '../sweep_driver.dart';

class SweepSurface {
  const SweepSurface(this.name, this.run, {this.tags = const []});

  final String name;
  final Future<void> Function(SweepDriver driver) run;
  final List<String> tags;
}

/// Top-level destinations by analytics name and drawer label.
const destinationLabels = <String, String>{
  'dashboard': 'لوحة التحكم',
  'pos': 'شاشة البيع',
  'ai_assistant': 'GPT',
  'operations': 'المهام والتشغيل',
  'assets': 'الأجهزة والمركبات',
  'invoices': 'الفواتير',
  'returns_exchange': 'المرتجعات والاستبدال',
  'register_sessions': 'جلسات الدرج',
  'discounts': 'الخصومات',
  'catalog': 'المنتجات',
  'categories': 'التصنيفات',
  'purchase_orders': 'المشتريات',
  'stock_counts': 'جرد المخزون',
  'contacts': 'الجهات',
  'conversations': 'المحادثات',
  'campaigns': 'الحملات',
  'employees': 'الموظفون والرواتب',
  'expenses': 'المصروفات',
  'payments_hub': 'الخزينة',
  'reports': 'التقارير',
  'activity_log': 'سجل النشاط',
  'user_settings': 'إعداداتي',
  'device_settings': 'إعدادات الجهاز',
  'users': 'المستخدمون',
  'shop_settings': 'إعدادات المتجر',
};

/// A top-level screen: navigate through the drawer/rail, measure transition,
/// load, idle and scroll, then run [extras] on it (dialogs, sheets, details
/// screens, typing into its search field).
SweepSurface screen(
  String name, {
  bool scroll = true,
  Future<void> Function(SweepDriver driver)? extras,
}) {
  final label = destinationLabels[name];
  if (label == null) {
    throw ArgumentError('no drawer label for surface "$name"');
  }
  return SweepSurface(name, (driver) async {
    await driver.dismissOverlays();
    await driver.measureSurface(
      name,
      reach: () => driver.navigate(label),
      scroll: scroll,
      extras: extras == null ? null : () => extras(driver),
    );
  });
}
