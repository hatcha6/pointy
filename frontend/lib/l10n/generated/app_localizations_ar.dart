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
  String get brandName => 'دفتر';

  @override
  String get errorUnexpectedMessage => 'حدث خطأ غير متوقع. حاول مرة أخرى.';

  @override
  String get errorServerMessage =>
      'تعذّر إكمال العملية على الخادم. حاول مرة أخرى لاحقًا.';

  @override
  String get commandPaletteTitle => 'تنقّل سريع';

  @override
  String get commandPaletteSearchHint =>
      'ابحث عن شاشة أو منتج أو عميل أو فاتورة…';

  @override
  String get commandPaletteScreensSection => 'الشاشات';

  @override
  String get commandPaletteProductsSection => 'المنتجات';

  @override
  String get commandPaletteCustomersSection => 'العملاء';

  @override
  String get commandPaletteSuppliersSection => 'الموردون';

  @override
  String get commandPaletteInvoicesSection => 'الفواتير';

  @override
  String get commandPalettePurchaseOrdersSection => 'أوامر الشراء';

  @override
  String get commandPaletteSearching => 'جارٍ البحث…';

  @override
  String get commandPaletteActionsSection => 'إجراءات سريعة';

  @override
  String get commandPaletteRecentsSection => 'المفتوحة مؤخرًا';

  @override
  String get commandPaletteActionNewSale => 'بيع جديد';

  @override
  String get commandPaletteActionNewPurchaseOrder => 'أمر شراء جديد';

  @override
  String get commandPaletteActionRecordExpense => 'تسجيل مصروف';

  @override
  String get commandPaletteActionStockCount => 'بدء جرد';

  @override
  String commandPaletteStockLabel(String count) {
    return '$count في المخزون';
  }

  @override
  String get commandPalettePrintLabelAction => 'طباعة الملصق';

  @override
  String get commandPaletteReorderAction => 'إعادة الطلب';

  @override
  String get commandPaletteReprintAction => 'إعادة طباعة الفاتورة';

  @override
  String get commandPaletteLabelPrinted => 'تمت طباعة الملصق';

  @override
  String get commandPaletteLabelPrintFailed => 'تعذرت طباعة الملصق';

  @override
  String get commandPaletteReorderNoVariant => 'لا يمكن إعادة طلب هذا المنتج';

  @override
  String get commandPaletteInvoicePrinted => 'تمت طباعة الفاتورة';

  @override
  String get commandPaletteInvoicePrintFailed => 'تعذرت طباعة الفاتورة';

  @override
  String get commandPaletteOpenError => 'تعذر فتح العنصر';

  @override
  String get commandPaletteNoResults => 'لا توجد نتائج مطابقة';

  @override
  String get commandPaletteOpenLabel => 'بحث وتنقّل سريع';

  @override
  String get commandPaletteFooterHint =>
      '↑↓ للتنقل · Enter للفتح · Esc للإغلاق';

  @override
  String get commandPaletteActionsHint => 'Tab للإجراءات';

  @override
  String get refreshCatalogTooltip => 'تحديث المنتجات';

  @override
  String get searchProductsHint => 'ابحث باسم المنتج أو الرمز';

  @override
  String get categorySearchHint => 'ابحث باسم التصنيف';

  @override
  String get categoriesLoadError => 'تعذر تحميل التصنيفات.';

  @override
  String get savingButton => 'جار الحفظ...';

  @override
  String get retryButton => 'إعادة المحاولة';

  @override
  String lineItemCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عناصر',
      two: 'عنصران',
      one: 'عنصر واحد',
      zero: 'لا توجد عناصر',
    );
    return '$_temp0';
  }

  @override
  String get clearSearchTooltip => 'مسح البحث';

  @override
  String get openCameraScannerTooltip => 'فتح ماسح الكاميرا';

  @override
  String get openFiltersTooltip => 'الفلاتر والترتيب';

  @override
  String get filtersButtonLabel => 'الفلاتر';

  @override
  String get filtersSheetTitle => 'الفلاتر والترتيب';

  @override
  String get availabilityFilterTitle => 'حالة المنتج';

  @override
  String get availabilityAll => 'كل المنتجات';

  @override
  String get availabilityActive => 'المتاحة فقط';

  @override
  String get availabilityInactive => 'المتوقفة فقط';

  @override
  String get orderingTitle => 'ترتيب النتائج';

  @override
  String get orderingName => 'الاسم';

  @override
  String get orderingMostBought => 'الأكثر مبيعًا';

  @override
  String get orderingPriceAsc => 'السعر: من الأقل إلى الأعلى';

  @override
  String get orderingPriceDesc => 'السعر: من الأعلى إلى الأقل';

  @override
  String get orderingNewest => 'الأحدث أولًا';

  @override
  String get resetFiltersButton => 'إعادة ضبط';

  @override
  String get applyFiltersButton => 'تطبيق';

  @override
  String get navigationMenuTooltip => 'فتح القائمة';

  @override
  String get navigationRailExpandTooltip => 'توسيع التنقل';

  @override
  String get navigationRailCollapseTooltip => 'طي التنقل';

  @override
  String get navigationMenuTitle => 'القائمة';

  @override
  String get navigationMenuSubtitle => 'تنقل سريع بين شاشات نقطة البيع';

  @override
  String get posDrawerLabel => 'شاشة البيع';

  @override
  String get purchasingDrawerLabel => 'المشتريات';

  @override
  String get contactsDrawerLabel => 'الجهات';

  @override
  String get catalogDrawerLabel => 'المنتجات';

  @override
  String get categoriesDrawerLabel => 'التصنيفات';

  @override
  String get registerSessionsDrawerLabel => 'جلسات الدرج';

  @override
  String get invoicesDrawerLabel => 'الفواتير';

  @override
  String get deviceSettingsDrawerLabel => 'إعدادات الجهاز';

  @override
  String get usersDrawerLabel => 'المستخدمون';

  @override
  String get settingsDrawerLabel => 'إعدادات المتجر';

  @override
  String get dashboardDrawerLabel => 'لوحة التحكم';

  @override
  String get userSettingsDrawerLabel => 'إعداداتي';

  @override
  String get navigationGroupPrimary => 'الرئيسية';

  @override
  String get navigationGroupSales => 'المبيعات';

  @override
  String get navigationGroupStock => 'المخزون والمشتريات';

  @override
  String get navigationGroupPeople => 'الأشخاص والرواتب';

  @override
  String get navigationGroupReports => 'التقارير والمراجعة';

  @override
  String get navigationGroupSettings => 'الإعدادات';

  @override
  String get reportsDrawerLabel => 'التقارير';

  @override
  String get activityLogDrawerLabel => 'سجل النشاط';

  @override
  String get activityLogTitle => 'سجل نشاط المستخدمين';

  @override
  String get refreshActivityLogTooltip => 'تحديث سجل النشاط';

  @override
  String get activityLogSearchHint => 'ابحث باسم الحدث أو الأثر أو الكيان';

  @override
  String get activityLogTotalMetric => 'إجمالي النتائج';

  @override
  String get activityLogLoadedMetric => 'المعروض الآن';

  @override
  String get activityLogFraudMetric => 'مؤشرات اشتباه';

  @override
  String get activityLogHighRiskMetric => 'مخاطر عالية';

  @override
  String get activityLogUsersLoadWarning =>
      'تعذر تحميل قائمة المستخدمين للفلاتر. يمكنك متابعة البحث والفلاتر الأخرى.';

  @override
  String get activityLogLoadError => 'تعذر تحميل سجل النشاط.';

  @override
  String get activityLogEmpty => 'لا توجد أحداث تطابق الفلاتر الحالية.';

  @override
  String activityLogSuspicionReviewBanner(String reason) {
    return 'تم فتح سجل النشاط بفلاتر مراجعة لأن النظام لاحظ نمطًا مشتبهًا: $reason. راجع الأحداث والطلبات ضمن الفترة المحددة قبل اتخاذ أي إجراء.';
  }

  @override
  String get activityLogNoEventSelected => 'اختر حدثًا لمراجعة التفاصيل.';

  @override
  String get activityLogUnknownUser => 'مستخدم غير معروف';

  @override
  String activityLogEventSubtitle(String date, String user) {
    return '$date بواسطة $user';
  }

  @override
  String activityLogEventSubtitleWithSummary(
    String date,
    String user,
    String summary,
  ) {
    return '$date بواسطة $user - $summary';
  }

  @override
  String activityLogRiskScore(int score) {
    return 'مخاطر $score';
  }

  @override
  String get activityLogDetailUser => 'المستخدم';

  @override
  String get activityLogDetailRisk => 'درجة المخاطر';

  @override
  String get activityLogNoRiskScore => 'لا توجد';

  @override
  String get activityLogDetailEventSection => 'الحدث';

  @override
  String get activityLogRawNameLabel => 'الاسم الخام';

  @override
  String get activityLogTypeLabel => 'النوع';

  @override
  String get activityLogSeverityLabel => 'الحدة';

  @override
  String get activityLogSourceLabel => 'المصدر';

  @override
  String get activityLogDetailContextSection => 'السياق';

  @override
  String get activityLogSessionLabel => 'الجلسة';

  @override
  String get activityLogEntityTypeLabel => 'نوع الكيان';

  @override
  String get activityLogEntityIdLabel => 'معرّف الكيان';

  @override
  String get activityLogTraceIdLabel => 'أثر الطلب';

  @override
  String get activityLogPlatformLabel => 'المنصة';

  @override
  String get activityLogAttributesSection => 'البيانات';

  @override
  String get activityLogNoAttributes => 'لا توجد بيانات إضافية.';

  @override
  String get activityLogMetricsSection => 'المقاييس';

  @override
  String get activityLogNoMetrics => 'لا توجد مقاييس.';

  @override
  String get activityLogMissingValue => 'غير متوفر';

  @override
  String get activityLogOpenInvoice => 'فتح الفاتورة';

  @override
  String get activityLogOpenPurchaseOrder => 'فتح أمر الشراء';

  @override
  String get activityLogOpenTargetError => 'تعذر فتح تفاصيل هذا السجل.';

  @override
  String get activityLogNoSummary => 'لا توجد خلاصة إضافية.';

  @override
  String activityLogSessionSummary(String session) {
    return 'جلسة $session';
  }

  @override
  String activityLogTotalSummary(String total) {
    return 'الإجمالي $total';
  }

  @override
  String activityLogCartTotalSummary(String total) {
    return 'إجمالي السلة $total';
  }

  @override
  String activityLogDraftTotalSummary(String total) {
    return 'إجمالي مسودة الشراء $total';
  }

  @override
  String activityLogProductSummary(String product, String quantity) {
    return '$product - الكمية $quantity';
  }

  @override
  String activityLogSupplierSummary(String supplier) {
    return 'المورد $supplier';
  }

  @override
  String activityLogUserSummary(String user) {
    return 'المستخدم $user';
  }

  @override
  String activityLogDiscountRuleSummary(String rule) {
    return 'قاعدة الخصم $rule';
  }

  @override
  String activityLogReportSummary(String report) {
    return 'التقرير $report';
  }

  @override
  String activityLogMovementTypeSummary(String movementType) {
    return 'نوع الحركة $movementType';
  }

  @override
  String activityLogUiSourceSummary(String source) {
    return 'من $source';
  }

  @override
  String activityLogReasonSummary(String reason) {
    return 'السبب: $reason';
  }

  @override
  String activityLogSuspicionRuleSummary(String rule) {
    return 'قاعدة المراجعة: $rule';
  }

  @override
  String activityBackendRequestTitle(String method, String target) {
    return '$method $target';
  }

  @override
  String activityFrontendInteractionTitle(String action, String target) {
    return '$action $target';
  }

  @override
  String activityEventUnknownTitle(String name) {
    return 'حدث غير مصنف: $name';
  }

  @override
  String activityLogMethodPathSummary(String method, String path) {
    return '$method $path';
  }

  @override
  String activityLogRequestSummary(String method, String path, int status) {
    return '$method $path - الحالة $status';
  }

  @override
  String activityLogInteractionSummary(String action, String target) {
    return 'الإجراء $action على $target';
  }

  @override
  String get activityRequestMethodGet => 'استعرض';

  @override
  String get activityRequestMethodPost => 'نفّذ';

  @override
  String get activityRequestMethodPatch => 'عدّل';

  @override
  String get activityRequestMethodDelete => 'حذف';

  @override
  String get activityRequestMethodOther => 'طلب';

  @override
  String get activityTargetActivityLog => 'سجل النشاط';

  @override
  String get activityTargetUsers => 'المستخدمين';

  @override
  String get activityTargetInvoices => 'الفواتير';

  @override
  String get activityTargetCheckout => 'إكمال بيع';

  @override
  String get activityTargetPurchaseOrders => 'أوامر الشراء';

  @override
  String get activityTargetCustomers => 'العملاء';

  @override
  String get activityTargetSuppliers => 'الموردين';

  @override
  String get activityTargetCatalog => 'المنتجات والمخزون';

  @override
  String get activityTargetRegisterSessions => 'جلسات الدرج';

  @override
  String get activityTargetDiscounts => 'الخصومات';

  @override
  String get activityTargetReports => 'التقارير';

  @override
  String get activityTargetAuth => 'تسجيل الدخول';

  @override
  String get activityTargetSystem => 'النظام';

  @override
  String get activityTargetCurrentScreen => 'الشاشة الحالية';

  @override
  String get activityInteractionNavigation => 'فتح شاشة';

  @override
  String get activityInteractionLogout => 'اختار الخروج من';

  @override
  String get activityInteractionProductSelected => 'فتح منتج من';

  @override
  String get activityInteractionPointer => 'لمس';

  @override
  String get activityInteractionScroll => 'مرر';

  @override
  String get activityInteractionKeyboard => 'استخدم لوحة المفاتيح في';

  @override
  String get activityInteractionFocus => 'نقل التركيز داخل';

  @override
  String get activityInteractionGeneral => 'تفاعل مع';

  @override
  String get activityUiSourceProductTile => 'بطاقة المنتج';

  @override
  String get activityUiSourceVariantPicker => 'نافذة اختيار المتغير';

  @override
  String get activityUiSourceBarcodeLookup => 'حقل الباركود';

  @override
  String get activityUiSourceHardwareScanner => 'ماسح الباركود الخارجي';

  @override
  String get activityUiSourceCameraScanner => 'ماسح الكاميرا';

  @override
  String get activityUiSourceCartQuantityButton => 'أزرار كمية السلة';

  @override
  String get activityUiSourceCartDeleteButton => 'زر حذف سطر السلة';

  @override
  String get activityUiSourceCartClearButton => 'زر تفريغ السلة';

  @override
  String get activityUiSourcePurchaseCatalog => 'كتالوج الشراء';

  @override
  String get activityUiSourcePurchaseBarcodeLookup => 'حقل باركود الشراء';

  @override
  String get activityUiSourcePurchaseCameraScanner => 'ماسح كاميرا الشراء';

  @override
  String get activityUiSourcePurchaseDraftQuantityButton =>
      'أزرار كمية مسودة الشراء';

  @override
  String get activityUiSourcePurchaseDraftClearButton =>
      'زر تفريغ مسودة الشراء';

  @override
  String get activityUiSourceRegisterSessionGate => 'واجهة فتح الدرج';

  @override
  String get activityUiSourceRegisterSessionCloseSheet => 'نافذة إغلاق الدرج';

  @override
  String get activityUiSourceRegisterCashMovementSheet =>
      'نافذة الحركة النقدية';

  @override
  String get activityUiSourceRegisterSessionHistory => 'سجل جلسات الدرج';

  @override
  String get activityUiSourceSaleOrderDetailsSheet => 'نافذة تفاصيل الفاتورة';

  @override
  String get activityUiSourceCatalogProductForm => 'نموذج المنتج';

  @override
  String get activityUiSourceCatalogProductDetails => 'تفاصيل المنتج';

  @override
  String get activityUiSourceCatalogVariantForm => 'نموذج متغير المنتج';

  @override
  String get activityUiSourceCatalogVariantGenerator => 'مولّد المتغيرات';

  @override
  String get activityUiSourceCategoryManagement => 'إدارة التصنيفات';

  @override
  String get activityUiSourceStockMovementForm => 'نموذج حركة المخزون';

  @override
  String get activityUiSourceBarcodeLabelPanel => 'لوحة طباعة الباركود';

  @override
  String get activityUiSourceUserManagement => 'إدارة المستخدمين';

  @override
  String get activityUiSourceShopSettings => 'إعدادات المتجر';

  @override
  String get activityUiSourceDeviceSettings => 'إعدادات الجهاز';

  @override
  String get activityUiSourceDiscountManagement => 'إدارة الخصومات';

  @override
  String get activityUiSourceReportsScreen => 'شاشة التقارير';

  @override
  String get activityUiSourceAnalyticsExportSheet => 'نافذة تصدير التحليلات';

  @override
  String get activityUiSourcePrintingSettings => 'إعدادات الطباعة';

  @override
  String activityUiSourceUnknown(String source) {
    return '$source';
  }

  @override
  String get activityLogScopeFilterTitle => 'نطاق السجل';

  @override
  String get activityScopeReviewable => 'الأحداث المهمة فقط';

  @override
  String get activityScopeAll => 'كل الأحداث';

  @override
  String get activityScopeTechnical => 'السجل التقني فقط';

  @override
  String get activityLogActionFilterTitle => 'الإجراء';

  @override
  String get activityLogDateFilterTitle => 'الفترة';

  @override
  String get activityLogFromDateOpen => 'من البداية';

  @override
  String get activityLogToDateOpen => 'إلى الآن';

  @override
  String activityLogFromDateValue(String date) {
    return 'من $date';
  }

  @override
  String activityLogToDateValue(String date) {
    return 'إلى $date';
  }

  @override
  String get activityLogUserFilterTitle => 'المستخدم';

  @override
  String get activityLogUserFilterLabel => 'المستخدم';

  @override
  String get activityLogAllUsers => 'كل المستخدمين';

  @override
  String get activityLogUserFilterHelper =>
      'اختر مستخدمًا أو أكثر لتصفية الإجراءات المسجلة.';

  @override
  String get activityLogUsersOpenPickerTooltip => 'اختيار المستخدمين';

  @override
  String get activityLogUserPickerTitle => 'اختيار المستخدمين';

  @override
  String get activityLogUserPickerSearchHint => 'ابحث باسم المستخدم أو البريد';

  @override
  String get activityLogUserPickerEmpty => 'لا يوجد مستخدمون مطابقون.';

  @override
  String get activityLogUserPickerLoadError => 'تعذر تحميل المستخدمين.';

  @override
  String activityLogUserFallbackLabel(int id) {
    return 'مستخدم #$id';
  }

  @override
  String get activityLogContextFilterTitle => 'السياق';

  @override
  String get activityLogSessionFilterLabel => 'معرّف جلسة الدرج';

  @override
  String get activityLogEntityTypeFilterLabel => 'نوع الكيان';

  @override
  String get activityLogEntityIdFilterLabel => 'معرّف الكيان';

  @override
  String get activityLogEventTypeFilterTitle => 'نوع الحدث';

  @override
  String get activityLogSeverityFilterTitle => 'الحدة';

  @override
  String get activityLogRiskFilterTitle => 'درجة المخاطر';

  @override
  String get activityLogRiskAll => 'كل درجات المخاطر';

  @override
  String activityLogRiskAtLeast(int score) {
    return '$score فأعلى';
  }

  @override
  String get activityLogSourceFilterTitle => 'المصدر';

  @override
  String get activityLogOrderingTitle => 'ترتيب النتائج';

  @override
  String get activityActionAll => 'كل الإجراءات';

  @override
  String get activityActionFraudSignal => 'مؤشرات الاشتباه';

  @override
  String get activityActionPosLineAdded => 'إضافة سطر بيع';

  @override
  String get activityActionPosLineQuantityChanged => 'تغيير كمية سطر بيع';

  @override
  String get activityActionPosLineDeleted => 'حذف سطر بيع';

  @override
  String get activityActionPosCartCleared => 'تفريغ سلة البيع';

  @override
  String get activityActionPurchaseLineAdded => 'إضافة سطر شراء';

  @override
  String get activityActionPurchaseLineQuantityChanged => 'تغيير كمية سطر شراء';

  @override
  String get activityActionPurchaseLineDeleted => 'حذف سطر شراء';

  @override
  String get activityActionPurchaseDraftCleared => 'تفريغ مسودة شراء';

  @override
  String get activityActionPurchaseDraftSubmitted => 'إرسال مسودة شراء';

  @override
  String get activityActionInvoiceCreated => 'إنشاء فاتورة';

  @override
  String get activityActionCustomerCreated => 'إنشاء عميل';

  @override
  String get activityActionRegisterCashMovement => 'حركة نقدية في الدرج';

  @override
  String get activityActionRegisterSessionStarted => 'فتح جلسة درج';

  @override
  String get activityActionRegisterSessionClosed => 'إغلاق جلسة درج';

  @override
  String get activityActionReceiptReprinted => 'إعادة طباعة إيصال';

  @override
  String get activityActionOrderVoided => 'إلغاء فاتورة';

  @override
  String get activityActionOrderReturned => 'مرتجع فاتورة';

  @override
  String get activityActionProductChanged => 'تغييرات المنتجات';

  @override
  String get activityActionStockMovementCreated => 'حركات المخزون';

  @override
  String get activityActionBarcodeLabelsPrinted => 'طباعة ملصقات باركود';

  @override
  String get activityActionUserChanged => 'تغييرات المستخدمين';

  @override
  String get activityActionSettingsChanged => 'تغييرات الإعدادات';

  @override
  String get activityActionDiscountChanged => 'تغييرات الخصومات';

  @override
  String get activityActionReportActivity => 'نشاط التقارير';

  @override
  String get activityActionPrinterActivity => 'نشاط الطباعة';

  @override
  String get activityActionAnalyticsExport => 'تصدير التحليلات';

  @override
  String get activityActionPurchaseOrderDeleted => 'حذف أمر شراء';

  @override
  String get activityActionAnyDeleted => 'أي حذف';

  @override
  String get activityDateRangeAll => 'كل الفترات';

  @override
  String get activityDateRangeToday => 'اليوم';

  @override
  String get activityDateRange7Days => 'آخر 7 أيام';

  @override
  String get activityDateRange30Days => 'آخر 30 يومًا';

  @override
  String get activityDateRangeCustom => 'فترة مخصصة';

  @override
  String get activityOrderingNewest => 'الأحدث أولًا';

  @override
  String get activityOrderingOldest => 'الأقدم أولًا';

  @override
  String get activityOrderingHighestRisk => 'الأعلى مخاطرة أولًا';

  @override
  String get activityOrderingNewestReceived => 'الأحدث وصولًا أولًا';

  @override
  String get activityEventCheckoutCompleted => 'اكتملت عملية بيع';

  @override
  String get activityEventOrderPaid => 'تم دفع فاتورة';

  @override
  String get activityEventOrderVoided => 'ألغيت فاتورة';

  @override
  String get activityEventOrderReturned => 'تم تسجيل مرتجع';

  @override
  String get activityEventSuspectedActivityDetected =>
      'رُصد نمط مشتبه للمراجعة';

  @override
  String get activityEventReceiptReprintQueued => 'أعيدت طباعة إيصال';

  @override
  String get activityEventReceiptReprintFailed => 'فشلت إعادة طباعة إيصال';

  @override
  String get activityEventRegisterSessionStarted => 'بدأت جلسة درج';

  @override
  String get activityEventRegisterSessionResumed => 'استؤنفت جلسة درج';

  @override
  String get activityEventRegisterSessionClosed => 'أغلقت جلسة درج';

  @override
  String get activityEventRegisterCashMovementCreated => 'سجلت حركة نقدية';

  @override
  String get activityEventSalesHistorySessionSelected => 'فتحت جلسة من السجل';

  @override
  String get activityEventSalesHistoryOrderVoidCompleted =>
      'اكتمل إلغاء فاتورة من السجل';

  @override
  String get activityEventSalesHistoryOrderReturnCompleted =>
      'اكتمل مرتجع فاتورة من السجل';

  @override
  String get activityEventPosLineAdded => 'أضيف سطر إلى سلة البيع';

  @override
  String get activityEventPosLineQuantityIncreased =>
      'زادت كمية سطر في سلة البيع';

  @override
  String get activityEventPosLineQuantityDecreased =>
      'نقصت كمية سطر في سلة البيع';

  @override
  String get activityEventPosLineDeleted => 'حذف سطر من سلة البيع';

  @override
  String get activityEventPosCartCleared => 'أفرغت سلة البيع';

  @override
  String get activityEventPosCheckoutStarted => 'بدأ إرسال عملية بيع';

  @override
  String get activityEventPosCheckoutCompleted =>
      'اكتملت عملية البيع من الواجهة';

  @override
  String get activityEventPosCheckoutFailed => 'فشل إرسال عملية بيع';

  @override
  String get activityEventPosCheckoutStockRejected =>
      'رفضت عملية بيع بسبب المخزون';

  @override
  String get activityEventPurchaseLineAdded => 'أضيف سطر إلى مسودة الشراء';

  @override
  String get activityEventPurchaseLineQuantityIncreased =>
      'زادت كمية سطر في مسودة الشراء';

  @override
  String get activityEventPurchaseLineQuantityDecreased =>
      'نقصت كمية سطر في مسودة الشراء';

  @override
  String get activityEventPurchaseLineDeleted => 'حذف سطر من مسودة الشراء';

  @override
  String get activityEventPurchaseDraftCleared => 'أفرغت مسودة الشراء';

  @override
  String get activityEventPurchaseSupplierSelected =>
      'اختير مورد لمسودة الشراء';

  @override
  String get activityEventPurchaseDraftSubmitted => 'أرسلت مسودة شراء';

  @override
  String get activityEventPurchaseDraftSubmitFailed => 'فشل إرسال مسودة شراء';

  @override
  String get activityEventPurchaseOrderCreated => 'أنشئ أمر شراء';

  @override
  String get activityEventPurchaseOrderUpdated => 'حُدث أمر شراء';

  @override
  String get activityEventPurchaseOrderSubmitted => 'أرسل أمر شراء';

  @override
  String get activityEventPurchaseOrderReceived => 'استلم أمر شراء';

  @override
  String get activityEventPurchaseOrderAdjusted => 'عدّل أمر شراء';

  @override
  String get activityEventPurchaseOrderCancelled => 'ألغي أمر شراء';

  @override
  String get activityEventPurchaseOrderDeleted => 'حذف أمر شراء';

  @override
  String get activityEventCustomerCreated => 'أنشئ عميل';

  @override
  String get activityEventCustomerUpdated => 'حُدث عميل';

  @override
  String get activityEventCustomerDeleted => 'حذف عميل';

  @override
  String get activityEventCatalogProductCreated => 'أنشئ منتج';

  @override
  String get activityEventCatalogProductUpdated => 'حُدث منتج';

  @override
  String get activityEventCatalogProductImageUploaded => 'رُفعت صورة منتج';

  @override
  String get activityEventCatalogProductImageImported => 'استوردت صورة منتج';

  @override
  String get activityEventCatalogVariantCreated => 'أنشئ متغير منتج';

  @override
  String get activityEventCatalogVariantUpdated => 'حُدث متغير منتج';

  @override
  String get activityEventCatalogVariantsGenerated => 'وُلدت متغيرات منتج';

  @override
  String get activityEventCatalogCategoryCreated => 'أنشئ تصنيف منتج';

  @override
  String get activityEventStockMovementCreated => 'سجلت حركة مخزون';

  @override
  String get activityEventStockMovementCreateFailed => 'فشل تسجيل حركة مخزون';

  @override
  String get activityEventUserCreated => 'أنشئ مستخدم';

  @override
  String get activityEventUserUpdated => 'حُدث مستخدم';

  @override
  String get activityEventUserDeleted => 'حذف مستخدم';

  @override
  String get activityEventUserRoleChanged => 'تغير دور مستخدم';

  @override
  String get activityEventUserActiveChanged => 'تغيرت حالة مستخدم';

  @override
  String get activityEventShopSettingsUpdated => 'حُدثت إعدادات المتجر';

  @override
  String get activityEventShopLogoUploaded => 'رُفع شعار المتجر';

  @override
  String get activityEventShopLogoRemoved => 'أزيل شعار المتجر';

  @override
  String get activityEventDeviceUsageModeChanged => 'تغير وضع استخدام الجهاز';

  @override
  String get activityEventDiscountRuleCreated => 'أنشئت قاعدة خصم';

  @override
  String get activityEventDiscountRuleUpdated => 'حُدثت قاعدة خصم';

  @override
  String get activityEventDiscountRuleEnabled => 'فُعلت قاعدة خصم';

  @override
  String get activityEventDiscountRuleDisabled => 'عُطلت قاعدة خصم';

  @override
  String get activityEventDiscountRuleArchived => 'أرشفت قاعدة خصم';

  @override
  String get activityEventBarcodeLabelsPrinted => 'طُبعت ملصقات باركود';

  @override
  String get activityEventBarcodeLabelsFailed => 'فشلت طباعة ملصقات باركود';

  @override
  String get activityEventPrinterDiscoveryCompleted =>
      'اكتمل البحث عن الطابعات';

  @override
  String get activityEventPrinterDiscoveryFailed => 'فشل البحث عن الطابعات';

  @override
  String get activityEventPrinterTested => 'اختُبرت الطابعة';

  @override
  String get activityEventPrinterFakeReceiptPrinted => 'طُبع إيصال تجريبي';

  @override
  String get activityEventAppFlutterError => 'سجل التطبيق خطأ';

  @override
  String get activityEventAppPlatformError => 'سجل النظام خطأ';

  @override
  String get activityEventAuthSessionStarted => 'بدأت جلسة دخول';

  @override
  String get activityEventLoginSucceeded => 'نجح تسجيل الدخول';

  @override
  String get activityEventLoginFailed => 'فشل تسجيل الدخول';

  @override
  String get activityEventLogout => 'سجل المستخدم خروجه';

  @override
  String get activityEventAnalyticsExportStarted => 'بدأ تصدير التحليلات';

  @override
  String get activityEventAnalyticsExportCompleted => 'اكتمل تصدير التحليلات';

  @override
  String get activityEventAnalyticsExportCanceled => 'أُلغي تصدير التتبع';

  @override
  String get activityEventAnalyticsExportFailed => 'فشل تصدير التحليلات';

  @override
  String get activityEventAnalyticsExportDownloaded => 'نُزل ملف التحليلات';

  @override
  String get activityEventAnalyticsExportDownloadFailed =>
      'فشل تنزيل ملف التحليلات';

  @override
  String get activityEventReportGenerated => 'أنشئ تقرير';

  @override
  String get activityEventReportGenerationFailed => 'فشل إنشاء تقرير';

  @override
  String get activityEventReportPreviewed => 'عاين المستخدم تقريرًا';

  @override
  String get activityEventReportPrinted => 'طبع المستخدم تقريرًا';

  @override
  String get activityEventReportShared => 'شارك المستخدم تقريرًا';

  @override
  String get activityEventReportRunCompleted => 'اكتمل تشغيل تقرير';

  @override
  String get activityEventReportRunFailed => 'فشل تشغيل تقرير';

  @override
  String get reportsTitle => 'التقارير';

  @override
  String get reportsCatalogTitle => 'أنواع التقارير';

  @override
  String get reportsSetupTitle => 'إعداد التقرير';

  @override
  String get reportCategorySales => 'المبيعات';

  @override
  String get reportCategoryCash => 'النقدية';

  @override
  String get reportCategoryPayments => 'المدفوعات';

  @override
  String get reportCategoryInventory => 'المخزون';

  @override
  String get reportCategoryPurchasing => 'المشتريات';

  @override
  String get reportCategoryReceivables => 'الذمم المدينة';

  @override
  String get reportCategoryPayables => 'الذمم الدائنة';

  @override
  String get reportCategoryExpenses => 'المصاريف';

  @override
  String get reportCategoryClose => 'الإقفال';

  @override
  String get reportCategoryContacts => 'الجهات';

  @override
  String get reportCategoryDiscounts => 'الخصومات';

  @override
  String get reportSalesSummaryTitle => 'ملخص المبيعات';

  @override
  String get reportSalesSummarySubtitle =>
      'إجماليات الطلبات والمرتجعات والخصومات حسب الفترة.';

  @override
  String get reportRegisterSessionsTitle => 'جلسات الدرج';

  @override
  String get reportRegisterSessionsSubtitle =>
      'افتتاح وإغلاق الجلسات والفروقات النقدية لكل وردية.';

  @override
  String get reportPaymentsTitle => 'المدفوعات';

  @override
  String get reportPaymentsSubtitle =>
      'طرق الدفع والعمولات والتسويات خلال الفترة.';

  @override
  String get reportInventoryValueTitle => 'قيمة المخزون';

  @override
  String get reportInventoryValueSubtitle =>
      'الكميات الحالية وقيمة البيع والتكلفة عند توفرها.';

  @override
  String get reportStockMovementTitle => 'حركات المخزون';

  @override
  String get reportStockMovementSubtitle =>
      'الاستلام والتعديل والبيع لكل منتج.';

  @override
  String get reportPurchasesTitle => 'المشتريات والموردون';

  @override
  String get reportPurchasesSubtitle => 'أوامر الشراء والاستلام والمستحقات.';

  @override
  String get reportCategoryEmployees => 'الموظفون';

  @override
  String get reportReorderItemsTitle => 'أصناف تحتاج إعادة طلب';

  @override
  String get reportReorderItemsSubtitle =>
      'المنتجات التي بلغت حد إعادة الطلب مع الكميات المقترحة للشراء.';

  @override
  String get reportPayrollSummaryTitle => 'الرواتب والأجور';

  @override
  String get reportPayrollSummarySubtitle =>
      'مسيرات الرواتب وتكلفة الموظفين خلال الفترة.';

  @override
  String get reportProfitCostsTitle => 'الأرباح والتكاليف';

  @override
  String get reportProfitCostsSubtitle =>
      'الربح الإجمالي مقابل الرواتب والعمولات وإنفاق المشتريات.';

  @override
  String get reportContactsTitle => 'أرصدة الجهات';

  @override
  String get reportContactsSubtitle =>
      'نشاط العملاء والموردين والأرصدة المرتبطة بهم.';

  @override
  String get reportDiscountsTitle => 'سجل الخصومات';

  @override
  String get reportDiscountsSubtitle =>
      'الخصومات النشطة والاستخدامات خلال الفترة.';

  @override
  String get reportReceivablesAgingTitle => 'أعمار الذمم المدينة';

  @override
  String get reportReceivablesAgingSubtitle =>
      'من يدين للمتجر، ومنذ متى، مع تقادم الديون.';

  @override
  String get reportPayablesAgingTitle => 'أعمار الذمم الدائنة';

  @override
  String get reportPayablesAgingSubtitle =>
      'ما على المتجر للموردين، وما استحق منه.';

  @override
  String get reportCustomerStatementTitle => 'كشف حساب عميل';

  @override
  String get reportCustomerStatementSubtitle =>
      'رصيد أول المدة والحركات ورصيد آخر المدة لعميل واحد.';

  @override
  String get reportSupplierStatementTitle => 'كشف حساب مورد';

  @override
  String get reportSupplierStatementSubtitle =>
      'فواتير المورد ومدفوعاته والرصيد المتبقي.';

  @override
  String get reportCashPositionTitle => 'النقدية والمصارف';

  @override
  String get reportCashPositionSubtitle =>
      'رصيد أول المدة والحركة والرصيد المتوقع لكل حساب.';

  @override
  String get reportExpenseBreakdownTitle => 'المصاريف حسب البند';

  @override
  String get reportExpenseBreakdownSubtitle =>
      'أين ذهب المال، مرتبًا من الأكبر.';

  @override
  String get reportProductMarginTitle => 'هوامش المنتجات';

  @override
  String get reportProductMarginSubtitle => 'ما يربح فعلًا وما يُباع بخسارة.';

  @override
  String get reportDiscountAuditTitle => 'الخصومات والإلغاءات';

  @override
  String get reportDiscountAuditSubtitle =>
      'ما مُنح من خصومات وما أُلغي أو رُدّ، ومن قام به.';

  @override
  String get reportSalesByStaffTitle => 'المبيعات حسب الموظف والساعة';

  @override
  String get reportSalesByStaffSubtitle =>
      'من باع ماذا، ومتى يكون المتجر مزدحمًا.';

  @override
  String get reportMonthEndPackTitle => 'حزمة إقفال الشهر';

  @override
  String get reportMonthEndPackSubtitle => 'كل قوائم الإقفال في مستند واحد.';

  @override
  String get reportPeriodLastMonth => 'الشهر الماضي';

  @override
  String get reportPeriodQuarter => 'الربع الحالي';

  @override
  String get reportPeriodLastQuarter => 'الربع الماضي';

  @override
  String get reportPeriodYear => 'السنة المالية';

  @override
  String get reportPeriodLastYear => 'السنة الماضية';

  @override
  String get reportPeriodYesterday => 'أمس';

  @override
  String get reportComparisonTitle => 'المقارنة';

  @override
  String get reportComparisonNone => 'بدون';

  @override
  String get reportComparisonPreviousPeriod => 'الفترة السابقة';

  @override
  String get reportComparisonPreviousYear => 'العام السابق';

  @override
  String get reportResultsTitle => 'النتيجة';

  @override
  String get reportResultsEmpty => 'شغّل التقرير لعرض النتيجة.';

  @override
  String get reportRunAction => 'عرض التقرير';

  @override
  String get reportExportCsvAction => 'تصدير Excel/CSV';

  @override
  String reportCsvSavedMessage(String location) {
    return 'تم حفظ الملف: $location';
  }

  @override
  String get reportCsvCanceledMessage => 'أُلغي الحفظ.';

  @override
  String get reportHistoryTitle => 'التقارير السابقة';

  @override
  String get reportHistoryEmpty => 'لا توجد تقارير محفوظة بعد.';

  @override
  String get reportHistoryVerifyAction => 'تحقّق من الأرقام';

  @override
  String get reportVerifyMatchMessage => 'الأرقام لم تتغير منذ إصدار التقرير.';

  @override
  String reportVerifyChangedMessage(String count) {
    return 'تغيّرت $count من الأرقام منذ إصدار التقرير.';
  }

  @override
  String reportTruncatedNotice(String shown, String total) {
    return 'معروض $shown من $total صفًا.';
  }

  @override
  String get reportTotalsShownLabel => 'إجمالي المعروض';

  @override
  String get reportTotalsFullLabel => 'إجمالي كل الصفوف';

  @override
  String get reportNotesTitle => 'تعريفات وملاحظات';

  @override
  String get reportPeriodLockTitle => 'إقفال الفترة';

  @override
  String get reportPeriodLockOpen => 'الدفاتر مفتوحة — لم تُقفل أي فترة بعد.';

  @override
  String reportPeriodLockClosedThrough(String date) {
    return 'الدفاتر مقفلة حتى $date.';
  }

  @override
  String get reportPeriodLockCloseAction => 'أقفل حتى تاريخ…';

  @override
  String get reportPeriodLockReopenAction => 'إعادة فتح…';

  @override
  String get reportPeriodLockReopenWarning =>
      'إعادة الفتح تسمح بتغيير أرقام سبق إصدارها. هل تريد المتابعة؟';

  @override
  String get reportPeriodLockSavedMessage => 'تم تحديث إقفال الفترة.';

  @override
  String get reportSelectCustomerLabel => 'اختر العميل';

  @override
  String get reportSelectSupplierLabel => 'اختر المورد';

  @override
  String get reportPartyRequiredMessage => 'اختر الجهة أولًا لعرض الكشف.';

  @override
  String get reportResultStaleMessage =>
      'الإعدادات تغيّرت منذ إنشاء هذه النتيجة — أعد التشغيل قبل الطباعة.';

  @override
  String get reportSectionEmpty => 'لا توجد بيانات في هذا القسم.';

  @override
  String get reportPeriodOpenChip => 'فترة مفتوحة';

  @override
  String get reportPeriodClosedChip => 'فترة مقفلة';

  @override
  String reportTruncatedChip(String count) {
    return '$count صفًا غير معروض';
  }

  @override
  String get reportAsOfChip => 'بتاريخ محدد';

  @override
  String get reportAccountingCalendarTitle => 'التقويم المحاسبي';

  @override
  String get reportFiscalYearStartLabel => 'بداية السنة المالية';

  @override
  String get reportFiscalYearStartAction => 'تغيير بداية السنة';

  @override
  String get reportFiscalYearSavedMessage => 'تم تحديث بداية السنة المالية.';

  @override
  String reportOpenDocumentPrompt(String reference) {
    return 'افتح المستند رقم $reference واعرض تفاصيله.';
  }

  @override
  String get reportMonthEndSnapshotLabel => 'لقطة إقفال الشهر';

  @override
  String get reportMonthEndSnapshotOff => 'متوقفة';

  @override
  String reportMonthEndSnapshotOnDay(String day) {
    return 'يوم $day من كل شهر';
  }

  @override
  String get reportA4Chip => 'A4';

  @override
  String get reportArchiveChip => 'أرشفة';

  @override
  String get reportAuditableChip => 'قابل للتدقيق';

  @override
  String get reportPeriodTitle => 'الفترة';

  @override
  String get reportPeriodToday => 'اليوم';

  @override
  String get reportPeriodWeek => 'الأسبوع';

  @override
  String get reportPeriodMonth => 'الشهر';

  @override
  String get reportPeriodCustom => 'مخصص';

  @override
  String reportFromDateValue(String date) {
    return 'من $date';
  }

  @override
  String reportToDateValue(String date) {
    return 'إلى $date';
  }

  @override
  String reportDateRangeValue(String start, String end) {
    return '$start - $end';
  }

  @override
  String get reportGranularityTitle => 'التفصيل';

  @override
  String get reportGranularitySummary => 'ملخص';

  @override
  String get reportGranularityDaily => 'يومي';

  @override
  String get reportGranularityDetailed => 'تفصيلي';

  @override
  String get reportArchiveOptionsTitle => 'الأرشفة';

  @override
  String get reportIncludeAuditTrailLabel => 'إضافة سجل التدقيق';

  @override
  String get reportIncludePreparedByLabel => 'إظهار معد التقرير والتاريخ';

  @override
  String get reportOutputTitle => 'الإخراج';

  @override
  String get reportPreviewPdfAction => 'معاينة PDF';

  @override
  String get reportPdfPreviewTitle => 'معاينة التقرير';

  @override
  String get reportPrintAction => 'طباعة';

  @override
  String get reportExportArchiveAction => 'حفظ للأرشيف';

  @override
  String reportSelectedSummary(String range, String granularity) {
    return 'الفترة: $range، التفصيل: $granularity';
  }

  @override
  String reportActionPlaceholder(String action, String report) {
    return '$action غير موصول بعد لتقرير $report.';
  }

  @override
  String reportActionInProgress(String action) {
    return 'جارٍ تنفيذ $action...';
  }

  @override
  String reportActionError(String action) {
    return 'تعذر تنفيذ $action. حاول مرة أخرى.';
  }

  @override
  String get reportGenerationError => 'تعذر إنشاء التقرير.';

  @override
  String get reportPrintQueuedMessage => 'تم إرسال التقرير للطباعة.';

  @override
  String get reportArchiveSharedMessage => 'تم تجهيز نسخة الأرشيف.';

  @override
  String get dashboardTitle => 'لوحة التحكم';

  @override
  String get dashboardOverviewTitle => 'نظرة تشغيلية';

  @override
  String get refreshDashboardTooltip => 'تحديث لوحة التحكم';

  @override
  String get dashboardLoadError => 'تعذر تحميل لوحة التحكم.';

  @override
  String get dashboardEmptyState => 'لا توجد مؤشرات متاحة لهذا المستخدم.';

  @override
  String get dashboardNoWidgetData => 'لا توجد بيانات لهذا المؤشر.';

  @override
  String dashboardLastUpdated(String value) {
    return 'آخر تحديث: $value';
  }

  @override
  String get dashboardLastUpdatedUnknown => 'آخر تحديث غير معروف';

  @override
  String get dashboardRange7Days => '٧ أيام';

  @override
  String get dashboardRange30Days => '٣٠ يومًا';

  @override
  String get dashboardRange90Days => '٩٠ يومًا';

  @override
  String get dashboardSalesSectionTitle => 'المبيعات';

  @override
  String get dashboardPaymentsSectionTitle => 'المدفوعات';

  @override
  String get dashboardInventorySectionTitle => 'المخزون';

  @override
  String get dashboardPurchasingSectionTitle => 'المشتريات';

  @override
  String get dashboardCustomersSectionTitle => 'العملاء';

  @override
  String get dashboardDiscountsSectionTitle => 'الخصومات';

  @override
  String get dashboardPrintingSectionTitle => 'الطباعة';

  @override
  String get dashboardNetSalesMetric => 'صافي المبيعات';

  @override
  String get dashboardGrossProfitMetric => 'الربح الإجمالي';

  @override
  String get dashboardProfitMarginMetric => 'هامش الربح';

  @override
  String get dashboardOrdersMetric => 'الطلبات';

  @override
  String get dashboardAverageOrderMetric => 'متوسط الطلب';

  @override
  String get dashboardItemsSoldMetric => 'القطع المباعة';

  @override
  String get dashboardDiscountsMetric => 'الخصومات';

  @override
  String get dashboardRefundsMetric => 'المرتجعات';

  @override
  String dashboardAdjustmentsDetail(int voids, int returns) {
    return 'إلغاء $voids، إرجاع $returns';
  }

  @override
  String get dashboardSpecialDayMessage => 'يعرف دفتر أن اليوم مناسبة خاصة 🎉';

  @override
  String get dashboardSalesTrendTitle => 'اتجاه صافي المبيعات';

  @override
  String get dashboardHourlySalesTitle => 'المبيعات حسب الساعة';

  @override
  String get dashboardTopProductsTitle => 'أفضل المنتجات';

  @override
  String get dashboardTopCategoriesTitle => 'أفضل التصنيفات';

  @override
  String get dashboardRecentOrdersTitle => 'آخر الطلبات';

  @override
  String get dashboardRegistersTitle => 'جلسات الدرج';

  @override
  String get dashboardOpenRegistersLabel => 'جلسات مفتوحة';

  @override
  String get dashboardClosedRegistersLabel => 'جلسات مغلقة';

  @override
  String get dashboardVarianceRegistersLabel => 'فروقات نقدية';

  @override
  String get dashboardPaymentsTotalMetric => 'إجمالي المدفوعات';

  @override
  String get dashboardPaymentCountMetric => 'عدد المدفوعات';

  @override
  String get dashboardCommissionMetric => 'العمولات';

  @override
  String get dashboardPaymentMixTitle => 'توزيع طرق الدفع';

  @override
  String get dashboardPaymentMethodsTitle => 'طرق الدفع';

  @override
  String dashboardPaymentMethodCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count دفعات',
      two: 'دفعتان',
      one: 'دفعة واحدة',
      zero: 'لا مدفوعات',
    );
    return '$_temp0';
  }

  @override
  String get dashboardProductsMetric => 'المنتجات';

  @override
  String get dashboardLowStockMetric => 'مخزون منخفض';

  @override
  String get dashboardOutOfStockMetric => 'نافد';

  @override
  String get dashboardRetailStockValueMetric => 'قيمة المخزون بسعر البيع';

  @override
  String get dashboardCommittedUnitsMetric => 'محجوز';

  @override
  String get dashboardExpectedUnitsMetric => 'متوقع';

  @override
  String get dashboardLowStockTitle => 'تنبيهات المخزون المنخفض';

  @override
  String get dashboardDustyInventoryTitle => 'مخزون راكد';

  @override
  String get dashboardStockMovementMixTitle => 'حركات المخزون';

  @override
  String get dashboardRecentStockMovementsTitle => 'آخر حركات المخزون';

  @override
  String dashboardStockItemSubtitle(
    String sku,
    int reorderLevel,
    int expected,
  ) {
    return '$sku، حد الطلب $reorderLevel، المتوقع $expected';
  }

  @override
  String get dashboardPurchasesMetric => 'قيمة المشتريات';

  @override
  String get dashboardDueToSuppliersMetric => 'مستحق للموردين';

  @override
  String get dashboardOpenPurchasesMetric => 'أوامر مفتوحة';

  @override
  String get dashboardOverduePurchasesMetric => 'متأخرة';

  @override
  String get dashboardPurchaseStatusTitle => 'حالات أوامر الشراء';

  @override
  String get dashboardOverduePurchasesTitle => 'مشتريات متأخرة';

  @override
  String get dashboardSupplierBalancesTitle => 'أرصدة الموردين';

  @override
  String get dashboardActiveCustomersMetric => 'عملاء نشطون';

  @override
  String get dashboardNewCustomersMetric => 'عملاء جدد';

  @override
  String get dashboardCustomersWithSalesMetric => 'عملاء اشتروا';

  @override
  String get dashboardRepeatCustomersMetric => 'عملاء متكررون';

  @override
  String get dashboardMarketingConsentMetric => 'موافقات تسويقية';

  @override
  String get dashboardTopCustomersTitle => 'أفضل العملاء';

  @override
  String get dashboardRecentCustomersTitle => 'عملاء مضافون حديثًا';

  @override
  String get dashboardActiveDiscountsMetric => 'خصومات نشطة';

  @override
  String get dashboardCouponDiscountsMetric => 'كوبونات';

  @override
  String get dashboardRedemptionsMetric => 'استخدامات الخصم';

  @override
  String get dashboardSalesDiscountMetric => 'خصومات المبيعات';

  @override
  String get dashboardPurchaseDiscountMetric => 'خصومات المشتريات';

  @override
  String get dashboardTopDiscountsTitle => 'أكثر الخصومات استخدامًا';

  @override
  String get dashboardExpiringDiscountsTitle => 'خصومات تنتهي قريبًا';

  @override
  String get dashboardQueuedPrintJobsMetric => 'طباعة في الانتظار';

  @override
  String get dashboardClaimedPrintJobsMetric => 'طباعة قيد التنفيذ';

  @override
  String get dashboardFailedPrintJobsMetric => 'فشل الطباعة';

  @override
  String get dashboardActivePrintAgentsMetric => 'وكلاء نشطون';

  @override
  String get dashboardStalePrintAgentsMetric => 'وكلاء غير متصلين';

  @override
  String get dashboardPrintStatusTitle => 'حالات الطباعة';

  @override
  String get dashboardPrintFailuresTitle => 'أخطاء الطباعة';

  @override
  String get dashboardPrintStatusQueued => 'بالانتظار';

  @override
  String get dashboardPrintStatusClaimed => 'قيد التنفيذ';

  @override
  String get dashboardPrintStatusPrinted => 'مطبوعة';

  @override
  String get dashboardPrintStatusFailed => 'فاشلة';

  @override
  String get dashboardPrintStatusCanceled => 'ملغاة';

  @override
  String get dashboardOrderStatusOpen => 'مفتوح';

  @override
  String get dashboardOrderStatusPaid => 'مدفوع';

  @override
  String get dashboardOrderStatusVoid => 'ملغى';

  @override
  String get dashboardUncategorizedLabel => 'غير مصنف';

  @override
  String get dashboardAnonymousCustomerLabel => 'عميل غير محدد';

  @override
  String dashboardQuantityWithSku(int quantity, String sku) {
    return '$quantity قطعة، $sku';
  }

  @override
  String dashboardQuantityOnly(int quantity) {
    return '$quantity قطعة';
  }

  @override
  String get smartNotificationsTooltip => 'التنبيهات الذكية';

  @override
  String smartNotificationsTooltipWithCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count تنبيهات ذكية',
      two: 'تنبيهان ذكيان',
      one: 'تنبيه ذكي واحد',
      zero: 'التنبيهات الذكية',
    );
    return '$_temp0';
  }

  @override
  String get smartNotificationsTitle => 'التنبيهات الذكية';

  @override
  String smartNotificationsActiveCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count تنبيهات نشطة',
      two: 'تنبيهان نشطان',
      one: 'تنبيه نشط واحد',
      zero: 'لا توجد تنبيهات نشطة',
    );
    return '$_temp0';
  }

  @override
  String smartNotificationsLastUpdated(String value) {
    return 'آخر فحص: $value';
  }

  @override
  String get smartNotificationsRefreshTooltip => 'تحديث التنبيهات';

  @override
  String get smartNotificationsRestoreTooltip => 'إظهار التنبيهات المخفية';

  @override
  String get smartNotificationsLoadError => 'تعذر تحميل التنبيهات الذكية.';

  @override
  String get smartNotificationsEmptyTitle => 'الأمور المهمة تحت السيطرة';

  @override
  String get smartNotificationsEmptyMessage =>
      'سنظهر هنا فقط ما يحتاج انتباهًا فعليًا.';

  @override
  String get smartNotificationsHiddenOnlyTitle => 'كل التنبيهات الحالية مخفية';

  @override
  String get smartNotificationsHiddenOnlyMessage =>
      'يمكنك إظهارها مرة أخرى إذا أردت مراجعتها.';

  @override
  String get smartNotificationsRestoreHiddenButton => 'إظهار المخفية';

  @override
  String get smartNotificationsDismissAllButton => 'إخفاء التنبيهات الحالية';

  @override
  String get smartNotificationDismissTooltip => 'إخفاء التنبيه';

  @override
  String get smartNotificationSnoozeAction => 'تأجيل ٤ ساعات';

  @override
  String get smartNotificationReviewAction => 'مراجعة';

  @override
  String get smartNotificationSeverityCritical => 'حرج';

  @override
  String get smartNotificationSeverityWarning => 'مهم';

  @override
  String get smartNotificationSeverityInfo => 'متابعة';

  @override
  String get smartNotificationCategoryInventory => 'المخزون';

  @override
  String get smartNotificationCategoryPurchasing => 'المشتريات';

  @override
  String get smartNotificationCategoryPrinting => 'الطباعة';

  @override
  String get smartNotificationCategorySales => 'المبيعات';

  @override
  String get smartNotificationCategoryFraud => 'مراجعة الاشتباه';

  @override
  String get smartNotificationCategoryDiscounts => 'الخصومات';

  @override
  String get smartNotificationCategoryOperations => 'التشغيل';

  @override
  String get smartNotificationStockUntrustedTitle => 'أرصدة المخزون غير موثوقة';

  @override
  String smartNotificationStockUntrustedMessage(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count أصناف أرصدتها بالسالب — بيعت دون أن تُستلم. راجع الجرد قبل الاعتماد على أرقام المخزون.',
      two:
          'صنفان رصيدهما بالسالب — بيعا دون أن يُستلما. راجع الجرد قبل الاعتماد على أرقام المخزون.',
      one:
          'صنف واحد رصيده بالسالب — بيع دون أن يُستلم. راجع الجرد قبل الاعتماد على أرقام المخزون.',
    );
    return '$_temp0';
  }

  @override
  String get smartNotificationOutOfStockTitle => 'منتجات نافدة تحتاج إجراء';

  @override
  String smartNotificationOutOfStockMessage(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count منتجات غير متاحة للبيع الآن.',
      two: 'منتجان غير متاحين للبيع الآن.',
      one: 'منتج واحد غير متاح للبيع الآن.',
    );
    return '$_temp0';
  }

  @override
  String get smartNotificationLowStockTitle => 'مخزون منخفض';

  @override
  String smartNotificationLowStockMessage(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count منتجات وصلت إلى حد إعادة الطلب.',
      two: 'منتجان وصلا إلى حد إعادة الطلب.',
      one: 'منتج واحد وصل إلى حد إعادة الطلب.',
    );
    return '$_temp0';
  }

  @override
  String get smartNotificationExpiringStockTitle => 'مخزون يقترب من الانتهاء';

  @override
  String smartNotificationExpiringStockMessage(num count, int days) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count دفعات مخزون تحتاج متابعة، أقربها خلال $days يوم.',
      two: 'دفعتا مخزون تحتاجان متابعة، أقربهما خلال $days يوم.',
      one: 'دفعة مخزون واحدة تحتاج متابعة خلال $days يوم.',
    );
    return '$_temp0';
  }

  @override
  String smartNotificationStockDetail(
    String name,
    int quantity,
    int threshold,
  ) {
    return '$name: المتاح $quantity، حد الطلب $threshold';
  }

  @override
  String smartNotificationExpiringStockDetailBasic(
    String name,
    int quantity,
    String date,
  ) {
    return '$name: المتبقي $quantity، تاريخ الانتهاء $date';
  }

  @override
  String smartNotificationExpiringStockDetail(
    String name,
    int quantity,
    String date,
    String context,
  ) {
    return '$name: المتبقي $quantity، تاريخ الانتهاء $date، المرجع $context';
  }

  @override
  String get smartNotificationDustyInventoryTitle => 'مخزون راكد يحتاج مراجعة';

  @override
  String smartNotificationDustyInventoryMessage(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count منتجات متوفرة ولم تتحرك خلال الفترة.',
      two: 'منتجان متوفران ولم يتحركا خلال الفترة.',
      one: 'منتج واحد متوفر ولم يتحرك خلال الفترة.',
    );
    return '$_temp0';
  }

  @override
  String smartNotificationDustyInventoryDetail(String name, int quantity) {
    return '$name: $quantity قطعة متاحة';
  }

  @override
  String get smartNotificationOverduePurchasesTitle => 'مستحقات شراء متأخرة';

  @override
  String smartNotificationOverduePurchasesMessage(num count, String amount) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count أوامر شراء متأخرة، أقرب رصيد $amount.',
      two: 'أمرا شراء متأخران، أقرب رصيد $amount.',
      one: 'أمر شراء واحد متأخر بقيمة $amount.',
    );
    return '$_temp0';
  }

  @override
  String smartNotificationOverduePurchaseDetail(String order, String supplier) {
    return '$order لدى $supplier';
  }

  @override
  String get smartNotificationPrintFailuresTitle => 'فشل في الطباعة';

  @override
  String smartNotificationPrintFailuresMessage(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count مهام طباعة فشلت وتحتاج متابعة.',
      two: 'مهمتا طباعة فشلتا وتحتاجان متابعة.',
      one: 'مهمة طباعة واحدة فشلت وتحتاج متابعة.',
    );
    return '$_temp0';
  }

  @override
  String get smartNotificationStalePrintAgentsTitle => 'وكلاء طباعة غير متصلين';

  @override
  String smartNotificationStalePrintAgentsMessage(num agents, int queued) {
    String _temp0 = intl.Intl.pluralLogic(
      agents,
      locale: localeName,
      other: '$agents وكلاء طباعة غير متصلين، و$queued مهمة في الانتظار.',
      two: 'وكيلا طباعة غير متصلين، و$queued مهمة في الانتظار.',
      one: 'وكيل طباعة واحد غير متصل، و$queued مهمة في الانتظار.',
    );
    return '$_temp0';
  }

  @override
  String get smartNotificationSuspectedActivityTitle =>
      'نشاط مشتبه يحتاج مراجعة';

  @override
  String smartNotificationSuspectedActivityMessage(String user, int score) {
    return 'النظام لاحظ نمطًا مشتبهًا لدى $user بدرجة $score. هذه مراجعة أولية وليست حكمًا نهائيًا.';
  }

  @override
  String get smartNotificationRegisterVarianceTitle => 'فروقات نقدية في الدرج';

  @override
  String smartNotificationRegisterVarianceMessage(num count, String amount) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count جلسات درج فيها فرق نقدي، الإجمالي $amount.',
      two: 'جلستا درج فيهما فرق نقدي، الإجمالي $amount.',
      one: 'جلسة درج واحدة فيها فرق نقدي بقيمة $amount.',
    );
    return '$_temp0';
  }

  @override
  String get smartNotificationSalesDropTitle => 'انخفاض واضح في المبيعات';

  @override
  String smartNotificationSalesDropMessage(int days, String percent) {
    return 'صافي المبيعات أقل بنسبة $percent% خلال آخر $days يومًا مقارنة بالفترة السابقة.';
  }

  @override
  String get smartNotificationLowProfitMarginTitle => 'بيع بهامش سلبي';

  @override
  String smartNotificationLowProfitMarginMessage(
    String percent,
    String amount,
  ) {
    return 'الهامش سلبي بنسبة $percent%، والفرق التقريبي $amount.';
  }

  @override
  String get smartNotificationExpiringDiscountsTitle => 'خصومات تنتهي قريبًا';

  @override
  String smartNotificationExpiringDiscountsMessage(num count, int days) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count خصومات تنتهي قريبًا، أقربها خلال $days يوم.',
      two: 'خصمان ينتهيان قريبًا، أقربهما خلال $days يوم.',
      one: 'خصم واحد ينتهي خلال $days يوم.',
    );
    return '$_temp0';
  }

  @override
  String smartNotificationDiscountDetail(String name) {
    return '$name';
  }

  @override
  String get smartNotificationPayrollReadyTitle => 'مسودة رواتب جاهزة للاعتماد';

  @override
  String smartNotificationPayrollReadyMessage(num count, String amount) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'مسودة رواتب لـ $count موظفين جاهزة بإجمالي $amount.',
      two: 'مسودة رواتب لموظفين جاهزة بإجمالي $amount.',
      one: 'مسودة راتب لموظف واحد جاهزة بإجمالي $amount.',
    );
    return '$_temp0';
  }

  @override
  String smartNotificationPayrollReadyDetail(
    String runNumber,
    String start,
    String end,
  ) {
    return '$runNumber: من $start إلى $end';
  }

  @override
  String get smartNotificationOperationsErrorTitle => 'خطأ تشغيلي يحتاج متابعة';

  @override
  String smartNotificationOperationsErrorMessage(String name, String source) {
    return '$name من $source';
  }

  @override
  String get smartNotificationUnknownTitle => 'تنبيه جديد';

  @override
  String get smartNotificationUnknownMessage => 'يوجد تنبيه يحتاج مراجعة.';

  @override
  String dashboardOrderCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count طلبات',
      two: 'طلبان',
      one: 'طلب واحد',
      zero: 'لا طلبات',
    );
    return '$_temp0';
  }

  @override
  String get stockMovementExpected => 'متوقع';

  @override
  String get stockMovementReceiveExpected => 'استلام المتوقع';

  @override
  String get stockMovementReceiveDamaged => 'استلام تالف';

  @override
  String get stockMovementCancelExpected => 'إلغاء المتوقع';

  @override
  String get logoutButton => 'تسجيل الخروج';

  @override
  String get unauthorizedTitle => 'غير مصرح';

  @override
  String get unauthorizedMessage =>
      'لا يملك هذا المستخدم صلاحية الوصول إلى هذه الشاشة.';

  @override
  String get authCheckingSession => 'جار فحص الجلسة...';

  @override
  String get onboardingTitle => 'إعداد نقطة البيع';

  @override
  String get onboardingIntro => 'أنشئ حساب المدير الأول للمتجر.';

  @override
  String get onboardingAdminSectionTitle => 'حساب المدير';

  @override
  String get onboardingCreateAdminButton => 'إنشاء المدير';

  @override
  String get onboardingCreatingAdminButton => 'جار إنشاء المدير...';

  @override
  String get onboardingCreateAdminError =>
      'تعذر إنشاء المدير. تحقق من البيانات وقوة كلمة المرور ثم حاول مرة أخرى.';

  @override
  String get loginTitle => 'تسجيل الدخول';

  @override
  String get usernameLabel => 'اسم المستخدم';

  @override
  String get passwordLabel => 'كلمة المرور';

  @override
  String get showPasswordTooltip => 'إظهار كلمة المرور';

  @override
  String get hidePasswordTooltip => 'إخفاء كلمة المرور';

  @override
  String get loginButton => 'دخول';

  @override
  String get loggingInButton => 'جار الدخول...';

  @override
  String get loginError =>
      'تعذر تسجيل الدخول. تحقق من اسم المستخدم وكلمة المرور.';

  @override
  String get managerRoleLabel => 'مدير';

  @override
  String get cashierRoleLabel => 'كاشير';

  @override
  String get usersManagementTitle => 'إدارة المستخدمين';

  @override
  String get supervisorRoleLabel => 'مشرف';

  @override
  String get auditorRoleLabel => 'مدقق';

  @override
  String get purchasingAgentRoleLabel => 'مسؤول المشتريات';

  @override
  String get inventoryClerkRoleLabel => 'أمين المخزن';

  @override
  String get managerRoleDescription =>
      'صلاحية كاملة على كل أقسام النظام والإعدادات.';

  @override
  String get supervisorRoleDescription =>
      'إشراف على المبيعات والمخزون والمشتريات والتقارير على مستوى المتجر، دون إدارة المستخدمين أو الإعدادات أو اعتماد الرواتب.';

  @override
  String get accountantRoleDescription =>
      'المالية والرواتب والسلف والمصروفات والتقارير.';

  @override
  String get auditorRoleDescription =>
      'اطّلاع فقط على المبيعات والتقارير والمخزون والمشتريات دون أي تعديل.';

  @override
  String get purchasingAgentRoleDescription =>
      'إدارة دورة أوامر الشراء كاملة والموردين.';

  @override
  String get inventoryClerkRoleDescription =>
      'إدارة المخزون والجرد واستلام المشتريات.';

  @override
  String get technicianRoleDescription =>
      'تنفيذ أوامر الصيانة والتصنيع ومتابعة العملاء.';

  @override
  String get cashierRoleDescription =>
      'البيع عبر نقطة البيع وإدارة وردية الصندوق.';

  @override
  String get usersSearchHint => 'ابحث عن مستخدم';

  @override
  String get roleFilterAllLabel => 'كل الأدوار';

  @override
  String get usersTotalMetric => 'إجمالي المستخدمين';

  @override
  String get usersActiveMetric => 'النشطون';

  @override
  String get usersCustomPermissionsMetric => 'صلاحيات مخصصة';

  @override
  String usersCustomPermissionsBadge(int count) {
    return '$count مخصصة';
  }

  @override
  String get usersNoMatches => 'لا يوجد مستخدمون مطابقون';

  @override
  String get userActionsTooltip => 'إجراءات';

  @override
  String get userEditAction => 'تعديل';

  @override
  String get userManagePermissionsAction => 'الصلاحيات';

  @override
  String get userActivateAction => 'تفعيل';

  @override
  String get userDeactivateAction => 'تعطيل';

  @override
  String get userEditTitle => 'تعديل المستخدم';

  @override
  String get passwordResetLabel =>
      'كلمة مرور جديدة (اتركها فارغة لعدم التغيير)';

  @override
  String get userEditSelfRoleLocked =>
      'لا يمكنك تغيير دورك أو تعطيل حسابك بنفسك.';

  @override
  String get userManagePermissionsLinkTitle => 'الصلاحيات الإضافية';

  @override
  String get userManagePermissionsLinkSubtitle =>
      'منح صلاحيات فوق صلاحيات الدور';

  @override
  String get updateUserError => 'تعذّر تحديث المستخدم';

  @override
  String userPermissionsTitle(String user) {
    return 'صلاحيات $user';
  }

  @override
  String get permissionsLoadError => 'تعذّر تحميل الصلاحيات';

  @override
  String get permissionsManagerHasAll =>
      'هذا المستخدم مدير ويملك جميع الصلاحيات.';

  @override
  String permissionsSummaryInheritedExtra(int inherited, int extra) {
    return '$inherited من الدور • $extra مخصصة';
  }

  @override
  String get permissionsSearchHint => 'ابحث في الصلاحيات';

  @override
  String get permissionsEmpty => 'لا توجد صلاحيات مطابقة';

  @override
  String get permissionsSelectGroup => 'تحديد الكل';

  @override
  String get permissionsClearGroup => 'إلغاء التحديد';

  @override
  String get permissionsInheritedFromRole => 'من الدور';

  @override
  String get permissionsNeedsHigherPermission => 'تحتاج صلاحية أعلى';

  @override
  String get permissionsSaveError => 'تعذّر حفظ الصلاحيات';

  @override
  String get permissionsSaveButton => 'حفظ الصلاحيات';

  @override
  String get permissionsSavedMessage => 'تم تحديث الصلاحيات';

  @override
  String get userPermissionsSectionTitle => 'الصلاحيات';

  @override
  String get userEditPermissionsAction => 'تعديل';

  @override
  String userPermissionsInheritedCount(int count) {
    return '$count من الدور';
  }

  @override
  String userPermissionsExtraCount(int count) {
    return '$count مخصصة';
  }

  @override
  String get userPermissionsNoExtras =>
      'لا توجد صلاحيات إضافية مخصصة لهذا المستخدم.';

  @override
  String get refreshUsersTooltip => 'تحديث المستخدمين';

  @override
  String get addUserButton => 'إضافة مستخدم';

  @override
  String get userCreateTitle => 'مستخدم جديد';

  @override
  String get firstNameLabel => 'الاسم الأول';

  @override
  String get lastNameLabel => 'اسم العائلة';

  @override
  String get displayNameLabel => 'الاسم المعروض';

  @override
  String get emailLabel => 'البريد الإلكتروني';

  @override
  String get currentPasswordLabel => 'كلمة المرور الحالية';

  @override
  String get newPasswordLabel => 'كلمة المرور الجديدة';

  @override
  String get confirmPasswordLabel => 'تأكيد كلمة المرور';

  @override
  String get saveChangesButton => 'حفظ التغييرات';

  @override
  String get changePasswordButton => 'تغيير كلمة المرور';

  @override
  String get passwordConfirmationMismatch => 'تأكيد كلمة المرور غير مطابق.';

  @override
  String get userSettingsTitle => 'إعداداتي';

  @override
  String get userSettingsRefreshLoansTooltip => 'تحديث طلبات السلفة';

  @override
  String get userSettingsOverviewTitle => 'إعدادات الحساب';

  @override
  String get userSettingsOverviewSubtitle =>
      'بيانات الدخول وطلبات السلفة المرتبطة بسجل الموظف';

  @override
  String get userSettingsProfileSectionTitle => 'البيانات الشخصية';

  @override
  String get userSettingsPasswordSectionTitle => 'كلمة المرور';

  @override
  String get userSettingsLoansSectionTitle => 'طلبات السلفة';

  @override
  String get userSettingsProfileSaveError =>
      'تعذر حفظ بيانات الحساب. تحقق من اسم المستخدم ثم حاول مرة أخرى.';

  @override
  String get userSettingsProfileSaved => 'تم حفظ بيانات الحساب.';

  @override
  String get userSettingsPasswordChangeError =>
      'تعذر تغيير كلمة المرور. تحقق من كلمة المرور الحالية وشروط كلمة المرور الجديدة.';

  @override
  String get userSettingsPasswordChanged => 'تم تغيير كلمة المرور.';

  @override
  String get passwordRulesTitle => 'متطلبات كلمة المرور';

  @override
  String get passwordAdviceTitle => 'لكلمة مرور أقوى (اختياري)';

  @override
  String get passwordAdviceNote => 'هذه اقتراحات فقط — يمكنك الحفظ بدونها.';

  @override
  String passwordRuleMinLength(int count) {
    return '$count خانات على الأقل';
  }

  @override
  String passwordAdviceRecommendedLength(int count) {
    return '$count خانات أو أكثر';
  }

  @override
  String get passwordAdviceNotNumeric => 'ليست أرقامًا فقط';

  @override
  String get passwordAdviceNotCommon => 'ليست كلمة مرور شائعة';

  @override
  String get passwordAdviceNotSimilarToUser => 'لا تشبه اسمك أو اسم المستخدم';

  @override
  String get passwordRuleNotCheckedYet => 'لم يُتحقق منها بعد';

  @override
  String get passwordStrengthWeak => 'مقبولة';

  @override
  String get passwordStrengthFair => 'جيدة';

  @override
  String get passwordStrengthStrong => 'قوية';

  @override
  String get passwordCurrentIncorrectError => 'كلمة المرور الحالية غير صحيحة.';

  @override
  String get passwordChangeThrottledError =>
      'محاولات كثيرة خلال وقت قصير. انتظر قليلًا ثم أعد المحاولة.';

  @override
  String get passwordChangeRuleRejectedError =>
      'كلمة المرور الجديدة لا تحقق المتطلبات الموضّحة أعلاه.';

  @override
  String get profileUsernameTakenError =>
      'اسم المستخدم هذا مستخدم بالفعل. اختر اسمًا آخر.';

  @override
  String get profileEmailInvalidError =>
      'أدخل بريدًا إلكترونيًا صحيحًا، أو اترك الحقل فارغًا.';

  @override
  String get profileNoChangesHint => 'لا توجد تغييرات لحفظها.';

  @override
  String get userSettingsLoansLoadError => 'تعذر تحميل طلبات السلفة.';

  @override
  String get userSettingsLoanNoEmployeeRecord =>
      'لا يوجد سجل موظف مرتبط بهذا المستخدم، لذلك لا يمكن إرسال طلب سلفة.';

  @override
  String get loanAmountLabel => 'مبلغ السلفة';

  @override
  String get loanMonthlyDeductionLabel => 'الخصم الشهري';

  @override
  String get loanPurposeLabel => 'سبب الطلب';

  @override
  String get loanMonthlyDeductionTooHigh =>
      'لا يمكن أن يكون الخصم الشهري أكبر من مبلغ السلفة.';

  @override
  String get submitLoanRequestButton => 'إرسال طلب السلفة';

  @override
  String get userSettingsLoanRequestError =>
      'تعذر إرسال طلب السلفة. راجع المبلغ والخصم الشهري ثم حاول مرة أخرى.';

  @override
  String get userSettingsLoanRequested => 'تم إرسال طلب السلفة للاعتماد.';

  @override
  String get userSettingsNoLoans => 'لا توجد طلبات سلفة بعد.';

  @override
  String get userSettingsLoanHistoryTitle => 'سجل طلبات السلفة';

  @override
  String userSettingsLoanBalanceDetail(
    String balance,
    String monthlyDeduction,
  ) {
    return 'المتبقي $balance، الخصم الشهري $monthlyDeduction';
  }

  @override
  String get roleLabel => 'الدور';

  @override
  String get activeUserLabel => 'مستخدم نشط';

  @override
  String get createUserButton => 'إنشاء المستخدم';

  @override
  String get createUserError =>
      'تعذر إنشاء المستخدم. راجع البيانات وحاول مرة أخرى.';

  @override
  String get usersLoadError => 'تعذر تحميل المستخدمين.';

  @override
  String get emptyUsers => 'لا يوجد مستخدمون بعد.';

  @override
  String get userStatusActive => 'نشط';

  @override
  String get userStatusInactive => 'متوقف';

  @override
  String get userDetailsTooltip => 'عرض تفاصيل المستخدم';

  @override
  String userDetailsTitle(String user) {
    return 'تفاصيل $user';
  }

  @override
  String get refreshUserDetailsTooltip => 'تحديث تفاصيل المستخدم';

  @override
  String get userActivityLoadError => 'تعذر تحميل نشاط المستخدم.';

  @override
  String get userDetailsOverviewTitle => 'ملخص المستخدم';

  @override
  String get userDetailsRecentSalesTitle => 'آخر فواتير العملاء';

  @override
  String get userDetailsRecentPurchasesTitle => 'آخر فواتير الموردين';

  @override
  String get userDetailsRecentSessionsTitle => 'آخر جلسات الدرج';

  @override
  String get userDetailsRecentActivityTitle => 'آخر النشاطات';

  @override
  String get userActivityNetSalesMetric => 'صافي المبيعات';

  @override
  String get userActivityCustomersMetric => 'العملاء';

  @override
  String get userActivityPurchaseTotalMetric => 'قيمة المشتريات';

  @override
  String get userActivitySupplierPaymentsMetric => 'مدفوعات الموردين';

  @override
  String get userActivityRegisterSessionsMetric => 'جلسات الدرج';

  @override
  String get userActivityCashMovementsMetric => 'صافي حركة النقد';

  @override
  String userActivityInvoicesDetail(int invoices, int paid) {
    return '$invoices فواتير، $paid مدفوعة';
  }

  @override
  String userActivityReturnsDetail(int count, String amount) {
    return '$count إرجاع، $amount';
  }

  @override
  String userActivitySupplierInvoicesDetail(int invoices, int orders) {
    return '$invoices فواتير موردين، $orders أوامر';
  }

  @override
  String userActivitySupplierPaymentsDetail(int payments, int refunds) {
    return '$payments دفعات، $refunds استرداد';
  }

  @override
  String userActivityRegisterSessionsDetail(int open, int closed) {
    return '$open مفتوحة، $closed مغلقة';
  }

  @override
  String userActivityCashMovementsDetail(String payIn, String payOut) {
    return 'إيداع $payIn، سحب $payOut';
  }

  @override
  String get userActivityEmptyRecentSales =>
      'لا توجد فواتير عملاء لهذا المستخدم.';

  @override
  String get userActivityEmptyRecentPurchases =>
      'لا توجد فواتير موردين لهذا المستخدم.';

  @override
  String get userActivityEmptyRecentSessions =>
      'لا توجد جلسات درج لهذا المستخدم.';

  @override
  String get userActivityEmptyRecentActivity =>
      'لا يوجد نشاط مسجل لهذا المستخدم.';

  @override
  String userActivityReceiptFallback(int id) {
    return 'فاتورة #$id';
  }

  @override
  String userActivityPurchaseFallback(int id) {
    return 'أمر شراء #$id';
  }

  @override
  String userActivitySessionFallback(int id) {
    return 'جلسة درج #$id';
  }

  @override
  String get userActivityEventLogin => 'تسجيل دخول ناجح';

  @override
  String get userActivityEventRegisterStarted => 'بدء جلسة درج';

  @override
  String get userActivityEventRegisterClosed => 'إغلاق جلسة درج';

  @override
  String get userActivityEventCashMovement => 'حركة نقدية في الدرج';

  @override
  String get userActivityEventUserCreated => 'إنشاء مستخدم';

  @override
  String get userActivityEventUserUpdated => 'تعديل مستخدم';

  @override
  String get userActivityEventUserDeleted => 'حذف مستخدم';

  @override
  String get userActivityEventFallback => 'نشاط مسجل';

  @override
  String get userActivityEventTypeSecurity => 'أمان';

  @override
  String get userActivityEventTypeAudit => 'تدقيق';

  @override
  String get userActivityEventTypeError => 'خطأ';

  @override
  String get userActivityEventTypePerformance => 'أداء';

  @override
  String get userActivityEventTypeUsage => 'استخدام';

  @override
  String get shopSettingsTitle => 'إعدادات المتجر';

  @override
  String get refreshShopSettingsTooltip => 'تحديث إعدادات المتجر';

  @override
  String get shopSettingsLoadError => 'تعذر تحميل إعدادات المتجر.';

  @override
  String get shopSettingsSaveError =>
      'تعذر حفظ إعدادات المتجر. راجع البيانات وحاول مرة أخرى.';

  @override
  String get shopSettingsSavedMessage => 'تم حفظ إعدادات المتجر.';

  @override
  String get deviceSettingsTitle => 'إعدادات الجهاز';

  @override
  String get refreshDeviceSettingsTooltip => 'تحديث إعدادات الجهاز';

  @override
  String get deviceSettingsLoadError => 'تعذر تحميل إعدادات الجهاز المحلية.';

  @override
  String get deviceSettingsSaveError => 'تعذر حفظ إعدادات الجهاز المحلية.';

  @override
  String get deviceUsageSectionTitle => 'استخدام الجهاز';

  @override
  String get deviceUsageSingleUserTitle => 'مستخدم واحد';

  @override
  String get deviceUsageSingleUserDescription =>
      'يفتح التطبيق بنفس الجلسة المحفوظة عند تشغيله مرة أخرى.';

  @override
  String get deviceUsageMultiUserTitle => 'عدة مستخدمين';

  @override
  String get deviceUsageMultiUserDescription =>
      'ينسى الجهاز المستخدم المسجل عند فتح التطبيق ويطلب تسجيل الدخول كل مرة.';

  @override
  String get appearanceSectionTitle => 'المظهر';

  @override
  String get appearanceSectionSubtitle =>
      'يُحفظ هذا الاختيار على هذا الجهاز فقط، مناسب للمتاجر ذات الإضاءة المنخفضة.';

  @override
  String get themeModeLight => 'فاتح';

  @override
  String get themeModeDark => 'داكن';

  @override
  String get themeModeSystem => 'تلقائي';

  @override
  String get themeModeSystemHint => 'يتبع إعداد النظام';

  @override
  String get appearanceToggleTooltip => 'تبديل بين الفاتح والداكن';

  @override
  String get switchToDarkAction => 'التبديل إلى الوضع الداكن';

  @override
  String get switchToLightAction => 'التبديل إلى الوضع الفاتح';

  @override
  String get shopSetupTitle => 'إعداد المتجر';

  @override
  String get shopSetupSkip => 'تخطٍّ';

  @override
  String get shopSetupPickTypeTitle => 'ما نوع متجرك؟';

  @override
  String get shopSetupPickTypeSubtitle =>
      'نفعّل لك الإعدادات المناسبة تلقائيًا — يمكنك تغيير أي شيء لاحقًا.';

  @override
  String get shopSetupTuneTitle => 'إعدادات سريعة';

  @override
  String get shopSetupTuneSubtitle =>
      'اضبط القليل من الإعدادات الأساسية للبدء.';

  @override
  String get shopSetupFinish => 'إنهاء الإعداد';

  @override
  String get shopSetupError => 'تعذّر حفظ الإعداد، حاول مرة أخرى.';

  @override
  String get shopSetupShopNameLabel => 'اسم المتجر';

  @override
  String get shopSetupCurrencyLabel => 'العملة';

  @override
  String get shopSetupCurrencyValue => 'د.ل (دينار ليبي)';

  @override
  String get shopSetupCurrencyHint => 'دعم العملات المتعددة قادم قريبًا.';

  @override
  String get shopSetupOversellingTitle => 'السماح بالبيع رغم نفاد المخزون';

  @override
  String get shopSetupOversellingSubtitle =>
      'يسمح ببيع المنتجات غير المتوفرة في المخزون.';

  @override
  String get shopSetupOpeningCashTitle => 'طلب رصيد افتتاحي للدرج';

  @override
  String get shopSetupOpeningCashSubtitle =>
      'يطلب من الكاشير إدخال النقد الافتتاحي عند بدء جلسة الدرج.';

  @override
  String get shopSetupReceiptsTitle => 'طباعة الإيصالات تلقائيًا';

  @override
  String get shopSetupReceiptsSubtitle =>
      'يطبع إيصال العميل تلقائيًا بعد كل عملية بيع.';

  @override
  String get shopTypeGeneral => 'متجر عام';

  @override
  String get shopTypeGeneralDescription =>
      'بيع بالتجزئة بسيط دون ميزات إضافية.';

  @override
  String get shopTypeRestaurant => 'مطعم / مقهى';

  @override
  String get shopTypeRestaurantDescription =>
      'عمليات المطبخ وطباعة طلبات المطبخ والتحضير عند الطلب.';

  @override
  String get shopTypeGrocery => 'بقالة / سوبر ماركت';

  @override
  String get shopTypeGroceryDescription =>
      'وحدات قياس متعددة وتنبيهات نقص المخزون ومراقبة صارمة.';

  @override
  String get shopTypePharmacy => 'صيدلية';

  @override
  String get shopTypePharmacyDescription =>
      'مراقبة مخزون صارمة ومنع البيع بخسارة.';

  @override
  String get shopTypePhoneRepair => 'هواتف وصيانة';

  @override
  String get shopTypePhoneRepairDescription => 'عمليات الصيانة وتتبّع الأعمال.';

  @override
  String get shopTypeBakery => 'مخبز / حلويات';

  @override
  String get shopTypeBakeryDescription =>
      'عمليات المطبخ والإنتاج للتحضير المسبق.';

  @override
  String get shopTypeRetail => 'ملابس وتجزئة';

  @override
  String get shopTypeRetailDescription => 'متجر تجزئة مع مراقبة مخزون صارمة.';

  @override
  String get devicePrinterSectionTitle => 'أدوار الطباعة';

  @override
  String get shopIdentitySectionTitle => 'هوية المتجر';

  @override
  String get shopBehaviorSectionTitle => 'سلوك التطبيق';

  @override
  String get receiptSettingsSectionTitle => 'الإيصالات';

  @override
  String get registerSessionSettingsSectionTitle => 'جلسة الدرج';

  @override
  String get paymentSettingsSectionTitle => 'طرق الدفع';

  @override
  String get inventorySettingsSectionTitle => 'المخزون والربحية';

  @override
  String get analyticsExportSectionTitle => 'تصدير التتبع';

  @override
  String get salesChannelsSectionTitle => 'قنوات البيع';

  @override
  String get salesChannelsSectionSubtitle =>
      'ربط تطبيقات التوصيل والمتاجر الإلكترونية وإدارة تفويضها';

  @override
  String get salesChannelsLoadError => 'تعذر تحميل قنوات البيع.';

  @override
  String get salesChannelsEmptyMessage =>
      'لا توجد قنوات بيع خارجية بعد. أضف قناة لربط تطبيقات التوصيل أو المتاجر الإلكترونية.';

  @override
  String get salesChannelAddButton => 'إضافة قناة';

  @override
  String get salesChannelCreateTitle => 'إضافة قناة بيع';

  @override
  String get salesChannelCreateSubmit => 'إنشاء القناة';

  @override
  String get salesChannelNameLabel => 'اسم القناة';

  @override
  String get salesChannelNameRequired => 'أدخل اسم القناة.';

  @override
  String get salesChannelTypeLabel => 'نوع القناة';

  @override
  String get salesChannelNotesLabel => 'ملاحظات (اختياري)';

  @override
  String get salesChannelTypePos => 'نقطة البيع';

  @override
  String get salesChannelTypeDelivery => 'تطبيق توصيل';

  @override
  String get salesChannelTypeEcommerce => 'متجر إلكتروني';

  @override
  String get salesChannelTypeMarketplace => 'سوق إلكتروني';

  @override
  String get salesChannelTypeOther => 'أخرى';

  @override
  String get salesChannelStatusActive => 'مفوضة';

  @override
  String get salesChannelStatusInactive => 'موقوفة';

  @override
  String get salesChannelSystemBadge => 'القناة الافتراضية';

  @override
  String get salesChannelPosSubtitle =>
      'تطبيق نقطة البيع الخاص بالمتجر. يحدد الخادم هذه القناة تلقائيًا من جلسة الدخول ولا يمكن إيقافها.';

  @override
  String salesChannelKeyPrefixLabel(String prefix) {
    return 'معرف المفتاح: $prefix';
  }

  @override
  String get salesChannelDeauthorizeAction => 'إيقاف التفويض';

  @override
  String get salesChannelAuthorizeAction => 'إعادة التفويض';

  @override
  String get salesChannelDeauthorizeConfirmTitle => 'إيقاف تفويض القناة؟';

  @override
  String salesChannelDeauthorizeConfirmMessage(String name) {
    return 'سيرفض الخادم جميع طلبات «$name» فورًا حتى تتم إعادة التفويض.';
  }

  @override
  String get salesChannelRotateKeyAction => 'تدوير مفتاح الربط';

  @override
  String get salesChannelRotateKeyConfirmTitle => 'تدوير مفتاح الربط؟';

  @override
  String get salesChannelRotateKeyConfirmMessage =>
      'سيتوقف المفتاح الحالي عن العمل فورًا وسيظهر مفتاح جديد لمرة واحدة.';

  @override
  String get salesChannelDeleteAction => 'حذف القناة';

  @override
  String get salesChannelDeleteConfirmTitle => 'حذف القناة؟';

  @override
  String salesChannelDeleteConfirmMessage(String name) {
    return 'سيتم حذف «$name» نهائيًا. القنوات التي لديها فواتير مسجلة لا يمكن حذفها ويمكن إيقاف تفويضها بدلًا من ذلك.';
  }

  @override
  String get salesChannelApiKeyDialogTitle => 'مفتاح ربط القناة';

  @override
  String get salesChannelApiKeyDialogMessage =>
      'انسخ المفتاح الآن واحفظه في مكان آمن، لن يظهر مرة أخرى.';

  @override
  String get salesChannelApiKeyCopyButton => 'نسخ المفتاح';

  @override
  String get salesChannelApiKeyCopiedMessage => 'تم نسخ المفتاح.';

  @override
  String get salesChannelActionError =>
      'تعذر تنفيذ العملية على القناة. حاول مرة أخرى.';

  @override
  String get technicianRoleLabel => 'فني';

  @override
  String get navigationGroupOperations => 'العمليات';

  @override
  String get operationsDrawerLabel => 'المهام والتشغيل';

  @override
  String get jobsBoardTitle => 'المهام';

  @override
  String get refreshJobsTooltip => 'تحديث المهام';

  @override
  String get jobsLoadError => 'تعذر تحميل المهام.';

  @override
  String get operationsActionError => 'تعذر تنفيذ العملية. حاول مرة أخرى.';

  @override
  String get posWeightDialogTitle => 'أدخل الوزن';

  @override
  String get posWeightInvalid => 'أدخل وزنًا أكبر من صفر.';

  @override
  String get posQuantityInvalid => 'أدخل كمية أكبر من صفر.';

  @override
  String get posUnitSelectLabel => 'الوحدة';

  @override
  String get posUnitQuantityLabel => 'الكمية';

  @override
  String posUnitSheetAdd(String total) {
    return 'إضافة · $total';
  }

  @override
  String get posCartSwitchUnitTooltip => 'تغيير الوحدة';

  @override
  String get cartEditWeightTooltip => 'تعديل الوزن';

  @override
  String saleReturnQuantityHint(String quantity) {
    return 'الكمية القابلة للإرجاع: $quantity';
  }

  @override
  String get unitPiece => 'قطعة';

  @override
  String get unitKilogram => 'كجم';

  @override
  String get unitGram => 'جم';

  @override
  String get unitLiter => 'لتر';

  @override
  String get unitMilliliter => 'مل';

  @override
  String get unitDozen => 'دزينة';

  @override
  String get unitPair => 'زوج';

  @override
  String get unitPack => 'عبوة';

  @override
  String get unitBox => 'صندوق';

  @override
  String get unitCarton => 'كرتون';

  @override
  String get unitBag => 'كيس';

  @override
  String get unitTon => 'طن';

  @override
  String get unitMeter => 'متر';

  @override
  String get unitCentimeter => 'سم';

  @override
  String get productUnitLabel => 'وحدة القياس';

  @override
  String get productUnitsSectionTitle => 'الوحدات والتحويلات';

  @override
  String get productUnitsSectionDescription =>
      'أضف وحدات بيع وشراء إضافية (صندوق، كرتون، جملة) مع معامل التحويل إلى الوحدة الأساسية وسعر مخصّص اختياري لكل وحدة.';

  @override
  String get productUnitsAddButton => 'إضافة وحدة';

  @override
  String get productUnitPickLabel => 'الوحدة';

  @override
  String get productUnitRemoveTooltip => 'حذف الوحدة';

  @override
  String get productUnitPriceLabel => 'سعر مخصّص (اختياري)';

  @override
  String get productUnitPriceHelper =>
      'اتركه فارغًا ليُحتسب من سعر الوحدة الأساسية × المعامل.';

  @override
  String get productUnitSellable => 'متاح للبيع';

  @override
  String get productUnitPurchasable => 'متاح للشراء';

  @override
  String get productUnitBarcodesLabel => 'باركود الوحدة';

  @override
  String get productUnitBarcodesHelper =>
      'امسح أو اكتب باركود العبوة (الكرتون/الصندوق) ليُباع المنتج بهذه الوحدة وسعرها عند مسحه في نقطة البيع.';

  @override
  String get productUnitBarcodeAddHint => 'امسح أو اكتب الباركود';

  @override
  String get productUnitBarcodeAddTooltip => 'إضافة الباركود';

  @override
  String get productUnitBarcodeScanTooltip => 'مسح بالكاميرا';

  @override
  String get productUnitBarcodeScanTitle => 'مسح باركود الوحدة';

  @override
  String get productUnitBarcodeRemoveTooltip => 'حذف الباركود';

  @override
  String get productUnitBarcodeDuplicate =>
      'هذا الباركود مُضاف بالفعل لهذه الوحدة.';

  @override
  String productUnitBarcodeConflict(String unit) {
    return 'الباركود مُسجّل بالفعل للوحدة $unit.';
  }

  @override
  String get productDefaultSaleUnitLabel => 'وحدة البيع الافتراضية';

  @override
  String get productDefaultPurchaseUnitLabel => 'وحدة الشراء الافتراضية';

  @override
  String productUnitBaseOption(String unit) {
    return '$unit (أساسية)';
  }

  @override
  String get productUnitsLoadError => 'تعذّر تحميل الوحدات.';

  @override
  String get manageUnitsTooltip => 'إدارة وحدات القياس';

  @override
  String get moreActionsTooltip => 'إجراءات';

  @override
  String get unitsManagementTitle => 'وحدات القياس';

  @override
  String get unitsManagementIntroTitle => 'وحدات القياس';

  @override
  String get unitsManagementIntroMessage =>
      'أنشئ وحدات مخصّصة للبيع والشراء (صندوق، كرتون، جملة) وعدّل الوحدات الجاهزة. الوحدات المضمّنة لا تُحذف بل تُعطَّل.';

  @override
  String get addUnitButton => 'إضافة وحدة';

  @override
  String unitsCountLabel(int count) {
    return '$count وحدة';
  }

  @override
  String get unitsLoadError => 'تعذّر تحميل الوحدات.';

  @override
  String get unitsEmptyTitle => 'لا توجد وحدات';

  @override
  String get unitsEmptyMessage => 'أضف أول وحدة قياس للبدء.';

  @override
  String get unitDimensionCount => 'العدد';

  @override
  String get unitDimensionWeight => 'الوزن';

  @override
  String get unitDimensionVolume => 'الحجم';

  @override
  String get unitDimensionLength => 'الطول';

  @override
  String get unitSystemBadge => 'مضمّنة';

  @override
  String get unitInactiveBadge => 'معطّلة';

  @override
  String unitInUseBadge(int count) {
    return 'مستخدمة في $count';
  }

  @override
  String unitReferenceSummary(String factor, String unit) {
    return 'تعادل $factor $unit';
  }

  @override
  String get unitEditTitle => 'تعديل وحدة';

  @override
  String get unitCreateTitle => 'وحدة جديدة';

  @override
  String get unitNameLabel => 'الاسم';

  @override
  String get unitCodeLabel => 'الرمز';

  @override
  String get unitCodeHelper => 'معرّف فريد بأحرف لاتينية صغيرة، مثل: box';

  @override
  String get unitAbbreviationLabel => 'الاختصار';

  @override
  String get unitDimensionLabel => 'النوع';

  @override
  String get unitReferenceFactorLabel => 'معامل التحويل المرجعي';

  @override
  String get unitReferenceFactorHelper =>
      'كمية الوحدة المرجعية في وحدة واحدة (مثلاً: 1 كجم = 1000 جم).';

  @override
  String get unitAllowsFractionalLabel => 'يسمح بكميات كسرية';

  @override
  String get unitActiveLabel => 'مفعّلة';

  @override
  String get unitSystemLockedHint =>
      'وحدة مضمّنة: لا يمكن تغيير الرمز أو النوع أو المعامل المرجعي.';

  @override
  String get unitSaveError => 'تعذّر حفظ الوحدة.';

  @override
  String get unitDeletedMessage => 'تم حذف الوحدة.';

  @override
  String get unitDeleteError => 'تعذّر حذف الوحدة.';

  @override
  String get unitDeleteTitle => 'حذف الوحدة';

  @override
  String unitDeleteConfirm(String name) {
    return 'سيتم حذف الوحدة «$name» نهائيًا.';
  }

  @override
  String get unitCannotDeleteSystemTitle => 'وحدة مضمّنة';

  @override
  String get unitCannotDeleteSystemMessage =>
      'الوحدات المضمّنة لا تُحذف. يمكنك تعطيلها بدلاً من ذلك.';

  @override
  String get unitCannotDeleteInUseTitle => 'الوحدة قيد الاستخدام';

  @override
  String unitCannotDeleteInUseMessage(int count) {
    return 'هذه الوحدة مستخدمة في $count منتج، لذا لا يمكن حذفها. عطّلها بدلاً من ذلك.';
  }

  @override
  String get unitActivateAction => 'تفعيل';

  @override
  String get unitDeactivateAction => 'تعطيل';

  @override
  String get productIsPreparedTitle => 'يُحضّر عند الطلب';

  @override
  String get productIsPreparedDescription =>
      'طبق مطبخ: يُباع دون مخزون خاص به وتُخصم مكوناته من الوصفة عند التحضير.';

  @override
  String get productIsServiceTitle => 'منتج خدمي';

  @override
  String get productIsServiceDescription => 'خدمة أو رسوم تُباع دون أي مخزون.';

  @override
  String get jobsEmptyTitle => 'لا توجد مهام بعد';

  @override
  String get jobsEmptyMessage =>
      'المهمة هي أي عمل تتابعه خطوة بخطوة: تصليح جهاز، دفعة إنتاج، أو طلب مطبخ. أنشئ أول مهمة وسيظهر مسارها هنا.';

  @override
  String get newJobButton => 'مهمة جديدة';

  @override
  String get jobSearchHint => 'ابحث برقم المهمة أو اسم الزبون أو رقم الجهاز';

  @override
  String get jobFilterAll => 'الكل';

  @override
  String get jobFilterMine => 'مهامي';

  @override
  String get jobFilterOpenOnly => 'قيد العمل';

  @override
  String get jobFilterDone => 'المنتهية';

  @override
  String get jobStatusOpen => 'قيد العمل';

  @override
  String get jobStatusCompleted => 'منتهية';

  @override
  String get jobStatusCancelled => 'ملغاة';

  @override
  String get jobPriorityLabel => 'الأولوية';

  @override
  String get jobPriorityLow => 'منخفضة';

  @override
  String get jobPriorityNormal => 'عادية';

  @override
  String get jobPriorityHigh => 'مرتفعة';

  @override
  String get jobPriorityUrgent => 'عاجلة';

  @override
  String get jobTypeRepair => 'تصليح';

  @override
  String get jobTypeProduction => 'إنتاج';

  @override
  String get jobTypeKitchen => 'مطبخ';

  @override
  String get jobTypeWorkOrder => 'أمر عمل';

  @override
  String get jobDetailsTitle => 'تفاصيل المهمة';

  @override
  String get jobTimelineTitle => 'مسار المهمة';

  @override
  String get jobCurrentStageLabel => 'المرحلة الحالية';

  @override
  String jobStageProgress(int current, int total) {
    return 'المرحلة $current من $total';
  }

  @override
  String get jobOverdueBadge => 'متأخرة';

  @override
  String get jobMaterialsTotalShort => 'إجمالي المواد';

  @override
  String jobNextActionButton(String stageName) {
    return 'الخطوة التالية: $stageName';
  }

  @override
  String get jobMoveToStageAction => 'نقل إلى مرحلة أخرى';

  @override
  String get jobStageChangeNoteLabel => 'ملاحظة (اختياري)';

  @override
  String jobStageChangedMessage(String stageName) {
    return 'انتقلت المهمة إلى «$stageName».';
  }

  @override
  String get jobManagerOnlyMoveHint =>
      'الرجوع للخلف أو تخطي مرحلة يحتاج صلاحية مدير.';

  @override
  String get jobCustomerSection => 'الزبون';

  @override
  String get jobNoCustomer => 'بدون زبون';

  @override
  String get jobAssetSection => 'الجهاز';

  @override
  String get assetHistoryTitle => 'سجل الصيانة';

  @override
  String get assetHistoryEmpty => 'لا يوجد سجل سابق لهذا الجهاز.';

  @override
  String get customerAssetsTitle => 'أجهزة الزبون';

  @override
  String get customerAssetsEmpty => 'لا توجد أجهزة مسجلة لهذا الزبون.';

  @override
  String get jobMaterialsSection => 'القطع والمواد';

  @override
  String get jobMaterialsEmpty =>
      'لم تُستخدم قطع بعد. أضف كل قطعة تركّبها وسيُخصم المخزون تلقائيًا.';

  @override
  String get addMaterialButton => 'إضافة قطعة';

  @override
  String get materialQuantityLabel => 'الكمية';

  @override
  String get materialConsumedBadge => 'خُصمت من المخزون';

  @override
  String get materialPendingBadge => 'بانتظار الخصم';

  @override
  String get materialReversedBadge => 'أُرجعت للمخزون';

  @override
  String get reverseMaterialAction => 'إرجاع للمخزون';

  @override
  String get reverseMaterialConfirmTitle => 'إرجاع القطعة للمخزون؟';

  @override
  String get reverseMaterialConfirmMessage =>
      'ستُعاد الكمية إلى المخزون وتُحذف من حساب المهمة.';

  @override
  String jobMaterialsTotalLabel(String amount) {
    return 'إجمالي القطع: $amount';
  }

  @override
  String get jobQuotedPriceLabel => 'السعر المبدئي';

  @override
  String get jobApprovedPriceLabel => 'السعر المعتمد من الزبون';

  @override
  String get jobApprovalRequiredHint =>
      'سجّل السعر الذي وافق عليه الزبون قبل بدء العمل.';

  @override
  String get jobWarrantyDaysLabel => 'أيام الضمان';

  @override
  String get jobSymptomsLabel => 'وصف المشكلة';

  @override
  String get jobDiagnosisLabel => 'التشخيص';

  @override
  String get jobTechnicianNotesLabel => 'ملاحظات الفني';

  @override
  String get jobSaveButton => 'حفظ التعديلات';

  @override
  String get jobSavedMessage => 'تم حفظ المهمة.';

  @override
  String get jobAssignedToLabel => 'مسؤول التنفيذ';

  @override
  String get jobUnassigned => 'غير معيّن';

  @override
  String get jobDueAtLabel => 'موعد التسليم';

  @override
  String get jobCreatedAtLabel => 'تاريخ الاستلام';

  @override
  String get jobInvoiceButton => 'تحصيل وفوترة';

  @override
  String get jobInvoiceTitle => 'فاتورة المهمة';

  @override
  String get jobInvoiceExplainer =>
      'ستُنشأ فاتورة عادية بالقطع المستخدمة وأجور العمل، ويدخل المبلغ في جلسة الدرج الحالية.';

  @override
  String get jobLaborTotalLabel => 'أجور العمل';

  @override
  String jobInvoiceTotalLabel(String amount) {
    return 'الإجمالي: $amount';
  }

  @override
  String jobInvoiceSuccess(String receiptNumber) {
    return 'تم إنشاء الفاتورة $receiptNumber.';
  }

  @override
  String get jobInvoiceNeedsRegister =>
      'افتح جلسة الدرج أولًا حتى يُسجل المبلغ في حساباتك.';

  @override
  String jobInvoicedBadge(String receiptNumber) {
    return 'مفوترة — $receiptNumber';
  }

  @override
  String get jobCancelAction => 'إلغاء المهمة';

  @override
  String get jobCancelConfirmTitle => 'إلغاء المهمة؟';

  @override
  String get jobCancelConfirmMessage =>
      'ستُلغى المهمة وتُعاد أي قطع مستخدمة إلى المخزون.';

  @override
  String get jobCancelReasonLabel => 'سبب الإلغاء';

  @override
  String get jobReopenAction => 'إعادة فتح المهمة';

  @override
  String get intakeTitle => 'استلام مهمة جديدة';

  @override
  String get intakeStepCustomer => 'الزبون';

  @override
  String get intakeStepAsset => 'الجهاز';

  @override
  String get intakeStepDetails => 'التفاصيل';

  @override
  String get intakeNextButton => 'التالي';

  @override
  String get intakeBackButton => 'السابق';

  @override
  String get intakeCreateButton => 'إنشاء المهمة';

  @override
  String get intakeSelectCustomerHint =>
      'ابحث عن الزبون بالاسم أو الهاتف، أو أنشئ زبونًا جديدًا.';

  @override
  String get intakeNewCustomerButton => 'زبون جديد';

  @override
  String get intakeCustomerNameLabel => 'اسم الزبون';

  @override
  String get intakeCustomerPhoneLabel => 'رقم الهاتف';

  @override
  String get intakeCustomerRequired => 'اختر زبونًا للمتابعة.';

  @override
  String get intakeCustomerCreateError =>
      'تعذّر إنشاء الزبون. تحقّق من الاتصال ثم حاول مرة أخرى.';

  @override
  String get intakeSelectAssetHint =>
      'اختر جهاز الزبون أو أضف جهازًا جديدًا. يساعدك هذا لاحقًا في معرفة تاريخ كل جهاز.';

  @override
  String get intakeNewAssetButton => 'جهاز جديد';

  @override
  String get intakeSkipAssetButton => 'متابعة بدون جهاز';

  @override
  String get assetTypeLabel => 'نوع الجهاز';

  @override
  String get assetBrandLabel => 'الماركة';

  @override
  String get assetModelLabel => 'الموديل';

  @override
  String get assetSerialLabel => 'الرقم التسلسلي';

  @override
  String get assetImeiLabel => 'IMEI';

  @override
  String get assetColorLabel => 'اللون';

  @override
  String get assetNotesLabel => 'ملاحظات';

  @override
  String get assetTypePhone => 'هاتف';

  @override
  String get assetTypeTablet => 'تابلت';

  @override
  String get assetTypeLaptop => 'حاسوب محمول';

  @override
  String get assetTypeConsole => 'جهاز ألعاب';

  @override
  String get assetTypeAppliance => 'جهاز منزلي';

  @override
  String get assetTypeOther => 'أخرى';

  @override
  String get assetTypeVehicle => 'مركبة';

  @override
  String get assetTypesSectionTitle => 'أنواع الأجهزة والمركبات';

  @override
  String get assetTypesSectionHint =>
      'ما الذي تستقبله الورشة؟ أضف نوعاً جديداً وحدد الأرقام التي يُعرف بها.';

  @override
  String get assetTypeAddButton => 'نوع جديد';

  @override
  String get assetTypeEditTitle => 'تعديل النوع';

  @override
  String get assetTypeCreateTitle => 'نوع جديد';

  @override
  String get assetTypeNameLabel => 'الاسم';

  @override
  String get assetTypeSlugLabel => 'المعرّف (بالإنجليزية)';

  @override
  String get assetTypeIconLabel => 'الأيقونة';

  @override
  String get assetTypeIdentifiersLabel => 'الأرقام التي يُعرف بها';

  @override
  String get assetTypeCustomLabelLabel => 'اسم رقم خاص (اختياري)';

  @override
  String get assetTypeCustomLabelHint => 'مثال: رقم الهيكل، رقم العداد';

  @override
  String get assetTypeTracksSerial => 'رقم تسلسلي';

  @override
  String get assetTypeTracksImei => 'IMEI';

  @override
  String get assetTypeTracksVin => 'رقم الشاصي';

  @override
  String get assetTypeTracksPlate => 'رقم اللوحة';

  @override
  String get assetTypeTracksEngine => 'رقم المحرك';

  @override
  String get assetTypeTracksYear => 'سنة الصنع';

  @override
  String get assetTypeTracksOdometer => 'قراءة العداد';

  @override
  String get assetTypeInactiveBadge => 'غير مفعّل';

  @override
  String get assetTypeBuiltInBadge => 'أساسي';

  @override
  String assetTypeItemCount(int count) {
    return '$count جهاز';
  }

  @override
  String get assetTypeDeleteConfirmTitle => 'حذف النوع؟';

  @override
  String get assetTypeDeleteConfirmBody =>
      'لن يظهر هذا النوع عند استلام جهاز جديد.';

  @override
  String get assetTypeSlugRequired => 'المعرّف مطلوب، بالحروف الإنجليزية.';

  @override
  String get assetTypeActiveLabel => 'مفعّل عند الاستلام';

  @override
  String get assetCustomIdentifierFallbackLabel => 'رقم التعريف';

  @override
  String get shopSetupKitchenScreenTitle => 'شاشة مطبخ بدل الورقة';

  @override
  String get shopSetupKitchenScreenSubtitle =>
      'الطلب يظهر على لوحة المهام ويتحرك: تم الاستلام ← قيد التحضير ← جاهز ← تم التقديم. اتركه مغلقاً إذا كان الطباخ يعمل على الفاتورة المطبوعة فقط.';

  @override
  String get workflowStageSettlementLabel => 'يشترط السداد قبل الدخول';

  @override
  String get workflowStageSettlementHelp =>
      'لا يمكن نقل المهمة إلى هذه المرحلة قبل إصدار الفاتورة واستلام المبلغ أو تسجيلها آجل.';

  @override
  String get workflowStageCustodyLabel => 'تسليم الجهاز للزبون';

  @override
  String get workflowStageCustodyHelp =>
      'دخول هذه المرحلة يعني أن الزبون استلم جهازه.';

  @override
  String get shopTypeCarWorkshop => 'ورشة سيارات';

  @override
  String get shopTypeCarWorkshopDescription =>
      'استلام السيارات، تشخيص، تسعيرة، تصليح، ثم التسليم بعد السداد.';

  @override
  String get assetVinLabel => 'رقم الشاصي (VIN)';

  @override
  String get assetPlateLabel => 'رقم اللوحة';

  @override
  String get assetEngineLabel => 'رقم المحرك';

  @override
  String get assetYearLabel => 'سنة الصنع';

  @override
  String get assetOdometerLabel => 'قراءة العداد (كم)';

  @override
  String get assetsDrawerLabel => 'الأجهزة والمركبات';

  @override
  String get assetsTitle => 'الأجهزة والمركبات';

  @override
  String get assetsSearchHint => 'الشاصي، اللوحة، IMEI، الرقم التسلسلي…';

  @override
  String get assetsInShopFilter => 'عندنا الآن';

  @override
  String get assetsAllFilter => 'الكل';

  @override
  String get assetsEmptyTitle => 'لا توجد أجهزة مسجّلة';

  @override
  String get assetsEmptyMessage =>
      'كل جهاز أو مركبة تدخل الورشة تُسجَّل هنا مع سجلها الكامل.';

  @override
  String get assetsInShopEmptyTitle => 'لا يوجد شيء عندنا الآن';

  @override
  String get assetsInShopEmptyMessage => 'كل ما دخل الورشة تم تسليمه لأصحابه.';

  @override
  String get assetsLoadError => 'تعذّر تحميل الأجهزة';

  @override
  String get assetsLoadErrorDetail => 'تعذّر تحميل هذا الجهاز';

  @override
  String get assetInShopBadge => 'عندنا الآن';

  @override
  String get assetOwnerLabel => 'المالك الحالي';

  @override
  String get assetOwnershipHistoryTitle => 'تاريخ الملكية';

  @override
  String get assetOwnershipCurrent => 'المالك الحالي';

  @override
  String assetOwnershipSince(String date) {
    return 'منذ $date';
  }

  @override
  String assetOwnershipRange(String from, String to) {
    return 'من $from إلى $to';
  }

  @override
  String get assetTransferButton => 'تحويل الملكية';

  @override
  String get assetTransferDialogTitle => 'تحويل ملكية الجهاز';

  @override
  String get assetTransferExplainer =>
      'سجل الصيانة يبقى مع الجهاز، فيرى المالك الجديد كل ما عملناه عليه.';

  @override
  String get assetTransferNoteLabel => 'ملاحظة (اختياري)';

  @override
  String get assetTransferConfirm => 'تحويل';

  @override
  String assetTransferSuccess(String customer) {
    return 'تم تحويل الملكية إلى $customer.';
  }

  @override
  String get assetVisitsMetric => 'الزيارات';

  @override
  String get assetTotalSpentMetric => 'إجمالي الفواتير';

  @override
  String get assetLastVisitMetric => 'آخر زيارة';

  @override
  String get assetNeverVisited => 'لم تدخل بعد';

  @override
  String get assetNoHistoryMessage => 'لا توجد مهام على هذا الجهاز بعد.';

  @override
  String get assetNewJobButton => 'مهمة جديدة لهذا الجهاز';

  @override
  String get assetIdentitySectionTitle => 'بيانات التعريف';

  @override
  String get jobServicesSectionTitle => 'الخدمات والأعمال';

  @override
  String get jobAddServiceButton => 'إضافة خدمة';

  @override
  String get jobServicesTotalLabel => 'إجمالي الخدمات';

  @override
  String get jobRemoveServiceTooltip => 'حذف الخدمة';

  @override
  String get jobNoServicesMessage =>
      'لم تُضف أي خدمة بعد (كشف، تركيب، صيانة…).';

  @override
  String get jobNoServiceProductsMessage =>
      'لا توجد منتجات خدمية في الكتالوج. أضف منتجاً وفعّل خيار «خدمة».';

  @override
  String get jobServicePickerTitle => 'اختر خدمة';

  @override
  String get jobHoldButton => 'تعليق';

  @override
  String get jobResumeButton => 'استئناف';

  @override
  String get jobHoldDialogTitle => 'تعليق المهمة';

  @override
  String get jobHoldExplainer =>
      'الوقت المعلّق لا يُحتسب ضمن مدة العمل، فيبقى عمر المهمة صادقاً.';

  @override
  String get jobHoldReasonLabel => 'سبب التعليق';

  @override
  String get jobHoldReasonHint => 'بانتظار وصول قطعة الغيار';

  @override
  String get jobOnHoldBadge => 'معلّقة';

  @override
  String jobHeldTimeLabel(String duration) {
    return 'مدة التعليق: $duration';
  }

  @override
  String get jobSettlementNotInvoiced => 'لم تُفوتر';

  @override
  String get jobSettlementDepositPaid => 'دفعة مقدمة';

  @override
  String get jobSettlementCreditOpen => 'آجل';

  @override
  String get jobSettlementSettled => 'مدفوعة';

  @override
  String get jobCustodyWithShop => 'عندنا';

  @override
  String get jobCustodyReleased => 'تم التسليم';

  @override
  String get jobHandoverButton => 'تسليم للزبون';

  @override
  String get jobHandoverDialogTitle => 'تسليم الجهاز للزبون';

  @override
  String get jobHandoverCollectorLabel => 'استلمها (اختياري)';

  @override
  String get jobHandoverCollectorHint => 'اسم من استلم الجهاز';

  @override
  String get jobHandoverConfirm => 'تسليم';

  @override
  String get jobHandoverBlockedTitle => 'لا يمكن التسليم قبل السداد';

  @override
  String get jobHandoverBlockedMessage =>
      'أصدر الفاتورة واستلم المبلغ، أو سجّلها آجل على الزبون، قبل تسليم الجهاز.';

  @override
  String get jobHandoverBlockedInvoiceAction => 'إصدار الفاتورة';

  @override
  String get jobAwaitingCollectionHint =>
      'مدفوعة وجاهزة — الجهاز ما زال عندنا حتى يستلمه الزبون.';

  @override
  String get jobForceReleaseButton => 'تسليم بدون سداد';

  @override
  String get jobForceReleaseDialogTitle => 'تسليم دون استلام المبلغ';

  @override
  String get jobForceReleaseExplainer =>
      'سيخرج الجهاز والمبلغ لم يُسدَّد. تُسجَّل هذه العملية باسمك.';

  @override
  String get jobForceReleaseNoteLabel => 'السبب';

  @override
  String get jobForceReleaseNoteHint => 'زبون قديم، يدفع الأسبوع القادم';

  @override
  String jobBalanceDueLabel(String amount) {
    return 'المتبقي: $amount';
  }

  @override
  String get jobInvoiceOnCreditLabel => 'آجل (دفعة مقدمة أو دفع لاحق)';

  @override
  String get jobInvoiceOnCreditExplainer =>
      'المبلغ المتبقي يُسجَّل ديناً على الزبون، ويمكن استلام دفعة مقدمة الآن.';

  @override
  String get jobInvoiceAmountNowLabel => 'المبلغ المستلم الآن';

  @override
  String get jobInvoiceDueDateLabel => 'تاريخ الاستحقاق';

  @override
  String get jobInvoiceNeedsCustomerForCredit =>
      'الفاتورة الآجلة تحتاج زبوناً مسجَّلاً على المهمة.';

  @override
  String get jobInvoiceServicesLabel => 'الخدمات';

  @override
  String get jobOverQuoteTitle => 'المبلغ أعلى من السعر المتفق عليه';

  @override
  String jobOverQuoteMessage(String approved, String total) {
    return 'وافق الزبون على $approved والفاتورة $total. أكّد المبلغ الجديد معه أولاً.';
  }

  @override
  String get jobOverQuoteConfirm => 'الزبون موافق، أصدر الفاتورة';

  @override
  String get jobsHistoryTitle => 'سجل المهام';

  @override
  String get jobsHistoryTooltip => 'سجل المهام المنتهية';

  @override
  String get jobsHistoryEmptyTitle => 'لا توجد مهام منتهية';

  @override
  String get jobsHistoryEmptyMessage => 'المهام المكتملة والملغاة تظهر هنا.';

  @override
  String get jobsBoardBackToBoard => 'لوحة العمل';

  @override
  String jobsBoardStageCount(int count) {
    return '$count';
  }

  @override
  String get intakeWorkflowLabel => 'نوع المهمة';

  @override
  String intakeJobCreated(String jobNumber) {
    return 'تم إنشاء المهمة $jobNumber.';
  }

  @override
  String get productionNewBatchButton => 'دفعة إنتاج جديدة';

  @override
  String get productionRecipeLabel => 'الوصفة';

  @override
  String get productionBatchesLabel => 'عدد الدفعات';

  @override
  String get productionBatchesIncreaseTooltip => 'زيادة عدد الدفعات';

  @override
  String get productionBatchesDecreaseTooltip => 'إنقاص عدد الدفعات';

  @override
  String productionOutputPreview(String quantity, String name) {
    return 'سينتج $quantity × $name';
  }

  @override
  String get productionMaterialsPreviewTitle => 'المكونات المطلوبة';

  @override
  String get productionOutputSection => 'ناتج الإنتاج';

  @override
  String get productionReceivedBadge => 'أُضيف للمخزون';

  @override
  String get productionNoRecipesMessage =>
      'أنشئ وصفة أولًا من إعدادات المتجر حتى يعرف النظام مكونات كل منتج.';

  @override
  String get recipesTitle => 'الوصفات';

  @override
  String get recipesSubtitle =>
      'حدد مكونات كل منتج تنتجه ليُخصم المخزون ويُحسب الناتج تلقائيًا';

  @override
  String get recipesEmptyMessage =>
      'الوصفة تخبر النظام بمكونات كل منتج تنتجه — مثل الدقيق والخميرة لرغيف الخبز — ليخصم المخزون ويضيف الناتج تلقائيًا.';

  @override
  String get newRecipeButton => 'وصفة جديدة';

  @override
  String get recipeNameLabel => 'اسم الوصفة';

  @override
  String get recipeOutputVariantLabel => 'المنتج الناتج';

  @override
  String get recipeOutputQuantityLabel => 'الكمية الناتجة لكل دفعة';

  @override
  String get recipeMakeToOrderLabel => 'يُحضّر عند الطلب';

  @override
  String get recipeMakeToOrderHelper =>
      'يُخصم المكوّنات عند بيع المنتج، دون الحاجة لمخزون خاص به.';

  @override
  String get recipeProduceToStockHelper =>
      'يُنتَج إلى المخزون مسبقًا عبر أمر إنتاج، ثم يُباع من المخزون.';

  @override
  String get recipeComponentsTitle => 'المكونات';

  @override
  String get recipeAddComponentButton => 'إضافة مكوّن';

  @override
  String get recipeComponentQuantityLabel => 'الكمية';

  @override
  String get recipeRemoveComponentTooltip => 'حذف المكوّن';

  @override
  String get recipeWastePercentLabel => 'نسبة الهدر %';

  @override
  String get recipeDeleteAction => 'حذف الوصفة';

  @override
  String get recipeDeleteConfirmTitle => 'حذف الوصفة؟';

  @override
  String recipeDeleteConfirmMessage(String name) {
    return 'سيتم حذف «$name» نهائيًا. الوصفات المستخدمة في دفعات إنتاج سابقة لا يمكن حذفها.';
  }

  @override
  String get recipeSaveButton => 'حفظ الوصفة';

  @override
  String get recipeSavedMessage => 'تم حفظ الوصفة.';

  @override
  String get recipesLoadError => 'تعذر تحميل الوصفات.';

  @override
  String get recipeNameRequired => 'أدخل اسم الوصفة.';

  @override
  String get recipeComponentsRequired => 'أضف مكوّنًا واحدًا على الأقل.';

  @override
  String get operationsSettingsSectionTitle => 'العمليات والمهام';

  @override
  String get operationsSettingsSectionSubtitle =>
      'تشغيل التصليح والإنتاج والمطبخ وإدارة مراحل العمل';

  @override
  String get operationsModesTitle => 'أقسام العمل';

  @override
  String get operationsModesHint =>
      'فعّل ما يناسب نشاطك فقط — كل قسم يضيف نوع مهام جاهزًا بمراحله.';

  @override
  String get enableRepairOperationsTitle => 'التصليح والصيانة';

  @override
  String get enableRepairOperationsDescription =>
      'استلام أجهزة الزبائن، تتبع التصليح خطوة بخطوة، وفوترة القطع والأجور.';

  @override
  String get enableProductionOperationsTitle => 'الإنتاج';

  @override
  String get enableProductionOperationsDescription =>
      'دفعات إنتاج بوصفات محددة: تُخصم المكونات ويُضاف الناتج للمخزون تلقائيًا.';

  @override
  String get enableKitchenOperationsTitle => 'المطبخ';

  @override
  String get enableKitchenOperationsDescription =>
      'طلبات مطبخ تمر بمراحل التحضير وتخصم المكونات عند الطبخ.';

  @override
  String get kitchenPrintingSectionTitle => 'طباعة المطبخ';

  @override
  String get kitchenPrintingSectionHint =>
      'اطبع تذاكر المطبخ تلقائيًا للأصناف المحضّرة عند الدفع، ووجّهها إلى الطابعات حسب الفئة.';

  @override
  String get autoPrintKitchenTicketsTitle => 'طباعة تذاكر المطبخ تلقائيًا';

  @override
  String get autoPrintKitchenTicketsDescription =>
      'عند الدفع، تُطبع تذكرة تحضير لكل محطة معنية بالأصناف المحضّرة.';

  @override
  String get prepStationsSectionTitle => 'محطات التحضير';

  @override
  String get prepStationsSectionSubtitle =>
      'وجّه الأصناف المحضّرة إلى طابعات المحطات حسب الفئة.';

  @override
  String get prepStationAddButton => 'إضافة محطة';

  @override
  String get prepStationsLoadError => 'تعذّر تحميل محطات التحضير.';

  @override
  String get prepStationsEmptyMessage => 'لا توجد محطات تحضير بعد.';

  @override
  String get prepStationNameLabel => 'اسم المحطة';

  @override
  String get prepStationCategoriesLabel => 'الفئات الموجّهة';

  @override
  String get prepStationDefaultLabel =>
      'المحطة الافتراضية (تستقبل الأصناف غير المصنّفة)';

  @override
  String get prepStationActiveLabel => 'مفعّلة';

  @override
  String get prepStationDefaultBadge => 'افتراضية';

  @override
  String get prepStationInactiveBadge => 'موقوفة';

  @override
  String get prepStationCategoriesEmpty => 'كل الأصناف المحضّرة غير المصنّفة';

  @override
  String get prepStationDeleteTitle => 'حذف المحطة؟';

  @override
  String get prepStationDeleteMessage => 'لن تُطبع تذاكر هذه المحطة بعد الآن.';

  @override
  String get prepStationSaveError => 'تعذّر حفظ المحطة.';

  @override
  String get prepStationDeleteError => 'تعذّر حذف المحطة.';

  @override
  String get kitchenPrintersSectionTitle => 'طابعات المطبخ';

  @override
  String get kitchenPrintersSectionHint =>
      'اربط طابعة حرارية بكل محطة تحضير يخدمها هذا الجهاز.';

  @override
  String get kitchenPrintersNoStations =>
      'لا توجد محطات تحضير. أضِفها من إعدادات المتجر.';

  @override
  String get kitchenPrintersLoadError => 'تعذّر تحميل محطات التحضير.';

  @override
  String get kitchenStationNotConfigured => 'لم تُضبط طابعة لهذه المحطة.';

  @override
  String get enableJobTrackingTitle => 'صفحة تتبع للزبائن';

  @override
  String get enableJobTrackingDescription =>
      'رابط عام يطّلع منه الزبون على حالة مهمته دون الاتصال بك.';

  @override
  String get workflowsTitle => 'مراحل العمل';

  @override
  String get workflowStagesHint =>
      'هذه هي الخطوات التي تمر بها كل مهمة من الاستلام حتى التسليم. يمكنك إعادة تسميتها أو إضافة مراحل تناسب طريقة عملك.';

  @override
  String get workflowStageNameLabel => 'اسم المرحلة';

  @override
  String get workflowStageMoveUpTooltip => 'تحريك المرحلة لأعلى';

  @override
  String get workflowStageMoveDownTooltip => 'تحريك المرحلة لأسفل';

  @override
  String get workflowStageDeleteTooltip => 'حذف المرحلة';

  @override
  String get workflowAddStageButton => 'إضافة مرحلة';

  @override
  String get workflowStageInitialLabel => 'مرحلة البداية';

  @override
  String get workflowStageTerminalLabel => 'مرحلة النهاية';

  @override
  String get workflowStageApprovalLabel => 'تتطلب موافقة الزبون على السعر';

  @override
  String get workflowStageConsumesLabel => 'تخصم المواد من المخزون';

  @override
  String get workflowStageProducesLabel => 'تضيف الناتج إلى المخزون';

  @override
  String get workflowSaveButton => 'حفظ المراحل';

  @override
  String get workflowSavedMessage => 'تم حفظ مراحل العمل.';

  @override
  String get workflowsLoadError => 'تعذر تحميل مراحل العمل.';

  @override
  String jobCountLabel(int count) {
    return '$count مهمة';
  }

  @override
  String get shopSettingsEmptyValue => 'غير محدد';

  @override
  String get shopSettingsEnabledValue => 'مفعل';

  @override
  String get shopSettingsDisabledValue => 'متوقف';

  @override
  String shopIdentitySummary(String shopName, String logoStatus) {
    return '$shopName، $logoStatus';
  }

  @override
  String receiptSettingsSummary(String status) {
    return 'الطباعة التلقائية: $status';
  }

  @override
  String onlineInvoiceSettingSummary(String status) {
    return 'فواتير الإنترنت: $status';
  }

  @override
  String registerSessionSettingsSummary(String status, String window) {
    return 'نقدية الافتتاح: $status، صلاحية الكاشير للإرجاع: $window';
  }

  @override
  String inventorySettingsSummary(
    int count,
    String oversellStatus,
    String lossStatus,
  ) {
    return 'تنبيه عند $count قطع أو أقل، البيع فوق المخزون: $oversellStatus، منع الخسارة: $lossStatus';
  }

  @override
  String paymentSettingsSummary(
    num count,
    String cardCommission,
    String transferCommission,
    String receiptStatus,
    String terminalStatus,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count طرق دفع مفعلة',
      two: 'طريقتان مفعّلتان',
      one: 'طريقة دفع واحدة مفعلة',
      zero: 'لا توجد طرق دفع مفعلة',
    );
    return '$_temp0، بطاقة $cardCommission%، تحويل $transferCommission%، إثبات البطاقة: $receiptStatus، $terminalStatus';
  }

  @override
  String get analyticsExportAllEventsSummary => 'كل أحداث التتبع';

  @override
  String analyticsExportDateRangeSummary(String from, String to) {
    return 'من $from إلى $to';
  }

  @override
  String get analyticsExportTitle => 'تصدير التتبع';

  @override
  String get analyticsExportFiltersSectionTitle => 'فلاتر التصدير';

  @override
  String get analyticsExportFormatLabel => 'صيغة الملف';

  @override
  String get analyticsExportFormatCsv => 'CSV';

  @override
  String get analyticsExportFormatJson => 'JSON';

  @override
  String get analyticsExportFormatJsonl => 'JSON Lines (سطر لكل حدث)';

  @override
  String get analyticsExportCompressionLabel => 'الضغط';

  @override
  String get analyticsExportCompressionDeflate => 'مضغوط (أصغر حجما)';

  @override
  String get analyticsExportCompressionNone => 'بدون ضغط (أسرع)';

  @override
  String get analyticsExportFromDateLabel => 'من تاريخ';

  @override
  String get analyticsExportToDateLabel => 'إلى تاريخ';

  @override
  String get analyticsExportOpenDateValue => 'مفتوح';

  @override
  String get analyticsExportClearDatesButton => 'مسح التواريخ';

  @override
  String get analyticsExportEventTypeLabel => 'نوع الحدث';

  @override
  String get analyticsExportSeverityLabel => 'الحدة';

  @override
  String get analyticsExportSourceLabel => 'المصدر';

  @override
  String get analyticsExportAnyValue => 'الكل';

  @override
  String get analyticsExportSearchLabel => 'بحث في الاسم أو الأثر';

  @override
  String get analyticsExportPlatformLabel => 'المنصة';

  @override
  String get analyticsExportSessionLabel => 'معرّف الجلسة';

  @override
  String get analyticsExportDeviceLabel => 'معرّف الجهاز';

  @override
  String get analyticsExportDownloadButton => 'تنزيل الملف';

  @override
  String get analyticsExportRunningButton => 'جار التصدير...';

  @override
  String get analyticsExportStartedMessage => 'بدأ تنزيل ملف التتبع.';

  @override
  String get analyticsExportFailedMessage =>
      'تعذر تصدير التتبع. راجع الفلاتر وحاول مرة أخرى.';

  @override
  String get analyticsExportSaveDialogTitle => 'حفظ ملف التتبع';

  @override
  String analyticsExportSavedMessage(String path) {
    return 'حُفظ ملف التتبع في: $path';
  }

  @override
  String get analyticsPurgeSectionTitle => 'مسح سجل التتبع';

  @override
  String get analyticsPurgeSectionDescription =>
      'حذف نهائي لكل الأحداث المخزّنة على الخادم لتحرير مساحة القرص. صدّر ما تحتاجه أولا.';

  @override
  String get analyticsPurgeButton => 'مسح كل بيانات التتبع';

  @override
  String get analyticsPurgeRunningButton => 'جار المسح...';

  @override
  String get analyticsPurgeDialogTitle => 'مسح كل بيانات التتبع؟';

  @override
  String get analyticsPurgeDialogMessage =>
      'سيُحذف نهائيا كل حدث مسجّل على الخادم، ويشمل ذلك سجل النشاط وسجل التدقيق وقياسات الأداء. لا يمكن التراجع، ولا تحتفظ النسخ الاحتياطية بنسخة من هذه البيانات.';

  @override
  String get analyticsPurgeDialogConfirm => 'امسح نهائيا';

  @override
  String analyticsPurgeDoneMessage(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'حُذف $count حدث',
      two: 'حُذف حدثان',
      one: 'حُذف حدث واحد',
      zero: 'لم يكن هناك ما يُمسح',
    );
    return '$_temp0';
  }

  @override
  String get analyticsPurgeFailedMessage =>
      'تعذر مسح بيانات التتبع. حاول مرة أخرى.';

  @override
  String get analyticsExportCanceledMessage => 'أُلغي حفظ ملف التتبع.';

  @override
  String get analyticsExportCancelButton => 'إلغاء التصدير';

  @override
  String get analyticsExportStoppedMessage => 'أُوقف التصدير.';

  @override
  String analyticsExportProgressSummary(
    String size,
    String rate,
    String elapsed,
  ) {
    return '$size · $rate/ث · $elapsed';
  }

  @override
  String analyticsExportEstimatedEventsSummary(String count) {
    return 'نحو $count حدث';
  }

  @override
  String get backupRestoreSectionTitle => 'النسخ والاستعادة';

  @override
  String get backupStatusLoadingSummary => 'جار تحميل حالة النسخ الاحتياطي';

  @override
  String get backupScheduleDisabledSummary => 'النسخ التلقائي متوقف';

  @override
  String get backupScheduleMissingDestinationSummary =>
      'اختر قرصا خارجيا لتفعيل النسخ التلقائي';

  @override
  String backupNextScheduledSummary(String dateTime) {
    return 'النسخة التالية: $dateTime';
  }

  @override
  String backupJobRunningSummary(String operation, int percent) {
    return '$operation قيد التنفيذ، $percent٪';
  }

  @override
  String get backupRestoreTitle => 'النسخ والاستعادة';

  @override
  String get backupRefreshTooltip => 'تحديث حالة النسخ';

  @override
  String get backupScheduleSectionTitle => 'النسخ الاحتياطي التلقائي';

  @override
  String get backupScheduleEnabledLabel => 'تفعيل النسخ اليومي';

  @override
  String get backupScheduleEnabledSubtitle =>
      'ينشئ النظام ملف ZIP واحدا يحتوي قاعدة البيانات والملفات المرفوعة.';

  @override
  String get backupDestinationLabel => 'قرص النسخ الاحتياطي';

  @override
  String backupDestinationOption(String label, String freeSpace) {
    return '$label، متاح $freeSpace';
  }

  @override
  String backupDestinationDetails(
    String path,
    String freeSpace,
    String totalSpace,
  ) {
    return 'سيتم الحفظ في $path. المساحة المتاحة $freeSpace من $totalSpace.';
  }

  @override
  String get backupNoWritableDestinationsMessage =>
      'لم يجد الخادم قرصا خارجيا قابلا للكتابة. تأكد من توصيل القرص وربطه داخل Docker.';

  @override
  String get backupScheduledTimeLabel => 'وقت النسخ اليومي';

  @override
  String backupRetentionMessage(int count) {
    return 'بعد نجاح النسخ يحتفظ دفتر بآخر $count نسخ ويحذف الأقدم من مجلد النسخ.';
  }

  @override
  String get backupDestinationRequiredError => 'اختر قرصا للنسخ الاحتياطي.';

  @override
  String get backupSaveScheduleButton => 'حفظ الجدولة';

  @override
  String get backupSavingScheduleButton => 'جار الحفظ...';

  @override
  String get backupStartNowButton => 'نسخ الآن';

  @override
  String get backupStartingButton => 'جار البدء...';

  @override
  String get backupScheduleSavedMessage => 'تم حفظ جدولة النسخ الاحتياطي.';

  @override
  String get backupStartedMessage => 'بدأ النسخ الاحتياطي.';

  @override
  String get backupOperationFailedMessage =>
      'تعذرت عملية النسخ أو الاستعادة. حاول مرة أخرى.';

  @override
  String backupActiveJobTitle(String operation) {
    return '$operation قيد التنفيذ';
  }

  @override
  String backupProgressPercent(int percent) {
    return '$percent٪';
  }

  @override
  String get restoreSectionTitle => 'استعادة نسخة';

  @override
  String get restoreWarningMessage =>
      'الاستعادة تستبدل قاعدة البيانات والملفات الحالية بمحتوى النسخة المختارة.';

  @override
  String get restorePickFileButton => 'اختيار ملف ZIP';

  @override
  String get restoreUploadingButton => 'جار الرفع...';

  @override
  String get restorePickErrorMessage => 'تعذر قراءة ملف النسخة المختارة.';

  @override
  String get restoreConfirmTitle => 'تأكيد الاستعادة';

  @override
  String get restoreConfirmMessage =>
      'سيتم استبدال بيانات المتجر الحالية بعد بدء الاستعادة. تأكد أن ملف النسخة صحيح.';

  @override
  String get restoreConfirmButton => 'بدء الاستعادة';

  @override
  String get restoreStartedMessage => 'بدأت الاستعادة.';

  @override
  String get purchaseCostWarningTitle => 'تحقق من التكلفة';

  @override
  String get purchaseCostWarningBody =>
      'التكلفة المدخلة تبدو غير معتادة. راجعها قبل الحفظ — إن كانت صحيحة يمكنك المتابعة.';

  @override
  String get purchaseCostWarningBlockedBody =>
      'التكلفة المدخلة غير منطقية ولا يمكن حفظها. تأكد من الكمية وسعر الوحدة، فربما أدخلت المبلغ الإجمالي بدل سعر القطعة.';

  @override
  String get purchaseCostWarningReviewButton => 'مراجعة';

  @override
  String get purchaseCostWarningFixButton => 'تصحيح';

  @override
  String get purchaseCostWarningConfirmButton => 'التكلفة صحيحة، تابع';

  @override
  String get backupHealthNeverTitle => 'لا توجد نسخة احتياطية مؤكدة';

  @override
  String get backupHealthNeverMessage =>
      'لم يتم بعد التحقق من أي نسخة احتياطية لهذا المتجر. لا توجد حالياً وسيلة لاسترجاع البيانات إذا تعطل الجهاز.';

  @override
  String get backupHealthStaleTitle => 'النسخة الاحتياطية قديمة';

  @override
  String backupHealthStaleMessage(String verifiedAt, int hours) {
    return 'آخر نسخة مؤكدة كانت $verifiedAt. الحد المسموح به $hours ساعة.';
  }

  @override
  String backupHealthLastErrorLabel(String message) {
    return 'آخر خطأ: $message';
  }

  @override
  String get backupHealthVerifiedLabel => 'آخر نسخة مؤكدة';

  @override
  String get backupHealthVerifiedNever => 'لا توجد';

  @override
  String get backupHistorySectionTitle => 'آخر العمليات';

  @override
  String get latestBackupLabel => 'آخر نسخة احتياطية';

  @override
  String get latestRestoreLabel => 'آخر استعادة';

  @override
  String get backupNoJobValue => 'لا توجد عملية مسجلة';

  @override
  String backupJobHistorySummary(
    String status,
    String completedAt,
    String filename,
  ) {
    return '$status، $completedAt، $filename';
  }

  @override
  String get backupOperationBackup => 'النسخ الاحتياطي';

  @override
  String get backupOperationRestore => 'الاستعادة';

  @override
  String get backupJobStatusQueued => 'في الانتظار';

  @override
  String get backupJobStatusRunning => 'قيد التنفيذ';

  @override
  String get backupJobStatusSucceeded => 'مكتملة';

  @override
  String get backupJobStatusFailed => 'فشلت';

  @override
  String get backupStorageUnknownValue => 'غير معروف';

  @override
  String backupStorageGigabytes(String value) {
    return '$value جيجابايت';
  }

  @override
  String backupStorageMegabytes(String value) {
    return '$value ميجابايت';
  }

  @override
  String get analyticsEventTypeUsage => 'استخدام';

  @override
  String get analyticsEventTypeError => 'خطأ';

  @override
  String get analyticsEventTypePerformance => 'أداء';

  @override
  String get analyticsEventTypeSecurity => 'أمان';

  @override
  String get analyticsEventTypeFraudSignal => 'مؤشر اشتباه';

  @override
  String get analyticsEventTypeAudit => 'تدقيق';

  @override
  String get analyticsSeverityDebug => 'تصحيح';

  @override
  String get analyticsSeverityInfo => 'معلومة';

  @override
  String get analyticsSeverityWarning => 'تحذير';

  @override
  String get analyticsSeverityError => 'خطأ';

  @override
  String get analyticsSeverityCritical => 'حرج';

  @override
  String get analyticsSourceFrontend => 'الواجهة';

  @override
  String get analyticsSourceBackend => 'الخادم';

  @override
  String get analyticsSourcePrintAgent => 'وكيل الطباعة';

  @override
  String get analyticsSourceIntegration => 'تكامل';

  @override
  String get shopNameLabel => 'اسم المتجر';

  @override
  String get shopLogoLabel => 'شعار المتجر';

  @override
  String get shopLogoEmpty => 'لم يتم رفع شعار بعد.';

  @override
  String get shopLogoUploadedValue => 'الشعار مرفوع';

  @override
  String get shopLogoMissingValue => 'الشعار غير مرفوع';

  @override
  String get shopLogoMarkedForRemoval => 'سيتم إزالة الشعار عند الحفظ.';

  @override
  String get shopLogoUploadButton => 'رفع شعار';

  @override
  String get shopLogoReplaceButton => 'استبدال الشعار';

  @override
  String get shopLogoRemoveButton => 'إزالة الشعار';

  @override
  String get shopLogoPickError => 'تعذر قراءة الشعار المختار.';

  @override
  String get receiptHeaderLabel => 'ترويسة الإيصال';

  @override
  String get receiptFooterLabel => 'خاتمة الإيصال';

  @override
  String get requireOpeningCashLabel => 'طلب نقدية افتتاح الجلسة';

  @override
  String get posCashPurchaseLimitSettingLabel =>
      'حد الشراء النقدي من شاشة البيع';

  @override
  String get posCashPurchaseLimitSettingHelp =>
      'الحد الأقصى لقيمة الشراء النقدي الواحد المدفوع من درج الوردية. اتركه فارغاً لإلغاء الحد.';

  @override
  String get cashierReturnWindowLabel => 'مدة صلاحية الإرجاع للكاشير';

  @override
  String get cashierReturnWindowDialogTitle => 'مدة صلاحية الإرجاع';

  @override
  String get cashierReturnWindowDaysLabel => 'الأيام';

  @override
  String get cashierReturnWindowHoursLabel => 'الساعات';

  @override
  String cashierReturnWindowHoursValue(int hours) {
    return '$hours ساعة';
  }

  @override
  String cashierReturnWindowDaysValue(int days) {
    return '$days يوم';
  }

  @override
  String cashierReturnWindowDaysHoursValue(int days, int hours) {
    return '$days يوم و$hours ساعة';
  }

  @override
  String get autoPrintReceiptsLabel => 'طباعة الإيصالات تلقائيًا';

  @override
  String get enableOnlineInvoicesLabel =>
      'إظهار رابط وQR للفاتورة عبر الإنترنت';

  @override
  String get enableOnlineInvoicesSubtitle =>
      'بعد الدفع يظهر رابط الفاتورة الحقيقي عبر الريلاي ليتمكن العميل من حفظها كملف PDF.';

  @override
  String get allowOversellingLabel => 'السماح بالبيع فوق المخزون';

  @override
  String get warnLowStockBeforeSaleLabel => 'تنبيه المخزون قبل البيع';

  @override
  String get warnLowStockBeforeSaleSubtitle =>
      'عند إيقافه يكتمل البيع فوق المخزون دون طلب تأكيد (يتطلب تفعيل «السماح بالبيع فوق المخزون»).';

  @override
  String get preventSellingAtLossLabel => 'منع البيع بخسارة';

  @override
  String get preventSellingAtLossSubtitle =>
      'عند إيقافه سيظهر تحذير للكاشير قبل إتمام بيع بخسارة.';

  @override
  String get valuationMethodLabel => 'طريقة تسعير المخزون';

  @override
  String get valuationMethodHelper =>
      'تحدد تكلفة البضاعة المباعة عندما يُشترى نفس الصنف بأسعار مختلفة.';

  @override
  String get valuationMethodMovingAverage => 'المتوسط المتحرك';

  @override
  String get valuationMethodFifo => 'الوارد أولاً يصرف أولاً (FIFO)';

  @override
  String get valuationMethodLifo => 'الوارد أخيراً يصرف أولاً (LIFO)';

  @override
  String get valuationMethodMovingAverageDescription =>
      'تكلفة واحدة مُوزّعة على كل الكمية الموجودة، تتغيّر مع كل شراء جديد. الأنسب لمعظم المحلات.';

  @override
  String get valuationMethodFifoDescription =>
      'يُحتسب البيع على تكلفة أقدم بضاعة في المخزن أولاً. الأنسب للبضاعة ذات الصلاحية.';

  @override
  String get valuationMethodLifoDescription =>
      'يُحتسب البيع على تكلفة أحدث بضاعة اشتُريت أولاً. يرفع التكلفة ويقلّل الربح المُعلن عند ارتفاع الأسعار.';

  @override
  String get valuationMethodChangeWarningTitle => 'تغيير طريقة تسعير المخزون';

  @override
  String valuationMethodChangeWarningBody(
    String currentMethod,
    String newMethod,
  ) {
    return 'أنت على وشك التغيير من «$currentMethod» إلى «$newMethod».';
  }

  @override
  String get valuationMethodChangeWarningConsequences =>
      'هذه الطريقة تحدد تكلفة كل بيعة وربحها. تغييرها الآن يجعل أرقام التكلفة والأرباح الجديدة محسوبة بطريقة مختلفة عن التقارير التي سبق أن اعتمدت عليها، وقد لا تتطابق مع العمولات التي صُرفت أو الأرباح التي أُعلنت سابقاً.';

  @override
  String get valuationMethodChangeWarningAdvice =>
      'الأفضل اختيار الطريقة مرة واحدة عند تجهيز المحل وعدم تغييرها بعد ذلك. إن كنت مضطراً للتغيير، فالأنسب أن يكون في بداية فترة محاسبية جديدة وبعد استخراج تقارير الفترة السابقة.';

  @override
  String get valuationMethodChangeKeepCurrent => 'إبقاء الطريقة الحالية';

  @override
  String get valuationMethodChangeConfirm => 'أفهم ذلك، غيّرها';

  @override
  String get valuationMethodSetupTitle => 'طريقة تسعير المخزون';

  @override
  String get valuationMethodSetupSubtitle =>
      'اختر مرة واحدة الآن — تغييرها بعد بدء البيع يؤثر على تكلفة وأرباح المبيعات السابقة.';

  @override
  String get paymentMethodCash => 'نقد';

  @override
  String get paymentMethodCard => 'بطاقة';

  @override
  String get paymentMethodTransfer => 'تحويل';

  @override
  String get requireCardReceiptSettingLabel =>
      'إلزام مسح ومطابقة إيصال البطاقة';

  @override
  String get requireCardReceiptSettingSubtitle =>
      'يجب مسح رابط QR من إيصال معاملات ومطابقة المبلغ لكل دفعة بطاقة.';

  @override
  String get requireCustomerForCreditLabel =>
      'طلب عميل للبيع الآجل وعروض الأسعار';

  @override
  String get requireCustomerForCreditSubtitle =>
      'عند تفعيله يجب اختيار عميل قبل إتمام بيع آجل أو عرض سعر.';

  @override
  String get enforceCustomerCreditLimitsLabel => 'تفعيل سقف الدين للعملاء';

  @override
  String get enforceCustomerCreditLimitsSubtitle =>
      'عند تفعيله يُرفض البيع الآجل الذي يتجاوز سقف دين العميل. مغلق افتراضيًا، ولا يتغيّر شيء حتى تُفعّله.';

  @override
  String get defaultCustomerCreditLimitLabel => 'سقف الدين الافتراضي';

  @override
  String get defaultCustomerCreditLimitHelp =>
      'يُطبَّق على كل عميل ما لم يُحدَّد له سقف خاص من صفحته. اتركه فارغًا لعدم وضع سقف، أو اكتب 0 لمنع البيع الآجل افتراضيًا.';

  @override
  String get defaultPaymentTermsDaysLabel => 'مهلة السداد الافتراضية (أيام)';

  @override
  String get defaultPaymentTermsDaysHelp =>
      'تُطبَّق على كل عميل ما لم يُحدَّد له اتفاق خاص من صفحته. اكتب 0 إذا كان الدين مستحقًا يوم إصداره.';

  @override
  String get paymentTermsBasisLabel => 'تُحسب المهلة من';

  @override
  String get paymentTermsBasisNetDays => 'تاريخ الفاتورة';

  @override
  String get paymentTermsBasisEndOfMonth => 'نهاية شهر الفاتورة';

  @override
  String get paymentTermsPolicyLabel => 'مهلة السداد';

  @override
  String get paymentTermsPolicyShopDefault => 'حسب إعداد المحل';

  @override
  String get paymentTermsPolicyImmediate => 'مستحق فورًا';

  @override
  String get paymentTermsPolicyCustom => 'مهلة خاصة';

  @override
  String get paymentTermsDaysLabel => 'عدد الأيام';

  @override
  String get paymentTermsDaysRequired => 'المهلة الخاصة تحتاج عدد أيام.';

  @override
  String get effectivePaymentTermsImmediate =>
      'الفواتير الآجلة لهذا العميل مستحقة يوم إصدارها.';

  @override
  String effectivePaymentTermsNetDays(int days) {
    return 'الفواتير الآجلة لهذا العميل مستحقة بعد $days يومًا من تاريخ الفاتورة.';
  }

  @override
  String effectivePaymentTermsEndOfMonth(int days) {
    return 'الفواتير الآجلة لهذا العميل مستحقة بعد $days يومًا من نهاية شهر الفاتورة.';
  }

  @override
  String get creditDueDateProposedHint =>
      'مقترح من اتفاق العميل — يمكنك تغييره.';

  @override
  String invoiceOverdueBadge(int days) {
    return 'متأخرة $days يومًا';
  }

  @override
  String invoiceDueOnLabel(String date) {
    return 'تستحق في $date';
  }

  @override
  String get creditLimitBlockedTitle => 'تجاوز سقف الدين';

  @override
  String get creditLimitBlockedMessage =>
      'هذه الفاتورة الآجلة تتجاوز سقف دين العميل. حصِّل دفعة أولى، أو عدّل سقف العميل من صفحته.';

  @override
  String creditLimitBlockedOutstanding(String amount) {
    return 'الدين الحالي: $amount';
  }

  @override
  String creditLimitBlockedLimit(String amount) {
    return 'السقف: $amount';
  }

  @override
  String creditLimitBlockedAvailable(String amount) {
    return 'المتاح: $amount';
  }

  @override
  String creditLimitBlockedNewDebt(String amount) {
    return 'هذه الفاتورة تضيف: $amount';
  }

  @override
  String get customerCreditLimitTitle => 'سقف الدين (آجل)';

  @override
  String get customerCreditLimitPolicyShopDefault => 'افتراضي المتجر';

  @override
  String get customerCreditLimitPolicyUnlimited => 'بلا سقف';

  @override
  String get customerCreditLimitPolicyCustom => 'سقف خاص';

  @override
  String get customerCreditLimitAmountLabel => 'المبلغ';

  @override
  String get customerCreditLimitAmountRequired => 'أدخل مبلغ السقف.';

  @override
  String customerCreditLimitEffective(String amount) {
    return 'السقف المطبَّق: $amount';
  }

  @override
  String get customerCreditLimitNone => 'بلا سقف';

  @override
  String customerCreditLimitShopDefaultHint(String amount) {
    return 'افتراضي المتجر: $amount';
  }

  @override
  String customerCreditLimitAvailable(String amount) {
    return 'المتاح للشراء الآجل: $amount';
  }

  @override
  String get customerCreditLimitSaveError =>
      'تعذّر حفظ سقف الدين. حاول مرة أخرى.';

  @override
  String get customerCreditLimitSaved => 'تم حفظ سقف الدين.';

  @override
  String get allowCashierCustomerAccessLabel =>
      'السماح للكاشير بالعملاء والتحصيل';

  @override
  String get allowCashierCustomerAccessSubtitle =>
      'يتيح للكاشير اختيار عميل للبيع الآجل/عرض السعر وتحصيل ديون العملاء — دون رؤية فواتير الكاشيرين الآخرين أو تعديل بيانات العملاء.';

  @override
  String get collectDebtTitle => 'تحصيل دين';

  @override
  String get collectDebtPickCustomer => 'اختر عميلاً للتحصيل';

  @override
  String get collectDebtChangeCustomer => 'تغيير العميل';

  @override
  String get collectDebtLoadError => 'تعذّر تحميل رصيد العميل. حاول مرة أخرى.';

  @override
  String collectDebtOutstanding(String amount) {
    return 'المتبقّي على العميل: $amount';
  }

  @override
  String get collectDebtNoDebt => 'لا يوجد دين على هذا العميل.';

  @override
  String get collectDebtRecordPayment => 'تسجيل دفعة';

  @override
  String get collectDebtRecordedMessage => 'تم تسجيل الدفعة وتحصيل الدين.';

  @override
  String get collectDebtFailedMessage => 'تعذّر تسجيل الدفعة. حاول مرة أخرى.';

  @override
  String get trustedCardTerminalIdsLabel => 'أجهزة البطاقة الموثوقة';

  @override
  String get trustedCardTerminalIdsHelper =>
      'حدد أجهزة البطاقة التي تقبل إيصالاتها عند مطابقة الدفع. اترك القائمة فارغة لقبول أي جهاز.';

  @override
  String get manageTrustedCardTerminalsButton => 'إدارة الأجهزة';

  @override
  String get addTrustedCardTerminalButton => 'إضافة جهاز';

  @override
  String get trustedCardTerminalsDialogTitle => 'إدارة أجهزة البطاقة';

  @override
  String get trustedCardTerminalsDialogDescription =>
      'أضف رقم الجهاز كما يظهر في إيصال البطاقة. عند ترك القائمة فارغة سيتم قبول أي جهاز.';

  @override
  String get trustedCardTerminalIdFieldLabel => 'رقم الجهاز';

  @override
  String get trustedCardTerminalIdFieldHint => 'مثال: 0JA8Y13W';

  @override
  String get trustedCardTerminalRequiredError => 'أدخل رقم الجهاز.';

  @override
  String get trustedCardTerminalDuplicateError =>
      'هذا الجهاز موجود في القائمة.';

  @override
  String get trustedCardTerminalAllowAnyMessage =>
      'لا توجد أجهزة محددة؛ سيتم قبول أي جهاز بطاقة عند مطابقة الإيصال.';

  @override
  String removeTrustedCardTerminalTooltip(String terminalId) {
    return 'إزالة الجهاز $terminalId';
  }

  @override
  String trustedCardTerminalCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count أجهزة موثوقة',
      two: 'جهازان موثوقان',
      one: 'جهاز موثوق واحد',
      zero: 'لا توجد أجهزة محددة',
    );
    return '$_temp0';
  }

  @override
  String get cardCommissionPercentLabel => 'عمولة البطاقة (%)';

  @override
  String get transferCommissionPercentLabel => 'عمولة التحويل (%)';

  @override
  String get paymentMethodsRequiredError => 'فعّل طريقة دفع واحدة على الأقل.';

  @override
  String get lowStockThresholdLabel => 'حد تنبيه المخزون المنخفض';

  @override
  String get printerTransportLabel => 'طريقة الاتصال';

  @override
  String get printerTransportSerial => 'تسلسلي';

  @override
  String get printerTransportBluetooth => 'بلوتوث';

  @override
  String get printerTransportWifi => 'شبكة';

  @override
  String get printerTransportSystem => 'طابعة النظام';

  @override
  String get printerTransportUsb => 'USB';

  @override
  String get printerTransportFake => 'محاكاة';

  @override
  String get printerOutputThermalReceipt => 'إخراج حراري ESC/POS';

  @override
  String get printerOutputA4Pdf => 'إخراج PDF بحجم A4';

  @override
  String printerOutputPdfReceipt(int width) {
    return 'إخراج إيصال PDF بعرض $width مم';
  }

  @override
  String get printerPdfPageSizeLabel => 'حجم صفحة PDF';

  @override
  String get printerPdfPageSizeHelper =>
      'A4 لطباعة فاتورة كاملة، أو اختر عرض إيصال (58 أو 70 أو 80 مم) لطباعة إيصال مضغوط عبر تعريف الطابعة (مثل Xprinter) بدل أوامر ESC/POS غير المدعومة.';

  @override
  String get printerPdfPageSizeA4 => 'A4 (فاتورة كاملة)';

  @override
  String get printerPdfPageSizeRoll58 => 'إيصال 58 مم';

  @override
  String get printerPdfPageSizeRoll70 => 'إيصال 70 مم';

  @override
  String get printerPdfPageSizeRoll80 => 'إيصال 80 مم';

  @override
  String get printerBarcodeLabelPdfSizeLabel => 'حجم ملصق الباركود';

  @override
  String get printerBarcodeLabelPdfSizeHelper =>
      'شكل ملصق الباركود عند الطباعة عبر تعريف الطابعة. الملصق المقصوص يُطبع بمقاس العرض والارتفاع المحددين أدناه بالضبط، فلا يدور ولا تخرج ملصقات فارغة بعده. على ويندوز اضبط المقاس نفسه في تعريف الطابعة.';

  @override
  String get printerBarcodeLabelPdfSizeSticker =>
      'ملصق مقصوص (بمقاس الملصق أدناه)';

  @override
  String get printerBarcodeLabelPdfSizeRoll50 => 'لفة 50 مم';

  @override
  String get printerBarcodeLabelPdfSizeRoll70 => 'لفة 70 مم';

  @override
  String get printerBarcodeLabelPdfSizeRoll80 => 'لفة 80 مم';

  @override
  String get printerBarcodeLabelPdfSizeA4 => 'A4 (شبكة ملصقات)';

  @override
  String get printerBarcodeLabelCalibrationTitle => 'معايرة مقاس الملصق';

  @override
  String get printerBarcodeLabelCalibrationHelper =>
      'اطبع مسطرة على الملصقات واقرأ الأرقام منها بدل التخمين: المسطرة العرضية تعطيك الإزاحة من اليسار وعرض الملصق، ومسطرة التغذية تعطيك الإزاحة من الأعلى وارتفاع الملصق، والمشط يعطيك المسافة بين الملصقات (العمود الذي يبقى في نفس الارتفاع على كل ملصق هو الصحيح).';

  @override
  String get printerBarcodeLabelCalibrationAcross => 'مسطرة عرضية';

  @override
  String get printerBarcodeLabelCalibrationFeed => 'مسطرة التغذية';

  @override
  String get printerBarcodeLabelCalibrationCombCoarse => 'مشط المسافة (خشن)';

  @override
  String get printerBarcodeLabelCalibrationCombFine => 'مشط المسافة (دقيق)';

  @override
  String get printerBarcodeLabelOffsetYLabel => 'إزاحة الملصق من الأعلى مم';

  @override
  String get printerBarcodeLabelOffsetYHelper =>
      'المسافة من بداية الطباعة إلى الحافة العليا للملصق، في اتجاه التغذية.';

  @override
  String get printerBarcodeLabelPitchLabel => 'المسافة بين الملصقات مم';

  @override
  String get printerBarcodeLabelPitchHelper =>
      'من بداية ملصق إلى بداية الذي يليه (الملصق + الفاصل). تُطبع الدفعة كشريط متصل بهذه المسافة، فلا تنزلق الملصقات مع الطباعة المتتابعة. يقبل الكسور مثل 24.8.';

  @override
  String get printerBarcodeLabelOffsetXLabel => 'إزاحة الملصق من اليسار مم';

  @override
  String get printerBarcodeLabelOffsetXHelper =>
      'المسافة من بداية طباعة الرأس إلى الحافة اليسرى للملصق. اضبطها إذا كانت لفة الملصقات أضيق من عرض الطابعة أو غير محاذية للطرف، فتُطبع الملصقات مزاحة أو مقصوصة.';

  @override
  String get printerBarcodeLabelMediaHelper =>
      'مقاس الملصق كما هو محمّل في الطابعة: العرض بعرض الملصق، والارتفاع من بداية ملصق إلى بداية الذي يليه (الملصق + الفاصل) حتى تتقدّم الطابعة ملصقًا واحدًا في كل مرة.';

  @override
  String get printerBarcodeLabelRotationLabel => 'تدوير الملصق';

  @override
  String get printerBarcodeLabelRotationHelper =>
      'يدوّر محتوى الملصق داخل الملصق نفسه، إذا كانت الطابعة تُغذّي الملصقات بالعرض.';

  @override
  String get printerBarcodeLabelRotation0 => 'بدون تدوير';

  @override
  String get printerBarcodeLabelRotation90 => '90° يمين';

  @override
  String get printerBarcodeLabelRotation180 => '180°';

  @override
  String get printerBarcodeLabelRotation270 => '270° يسار';

  @override
  String get systemDefaultPrinterLabel => 'طابعة النظام الافتراضية';

  @override
  String get posReceiptPrinterRoleTitle => 'إيصال نقطة البيع';

  @override
  String get posReceiptPrinterRoleDescription =>
      'الطابعة الافتراضية لفواتير البيع وإعادة الطباعة من شاشة نقطة البيع.';

  @override
  String get configurePrinterRoleButton => 'اختيار طابعة الإيصال';

  @override
  String get printerRoleDialogTitle => 'طابعة إيصال نقطة البيع';

  @override
  String get printerRoleDialogDoneButton => 'تم';

  @override
  String get selectedPrinterLabel => 'طابعة إيصال نقطة البيع';

  @override
  String get noSelectedPrinter => 'لم يتم اختيار طابعة';

  @override
  String get paperWidthLabel => 'عرض الورق بالملليمتر';

  @override
  String get printerCodeTableLabel => 'جدول ترميز الطابعة';

  @override
  String get printerCapabilityProfileLabel => 'ملف تعريف الطابعة';

  @override
  String get printerCapabilityProfileHelper =>
      'اتركه default إن لم تكن متأكدًا. اختر ملف الشركة المصنعة للطابعات غير المتوافقة.';

  @override
  String get printerCutModeLabel => 'وضع قص الورق';

  @override
  String get printerCutModePartial => 'قص جزئي';

  @override
  String get printerCutModeFull => 'قص كامل';

  @override
  String get printerCutModeNone => 'بدون قص (تغذية فقط)';

  @override
  String get printerFeedLinesLabel => 'أسطر التغذية قبل القص';

  @override
  String get printerFeedLinesHelper =>
      'زدها إذا كان آخر الإيصال يُقطع قبل اكتمال الطباعة.';

  @override
  String get printerCompactReceiptLabel => 'إيصال مضغوط (توفير الورق)';

  @override
  String get printerCompactReceiptHelper =>
      'طباعة بمسافات أضيق وبدون تكبير للعناوين ليستهلك الإيصال ورقًا أقل. يسري على الطابعات الحرارية وطابعات PDF/النظام (مقاس A4 ولفات الإيصالات).';

  @override
  String get barcodeLabelPrinterSettingsTitle => 'إعدادات ملصقات الباركود';

  @override
  String get printerBarcodeLabelLanguageLabel => 'لغة طابعة الملصقات';

  @override
  String get printerBarcodeLabelLanguageAuto => 'اكتشاف تلقائي آمن';

  @override
  String get printerBarcodeLabelLanguageZpl => 'ZPL';

  @override
  String get printerBarcodeLabelLanguageTspl => 'TSPL/TSPL2';

  @override
  String get printerBarcodeLabelLanguageEpl => 'EPL/EPL2';

  @override
  String get printerBarcodeLabelLanguageCpcl => 'CPCL';

  @override
  String get printerBarcodeLabelLanguageEscPos => 'ESC/POS (طابعة إيصالات)';

  @override
  String get detectBarcodeLabelLanguageButton => 'اكتشاف لغة طابعة الملصقات';

  @override
  String get printerLabelWidthLabel => 'عرض الملصق مم';

  @override
  String get printerLabelHeightLabel => 'ارتفاع الملصق مم';

  @override
  String get printerBarcodeLabelHeightHelper =>
      'بوحدات الصفحة لا بمليمترات الورق: تغذية هذه الطابعات أقصر من قياسها الاسمي (٩٪ في LPQ80). اضرب الارتفاع المقاس بالمسطرة في: الخطوة ÷ (الملصق + الفاصل بالمسطرة). للتحقّق: الارتفاع + الفاصل = الخطوة.';

  @override
  String get printerLabelGapLabel => 'الفاصل مم';

  @override
  String get printerLabelDpiLabel => 'الدقة DPI';

  @override
  String printerBarcodeLanguageSummary(String language) {
    return 'لغة الملصقات: $language';
  }

  @override
  String printerLabelGeometrySummary(int width, int height, int gap, int dpi) {
    return 'الملصق: $width×$height مم، فاصل $gap مم، $dpi DPI';
  }

  @override
  String get barcodeLabelLanguageDetected =>
      'تم اكتشاف لغة طابعة الملصقات وحفظها.';

  @override
  String get barcodeLabelLanguageInferred =>
      'تم تخمين لغة طابعة الملصقات من اسم الطابعة. راجعها إذا لم تطبع الملصقات بشكل صحيح.';

  @override
  String get barcodeLabelLanguageDetectionUnavailable =>
      'تعذر اكتشاف لغة الملصقات تلقائيًا. اختر اللغة يدويًا لتجنب إرسال أوامر غير مناسبة.';

  @override
  String get barcodeLabelLanguageDetectionFailed =>
      'فشل اكتشاف لغة طابعة الملصقات. تحقق من الاتصال أو اختر اللغة يدويًا.';

  @override
  String get discoveredPrintersLabel => 'اختر الطابعة';

  @override
  String get selectDiscoveredPrinterHint => 'اختر طابعة';

  @override
  String get noDiscoveredPrinters => 'اضغط على البحث لاكتشاف الطابعات المتاحة';

  @override
  String get discoverPrintersButton => 'اكتشاف الطابعات';

  @override
  String get printerDiscoveryError =>
      'تعذر اكتشاف الطابعات. تحقق من الاتصال وحاول مرة أخرى.';

  @override
  String get checkPrinterConnectionButton => 'فحص الاتصال';

  @override
  String get printerStatusUnknown => 'لم يتم فحص اتصال الطابعة بعد.';

  @override
  String get printerStatusNotConfigured =>
      'اختر طابعة إيصال حتى يبدأ الجهاز بفحص اتصالها.';

  @override
  String get printerStatusChecking => 'جار فحص اتصال الطابعة...';

  @override
  String get printerStatusConnected => 'طابعة الإيصال متصلة وجاهزة.';

  @override
  String get printerStatusDisconnected =>
      'تعذر الاتصال بطابعة الإيصال. تحقق من تشغيلها واتصالها.';

  @override
  String get printerDisconnectedSnackBar =>
      'تعذر الاتصال بطابعة إيصال نقطة البيع.';

  @override
  String get testPrinterButton => 'اختبار الطابعة';

  @override
  String get testingPrinterButton => 'جار الاختبار...';

  @override
  String get testBarcodeLabelPrinterButton => 'اختبار ملصق باركود';

  @override
  String get testingBarcodeLabelPrinterButton => 'جار اختبار الملصق...';

  @override
  String get fakePrintButton => 'طباعة تجريبية بالمحاكاة';

  @override
  String get printerTestSuccess => 'تم إرسال اختبار الطباعة.';

  @override
  String get printerTestFailure =>
      'تعذر اختبار الطابعة. تحقق من الاتصال والإعدادات وحاول مرة أخرى.';

  @override
  String get barcodeLabelTestSuccess => 'تم إرسال ملصق اختبار الباركود.';

  @override
  String get barcodeLabelTestFailure =>
      'تعذر إرسال ملصق اختبار الباركود. تحقق من لغة الملصقات والإعدادات.';

  @override
  String get printerTestUnsupported =>
      'طريقة الاتصال غير متاحة على هذا الجهاز.';

  @override
  String get fakePrintSuccess => 'نجحت الطباعة التجريبية بالمحاكاة.';

  @override
  String get fakePrintFailure => 'تعذرت الطباعة التجريبية بالمحاكاة.';

  @override
  String get saveSettingsButton => 'حفظ الإعدادات';

  @override
  String get catalogTitle => 'المنتجات';

  @override
  String get catalogManagementTitle => 'إدارة المنتجات';

  @override
  String get backTooltip => 'رجوع';

  @override
  String get sampleCatalogNotice =>
      'يتم عرض منتجات تجريبية إلى أن يعمل الخادم.';

  @override
  String get emptyCatalog => 'لا توجد منتجات';

  @override
  String queryNoSearchResultsTitle(String query) {
    return 'لا توجد نتائج لـ «$query»';
  }

  @override
  String get queryNoFilteredResultsTitle =>
      'لا توجد نتائج مطابقة للفلاتر المحددة';

  @override
  String get queryNoResultsMessage =>
      'تحقق من الكتابة، أو امسح البحث والفلاتر لعرض القائمة كاملة.';

  @override
  String get queryClearSearchAndFiltersButton => 'مسح البحث والفلاتر';

  @override
  String get queryNoFiltersResultsMessage => 'امسح الفلاتر لعرض القائمة كاملة.';

  @override
  String get queryClearFiltersButton => 'مسح الفلاتر';

  @override
  String get queryNoSearchResultsMessage =>
      'تحقق من الكتابة، أو امسح البحث لعرض القائمة كاملة.';

  @override
  String get queryClearSearchButton => 'مسح البحث';

  @override
  String catalogNoSearchResultsTitle(String query) {
    return 'لا توجد نتائج لـ «$query»';
  }

  @override
  String get catalogNoFilteredResultsTitle =>
      'لا توجد منتجات مطابقة للفلاتر المحددة';

  @override
  String get catalogNoResultsMessage =>
      'تحقق من الكتابة أو امسح البحث والفلاتر لعرض كل المنتجات.';

  @override
  String get catalogClearSearchAndFiltersButton => 'مسح البحث والفلاتر';

  @override
  String get productListTitle => 'قائمة المنتجات';

  @override
  String get addProductButton => 'إضافة منتج';

  @override
  String get productTableProductColumn => 'المنتج';

  @override
  String get productTableStockColumn => 'المخزون';

  @override
  String get productTablePriceColumn => 'السعر';

  @override
  String get productTableBarcodeColumn => 'الباركود';

  @override
  String get productTableEditColumn => 'تعديل';

  @override
  String get openProductDetailsTooltip => 'فتح تفاصيل المنتج';

  @override
  String get stockStatusAvailable => 'متوفر';

  @override
  String get stockStatusLow => 'منخفض';

  @override
  String get stockStatusOut => 'نافد';

  @override
  String get newProductTitle => 'منتج جديد';

  @override
  String get productNameLabel => 'اسم المنتج';

  @override
  String get productNameHint => 'مثال: قهوة عربية';

  @override
  String get skuLabel => 'رمز المنتج';

  @override
  String get skuHint => 'مثال: COF-100';

  @override
  String get barcodeLabel => 'الباركود';

  @override
  String get barcodeHint => 'اختياري';

  @override
  String get descriptionLabel => 'الوصف';

  @override
  String get descriptionHint => 'تفاصيل قصيرة للمنتج';

  @override
  String get unitPriceLabel => 'السعر';

  @override
  String get productCategoriesLabel => 'تصنيفات المنتج';

  @override
  String get productCategoriesEmpty => 'لا توجد تصنيفات محددة';

  @override
  String get productCategoriesHelper =>
      'اختياري، يساعد في البحث والتصفية داخل نقطة البيع والمشتريات';

  @override
  String get productCategoriesOpenPickerTooltip => 'اختيار التصنيفات';

  @override
  String get productImageLabel => 'صورة المنتج';

  @override
  String get productImageEmpty => 'لم يتم اختيار صورة';

  @override
  String get productImageUploadButton => 'رفع صورة';

  @override
  String get productImageCameraButton => 'التقاط صورة';

  @override
  String get productImageSearchButton => 'بحث في الإنترنت';

  @override
  String get productImageClearSelectionButton => 'إلغاء الاختيار';

  @override
  String get productImagePickError => 'تعذر قراءة الصورة المختارة.';

  @override
  String get productImageCameraUnavailable =>
      'تعذّر فتح الكاميرا على هذا الجهاز.';

  @override
  String get productImageSearchTitle => 'بحث صور المنتج';

  @override
  String get productImageSearchQueryLabel => 'كلمة البحث';

  @override
  String get productImageSearchSubmitButton => 'بحث';

  @override
  String get productImageLoadMoreButton => 'عرض المزيد';

  @override
  String get productImageSearchEmpty => 'لا توجد صور بعد.';

  @override
  String get productImageSearchShortQuery => 'أدخل حرفين على الأقل للبحث.';

  @override
  String get productImageSearchError =>
      'تعذر البحث عن الصور. تحقق من إعداد مزود البحث وحاول مرة أخرى.';

  @override
  String get productImageSearchNotSubscribed =>
      'البحث عن الصور غير مشمول في اشتراك هذا المتجر.';

  @override
  String get productImageAttachError => 'تم حفظ المنتج، لكن تعذر حفظ الصورة.';

  @override
  String get productCategoryPickerTitle => 'اختيار التصنيفات';

  @override
  String get productCategoryPickerEmpty => 'لا توجد تصنيفات مطابقة';

  @override
  String productCategoryFallbackLabel(int id) {
    return 'تصنيف #$id';
  }

  @override
  String get variantOptionValuesLabel => 'قيم الخيارات';

  @override
  String get variantOptionValuesEmpty => 'لا توجد قيم خيارات محددة';

  @override
  String get variantOptionValuesHelper => 'اختياري';

  @override
  String get variantOptionValuesOpenPickerTooltip => 'اختيار قيم الخيارات';

  @override
  String get variantOptionValuePickerTitle => 'اختيار قيم الخيارات';

  @override
  String get variantOptionValuePickerSearchHint => 'ابحث باسم الخيار أو القيمة';

  @override
  String get variantOptionValuePickerEmpty => 'لا توجد قيم خيارات مطابقة';

  @override
  String get variantOptionValuePickerLoadError => 'تعذر تحميل قيم الخيارات.';

  @override
  String variantOptionValueFallbackLabel(int id) {
    return 'قيمة خيار #$id';
  }

  @override
  String get variantOptionsLabel => 'خيارات المنتج';

  @override
  String get variantOptionsHelper =>
      'أضِف خيارًا يميّز المنتج مثل اللون أو المقاس، ثم أدخل قيمه. ستُستخدم القيم لتوليد خيارات المنتج تلقائيًا.';

  @override
  String get variantOptionsEmpty => 'لم تُضِف أي خيار بعد.';

  @override
  String get variantOptionsLoadError => 'تعذر تحميل الخيارات.';

  @override
  String get variantOptionSearchHint => 'ابحث في الخيارات المحفوظة';

  @override
  String get variantOptionSearchOrCreateHint =>
      'ابحث في الخيارات المحفوظة أو اكتب اسمًا جديدًا';

  @override
  String get variantOptionSearchNoMatch => 'لا يوجد خيار مطابق.';

  @override
  String get variantOptionSearchEmpty => 'اكتب اسم الخيار لإنشائه.';

  @override
  String createVariantOptionInline(String name) {
    return 'إنشاء خيار «$name»';
  }

  @override
  String removeVariantOptionTooltip(String name) {
    return 'إزالة $name';
  }

  @override
  String get newVariantOptionTitle => 'خيار جديد';

  @override
  String get variantOptionNameLabel => 'اسم الخيار';

  @override
  String get variantOptionNameHint => 'مثال: اللون';

  @override
  String get variantOptionCodeLabel => 'رمز الخيار';

  @override
  String get variantOptionCodeHint => 'مثال: color';

  @override
  String get createVariantOptionButton => 'حفظ الخيار';

  @override
  String get variantOptionCreateError => 'تعذر إنشاء الخيار.';

  @override
  String get variantValuesNoOptions =>
      'أضِف خيارًا واحدًا على الأقل لتحديد قيمه.';

  @override
  String get variantOptionNoValues => 'لا توجد قيم لهذا الخيار بعد.';

  @override
  String get variantOptionValueRequired => 'اختر قيمة واحدة على الأقل.';

  @override
  String get variantOptionNoValuesSelected => 'لم تُحدد أي قيمة بعد.';

  @override
  String get variantOptionValueSearchHint => 'ابحث في القيم المحفوظة';

  @override
  String get variantOptionValueSearchOrCreateHint =>
      'ابحث في القيم المحفوظة أو اكتب قيمة جديدة';

  @override
  String get variantOptionValueSearchNoMatch => 'لا توجد قيمة مطابقة.';

  @override
  String get variantOptionValueSearchEmpty => 'اكتب اسم القيمة لإنشائها.';

  @override
  String createVariantOptionValueInline(String name) {
    return 'إنشاء قيمة «$name»';
  }

  @override
  String removeVariantOptionValueTooltip(String name) {
    return 'إزالة $name';
  }

  @override
  String selectAllVariantOptionValues(int count) {
    return 'إضافة الكل ($count)';
  }

  @override
  String variantOptionSelectedValuesCount(int count) {
    return '$count محددة';
  }

  @override
  String get newVariantOptionValueTitle => 'قيمة خيار جديدة';

  @override
  String get variantOptionValueNameLabel => 'اسم القيمة';

  @override
  String get variantOptionValueNameHint => 'مثال: أحمر';

  @override
  String get variantOptionValueCodeLabel => 'رمز القيمة';

  @override
  String get variantOptionValueCodeHint => 'مثال: red';

  @override
  String get createVariantOptionValueButton => 'حفظ القيمة';

  @override
  String get variantOptionValueCreateError => 'تعذر إنشاء قيمة الخيار.';

  @override
  String get skuPrefixLabel => 'بادئة الرمز';

  @override
  String get skuPrefixHint => 'مثال: IPHONE';

  @override
  String get generatedVariantPriceLabel => 'سعر الخيارات المولدة';

  @override
  String get generatedVariantsEmpty => 'اختر قيم الخيارات لعرض كل التركيبات.';

  @override
  String generatedVariantsCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count خيارات مولدة',
      two: 'خياران مولدان',
      one: 'خيار واحد مولد',
      zero: 'لا توجد خيارات مولدة',
    );
    return '$_temp0';
  }

  @override
  String get generatedVariantNameLabel => 'اسم الخيار';

  @override
  String get generatedVariantsMissingValues =>
      'اختر قيمة واحدة على الأقل لكل خيار.';

  @override
  String get generatedVariantsTooMany =>
      'عدد الخيارات المولدة كبير جدًا. قلل القيم المحددة.';

  @override
  String skuTakenError(String owner) {
    return 'رمز المنتج مستخدم في \"$owner\"';
  }

  @override
  String barcodeTakenError(String owner) {
    return 'الباركود مستخدم في \"$owner\"';
  }

  @override
  String barcodeTakenByUnitError(String unit, String owner) {
    return 'الباركود مسجَّل كباركود عبوة ($unit) للمنتج \"$owner\"';
  }

  @override
  String get skuTakenUnknownOwner => 'رمز المنتج مستخدم في منتج آخر';

  @override
  String get barcodeTakenUnknownOwner => 'الباركود مستخدم في منتج آخر';

  @override
  String get identityArchivedOwnerSuffix => '(منتج مؤرشف)';

  @override
  String get skuDuplicateInFormError => 'رمز المنتج مكرر داخل هذا النموذج';

  @override
  String get barcodeDuplicateInFormError => 'الباركود مكرر داخل هذا النموذج';

  @override
  String get identityCodeClaimedDuringSave =>
      'تم حجز هذا الرمز من جهاز آخر أثناء الحفظ. أعد المحاولة برمز مختلف.';

  @override
  String get identityCheckingLabel => 'جارٍ التحقق...';

  @override
  String get skuAvailableLabel => 'الرمز متاح';

  @override
  String get barcodeAvailableLabel => 'الباركود متاح';

  @override
  String get identityCheckUnavailableLabel => 'تعذر التحقق من التوفر الآن';

  @override
  String get formFixHighlightedFieldsError =>
      'راجع الحقول المعلَّمة بالأحمر ثم أعد المحاولة.';

  @override
  String get generatedVariantsNoMissing =>
      'كل التركيبات المحددة موجودة بالفعل.';

  @override
  String get generateVariantsTitle => 'توليد الخيارات';

  @override
  String get generateVariantsButton => 'توليد الخيارات';

  @override
  String get variantsGeneratedMessage => 'تم حفظ الخيارات المولدة';

  @override
  String get variantGenerateError =>
      'تعذر توليد الخيارات. راجع البيانات وحاول مرة أخرى.';

  @override
  String get productVariantOptionsTitle => 'خيارات المنتج';

  @override
  String get productVariantOptionsEmpty => 'لا توجد خيارات مرتبطة بهذا المنتج.';

  @override
  String get reloadButton => 'إعادة التحميل';

  @override
  String get categoryFilterTitle => 'التصنيف';

  @override
  String get categoryManagementTitle => 'إدارة التصنيفات';

  @override
  String get addCategoryButton => 'إضافة تصنيف';

  @override
  String get newCategoryTitle => 'تصنيف جديد';

  @override
  String get categoryNameLabel => 'اسم التصنيف';

  @override
  String get parentCategoryLabel => 'التصنيف الأب';

  @override
  String get noParentCategory => 'تصنيف رئيسي';

  @override
  String get parentCategoryHelper => 'اختياري، اختر أبًا لإنشاء تصنيف فرعي';

  @override
  String get activeCategoryLabel => 'تصنيف نشط';

  @override
  String get createCategoryButton => 'إنشاء التصنيف';

  @override
  String get creatingCategoryButton => 'جار الإنشاء...';

  @override
  String get categoryCreateError =>
      'تعذر إنشاء التصنيف. راجع البيانات وحاول مرة أخرى.';

  @override
  String get categoryEmptyState => 'لا توجد تصنيفات بعد.';

  @override
  String get rootCategoryLabel => 'تصنيف رئيسي';

  @override
  String get categoryExpandTooltip => 'عرض الفروع';

  @override
  String get categoryCollapseTooltip => 'إخفاء الفروع';

  @override
  String get categoryLoadingChildren => 'جار تحميل الفروع...';

  @override
  String get categoryChildrenLoadError => 'تعذر تحميل الفروع.';

  @override
  String get categoryLoadMoreChildrenButton => 'تحميل فروع إضافية';

  @override
  String categoryParentValue(String parent) {
    return 'ضمن $parent';
  }

  @override
  String categoryChildrenCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count فروع',
      two: 'فرعان',
      one: 'فرع واحد',
      zero: 'لا توجد فروع',
    );
    return '$_temp0';
  }

  @override
  String categoryProductCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count منتجات',
      two: 'منتجان',
      one: 'منتج واحد',
      zero: 'لا منتجات',
    );
    return '$_temp0';
  }

  @override
  String get allCategoriesSectionTitle => 'كل التصنيفات';

  @override
  String get categorySearchResultsTitle => 'نتائج البحث';

  @override
  String get categorySearchEmptyState => 'لا توجد تصنيفات مطابقة لبحثك.';

  @override
  String get categoryEmptyHint => 'أنشئ تصنيفك الأول لتنظيم منتجاتك.';

  @override
  String get categoryInactiveBadge => 'غير نشط';

  @override
  String get categoryActionsTooltip => 'خيارات';

  @override
  String get addSubcategoryAction => 'إضافة تصنيف فرعي';

  @override
  String get editCategoryTitle => 'تعديل التصنيف';

  @override
  String get savingCategoryButton => 'جار الحفظ...';

  @override
  String get categoryUpdateError => 'تعذر حفظ التغييرات. حاول مرة أخرى.';

  @override
  String get categoryDeletedMessage => 'تم حذف التصنيف';

  @override
  String get categoryDeleteError => 'تعذر حذف التصنيف.';

  @override
  String get deleteCategoryTitle => 'حذف التصنيف';

  @override
  String deleteCategoryConfirmMessage(String name) {
    return 'سيتم حذف «$name» نهائيًا.';
  }

  @override
  String get deleteCategoryHasChildrenTitle => 'تعذر حذف التصنيف';

  @override
  String get deleteCategoryHasChildrenMessage =>
      'يحتوي هذا التصنيف على فروع. احذف أو انقل التصنيفات الفرعية أولًا.';

  @override
  String get quickAccessSectionTitle => 'الوصول السريع';

  @override
  String get quickAccessSectionSubtitle =>
      'تظهر كأزرار تصفية فوق البحث في نقطة البيع والمشتريات.';

  @override
  String get quickAccessEmptyTitle => 'لا توجد تصنيفات سريعة بعد';

  @override
  String get quickAccessEmptyMessage =>
      'ثبّت تصنيفًا ليظهر كزر تصفية بنقرة واحدة. تشمل التصفية التصنيف وكل فروعه.';

  @override
  String get quickAccessReorderHint => 'اسحب الأزرار لإعادة ترتيبها';

  @override
  String get quickAccessLoadError => 'تعذر تحميل الوصول السريع.';

  @override
  String get quickAccessUpdateError => 'تعذر تحديث الوصول السريع.';

  @override
  String get pinToQuickAccessTooltip => 'تثبيت في الوصول السريع';

  @override
  String get unpinFromQuickAccessTooltip => 'إزالة من الوصول السريع';

  @override
  String quickAccessAddedMessage(String name) {
    return '$name في الوصول السريع الآن';
  }

  @override
  String quickAccessRemovedMessage(String name) {
    return 'تمت إزالة $name من الوصول السريع';
  }

  @override
  String get quickAccessSwitchLabel => 'إظهار في الوصول السريع';

  @override
  String get quickAccessSwitchHelper =>
      'زر تصفية سريع في نقطة البيع والمشتريات';

  @override
  String get activeProductLabel => 'متاح للبيع';

  @override
  String get applyButton => 'تطبيق';

  @override
  String get bulkSelectTooltip => 'تحديد متعدد';

  @override
  String bulkSelectedCount(int count) {
    return '$count محدد';
  }

  @override
  String get bulkSelectAllAction => 'تحديد الكل';

  @override
  String get bulkClearSelectionAction => 'مسح التحديد';

  @override
  String get bulkArchiveAction => 'أرشفة';

  @override
  String get bulkRestoreAction => 'استعادة';

  @override
  String get bulkRepriceAction => 'تعديل السعر';

  @override
  String get bulkCategorizeAction => 'تصنيف';

  @override
  String get bulkFlagsAction => 'الخصائص';

  @override
  String get bulkArchiveConfirmTitle => 'أرشفة المنتجات المحددة؟';

  @override
  String bulkArchiveConfirmMessage(int count) {
    return 'سيتم أرشفة $count منتج وإخفاؤها من القوائم ونقطة البيع. يمكن استعادتها لاحقًا.';
  }

  @override
  String get bulkRestoreConfirmTitle => 'استعادة المنتجات المحددة؟';

  @override
  String bulkRestoreConfirmMessage(int count) {
    return 'سيتم إعادة $count منتج إلى القوائم.';
  }

  @override
  String bulkActionSuccess(int count) {
    return 'تم تحديث $count منتج';
  }

  @override
  String get bulkActionError => 'تعذّر تنفيذ العملية، حاول مرة أخرى.';

  @override
  String get bulkActionNoChanges => 'لم يتغيّر أي منتج.';

  @override
  String get bulkRepriceTitle => 'تعديل أسعار المنتجات المحددة';

  @override
  String get bulkRepriceModeLabel => 'طريقة التعديل';

  @override
  String get bulkRepriceModeSet => 'تعيين سعر موحّد';

  @override
  String get bulkRepriceModeIncreasePercent => 'زيادة بنسبة %';

  @override
  String get bulkRepriceModeDecreasePercent => 'خصم بنسبة %';

  @override
  String get bulkRepriceModeIncreaseAmount => 'زيادة بمبلغ';

  @override
  String get bulkRepriceModeDecreaseAmount => 'خصم بمبلغ';

  @override
  String get bulkRepricePercentLabel => 'النسبة';

  @override
  String get bulkRepriceAmountLabel => 'المبلغ';

  @override
  String get bulkRepriceValueRequired => 'أدخل قيمة صحيحة.';

  @override
  String get bulkCategorizeTitle => 'تصنيف المنتجات المحددة';

  @override
  String get bulkCategorizeModeLabel => 'الإجراء';

  @override
  String get bulkCategorizeModeAdd => 'إضافة تصنيفات';

  @override
  String get bulkCategorizeModeReplace => 'استبدال التصنيفات';

  @override
  String get bulkCategorizeModeRemove => 'إزالة تصنيفات';

  @override
  String get bulkCategorizePickButton => 'اختيار التصنيفات';

  @override
  String bulkCategorizePickedCount(int count) {
    return '$count تصنيف محدد';
  }

  @override
  String get bulkFlagsTitle => 'تعديل خصائص المنتجات المحددة';

  @override
  String get bulkFlagNoChange => 'بدون تغيير';

  @override
  String get bulkFlagOn => 'تشغيل';

  @override
  String get bulkFlagOff => 'إيقاف';

  @override
  String get productTracksExpiryLabel => 'يتابع تاريخ الانتهاء';

  @override
  String get productTracksExpiryHint =>
      'سيطلب تاريخ انتهاء عند شراء هذا المنتج ويظهر تنبيه قبل انتهائه.';

  @override
  String get activeVariantLabel => 'متاح للبيع';

  @override
  String get defaultVariantLabel => 'الخيار الافتراضي';

  @override
  String get variantNameLabel => 'اسم الخيار';

  @override
  String get variantNameHint => 'مثال: كبير أو أحمر';

  @override
  String get parentProductStepTitle => 'بيانات المنتج';

  @override
  String get defaultVariantStepTitle => 'الخيار الافتراضي';

  @override
  String productWizardStepLabel(int step, int total) {
    return '$step من $total';
  }

  @override
  String get backButton => 'السابق';

  @override
  String get nextButton => 'التالي';

  @override
  String get createProductButton => 'إنشاء المنتج';

  @override
  String get creatingProductButton => 'جار الإنشاء...';

  @override
  String get saveProductButton => 'حفظ المنتج';

  @override
  String get editProductButton => 'تعديل المنتج';

  @override
  String get requiredField => 'هذا الحقل مطلوب';

  @override
  String get invalidNumber => 'أدخل رقمًا صحيحًا';

  @override
  String get invalidDate => 'أدخل تاريخًا صحيحًا';

  @override
  String get productCreatedMessage => 'تم إنشاء المنتج';

  @override
  String get productUpdatedMessage => 'تم حفظ المنتج';

  @override
  String get productCreatedImageAttachError =>
      'تم إنشاء المنتج، لكن تعذر حفظ الصورة.';

  @override
  String get productCreateError =>
      'تعذر إنشاء المنتج. راجع البيانات وحاول مرة أخرى.';

  @override
  String get productUpdateError =>
      'تعذر حفظ المنتج. راجع البيانات وحاول مرة أخرى.';

  @override
  String get catalogLoadError => 'تعذر تحميل المنتجات من الخادم.';

  @override
  String get activeStatus => 'متاح';

  @override
  String get inactiveStatus => 'متوقف';

  @override
  String get archivedStatus => 'مؤرشف';

  @override
  String get archivedFilterLabel => 'المؤرشفة';

  @override
  String get viewArchivedProductsAction => 'عرض المنتجات المؤرشفة';

  @override
  String get viewActiveProductsAction => 'عرض المنتجات النشطة';

  @override
  String get archiveProductAction => 'أرشفة';

  @override
  String get restoreProductAction => 'استعادة';

  @override
  String get archiveProductConfirmTitle => 'أرشفة المنتج';

  @override
  String archiveProductConfirmMessage(String name) {
    return 'سيتم إخفاء «$name» من نقطة البيع والمشتريات وقائمة المنتجات، مع إمكانية استعادته لاحقًا.';
  }

  @override
  String get archiveProductSuccess => 'تمت أرشفة المنتج';

  @override
  String get archiveProductError => 'تعذرت أرشفة المنتج. حاول مرة أخرى.';

  @override
  String get restoreProductSuccess => 'تمت استعادة المنتج';

  @override
  String get restoreProductError => 'تعذرت استعادة المنتج. حاول مرة أخرى.';

  @override
  String get productDetailsTitle => 'تفاصيل المنتج';

  @override
  String get catalogSelectProductPlaceholder =>
      'اختر منتجًا من القائمة لعرض تفاصيله.';

  @override
  String get invoicesSelectInvoicePlaceholder =>
      'اختر فاتورة من القائمة لعرض تفاصيلها.';

  @override
  String get contactsSelectContactPlaceholder =>
      'اختر جهة من القائمة لعرض تفاصيلها.';

  @override
  String get discountsSelectDiscountPlaceholder =>
      'اختر قاعدة خصم من القائمة لعرض تفاصيلها.';

  @override
  String reportLastCompletedMessage(String action, String report) {
    return 'آخر إجراء ناجح: $action — $report';
  }

  @override
  String get reportRunAgainButton => 'تشغيل مجددًا';

  @override
  String get variantDetailsTitle => 'تفاصيل الخيار';

  @override
  String get productDetailLoadError => 'تعذر تحميل تفاصيل المنتج.';

  @override
  String get productSummaryTitle => 'ملخص المنتج';

  @override
  String get productPriceTitle => 'السعر';

  @override
  String get productTotalStockLabel => 'إجمالي المخزون';

  @override
  String get productNoCategories => 'لا توجد تصنيفات';

  @override
  String get productVariantsTitle => 'الخيارات';

  @override
  String get addVariantButton => 'إضافة خيار';

  @override
  String get noVariants => 'لا توجد خيارات لهذا المنتج.';

  @override
  String get newVariantTitle => 'خيار جديد';

  @override
  String get editVariantTitle => 'تعديل الخيار';

  @override
  String get createVariantButton => 'إنشاء الخيار';

  @override
  String get saveVariantButton => 'حفظ الخيار';

  @override
  String get variantCreatedMessage => 'تم إنشاء الخيار';

  @override
  String get variantUpdatedMessage => 'تم حفظ الخيار';

  @override
  String get variantCreateError =>
      'تعذر إنشاء الخيار. راجع البيانات وحاول مرة أخرى.';

  @override
  String get variantUpdateError =>
      'تعذر حفظ الخيار. راجع البيانات وحاول مرة أخرى.';

  @override
  String get variantNameColumn => 'الخيار';

  @override
  String get variantStockColumn => 'المخزون';

  @override
  String get variantPriceColumn => 'السعر';

  @override
  String get variantSkuColumn => 'الرمز';

  @override
  String get variantBarcodeColumn => 'الباركود';

  @override
  String get variantStatusColumn => 'الحالة';

  @override
  String get actionsColumn => 'إجراءات';

  @override
  String get openVariantDetailsTooltip => 'فتح تفاصيل الخيار';

  @override
  String get defaultVariantBadge => 'افتراضي';

  @override
  String get productCostHistoryTitle => 'تكلفة الشراء والهامش';

  @override
  String get productCostHistoryLoadError =>
      'تعذر تحميل تاريخ تكلفة الشراء لهذا المنتج.';

  @override
  String get productCostHistoryEmpty =>
      'لا توجد مشتريات مسجلة لهذا المنتج بعد.';

  @override
  String productCostHistoryPackCost(String cost, String unit) {
    return '$cost لكل $unit';
  }

  @override
  String get productDocumentHistoryTitle => 'الفواتير المرتبطة';

  @override
  String get productRecentInvoicesTitle => 'فواتير البيع الأخيرة';

  @override
  String get productRecentPurchaseBillsTitle => 'فواتير الشراء الأخيرة';

  @override
  String get productRecentInvoicesLoadError =>
      'تعذر تحميل فواتير البيع لهذا المنتج.';

  @override
  String get productRecentPurchaseBillsLoadError =>
      'تعذر تحميل فواتير الشراء لهذا المنتج.';

  @override
  String get productRecentInvoicesEmpty =>
      'لم يظهر هذا المنتج في أي فاتورة بيع بعد.';

  @override
  String get productRecentPurchaseBillsEmpty =>
      'لم يظهر هذا المنتج في أي فاتورة شراء بعد.';

  @override
  String get productBoughtTogetherTitle => 'يُشترى عادةً مع';

  @override
  String get productBoughtTogetherSubtitle =>
      'منتجات يضيفها العملاء عادةً إلى الطلب نفسه.';

  @override
  String productBoughtTogetherOrders(String count) {
    return 'في $count طلبًا';
  }

  @override
  String get productLatestCostLabel => 'آخر تكلفة';

  @override
  String get productGrossProfitLabel => 'ربح القطعة';

  @override
  String get productMarginPercentLabel => 'هامش الربح';

  @override
  String productMarginPercentValue(String percent) {
    return '$percent%';
  }

  @override
  String get productCostChangeLabel => 'تغير التكلفة';

  @override
  String get productMarginChangeLabel => 'تغير الهامش';

  @override
  String get productPricingAndCostTitle => 'التسعير والتكلفة';

  @override
  String get productCostOverviewTitle => 'نظرة عامة على التكلفة';

  @override
  String get lowestCostLabel => 'أقل تكلفة';

  @override
  String get highestCostLabel => 'أعلى تكلفة';

  @override
  String get lastCostLabel => 'آخر تكلفة';

  @override
  String get averageCostLabel => 'متوسط التكلفة';

  @override
  String get currentPriceLabel => 'السعر الحالي';

  @override
  String get noCostDataLabel => 'لا توجد بيانات تكلفة بعد';

  @override
  String get changePricesButton => 'تغيير الأسعار';

  @override
  String get changePricesTitle => 'تغيير الأسعار';

  @override
  String get changePricesSubtitle =>
      'راجع تكلفة كل خيار وحدّد سعر البيع الجديد بثقة.';

  @override
  String get changePricesNewPriceLabel => 'السعر الجديد';

  @override
  String get changePricesSaveButton => 'حفظ الأسعار';

  @override
  String get changePricesSuccess => 'تم تحديث الأسعار.';

  @override
  String get changePricesError => 'تعذر تحديث الأسعار. حاول مرة أخرى.';

  @override
  String get changePricesLoadError => 'تعذر تحميل بيانات التكلفة.';

  @override
  String get changePricesNoVariants => 'لا توجد خيارات لتسعيرها.';

  @override
  String get productIdentifierTitle => 'بيانات التعريف';

  @override
  String get productDescriptionTitle => 'الوصف';

  @override
  String get productAvailabilityTitle => 'حالة البيع';

  @override
  String get productAvailableForSale => 'هذا المنتج متاح للبيع في نقطة البيع.';

  @override
  String get productUnavailableForSale => 'هذا المنتج متوقف ولا يظهر للبيع.';

  @override
  String get stockSummaryTitle => 'المخزون';

  @override
  String get stockOnHandLabel => 'المتاح';

  @override
  String get stockLoadError => 'تعذر تحميل المخزون.';

  @override
  String get stockMovementsButton => 'حركات المخزون';

  @override
  String get stockMovementsTitle => 'حركات المخزون';

  @override
  String get emptyStockMovements => 'لا توجد حركات مخزون لهذا المنتج.';

  @override
  String get stockMovementLoadError => 'تعذر تحميل حركات المخزون.';

  @override
  String get newStockMovementButton => 'حركة مخزون جديدة';

  @override
  String get newStockMovementTitle => 'حركة مخزون جديدة';

  @override
  String get stockMovementTypeLabel => 'نوع الحركة';

  @override
  String get stockMovementQuantityLabel => 'الكمية';

  @override
  String get stockMovementNoteLabel => 'ملاحظة';

  @override
  String get saveStockMovementButton => 'حفظ الحركة';

  @override
  String get stockMovementCreateError =>
      'تعذر حفظ حركة المخزون. راجع الكمية وحاول مرة أخرى.';

  @override
  String get stockMovementIncrease => 'زيادة المخزون';

  @override
  String get stockMovementDecrease => 'نقص المخزون';

  @override
  String get stockMovementDamaged => 'تالف';

  @override
  String stockMovementQuantityValue(String quantity) {
    return '$quantity قطعة';
  }

  @override
  String get barcodeLabelPrintTitle => 'طباعة ملصق الباركود';

  @override
  String get barcodeLabelPrintButton => 'طباعة ملصقات';

  @override
  String get barcodeLabelPrintInProgressButton => 'جار الطباعة...';

  @override
  String get barcodeLabelPrintNoBarcode =>
      'أضف باركودًا للمنتج قبل طباعة الملصق.';

  @override
  String get barcodeLabelPrintNoBarcodeShort => 'لا يوجد باركود للطباعة';

  @override
  String get barcodeLabelCopiesDialogTitle => 'طباعة ملصقات الباركود';

  @override
  String get barcodeLabelCopiesLabel => 'عدد النسخ';

  @override
  String get barcodeLabelCopiesHint => 'مثال: 10';

  @override
  String get barcodeLabelCopiesPrintButton => 'طباعة';

  @override
  String get barcodeLabelIncludePriceLabel => 'طباعة السعر';

  @override
  String get barcodeLabelIncludePriceHint => 'إظهار سعر البيع على الملصق.';

  @override
  String get barcodeLabelIncludeExpiryLabel => 'طباعة تاريخ الانتهاء';

  @override
  String get barcodeLabelIncludeExpiryHint =>
      'إضافة تاريخ انتهاء الدفعة على الملصق.';

  @override
  String get barcodeLabelExpiryDateLabel => 'تاريخ الانتهاء';

  @override
  String get barcodeLabelExpiryDatePickerTooltip => 'اختيار تاريخ الانتهاء';

  @override
  String get barcodeLabelExpiryDateRequired =>
      'اختر تاريخ الانتهاء أو أوقف طباعته.';

  @override
  String get barcodeLabelPreviewTitle => 'معاينة الملصق';

  @override
  String barcodeLabelPreviewPrice(String price) {
    return 'السعر $price';
  }

  @override
  String barcodeLabelPreviewExpiry(String date) {
    return 'الانتهاء $date';
  }

  @override
  String get barcodeLabelPrintProductTooltip => 'طباعة ملصقات المنتج';

  @override
  String get barcodeLabelPrintVariantTooltip => 'طباعة ملصقات الخيار';

  @override
  String barcodeLabelPrintSuccess(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'تم إرسال $count ملصقات باركود للطابعة.',
      two: 'تم إرسال ملصقي باركود للطابعة.',
      one: 'تم إرسال ملصق باركود واحد للطابعة.',
    );
    return '$_temp0';
  }

  @override
  String get barcodeLabelPrintError =>
      'تعذرت طباعة ملصق الباركود. تحقق من إعدادات الطابعة.';

  @override
  String get noBarcode => 'لا يوجد باركود';

  @override
  String get noDescription => 'لا يوجد وصف لهذا المنتج';

  @override
  String get posProductLookupHint => 'ابحث عن منتج أو امسح الباركود';

  @override
  String get posAllProductsFilterLabel => 'الكل';

  @override
  String posVariantPickerTitle(String productName) {
    return 'اختيار خيار $productName';
  }

  @override
  String posVariantPickerStock(String quantity) {
    return 'المتاح $quantity';
  }

  @override
  String get posProductHasNoActiveVariants =>
      'لا توجد خيارات نشطة لهذا المنتج.';

  @override
  String get clearBarcodeStatusTooltip => 'إخفاء حالة الباركود';

  @override
  String get barcodeScanResolving => 'جار البحث عن الباركود...';

  @override
  String barcodeScanAdded(String productName) {
    return 'تمت إضافة $productName';
  }

  @override
  String barcodeScanNotFound(String barcode) {
    return 'لم يتم العثور على منتج للباركود $barcode';
  }

  @override
  String get barcodeScanError => 'تعذر البحث عن الباركود. حاول مرة أخرى.';

  @override
  String get manageScaleRulesTooltip => 'إعداد ملصقات الميزان';

  @override
  String get scaleRulesTitle => 'ملصقات الميزان';

  @override
  String get scaleRulesIntroTitle => 'كيف يقرأ الصندوق ملصق الميزان';

  @override
  String get scaleRulesIntroMessage =>
      'الميزان يطبع باركود يحمل رمز الصنف والوزن أو السعر. نفس الأرقام تعني وزناً على ميزان وسعراً على آخر، فلا يُخمَّن شيء: عرّف هنا تنسيق كل ميزان لديك. الباركود الذي لا يطابق أي تنسيق يُعامل باركوداً عادياً.';

  @override
  String get addScaleRuleButton => 'إضافة تنسيق';

  @override
  String get scaleRuleEditTitle => 'تنسيق ملصق';

  @override
  String get scaleRuleNameLabel => 'الاسم';

  @override
  String get scaleRuleNameHint => 'ميزان الخضار';

  @override
  String get scaleRulePrefixLabel => 'يبدأ الباركود بـ';

  @override
  String get scaleRuleItemDigitsLabel => 'خانات رمز الصنف';

  @override
  String get scaleRuleValueDigitsLabel => 'خانات القيمة';

  @override
  String get scaleRuleValueKindLabel => 'القيمة المطبوعة هي';

  @override
  String get scaleRuleValueKindWeight => 'وزن';

  @override
  String get scaleRuleValueKindPrice => 'سعر';

  @override
  String get scaleRuleValueKindCount => 'عدد';

  @override
  String get scaleRuleDecimalsLabel => 'منازل عشرية';

  @override
  String get scaleRuleUnitLabel => 'وحدة الوزن';

  @override
  String get scaleRuleRequireCheckDigitLabel => 'تحقّق من خانة المراجعة';

  @override
  String get scaleRuleRequireCheckDigitHint =>
      'أوقفه فقط إذا كان ميزانك يطبع خانة مراجعة خاطئة.';

  @override
  String get scaleRuleActiveLabel => 'مُفعّل';

  @override
  String get scaleRulePatternLabel => 'النمط';

  @override
  String get scaleRulePatternHelp =>
      'رقم = ثابت · I = رمز الصنف · V = القيمة · C = خانة المراجعة · X = يُتجاهل';

  @override
  String get scaleRulePatternInvalid => 'نمط غير صالح.';

  @override
  String get scaleRuleExampleLabel => 'مثال';

  @override
  String scaleRulePlainSummary(String prefix, int itemDigits, String value) {
    return 'يبدأ بـ $prefix · $itemDigits خانات للصنف · $value';
  }

  @override
  String get scaleRuleValueWeight => 'ثم الوزن';

  @override
  String get scaleRuleValuePrice => 'ثم السعر';

  @override
  String get scaleRuleValueCount => 'ثم العدد';

  @override
  String scaleRuleExampleReads(String barcode, String reading) {
    return 'مثال: $barcode ← $reading';
  }

  @override
  String get scaleRuleTryTitle => 'جرّب ملصقاً';

  @override
  String get scaleRuleTryDescription =>
      'امسك ملصقاً طبعه ميزانك ومرّره على القارئ — سيظهر هنا كيف يقرأه الصندوق.';

  @override
  String get scaleRuleTryHint => 'امسح أو الصق باركوداً طبعه الميزان';

  @override
  String get scaleRuleTryUnreadable =>
      'لا يطابق أي تنسيق مُفعّل. سيُقرأ باركوداً عادياً.';

  @override
  String scaleRuleTryResult(String itemCode, String value) {
    return 'الصنف $itemCode · $value';
  }

  @override
  String get scaleRuleSaveError => 'تعذّر حفظ التنسيق.';

  @override
  String get scaleRuleDeleteTitle => 'حذف التنسيق؟';

  @override
  String get scaleRuleDeleteMessage =>
      'لن يُقرأ أي ملصق بهذا التنسيق بعد الحذف.';

  @override
  String get scaleRulesEmpty => 'لا توجد تنسيقات بعد.';

  @override
  String get scalesTitle => 'الموازين';

  @override
  String get scalesNavLabel => 'الموازين';

  @override
  String get scalesIntroTitle => 'الميزان يحمل نسخته من الأسعار';

  @override
  String get scalesIntroMessage =>
      'الميزان يطبع السعر على الملصق من جدول داخله. إن لم يوافق جدول الميزان الكتالوج فللمحل سعران ولا أحد يعرف بأيّهما باع. أرسل الأسعار من هنا بدل إدخالها في الميزان يدوياً.';

  @override
  String get addScaleButton => 'إضافة ميزان';

  @override
  String get scaleEditTitle => 'ميزان';

  @override
  String get scaleNameLabel => 'الاسم';

  @override
  String get scaleTypeLabel => 'نوع الميزان';

  @override
  String get scaleHostLabel => 'عنوان الميزان في الشبكة';

  @override
  String get scalePortLabel => 'المنفذ';

  @override
  String get scaleDepartmentLabel => 'رقم القسم في الميزان';

  @override
  String get scaleActiveLabel => 'مُفعّل';

  @override
  String get scaleCheckAction => 'اختبار الاتصال';

  @override
  String get scalePushAction => 'إرسال الأسعار';

  @override
  String get scaleExportAction => 'تنزيل ملف الأسعار';

  @override
  String get scaleExportFallbackAction => 'تنزيل الملف بدل الإرسال';

  @override
  String get scaleReachableMessage => 'الميزان يستجيب.';

  @override
  String get scaleUnreachableMessage => 'لا يوجد رد من الميزان.';

  @override
  String get scaleSaveError => 'تعذّر حفظ الميزان.';

  @override
  String get scaleDeleteTitle => 'حذف الميزان؟';

  @override
  String get scaleDeleteMessage => 'سيُحذف الميزان وسجلّ عمليات الإرسال إليه.';

  @override
  String get scalePushExportedMessage =>
      'أُنشئ الملف. الأسعار لن تتغيّر في الميزان حتى تُحمّل الملف إليه.';

  @override
  String scalePushSucceededMessage(int count) {
    return 'وصلت $count أصناف إلى الميزان.';
  }

  @override
  String scalePushPartialMessage(int sent, int failed) {
    return 'وصل $sent ولم يصل $failed.';
  }

  @override
  String get scalePushFailedMessage => 'لم يصل شيء إلى الميزان.';

  @override
  String get scaleLastPushNever => 'لم يُرسل شيء بعد.';

  @override
  String get scaleStatusNeverPushed => 'لم يُرسل';

  @override
  String get scaleStatusWaitingToLoad => 'بانتظار التحميل';

  @override
  String get scaleStatusUpToDate => 'محدَّث';

  @override
  String get scaleStatusPartial => 'ناقص';

  @override
  String get scaleStatusFailed => 'فشل';

  @override
  String get scaleDriverLineFile => 'يُحمَّل بملف';

  @override
  String get scaleAddressLineLabel => 'العنوان';

  @override
  String scaleAssignedCount(int count) {
    return '$count صنفاً على الموازين';
  }

  @override
  String get scalePlusSectionTitle => 'الأصناف على الموازين';

  @override
  String get scalePlusEmpty =>
      'لا يوجد صنف على الموازين بعد. أضف الأصناف التي تُوزن.';

  @override
  String get scaleAssignPluButton => 'إضافة صنف';

  @override
  String get scaleAssignPluHint => 'ابحث بالاسم أو الباركود';

  @override
  String get scaleAssignPluTitle => 'إضافة صنف إلى الموازين';

  @override
  String get scalePluRetireAction => 'إيقاف';

  @override
  String get scalePluRestoreAction => 'إعادة تفعيل';

  @override
  String get scalePluRetiredNote =>
      'الرقم لا يُعاد استخدامه؛ قد تكون ملصقاته ما زالت في المحل.';

  @override
  String get scalesEmpty => 'لا توجد موازين معرّفة.';

  @override
  String scaleLabelWarnNotFractional(String productName) {
    return '$productName: هذا المنتج يُباع بالعدد، فلم يُؤخذ الوزن من ملصق الميزان.';
  }

  @override
  String scaleLabelWarnUnitMismatch(String productName) {
    return '$productName: وحدة ملصق الميزان لا تناسب وحدة المنتج، فلم تُؤخذ الكمية من الملصق.';
  }

  @override
  String scaleLabelWarnNoUnitPrice(String productName) {
    return '$productName: سعر المنتج صفر، فتعذّر حساب الكمية من سعر الملصق.';
  }

  @override
  String scaleLabelWarnRoundingDrift(
    String productName,
    String labelTotal,
    String rungTotal,
  ) {
    return '$productName: الملصق $labelTotal والمسجَّل $rungTotal.';
  }

  @override
  String get cameraScannerSingleTitle => 'مسح باركود';

  @override
  String get cameraScannerMultipleTitle => 'مسح عدة منتجات';

  @override
  String get cameraScannerStarting => 'جار تشغيل الكاميرا...';

  @override
  String get cameraScannerPermissionError =>
      'لم يُسمح للتطبيق باستخدام الكاميرا. امنح الإذن من إعدادات الجهاز ثم أعد المحاولة.';

  @override
  String get cameraScannerNoCameraError =>
      'لا توجد كاميرا متاحة على هذا الجهاز. استخدم قارئ الباركود أو ابحث عن المنتج بالاسم.';

  @override
  String get cameraScannerGenericError =>
      'تعذر تشغيل الكاميرا. أعد المحاولة، وإن استمرت المشكلة أغلق النافذة وافتحها من جديد.';

  @override
  String cameraScannerResolvingProduct(String barcode) {
    return 'جار البحث عن منتج للباركود $barcode...';
  }

  @override
  String get cameraScannerScanQuantityLabel => 'كمية كل مسح';

  @override
  String get cameraScannerEmptyScans => 'وجّه الكاميرا نحو الباركود أو رمز QR.';

  @override
  String get cameraScannerDoneButton => 'اعتماد المسح';

  @override
  String cameraScannerQuantityValue(int quantity) {
    return 'الكمية: $quantity';
  }

  @override
  String get removeScannedCodeTooltip => 'حذف الرمز الممسوح';

  @override
  String get switchCameraTooltip => 'تبديل الكاميرا';

  @override
  String get toggleTorchTooltip => 'تشغيل أو إيقاف الفلاش';

  @override
  String get currentSaleTitle => 'البيع الحالي';

  @override
  String get saleDraftSettingsActionTooltip => 'إعدادات الفاتورة';

  @override
  String get saleDraftSettingsDialogTitle => 'إعدادات الفاتورة';

  @override
  String get clearCartTooltip => 'مسح السلة';

  @override
  String get removeCartLineTooltip => 'حذف العنصر من السلة';

  @override
  String get cartLineNoteAdd => 'إضافة ملاحظة للمطبخ';

  @override
  String get cartLineNoteEdit => 'تعديل ملاحظة المطبخ';

  @override
  String get cartLineNoteDialogTitle => 'ملاحظة للمطبخ';

  @override
  String get cartLineNoteHint => 'مثال: بدون بصل';

  @override
  String get modifierGroupRequiredLabel => 'مطلوب';

  @override
  String get modifierGroupOptionalLabel => 'اختياري';

  @override
  String modifierGroupChooseUpToLabel(int count) {
    return 'اختر حتى $count';
  }

  @override
  String modifierSheetAddButton(String price) {
    return 'إضافة — $price';
  }

  @override
  String get modifierSheetEditTitle => 'تعديل الخيارات';

  @override
  String get modifierGroupsSectionTitle => 'مجموعات الإضافات';

  @override
  String get modifierGroupsSectionSubtitle =>
      'خيارات تُضاف للأصناف عند البيع (الحليب، الإضافات...).';

  @override
  String get modifierGroupAddButton => 'إضافة مجموعة';

  @override
  String get modifierGroupsEmptyMessage => 'لا توجد مجموعات إضافات بعد.';

  @override
  String get modifierGroupsLoadError => 'تعذّر تحميل مجموعات الإضافات.';

  @override
  String get modifierGroupNameLabel => 'اسم المجموعة';

  @override
  String get modifierGroupSingleSelectLabel => 'اختيار واحد فقط';

  @override
  String get modifierGroupRequiredToggleLabel => 'إلزامية';

  @override
  String get modifierGroupOptionsLabel => 'الخيارات';

  @override
  String get modifierOptionAddButton => 'إضافة خيار';

  @override
  String get modifierOptionNameLabel => 'الاسم';

  @override
  String get modifierOptionPriceLabel => 'السعر الإضافي';

  @override
  String get modifierOptionMaxQtyLabel => 'أقصى كمية';

  @override
  String get modifierOptionMaxQtyIncreaseTooltip => 'زيادة أقصى كمية';

  @override
  String get modifierOptionMaxQtyDecreaseTooltip => 'إنقاص أقصى كمية';

  @override
  String get modifierOptionDefaultLabel => 'افتراضي';

  @override
  String modifierGroupSummary(String selection, int count) {
    return '$selection · $count خيار';
  }

  @override
  String get modifierGroupDeleteTitle => 'حذف المجموعة؟';

  @override
  String get modifierGroupDeleteMessage => 'ستُزال من كل الأصناف المرتبطة بها.';

  @override
  String get modifierGroupSaveError => 'تعذّر حفظ المجموعة.';

  @override
  String get modifierGroupDeleteError => 'تعذّر حذف المجموعة.';

  @override
  String get productModifierGroupsLabel => 'مجموعات الإضافات';

  @override
  String get emptyCart => 'لا توجد عناصر في السلة';

  @override
  String get emptyCartMessage => 'ابحث عن منتج أو امسح الباركود لبدء البيع';

  @override
  String cartQuantityPendingLabel(String productName, String quantity) {
    return '$productName — الكمية: $quantity';
  }

  @override
  String get cartQuantityPendingHint => 'Enter للتأكيد';

  @override
  String get openCartSheetButton => 'مراجعة السلة';

  @override
  String get openSaleSessionsTitle => 'الفواتير المفتوحة';

  @override
  String get newSaleSessionButton => 'فاتورة جديدة';

  @override
  String get newSaleSessionTooltip => 'بدء فاتورة جديدة';

  @override
  String get saleSessionSwitcherTooltip => 'إدارة الفواتير المفتوحة';

  @override
  String get activeSaleSessionStatusLabel => 'الحالية';

  @override
  String get parkedSaleSessionStatusLabel => 'معلقة';

  @override
  String saleSessionTitle(int number) {
    return 'فاتورة $number';
  }

  @override
  String saleSessionSwitchTooltip(String title) {
    return 'فتح $title';
  }

  @override
  String get discardSaleSessionTooltip => 'حذف الفاتورة المعلقة';

  @override
  String get purchasingTitle => 'المشتريات';

  @override
  String get purchaseOrdersTitle => 'فواتير المشتريات';

  @override
  String get refreshPurchaseOrdersTooltip => 'تحديث فواتير المشتريات';

  @override
  String get refreshPurchaseOrderDetailsTooltip => 'تحديث تفاصيل أمر الشراء';

  @override
  String get newPurchaseOrderButton => 'أمر شراء جديد';

  @override
  String get newPurchaseOrderTitle => 'أمر شراء جديد';

  @override
  String get searchPurchaseOrdersHint =>
      'ابحث برقم أمر الشراء أو فاتورة المورد أو المنتج';

  @override
  String get purchaseOrderSupplierFilterTitle => 'المورد';

  @override
  String get allSuppliersFilterLabel => 'كل الموردين';

  @override
  String get clearSupplierFilterTooltip => 'مسح فلتر المورد';

  @override
  String get purchaseOrderStatusFilterTitle => 'حالة أمر الشراء';

  @override
  String get purchaseOrderStatusAll => 'كل أوامر الشراء';

  @override
  String get purchaseOrderStatusDraft => 'مسودة';

  @override
  String get purchaseOrderStatusSubmitted => 'مرسل';

  @override
  String get purchaseOrderStatusPartiallyReceived => 'مستلم جزئيًا';

  @override
  String get purchaseOrderStatusReceived => 'مستلم';

  @override
  String get purchaseOrderStatusCancelled => 'ملغى';

  @override
  String get purchaseOrderOrderingNewest => 'الأحدث أولًا';

  @override
  String get purchaseOrderOrderingUpdated => 'آخر تحديث';

  @override
  String get purchaseOrderOrderingTotalDesc => 'الإجمالي: من الأعلى إلى الأقل';

  @override
  String get purchaseOrderOrderingNumber => 'رقم أمر الشراء';

  @override
  String get purchaseOrdersLoadError => 'تعذر تحميل فواتير المشتريات.';

  @override
  String get purchaseOrderDetailsLoadError => 'تعذر تحميل تفاصيل أمر الشراء.';

  @override
  String get outstandingPurchasesTitle => 'مستلم وغير مدفوع';

  @override
  String get purchasePayablesTitle => 'مستحقات الموردين';

  @override
  String purchasePayablesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count فواتير بانتظار السداد',
      two: 'فاتورتان بانتظار السداد',
      one: 'فاتورة واحدة بانتظار السداد',
    );
    return '$_temp0';
  }

  @override
  String get purchasePayablesMore => 'والمزيد';

  @override
  String get outstandingPurchasesLoadError =>
      'تعذر تحميل المشتريات المستلمة غير المدفوعة.';

  @override
  String outstandingPurchasesSummary(num count, String amount) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count فواتير • $amount',
      two: 'فاتورتان • $amount',
      one: 'فاتورة واحدة • $amount',
      zero: 'لا توجد فواتير',
    );
    return '$_temp0';
  }

  @override
  String outstandingPurchasesLoadedSummary(num count, String amount) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'المحمّل: $count فواتير • $amount',
      two: 'المحمّل: فاتورتان • $amount',
      one: 'المحمّل: فاتورة واحدة • $amount',
      zero: 'لم يتم تحميل فواتير',
    );
    return '$_temp0';
  }

  @override
  String purchaseOutstandingAmountValue(String amount) {
    return 'متبقي $amount';
  }

  @override
  String get emptyPurchaseOrders => 'لا توجد فواتير مشتريات بعد.';

  @override
  String purchaseOrderFallbackTitle(int id) {
    return 'أمر شراء #$id';
  }

  @override
  String get purchaseOrderDetailsSummaryTitle => 'ملخص أمر الشراء';

  @override
  String get purchaseOrderNumberLabel => 'رقم أمر الشراء';

  @override
  String purchaseOrderNumberValue(String orderNumber) {
    return 'أمر الشراء $orderNumber';
  }

  @override
  String get supplierInvoiceNumberLabel => 'رقم فاتورة المورد';

  @override
  String get supplierInvoiceNumberHint => 'مثال: INV-1024';

  @override
  String supplierInvoiceNumberValue(String invoiceNumber) {
    return 'فاتورة المورد $invoiceNumber';
  }

  @override
  String get supplierInvoiceDateLabel => 'تاريخ فاتورة المورد';

  @override
  String get supplierInvoiceDateHint => 'مثال: 2026-05-19';

  @override
  String get supplierInvoiceDateInvalid => 'أدخل التاريخ بصيغة سنة-شهر-يوم.';

  @override
  String get supplierInvoiceDatePickerTooltip => 'اختيار تاريخ فاتورة المورد';

  @override
  String supplierInvoiceDateValue(String date) {
    return 'تاريخ الفاتورة $date';
  }

  @override
  String get purchaseOrderLineCountLabel => 'العناصر';

  @override
  String get purchaseOrderCreatedAtLabel => 'تاريخ الإنشاء';

  @override
  String get purchaseOrderSubmittedAtLabel => 'تاريخ الإرسال';

  @override
  String get purchaseOrderReceivedAtLabel => 'تاريخ الاستلام';

  @override
  String get purchaseOrderDueDateLabel => 'تاريخ الاستحقاق';

  @override
  String purchaseOrderDueDateValue(String date) {
    return 'الاستحقاق $date';
  }

  @override
  String get purchaseOrderOverdueValue => 'متأخر';

  @override
  String get purchaseOrderPaymentStatusLabel => 'حالة السداد';

  @override
  String get purchasePaymentStatusUnpaid => 'غير مدفوع';

  @override
  String get purchasePaymentStatusPartial => 'مدفوع جزئيًا';

  @override
  String get purchasePaymentStatusPaid => 'مدفوع';

  @override
  String get purchasePaymentStatusCredit => 'رصيد دائن';

  @override
  String get purchaseOrderPaidTotalLabel => 'المدفوع';

  @override
  String get purchaseOrderCreditAppliedLabel => 'رصيد مستخدم';

  @override
  String get purchaseOrderAdjustmentCreditLabel => 'رصيد من المرتجعات';

  @override
  String get purchaseOrderBalanceDueLabel => 'المتبقي للمورد';

  @override
  String get purchaseOrderActionsTitle => 'إجراءات الحالة';

  @override
  String get purchaseOrderActionsSheetTitle => 'إجراءات أمر الشراء';

  @override
  String get purchaseOrderMoreActionsLabel => 'إجراءات أخرى';

  @override
  String get purchaseOrderDocumentMenuTooltip => 'طباعة ومشاركة';

  @override
  String get purchaseOrderSubmitDescription =>
      'إرسال الأمر إلى المورد لبدء التوريد.';

  @override
  String get purchaseOrderReceiveDescription =>
      'تسجيل الكميات الواردة وإضافتها إلى المخزون.';

  @override
  String get purchaseOrderRecordPaymentDescription =>
      'تسجيل دفعة للمورد مقابل هذا الأمر.';

  @override
  String get purchaseOrderReturnDescription => 'إرجاع أصناف مستلمة إلى المورد.';

  @override
  String get purchaseOrderRefundDescription => 'استرداد قيمة أصناف من المورد.';

  @override
  String get purchaseOrderExchangeDescription => 'استبدال أصناف مستلمة بأخرى.';

  @override
  String get purchaseOrderCancelActionDescription =>
      'إلغاء أمر الشراء نهائيًا.';

  @override
  String get purchaseOrderCalloutDraftTitle => 'جاهز للإرسال';

  @override
  String get purchaseOrderCalloutDraftMessage =>
      'أرسل الأمر إلى المورد عندما تكون جاهزًا.';

  @override
  String get purchaseOrderCalloutAwaitingTitle => 'بانتظار الاستلام';

  @override
  String get purchaseOrderCalloutAwaitingMessage =>
      'سجّل الكميات عند وصول البضاعة من المورد.';

  @override
  String get purchaseOrderCalloutPartialTitle => 'مستلم جزئيًا';

  @override
  String get purchaseOrderCalloutPartialMessage =>
      'ما زالت بعض الأصناف بانتظار الاستلام.';

  @override
  String get purchaseOrderCalloutReceivedDueTitle => 'تم الاستلام بالكامل';

  @override
  String get purchaseOrderCalloutCompleteTitle => 'مكتمل';

  @override
  String get purchaseOrderCalloutCompleteMessage =>
      'تم الاستلام والسداد بالكامل.';

  @override
  String get purchaseOrderCalloutCancelledTitle => 'أمر ملغى';

  @override
  String get purchaseOrderCalloutCancelledMessage =>
      'تم إلغاء هذا الأمر ولا يمكن تعديله.';

  @override
  String get purchaseOrderReceivedProgressLabel => 'المستلم';

  @override
  String purchaseOrderReceivedProgressValue(String received, String ordered) {
    return '$received من $ordered';
  }

  @override
  String get purchaseOrderPrintAction => 'طباعة';

  @override
  String get purchaseOrderPrintInProgressAction => 'جار الطباعة...';

  @override
  String get purchaseOrderShareAction => 'مشاركة PDF';

  @override
  String get purchaseOrderShareInProgressAction => 'جار تجهيز PDF...';

  @override
  String get purchaseOrderRowActionsTooltip => 'إجراءات أمر الشراء';

  @override
  String purchaseOrderPrintSuccess(String orderNumber) {
    return 'تم إرسال أمر الشراء رقم $orderNumber للطابعة.';
  }

  @override
  String get purchaseOrderPrintError =>
      'تعذرت طباعة أمر الشراء. راجع الطابعة وحاول مرة أخرى.';

  @override
  String purchaseOrderShareSuccess(String orderNumber) {
    return 'تم تجهيز ملف PDF لأمر الشراء رقم $orderNumber.';
  }

  @override
  String get purchaseOrderShareError => 'تعذر تجهيز ملف PDF لأمر الشراء.';

  @override
  String get submitPurchaseOrderAction => 'إرسال';

  @override
  String get receivePurchaseOrderAction => 'تحديد كمستلم';

  @override
  String get receivePurchaseLinesAction => 'استلام كميات';

  @override
  String get purchaseOrderAdjustmentsTitle => 'المرتجعات والاستبدالات';

  @override
  String get returnPurchaseItemsAction => 'إرجاع';

  @override
  String get refundPurchaseItemsAction => 'استرداد';

  @override
  String get exchangePurchaseItemsAction => 'استبدال';

  @override
  String get purchaseOrderStatusChangeError =>
      'تعذر تغيير حالة أمر الشراء. حاول مرة أخرى.';

  @override
  String get purchaseOrderAdjustmentError =>
      'تعذر تسجيل تعديل المشتريات. راجع الكميات والمخزون وحاول مرة أخرى.';

  @override
  String get purchaseOrderAdjustmentStockUnavailableError =>
      'لا يمكن تعديل أمر الشراء لأن الكمية المستلمة بيعت أو لم تعد متوفرة في المخزون.';

  @override
  String get purchaseOrderPermissionError =>
      'لا يملك هذا المستخدم صلاحية تنفيذ هذا الإجراء على أمر الشراء.';

  @override
  String get purchaseOrderValidationError =>
      'تعذر تنفيذ الإجراء. راجع حالة أمر الشراء والكميات ثم حاول مرة أخرى.';

  @override
  String get purchaseOrderPaymentError =>
      'تعذر تسجيل دفعة المورد. راجع المبلغ وطريقة الدفع وحاول مرة أخرى.';

  @override
  String get recordSupplierPaymentAction => 'تسجيل دفعة';

  @override
  String get supplierPaymentTitle => 'دفعة للمورد';

  @override
  String get supplierPaymentAmountLabel => 'المبلغ';

  @override
  String get supplierPaymentReferenceLabel => 'مرجع اختياري';

  @override
  String get supplierPaymentNotesLabel => 'ملاحظات اختيارية';

  @override
  String get supplierPaymentPrintProofLabel => 'طباعة سند صرف';

  @override
  String get supplierPaymentPositiveAmountError =>
      'أدخل مبلغًا أكبر من صفر ولا يتجاوز المتبقي.';

  @override
  String supplierPaymentSuccess(String orderNumber) {
    return 'تم تسجيل دفعة المورد لأمر الشراء رقم $orderNumber.';
  }

  @override
  String get supplierPaymentMethodCredit => 'رصيد المورد';

  @override
  String get purchaseReturnTitle => 'إرجاع مشتريات';

  @override
  String get purchaseRefundTitle => 'استرداد مشتريات';

  @override
  String get purchaseExchangeTitle => 'استبدال مشتريات';

  @override
  String get purchaseAdjustmentReasonLabel => 'سبب التعديل';

  @override
  String get purchaseAdjustmentReasonHint =>
      'مثال: تالف، خطأ في الفاتورة، استبدال مع المورد';

  @override
  String get purchaseNoAdjustableItems => 'لا توجد عناصر قابلة للتعديل.';

  @override
  String get purchaseAdjustmentNoItemsSelected =>
      'اختر عنصرًا واحدًا على الأقل.';

  @override
  String get purchaseExchangeNoItemsSelected =>
      'اختر عناصر صادرة وعناصر بديلة للاستبدال.';

  @override
  String get purchaseExchangeOutboundSectionTitle => 'العناصر الصادرة';

  @override
  String get purchaseExchangeReplacementSectionTitle => 'العناصر البديلة';

  @override
  String get purchaseExchangeAddReplacementLine => 'إضافة بديل';

  @override
  String get purchaseExchangeNoReplacementProducts =>
      'لا توجد منتجات متاحة للاختيار من هذا الأمر.';

  @override
  String get purchaseExchangeInvalidLinesError =>
      'أدخل كمية صادرة واحدة على الأقل وبديلًا بكمية وتكلفة صحيحتين.';

  @override
  String get purchaseExchangeReplacementProductLabel => 'المنتج البديل';

  @override
  String get purchaseExchangeReplacementQuantityLabel => 'الكمية';

  @override
  String get purchaseExchangeReplacementUnitCostLabel => 'التكلفة';

  @override
  String purchaseReturnSuccess(String orderNumber) {
    return 'تم تسجيل إرجاع المشتريات رقم $orderNumber.';
  }

  @override
  String purchaseRefundSuccess(String orderNumber) {
    return 'تم تسجيل استرداد المشتريات رقم $orderNumber.';
  }

  @override
  String purchaseExchangeSuccess(String orderNumber) {
    return 'تم تسجيل استبدال المشتريات رقم $orderNumber.';
  }

  @override
  String purchaseAdjustmentLineRemaining(String remaining, String quantity) {
    return 'المتبقي $remaining من $quantity';
  }

  @override
  String get purchaseAdjustmentHistoryEmpty =>
      'لا توجد مرتجعات أو استبدالات مسجلة.';

  @override
  String get purchaseAdjustmentTypeReturn => 'إرجاع';

  @override
  String get purchaseAdjustmentTypeRefund => 'استرداد';

  @override
  String get purchaseAdjustmentTypeExchange => 'استبدال';

  @override
  String purchaseAdjustmentSettlementMethod(String method) {
    return 'التسوية: $method';
  }

  @override
  String purchaseAdjustmentSupplierCreditCreated(String amount) {
    return 'أنشئ رصيد مورد بقيمة $amount';
  }

  @override
  String purchaseAdjustmentSupplierCreditRemaining(String amount) {
    return 'المتبقي من الرصيد $amount';
  }

  @override
  String purchaseExchangeReplacementLineCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count بدائل',
      two: 'بديلان',
      one: 'بديل واحد',
      zero: 'لا توجد بدائل',
    );
    return '$_temp0';
  }

  @override
  String purchaseExchangeReplacementHistoryLine(
    String product,
    String quantity,
    String unitCost,
  ) {
    return 'بديل: $product × $quantity بتكلفة $unitCost';
  }

  @override
  String purchaseOrderSubmitSuccess(String orderNumber) {
    return 'تم إرسال أمر الشراء رقم $orderNumber.';
  }

  @override
  String purchaseOrderReceiveSuccess(String orderNumber) {
    return 'تم استلام أمر الشراء رقم $orderNumber.';
  }

  @override
  String get purchaseReceiveTitle => 'استلام كميات أمر الشراء';

  @override
  String get purchaseReceiveNoOpenLines => 'لا توجد كميات مفتوحة للاستلام.';

  @override
  String get purchaseReceiveNoItemsSelected =>
      'أدخل كمية مستلمة أو تالفة أو مرفوضة لعنصر واحد على الأقل.';

  @override
  String get purchaseReceiveInvalidQuantityError =>
      'أدخل كميات صحيحة لا تقل عن صفر.';

  @override
  String get purchaseExpiryDatesRequired =>
      'أدخل تاريخ انتهاء لكل منتج يتابع الانتهاء.';

  @override
  String get purchaseReceiveReceivedLabel => 'مستلم سليم';

  @override
  String get purchaseReceiveDamagedLabel => 'تالف عند الوصول';

  @override
  String get purchaseReceiveRejectedLabel => 'مرفوض/لن يصل';

  @override
  String get purchaseReceiveNoteLabel => 'ملاحظة الاستلام';

  @override
  String get purchaseReceiveNoteHint =>
      'مثال: نقص في الصندوق أو زيادة من المورد';

  @override
  String purchaseReceiveExpectedValue(String quantity) {
    return 'المطلوب $quantity';
  }

  @override
  String purchaseReceiveAlreadyValue(String quantity) {
    return 'استلم سابقًا $quantity';
  }

  @override
  String purchaseReceiveOpenValue(String quantity) {
    return 'المفتوح $quantity';
  }

  @override
  String purchaseReceiveOpenAfterValue(String quantity) {
    return 'المفتوح بعد الإدخال $quantity';
  }

  @override
  String purchaseReceiveAfterVarianceValue(String quantity) {
    return 'الفرق بعد الإدخال $quantity';
  }

  @override
  String purchaseOrderCancelSuccess(String orderNumber) {
    return 'تم إلغاء أمر الشراء رقم $orderNumber.';
  }

  @override
  String get purchaseOrderLinesTitle => 'محتويات أمر الشراء';

  @override
  String get purchaseOrderUnknownProduct => 'منتج غير محدد';

  @override
  String purchaseOrderLineQuantity(String quantity) {
    return 'الكمية $quantity';
  }

  @override
  String purchaseLineReceivedQuantity(String quantity) {
    return 'مستلم $quantity';
  }

  @override
  String purchaseLineOpenQuantity(String quantity) {
    return 'مفتوح/متأخر $quantity';
  }

  @override
  String purchaseLineDamagedQuantity(String quantity) {
    return 'تالف $quantity';
  }

  @override
  String purchaseLineRejectedQuantity(String quantity) {
    return 'مرفوض $quantity';
  }

  @override
  String purchaseLineVarianceValue(String quantity) {
    return 'الفرق $quantity';
  }

  @override
  String get purchaseReceiptHistoryTitle => 'سجل الاستلام';

  @override
  String get purchaseReceiptHistoryEmpty => 'لا توجد عمليات استلام مسجلة.';

  @override
  String get purchaseReceiptHistoryItemFallback => 'عملية استلام';

  @override
  String purchaseOrderPreviousCostValue(String amount) {
    return 'آخر تكلفة $amount';
  }

  @override
  String purchaseOrderCostChangeValue(String amount) {
    return 'تغير التكلفة $amount';
  }

  @override
  String purchaseOrderCostChangePercentValue(String percent) {
    return '$percent%';
  }

  @override
  String get purchaseCatalogTitle => 'كتالوج الشراء';

  @override
  String get purchaseProductLookupHint => 'ابحث عن منتج لإضافته للمشتريات';

  @override
  String get purchaseDraftTitle => 'مسودة الشراء';

  @override
  String get openPurchaseDraftSheetButton => 'مراجعة المسودة';

  @override
  String get clearPurchaseDraftTooltip => 'مسح مسودة الشراء';

  @override
  String get purchaseDraftSettingsActionTooltip => 'إعدادات مسودة الشراء';

  @override
  String get purchaseDraftSettingsDialogTitle => 'إعدادات مسودة الشراء';

  @override
  String get purchaseSupplierActionTooltip => 'اختيار المورد';

  @override
  String get purchaseInvoiceDetailsActionTooltip => 'بيانات فاتورة المورد';

  @override
  String get purchaseInvoiceDetailsDialogTitle => 'بيانات فاتورة المورد';

  @override
  String get purchaseLandedCostActionTooltip => 'تكاليف الوصول';

  @override
  String get purchaseDiscountActionTooltip => 'كود خصم المورد';

  @override
  String get emptyPurchaseDraft => 'لا توجد عناصر في مسودة الشراء';

  @override
  String get emptyPurchaseDraftMessage =>
      'أضف منتجات من الكتالوج لبناء أمر الشراء';

  @override
  String get purchaseLineCostLabel => 'التكلفة';

  @override
  String get purchaseLineUnitLabel => 'وحدة الشراء';

  @override
  String purchaseLineSellingPrice(String price) {
    return 'سعر البيع $price';
  }

  @override
  String purchaseLineSellingPricePerUnit(String price, String unit) {
    return 'سعر البيع $price / $unit';
  }

  @override
  String get purchaseLineNoSellingPrice => 'لا يوجد سعر بيع';

  @override
  String get purchaseLineSellingPriceBelowCostTooltip =>
      'سعر البيع لا يغطي تكلفة الشراء';

  @override
  String purchaseLineBaseEquivalent(String quantity, String unit) {
    return '= $quantity $unit';
  }

  @override
  String get purchaseLineExpiryDateLabel => 'تاريخ الانتهاء';

  @override
  String get purchaseLineExpiryDateHint => 'مثال: 2026-12-31';

  @override
  String get purchaseLineExpiryDatePickerTooltip => 'اختيار تاريخ الانتهاء';

  @override
  String get purchaseLineExpiryDateInvalid =>
      'أدخل تاريخًا صحيحًا بصيغة سنة-شهر-يوم.';

  @override
  String get purchaseLineExpiryDateRequired =>
      'تاريخ الانتهاء مطلوب لهذا المنتج.';

  @override
  String get purchaseShippingCostLabel => 'الشحن';

  @override
  String get purchaseCustomsCostLabel => 'الجمارك';

  @override
  String get purchaseHandlingCostLabel => 'المناولة';

  @override
  String get purchaseLandedCostTotalLabel => 'تكاليف الوصول';

  @override
  String purchaseLandedCostButton(String amount) {
    return 'تكاليف الوصول $amount';
  }

  @override
  String get purchaseLandedCostSheetTitle => 'تكاليف الوصول';

  @override
  String get landedCostAllocationMethodLabel => 'طريقة توزيع تكاليف الوصول';

  @override
  String get landedCostEntryNameLabel => 'اسم التكلفة';

  @override
  String get landedCostEntryCostLabel => 'القيمة';

  @override
  String get addLandedCostEntryButton => 'إضافة تكلفة';

  @override
  String get saveLandedCostEntriesButton => 'حفظ التكاليف';

  @override
  String get removeLandedCostEntryTooltip => 'حذف التكلفة';

  @override
  String get defaultLandedCostEntryName => 'تكلفة وصول';

  @override
  String get landedCostAllocationByLineValueLabel => 'حسب قيمة السطر';

  @override
  String get landedCostAllocationByQuantityLabel => 'حسب الكمية';

  @override
  String get landedCostAllocationByRetailValueLabel => 'حسب قيمة البيع';

  @override
  String get landedCostAllocationEquallyByLineLabel => 'بالتساوي على السطور';

  @override
  String purchaseLineLandedCostValue(String amount) {
    return 'تكلفة وصول $amount';
  }

  @override
  String purchaseLineEffectiveCostValue(String amount) {
    return 'التكلفة الفعلية $amount';
  }

  @override
  String get receivePurchaseImmediatelyLabel => 'استلام أمر الشراء فورًا';

  @override
  String submitPurchaseDraftButton(String amount) {
    return 'إرسال أمر الشراء $amount';
  }

  @override
  String get purchaseSubmitInProgressButton => 'جار الإرسال...';

  @override
  String purchaseDraftSubmitSuccess(String draftNumber) {
    return 'تم إرسال أمر الشراء رقم $draftNumber.';
  }

  @override
  String get purchaseDraftSubmitError =>
      'تعذر إرسال أمر الشراء. راجع العناصر ورقم فاتورة المورد وحاول مرة أخرى.';

  @override
  String get editPurchaseOrderTitle => 'تعديل أمر الشراء';

  @override
  String get editPurchaseOrderAction => 'تعديل';

  @override
  String get purchaseOrderEditDescription =>
      'فتح الأمر في شاشة الشراء لتعديل أصنافه وتكاليفه قبل تسجيل الدفع.';

  @override
  String get savePurchaseDraftButton => 'حفظ التعديلات';

  @override
  String get purchaseDraftSaveInProgressButton => 'جارٍ الحفظ...';

  @override
  String purchaseDraftSaveSuccess(String draftNumber) {
    return 'تم حفظ مسودة أمر الشراء رقم $draftNumber.';
  }

  @override
  String get purchaseDraftSaveError =>
      'تعذر حفظ المسودة. راجع العناصر ورقم فاتورة المورد وحاول مرة أخرى.';

  @override
  String get editPurchaseOrderLoadError => 'تعذر فتح أمر الشراء للتعديل.';

  @override
  String get editPurchaseOrderNotEditableError =>
      'لا يمكن التعديل بعد تسجيل دفعة أو رصيد على أمر الشراء.';

  @override
  String get purchaseEditReceivedOrderNotice =>
      'تم استلام هذا الأمر بالفعل. عند الحفظ سيُعاد تسجيل الاستلام بالكميات والتكاليف الجديدة.';

  @override
  String purchaseEditUnresolvedLines(int count) {
    return 'تعذّر تحميل $count من الأصناف لأنها لم تعد متوفرة في الكتالوج.';
  }

  @override
  String get contactsTitle => 'العملاء والموردون';

  @override
  String get customersTab => 'العملاء';

  @override
  String get suppliersTab => 'الموردون';

  @override
  String get refreshContactsTooltip => 'تحديث العملاء والموردين';

  @override
  String get contactSearchHint => 'ابحث بالاسم أو الهاتف أو البريد';

  @override
  String get contactsLoadError => 'تعذر تحميل العملاء والموردين.';

  @override
  String get emptyCustomers => 'لا يوجد عملاء بعد.';

  @override
  String get emptySuppliers => 'لا يوجد موردون بعد.';

  @override
  String get addCustomerButton => 'إضافة عميل';

  @override
  String get addSupplierButton => 'إضافة مورد';

  @override
  String get customerFullNameLabel => 'اسم العميل';

  @override
  String get supplierNameLabel => 'اسم المورد';

  @override
  String get contactPersonLabel => 'اسم جهة التواصل';

  @override
  String get phoneOptionalLabel => 'رقم الهاتف (اختياري)';

  @override
  String get emailOptionalLabel => 'البريد الإلكتروني (اختياري)';

  @override
  String get birthdayOptionalLabel => 'تاريخ الميلاد (اختياري)';

  @override
  String get birthdayHint => 'YYYY-MM-DD';

  @override
  String get genderLabel => 'الجنس';

  @override
  String get genderUnspecified => 'غير محدد';

  @override
  String get genderFemale => 'أنثى';

  @override
  String get genderMale => 'ذكر';

  @override
  String get genderNonBinary => 'غير ثنائي';

  @override
  String get genderPreferNotToSay => 'يفضل عدم الإفصاح';

  @override
  String get marketingConsentLabel => 'وافق على التواصل التسويقي';

  @override
  String get addressOptionalLabel => 'العنوان (اختياري)';

  @override
  String get notesOptionalLabel => 'ملاحظات (اختياري)';

  @override
  String get activeContactLabel => 'نشط';

  @override
  String get saveCustomerButton => 'حفظ العميل';

  @override
  String get saveSupplierButton => 'حفظ المورد';

  @override
  String get customerCreateError =>
      'تعذر حفظ العميل. راجع البيانات وحاول مرة أخرى.';

  @override
  String get supplierCreateError =>
      'تعذر حفظ المورد. راجع البيانات وحاول مرة أخرى.';

  @override
  String get customerNumberLabel => 'رقم العميل';

  @override
  String get customerBirthdayLabel => 'الميلاد';

  @override
  String get marketingAllowedLabel => 'يسمح بالتسويق';

  @override
  String get inactiveContactLabel => 'غير نشط';

  @override
  String get supplierContactLabel => 'جهة التواصل';

  @override
  String supplierContactValue(String name) {
    return 'جهة التواصل $name';
  }

  @override
  String get refreshSupplierDetailsTooltip => 'تحديث تفاصيل المورد';

  @override
  String get supplierDetailsLoadError => 'تعذر تحميل ملخص المورد.';

  @override
  String get supplierPurchaseSummaryTitle => 'ملخص الشراء من المورد';

  @override
  String get supplierTotalBoughtLabel => 'إجمالي المشتريات';

  @override
  String get supplierPurchaseCountLabel => 'عدد أوامر الشراء';

  @override
  String supplierPurchaseCountValue(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count أوامر',
      two: 'أمران',
      one: 'أمر واحد',
      zero: 'لا توجد أوامر',
    );
    return '$_temp0';
  }

  @override
  String get supplierPurchaseHistoryTitle => 'سجل مشتريات المورد';

  @override
  String get supplierPurchaseHistoryLoadError =>
      'تعذر تحميل سجل مشتريات المورد.';

  @override
  String get supplierPurchaseHistoryEmpty =>
      'لا توجد مشتريات مسجلة لهذا المورد.';

  @override
  String get supplierReturnRefundHistoryTitle => 'سجل الإرجاع والاسترداد';

  @override
  String get supplierReturnRefundHistoryLoadError =>
      'تعذر تحميل سجل الإرجاع والاسترداد.';

  @override
  String get supplierReturnRefundHistoryEmpty =>
      'لا توجد عمليات إرجاع أو استرداد لهذا المورد.';

  @override
  String supplierPayableBalanceValue(String amount) {
    return 'مستحق $amount';
  }

  @override
  String supplierCreditBalanceValue(String amount) {
    return 'رصيد $amount';
  }

  @override
  String supplierNetBalanceValue(String amount) {
    return 'الصافي $amount';
  }

  @override
  String get refreshCustomerDetailsTooltip => 'تحديث تفاصيل العميل';

  @override
  String get customerDetailsLoadError => 'تعذر تحميل بيانات العميل.';

  @override
  String get customerProfileTitle => 'بيانات العميل';

  @override
  String get paymentCardsTitle => 'بطاقات الدفع';

  @override
  String get paymentCardsLoadError => 'تعذّر تحميل بطاقات الدفع.';

  @override
  String get paymentCardsEmpty => 'لا توجد بطاقات مرتبطة بهذا العميل.';

  @override
  String paymentCardLastSeenValue(String date) {
    return 'آخر استخدام: $date';
  }

  @override
  String paymentCardCountValue(int count) {
    return '$count بطاقة';
  }

  @override
  String get reassignCardTooltip => 'نقل البطاقة إلى عميل آخر';

  @override
  String get reassignCardTitle => 'نقل البطاقة';

  @override
  String get cardReassignedMessage => 'تم نقل البطاقة.';

  @override
  String get cardReassignFailedMessage => 'تعذّر نقل البطاقة.';

  @override
  String get unclaimedCardCustomerCalloutTitle => 'عميل بطاقة غير مُسمّى';

  @override
  String get unclaimedCardCustomerCalloutBody =>
      'أُنشئ هذا العميل تلقائيًا من بطاقة دفع. ادمجه مع عميل موجود أو أعطه اسمًا ليصبح عميلًا مستقلًا.';

  @override
  String get mergeIntoCustomerButton => 'دمج مع عميل';

  @override
  String get mergeCustomerSuccessMessage => 'تم دمج العميل.';

  @override
  String get mergeCustomerFailedMessage => 'تعذّر دمج العميل.';

  @override
  String get nameCustomerButton => 'تسمية العميل';

  @override
  String get nameCustomerTitle => 'تسمية العميل';

  @override
  String get customerClaimedMessage => 'تم حفظ العميل.';

  @override
  String get customerClaimFailedMessage => 'تعذّر حفظ العميل.';

  @override
  String get unclaimedCardsFilterLabel => 'بطاقات غير مُسمّاة';

  @override
  String get allCustomersFilterLabel => 'كل العملاء';

  @override
  String get customerAutoCreatedBadge => 'بطاقة غير مُسمّاة';

  @override
  String get customerRankFilterTitle => 'التصنيف';

  @override
  String get allRanksFilterLabel => 'كل التصنيفات';

  @override
  String get customerRankChampion => 'مميّز';

  @override
  String get customerRankLoyal => 'وفيّ';

  @override
  String get customerRankPotentialLoyalist => 'وفيّ محتمل';

  @override
  String get customerRankNew => 'جديد';

  @override
  String get customerRankPromising => 'واعد';

  @override
  String get customerRankNeedsAttention => 'يحتاج اهتمامًا';

  @override
  String get customerRankAtRisk => 'معرّض للفقدان';

  @override
  String get customerRankCantLose => 'لا يجب خسارته';

  @override
  String get customerRankHibernating => 'خامل';

  @override
  String get customerRankLost => 'مفقود';

  @override
  String get customerRankInactive => 'بدون مشتريات';

  @override
  String get customerSalesSummaryTitle => 'ملخص تعاملات العميل';

  @override
  String get customerSalesSummaryLoadError => 'تعذر تحميل ملخص تعاملات العميل.';

  @override
  String get customerInvoiceHistoryTitle => 'الفواتير';

  @override
  String get customerInvoiceHistoryLoadError => 'تعذر تحميل فواتير العميل.';

  @override
  String get customerInvoiceHistoryEmpty => 'لا توجد فواتير مسجلة لهذا العميل.';

  @override
  String get customerAdjustmentHistoryTitle => 'الإرجاع والاستبدال والاسترداد';

  @override
  String get customerAdjustmentHistoryLoadError =>
      'تعذر تحميل سجل الإرجاع والاسترداد.';

  @override
  String get customerAdjustmentHistoryEmpty =>
      'لا توجد عمليات إرجاع أو استبدال أو استرداد لهذا العميل.';

  @override
  String get customerEmptyValue => 'غير مسجل';

  @override
  String get customerMarketingConsentLabel => 'موافقة التسويق';

  @override
  String get customerStatusLabel => 'الحالة';

  @override
  String get customerNotesLabel => 'الملاحظات';

  @override
  String get customerTotalInvoicedLabel => 'إجمالي الفواتير';

  @override
  String get customerNetSalesLabel => 'صافي المبيعات';

  @override
  String get customerOutstandingBalanceLabel => 'الرصيد المستحق';

  @override
  String get recordCustomerPaymentButton => 'تسجيل دفعة';

  @override
  String customerOutstandingBalanceCalloutTitle(String amount) {
    return 'على هذا العميل رصيد مستحق قدره $amount.';
  }

  @override
  String get customerOutstandingBalanceCalloutBody =>
      'تُوزَّع الدفعة تلقائيًا على أقدم الفواتير الآجلة أولًا.';

  @override
  String get customerAccountPaymentTitle => 'تسجيل دفعة على الحساب';

  @override
  String get customerAccountPaymentAmountLabel => 'المبلغ';

  @override
  String customerAccountPaymentOutstandingValue(String amount) {
    return 'الرصيد المستحق: $amount';
  }

  @override
  String get customerAccountPaymentAmountError =>
      'أدخل مبلغًا أكبر من صفر ولا يتجاوز الرصيد المستحق.';

  @override
  String get customerAccountPaymentSuccess =>
      'تم تسجيل الدفعة على حساب العميل.';

  @override
  String get customerAccountPaymentError =>
      'تعذّر تسجيل الدفعة. حاول مرة أخرى.';

  @override
  String get customerInvoiceCountLabel => 'عدد الفواتير';

  @override
  String customerInvoiceCountValue(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count فواتير',
      two: 'فاتورتان',
      one: 'فاتورة واحدة',
      zero: 'لا توجد فواتير',
    );
    return '$_temp0';
  }

  @override
  String get customerPaidInvoiceCountLabel => 'الفواتير المدفوعة';

  @override
  String customerPaidInvoiceCountValue(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count فواتير مدفوعة',
      two: 'فاتورتان مدفوعتان',
      one: 'فاتورة مدفوعة واحدة',
      zero: 'لا توجد فواتير مدفوعة',
    );
    return '$_temp0';
  }

  @override
  String get customerVoidCountLabel => 'الفواتير الملغاة';

  @override
  String customerVoidCountValue(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count فواتير ملغاة',
      two: 'فاتورتان ملغاتان',
      one: 'فاتورة ملغاة واحدة',
      zero: 'لا توجد فواتير ملغاة',
    );
    return '$_temp0';
  }

  @override
  String get customerVoidTotalLabel => 'إجمالي الإلغاء';

  @override
  String get customerReturnCountLabel => 'عمليات الإرجاع';

  @override
  String customerReturnCountValue(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عمليات إرجاع',
      two: 'إرجاعان',
      one: 'إرجاع واحد',
      zero: 'لا توجد عمليات إرجاع',
    );
    return '$_temp0';
  }

  @override
  String get customerReturnTotalLabel => 'إجمالي الإرجاع';

  @override
  String get customerRefundCountLabel => 'عمليات الاسترداد';

  @override
  String customerRefundCountValue(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عمليات استرداد',
      two: 'استردادان',
      one: 'استرداد واحد',
      zero: 'لا توجد عمليات استرداد',
    );
    return '$_temp0';
  }

  @override
  String get customerRefundTotalLabel => 'إجمالي الاسترداد';

  @override
  String get customerExchangeCountLabel => 'عمليات الاستبدال';

  @override
  String customerExchangeCountValue(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عمليات استبدال',
      two: 'استبدالان',
      one: 'استبدال واحد',
      zero: 'لا توجد عمليات استبدال',
    );
    return '$_temp0';
  }

  @override
  String get customerExchangeTotalLabel => 'إجمالي الاستبدال';

  @override
  String get customerLastInvoiceAtLabel => 'آخر فاتورة';

  @override
  String get saleOrderStatusPaid => 'مدفوعة';

  @override
  String get saleOrderStatusVoid => 'ملغاة';

  @override
  String get saleOrderStatusOpen => 'مفتوحة';

  @override
  String get customerAdjustmentTypeReturn => 'إرجاع';

  @override
  String get customerAdjustmentTypeVoid => 'إلغاء فاتورة';

  @override
  String get customerAdjustmentTypeExchange => 'استبدال';

  @override
  String get customerAdjustmentTypeRefund => 'استرداد';

  @override
  String get customerAdjustmentTypeUnknown => 'تعديل';

  @override
  String customerRefundMethodValue(String method) {
    return 'استرداد: $method';
  }

  @override
  String customerAdjustmentCreatedByValue(String username) {
    return 'بواسطة $username';
  }

  @override
  String get selectedCustomerLabel => 'العميل';

  @override
  String get selectedSupplierLabel => 'المورد';

  @override
  String get walkInCustomerLabel => 'عميل عابر';

  @override
  String get noSupplierSelectedLabel => 'لا يوجد مورد محدد';

  @override
  String get purchaseSupplierRequiredHint =>
      'اختر موردًا قبل إرسال أمر الشراء.';

  @override
  String get chooseCustomerTitle => 'اختيار العميل';

  @override
  String get chooseSupplierTitle => 'اختيار المورد';

  @override
  String get changeContactAction => 'تغيير';

  @override
  String get clearContactTooltip => 'إزالة الاختيار';

  @override
  String get createNewCustomerAction => 'عميل جديد';

  @override
  String get createNewSupplierAction => 'مورد جديد';

  @override
  String payAmount(String amount) {
    return 'ادفع $amount';
  }

  @override
  String get checkoutInProgressButton => 'جار الدفع...';

  @override
  String get paymentDialogTitle => 'إتمام الدفع';

  @override
  String get paymentMethodLabel => 'طريقة الدفع';

  @override
  String get cashReceivedLabel => 'المبلغ المستلم';

  @override
  String get cashReceivedTooLowError => 'المبلغ المستلم أقل من الإجمالي.';

  @override
  String get paymentTenderAmountLabel => 'المبلغ';

  @override
  String get addSplitTenderButton => 'إضافة دفعة';

  @override
  String get removeTenderTooltip => 'حذف الدفعة';

  @override
  String get paymentMethodSplitTender => 'دفعات متعددة';

  @override
  String get amountDueLabel => 'المستحق';

  @override
  String get paymentQuickAmountsLabel => 'مبالغ سريعة';

  @override
  String get paymentKeypadLabel => 'لوحة الإدخال';

  @override
  String get paymentKeypadBackspaceTooltip => 'حذف آخر رقم';

  @override
  String get paymentKeypadClearTooltip => 'مسح المبلغ';

  @override
  String paymentTenderLineTitle(int index) {
    return 'دفعة $index';
  }

  @override
  String get cardReceiptValidateButton => 'طابق الإيصال';

  @override
  String get cardReceiptRescanButton => 'إعادة المسح';

  @override
  String get cardReceiptRequiredInline => 'هذه الدفعة تحتاج مسح إيصال البطاقة.';

  @override
  String cardReceiptAwaitingCardTender(String amount) {
    return 'تمت قراءة إيصال بطاقة بمبلغ $amount. اضبط دفعة بطاقة بنفس المبلغ لمطابقته.';
  }

  @override
  String get cardReceiptAwaitingCardTenderUnknownAmount =>
      'تمت قراءة إيصال بطاقة. اضبط دفعة بطاقة لإرفاقه، وسيتم التحقق من المبلغ بعد إتمام البيع.';

  @override
  String get cardReceiptPendingVerificationSummary =>
      'إيصال مُرفق — يتم التحقق من مبلغه مع المصرف بعد إتمام البيع.';

  @override
  String get cardReceiptStatusVerified => 'موثّق';

  @override
  String get cardReceiptStatusPending => 'قيد التحقق';

  @override
  String get cardReceiptStatusFlagged => 'يحتاج مراجعة';

  @override
  String get cardReceiptStatusUnavailable => 'تعذّر الاتصال';

  @override
  String get cardReceiptStatusNoReceipt => 'بدون إيصال';

  @override
  String get cardReceiptStatusVerifiedDetail =>
      'تم التحقق من هذا الإيصال لدى جهة الإصدار، ومبلغه يطابق الدفعة.';

  @override
  String get cardReceiptStatusPendingDetail =>
      'تم مسح الإيصال وسيتم التحقق من مبلغه لدى جهة الإصدار.';

  @override
  String get cardReceiptStatusFlaggedDetail =>
      'جهة الإصدار لا تعترف بهذا الإيصال، أو أن مبلغه يخالف الدفعة. يحتاج مراجعة.';

  @override
  String get cardReceiptStatusUnavailableDetail =>
      'تعذّر الوصول إلى جهة الإصدار. هذا لا يعني أن الإيصال غير صحيح.';

  @override
  String get cardReceiptStatusNoReceiptDetail => 'دفعة بطاقة بدون إيصال مرفق.';

  @override
  String get sessionCardReceiptsTitle => 'التحقق من إيصالات البطاقة';

  @override
  String sessionCardReceiptsHeadline(String verified, String gross) {
    return '$verified موثّق من $gross';
  }

  @override
  String get sessionCardReceiptsAllVerified =>
      'كل مبالغ البطاقة في هذه الوردية موثّقة.';

  @override
  String sessionCardReceiptsNeedsAttention(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count دفعة تحتاج مراجعة',
      few: '$count دفعات تحتاج مراجعة',
      two: 'دفعتان تحتاجان مراجعة',
      one: 'دفعة واحدة تحتاج مراجعة',
    );
    return '$_temp0';
  }

  @override
  String sessionCardReceiptsPendingNote(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count دفعة ما زالت قيد التحقق',
      few: '$count دفعات ما زالت قيد التحقق',
      two: 'دفعتان ما زالتا قيد التحقق',
      one: 'دفعة واحدة ما زالت قيد التحقق',
    );
    return '$_temp0';
  }

  @override
  String get orderCardReceiptViewButton => 'عرض إيصال الجهاز';

  @override
  String get orderCardReceiptSheetTitle => 'إيصال جهاز البطاقة';

  @override
  String get orderCardReceiptOpenOriginal => 'عرض الأصل من المصرف';

  @override
  String get orderCardReceiptOpenOriginalFailed => 'تعذّر فتح الإيصال الأصلي.';

  @override
  String get orderCardReceiptNoOriginal => 'لا يوجد رابط أصلي لهذا الإيصال.';

  @override
  String get orderCardReceiptOriginalHint =>
      'النسخة المعروضة أعلاه من البيانات المحفوظة لدينا، وتعمل بدون إنترنت. الأصل يُفتح من خادم المصرف ويحتاج اتصالاً.';

  @override
  String get orderCardReceiptFieldAmount => 'المبلغ';

  @override
  String get orderCardReceiptFieldTerminal => 'رقم الآلة';

  @override
  String get orderCardReceiptFieldMerchant => 'التاجر';

  @override
  String get orderCardReceiptFieldCard => 'البطاقة';

  @override
  String get orderCardReceiptFieldCardholder => 'حامل البطاقة';

  @override
  String get orderCardReceiptFieldRrn => 'الرقم المرجعي';

  @override
  String get orderCardReceiptFieldAuth => 'رقم التفويض';

  @override
  String get orderCardReceiptFieldDateTime => 'التاريخ والوقت';

  @override
  String get orderCardReceiptFieldProvider => 'مزوّد الخدمة';

  @override
  String get orderCardReceiptRawFieldsTitle => 'كل حقول الإيصال';

  @override
  String get orderCardReceiptRawFieldsSubtitle =>
      'كما أرسلها المزوّد، للمطابقة المحاسبية.';

  @override
  String get orderCardReceiptNoneForOrder =>
      'لا توجد إيصالات بطاقة لهذه الفاتورة.';

  @override
  String get invoiceCardReceiptFilterLabel => 'إيصال البطاقة';

  @override
  String get cardProviderMoamalat => 'معاملات';

  @override
  String get cardProviderMadfoatech => 'مدفوعاتك';

  @override
  String get cardReceiptRequiredError =>
      'يجب مطابقة كل دفعة بطاقة قبل تأكيد الدفع.';

  @override
  String cardReceiptValidatedSummary(String amount, String maskedPan) {
    return 'تمت المطابقة: $amount، البطاقة $maskedPan';
  }

  @override
  String get cardReceiptDialogTitle => 'مطابقة إيصال البطاقة';

  @override
  String cardReceiptExpectedAmount(String amount) {
    return 'المبلغ المتوقع: $amount';
  }

  @override
  String get cardReceiptUrlLabel => 'رابط إيصال معاملات';

  @override
  String get cardReceiptCameraTooltip => 'مسح QR بالكاميرا';

  @override
  String get cardReceiptCameraTitle => 'امسح QR إيصال البطاقة';

  @override
  String cardReceiptAmountMismatch(
    String receiptAmount,
    String expectedAmount,
  ) {
    return 'مبلغ الإيصال $receiptAmount لا يطابق مبلغ الدفعة $expectedAmount.';
  }

  @override
  String get cardReceiptUrlRequiredError => 'أدخل رابط الإيصال أو امسح رمز QR.';

  @override
  String get cardReceiptInvalidUrlError =>
      'الرابط ليس رابط إيصال معاملات صالحًا.';

  @override
  String get cardReceiptMissingQueryError =>
      'رابط الإيصال لا يحتوي على بيانات المطابقة.';

  @override
  String get cardReceiptDecodeError => 'تعذر قراءة بيانات إيصال معاملات.';

  @override
  String get cardReceiptInvalidAmountError => 'تعذر قراءة مبلغ الإيصال.';

  @override
  String get cardReceiptUnsuccessfulError => 'الإيصال لا يشير إلى عملية ناجحة.';

  @override
  String get cardReceiptMissingReferenceError =>
      'الإيصال لا يحتوي على بيانات البطاقة أو مرجع العملية.';

  @override
  String cardReceiptTerminalNotTrusted(String terminalId) {
    return 'جهاز البطاقة $terminalId غير موجود ضمن الأجهزة الموثوقة.';
  }

  @override
  String get receiptToggleSubtitle =>
      'سيتم إرسال الفاتورة إلى الطابعة بعد إتمام الدفع.';

  @override
  String get receiptToggleTooltip => 'تبديل طباعة الفاتورة';

  @override
  String get shareInvoiceAfterPaymentLabel => 'مشاركة PDF بعد الدفع';

  @override
  String get shareInvoiceToggleSubtitle =>
      'سيتم فتح ورقة المشاركة على الجوال أو نافذة الحفظ على سطح المكتب.';

  @override
  String get shareInvoiceToggleTooltip => 'تبديل مشاركة ملف PDF للفاتورة';

  @override
  String get paidAmountLabel => 'المدفوع';

  @override
  String get remainingAmountLabel => 'المتبقي';

  @override
  String get changeDueLabel => 'الباقي للعميل';

  @override
  String get paymentTotalTooLowError =>
      'يجب أن يغطي مجموع الدفعات إجمالي البيع.';

  @override
  String get confirmPaymentButton => 'تأكيد الدفع';

  @override
  String get saleTypeLabel => 'نوع البيع';

  @override
  String get saleTypeStandardLabel => 'عادي';

  @override
  String get saleTypeCreditLabel => 'آجل';

  @override
  String get saleTypeQuotationLabel => 'عرض سعر';

  @override
  String get saleCustomerRequiredBanner =>
      'اختر عميلًا قبل إتمام بيع آجل أو عرض سعر.';

  @override
  String get creditBalanceDueLabel => 'المتبقّي على العميل';

  @override
  String get creditDownPaymentTooHighError =>
      'المبلغ المدفوع أكبر من الإجمالي.';

  @override
  String get creditFullyOnAccountHint =>
      'كامل المبلغ سيُسجَّل دَينًا على العميل. أضِف دفعة مقدّمة إن وُجدت.';

  @override
  String get creditDownPaymentHint =>
      'المبلغ المُدخَل دفعة مقدّمة؛ والباقي يُسجَّل دَينًا على العميل.';

  @override
  String get creditDueDateLabel => 'تاريخ الاستحقاق';

  @override
  String get creditDueDateUnset => 'اختر تاريخًا (اختياري)';

  @override
  String get creditDueDateClearTooltip => 'إزالة تاريخ الاستحقاق';

  @override
  String get creditDueDatePresetWeek => 'بعد أسبوع';

  @override
  String get creditDueDatePresetTwoWeeks => 'بعد أسبوعين';

  @override
  String get creditDueDatePresetMonth => 'بعد شهر';

  @override
  String get creditDownPaymentTenderTitle => 'دفعة مقدّمة';

  @override
  String get addDownPaymentButton => 'إضافة دفعة مقدّمة';

  @override
  String get printDownPaymentProofLabel => 'طباعة سند قبض';

  @override
  String get printDownPaymentProofSubtitle =>
      'طباعة إيصال بالدفعة المقدّمة على البيع الآجل.';

  @override
  String get quotationTotalLabel => 'إجمالي العرض';

  @override
  String get quotationReserveStockLabel => 'حجز الكمية';

  @override
  String get quotationReserveStockSubtitle =>
      'حجز الكميات المعروضة دون خصمها من المخزون حتى انتهاء صلاحية العرض.';

  @override
  String get quotationValidUntilLabel => 'صالح حتى';

  @override
  String get quotationValidUntilUnset => 'اختر تاريخًا';

  @override
  String get quotationNoPaymentHint =>
      'عرض السعر لا يتضمّن أي دفع ولا يخصم من المخزون.';

  @override
  String get noEnabledPaymentMethods =>
      'لا توجد طريقة دفع مفعلة. راجع إعدادات المتجر.';

  @override
  String get printInvoiceAfterPaymentLabel => 'طباعة الفاتورة بعد الدفع';

  @override
  String get saleCheckoutSuccess => 'تم تسجيل البيع.';

  @override
  String saleCheckoutSuccessWithReceipt(String receiptNumber) {
    return 'تم تسجيل البيع. رقم الإيصال: $receiptNumber';
  }

  @override
  String get invoicePrintSuccess => 'تم إرسال الفاتورة للطابعة.';

  @override
  String get invoicePrintError => 'تم تسجيل البيع، لكن تعذرت طباعة الفاتورة.';

  @override
  String get invoiceShareSuccess => 'تم تجهيز ملف PDF للفاتورة.';

  @override
  String get invoiceShareError => 'تعذر تجهيز ملف PDF للفاتورة.';

  @override
  String get publicInvoiceDialogTitle => 'فاتورة العميل عبر الإنترنت';

  @override
  String get publicInvoiceDialogSubtitle =>
      'اطلب من العميل مسح رمز QR لفتح الفاتورة.';

  @override
  String publicInvoiceDialogSubtitleWithReceipt(String receiptNumber) {
    return 'اطلب من العميل مسح رمز QR لفتح الفاتورة $receiptNumber.';
  }

  @override
  String get publicInvoiceUrlLabel => 'رابط الفاتورة';

  @override
  String get copyPublicInvoiceUrlButton => 'نسخ الرابط';

  @override
  String get publicInvoiceUrlCopiedMessage => 'تم نسخ رابط الفاتورة.';

  @override
  String get publicInvoiceQrSemanticsLabel => 'رمز QR لرابط الفاتورة';

  @override
  String get invoiceProfitLabel => 'الربح';

  @override
  String invoiceProfitValue(String amount) {
    return 'الربح $amount';
  }

  @override
  String invoiceProfitMarginValue(String percent) {
    return 'هامش $percent%';
  }

  @override
  String get saleCheckoutError =>
      'تعذر تسجيل البيع. تحقق من جلسة الدرج وحاول مرة أخرى.';

  @override
  String get saleCheckoutSessionExpired =>
      'لم تعد جلسة الدرج مفتوحة. يرجى فتح جلسة درج جديدة ثم إعادة المحاولة.';

  @override
  String get oversellWarningTitle => 'تنبيه المخزون';

  @override
  String get oversellWarningMessage =>
      'تتجاوز بعض عناصر السلة الكمية المتاحة. هل تريد إتمام البيع رغم ذلك؟';

  @override
  String get oversellBlockedMessage =>
      'لا يمكن إتمام البيع لأن الكمية المطلوبة تتجاوز المخزون المتاح.';

  @override
  String oversellLine(String productName, String requested, String available) {
    return '$productName: المطلوب $requested، المتاح $available';
  }

  @override
  String get lossSaleWarningTitle => 'تنبيه الخسارة';

  @override
  String get lossSaleWarningMessage =>
      'نحن نبيع بعض عناصر السلة بخسارة. هل تريد إتمام البيع رغم ذلك؟';

  @override
  String get lossSaleBlockedMessage =>
      'لا يمكن إتمام البيع لأن إعدادات المتجر تمنع البيع بخسارة.';

  @override
  String lossSaleLine(String productName, String amount) {
    return '$productName: الخسارة $amount';
  }

  @override
  String get reviewCartButton => 'مراجعة السلة';

  @override
  String get continueSaleButton => 'إتمام البيع';

  @override
  String get paymentUnauthorizedMessage =>
      'لا يملك هذا المستخدم صلاحية إتمام الدفع.';

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
  String get total => 'الإجمالي';

  @override
  String get registerSessionGateTitle => 'جلسة الدرج';

  @override
  String get checkingRegisterSession => 'جار فحص جلسة الدرج...';

  @override
  String get noOpenRegisterSession =>
      'لا توجد جلسة درج مفتوحة. ابدأ جلسة جديدة قبل البيع.';

  @override
  String get registerSessionLoadError =>
      'تعذر الاتصال بجلسة الدرج، فلا نعرف إن كانت هناك جلسة مفتوحة. أعد المحاولة قبل بدء جلسة جديدة، تفاديا لفتح جلستين.';

  @override
  String get openingCashInputLabel => 'نقدية الافتتاح';

  @override
  String get moneyAmountHint => '0.00';

  @override
  String get openingCashRequiredError => 'أدخل نقدية الافتتاح قبل بدء الجلسة.';

  @override
  String get startRegisterSessionButton => 'بدء الجلسة';

  @override
  String get startingRegisterSessionButton => 'جار بدء الجلسة...';

  @override
  String resumeRegisterSessionTitle(String sessionNumber) {
    return 'جلسة $sessionNumber';
  }

  @override
  String registerSessionOpeningCash(String amount) {
    return 'نقدية الافتتاح: $amount';
  }

  @override
  String get resumeRegisterSessionButton => 'متابعة البيع';

  @override
  String activeRegisterSessionLabel(String sessionNumber) {
    return 'جلسة $sessionNumber';
  }

  @override
  String get posSessionMenuTitle => 'إجراءات الجلسة';

  @override
  String get posSessionMenuTooltip => 'خيارات الجلسة';

  @override
  String get posShortcutsButtonTooltip => 'اختصارات لوحة المفاتيح';

  @override
  String get posShortcutsTitle => 'اختصارات لوحة المفاتيح';

  @override
  String get posShortcutsSubtitle => 'تعمل من أي مكان في شاشة البيع';

  @override
  String get posShortcutsSectionInvoices => 'الفواتير';

  @override
  String get posShortcutsSectionItems => 'الأصناف';

  @override
  String get posShortcutsSectionCheckout => 'الدفع';

  @override
  String get posShortcutNewInvoice => 'فتح فاتورة معلّقة جديدة';

  @override
  String get posShortcutCycleInvoices => 'التنقّل بين الفواتير المعلّقة';

  @override
  String get posShortcutCycleUnit => 'تبديل وحدة الصنف المحدد';

  @override
  String get posShortcutDeleteLine => 'حذف الصنف المحدد';

  @override
  String get posShortcutCheckout => 'إتمام البيع';

  @override
  String get payInRegisterSessionDescription => 'إيداع مبلغ نقدي في الدرج';

  @override
  String get payOutRegisterSessionDescription => 'سحب مبلغ نقدي من الدرج';

  @override
  String get posCashPurchaseTitle => 'شراء نقدي من الصندوق';

  @override
  String get posCashPurchaseDescription =>
      'تسجيل مشتريات تُدفع نقداً من الدرج وتدخل للمخزون';

  @override
  String get posCashPurchaseSupplierLabel => 'المورد';

  @override
  String get posCashPurchaseSelectSupplierHint => 'اختر المورد الذي اشتريت منه';

  @override
  String get posCashPurchaseChangeSupplierButton => 'تغيير';

  @override
  String get posCashPurchaseSupplierSearchHint => 'ابحث عن مورد…';

  @override
  String get posCashPurchaseNoSuppliersMessage => 'لا يوجد موردون مطابقون';

  @override
  String get posCashPurchaseProductSearchHint =>
      'ابحث باسم المنتج أو امسح الباركود';

  @override
  String get posCashPurchaseNoProductsMessage => 'لا توجد منتجات مطابقة';

  @override
  String get posCashPurchaseLinesEmptyMessage =>
      'أضف المنتجات المشتراة لتسجيلها';

  @override
  String get posCashPurchaseQuantityLabel => 'الكمية';

  @override
  String get posCashPurchaseUnitCostLabel => 'سعر الشراء';

  @override
  String get posCashPurchaseExpiryLabel => 'تاريخ الانتهاء';

  @override
  String get posCashPurchaseExpiryRequiredError =>
      'حدد تاريخ الانتهاء لهذا المنتج';

  @override
  String get posCashPurchaseTotalLabel => 'الإجمالي المدفوع من الدرج';

  @override
  String posCashPurchaseLimitHint(String amount) {
    return 'الحد الأقصى للشراء النقدي: $amount';
  }

  @override
  String posCashPurchaseOverLimitError(String amount) {
    return 'المبلغ يتجاوز الحد الأقصى المسموح ($amount)';
  }

  @override
  String get posCashPurchaseSubmitButton => 'تسجيل الشراء والدفع نقداً';

  @override
  String posCashPurchaseSuccessMessage(String orderNumber, String amount) {
    return 'تم تسجيل الشراء $orderNumber وخصم $amount من الدرج';
  }

  @override
  String get posCashPurchaseNoSessionError =>
      'تحتاج وردية صندوق مفتوحة لتسجيل شراء نقدي';

  @override
  String get posCashPurchaseCreateError =>
      'تعذر تسجيل الشراء. تحقق من البيانات وحاول مرة أخرى.';

  @override
  String get posCashPurchaseRemoveLineTooltip => 'إزالة الصنف';

  @override
  String get collectDebtSessionDescription =>
      'استلام دفعة من عميل عليه رصيد آجل';

  @override
  String get refreshCatalogDescription => 'مزامنة قائمة المنتجات مع الخادم';

  @override
  String get closeRegisterSessionDescription =>
      'إنهاء الجلسة وعدّ النقدية في الدرج';

  @override
  String get cashMovementMenuTooltip => 'حركات نقدية للدرج';

  @override
  String get payInRegisterSessionTitle => 'إضافة نقدية للدرج';

  @override
  String get payOutRegisterSessionTitle => 'سحب نقدية من الدرج';

  @override
  String get payInRegisterSessionButton => 'إضافة نقدية';

  @override
  String get payOutRegisterSessionButton => 'سحب نقدية';

  @override
  String get cashMovementAmountLabel => 'المبلغ';

  @override
  String get cashMovementReasonLabel => 'سبب الحركة';

  @override
  String get cashMovementReasonRequiredError => 'أدخل سبب الحركة قبل الحفظ.';

  @override
  String get positiveAmountRequiredError => 'أدخل مبلغًا أكبر من صفر.';

  @override
  String get cashMovementCreateError =>
      'تعذر حفظ الحركة النقدية. راجع المبلغ والسبب وحاول مرة أخرى.';

  @override
  String get cashMovementCreatedMessage => 'تم حفظ الحركة النقدية.';

  @override
  String get closeRegisterSessionTooltip => 'إغلاق جلسة الدرج';

  @override
  String get closeRegisterSessionTitle => 'إغلاق جلسة الدرج';

  @override
  String get closingCashInputLabel => 'النقد عند الإغلاق (بدون الفئات)';

  @override
  String get closingCashTotalLabel => 'إجمالي النقد عند الإغلاق';

  @override
  String denominationCountLabel(String denomination) {
    return 'عدد فئة $denomination';
  }

  @override
  String get cancelButton => 'إلغاء';

  @override
  String get editButton => 'تعديل';

  @override
  String get deleteButton => 'حذف';

  @override
  String get closeButton => 'إغلاق';

  @override
  String get closeRegisterSessionButton => 'إغلاق الجلسة';

  @override
  String get closingRegisterSessionButton => 'جار الإغلاق...';

  @override
  String get closeRegisterSessionError =>
      'تعذر إغلاق جلسة الدرج. راجع القيم وحاول مرة أخرى.';

  @override
  String get registerSessionHistoryTitle => 'سجل جلسات الدرج';

  @override
  String get refreshRegisterSessionsTooltip => 'تحديث سجل الجلسات';

  @override
  String get registerSessionsListTitle => 'جلسات الدرج';

  @override
  String get registerSessionHistoryLoadError => 'تعذر تحميل سجل الجلسات.';

  @override
  String get emptyRegisterSessionHistory => 'لا توجد جلسات درج مسجلة بعد.';

  @override
  String get registerSessionStatusOpen => 'مفتوحة';

  @override
  String get registerSessionStatusClosed => 'مغلقة';

  @override
  String get sessionSalesPlaceholderTitle => 'مبيعات الجلسة';

  @override
  String get selectRegisterSessionPrompt => 'اختر جلسة درج لعرض مبيعاتها.';

  @override
  String sessionSalesTitle(String sessionNumber) {
    return 'مبيعات جلسة $sessionNumber';
  }

  @override
  String get sessionSalesTab => 'المبيعات';

  @override
  String get sessionCashMovementsTab => 'حركات النقد';

  @override
  String get sessionSummaryTab => 'الملخص';

  @override
  String get sessionCashSummaryTitle => 'ملخص النقد';

  @override
  String get sessionOpeningCashMetric => 'نقدية الافتتاح';

  @override
  String get sessionCashSalesMetric => 'المبيعات النقدية';

  @override
  String get sessionPayInMetric => 'إضافات الدرج';

  @override
  String get sessionPayOutMetric => 'سحوبات الدرج';

  @override
  String get sessionCashRefundMetric => 'مبالغ الإرجاع النقدية';

  @override
  String get sessionExpectedCashMetric => 'النقد المتوقع';

  @override
  String get sessionClosingCashMetric => 'النقد المعدود';

  @override
  String get sessionCashVarianceMetric => 'فرق النقد';

  @override
  String get sessionDenominationsTitle => 'الفئات عند الإغلاق';

  @override
  String sessionVarianceFlag(String amount) {
    return 'فرق $amount';
  }

  @override
  String get sessionNoVariance => 'لا يوجد فرق مسجل';

  @override
  String get sessionSummaryLoadError => 'تعذّر تحميل ملخص الوردية.';

  @override
  String get sessionSalesSummaryTitle => 'ملخص المبيعات';

  @override
  String get sessionGrossSalesMetric => 'إجمالي المبيعات';

  @override
  String get sessionDiscountsMetric => 'الخصومات';

  @override
  String get sessionRefundsMetric => 'المرتجعات';

  @override
  String get sessionNetSalesMetric => 'صافي المبيعات';

  @override
  String get sessionOrderCountMetric => 'عدد الفواتير';

  @override
  String get sessionItemsSoldMetric => 'القطع المباعة';

  @override
  String get sessionVoidCountMetric => 'فواتير ملغاة';

  @override
  String get sessionExpensesMetric => 'مصروفات الوردية';

  @override
  String get sessionDrawerPurchasesMetric => 'مشتريات من الدرج';

  @override
  String get sessionPaymentMethodsTitle => 'حسب طريقة الدفع';

  @override
  String get sessionPaymentCollectedLabel => 'المقبوض';

  @override
  String get sessionPaymentCommissionLabel => 'العمولة';

  @override
  String get sessionPaymentRefundLabel => 'المرتجع';

  @override
  String get sessionPaymentNetLabel => 'الصافي';

  @override
  String get sessionPaymentsTotalLabel => 'إجمالي المقبوضات';

  @override
  String sessionPaymentOperationsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عملية',
      two: 'عمليتان',
      one: 'عملية واحدة',
      zero: 'لا عمليات',
    );
    return '$_temp0';
  }

  @override
  String get sessionCategoriesTitle => 'المبيعات حسب الفئة';

  @override
  String get sessionUncategorizedLabel => 'غير مصنف';

  @override
  String get sessionNoCategorySales =>
      'لا توجد مبيعات حسب الفئة في هذه الجلسة.';

  @override
  String sessionCategoryLineLabel(String category, String quantity) {
    return '$category ×$quantity';
  }

  @override
  String get sessionZReportTitle => 'تقرير إغلاق الوردية (Z)';

  @override
  String get sessionPrintZReportThermal => 'طباعة (إيصال)';

  @override
  String get sessionPrintZReportPdf => 'طباعة PDF';

  @override
  String get sessionShareZReportPdf => 'مشاركة / حفظ PDF';

  @override
  String get sessionZReportPrintedMessage => 'تمت طباعة تقرير الوردية.';

  @override
  String get sessionZReportSharedMessage => 'تم تجهيز تقرير الوردية.';

  @override
  String get sessionZReportFailedMessage => 'تعذّرت طباعة تقرير الوردية.';

  @override
  String get sessionClosedPrintZReportPrompt =>
      'تم إغلاق الوردية. هل تريد طباعة تقرير الإغلاق (Z)؟';

  @override
  String get sessionSalesLoadError => 'تعذر تحميل مبيعات هذه الجلسة.';

  @override
  String get emptySessionSales => 'لا توجد مبيعات مسجلة في هذه الجلسة.';

  @override
  String get clearCustomerFilterTooltip => 'مسح فلتر العميل';

  @override
  String get sessionCashMovementsLoadError =>
      'تعذر تحميل حركات النقد لهذه الجلسة.';

  @override
  String get emptySessionCashMovements =>
      'لا توجد حركات نقد مسجلة في هذه الجلسة.';

  @override
  String get cashMovementPayInLabel => 'إضافة نقدية';

  @override
  String get cashMovementPayOutLabel => 'سحب نقدية';

  @override
  String get invoicesTitle => 'الفواتير';

  @override
  String get refreshInvoicesTooltip => 'تحديث الفواتير';

  @override
  String get searchInvoicesHint =>
      'ابحث برقم الفاتورة أو المنتج أو SKU أو الباركود';

  @override
  String get invoicesLoadError => 'تعذر تحميل الفواتير.';

  @override
  String get emptyInvoices => 'لا توجد فواتير بعد.';

  @override
  String invoiceDetailsTitle(String receiptNumber) {
    return 'فاتورة $receiptNumber';
  }

  @override
  String get refreshInvoiceDetailsTooltip => 'تحديث تفاصيل الفاتورة';

  @override
  String get invoiceDetailsLoadError => 'تعذر تحميل تفاصيل الفاتورة.';

  @override
  String get invoiceActionsTitle => 'الإجراءات';

  @override
  String get invoiceSummaryTitle => 'ملخص الفاتورة';

  @override
  String get invoiceNumberLabel => 'رقم الفاتورة';

  @override
  String invoiceNumberValue(String receiptNumber) {
    return 'فاتورة $receiptNumber';
  }

  @override
  String get invoiceStatusLabel => 'الحالة';

  @override
  String get invoiceStatusFilterTitle => 'حالة الفاتورة';

  @override
  String get invoiceStatusAll => 'كل الحالات';

  @override
  String get invoiceStatusOpen => 'مفتوحة';

  @override
  String get invoiceStatusPaid => 'مدفوعة';

  @override
  String get invoiceStatusVoid => 'ملغاة';

  @override
  String get invoiceCustomerFilterTitle => 'العميل';

  @override
  String get invoiceCustomerLabel => 'العميل';

  @override
  String get invoiceRegisterSessionLabel => 'جلسة الدرج';

  @override
  String invoiceRegisterSessionValue(String sessionNumber) {
    return 'جلسة $sessionNumber';
  }

  @override
  String get invoiceLineCountLabel => 'العناصر';

  @override
  String get invoiceCreatedAtLabel => 'تاريخ الإصدار';

  @override
  String get invoiceUpdatedAtLabel => 'آخر تحديث';

  @override
  String get invoiceLinesTitle => 'المنتجات';

  @override
  String get invoiceLinesEmpty => 'لا توجد منتجات في هذه الفاتورة.';

  @override
  String get invoicePaymentsEmpty => 'لا توجد مدفوعات مسجلة لهذه الفاتورة.';

  @override
  String get recordInvoicePaymentButton => 'تسجيل دفعة';

  @override
  String invoiceCreditBalanceCalloutTitle(String amount) {
    return 'آجل — المتبقّي $amount.';
  }

  @override
  String get invoiceCreditBalanceCalloutBody =>
      'فاتورة آجلة لم يُسدَّد منها شيء بعد.';

  @override
  String invoiceCreditBalancePaidValue(String amount) {
    return 'المدفوع حتى الآن: $amount';
  }

  @override
  String get invoiceVoidedCalloutTitle => 'لا يمكن الإرجاع من هذه الفاتورة';

  @override
  String get invoiceVoidedCalloutBody =>
      'هذه الفاتورة ملغاة: أُرجعت أصنافها أو أُلغيت بالكامل، ولم يتبقَّ صنف قابل للإرجاع أو الاستبدال.';

  @override
  String get invoicePaymentTitle => 'تسجيل دفعة على الفاتورة';

  @override
  String get invoicePaymentAmountLabel => 'المبلغ';

  @override
  String get invoicePaymentReferenceLabel => 'مرجع اختياري';

  @override
  String get invoicePaymentPrintProofLabel => 'طباعة سند قبض';

  @override
  String invoicePaymentBalanceValue(String amount) {
    return 'المتبقّي على الفاتورة: $amount';
  }

  @override
  String get invoicePaymentAmountError =>
      'أدخل مبلغًا أكبر من صفر ولا يتجاوز المتبقّي.';

  @override
  String recordPaymentAmountMaxError(String amount) {
    return 'أدخل مبلغًا أكبر من صفر ولا يتجاوز $amount.';
  }

  @override
  String get invoicePaymentSuccess => 'تم تسجيل الدفعة على الفاتورة.';

  @override
  String get invoiceAssignCustomerButton => 'تعيين عميل';

  @override
  String get invoiceChangeCustomerButton => 'تغيير العميل';

  @override
  String get invoiceAssignCustomerSuccess => 'تم تعيين العميل على الفاتورة.';

  @override
  String get invoiceAssignCustomerError =>
      'تعذّر تعيين العميل على الفاتورة. لا يمكن ذلك بعد تسجيل أي دفعة.';

  @override
  String get invoiceTotalsTitle => 'الإجماليات';

  @override
  String get invoiceOrderingNewest => 'الأحدث أولًا';

  @override
  String get invoiceOrderingUpdated => 'آخر تحديث أولًا';

  @override
  String get invoiceOrderingTotalDesc => 'الإجمالي: من الأعلى إلى الأقل';

  @override
  String get invoiceOrderingReceiptNumber => 'رقم الفاتورة';

  @override
  String get invoiceReprintButton => 'إعادة طباعة الفاتورة';

  @override
  String get invoiceReprintInProgressButton => 'جار الطباعة...';

  @override
  String get invoiceReprintQueuedMessage => 'تم إرسال الفاتورة للطابعة.';

  @override
  String get invoiceReprintError => 'تعذرت طباعة الفاتورة.';

  @override
  String get invoiceShareButton => 'مشاركة PDF';

  @override
  String get invoiceShareInProgressButton => 'جار تجهيز PDF...';

  @override
  String get invoiceRowActionsTooltip => 'إجراءات الفاتورة';

  @override
  String get saleReceiptFallback => 'بدون رقم';

  @override
  String saleReceiptTitle(String receiptNumber) {
    return 'إيصال $receiptNumber';
  }

  @override
  String get saleReceiptShareButton => 'مشاركة PDF';

  @override
  String get saleReceiptShareInProgressButton => 'جار تجهيز PDF...';

  @override
  String get saleReceiptShareSuccess => 'تم تجهيز ملف PDF للإيصال.';

  @override
  String get saleReceiptShareError => 'تعذر تجهيز ملف PDF للإيصال.';

  @override
  String saleProductFallback(int productId) {
    return 'منتج رقم $productId';
  }

  @override
  String saleLineQuantityAndPrice(String quantity, String unitPrice) {
    return '$quantity × $unitPrice';
  }

  @override
  String get saleReprintButton => 'إعادة طباعة الإيصال';

  @override
  String get saleReprintInProgressButton => 'جار طلب الطباعة...';

  @override
  String get saleReprintQueuedMessage => 'تم إرسال طلب إعادة الطباعة.';

  @override
  String get saleReprintError => 'تعذر إرسال طلب إعادة الطباعة.';

  @override
  String get saleVoidButton => 'إلغاء الفاتورة';

  @override
  String get saleVoidTitle => 'إلغاء الفاتورة';

  @override
  String get saleVoidMessage =>
      'سيتم عكس كامل المبلغ وإرجاع الكميات المتبقية إلى المخزون.';

  @override
  String get saleVoidSuccess => 'تم إلغاء الفاتورة.';

  @override
  String get saleVoidError => 'تعذر إلغاء الفاتورة.';

  @override
  String get saleReturnButton => 'إرجاع منتجات';

  @override
  String get saleReturnTitle => 'إرجاع منتجات';

  @override
  String get saleReturnSuccess => 'تم تسجيل الإرجاع.';

  @override
  String get saleReturnError => 'تعذر تسجيل الإرجاع.';

  @override
  String get saleAdjustmentReasonLabel => 'سبب اختياري';

  @override
  String get saleAdjustmentReasonHint => 'مثال: طلب العميل الإرجاع';

  @override
  String get saleReturnQuantityLabel => 'كمية الإرجاع';

  @override
  String get saleExchangeButton => 'استبدال';

  @override
  String get saleExchangeTitle => 'استبدال منتجات';

  @override
  String get saleExchangeSuccess => 'تم تسجيل الاستبدال.';

  @override
  String get saleExchangeError => 'تعذّر تسجيل الاستبدال.';

  @override
  String get saleExchangeReturnedSectionTitle => 'العناصر المُرتجعة';

  @override
  String get saleExchangeReplacementSectionTitle => 'العناصر البديلة';

  @override
  String get saleExchangeSearchLabel => 'ابحث عن منتج بديل';

  @override
  String get saleExchangeSearchButton => 'بحث';

  @override
  String get saleExchangeNoResults => 'لا توجد نتائج مطابقة.';

  @override
  String get saleExchangeInvalidError =>
      'اختر عنصرًا مُرتجعًا واحدًا على الأقل وعنصرًا بديلًا.';

  @override
  String get saleExchangeSettlementLabel => 'طريقة تسوية الفرق';

  @override
  String saleExchangeNetPay(String amount) {
    return 'على العميل دفع $amount';
  }

  @override
  String saleExchangeNetRefund(String amount) {
    return 'يُرَدّ للعميل $amount';
  }

  @override
  String get saleExchangeNetEven => 'تبادل متكافئ — لا فرق';

  @override
  String get navReturnsExchange => 'المرتجعات والاستبدال';

  @override
  String get returnsLookupTitle => 'المرتجعات والاستبدال';

  @override
  String get returnsLookupPrompt =>
      'أدخل رقم الفاتورة لإجراء إرجاع أو استبدال.';

  @override
  String get returnsLookupFieldLabel => 'رقم الفاتورة';

  @override
  String get returnsLookupSearchButton => 'بحث';

  @override
  String get returnsLookupNotFound => 'لا توجد فاتورة بهذا الرقم.';

  @override
  String get returnsLookupEmpty => 'ابحث عن فاتورة برقمها للبدء.';

  @override
  String get returnsLookupNotFoundHint =>
      'تأكّد من رقم الفاتورة المطبوع على الإيصال، أو جرّب رقمًا آخر.';

  @override
  String get returnsLookupFailedTitle => 'تعذّر البحث عن الفاتورة';

  @override
  String get returnsLookupFailedMessage =>
      'لم يصل ردّ من الخادم، ولا يعني ذلك أن الفاتورة غير موجودة. تحقّق من الاتصال ثم أعد المحاولة.';

  @override
  String get salePaymentsTitle => 'المدفوعات';

  @override
  String salePaymentCommission(String amount, String percent) {
    return 'العمولة $amount بنسبة $percent%';
  }

  @override
  String saleLineReturnedQuantity(String returned, String quantity) {
    return 'تم إرجاع $returned من $quantity';
  }

  @override
  String get saleReturnNoItemsSelected => 'اختر كمية واحدة على الأقل للإرجاع.';

  @override
  String get saleNoReturnableItems => 'لا توجد كميات متاحة للإرجاع.';

  @override
  String get discountCouponCodeLabel => 'كود الخصم';

  @override
  String get discountCouponCodeHint => 'أدخل كود الكوبون';

  @override
  String get purchaseDiscountCodeHint => 'أدخل كود خصم المورد';

  @override
  String get clearCouponCodeTooltip => 'مسح كود الخصم';

  @override
  String get refreshDiscountPreviewTooltip => 'تحديث الخصومات';

  @override
  String get applyDiscountCodeButton => 'تطبيق الخصم';

  @override
  String get discountPreviewUnavailable => 'تعذر تحديث الخصومات الآن.';

  @override
  String get discountPreviewFailedCheckoutTitle => 'تعذر تحديث الخصومات';

  @override
  String get discountPreviewFailedCheckoutBody =>
      'قد توجد تخفيضات لا يمكن التحقق منها الآن. عند إتمام البيع سيحتسب النظام الخصومات الفعلية تلقائيًا، وقد يختلف الإجمالي النهائي عن المعروض.';

  @override
  String get discountPreviewFailedCheckoutConfirm => 'متابعة البيع';

  @override
  String discountCouponUnavailable(String code) {
    return 'الكود غير متاح: $code';
  }

  @override
  String get discountTotalLabel => 'الخصم';

  @override
  String discountCouponAppliedLabel(String code) {
    return 'كوبون $code';
  }

  @override
  String discountLineValue(String amount) {
    return 'خصم $amount';
  }

  @override
  String purchaseLineNetCostValue(String amount) {
    return 'صافي التكلفة $amount';
  }

  @override
  String get discountsDrawerLabel => 'الخصومات';

  @override
  String get discountManagementTitle => 'إدارة الخصومات';

  @override
  String get refreshDiscountsTooltip => 'تحديث الخصومات';

  @override
  String get discountCreateButton => 'خصم جديد';

  @override
  String get discountCreateTitle => 'إضافة خصم';

  @override
  String get discountEditTitle => 'تعديل خصم';

  @override
  String discountWizardStepLabel(int step, int total) {
    return '$step من $total';
  }

  @override
  String get discountWizardStepBasics => 'الأساسيات';

  @override
  String get discountWizardStepValue => 'قيمة الخصم';

  @override
  String get discountWizardStepEligibility => 'ينطبق على';

  @override
  String get discountWizardStepLimits => 'الحدود';

  @override
  String get discountWizardStepReview => 'المراجعة';

  @override
  String get discountWizardDescriptionToggle => 'إضافة وصف داخلي';

  @override
  String get discountWizardMaximumDiscountToggle => 'تحديد أقصى خصم';

  @override
  String get discountWizardRoundingToggle => 'تنظيف السعر بعد الخصم';

  @override
  String get discountWizardMinimumSubtotalToggle => 'اشتراط أقل إجمالي';

  @override
  String get discountWizardMinimumLineQuantityToggle => 'اشتراط أقل كمية';

  @override
  String get discountWizardProductScopeToggle => 'تطبيقه على منتجات محددة';

  @override
  String get discountWizardContactScopeToggle =>
      'تطبيقه على عملاء أو موردين محددين';

  @override
  String get discountWizardScheduleToggle => 'تحديد فترة للخصم';

  @override
  String get discountWizardUsageLimitsToggle => 'تحديد مرات الاستخدام';

  @override
  String get discountFormSummaryTitle => 'ملخص الخصم';

  @override
  String get discountSummaryPlaceholder => 'أدخل قيمة الخصم لمعاينة الملخص';

  @override
  String get discountSummaryAppliesAll => 'كل المنتجات';

  @override
  String get discountTargetedShort => 'أصناف محددة';

  @override
  String get discountSectionBasicsHint => 'الاسم والقناة وطريقة التطبيق';

  @override
  String get discountSectionValueHint => 'نوع الخصم وقيمته';

  @override
  String get discountSectionTargeting => 'على ماذا ينطبق';

  @override
  String get discountSectionTargetingHint => 'اتركه فارغًا لتطبيقه على كل شيء';

  @override
  String get discountSectionConditions => 'الشروط';

  @override
  String get discountSectionConditionsHint => 'حدود الحد الأدنى لتطبيق الخصم';

  @override
  String get discountSectionScheduleHint => 'فترة السريان وعدد مرات الاستخدام';

  @override
  String get discountSectionAdvanced => 'خيارات متقدمة';

  @override
  String get discountSectionAdvancedHint =>
      'الأولوية والتكديس مع الخصومات الأخرى';

  @override
  String get discountScopeAutoNote => 'ينطبق على كل صنف مطابق';

  @override
  String get discountValueTypePercentageHelp => 'نسبة مئوية تُخصم من السعر';

  @override
  String get discountValueTypeFixedAmountHelp => 'مبلغ ثابت يُخصم من الإجمالي';

  @override
  String get discountValueTypeFixedUnitAmountHelp => 'مبلغ يُخصم عن كل وحدة';

  @override
  String get discountValueTypeFixedPriceHelp =>
      'تثبيت سعر الصنف عند قيمة محددة';

  @override
  String get discountValueTypeMultiBuy => 'اشترِ عدّة بسعر';

  @override
  String get discountValueTypeMultiBuyHelp =>
      'حدّد عدد القطع في المجموعة وسعرها، مثل ٣ قطع بدينار.';

  @override
  String get discountValueTypeTiered => 'سعر متدرّج بالكمية';

  @override
  String get discountValueTypeTieredHelp =>
      'كلما زادت الكمية انخفض سعر الوحدة عبر شرائح.';

  @override
  String get discountValueTypeBuyXGetY => 'اشترِ X واحصل على Y';

  @override
  String get discountValueTypeBuyXGetYHelp =>
      'اشترِ كمية واحصل على قطع مجانية أو بخصم.';

  @override
  String get discountGroupSizeLabel => 'عدد قطع المجموعة';

  @override
  String get discountGroupPriceLabel => 'سعر المجموعة';

  @override
  String get discountBuyQuantityLabel => 'كمية الشراء (X)';

  @override
  String get discountGetQuantityLabel => 'كمية المكافأة (Y)';

  @override
  String get discountRewardTypeLabel => 'نوع المكافأة';

  @override
  String get discountRewardFree => 'مجانًا';

  @override
  String get discountRewardPercentage => 'نسبة خصم';

  @override
  String get discountRewardFixedPrice => 'سعر ثابت للقطعة';

  @override
  String get discountTiersLabel => 'شرائح السعر';

  @override
  String get discountTiersHint =>
      'حدّد سعر الوحدة عند كل كمية. تُطبَّق أعلى شريحة مؤهَّلة.';

  @override
  String get discountTierMinQuantityLabel => 'ابتداءً من كمية';

  @override
  String get discountTierUnitPriceLabel => 'سعر الوحدة';

  @override
  String get discountAddTierButton => 'إضافة شريحة';

  @override
  String get discountRemoveTierTooltip => 'حذف الشريحة';

  @override
  String get discountTiersRequiredError => 'أضف شريحة سعر واحدة على الأقل.';

  @override
  String discountMultiBuyValue(int count, String price) {
    return '$count بـ $price';
  }

  @override
  String discountTieredValue(String price) {
    return 'من $price';
  }

  @override
  String discountBuyGetValue(int buy, int get) {
    return 'اشترِ $buy واحصل على $get';
  }

  @override
  String discountMultiBuySummary(int count, String price) {
    return '$count قطع بـ $price';
  }

  @override
  String discountTierCountSummary(int count) {
    return '$count شرائح سعر';
  }

  @override
  String get discountRewardSummaryFree => 'القطعة المكافأة مجانًا';

  @override
  String discountRewardSummaryPercentage(String percent) {
    return 'خصم $percent% على المكافأة';
  }

  @override
  String discountRewardSummaryFixedPrice(String price) {
    return 'المكافأة بسعر $price';
  }

  @override
  String get discountWizardAdvancedToggle => 'إظهار خيارات متقدمة';

  @override
  String get discountWizardFixStepError =>
      'راجع الخطوة المحددة وأكمل البيانات المطلوبة.';

  @override
  String get discountFormFixFieldsError =>
      'أكمل الحقول المطلوبة المميزة بالأحمر.';

  @override
  String get discountWizardNoExtraRules => 'بدون شروط إضافية';

  @override
  String get discountWizardNoLimits => 'بدون حدود';

  @override
  String get discountLoadError => 'تعذر تحميل الخصومات.';

  @override
  String get discountSaveError =>
      'تعذر حفظ الخصم. راجع البيانات وحاول مرة أخرى.';

  @override
  String get discountEmptyRules => 'لا توجد خصومات بعد.';

  @override
  String get discountSearchHint => 'ابحث باسم الخصم أو الكود';

  @override
  String get discountStatusFilterLabel => 'الحالة';

  @override
  String get discountFilterAll => 'الكل';

  @override
  String get discountStatusActive => 'نشط';

  @override
  String get discountStatusInactive => 'متوقف';

  @override
  String get discountArchivedLabel => 'مؤرشف';

  @override
  String get discountOrderingLabel => 'الترتيب';

  @override
  String get discountOrderingPriority => 'الأولوية';

  @override
  String get discountOrderingName => 'الاسم';

  @override
  String get discountOrderingNewest => 'الأحدث';

  @override
  String get discountOrderingUpdated => 'آخر تعديل';

  @override
  String get discountNameLabel => 'اسم الخصم';

  @override
  String get discountDescriptionLabel => 'وصف داخلي';

  @override
  String get discountBasicsSection => 'الإعدادات الأساسية';

  @override
  String get discountConditionsSection => 'الشروط';

  @override
  String get discountUsageSection => 'حدود الاستخدام';

  @override
  String get discountChannelLabel => 'نطاق الخصم';

  @override
  String get discountChannelSales => 'المبيعات';

  @override
  String get discountChannelPurchasing => 'المشتريات';

  @override
  String get discountChannelBoth => 'المبيعات والمشتريات';

  @override
  String get discountApplicationTypeLabel => 'طريقة التطبيق';

  @override
  String get discountApplicationAutomatic => 'تلقائي';

  @override
  String get discountApplicationCoupon => 'كود';

  @override
  String get discountScopeLabel => 'مستوى التطبيق';

  @override
  String get discountScopeDocument => 'الفاتورة';

  @override
  String get discountScopeLine => 'السطر';

  @override
  String get discountValueTypeLabel => 'نوع الخصم';

  @override
  String get discountValueTypePercentage => 'نسبة مئوية';

  @override
  String get discountValueTypeFixedAmount => 'مبلغ ثابت';

  @override
  String get discountValueTypeFixedUnitAmount => 'مبلغ ثابت لكل وحدة';

  @override
  String get discountValueTypeFixedPrice => 'سعر ثابت';

  @override
  String get discountValueLabel => 'قيمة الخصم';

  @override
  String get discountMaxAmountLabel => 'أقصى خصم';

  @override
  String get discountRoundingModeLabel => 'طريقة تنظيف السعر';

  @override
  String get discountRoundingModeNone => 'بدون تنظيف';

  @override
  String get discountRoundingModeDown => 'نزولاً';

  @override
  String get discountRoundingModeNearest => 'لأقرب قيمة';

  @override
  String get discountRoundingModeUp => 'صعوداً';

  @override
  String get discountRoundingIncrementLabel => 'قيمة التقريب';

  @override
  String get discountRoundingIncrementError => 'أدخل قيمة تقريب صحيحة.';

  @override
  String discountRoundingSummary(String mode, String increment) {
    return '$mode إلى $increment';
  }

  @override
  String get discountPriorityLabel => 'الأولوية';

  @override
  String get discountExclusiveLabel => 'يمنع الخصومات الأقل أولوية';

  @override
  String get discountExclusiveHelper =>
      'عند تفعيله لا تطبق القواعد التالية بعد هذا الخصم.';

  @override
  String get discountExclusiveShort => 'حصري';

  @override
  String get discountActiveLabel => 'الخصم نشط';

  @override
  String get discountMinSubtotalLabel => 'أقل إجمالي';

  @override
  String get discountMinLineQuantityLabel => 'أقل كمية في السطر';

  @override
  String get discountStartsAtLabel => 'تاريخ البداية';

  @override
  String get discountEndsAtLabel => 'تاريخ النهاية';

  @override
  String get discountNoDateSelected => 'بدون تاريخ';

  @override
  String get discountPickDateTooltip => 'اختيار تاريخ';

  @override
  String get clearButton => 'مسح';

  @override
  String get discountProductIdsLabel => 'المنتجات الرئيسية';

  @override
  String get discountVariantIdsLabel => 'الخيارات / الرموز الدقيقة';

  @override
  String get discountProductCategoryIdsLabel => 'التصنيفات';

  @override
  String get discountCustomerIdsLabel => 'العملاء';

  @override
  String get discountSupplierIdsLabel => 'الموردون';

  @override
  String get discountPickerHelper => 'اختر من القائمة';

  @override
  String get discountNoConstraintsSelected => 'كل العناصر';

  @override
  String get discountOpenPickerTooltip => 'فتح قائمة الاختيار';

  @override
  String get discountPickerLoadError => 'تعذر تحميل القائمة.';

  @override
  String discountConstraintId(int id) {
    return 'معرّف $id';
  }

  @override
  String get discountProductPickerTitle => 'اختيار المنتجات';

  @override
  String get discountProductPickerEmpty => 'لا توجد منتجات مطابقة.';

  @override
  String get discountVariantPickerTitle => 'اختيار خيارات المنتجات';

  @override
  String get discountVariantPickerSearchHint =>
      'ابحث باسم المنتج أو رمز SKU أو الباركود';

  @override
  String get discountVariantPickerEmpty => 'لا توجد خيارات مطابقة.';

  @override
  String get discountProductCategoryPickerTitle => 'اختيار التصنيفات';

  @override
  String get discountProductCategoryPickerEmpty => 'لا توجد تصنيفات مطابقة.';

  @override
  String get discountCustomerPickerTitle => 'اختيار العملاء';

  @override
  String get discountCustomerPickerSearchHint => 'ابحث باسم العميل أو الهاتف';

  @override
  String get discountCustomerPickerEmpty => 'لا يوجد عملاء مطابقون.';

  @override
  String get discountSupplierPickerTitle => 'اختيار الموردين';

  @override
  String get discountSupplierPickerSearchHint => 'ابحث باسم المورد أو الهاتف';

  @override
  String get discountSupplierPickerEmpty => 'لا يوجد موردون مطابقون.';

  @override
  String get discountUsageLimitLabel => 'حد الاستخدام الكلي';

  @override
  String get discountPerCustomerLimitLabel => 'حد الاستخدام لكل عميل';

  @override
  String get discountPerSupplierLimitLabel => 'حد الاستخدام لكل مورد';

  @override
  String get discountSaveButton => 'حفظ الخصم';

  @override
  String get discountEditTooltip => 'تعديل الخصم';

  @override
  String get discountEnableTooltip => 'تفعيل الخصم';

  @override
  String get discountDisableTooltip => 'إيقاف الخصم';

  @override
  String get discountArchiveTooltip => 'أرشفة الخصم';

  @override
  String get discountEnabledMessage => 'تم تفعيل الخصم.';

  @override
  String get discountDisabledMessage => 'تم إيقاف الخصم.';

  @override
  String get discountArchivedMessage => 'تمت أرشفة الخصم.';

  @override
  String get discountArchiveTitle => 'أرشفة الخصم';

  @override
  String discountArchiveMessage(String name) {
    return 'سيتم إيقاف $name وإخفاؤه من التطبيق التلقائي.';
  }

  @override
  String get discountArchiveConfirmButton => 'أرشف الخصم';

  @override
  String get requiredFieldError => 'هذا الحقل مطلوب.';

  @override
  String get positiveNumberError => 'أدخل رقما أكبر من صفر.';

  @override
  String get nonNegativeNumberError => 'أدخل رقما لا يقل عن صفر.';

  @override
  String get positiveIntegerError => 'أدخل عددا صحيحا أكبر من صفر.';

  @override
  String get discountPercentError => 'النسبة لا يمكن أن تتجاوز 100%.';

  @override
  String get discountLineOnlyValueTypeError =>
      'هذا النوع يعمل على مستوى السطر فقط.';

  @override
  String get discountIdListError => 'أدخل معرفات صحيحة مفصولة بفواصل.';

  @override
  String get discountCustomerChannelError =>
      'شروط العملاء متاحة للمبيعات أو لكلا النطاقين فقط.';

  @override
  String get discountSupplierChannelError =>
      'شروط الموردين متاحة للمشتريات أو لكلا النطاقين فقط.';

  @override
  String get discountDateRangeError =>
      'تاريخ النهاية يجب أن يكون بعد تاريخ البداية.';

  @override
  String discountValueSummary(String type, String value) {
    return '$type: $value';
  }

  @override
  String discountPercentageValue(String value) {
    return '$value%';
  }

  @override
  String discountPrioritySummary(int priority) {
    return 'الأولوية $priority';
  }

  @override
  String discountCouponSummary(String code) {
    return 'الكود $code';
  }

  @override
  String discountMinSubtotalSummary(String amount) {
    return 'أقل إجمالي $amount';
  }

  @override
  String discountMinLineQuantitySummary(int quantity) {
    return 'أقل كمية $quantity';
  }

  @override
  String discountMaxAmountSummary(String amount) {
    return 'أقصى خصم $amount';
  }

  @override
  String discountUsageSummary(int used, int limit) {
    return 'الاستخدام $used/$limit';
  }

  @override
  String discountUsageCountSummary(int used) {
    return 'الاستخدام $used';
  }

  @override
  String discountAppliedCountSummary(int count) {
    return 'التطبيقات $count';
  }

  @override
  String discountStartsAtSummary(String date) {
    return 'يبدأ $date';
  }

  @override
  String discountEndsAtSummary(String date) {
    return 'ينتهي $date';
  }

  @override
  String discountProductConstraintSummary(int count) {
    return '$count منتجات';
  }

  @override
  String discountVariantConstraintSummary(int count) {
    return '$count خيارات دقيقة';
  }

  @override
  String discountProductCategoryConstraintSummary(int count) {
    return '$count تصنيفات';
  }

  @override
  String discountCustomerConstraintSummary(int count) {
    return '$count عملاء';
  }

  @override
  String discountSupplierConstraintSummary(int count) {
    return '$count موردين';
  }

  @override
  String get discountRankScopeToggle => 'حصره على تصنيفات عملاء معيّنة';

  @override
  String get discountRankScopeHint =>
      'يُطبَّق تلقائيًا فقط على العملاء ضمن التصنيفات المختارة.';

  @override
  String get discountRankConstraintLabel => 'التصنيفات المستهدفة';

  @override
  String discountRankConstraintSummary(int count) {
    return '$count تصنيف عميل';
  }

  @override
  String get yesLabel => 'نعم';

  @override
  String get noLabel => 'لا';

  @override
  String discountDetailsTitle(String name) {
    return 'تفاصيل $name';
  }

  @override
  String get discountDetailsRefreshTooltip => 'تحديث تفاصيل الخصم';

  @override
  String get discountDetailsLoadError => 'تعذر تحميل تفاصيل الخصم.';

  @override
  String get discountDetailsPerformanceSection => 'أداء الخصم';

  @override
  String get discountDetailsConfigurationSection => 'إعدادات الخصم';

  @override
  String get discountDetailsConstraintsSection => 'الشروط والنطاق';

  @override
  String get discountDetailsImpactSection => 'الأثر التقديري';

  @override
  String get discountDetailsTrendSection => 'الاتجاه الشهري';

  @override
  String get discountDetailsChannelBreakdownSection => 'توزيع النطاق';

  @override
  String get discountDetailsBeneficiariesSection => 'المستفيدون';

  @override
  String get discountDetailsRedemptionsMetric => 'الاستخدامات';

  @override
  String discountDetailsApplicationsSubtitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count تطبيقات',
      two: 'تطبيقان',
      one: 'تطبيق واحد',
      zero: 'لا توجد تطبيقات',
    );
    return '$_temp0';
  }

  @override
  String get discountDetailsBeneficiariesMetric => 'المستفيدون';

  @override
  String discountDetailsBeneficiariesSubtitle(int customers, int suppliers) {
    return '$customers عملاء • $suppliers موردون';
  }

  @override
  String get discountDetailsGrossInfluencedMetric => 'قيمة متأثرة';

  @override
  String get discountDetailsNetInfluencedMetric => 'صافي متأثر';

  @override
  String get discountDetailsDiscountCostMetric => 'تكلفة الخصم';

  @override
  String discountDetailsDiscountRateSubtitle(String rate) {
    return 'معدل الخصم $rate';
  }

  @override
  String get discountDetailsAverageDocumentMetric => 'متوسط المستند';

  @override
  String discountDetailsAverageDiscountSubtitle(String amount) {
    return 'متوسط الخصم $amount';
  }

  @override
  String get discountDetailsIncrementalNetMetric => 'قيمة صافية مقدرة';

  @override
  String get discountDetailsLiftUnavailable => 'لا يوجد خط أساس كاف';

  @override
  String discountDetailsLiftSubtitle(String rate) {
    return 'رفع مقدر $rate';
  }

  @override
  String get discountDetailsUsageLimitMetric => 'حد الاستخدام';

  @override
  String get discountDetailsUnlimitedUsage => 'غير محدود';

  @override
  String get discountDetailsNoUsageLimit => 'بدون حد استخدام';

  @override
  String discountDetailsUsageRemaining(int remaining, int limit) {
    return 'متبقٍ $remaining من $limit';
  }

  @override
  String get discountDetailsImpactMethodNote =>
      'التقدير يقارن الاستخدام الفعلي بآخر 90 يومًا من المستندات التاريخية المطابقة لشروط الخصم، لذلك هو مؤشر عملي وليس تجربة عزل كاملة.';

  @override
  String get discountDetailsExpectedDocumentsLabel =>
      'مستندات متوقعة بدون الخصم';

  @override
  String get discountDetailsExpectedGrossLabel => 'قيمة متوقعة بدون الخصم';

  @override
  String get discountDetailsIncrementalDocumentsLabel => 'مستندات إضافية مقدرة';

  @override
  String get discountDetailsIncrementalGrossLabel => 'قيمة إضافية مقدرة';

  @override
  String get discountDetailsBaselinePeriodLabel => 'فترة الخط الأساسي';

  @override
  String get discountDetailsBaselineDocumentsLabel => 'مستندات الخط الأساسي';

  @override
  String discountDetailsBaselineDocumentsValue(int count, String amount) {
    return '$count مستند • $amount';
  }

  @override
  String get discountDetailsConfidenceLabel => 'ثقة التقدير';

  @override
  String get discountDetailsConfidenceHigh => 'عالية';

  @override
  String get discountDetailsConfidenceMedium => 'متوسطة';

  @override
  String get discountDetailsConfidenceLow => 'منخفضة';

  @override
  String get discountDetailsConfidenceInsufficient => 'بيانات غير كافية';

  @override
  String discountDetailsPeriodValue(String start, String end) {
    return '$start إلى $end';
  }

  @override
  String get discountDetailsTrendEmpty =>
      'لا توجد استخدامات شهرية لهذا الخصم بعد.';

  @override
  String get discountDetailsTrendGrossHint =>
      'يعرض الشريط قيمة المستندات المتأثرة قبل الخصم.';

  @override
  String discountDetailsTrendValue(int count, String amount) {
    return '$count استخدام • $amount';
  }

  @override
  String get discountDetailsChannelBreakdownEmpty =>
      'لا توجد استخدامات موزعة حسب النطاق بعد.';

  @override
  String discountDetailsChannelBreakdownValue(
    int redemptions,
    int documents,
    String amount,
  ) {
    return '$redemptions استخدام • $documents مستند • صافي $amount';
  }

  @override
  String get discountDetailsBeneficiariesEmpty =>
      'لم يستخدم أي عميل أو مورد هذا الخصم بعد.';

  @override
  String get discountDetailsBeneficiariesLoadError =>
      'تعذر تحميل المستفيدين من الخصم.';

  @override
  String discountDetailsUseCountValue(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count استخدامات',
      two: 'استخدامان',
      one: 'استخدام واحد',
      zero: 'بدون استخدام',
    );
    return '$_temp0';
  }

  @override
  String discountDetailsDocumentCountValue(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count مستندات',
      two: 'مستندان',
      one: 'مستند واحد',
      zero: 'بدون مستندات',
    );
    return '$_temp0';
  }

  @override
  String discountDetailsBeneficiaryDiscountSummary(String amount) {
    return 'خصم $amount';
  }

  @override
  String discountDetailsBeneficiaryGrossSummary(String amount) {
    return 'قيمة $amount';
  }

  @override
  String discountDetailsLastUsedSummary(String date) {
    return 'آخر استخدام $date';
  }

  @override
  String discountDetailsFirstUsedSummary(String date) {
    return 'أول استخدام $date';
  }

  @override
  String get discountDetailsWalkInCustomer => 'عميل نقدي';

  @override
  String get discountDetailsUnknownSupplier => 'مورد غير محدد';

  @override
  String discountDetailsCountValue(int count) {
    return '$count';
  }

  @override
  String get printAuditButton => 'سجل الطباعة والمشاركة';

  @override
  String documentTrailSheetTitle(String documentNumber) {
    return 'سجل المستند $documentNumber';
  }

  @override
  String get documentTrailRefreshTooltip => 'تحديث السجل';

  @override
  String get documentTrailLoading => 'جارٍ تحميل السجل...';

  @override
  String get documentTrailLoadError => 'تعذّر تحميل سجل المستند.';

  @override
  String get documentTrailEmptyTitle => 'لا يوجد سجل بعد';

  @override
  String get documentTrailEmptyMessage =>
      'كل إصدار أو تصحيح أو إلغاء لهذا المستند سيظهر هنا، مع من قام به ومتى.';

  @override
  String get documentTrailOpenAction => 'سجل المستند';

  @override
  String get documentTrailActionCreated => 'أُنشئ';

  @override
  String get documentTrailActionSubmitted => 'صدر';

  @override
  String get documentTrailActionEdited => 'عُدّلت بياناته';

  @override
  String get documentTrailActionCorrected => 'صُحِّح';

  @override
  String get documentTrailActionCancelled => 'أُلغي';

  @override
  String get documentTrailActionAmended => 'استُبدل بنسخة مصححة';

  @override
  String get documentTrailActionSuperseded => 'حلّ محلّه مستند آخر';

  @override
  String get documentTrailActionUnknown => 'إجراء';

  @override
  String documentTrailActorValue(String name) {
    return 'بواسطة $name';
  }

  @override
  String get documentTrailUnknownActor => 'غير معروف';

  @override
  String get documentTrailReasonLabel => 'السبب';

  @override
  String documentTrailChangeValue(String from, String to) {
    return 'من $from إلى $to';
  }

  @override
  String get documentTrailEmptyValue => '(فارغ)';

  @override
  String get documentTrailFieldAmount => 'المبلغ';

  @override
  String get documentTrailFieldTotal => 'الإجمالي';

  @override
  String get documentTrailFieldSubtotal => 'المجموع الفرعي';

  @override
  String get documentTrailFieldDiscountTotal => 'إجمالي الخصم';

  @override
  String get documentTrailFieldExtraDiscount => 'خصم إضافي';

  @override
  String get documentTrailFieldQuantity => 'الكمية';

  @override
  String get documentTrailFieldUnitCost => 'تكلفة الوحدة';

  @override
  String get documentTrailFieldDescription => 'الوصف';

  @override
  String get documentTrailFieldNotes => 'ملاحظات';

  @override
  String get documentTrailFieldReference => 'المرجع';

  @override
  String get documentTrailFieldCustomer => 'العميل';

  @override
  String get documentTrailFieldSupplier => 'المورد';

  @override
  String get documentTrailFieldCategory => 'التصنيف';

  @override
  String get documentTrailFieldPaymentMethod => 'طريقة الدفع';

  @override
  String get documentTrailFieldSpentAt => 'تاريخ الصرف';

  @override
  String get documentTrailFieldDueDate => 'تاريخ الاستحقاق';

  @override
  String get documentTrailFieldSupplierInvoiceNumber => 'رقم فاتورة المورد';

  @override
  String get documentTrailFieldCancelledTotal => 'قيمة ما لن يصل';

  @override
  String get documentRetractedTitle => 'هذا المستند ملغى';

  @override
  String get documentRetractedMessage =>
      'لم يعد يُحتسب في أي تقرير أو رصيد. ما سجّله من حركة أُعيد.';

  @override
  String documentRetractedBy(String name, String when) {
    return 'بواسطة $name — $when';
  }

  @override
  String documentRetractedAt(String when) {
    return 'بتاريخ $when';
  }

  @override
  String documentRetractedReason(String reason) {
    return 'السبب: $reason';
  }

  @override
  String documentAmendmentBadge(int index) {
    return 'نسخة $index';
  }

  @override
  String printAuditSheetTitle(String documentNumber) {
    return 'سجل الطباعة والمشاركة $documentNumber';
  }

  @override
  String get printAuditRefreshTooltip => 'تحديث سجل الطباعة والمشاركة';

  @override
  String get printAuditLoading => 'جار تحميل سجل الطباعة والمشاركة...';

  @override
  String get printAuditLoadError => 'تعذر تحميل سجل الطباعة والمشاركة.';

  @override
  String get printAuditEmptyTitle => 'لا توجد عمليات مسجلة';

  @override
  String get printAuditEmptyMessage =>
      'ستظهر هنا عمليات الطباعة والمشاركة التي تمر عبر الخادم.';

  @override
  String printAuditEventTitle(String action, String status) {
    return '$action - $status';
  }

  @override
  String get printAuditActionPrint => 'طباعة';

  @override
  String get printAuditActionShare => 'مشاركة PDF';

  @override
  String get printAuditStatusRequested => 'قيد الطلب';

  @override
  String get printAuditStatusCompleted => 'مكتمل';

  @override
  String get printAuditStatusCanceled => 'ملغى';

  @override
  String get printAuditStatusFailed => 'فشل';

  @override
  String get printAuditUnknownActor => 'مستخدم غير معروف';

  @override
  String printAuditTimeValue(String time) {
    return 'الوقت $time';
  }

  @override
  String printAuditActorValue(String actor) {
    return 'المنفذ $actor';
  }

  @override
  String printAuditDeviceValue(String device) {
    return 'الجهاز $device';
  }

  @override
  String printAuditPrinterValue(String printer) {
    return 'الطابعة $printer';
  }

  @override
  String printAuditChannelValue(String channel) {
    return 'القناة $channel';
  }

  @override
  String printAuditEndpointValue(String endpoint) {
    return 'نقطة الاتصال $endpoint';
  }

  @override
  String printAuditJobValue(int jobId) {
    return 'مهمة الطباعة #$jobId';
  }

  @override
  String printAuditMessageValue(String message) {
    return 'الرسالة $message';
  }

  @override
  String get printAuditChannelNativeShare => 'ورقة المشاركة';

  @override
  String get printAuditChannelFileSave => 'حفظ ملف';

  @override
  String get printAuditChannelBrowserDownload => 'تنزيل المتصفح';

  @override
  String get confirmButton => 'تأكيد';

  @override
  String get saveButton => 'حفظ';

  @override
  String get accountantRoleLabel => 'محاسب';

  @override
  String get employeesDrawerLabel => 'الموظفون والرواتب';

  @override
  String get employeePayrollTitle => 'الموظفون والرواتب';

  @override
  String get refreshEmployeePayrollTooltip => 'تحديث الموظفين والرواتب';

  @override
  String get employeePayrollOverviewTitle => 'إدارة الموظفين والرواتب';

  @override
  String get employeePayrollOverviewSubtitle =>
      'سجلات الموظفين وخطط الأجر ومسيرات الرواتب';

  @override
  String get payrollHomeTabLabel => 'الرواتب';

  @override
  String payrollMonthCardTitle(String month) {
    return 'رواتب $month';
  }

  @override
  String get payrollMonthStepPrepare => 'تجهيز';

  @override
  String get payrollMonthStepApprove => 'اعتماد';

  @override
  String get payrollMonthStepPay => 'دفع';

  @override
  String get payrollMonthNoRunMessage =>
      'لم يتم تجهيز مسير رواتب هذا الشهر بعد.';

  @override
  String get payrollMonthDraftMessage => 'المسير جاهز للمراجعة والاعتماد.';

  @override
  String get payrollMonthApprovedMessage =>
      'المسير معتمد وبانتظار تسجيل الدفع.';

  @override
  String get payrollMonthPaidMessage => 'تم دفع رواتب هذا الشهر.';

  @override
  String get payrollMonthOnboardingMessage =>
      'أضف موظفيك وحدد خطط رواتبهم لبدء تجهيز مسيرات الرواتب.';

  @override
  String get preparePayrollMonthButton => 'تجهيز رواتب الشهر';

  @override
  String get reviewAndApprovePayrollButton => 'مراجعة واعتماد';

  @override
  String get recordPayrollPaymentButton => 'تسجيل الدفع';

  @override
  String get viewPayrollRunButton => 'عرض المسير';

  @override
  String get customPayrollRunButton => 'مسير مخصص';

  @override
  String get payrollHistoryTitle => 'سجل المسيرات';

  @override
  String get pendingLoanRequestsTitle => 'طلبات سلف بانتظار قرارك';

  @override
  String get employeeLoanApproveButton => 'موافقة';

  @override
  String get employeeLoanRejectButton => 'رفض';

  @override
  String get showAllLoansButton => 'عرض كل السلف';

  @override
  String get approveEmployeeLoanConfirmTitle => 'الموافقة على السلفة؟';

  @override
  String approveEmployeeLoanConfirmMessage(
    String employee,
    String amount,
    String monthly,
  ) {
    return 'سيتم اعتماد سلفة $employee بمبلغ $amount، ويُخصم $monthly من الراتب كل شهر حتى السداد. لا يمكن التراجع عن القرار.';
  }

  @override
  String get rejectEmployeeLoanConfirmTitle => 'رفض طلب السلفة؟';

  @override
  String rejectEmployeeLoanConfirmMessage(String employee, String amount) {
    return 'سيتم رفض طلب $employee بمبلغ $amount. لا يمكن التراجع عن القرار، وسيلزم تقديم طلب جديد.';
  }

  @override
  String get approvePayrollConfirmTitle => 'اعتماد مسير الرواتب؟';

  @override
  String approvePayrollConfirmMessage(String employees, String amount) {
    return 'سيتم اعتماد رواتب $employees بإجمالي صافي $amount. لا يمكن تعديل البنود بعد الاعتماد.';
  }

  @override
  String get approvePayrollConfirmButton => 'اعتماد';

  @override
  String get markPayrollPaidConfirmTitle => 'تسجيل دفع الرواتب؟';

  @override
  String markPayrollPaidConfirmMessage(String amount) {
    return 'سيتم تسجيل المسير كمدفوع بإجمالي $amount، وستُخصم أقساط السلف المرتبطة تلقائيًا.';
  }

  @override
  String get markPayrollPaidConfirmButton => 'تسجيل الدفع';

  @override
  String payrollAdditionsChipLabel(String amount) {
    return 'إضافات $amount';
  }

  @override
  String payrollDeductionsChipLabel(String amount) {
    return 'خصومات $amount';
  }

  @override
  String payrollAbsenceChipLabel(String days) {
    return 'غياب $days يوم';
  }

  @override
  String payrollOvertimeChipLabel(String hours, String amount) {
    return 'إضافي $hours س ($amount)';
  }

  @override
  String get payrollLineOvertimePayLabel => 'أجر العمل الإضافي';

  @override
  String get overtimeHoursField => 'ساعات العمل الإضافي';

  @override
  String overtimeHoursHelper(String rate, String multiplier) {
    return 'تُحتسب تلقائيًا: $rate للساعة × $multiplier';
  }

  @override
  String get overtimeMultiplierField => 'معامل الأجر الإضافي';

  @override
  String get overtimeMultiplierHelper =>
      'مثال: 1.50 يعني أجر الساعة الإضافية = 1.5 ضعف الأجر العادي';

  @override
  String get standardDailyHoursField => 'ساعات العمل اليومية';

  @override
  String get standardDailyHoursHelper => 'تُستخدم لاحتساب أجر الساعة الواحدة';

  @override
  String get payrollLineTapToAdjustHint =>
      'اضغط على موظف لتعديل غيابه وعمله الإضافي وإضافاته وخصوماته.';

  @override
  String get employeeNoPlanWarning => 'لا توجد خطة راتب';

  @override
  String get employeeCompensationButton => 'خطة الراتب';

  @override
  String get addEmployeeButton => 'إضافة موظف';

  @override
  String get draftMonthlyPayrollButton => 'مسودة رواتب الشهر';

  @override
  String get createPayrollRunButton => 'إنشاء مسير رواتب';

  @override
  String get employeePayrollSaveError =>
      'تعذر حفظ التغيير. راجع البيانات والصلاحيات ثم حاول مرة أخرى.';

  @override
  String get employeesTabLabel => 'الموظفون';

  @override
  String get payrollRunsTabLabel => 'مسيرات الرواتب';

  @override
  String get employeeLoansTabLabel => 'طلبات السلفة';

  @override
  String get employeesLoadError => 'تعذر تحميل الموظفين.';

  @override
  String get emptyEmployees => 'لا توجد سجلات موظفين بعد.';

  @override
  String employeeSystemAccessLabel(String username) {
    return 'دخول للنظام: $username';
  }

  @override
  String employeePayPlanLabel(String payType, String amount) {
    return '$payType - $amount';
  }

  @override
  String employeePayPlanWithCommissionLabel(String baseLabel, String percent) {
    return '$baseLabel + $percent% مبيعات';
  }

  @override
  String employeeMonthlyFixedPlanLabel(String amount) {
    return 'راتب شهري ثابت - $amount';
  }

  @override
  String employeeCommissionOnlyPlanLabel(String percent) {
    return 'عمولة مبيعات فقط - $percent%';
  }

  @override
  String employeeMonthlyFixedPlusCommissionPlanLabel(
    String amount,
    String percent,
  ) {
    return 'راتب شهري ثابت $amount + $percent% مبيعات';
  }

  @override
  String employeeUnitBasedPlanLabel(
    String salaryType,
    String amount,
    String units,
  ) {
    return '$salaryType - $amount × $units';
  }

  @override
  String get employeeNoDetails => 'لا توجد تفاصيل إضافية';

  @override
  String get addCompensationPlanTooltip => 'إضافة خطة أجر';

  @override
  String get payrollRunsLoadError => 'تعذر تحميل مسيرات الرواتب.';

  @override
  String get emptyPayrollRuns => 'لا توجد مسيرات رواتب بعد.';

  @override
  String get employeeLoansLoadError => 'تعذر تحميل طلبات السلفة.';

  @override
  String get emptyEmployeeLoans => 'لا توجد طلبات سلفة بعد.';

  @override
  String get employeeLoanStatusRequested => 'بانتظار الاعتماد';

  @override
  String get employeeLoanStatusApproved => 'معتمد';

  @override
  String get employeeLoanStatusRejected => 'مرفوض';

  @override
  String get employeeLoanStatusCancelled => 'ملغي';

  @override
  String get employeeLoanStatusPaid => 'مسدد';

  @override
  String employeeLoanAmountDetail(String amount) {
    return 'المبلغ $amount';
  }

  @override
  String employeeLoanMonthlyDeductionDetail(String amount) {
    return 'شهريًا $amount';
  }

  @override
  String get approveEmployeeLoanTooltip => 'اعتماد طلب السلفة';

  @override
  String get rejectEmployeeLoanTooltip => 'رفض طلب السلفة';

  @override
  String payrollLineCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count موظفين',
      two: 'موظفان',
      one: 'موظف واحد',
      zero: 'لا موظفين',
    );
    return '$_temp0';
  }

  @override
  String payrollPeriodSubtitle(String start, String end) {
    return '$start إلى $end';
  }

  @override
  String get payrollRunDetailsTooltip => 'عرض تفاصيل المسير';

  @override
  String payrollRunDetailsTitle(String runNumber) {
    return 'تفاصيل مسير $runNumber';
  }

  @override
  String get payrollRunDetailsLoadError => 'تعذر تحميل تفاصيل مسير الرواتب.';

  @override
  String get payrollRunSummarySection => 'ملخص المسير';

  @override
  String get payrollRunEmployeesSection => 'الموظفون في المسير';

  @override
  String get payrollRunGrossTotalLabel => 'الإجمالي الأساسي';

  @override
  String get payrollRunAdditionsTotalLabel => 'الإضافات';

  @override
  String get payrollRunDeductionsTotalLabel => 'الخصومات';

  @override
  String get payrollRunNetTotalLabel => 'الصافي';

  @override
  String get payrollRunPeriodLabel => 'الفترة';

  @override
  String get payrollRunPaymentDateLabel => 'تاريخ الدفع';

  @override
  String get payrollRunNotesLabel => 'الملاحظات';

  @override
  String get payrollRunNoNotes => 'لا توجد ملاحظات';

  @override
  String get payrollRunCreatedAtLabel => 'أُنشئ في';

  @override
  String get payrollRunApprovedByLabel => 'اعتمده';

  @override
  String get payrollRunPaidByLabel => 'سجله كمدفوع';

  @override
  String payrollRunActorWithDate(String actor, String date) {
    return '$actor - $date';
  }

  @override
  String get payrollRunNoEmployees => 'لا توجد بنود موظفين في هذا المسير.';

  @override
  String get payrollBulkAdjustmentButton => 'تعديل جماعي للرواتب';

  @override
  String get payrollBulkAdjustmentTitle => 'تعديل جماعي للرواتب';

  @override
  String get payrollBulkAdjustmentSubtitle =>
      'اختر الموظفين وأدخل مبلغًا يطبق على كل موظف محدد.';

  @override
  String get payrollBulkAdjustmentAmountLabel => 'المبلغ لكل موظف';

  @override
  String get payrollBulkAdjustmentAmountHelper =>
      'سيطبق نفس المبلغ على كل موظف محدد.';

  @override
  String get payrollBulkAdjustmentNotesLabel => 'ملاحظات التعديل';

  @override
  String get payrollBulkSelectionSection => 'الموظفون المحددون';

  @override
  String get payrollBulkSelectAllEmployees => 'اختيار كل موظفي المسير';

  @override
  String payrollBulkSelectedCount(int selected, int total) {
    return '$selected من $total محددين';
  }

  @override
  String get payrollBulkNoEmployeesSelected => 'اختر موظفًا واحدًا على الأقل.';

  @override
  String get payrollBulkPositiveAmountError => 'أدخل مبلغًا أكبر من صفر.';

  @override
  String get payrollBulkSelectedEmployeesLabel => 'الموظفون';

  @override
  String get payrollBulkAmountPerEmployeeLabel => 'لكل موظف';

  @override
  String get payrollBulkTotalAdditionLabel => 'إجمالي الإضافة';

  @override
  String get payrollBulkTotalDeductionLabel => 'إجمالي الخصم';

  @override
  String get payrollBulkAdjustmentSaveButton => 'تطبيق على المحددين';

  @override
  String get payrollBulkAdjustmentSaveError => 'تعذر تطبيق التعديل الجماعي.';

  @override
  String get payrollLineManualPayLabel => 'أجر يدوي';

  @override
  String get editPayrollLineAdjustmentsTooltip => 'تعديل غياب وإضافات الموظف';

  @override
  String payrollLineAdjustmentTitle(String employee) {
    return 'تعديل راتب $employee';
  }

  @override
  String get payrollLineAdjustmentSubtitle =>
      'أدخل الغياب أو الزيادة أو أي إضافة وخصم يدوي لهذا المسير فقط.';

  @override
  String get absenceDaysField => 'أيام الغياب';

  @override
  String absenceDaysHelper(String rate) {
    return 'يُحسب الخصم تلقائيًا حسب قيمة اليوم: $rate';
  }

  @override
  String absenceDaysExceedPeriodError(int days) {
    return 'لا يمكن أن تتجاوز أيام الغياب $days يومًا.';
  }

  @override
  String get raiseAmountField => 'زيادة هذا الشهر';

  @override
  String get raiseAmountHelper =>
      'مبلغ إضافي مؤقت يُضاف لصافي هذا الموظف في هذا المسير.';

  @override
  String get manualAdditionAmountField => 'إضافة يدوية';

  @override
  String get manualAdditionAmountHelper =>
      'أي مبلغ إضافي يقرره المدير لهذا الموظف.';

  @override
  String get manualDeductionAmountField => 'خصم يدوي';

  @override
  String get manualDeductionAmountHelper =>
      'أي مبلغ خصم إضافي يقرره المدير لهذا الموظف.';

  @override
  String get payrollAdjustmentPreviewSection => 'المجموع المتوقع';

  @override
  String get payrollLineProjectedNetLabel => 'الصافي المتوقع';

  @override
  String get payrollLineAdjustmentSaveButton => 'حفظ التعديل';

  @override
  String get payrollLineAdjustmentSaveError => 'تعذر حفظ تعديل راتب الموظف.';

  @override
  String get negativeNetPayrollLineError =>
      'الصافي المتوقع لا يمكن أن يكون أقل من صفر.';

  @override
  String payrollEmployeeFallbackLabel(int id) {
    return 'موظف #$id';
  }

  @override
  String get payrollLineUnitsLabel => 'الوحدات';

  @override
  String get payrollLineRateLabel => 'الأجر';

  @override
  String get payrollLineGrossLabel => 'الأساسي';

  @override
  String get payrollLineAbsenceDaysLabel => 'أيام الغياب';

  @override
  String get payrollLineAbsenceDeductionLabel => 'خصم الغياب';

  @override
  String get payrollLineRaiseLabel => 'الزيادة';

  @override
  String get payrollLineAdditionsLabel => 'الإضافات';

  @override
  String get payrollLineDeductionsLabel => 'الخصومات';

  @override
  String get payrollLineNetLabel => 'الصافي';

  @override
  String get payrollLineDescriptionLabel => 'الوصف';

  @override
  String get payrollLineNotesLabel => 'ملاحظات البند';

  @override
  String get payrollLineAdjustmentsLabel => 'التعديلات';

  @override
  String payrollLineAmountDetail(String label, String value) {
    return '$label: $value';
  }

  @override
  String payrollAdjustmentDetailLabel(String direction, String type) {
    return '$direction - $type';
  }

  @override
  String payrollAdjustmentAmountWithNotes(String amount, String notes) {
    return '$amount - $notes';
  }

  @override
  String get payrollAdjustmentAddition => 'إضافة';

  @override
  String get payrollAdjustmentDeduction => 'خصم';

  @override
  String get payrollAdjustmentBonus => 'مكافأة';

  @override
  String get payrollAdjustmentCommission => 'عمولة';

  @override
  String get payrollAdjustmentOvertime => 'وقت إضافي';

  @override
  String get payrollAdjustmentReimbursement => 'تعويض';

  @override
  String get payrollAdjustmentAdvance => 'سلفة';

  @override
  String get payrollAdjustmentLoan => 'خصم سلفة';

  @override
  String get payrollAdjustmentAbsence => 'غياب';

  @override
  String get payrollAdjustmentPenalty => 'جزاء';

  @override
  String get payrollAdjustmentOther => 'تعديل آخر';

  @override
  String get approvePayrollRunTooltip => 'اعتماد مسير الرواتب';

  @override
  String get markPayrollRunPaidTooltip => 'تسجيل المسير كمدفوع';

  @override
  String get missingDateLabel => 'تاريخ غير محدد';

  @override
  String get employeeNameField => 'اسم الموظف';

  @override
  String get employeeJobTitleField => 'المسمى الوظيفي';

  @override
  String get employeeDepartmentField => 'القسم';

  @override
  String get employeePhoneField => 'الهاتف';

  @override
  String get employeeHireDateField => 'تاريخ التعيين';

  @override
  String get employeeUserField => 'مستخدم نقطة البيع';

  @override
  String get employeeUserEmpty => 'غير مرتبط بمستخدم';

  @override
  String get employeeUserHelper =>
      'اربط الموظف بمستخدم إذا كان يعمل على النظام مثل الكاشير.';

  @override
  String get employeeUserClearTooltip => 'إزالة المستخدم المرتبط';

  @override
  String get employeeUserOpenPickerTooltip => 'اختيار مستخدم';

  @override
  String get employeeUserPickerTitle => 'اختيار مستخدم';

  @override
  String get employeeUserPickerSearchHint => 'ابحث باسم المستخدم أو البريد';

  @override
  String get employeeUserPickerEmpty => 'لا توجد مستخدمون مطابقون.';

  @override
  String get employeeUserPickerClear => 'مسح الاختيار';

  @override
  String get employeeUserPickerLoadError => 'تعذر تحميل المستخدمين.';

  @override
  String userFallbackLabel(int id) {
    return 'مستخدم #$id';
  }

  @override
  String get employeeTypeField => 'نوع التوظيف';

  @override
  String get employeeStatusActive => 'نشط';

  @override
  String get employeeStatusOnLeave => 'في إجازة';

  @override
  String get employeeStatusInactive => 'متوقف';

  @override
  String get employeeStatusTerminated => 'منتهي الخدمة';

  @override
  String get employmentTypeFullTime => 'دوام كامل';

  @override
  String get employmentTypePartTime => 'دوام جزئي';

  @override
  String get employmentTypeContractor => 'متعاقد';

  @override
  String get employmentTypeSeasonal => 'موسمي';

  @override
  String get employmentTypeIntern => 'متدرب';

  @override
  String get employmentTypeOther => 'آخر';

  @override
  String addCompensationPlanTitle(String employee) {
    return 'خطة أجر $employee';
  }

  @override
  String get payTypeField => 'نوع الأجر';

  @override
  String get payAmountField => 'المبلغ';

  @override
  String get payUnitsField => 'الوحدات';

  @override
  String get payEffectiveFromField => 'يبدأ من';

  @override
  String get salaryTypeField => 'نوع الراتب';

  @override
  String get salaryTypeMonthlyFixed => 'راتب شهري ثابت';

  @override
  String get salaryTypeWeeklyFixed => 'أجر أسبوعي ثابت';

  @override
  String get salaryTypeDailyRate => 'أجر يومي';

  @override
  String get salaryTypeHourlyRate => 'أجر بالساعة';

  @override
  String get salaryTypePerShift => 'أجر بالوردية';

  @override
  String get salaryTypeSalesCommissionOnly => 'عمولة مبيعات فقط';

  @override
  String get salaryTypeMonthlyFixedPlusSalesCommission =>
      'راتب شهري + عمولة مبيعات';

  @override
  String get salaryTypeContractFixed => 'مبلغ عقد ثابت';

  @override
  String get salaryTypeCustomFixed => 'نوع مخصص';

  @override
  String get salaryTypeMonthlyFixedHelper =>
      'يدفع مبلغًا ثابتًا كل شهر دون احتساب عمولة مبيعات.';

  @override
  String get salaryTypeWeeklyFixedHelper =>
      'يدفع مبلغًا ثابتًا لكل أسبوع. أدخل عدد الأسابيع المتوقع في مسير الشهر.';

  @override
  String get salaryTypeDailyRateHelper =>
      'يدفع أجرًا لكل يوم عمل. أدخل عدد الأيام المتوقع في مسير الشهر.';

  @override
  String get salaryTypeHourlyRateHelper =>
      'يدفع أجرًا لكل ساعة. أدخل عدد الساعات المتوقع في مسير الشهر.';

  @override
  String get salaryTypePerShiftHelper =>
      'يدفع أجرًا لكل وردية. أدخل عدد الورديات المتوقع في مسير الشهر.';

  @override
  String get salaryTypeSalesCommissionOnlyHelper =>
      'يدفع نسبة من المبيعات المدفوعة للمستخدم المرتبط بالموظف فقط.';

  @override
  String get salaryTypeMonthlyFixedPlusSalesCommissionHelper =>
      'يدفع الراتب الشهري الثابت ويضيف نسبة من مبيعات المستخدم المرتبط.';

  @override
  String get salaryTypeContractFixedHelper =>
      'يدفع مبلغ عقد ثابت في كل مسير رواتب إلى أن يتم تعطيل الخطة.';

  @override
  String get salaryTypeCustomFixedHelper =>
      'استخدمه عندما لا يناسب الموظف أي نوع جاهز. أضف ملاحظة توضّح طريقة الدفع.';

  @override
  String get monthlyBaseSalaryField => 'الراتب الشهري الثابت';

  @override
  String get monthlyBaseSalaryHelper =>
      'المبلغ الأساسي الذي يستحقه الموظف كل شهر.';

  @override
  String get compensationAmountField => 'المبلغ';

  @override
  String get weeklyAmountField => 'المبلغ الأسبوعي';

  @override
  String get dailyRateField => 'الأجر اليومي';

  @override
  String get hourlyRateField => 'أجر الساعة';

  @override
  String get shiftRateField => 'أجر الوردية';

  @override
  String get contractAmountField => 'مبلغ العقد';

  @override
  String get customAmountField => 'المبلغ المخصص';

  @override
  String get expectedUnitsPerPeriodField => 'الوحدات المتوقعة في الشهر';

  @override
  String get expectedWeeksPerPeriodHelper =>
      'عدد الأسابيع التي تُحتسب عادة في مسير الشهر.';

  @override
  String get expectedDaysPerPeriodHelper =>
      'عدد أيام العمل المتوقع احتسابها في مسير الشهر.';

  @override
  String get expectedHoursPerPeriodHelper =>
      'عدد الساعات المتوقع احتسابها في مسير الشهر.';

  @override
  String get expectedShiftsPerPeriodHelper =>
      'عدد الورديات المتوقع احتسابها في مسير الشهر.';

  @override
  String get compensationNotesField => 'ملاحظات طريقة الدفع';

  @override
  String get compensationNotesHelper =>
      'اختياري، لكنه مفيد للأنواع المخصصة أو العقود.';

  @override
  String get salesCommissionPercentField => 'نسبة عمولة المبيعات';

  @override
  String get salesCommissionPercentHelper =>
      'تُحسب من المبيعات المدفوعة للمستخدم المرتبط بالموظف.';

  @override
  String get baseSalaryRequiredError => 'أدخل مبلغًا أكبر من صفر.';

  @override
  String get expectedUnitsRequiredError => 'أدخل عدد وحدات أكبر من صفر.';

  @override
  String get commissionRequiredError => 'أدخل نسبة عمولة أكبر من صفر.';

  @override
  String get salesCommissionNeedsLinkedUserWarning =>
      'عمولة المبيعات تحتاج ربط الموظف بمستخدم نقطة بيع حتى تُحسب المبيعات تلقائيًا.';

  @override
  String get compensationPlanActivationNote =>
      'ستصبح هذه الخطة هي الراتب الحالي للموظف، وسيتم تعطيل الخطط النشطة السابقة.';

  @override
  String get payTypeMonthlySalary => 'راتب شهري';

  @override
  String get payTypeWeeklySalary => 'راتب أسبوعي';

  @override
  String get payTypeDailyRate => 'أجر يومي';

  @override
  String get payTypeHourly => 'أجر بالساعة';

  @override
  String get payTypePerShift => 'أجر بالوردية';

  @override
  String get payTypeCommission => 'عمولة';

  @override
  String get payTypeContract => 'عقد';

  @override
  String get payTypeOther => 'آخر';

  @override
  String get noEmployeesWithPayPlan =>
      'أضف خطة أجر لموظف واحد على الأقل قبل إنشاء مسير رواتب.';

  @override
  String get payrollEmployeeField => 'الموظف';

  @override
  String get payrollPeriodStartField => 'بداية الفترة';

  @override
  String get payrollPeriodEndField => 'نهاية الفترة';

  @override
  String get payrollStatusDraft => 'مسودة';

  @override
  String get payrollStatusApproved => 'معتمد';

  @override
  String get payrollStatusPaid => 'مدفوع';

  @override
  String get payrollStatusVoid => 'ملغى';

  @override
  String get dashboardPayrollSectionTitle => 'الرواتب';

  @override
  String get dashboardProfitabilitySectionTitle => 'الربحية بعد المصاريف';

  @override
  String get dashboardSalaryExpenseMetric => 'مصروف الرواتب';

  @override
  String get dashboardPayrollPaidMetric => 'الرواتب المدفوعة';

  @override
  String get dashboardPayrollPendingMetric => 'رواتب معتمدة غير مدفوعة';

  @override
  String get dashboardActiveEmployeesMetric => 'موظفون نشطون';

  @override
  String get dashboardRecentPayrollRunsTitle => 'آخر مسيرات الرواتب';

  @override
  String get dashboardPaymentCommissionsMetric => 'عمولات الدفع';

  @override
  String get dashboardNetOperatingProfitMetric => 'صافي الربح التشغيلي';

  @override
  String get dashboardProfitFromSalesMetric => 'ربح المبيعات';

  @override
  String get dashboardNetProfitMetric => 'صافي الربح';

  @override
  String get dashboardAfterExpensesCaption => 'بعد المصاريف';

  @override
  String get dashboardTopProductsByProfitTitle => 'أفضل المنتجات ربحًا';

  @override
  String get dashboardVsPreviousPeriodLabel => 'مقارنة بالفترة السابقة';

  @override
  String get dashboardActionCenterTitle => 'يحتاج انتباهك';

  @override
  String get dashboardAllClearMessage =>
      'كل شيء تحت السيطرة — لا يوجد ما يتطلب تدخلك الآن.';

  @override
  String dashboardAlertOutOfStock(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count منتجات نفدت من المخزون',
      two: 'منتجان نفدا من المخزون',
      one: 'منتج واحد نفد من المخزون',
    );
    return '$_temp0';
  }

  @override
  String dashboardAlertLowStock(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count منتجات تحت حد إعادة الطلب',
      two: 'منتجان تحت حد إعادة الطلب',
      one: 'منتج واحد تحت حد إعادة الطلب',
    );
    return '$_temp0';
  }

  @override
  String dashboardAlertOverduePurchases(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count أوامر شراء متأخرة السداد',
      two: 'أمرا شراء متأخران عن السداد',
      one: 'أمر شراء واحد متأخر السداد',
    );
    return '$_temp0';
  }

  @override
  String dashboardAlertRegisterVariance(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count جلسات درج بفروق نقدية',
      two: 'جلستا درج بفرق نقدي',
      one: 'جلسة درج واحدة بفرق نقدي',
    );
    return '$_temp0';
  }

  @override
  String dashboardAlertDraftPayroll(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count مسيرات رواتب بانتظار الاعتماد',
      two: 'مسيرا رواتب بانتظار الاعتماد',
      one: 'مسير رواتب بانتظار الاعتماد',
    );
    return '$_temp0';
  }

  @override
  String get dashboardAlertPendingPayroll => 'رواتب معتمدة بانتظار تسجيل الدفع';

  @override
  String dashboardAlertPendingLoans(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count طلبات سلف بانتظار قرارك',
      two: 'طلبا سلفة بانتظار قرارك',
      one: 'طلب سلفة واحد بانتظار قرارك',
    );
    return '$_temp0';
  }

  @override
  String dashboardAlertExpiringDiscounts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عروض خصم تنتهي قريبًا',
      two: 'عرضا خصم ينتهيان قريبًا',
      one: 'عرض خصم واحد ينتهي قريبًا',
    );
    return '$_temp0';
  }

  @override
  String dashboardAlertPrintFailures(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count مهام طباعة فشلت',
      two: 'مهمتا طباعة فشلتا',
      one: 'مهمة طباعة واحدة فشلت',
    );
    return '$_temp0';
  }

  @override
  String get integrityMonitorTitle => 'مركز النزاهة';

  @override
  String get integrityMonitorRefreshTooltip => 'تحديث نتائج المراقبة';

  @override
  String get integrityMonitorLoadError => 'تعذر تحميل نتائج المراقبة.';

  @override
  String get integrityMonitorActionError => 'تعذر حفظ الإجراء. حاول مرة أخرى.';

  @override
  String get integrityMonitorAllClearTitle => 'كل شيء سليم';

  @override
  String integrityMonitorAttentionTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count حالات تحتاج مراجعتك',
      two: 'حالتان تحتاجان مراجعتك',
      one: 'حالة واحدة تحتاج مراجعتك',
    );
    return '$_temp0';
  }

  @override
  String get integrityMonitorSubtitle =>
      'محرك المراقبة يعمل بصمت في الخلفية: يتحقق من كل إلغاء وإرجاع وفرق نقدي، ويقارن كل كاشير بزملائه دون أن يشعر أحد.';

  @override
  String get integrityMonitorActiveSection => 'حالات بانتظار قرارك';

  @override
  String get integrityMonitorSettledSection => 'حالات سابقة';

  @override
  String get integrityRiskScoreCaption => 'خطورة';

  @override
  String get integrityFindingWindowLabel => 'فترة الرصد';

  @override
  String get integrityFindingPatternCountLabel => 'عدد الأنماط المرصودة';

  @override
  String get integrityPeerComparisonTitle => 'مقارنة بالزملاء';

  @override
  String get integrityUserRateLabel => 'معدل هذا الكاشير';

  @override
  String get integrityPeerMedianLabel => 'وسيط الزملاء';

  @override
  String get integrityThresholdLabel => 'حد الاشتباه';

  @override
  String get integrityEvidenceTitle => 'الأدلة المرصودة';

  @override
  String get integrityOpenActivityLogButton => 'فتح سجل النشاط للتحقيق';

  @override
  String get integrityNoteFieldLabel => 'ملاحظة القرار';

  @override
  String get integrityNoteFieldHelper =>
      'وثّق ما وجدته بعد المراجعة — تُحفظ في سجل التدقيق.';

  @override
  String get integrityReviewButton => 'تمت المراجعة';

  @override
  String get integrityDismissButton => 'تجاهل كإنذار كاذب';

  @override
  String get integrityReopenButton => 'إعادة فتح الحالة';

  @override
  String get integrityStatusActive => 'بانتظار المراجعة';

  @override
  String get integrityStatusResolved => 'زال تلقائيًا';

  @override
  String get integrityStatusReviewed => 'تمت مراجعتها';

  @override
  String get integrityStatusDismissed => 'تم تجاهلها';

  @override
  String integrityFindingNoteLabel(String user, String note) {
    return 'ملاحظة $user: $note';
  }

  @override
  String dashboardAlertFraudFindings(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count حالات اشتباه تحتاج مراجعتك',
      two: 'حالتا اشتباه تحتاجان مراجعتك',
      one: 'حالة اشتباه واحدة تحتاج مراجعتك',
    );
    return '$_temp0';
  }

  @override
  String get dashboardIntegritySectionTitle => 'النزاهة والمراقبة';

  @override
  String get dashboardIntegrityAllClear =>
      'لا توجد حالات اشتباه نشطة — المراقبة تعمل بصمت.';

  @override
  String get dashboardOpenIntegrityButton => 'فتح مركز النزاهة';

  @override
  String get dashboardBestSellersTitle => 'الأفضل أداءً';

  @override
  String get dashboardOperationsTitle => 'التشغيل اليومي';

  @override
  String dashboardApprovedAwaitingPaymentNote(Object amount) {
    return 'منها $amount رواتب معتمدة لم تُدفع بعد';
  }

  @override
  String get attendanceSettingsSectionTitle => 'الحضور والانصراف (BioTime)';

  @override
  String get attendanceSettingsSectionSubtitle =>
      'ربط جهاز البصمة ZKTeco ومزامنة الحضور تلقائيًا';

  @override
  String get attendanceConnectionSectionTitle => 'الاتصال بخادم BioTime';

  @override
  String get attendanceConnectionSectionSubtitle =>
      'أدخل عنوان خادم BioTime المحلي وبيانات حساب لديه صلاحية قراءة الحضور.';

  @override
  String get attendanceServerUrlLabel => 'عنوان خادم BioTime';

  @override
  String get attendanceServerUrlHint => 'http://192.168.1.50:8081';

  @override
  String get attendanceUsernameLabel => 'اسم المستخدم';

  @override
  String get attendancePasswordLabel => 'كلمة المرور';

  @override
  String get attendancePasswordKeepHint =>
      'اتركها فارغة للإبقاء على كلمة المرور المحفوظة';

  @override
  String get attendanceEnableLabel => 'تفعيل مزامنة الحضور';

  @override
  String get attendanceEnableSubtitle =>
      'عند التفعيل يمكن سحب البصمات وتطبيقها على الرواتب';

  @override
  String get attendanceTestConnectionButton => 'اختبار الاتصال';

  @override
  String get attendanceTestInProgressButton => 'جار الاختبار...';

  @override
  String attendanceTestSuccess(int count) {
    return 'تم الاتصال بنجاح. عدد الموظفين في BioTime: $count';
  }

  @override
  String get attendanceTestFailed =>
      'تعذر الاتصال بخادم BioTime. تحقق من العنوان وبيانات الدخول.';

  @override
  String get attendanceScheduleSectionTitle => 'جدول الدوام الافتراضي';

  @override
  String get attendanceScheduleSectionSubtitle =>
      'يُستخدم لحساب التأخير والغياب والوقت الإضافي لكل الموظفين.';

  @override
  String get attendanceShiftStartLabel => 'بداية الدوام';

  @override
  String get attendanceShiftEndLabel => 'نهاية الدوام';

  @override
  String get attendanceGraceLabel => 'فترة السماح (دقائق)';

  @override
  String get attendanceWorkdaysLabel => 'أيام العمل';

  @override
  String get attendanceSyncNowButton => 'مزامنة الآن';

  @override
  String get attendanceSyncInProgressButton => 'جار المزامنة...';

  @override
  String attendanceSyncSuccess(int punches, int matched) {
    return 'تمت المزامنة: $punches بصمة جديدة، $matched موظف مرتبط';
  }

  @override
  String get attendanceSyncFailed =>
      'فشلت المزامنة مع BioTime. تحقق من الاتصال ثم أعد المحاولة.';

  @override
  String attendanceLastSyncLabel(String date) {
    return 'آخر مزامنة: $date';
  }

  @override
  String get attendanceNeverSynced => 'لم تتم المزامنة بعد';

  @override
  String attendanceCoverageLabel(String from, String to) {
    return 'البيانات المستوردة تغطي من $from إلى $to';
  }

  @override
  String get attendanceCoverageEmpty => 'لم يتم استيراد أي بصمات بعد';

  @override
  String attendanceLastSyncErrorLabel(String error) {
    return 'خطأ آخر مزامنة: $error';
  }

  @override
  String get attendanceMappingSectionTitle => 'ربط الموظفين بجهاز البصمة';

  @override
  String get attendanceMappingSectionSubtitle =>
      'اربط كل موظف برقمه في BioTime. الموظفون الذين يحمل رقمهم نفس رقم الموظف يُربطون تلقائيًا عند المزامنة.';

  @override
  String get attendanceMappingCodeLabel => 'رقم BioTime';

  @override
  String get attendanceMappingEmptyState =>
      'لا يوجد موظفون بعد. أضف الموظفين من شاشة الموظفين أولًا.';

  @override
  String get attendanceTrackedLabel => 'متابعة الحضور';

  @override
  String attendanceUnmatchedTitle(int count) {
    return 'في BioTime بدون ربط ($count)';
  }

  @override
  String get attendanceSaveInProgressButton => 'جار الحفظ...';

  @override
  String get attendanceSettingsSaved => 'تم حفظ إعدادات الحضور.';

  @override
  String get attendanceSettingsSaveError => 'تعذر حفظ إعدادات الحضور.';

  @override
  String get attendanceSettingsLoadError => 'تعذر تحميل إعدادات الحضور.';

  @override
  String get attendanceDisabledNotice =>
      'مزامنة الحضور غير مفعلة. فعّلها من إعدادات المتجر ← الحضور والانصراف.';

  @override
  String get attendanceTabLabel => 'الحضور';

  @override
  String get attendanceSelectEmployeeLabel => 'الموظف';

  @override
  String get attendanceSelectEmployeeHint => 'اختر موظفًا لعرض حضوره';

  @override
  String get attendanceMonthLabel => 'الشهر';

  @override
  String get attendanceSummaryExpectedLabel => 'أيام العمل';

  @override
  String get attendanceSummaryPresentLabel => 'أيام الحضور';

  @override
  String get attendanceSummaryAbsentLabel => 'أيام الغياب';

  @override
  String get attendanceSummaryLateLabel => 'دقائق التأخير';

  @override
  String get attendanceSummaryOvertimeLabel => 'دقائق إضافية';

  @override
  String get attendanceStatusPresent => 'حاضر';

  @override
  String get attendanceStatusLate => 'متأخر';

  @override
  String get attendanceStatusPartial => 'بصمة ناقصة';

  @override
  String get attendanceStatusDayOff => 'يوم راحة';

  @override
  String get attendanceNoDaysMessage => 'لا توجد سجلات حضور في هذه الفترة.';

  @override
  String attendanceMonthOutsideDataMessage(String from, String to) {
    return 'هذا الشهر خارج نطاق البيانات المستوردة ($from — $to).';
  }

  @override
  String get attendanceJumpToLatestDataButton => 'انتقل إلى آخر شهر به بيانات';

  @override
  String attendanceSyncRunningProgress(int count) {
    return 'جارٍ الاستيراد… $count بصمة حتى الآن';
  }

  @override
  String get attendanceSyncRunningStarting =>
      'جارٍ الاستيراد… قد يستغرق عدة دقائق';

  @override
  String attendanceApplyMissingWarning(int count) {
    return 'تحذير: $count موظف بلا أي بصمات في هذه الفترة، وتم احتسابهم غائبين بالكامل. تحقق من ربطهم بجهاز البصمة قبل الاعتماد.';
  }

  @override
  String get attendanceLoadError => 'تعذر تحميل سجلات الحضور.';

  @override
  String attendanceDayMetrics(String worked, int late, int overtime) {
    return 'عمل $worked • تأخير $late د • إضافي $overtime د';
  }

  @override
  String attendanceDayTimes(String firstIn, String lastOut) {
    return '$firstIn → $lastOut';
  }

  @override
  String get attendanceApplyToPayrollButton => 'تطبيق الحضور على الرواتب';

  @override
  String get attendanceApplyInProgressButton => 'جار التطبيق...';

  @override
  String get attendanceApplyCardTitle => 'احتساب الحضور من BioTime';

  @override
  String get attendanceApplyCardSubtitle =>
      'يحدّث أيام الغياب والوقت الإضافي لكل موظف مرتبط بجهاز البصمة قبل اعتماد المسير. يمكنك تعديل القيم يدويًا بعد ذلك.';

  @override
  String get attendanceApplySuccess =>
      'تم تحديث الغياب والوقت الإضافي من سجلات الحضور.';

  @override
  String get attendanceApplyFailed => 'تعذر تطبيق الحضور على مسير الرواتب.';

  @override
  String get weekdayMonday => 'الاثنين';

  @override
  String get weekdayTuesday => 'الثلاثاء';

  @override
  String get weekdayWednesday => 'الأربعاء';

  @override
  String get weekdayThursday => 'الخميس';

  @override
  String get weekdayFriday => 'الجمعة';

  @override
  String get weekdaySaturday => 'السبت';

  @override
  String get weekdaySunday => 'الأحد';

  @override
  String get expensesTitle => 'المصروفات';

  @override
  String get expensesDrawerLabel => 'المصروفات';

  @override
  String get expensesRefreshTooltip => 'تحديث';

  @override
  String get expenseAddButton => 'إضافة مصروف';

  @override
  String get expensesLoadError => 'تعذّر تحميل المصروفات.';

  @override
  String get expensesEmptyMessage => 'لا توجد مصروفات في هذه الفترة.';

  @override
  String get expensesPreviousMonth => 'الشهر السابق';

  @override
  String get expensesNextMonth => 'الشهر التالي';

  @override
  String expensesPeriodTotal(Object total) {
    return 'الإجمالي: $total';
  }

  @override
  String get expenseSourceAdHoc => 'مصروف';

  @override
  String get expenseSourceRegisterPayout => 'سحب نقدي';

  @override
  String get expenseSourcePurchase => 'مشتريات';

  @override
  String get expenseSourcePayroll => 'رواتب';

  @override
  String get expenseSourceCommission => 'عمولات';

  @override
  String get expenseSourceOther => 'أخرى';

  @override
  String get expensePaymentCash => 'نقدًا';

  @override
  String get expensePaymentCard => 'بطاقة';

  @override
  String get expensePaymentTransfer => 'تحويل';

  @override
  String get expenseLoadDetailsError => 'تعذّر تحميل تفاصيل المصروف.';

  @override
  String get expenseNeedsCategoryMessage =>
      'أضِف فئة واحدة على الأقل قبل تسجيل مصروف.';

  @override
  String get expenseSaveError => 'تعذّر حفظ المصروف.';

  @override
  String get expenseCancelTitle => 'إلغاء المصروف؟';

  @override
  String get expenseCancelMessage =>
      'يبقى المصروف في السجل مع سبب الإلغاء، وإذا كان مدفوعًا من الدرج تعود قيمته إلى الدرج المفتوح.';

  @override
  String get expenseCancelReasonLabel => 'سبب الإلغاء (اختياري)';

  @override
  String get expenseCancelConfirm => 'إلغاء المصروف';

  @override
  String get expenseCancelError => 'تعذّر إلغاء المصروف.';

  @override
  String get expenseEditTitle => 'تعديل المصروف';

  @override
  String get expenseCategoryLabel => 'الفئة';

  @override
  String get expenseDescriptionLabel => 'الوصف';

  @override
  String get expenseAmountLabel => 'المبلغ';

  @override
  String get expensePaymentMethodLabel => 'طريقة الدفع';

  @override
  String get expenseDateLabel => 'التاريخ';

  @override
  String get expenseReferenceLabel => 'مرجع (اختياري)';

  @override
  String get expenseNotesLabel => 'ملاحظات (اختياري)';

  @override
  String get expensePayFromRegisterLabel => 'الدفع من الصندوق';

  @override
  String get expensePayFromRegisterHint =>
      'يُسجَّل سحبًا نقديًا من الوردية المفتوحة إن وُجدت.';

  @override
  String get expenseCategoriesSectionTitle => 'فئات المصروفات';

  @override
  String get expenseCategoryAddButton => 'إضافة فئة';

  @override
  String get expenseCategoriesLoadError => 'تعذّر تحميل الفئات.';

  @override
  String get expenseCategoriesEmptyMessage => 'لا توجد فئات بعد.';

  @override
  String get expenseCategorySaveError => 'تعذّر حفظ الفئة.';

  @override
  String get expenseCategoryDeleteTitle => 'حذف الفئة؟';

  @override
  String get expenseCategoryDeleteMessage => 'لا يمكن حذف فئة مرتبطة بمصروفات.';

  @override
  String get expenseCategoryDeleteError => 'تعذّر حذف الفئة.';

  @override
  String get expenseCategoryInactiveBadge => 'غير مفعّلة';

  @override
  String get expenseCategoryNameLabel => 'اسم الفئة';

  @override
  String get expenseCategoryActiveLabel => 'مفعّلة';

  @override
  String get dashboardAdHocExpensesMetric => 'مصاريف عامة';

  @override
  String get jobAssignmentSection => 'الإسناد';

  @override
  String get jobAssignedEmployeeHint =>
      'الموظف الذي تُحتسب له عمولة العمل على هذه المهمة.';

  @override
  String get jobAssignButton => 'إسناد';

  @override
  String get jobReassignButton => 'تغيير';

  @override
  String get jobAssignLoadError => 'تعذّر تحميل قائمة الموظفين.';

  @override
  String get jobAssignedMessage => 'تم تحديث الإسناد.';

  @override
  String get jobAssignSelectTitle => 'اختر الموظف';

  @override
  String get jobAssignNoEmployees => 'لا يوجد موظفون نشطون.';

  @override
  String get jobUnassignOption => 'إلغاء الإسناد';

  @override
  String get salaryTypeOperationsCommissionOnly => 'عمولة على الأعمال فقط';

  @override
  String get salaryTypeOperationsCommissionOnlyHelper =>
      'تُحتسب نسبة على قيمة الأعمال (مثل الإصلاحات) التي أنجزها الموظف، بدون راتب ثابت.';

  @override
  String get salaryTypeMonthlyFixedPlusOperationsCommission =>
      'راتب شهري + عمولة على الأعمال';

  @override
  String get salaryTypeMonthlyFixedPlusOperationsCommissionHelper =>
      'راتب شهري ثابت بالإضافة إلى نسبة على قيمة الأعمال التي أنجزها الموظف.';

  @override
  String get operationsCommissionPercentField => 'نسبة العمولة على الأعمال';

  @override
  String get operationsCommissionPercentHelper =>
      'نسبة مئوية من قيمة الأعمال المنجزة (السعر المعتمد) تُضاف إلى المسير.';

  @override
  String get operationsCommissionBaseField => 'أساس احتساب العمولة';

  @override
  String get operationsCommissionBaseApprovedPrice =>
      'السعر المعتمد (قطع + أجور)';

  @override
  String get operationsCommissionBaseApprovedPriceHelper =>
      'تُحتسب العمولة على كامل السعر المعتمد للمهمة.';

  @override
  String get operationsCommissionBaseLabor => 'الأجور فقط';

  @override
  String get operationsCommissionBaseLaborHelper =>
      'تُحتسب العمولة على السعر المعتمد بعد خصم قيمة القطع المستهلكة.';

  @override
  String get operationsCommissionBaseOrderTotal => 'إجمالي الفاتورة';

  @override
  String get operationsCommissionBaseOrderTotalHelper =>
      'تُحتسب العمولة على إجمالي فاتورة المهمة (للمهام التي صدرت لها فاتورة).';

  @override
  String get stockCountDrawerLabel => 'جرد المخزون';

  @override
  String get stockCountSessionsTitle => 'عمليات الجرد';

  @override
  String get stockCountRefreshTooltip => 'تحديث عمليات الجرد';

  @override
  String get stockCountCountingTitle => 'الجرد';

  @override
  String get stockCountReconciliationTitle => 'مراجعة الفروقات';

  @override
  String get stockCountStartNew => 'بدء جرد جديد';

  @override
  String get stockCountResume => 'متابعة الجرد الحالي';

  @override
  String get stockCountStartTitle => 'جرد جديد';

  @override
  String get stockCountScopeLabel => 'نطاق الجرد';

  @override
  String get stockCountScopeFull => 'كل المنتجات';

  @override
  String get stockCountScopeCategory => 'تصنيف محدد';

  @override
  String get stockCountSelectCategory => 'اختر التصنيف';

  @override
  String get stockCountSelectCategoryError => 'اختر تصنيفًا للمتابعة.';

  @override
  String get stockCountNoteLabel => 'ملاحظة (اختياري)';

  @override
  String get stockCountStartButton => 'بدء الجرد';

  @override
  String get stockCountStartError => 'تعذّر بدء الجرد. حاول مرة أخرى.';

  @override
  String stockCountProgress(int counted, int total) {
    return '$counted من $total';
  }

  @override
  String get stockCountScanPrompt => 'امسح باركود الصنف للبدء';

  @override
  String get stockCountScanHint => 'امسح، أو ابحث، أو تصفّح المنتجات';

  @override
  String get stockCountCountLabel => 'الكمية المعدودة';

  @override
  String get stockCountSaveAndNext => 'حفظ والتالي';

  @override
  String get stockCountSearchItem => 'بحث عن صنف';

  @override
  String get stockCountSearchHint => 'ابحث بالاسم أو الرمز';

  @override
  String get stockCountBrowse => 'تصفّح المنتجات';

  @override
  String get stockCountScanMiss => 'لم يتم العثور على صنف بهذا الباركود.';

  @override
  String get stockCountSaveError => 'تعذّر حفظ العدّة. حاول مرة أخرى.';

  @override
  String get stockCountFinishButton => 'إنهاء ومراجعة';

  @override
  String get stockCountSearchEmpty => 'لا توجد أصناف مطابقة.';

  @override
  String stockCountItemUnit(String unit) {
    return 'الوحدة: $unit';
  }

  @override
  String get stockCountReentryTitle => 'الصنف معدود مسبقًا';

  @override
  String stockCountReentryBody(String current) {
    return 'لديك عدّة حالية $current لهذا الصنف.';
  }

  @override
  String get stockCountReentryAdd => 'أضف إلى العدّة';

  @override
  String get stockCountReentryReplace => 'استبدل العدّة';

  @override
  String get stockCountVarianceTitle => 'تحقّق من العدّة';

  @override
  String stockCountVarianceBody(String expected, String counted) {
    return 'النظام يُسجّل $expected، وأنت أدخلت $counted.';
  }

  @override
  String get stockCountRecount => 'إعادة العدّ';

  @override
  String get stockCountConfirm => 'تأكيد';

  @override
  String stockCountMismatchCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count أصناف لا تطابق',
      two: 'صنفان لا يطابقان',
      one: 'صنف واحد لا يطابق',
      zero: 'لا توجد فروقات',
    );
    return '$_temp0';
  }

  @override
  String get stockCountColumnExpected => 'النظام';

  @override
  String get stockCountColumnCounted => 'المعدود';

  @override
  String get stockCountColumnGap => 'الفرق';

  @override
  String get stockCountApply => 'تطبيق التعديلات';

  @override
  String get stockCountApplyConfirmTitle => 'تطبيق الجرد؟';

  @override
  String get stockCountApplyConfirmBody =>
      'سيتم تعديل المخزون بمقدار الفروقات المعدودة. لا يمكن التراجع عن هذا الإجراء.';

  @override
  String get stockCountApplyConfirm => 'تطبيق';

  @override
  String get stockCountApplied => 'تم تطبيق الجرد';

  @override
  String get stockCountApplyError => 'تعذّر تطبيق الجرد. حاول مرة أخرى.';

  @override
  String get stockCountApplyManagerOnly => 'تطبيق التعديلات متاح للمدير فقط.';

  @override
  String get stockCountNoVariances => 'لا توجد فروقات. المخزون مطابق للمعدود.';

  @override
  String get stockCountCancel => 'إلغاء الجرد';

  @override
  String get stockCountCancelConfirmTitle => 'إلغاء الجرد؟';

  @override
  String get stockCountCancelConfirmBody =>
      'سيتم تجاهل كل ما تم عدّه في هذه الجلسة.';

  @override
  String get stockCountCancelConfirm => 'إلغاء الجرد';

  @override
  String get stockCountEmpty => 'لا توجد عمليات جرد بعد.';

  @override
  String get stockCountLoadError => 'تعذّر تحميل عمليات الجرد.';

  @override
  String get stockCountReconciliationLoadError => 'تعذّر تحميل فروقات الجرد.';

  @override
  String get stockCountApplyBlockedByLoadError =>
      'لا يمكن إنهاء الجرد قبل تحميل الفروقات. أعد المحاولة أولاً.';

  @override
  String get stockCountHistoryTitle => 'سجل عمليات الجرد';

  @override
  String get stockCountStatusInProgress => 'قيد التنفيذ';

  @override
  String get stockCountStatusApplied => 'مطبّق';

  @override
  String get stockCountStatusCancelled => 'ملغى';

  @override
  String stockCountScopeCategoryLabel(String category) {
    return 'تصنيف: $category';
  }

  @override
  String stockCountOfTotal(int total) {
    return 'من $total';
  }

  @override
  String stockCountRemaining(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'بقي $count',
      two: 'بقي صنفان',
      one: 'بقي صنف واحد',
      zero: 'اكتمل العدّ',
    );
    return '$_temp0';
  }

  @override
  String get stockCountActiveTitle => 'جرد قيد التنفيذ';

  @override
  String get stockCountCameraScan => 'المسح بالكاميرا';

  @override
  String get stockCountYourCount => 'عدّتك';

  @override
  String get stockCountReentryCurrentLabel => 'العدّة الحالية';

  @override
  String get stockCountReentryQuestion =>
      'هل تضيف الكمية الجديدة إلى عدّتك أم تستبدلها؟';

  @override
  String get stockCountStartHeroTitle => 'ابدأ جردًا جديدًا';

  @override
  String get stockCountStartHeroBody =>
      'عُدّ مخزونك الفعلي وقارنه بالنظام لرصد الفروقات وتصحيحها.';

  @override
  String get stockCountHistoryEmptyHint => 'ستظهر عمليات الجرد السابقة هنا.';

  @override
  String get stockCountMatched => 'مطابق';

  @override
  String get stockCountAllMatched => 'كل شيء مطابق';

  @override
  String get stockCountFinishCount => 'إنهاء الجرد';

  @override
  String get stockCountShortage => 'نقص';

  @override
  String get stockCountSurplus => 'زيادة';

  @override
  String stockCountApplySummary(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'سيتم تعديل $count أصناف',
      two: 'سيتم تعديل صنفين',
      one: 'سيتم تعديل صنف واحد',
    );
    return '$_temp0';
  }

  @override
  String stockCountVarianceShort(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count فروق',
      two: 'فرقان',
      one: 'فرق واحد',
    );
    return '$_temp0';
  }

  @override
  String get priceCheckersSectionTitle => 'أجهزة فحص الأسعار';

  @override
  String get priceCheckersSectionSubtitle =>
      'متابعة أجهزة فحص الأسعار المتصلة في المتجر وحالتها';

  @override
  String get priceCheckersHeroDescription =>
      'نظرة سريعة على كل جهاز متصل وآخر نشاط له.';

  @override
  String get priceCheckerDevicesUnit => 'جهاز فحص أسعار';

  @override
  String priceCheckerServingPillLabel(int count) {
    return '$count قيد الخدمة';
  }

  @override
  String priceCheckerDiscoveredPillLabel(int count) {
    return '$count بانتظار التفعيل';
  }

  @override
  String get priceCheckerScanTooltip => 'البحث عن أجهزة في الشبكة';

  @override
  String get priceCheckerScanButton => 'بحث في الشبكة';

  @override
  String get priceCheckerRefreshTooltip => 'تحديث';

  @override
  String get priceCheckerDevicesListTitle => 'الأجهزة';

  @override
  String priceCheckerDevicesCountSubtitle(int count) {
    return '$count جهاز';
  }

  @override
  String get priceCheckersEmptyTitle => 'لا توجد أجهزة بعد';

  @override
  String get priceCheckersEmptyMessage =>
      'ابحث في الشبكة المحلية للعثور على أجهزة فحص الأسعار وتسجيلها تلقائيًا.';

  @override
  String get priceCheckersLoadError => 'تعذر تحميل أجهزة فحص الأسعار';

  @override
  String priceCheckerScanSuccess(int found, int registered) {
    return 'تم العثور على $found جهاز، وسُجِّل منها $registered.';
  }

  @override
  String get priceCheckerScanNone => 'لم يُعثر على أجهزة جديدة في الشبكة.';

  @override
  String get priceCheckerScanError =>
      'تعذر إجراء البحث في الشبكة. حاول مرة أخرى.';

  @override
  String priceCheckerLastSeen(String value) {
    return 'آخر نشاط: $value';
  }

  @override
  String get priceCheckerNeverSeen => 'لم يُسجَّل نشاط بعد';

  @override
  String get priceCheckerStatusActive => 'نشِط';

  @override
  String get priceCheckerStatusDiscovered => 'مكتشَف';

  @override
  String get priceCheckerStatusDisabled => 'مُعطّل';

  @override
  String get priceCheckerDiscoveryManual => 'إضافة يدوية';

  @override
  String get priceCheckerDiscoveryScan => 'فحص الشبكة';

  @override
  String get priceCheckerDiscoverySelf => 'تسجيل ذاتي';

  @override
  String get priceCheckerArabicNone => 'غير مدعوم (لاتيني)';

  @override
  String get priceCheckerArabicUnicode => 'يونيكود (الجهاز يُشكّل)';

  @override
  String get priceCheckerArabicCp1256 => 'CP1256 (الخادم يعيد الترتيب)';

  @override
  String get priceCheckerArabicGlyphs => 'محارف مُشكّلة مسبقًا';

  @override
  String get priceCheckResultFound => 'موجود';

  @override
  String get priceCheckResultNotFound => 'غير موجود';

  @override
  String get priceCheckResultError => 'خطأ';

  @override
  String get priceCheckerConnectionServing =>
      'هذا الجهاز قيد الخدمة ويستقبل عمليات الفحص';

  @override
  String get priceCheckerConnectionDiscovered =>
      'تم اكتشاف هذا الجهاز وهو بانتظار التفعيل';

  @override
  String get priceCheckerConnectionDisabled =>
      'هذا الجهاز مُعطّل ولا يستجيب لعمليات الفحص';

  @override
  String get priceCheckerNetworkSection => 'الشبكة';

  @override
  String get priceCheckerFieldIdentifier => 'المعرّف';

  @override
  String get priceCheckerFieldTransport => 'البروتوكول';

  @override
  String get priceCheckerFieldAddress => 'العنوان';

  @override
  String get priceCheckerFieldMac => 'عنوان MAC';

  @override
  String get priceCheckerFieldDriver => 'المشغّل';

  @override
  String get priceCheckerFieldHardware => 'الطراز';

  @override
  String get priceCheckerFieldDiscovery => 'طريقة الاكتشاف';

  @override
  String get priceCheckerFieldLocation => 'الموقع';

  @override
  String get priceCheckerDisplaySection => 'الشاشة';

  @override
  String get priceCheckerFieldDisplaySize => 'أبعاد الشاشة';

  @override
  String priceCheckerDisplaySizeValue(int rows, int cols) {
    return '$rows × $cols';
  }

  @override
  String get priceCheckerFieldArabic => 'دعم العربية';

  @override
  String get priceCheckerFieldEncoding => 'الترميز';

  @override
  String get priceCheckerActivitySection => 'أحدث عمليات الفحص';

  @override
  String get priceCheckerActivityLoadError => 'تعذر تحميل عمليات الفحص';

  @override
  String get priceCheckerActivityEmpty => 'لا توجد عمليات فحص بعد لهذا الجهاز.';

  @override
  String get priceCheckerScanPrompt => 'امسح الباركود لعرض السعر';

  @override
  String get priceCheckerLoading => 'جارٍ البحث…';

  @override
  String get priceCheckerScanAnother => 'امسح منتجًا آخر';

  @override
  String get priceCheckerNotFoundTitle => 'المنتج غير موجود';

  @override
  String get priceCheckerNotFoundBody => 'تحقّق من الباركود وحاول مرة أخرى';

  @override
  String priceCheckerScannedCode(String barcode) {
    return 'الباركود: $barcode';
  }

  @override
  String get priceCheckerDisconnectedTitle => 'غير متصل بالخادم';

  @override
  String get priceCheckerDisconnectedBody => 'جارٍ إعادة المحاولة…';

  @override
  String get priceCheckerInStock => 'متوفّر';

  @override
  String get priceCheckerOutOfStock => 'غير متوفّر';

  @override
  String priceCheckerSavePercent(String value) {
    return 'وفّر $value٪';
  }

  @override
  String priceCheckerSaveAmount(String value) {
    return 'وفّر $value';
  }

  @override
  String get priceCheckerManualEntry => 'إدخال يدوي';

  @override
  String get priceCheckerManualEntryTitle => 'أدخل الباركود';

  @override
  String get priceCheckerCameraScanPrompt =>
      'قرّب الباركود من الكاميرا لعرض السعر';

  @override
  String get priceCheckerCameraStarting => 'جارٍ تشغيل الكاميرا…';

  @override
  String get priceCheckerCameraUnavailable => 'الكاميرا غير متاحة';

  @override
  String get priceCheckerExitTooltip => 'الخروج من وضع كاشف الأسعار';

  @override
  String get priceCheckerExitTitle => 'الخروج من وضع كاشف الأسعار';

  @override
  String get priceCheckerExitSubtitle => 'أدخل الرمز السري للخروج';

  @override
  String get priceCheckerWrongPin => 'رمز غير صحيح، حاول مرة أخرى';

  @override
  String get priceCheckerModeButton => 'وضع كاشف الأسعار';

  @override
  String get priceCheckerSetupTitle => 'إعداد وضع كاشف الأسعار';

  @override
  String get priceCheckerSetupSubtitle =>
      'سيعرض هذا الجهاز الأسعار للزبائن عند مسح الباركود. اختر رمزًا سريًا للخروج من هذا الوضع لاحقًا.';

  @override
  String get priceCheckerDeviceNameLabel => 'اسم الجهاز';

  @override
  String get priceCheckerDeviceNameHint => 'مثال: كاشف الأسعار - الممر 3';

  @override
  String get priceCheckerLocationLabel => 'الموقع';

  @override
  String get priceCheckerPinLabel => 'الرمز السري';

  @override
  String get priceCheckerPinHint => 'من 4 إلى 6 أرقام';

  @override
  String get priceCheckerConfirmPinLabel => 'تأكيد الرمز السري';

  @override
  String get priceCheckerPinTooShort =>
      'يجب أن يتكوّن الرمز من 4 أرقام على الأقل';

  @override
  String get priceCheckerPinMismatch => 'الرمزان غير متطابقين';

  @override
  String get priceCheckerRunOnStartupLabel => 'التشغيل تلقائيًا عند بدء النظام';

  @override
  String get priceCheckerRunOnStartupHint =>
      'يفتح التطبيق تلقائيًا عند تشغيل الجهاز';

  @override
  String get priceCheckerStartButton => 'بدء الوضع';

  @override
  String get priceCheckerModeButtonTooltip =>
      'تشغيل وضع كاشف الأسعار على هذا الجهاز';

  @override
  String get priceCheckerSettingsTitle => 'وضع كاشف الأسعار';

  @override
  String get priceCheckerSettingsDescription =>
      'حوّل هذا الجهاز إلى شاشة لعرض الأسعار للزبائن. يعمل دون تسجيل دخول، ويُحمى الخروج منه برمز سري.';

  @override
  String get priceCheckerSettingsSetupButton => 'إعداد كاشف الأسعار';

  @override
  String get priceCheckerConfiguredStatus => 'هذا الجهاز مُعدّ ككاشف أسعار';

  @override
  String get priceCheckerNoNameSet => 'بدون اسم';

  @override
  String get priceCheckerEnterModeButton => 'الدخول إلى الوضع';

  @override
  String get priceCheckerChangePinButton => 'تغيير الرمز السري';

  @override
  String get priceCheckerEditDetailsButton => 'تعديل البيانات';

  @override
  String get priceCheckerRemoveButton => 'إيقاف الوضع';

  @override
  String get priceCheckerScanSettingsTitle => 'إعدادات المسح';

  @override
  String get priceCheckerCameraToggleLabel => 'المسح بالكاميرا';

  @override
  String get priceCheckerCameraToggleHint =>
      'قراءة الباركود بكاميرا الجهاز دون الحاجة إلى ماسح خارجي';

  @override
  String get priceCheckerCameraFacingLabel => 'الكاميرا المستخدمة';

  @override
  String get priceCheckerCameraFront => 'الأمامية';

  @override
  String get priceCheckerCameraBack => 'الخلفية';

  @override
  String get editCustomerTitle => 'تعديل بيانات الزبون';

  @override
  String get editSupplierTitle => 'تعديل بيانات المورد';

  @override
  String get editContactTooltip => 'تعديل البيانات';

  @override
  String get customerUpdateError =>
      'تعذر حفظ بيانات الزبون. تحقق من الاتصال وحاول مجددًا.';

  @override
  String get supplierUpdateError =>
      'تعذر حفظ بيانات المورد. تحقق من الاتصال وحاول مجددًا.';

  @override
  String get customerUpdatedMessage => 'تم حفظ بيانات الزبون.';

  @override
  String get supplierUpdatedMessage => 'تم حفظ بيانات المورد.';

  @override
  String get supplierProfileTitle => 'بيانات المورد';

  @override
  String get priceCheckerTorchToggleLabel => 'تشغيل الفلاش أثناء المسح';

  @override
  String get priceCheckerTorchToggleHint =>
      'يحسّن قراءة الباركود في الإضاءة الضعيفة (يعمل مع الكاميرا الخلفية فقط)';

  @override
  String get priceCheckerTorchTooltip => 'الفلاش';

  @override
  String get priceCheckerSpeakToggleLabel => 'نطق اسم المنتج والسعر';

  @override
  String get priceCheckerSpeakToggleHint =>
      'يقرأ الجهاز اسم المنتج وسعره بصوت مسموع عند العثور عليه';

  @override
  String priceCheckerSpokenResult(String product, String price) {
    return '$product، السعر $price دينار';
  }

  @override
  String get priceCheckerDwellLabel => 'مدة عرض المنتج';

  @override
  String get priceCheckerDwellHint =>
      'المدة قبل العودة تلقائيًا إلى شاشة المسح';

  @override
  String priceCheckerDwellSecondsValue(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: '$seconds ثانية',
      many: '$seconds ثانية',
      few: '$seconds ثوانٍ',
      two: 'ثانيتان',
      one: 'ثانية واحدة',
    );
    return '$_temp0';
  }

  @override
  String get priceCheckerRemoveConfirmTitle => 'إيقاف وضع كاشف الأسعار؟';

  @override
  String get priceCheckerRemoveConfirmMessage =>
      'سيعود هذا الجهاز جهازًا عاديًا لنقطة البيع. يمكنك إعداده مجددًا في أي وقت.';

  @override
  String get priceCheckerChangePinTitle => 'تغيير الرمز السري';

  @override
  String get startupSectionTitle => 'بدء التشغيل';

  @override
  String get startupSectionSubtitle =>
      'اجعل التطبيق يفتح تلقائيًا عند تشغيل الجهاز — مفيد لأجهزة الكاشير والكاشف.';

  @override
  String get clearCartConfirmTitle => 'مسح السلة؟';

  @override
  String get clearCartConfirmMessage =>
      'سيؤدي هذا إلى إزالة جميع العناصر من السلة الحالية، ولا يمكن التراجع عنه.';

  @override
  String get discardSaleConfirmTitle => 'تجاهل البيع المُعلّق؟';

  @override
  String get discardSaleConfirmMessage =>
      'سيتم حذف هذا البيع المُعلّق وجميع عناصره، ولا يمكن التراجع عنه.';

  @override
  String get discardSaleConfirmButton => 'تجاهل';

  @override
  String get cartLineRemovedMessage => 'تم حذف العنصر';

  @override
  String get undoButton => 'تراجع';

  @override
  String get clearPurchaseDraftConfirmTitle => 'مسح مسودة الشراء؟';

  @override
  String get clearPurchaseDraftConfirmMessage =>
      'سيؤدي هذا إلى إزالة جميع العناصر من المسودة الحالية، ولا يمكن التراجع عنه.';

  @override
  String get submitPurchaseOrderConfirmTitle => 'إرسال أمر الشراء؟';

  @override
  String get submitPurchaseOrderConfirmMessage =>
      'سيتم إرسال أمر الشراء إلى المورّد للاعتماد.';

  @override
  String get cancelPurchaseOrderConfirmTitle => 'إلغاء أمر الشراء؟';

  @override
  String get cancelPurchaseOrderConfirmMessage =>
      'سيؤدي إلغاء أمر الشراء إلى عكس أي مخزون تم استلامه منه، ولا يمكن التراجع عن هذا الإجراء.';

  @override
  String get cancelPurchaseOrderConfirmButton => 'تأكيد الإلغاء';

  @override
  String get unauthorizedAskManagerHint =>
      'اطلب من المدير منحك صلاحية الوصول إلى هذه الشاشة.';

  @override
  String get backToHomeButton => 'العودة إلى الرئيسية';

  @override
  String get unsavedChangesTitle => 'تجاهل التغييرات؟';

  @override
  String get unsavedChangesMessage =>
      'لديك تغييرات لم تُحفظ بعد. ستُفقد إذا غادرت الآن.';

  @override
  String get discardChangesButton => 'تجاهل التغييرات';

  @override
  String get keepEditingButton => 'متابعة التعديل';

  @override
  String get dashboardGetStartedTitle => 'لنبدأ';

  @override
  String get dashboardGetStartedSubtitle =>
      'أكمل هذه الخطوات لتجهيز متجرك للعمل.';

  @override
  String get dashboardGetStartedAddProduct => 'أضف أول منتج';

  @override
  String get dashboardGetStartedAddCustomer => 'أضف أول عميل';

  @override
  String get dashboardGetStartedFirstSale => 'سجّل أول عملية بيع';

  @override
  String get dashboardGetStartedDone => 'تم';

  @override
  String get posCartRestoredMessage => 'تمت استعادة سلة بيع غير مكتملة';

  @override
  String get purchaseDraftRestoredMessage => 'تمت استعادة مسودة شراء محفوظة';

  @override
  String get aiAssistantDrawerLabel => 'GPT';

  @override
  String get aiAssistantTitle => 'GPT';

  @override
  String get aiAssistantInputHint => 'اكتب رسالتك هنا…';

  @override
  String get aiAssistantDisclaimer => 'GPT قد يخطئ. تحقّق من المعلومات المهمة.';

  @override
  String get aiAssistantSendTooltip => 'إرسال';

  @override
  String get aiAssistantNewChat => 'محادثة جديدة';

  @override
  String get aiAssistantHistoryTitle => 'المحادثات السابقة';

  @override
  String get aiAssistantHistoryEmpty => 'لا توجد محادثات بعد';

  @override
  String get aiAssistantDeleteConversation => 'حذف المحادثة';

  @override
  String get aiAssistantEmptyTitle => 'كيف يمكنني مساعدتك؟';

  @override
  String get aiAssistantEmptySubtitle => 'اسأل GPT عن أي شيء يخص متجرك.';

  @override
  String get aiAssistantThinking => 'يكتب…';

  @override
  String get aiAssistantThinkingLabel => 'طريقة التفكير';

  @override
  String get aiAssistantSuggestion1 => 'اكتب رسالة ترحيب لعملاء متجري';

  @override
  String get aiAssistantSuggestion2 => 'اقترح أفكارًا لعرض ترويجي لهذا الأسبوع';

  @override
  String get aiAssistantSuggestion3 => 'اكتب وصفًا جذابًا لمنتج جديد';

  @override
  String get aiAssistantErrorNotEntitled => 'GPT غير مفعّل لهذا المتجر.';

  @override
  String get aiAssistantErrorNetwork =>
      'تعذّر الاتصال بـ GPT. تحقق من الشبكة وحاول مجددًا.';

  @override
  String get aiAssistantErrorGeneric =>
      'حدث خطأ أثناء معالجة طلبك. حاول مرة أخرى.';

  @override
  String get aiAssistantErrorRateLimited =>
      'لقد بلغت حدّ الاستخدام. حاول مرة أخرى لاحقًا.';

  @override
  String get aiAssistantErrorTooManyImages =>
      'عدد الصور كبير جدًا. الحد الأقصى ٥ صور.';

  @override
  String get aiAssistantAttachTooltip => 'إرفاق';

  @override
  String get aiAssistantAttachImage => 'صورة من المعرض';

  @override
  String get aiAssistantAttachCamera => 'التقاط صورة';

  @override
  String get aiAssistantAttachFile => 'ملف';

  @override
  String get aiAssistantRemoveAttachment => 'إزالة المرفق';

  @override
  String get aiAssistantAttachmentImage => 'صورة';

  @override
  String get aiAssistantRecordTooltip => 'تسجيل رسالة صوتية';

  @override
  String get aiAssistantRecordCancelTooltip => 'إلغاء التسجيل';

  @override
  String get aiAssistantVoiceMessage => 'رسالة صوتية';

  @override
  String get aiAssistantRecording => 'جارٍ التسجيل…';

  @override
  String get aiAssistantMicPermissionDenied =>
      'يلزم إذن الميكروفون لتسجيل الرسائل الصوتية. فعّله من إعدادات الجهاز.';

  @override
  String aiAssistantImageLimit(int count) {
    return 'يمكنك إرفاق $count صور كحد أقصى';
  }

  @override
  String get aiAssistantUsageTitle => 'حدود الاستخدام';

  @override
  String get aiAssistantUsageFiveHour => 'آخر ٥ ساعات';

  @override
  String get aiAssistantUsageWeekly => 'هذا الأسبوع';

  @override
  String get aiAssistantUsageUnlimited => 'غير محدود';

  @override
  String aiAssistantUsageRemaining(int count) {
    return 'متبقٍ $count';
  }

  @override
  String aiAssistantUsageUsedOfLimit(int used, int limit) {
    return '$used من $limit';
  }

  @override
  String aiAssistantUsageResets(String time) {
    return 'يتجدد $time';
  }

  @override
  String get aiAssistantActionEdit => 'تعديل الرسالة';

  @override
  String get aiAssistantActionRetry => 'إعادة المحاولة';

  @override
  String get aiAssistantActionCopy => 'نسخ';

  @override
  String get aiAssistantCopied => 'تم نسخ الرد';

  @override
  String aiAssistantToolQuerying(String label) {
    return 'يستعلم عن $label';
  }

  @override
  String get aiAssistantToolWorking => 'يجمع البيانات';

  @override
  String get aiAssistantToolDetailsTitle => 'تفاصيل الأداة';

  @override
  String get aiAssistantToolInputs => 'المدخلات';

  @override
  String get aiAssistantToolResult => 'النتيجة';

  @override
  String get aiAssistantToolNoOutput => 'لا توجد نتيجة';

  @override
  String get aiAssistantToolStatusOk => 'نجحت';

  @override
  String get aiAssistantToolStatusFailed => 'فشلت';

  @override
  String get aiAssistantAskUserSubmit => 'إرسال الإجابة';

  @override
  String get aiAssistantAskUserSkip => 'تخطّي';

  @override
  String get aiAssistantAskUserOther => 'أخرى…';

  @override
  String get aiAssistantAskUserOtherHint => 'اكتب إجابتك هنا';

  @override
  String get aiAssistantAskUserTextHint => 'اكتب إجابتك';

  @override
  String get aiAssistantAskUserAnswered => 'تم إرسال إجابتك';

  @override
  String get aiAssistantAskUserSkipped => 'تم تخطّي السؤال';

  @override
  String get aiAssistantAskUserConfirmYes => 'نعم';

  @override
  String get aiAssistantAskUserConfirmNo => 'لا';

  @override
  String get aiAssistantProductPickerChoose => 'ابحث واختر منتجًا';

  @override
  String get aiAssistantProductPickerChooseOther => 'ابحث عن منتج آخر…';

  @override
  String get aiAssistantProductPickerCreateNew => 'إنشاء منتج جديد';

  @override
  String get aiAssistantProductPickerCreateNewChosen => 'سيُنشأ منتج جديد';

  @override
  String get aiAssistantProductPickerTitle => 'اختر المنتج';

  @override
  String get aiAssistantProductPickerSearchHint => 'ابحث بالاسم أو الباركود';

  @override
  String get aiAssistantProductPickerEmpty => 'لا توجد منتجات مطابقة';

  @override
  String get aiAssistantProductPickerLoadError => 'تعذّر تحميل المنتجات';

  @override
  String get aiAssistantLinkUnavailable => 'تعذّر فتح الصفحة المطلوبة.';

  @override
  String get aiAssistantLinkCopied => 'تم نسخ الرابط';

  @override
  String get aiAssistantSearchedWeb => 'بحث في الويب';

  @override
  String get aiAssistantSourcesTitle => 'المصادر';

  @override
  String get aiAssistantAskUserRequired => 'هذا السؤال مطلوب';

  @override
  String get aiAssistantAskUserNumberInvalid => 'أدخل رقمًا صحيحًا';

  @override
  String aiAssistantAskUserNumberMin(String value) {
    return 'الحد الأدنى $value';
  }

  @override
  String aiAssistantAskUserNumberMax(String value) {
    return 'الحد الأقصى $value';
  }

  @override
  String aiAssistantAskUserSelectRange(int min, int max) {
    return 'اختر من $min إلى $max';
  }

  @override
  String aiAssistantAskUserSelectAtLeast(int min) {
    return 'اختر $min على الأقل';
  }

  @override
  String get aiAssistantAskUserPendingComposer =>
      'أجب عن السؤال أعلاه للمتابعة';

  @override
  String get migrationTitle => 'نقل البيانات';

  @override
  String get migrationSubtitle => 'استيراد بياناتك من نظام نقاط البيع القديم';

  @override
  String get migrationHeroDescription =>
      'انقل منتجاتك وفئاتك وعملاءك ومورّديك ومخزونك من نظامك القديم إلى دفتر.';

  @override
  String get migrationLoadError => 'تعذّر تحميل أدوات النقل';

  @override
  String get migrationStubSystemNotice =>
      'هذا النظام متاح لفحص التوافق فقط حاليًا؛ سيُفعَّل الاستيراد لاحقًا.';

  @override
  String get migrationCompatTitle => 'التوافق';

  @override
  String get migrationCompatibleMessage =>
      'قاعدة البيانات متوافقة وجاهزة للنقل.';

  @override
  String get migrationIncompatibleMessage =>
      'قاعدة البيانات غير متوافقة مع هذا النظام.';

  @override
  String migrationDetectedVersion(String version) {
    return 'الإصدار المكتشف: $version';
  }

  @override
  String get migrationCompatible => 'متوافق';

  @override
  String get migrationIncompatible => 'غير متوافق';

  @override
  String get migrationMissingTables => 'جداول مفقودة';

  @override
  String get migrationEntitiesSectionTitle => 'البيانات المراد نقلها';

  @override
  String get migrationEntitiesSectionSubtitle =>
      'اختر أنواع البيانات التي تريد نقلها.';

  @override
  String get migrationStockSourceSectionTitle => 'كميات المخزون';

  @override
  String get migrationStockSourceSnapshotLabel => 'نقل الكميات كما هي';

  @override
  String get migrationStockSourceSnapshotSubtitle =>
      'تُنقل كميات المخزون الحالية من النظام القديم كما هي.';

  @override
  String get migrationStockSourceReconstructLabel =>
      'احتساب الكميات من الفواتير';

  @override
  String get migrationStockSourceReconstructSubtitle =>
      'تُحتسب كمية كل صنف من فواتير الشراء ناقص فواتير البيع. مناسب عندما تكون كميات النظام القديم غير موثوقة لكن فواتيره سليمة. يتطلّب نقل فواتير الشراء والبيع، وسيُنبّهك إن بِيع صنف بكمية أكبر مما اشتُري.';

  @override
  String get migrationStockSourceNoneLabel => 'بدون كميات';

  @override
  String get migrationStockSourceNoneSubtitle =>
      'تُنقل المنتجات دون أي كميات، ويُبدأ الجرد من جديد في دفتر.';

  @override
  String get migrationEntityUnit => 'وحدات القياس';

  @override
  String get migrationEntityCategory => 'الفئات';

  @override
  String get migrationEntityProduct => 'المنتجات';

  @override
  String get migrationEntityVariant => 'المتغيرات';

  @override
  String get migrationEntityProductUnit => 'وحدات المنتج';

  @override
  String get migrationEntityStock => 'المخزون';

  @override
  String get migrationEntityCustomer => 'العملاء';

  @override
  String get migrationEntitySupplier => 'المورّدون';

  @override
  String get migrationEntityPurchaseOrder => 'فواتير الشراء';

  @override
  String get migrationEntitySupplierPayment => 'مدفوعات الموردين';

  @override
  String get migrationEntitySale => 'فواتير البيع';

  @override
  String get migrationEntityPayment => 'المدفوعات';

  @override
  String get migrationEntityEmployee => 'الموظفون';

  @override
  String get migrationEntityExpenseCategory => 'فئات المصروفات';

  @override
  String get migrationEntityExpense => 'المصروفات';

  @override
  String get migrationRunSectionTitle => 'النقل';

  @override
  String get migrationRunningLabel => 'جارٍ التنفيذ…';

  @override
  String get migrationDryRunHint =>
      'نفّذ تشغيلًا تجريبيًا أولًا للتحقق من البيانات قبل النقل الفعلي.';

  @override
  String get migrationRunSucceeded => 'اكتمل بنجاح';

  @override
  String get migrationRunPartial => 'اكتمل مع وجود مشكلات';

  @override
  String get migrationRunFailed => 'فشل';

  @override
  String get migrationSummaryCreated => 'جديد';

  @override
  String get migrationSummaryUpdated => 'محدّث';

  @override
  String get migrationSummaryFailed => 'فاشل';

  @override
  String get migrationViewIssuesButton => 'عرض المشكلات';

  @override
  String get migrationImportGatedHint =>
      'أكمِل تشغيلًا تجريبيًا ناجحًا بلا أخطاء لتفعيل النقل.';

  @override
  String get migrationImportButton => 'بدء النقل';

  @override
  String get migrationDryRunButton => 'تشغيل تجريبي';

  @override
  String get migrationRunStartError => 'تعذّر بدء العملية';

  @override
  String get migrationDryRunStarted => 'بدأ التشغيل التجريبي';

  @override
  String get migrationImportStarted => 'بدأ النقل';

  @override
  String get paymentsHubDrawerLabel => 'الخزينة';

  @override
  String get paymentsHubTitle => 'الخزينة';

  @override
  String get paymentsHubRefreshTooltip => 'تحديث المدفوعات';

  @override
  String get paymentsHubSegmentCustomer => 'مدفوعات العملاء (وارد)';

  @override
  String get paymentsHubSegmentSupplier => 'مدفوعات الموردين (صادر)';

  @override
  String get paymentsHubFilterAllMethods => 'كل الطرق';

  @override
  String get paymentsHubFilterDateRange => 'نطاق التاريخ';

  @override
  String paymentsHubFilterDateRangeValue(String start, String end) {
    return '$start - $end';
  }

  @override
  String get paymentsHubClearFilters => 'مسح عوامل التصفية';

  @override
  String get paymentsHubCustomerEmptyTitle => 'لا توجد مدفوعات عملاء';

  @override
  String get paymentsHubCustomerEmptyMessage =>
      'ستظهر هنا المبالغ المحصّلة من العملاء.';

  @override
  String get paymentsHubSupplierEmptyTitle => 'لا توجد مدفوعات موردين';

  @override
  String get paymentsHubSupplierEmptyMessage =>
      'ستظهر هنا المبالغ المدفوعة للموردين.';

  @override
  String get paymentsHubLoadError => 'تعذّر تحميل المدفوعات';

  @override
  String get paymentsHubWalkInCustomer => 'عميل نقدي';

  @override
  String get paymentsHubUnknownSupplier => 'مورد غير محدد';

  @override
  String paymentsHubInvoiceValue(String number) {
    return 'فاتورة $number';
  }

  @override
  String paymentsHubPurchaseOrderValue(String number) {
    return 'أمر شراء $number';
  }

  @override
  String paymentsHubCommissionValue(String amount) {
    return 'عمولة $amount';
  }

  @override
  String paymentsHubReferenceValue(String reference) {
    return 'مرجع: $reference';
  }

  @override
  String paymentsHubRecordedByValue(String username) {
    return 'سجّلها $username';
  }

  @override
  String get paymentsHubReprintProofAction => 'إعادة طباعة سند';

  @override
  String get paymentsHubPrintLogAction => 'سجل الطباعة';

  @override
  String get paymentsHubReprintSuccess => 'تمت إعادة طباعة السند';

  @override
  String get paymentsHubReprintError => 'تعذّرت إعادة طباعة السند';

  @override
  String get convertQuotationButton => 'تحويل إلى بيع';

  @override
  String get convertQuotationDialogTitle => 'تحويل عرض السعر إلى بيع';

  @override
  String get convertQuotationSaleTypeLabel => 'نوع البيع';

  @override
  String get convertQuotationSaleTypeStandard => 'عادي';

  @override
  String get convertQuotationSaleTypeCredit => 'آجل';

  @override
  String get convertQuotationDownPaymentLabel => 'الدفعة المقدمة';

  @override
  String get convertQuotationDownPaymentHelper =>
      'اختياري — المبلغ المحصّل عند التحويل.';

  @override
  String convertQuotationStandardHint(String total) {
    return 'يتطلب البيع العادي سداد كامل المبلغ ($total).';
  }

  @override
  String get convertQuotationConfirm => 'تحويل';

  @override
  String get convertQuotationSuccess => 'تم تحويل عرض السعر إلى بيع';

  @override
  String get convertQuotationError => 'تعذّر تحويل عرض السعر';

  @override
  String get subscriptionSectionTitle => 'الاشتراك والوصول عن بُعد';

  @override
  String get subscriptionSectionSubtitle => 'معرّف التثبيت وحالة اشتراكاتك';

  @override
  String get subscriptionStatusLoadError => 'تعذّر تحميل حالة الاشتراك.';

  @override
  String get subscriptionRefreshTooltip => 'تحديث من الخادم';

  @override
  String get subscriptionSyncFailedMessage =>
      'تعذّر الاتصال بالخادم لتحديث الحالة. يتم عرض آخر حالة محفوظة.';

  @override
  String get subscriptionSyncedMessage => 'تم تحديث حالة الاشتراك.';

  @override
  String get subscriptionHeroFallbackTitle => 'اشتراك دفتر';

  @override
  String get subscriptionStatusActive => 'نشط';

  @override
  String get subscriptionStatusExpired => 'منتهٍ';

  @override
  String get subscriptionStatusInactive => 'غير مُفعّل';

  @override
  String get subscriptionStateOn => 'مُفعّل';

  @override
  String get subscriptionStateOff => 'متوقّف';

  @override
  String subscriptionUntilDate(String date) {
    return 'حتى $date';
  }

  @override
  String subscriptionRemoteAccessPill(String state) {
    return 'الوصول عن بُعد · $state';
  }

  @override
  String subscriptionAiPill(String state) {
    return 'الذكاء الاصطناعي · $state';
  }

  @override
  String get subscriptionInstallationIdTitle => 'معرّف التثبيت';

  @override
  String get subscriptionInstallationIdHelper =>
      'أرسل هذا المعرّف للدعم لتفعيل اشتراكك أو تجديده.';

  @override
  String get subscriptionInstallationIdCopy => 'نسخ';

  @override
  String get subscriptionInstallationIdCopied => 'تم نسخ معرّف التثبيت.';

  @override
  String get subscriptionNotConfiguredTitle => 'لم يتم الربط بالخادم بعد';

  @override
  String get subscriptionNotConfiguredMessage =>
      'تواصل مع الدعم لتفعيل الوصول عن بُعد ومساعد الذكاء الاصطناعي.';

  @override
  String get subscriptionRemoteAccessTitle => 'الوصول عن بُعد';

  @override
  String get subscriptionRemoteAccessActiveTitle => 'الوصول عن بُعد مُفعّل';

  @override
  String get subscriptionRemoteAccessActiveMessage =>
      'يمكنك استخدام التطبيق خارج المتجر عبر خادم دفتر.';

  @override
  String get subscriptionRemoteAccessInactiveTitle =>
      'الوصول عن بُعد غير مُفعّل';

  @override
  String get subscriptionRemoteAccessInactiveMessage =>
      'تتطلب هذه الميزة اشتراكًا فعّالًا. تواصل مع الدعم لتفعيلها.';

  @override
  String get subscriptionFieldStatus => 'الحالة';

  @override
  String get subscriptionFieldSubscription => 'الاشتراك';

  @override
  String get subscriptionFieldExpiresOn => 'ينتهي في';

  @override
  String get subscriptionFieldRemaining => 'المدة المتبقية';

  @override
  String get subscriptionFieldLastConnected => 'آخر اتصال بالخادم';

  @override
  String get subscriptionExpiryNever => 'بدون تاريخ انتهاء';

  @override
  String subscriptionDaysLeft(int days) {
    return 'متبقّي $days يوم';
  }

  @override
  String get subscriptionNeverConnected => 'لم يتصل بعد';

  @override
  String get subscriptionAiTitle => 'مساعد الذكاء الاصطناعي';

  @override
  String get subscriptionAiActiveTitle => 'مساعد الذكاء الاصطناعي مُفعّل';

  @override
  String get subscriptionAiActiveMessage =>
      'اشتراكك يشمل GPT. هذا هو استهلاكك الحالي.';

  @override
  String get subscriptionAiInactiveTitle => 'مساعد الذكاء الاصطناعي غير مُفعّل';

  @override
  String get subscriptionAiInactiveMessage =>
      'أضِف GPT إلى اشتراكك للاستفادة منه. تواصل مع الدعم.';

  @override
  String get subscriptionAiUsageUnavailable =>
      'تعذّر تحميل بيانات الاستهلاك حاليًا.';

  @override
  String subscriptionLastSynced(String time) {
    return 'آخر تحديث للحالة: $time';
  }

  @override
  String get clientUpdatesTitle => 'تحديثات التطبيق';

  @override
  String get clientUpdatesSubtitle => 'تحقّق من وجود تحديث وثبّته';

  @override
  String get getAppsTitle => 'تنزيل التطبيق على جهاز جديد';

  @override
  String get getAppsSubtitle => 'رمز QR ورابط للتنزيل عبر الشبكة المحلية';

  @override
  String get appUpdatesPageTitle => 'تحديثات التطبيق';

  @override
  String get appUpdatesCurrentVersionLabel => 'الإصدار الحالي';

  @override
  String get appUpdatesChecking => 'جارٍ التحقق من التحديثات…';

  @override
  String get appUpdatesUpToDate => 'أنت تستخدم أحدث إصدار.';

  @override
  String get appUpdatesAvailableLabel => 'يتوفّر إصدار جديد';

  @override
  String get appUpdatesInstall => 'تحديث الآن';

  @override
  String get appUpdatesDownloading => 'جارٍ التنزيل…';

  @override
  String get appUpdatesFailed => 'تعذّر التحديث. حاول مرة أخرى.';

  @override
  String get appUpdatesUnsupportedWeb =>
      'تتم إدارة تحديثات نسخة الويب من الخادم.';

  @override
  String get appUpdatesRecheck => 'إعادة التحقق';

  @override
  String get getAppsDialogTitle => 'تنزيل تطبيقات دفتر';

  @override
  String get getAppsInstructions =>
      'امسح الرمز أو افتح الرابط على الجهاز الجديد (على نفس الشبكة) للتنزيل.';

  @override
  String get getAppsCopyLink => 'نسخ الرابط';

  @override
  String get getAppsLinkCopied => 'تم نسخ الرابط';

  @override
  String get aiDailyBriefLabel => 'ملخص اليوم من GPT';

  @override
  String get aiDailyBriefSeed =>
      'أعطني ملخصًا سريعًا لمتجري: كيف كان أداء المبيعات في الفترة، وما الذي يحتاج انتباهي اليوم، وأي شيء غير معتاد يجب أن أنتبه له.';

  @override
  String aiDigestElaborate(String topic) {
    return 'حدّثني أكثر عن $topic في متجري.';
  }

  @override
  String get smartReorderButton => 'إعادة طلب ذكية';

  @override
  String get smartReorderTooltip =>
      'اقتراح أوامر شراء ذكية للأصناف الناقصة بالذكاء الاصطناعي';

  @override
  String get smartReorderSeed =>
      'راجع مخزوني وأنشئ أوامر شراء ذكية للأصناف التي تحتاج إعادة طلب. تجاهل الأصناف البطيئة والراكدة حتى لا أُجمّد رأس مالي، واحسب الكميات من سرعة البيع الفعلية مقرّبةً لوحدات الشراء. لكل صنف اختر المورّد الأنسب من سجلّ الشراء، وأنشئ أمر شراء منفصلًا لكل مورّد. اعرض لي ملخصًا بعدد الأوامر والموردين وإجمالي رأس المال المقدَّر وخُذ تأكيدي قبل الإنشاء.';

  @override
  String get messagingSettingsTitle => 'إعدادات الرسائل';

  @override
  String get messagingSettingsSubtitle =>
      'بوابة الإرسال (هاتف SMS Gate) وحدود الإرسال ورسالة اختبار';

  @override
  String get messagingHeroTitle => 'بوابة الرسائل';

  @override
  String get messagingStatusInactive => 'غير مُهيّأة';

  @override
  String get messagingConnectionTitle => 'الاتصال بالجهاز';

  @override
  String get messagingBaseUrlLabel => 'عنوان الجهاز (Base URL)';

  @override
  String get messagingUsernameLabel => 'اسم المستخدم';

  @override
  String get messagingPasswordLabel => 'كلمة المرور';

  @override
  String get messagingPasswordKeepHint =>
      'اتركه فارغًا للإبقاء على كلمة المرور الحالية';

  @override
  String get messagingRateLabel => 'رسائل/الدقيقة';

  @override
  String get messagingDailyCapLabel => 'الحد اليومي (0 = بلا حد)';

  @override
  String get messagingSaveError => 'تعذّر حفظ الإعدادات';

  @override
  String get messagingLoadError => 'تعذّر تحميل إعدادات الرسائل';

  @override
  String get messagingTestTitle => 'إرسال رسالة اختبار';

  @override
  String get messagingTestNeedsSaveTitle => 'احفظ البوابة أولًا';

  @override
  String get messagingTestNeedsSaveMessage =>
      'أدخل إعدادات الاتصال واحفظها قبل إرسال رسالة اختبار.';

  @override
  String get messagingTestPhoneLabel => 'رقم الهاتف';

  @override
  String get messagingTestSendButton => 'إرسال اختبار';

  @override
  String get messagingTestSentTitle => 'تم الإرسال';

  @override
  String get messagingTestSentMessage => 'غادرت رسالة الاختبار البوابة بنجاح.';

  @override
  String get messagingTestFailedTitle => 'فشل الإرسال';

  @override
  String get messagingTestFailedMessage =>
      'تعذّر إرسال رسالة الاختبار. تأكد من عنوان الجهاز وبيانات الدخول.';

  @override
  String get messagingStatusReady => 'جاهزة — إرسال واستقبال';

  @override
  String get messagingStatusSendOnly => 'إرسال فقط — لم تُفعّل';

  @override
  String messagingLastSeenLabel(String when) {
    return 'آخر اتصال $when';
  }

  @override
  String get messagingUnsavedBadge => 'تغييرات غير محفوظة';

  @override
  String get messagingSetupGuideTitle => 'أين أجد هذه البيانات؟';

  @override
  String get messagingSetupGuideMessage =>
      'على هاتف الرسائل: افتح تطبيق SMS Gate، فعّل «Local Server»، ثم اضغط زر الحالة في الأسفل حتى تصبح Online. سيعرض التطبيق عنوان الهاتف على الشبكة واسم المستخدم وكلمة المرور — انقلها هنا كما هي.';

  @override
  String get messagingBaseUrlHelper =>
      'يكفي عنوان الهاتف على الشبكة؛ المنفذ الافتراضي 8080 يُضاف تلقائيًا.';

  @override
  String get messagingBaseUrlInvalid =>
      'عنوان غير صالح. اكتب عنوان الهاتف على الشبكة، مثل 192.168.1.50';

  @override
  String messagingBaseUrlNormalized(String url) {
    return 'سيُحفظ العنوان هكذا: $url';
  }

  @override
  String get messagingRateHelper => '0 = بلا حد';

  @override
  String get messagingUnpacedTitle => 'لا يوجد حد للإرسال في الدقيقة';

  @override
  String get messagingUnpacedMessage =>
      'بدون حد، قد تُصنَّف الشريحة كمرسل مزعج فيُحظر الرقم. القيمة المقترحة 6 رسائل في الدقيقة.';

  @override
  String get messagingConnectButton => 'حفظ وتفعيل';

  @override
  String get messagingActivateOnlyButton => 'تفعيل الجهاز';

  @override
  String get messagingReactivateButton => 'إعادة تسجيل الروابط';

  @override
  String get messagingConnectingLabel => 'جارٍ التفعيل…';

  @override
  String get messagingConnectHint =>
      'الحفظ يكفي للإرسال؛ التفعيل يضبط الهاتف ليُعيد إلينا الرسائل الواردة وتقارير التسليم دون أي إعداد يدوي عليه.';

  @override
  String get messagingNotActivatedTitle => 'لم يُفعّل الجهاز بعد';

  @override
  String get messagingNotActivatedMessage =>
      'الإرسال يعمل، لكن الردود الواردة وتقارير التسليم لن تصل حتى تضغط «تفعيل الجهاز».';

  @override
  String get messagingConnectedTitle => 'الجهاز جاهز';

  @override
  String messagingConnectedMessage(int count) {
    return 'حُفظت الإعدادات وسُجّلت $count روابط على الهاتف — الرسائل الواردة وتقارير التسليم تصل الآن تلقائيًا.';
  }

  @override
  String get messagingSavedNotActivatedTitle =>
      'حُفظت الإعدادات — لم يُفعّل الجهاز';

  @override
  String get messagingSavedNotActivatedMessage =>
      'تعذّر الوصول إلى الهاتف لتسجيل الروابط. تأكد أن الهاتف يعمل وأن «Local Server» في وضع Online على نفس الشبكة، ثم أعد المحاولة.';

  @override
  String get messagingReactivateFailedTitle => 'حُفظت الإعدادات';

  @override
  String get messagingReactivateFailedMessage =>
      'تعذّر الوصول إلى الهاتف الآن لإعادة تسجيل الروابط، والروابط المسجّلة سابقًا ما زالت تعمل.';

  @override
  String get messagingSaveFailedTitle => 'تعذّر حفظ الإعدادات';

  @override
  String get messagingDeviceErrorTitle => 'آخر خطأ من الجهاز';

  @override
  String messagingDeviceErrorMessage(String detail, String when) {
    return '$detail — $when';
  }

  @override
  String get messagingUnsavedTestHint =>
      'احفظ التغييرات أولًا — الاختبار يجري على الإعدادات المحفوظة في الخادم، لا على ما تراه هنا.';

  @override
  String get messagingTestPhoneHelper =>
      'استخدم رقمًا بين يديك الآن للتحقق من وصول الرسالة.';

  @override
  String get conversationsTitle => 'المحادثات';

  @override
  String get conversationsDrawerLabel => 'المحادثات';

  @override
  String get conversationsEmpty => 'لا توجد محادثات بعد';

  @override
  String get conversationsLoadError => 'تعذّر تحميل المحادثات';

  @override
  String conversationsUnreadBadge(int count) {
    return '$count جديدة';
  }

  @override
  String get conversationThreadEmpty => 'لا توجد رسائل في هذه المحادثة';

  @override
  String get conversationReplyHint => 'اكتب ردًا…';

  @override
  String get conversationSendTooltip => 'إرسال';

  @override
  String get conversationSendError => 'تعذّر إرسال الرسالة';

  @override
  String get conversationReadOnly => 'ليس لديك صلاحية الرد على المحادثات';

  @override
  String get conversationMessageStatusQueued => 'بانتظار الإرسال';

  @override
  String get conversationMessageStatusScheduled => 'مُجدولة';

  @override
  String get conversationMessageStatusSending => 'جارٍ الإرسال';

  @override
  String get conversationMessageStatusSent => 'أُرسلت';

  @override
  String get conversationMessageStatusDelivered => 'وصلت';

  @override
  String get conversationMessageStatusFailed => 'لم تُرسل';

  @override
  String get conversationMessageStatusBlocked => 'موقوفة: ألغى الاشتراك';

  @override
  String get conversationMessageStatusCancelled => 'أُلغيت';

  @override
  String get conversationMessageStatusExpired => 'انتهت مهلتها';

  @override
  String get newConversationTitle => 'محادثة جديدة';

  @override
  String get newConversationStarting => 'جارٍ فتح المحادثة…';

  @override
  String get newConversationCustomerLabel => 'العميل';

  @override
  String get newConversationSelectCustomer => 'اختر عميلاً';

  @override
  String get newConversationNoPhoneWarning =>
      'هذا العميل لا يملك رقم هاتف. أضِف رقمًا لبدء المحادثة.';

  @override
  String get newConversationStartButton => 'بدء المحادثة';

  @override
  String get newConversationError => 'تعذّر بدء المحادثة.';

  @override
  String get customerConsentTitle => 'تفضيلات التواصل';

  @override
  String get customerMarketingAllowedLabel => 'السماح بالرسائل التسويقية';

  @override
  String get customerMarketingAllowedHelp =>
      'إرسال العروض والحملات عبر SMS. يمكن للعميل الإيقاف بإرسال STOP.';

  @override
  String get customerDoNotContactLabel => 'عدم الإزعاج';

  @override
  String get customerDoNotContactHelp =>
      'إيقاف كل الرسائل التسويقية لهذا العميل (تبقى الرسائل المتعلقة بالفواتير مسموحة).';

  @override
  String get customerConsentError => 'تعذّر تحديث تفضيلات التواصل';

  @override
  String get invoiceSendSmsTooltip => 'إرسال الفاتورة كرسالة نصية';

  @override
  String get invoiceSendSmsSuccess => 'تم إرسال الفاتورة برسالة نصية';

  @override
  String get invoiceSendSmsError => 'تعذّر إرسال الفاتورة برسالة نصية';

  @override
  String get campaignsTitle => 'الحملات';

  @override
  String get campaignsDrawerLabel => 'الحملات';

  @override
  String get campaignsEmpty => 'لا توجد حملات بعد';

  @override
  String get campaignsLoadError => 'تعذّر تحميل الحملات';

  @override
  String get campaignNewButton => 'حملة جديدة';

  @override
  String get campaignNewTitle => 'حملة جديدة';

  @override
  String get campaignEditTitle => 'تعديل الحملة';

  @override
  String get campaignStatusLabel => 'الحالة';

  @override
  String get campaignStatusDraft => 'مسودة';

  @override
  String get campaignStatusSending => 'قيد الإرسال';

  @override
  String get campaignStatusSent => 'مُرسَلة';

  @override
  String get campaignStatusCancelled => 'ملغاة';

  @override
  String get campaignStatusFailed => 'فشلت';

  @override
  String get campaignAiBadge => 'اقتراح الذكاء الاصطناعي';

  @override
  String campaignRecipientsSummary(int sent, int total) {
    return '$sent من $total مُرسَلة';
  }

  @override
  String get campaignNameLabel => 'اسم الحملة';

  @override
  String get campaignBodyLabel => 'نص الرسالة';

  @override
  String get campaignBodyHelp =>
      'يمكن تضمين اسم العميل واسم المتجر في النص تلقائيًا.';

  @override
  String campaignSegmentsCounter(int count) {
    return '≈ $count مقطع';
  }

  @override
  String get campaignAudienceTitle => 'الفئة المستهدفة';

  @override
  String get campaignSaveButton => 'حفظ المسودة';

  @override
  String get campaignSavedMessage => 'تم حفظ المسودة';

  @override
  String get campaignSaveError => 'تعذّر حفظ المسودة';

  @override
  String get campaignSaveFirstTitle => 'احفظ المسودة أولًا';

  @override
  String get campaignSaveFirstHint =>
      'احفظ الحملة كمسودة لتتمكن من معاينتها وإرسالها.';

  @override
  String get campaignPreviewTitle => 'المعاينة والإرسال';

  @override
  String get campaignPreviewButton => 'معاينة الفئة';

  @override
  String get campaignPreviewAudience => 'إجمالي الفئة';

  @override
  String get campaignPreviewSendable => 'القابلون للإرسال';

  @override
  String get campaignPreviewSkipped => 'مستبعدون (رفضوا التسويق)';

  @override
  String get campaignPreviewSegments => 'عدد المقاطع';

  @override
  String get campaignPreviewDurationLabel => 'المدة التقديرية';

  @override
  String campaignPreviewDuration(int minutes) {
    return '≈ $minutes دقيقة';
  }

  @override
  String get campaignSampleTitle => 'نموذج الرسالة';

  @override
  String get campaignSendButton => 'موافقة وإرسال';

  @override
  String get campaignSendConfirmTitle => 'تأكيد إرسال الحملة';

  @override
  String campaignSendConfirmMessage(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'سيتم إرسال $count رسالة نصية إلى العملاء الآن، ولا يمكن التراجع بعد بدء الإرسال.',
      two:
          'سيتم إرسال رسالتين نصيتين إلى عميلين الآن، ولا يمكن التراجع بعد بدء الإرسال.',
      one:
          'سيتم إرسال رسالة نصية واحدة إلى عميل واحد الآن، ولا يمكن التراجع بعد بدء الإرسال.',
      zero:
          'لا يوجد عملاء قابلون للإرسال في هذه الفئة، لن تصل أي رسالة. راجع الفئة المستهدفة قبل المتابعة.',
    );
    return '$_temp0';
  }

  @override
  String get campaignSendConfirmButton => 'إرسال الآن';

  @override
  String get campaignSentMessage => 'بدأ إرسال الحملة';

  @override
  String get campaignSendError => 'تعذّر إرسال الحملة';

  @override
  String get campaignNoSendPermission => 'ليس لديك صلاحية إرسال الحملات';

  @override
  String get purchaseLineQuantityLabel => 'الكمية';

  @override
  String get purchaseExtraDiscountLabel => 'خصم على أمر الشراء';

  @override
  String get purchaseExtraDiscountHint =>
      'مبلغ يُخصم من إجمالي هذا الأمر (مثلاً لإزالة الكسور)';

  @override
  String get connectionSearchingMessage =>
      'نبحث عن خادم متجرك على الشبكة المحلية…';

  @override
  String get connectionManualTitle => 'تعذّر العثور على الخادم تلقائيًا';

  @override
  String get connectionManualMessage =>
      'أدخل عنوان الخادم (IP أو رابط) للاتصال يدويًا.';

  @override
  String get connectionManualFieldLabel => 'عنوان الخادم';

  @override
  String get connectionManualFieldHint => 'مثال: 192.168.1.10';

  @override
  String get connectionManualConnectButton => 'اتصال';

  @override
  String get connectionManualRetryButton => 'إعادة المحاولة تلقائيًا';

  @override
  String get connectionManualError =>
      'تعذّر الاتصال بهذا العنوان. تأكد من تشغيل الخادم واتصال الجهاز بالشبكة نفسها.';

  @override
  String get connectionManualSearchingHint =>
      'ما زلنا نبحث تلقائيًا في الخلفية…';

  @override
  String get treasuryTitle => 'الخزينة';

  @override
  String get treasuryDrawerLabel => 'الخزينة';

  @override
  String get treasuryRefreshTooltip => 'تحديث الأرصدة';

  @override
  String get treasuryHeroTitle => 'إجمالي أموال المحل';

  @override
  String get treasuryHeroSubtitle => 'ما يفترض أن يكون لديك الآن';

  @override
  String get treasuryCashLabel => 'نقدًا';

  @override
  String get treasuryBankLabel => 'في المصرف';

  @override
  String get treasurySectionCash => 'الصناديق النقدية';

  @override
  String get treasurySectionBank => 'الحسابات المصرفية';

  @override
  String get treasuryExpectedLabel => 'المتوقع';

  @override
  String get treasuryCountedLabel => 'المجرود';

  @override
  String get treasuryNeverCounted => 'لم يُجرد بعد';

  @override
  String treasuryCountedOn(String date) {
    return 'جُرد في $date';
  }

  @override
  String treasuryVarianceShort(String amount) {
    return 'عجز $amount';
  }

  @override
  String treasuryVarianceOver(String amount) {
    return 'زيادة $amount';
  }

  @override
  String get treasuryVarianceMatched => 'مطابق';

  @override
  String treasuryVarianceCalloutTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count حسابات لا تطابق الجرد',
      one: 'حساب واحد لا يطابق الجرد',
    );
    return '$_temp0';
  }

  @override
  String get treasuryVarianceCalloutMessage =>
      'افتح الحساب لمعرفة أين ذهب الفرق.';

  @override
  String get treasuryUncountedCalloutTitle => 'لم تجرد كل الحسابات بعد';

  @override
  String get treasuryUncountedCalloutMessage =>
      'الرصيد المعروض حساب من الحركات، لا عدّ فعلي. اجرد لتتأكد.';

  @override
  String get treasuryEmptyTitle => 'لا توجد حسابات بعد';

  @override
  String get treasuryEmptyMessage =>
      'أضف صندوقًا نقديًا أو حسابًا مصرفيًا لتتابع أموال المحل.';

  @override
  String get treasuryErrorTitle => 'تعذر تحميل الأرصدة';

  @override
  String get treasuryRetry => 'إعادة المحاولة';

  @override
  String get treasuryActionCount => 'جرد';

  @override
  String get treasuryActionTransfer => 'تحويل';

  @override
  String get treasuryActionDeposit => 'إيداع في المصرف';

  @override
  String get treasuryBreakdownTitle => 'من أين جاء هذا الرصيد';

  @override
  String get treasuryMovementsTitle => 'آخر الحركات';

  @override
  String get treasuryMovementsEmpty => 'لا حركات في هذه الفترة.';

  @override
  String get treasuryMovementsError => 'تعذر تحميل الحركات.';

  @override
  String get treasuryMovementsTruncated =>
      'عرضنا أحدث الحركات فقط. اختر فترة أقصر لرؤية الباقي.';

  @override
  String get treasuryRoutedHint => 'المقبوضات والمدفوعات غير المخصصة تدخل هنا.';

  @override
  String treasuryOpeningAtHint(String date) {
    return 'يُحسب من $date';
  }

  @override
  String get treasuryComponentOpening => 'الرصيد الافتتاحي';

  @override
  String get treasuryComponentSales => 'المبيعات والمقبوضات';

  @override
  String get treasuryComponentDrawerIn => 'إيداعات في الصندوق';

  @override
  String get treasuryComponentDrawerOut => 'سحوبات من الصندوق';

  @override
  String get treasuryComponentExpenses => 'المصروفات';

  @override
  String get treasuryComponentSuppliers => 'مدفوعات الموردين';

  @override
  String get treasuryComponentPayroll => 'الرواتب';

  @override
  String get treasuryComponentCommission => 'عمولات الدفع';

  @override
  String get treasuryComponentTransferIn => 'تحويلات واردة';

  @override
  String get treasuryComponentTransferOut => 'تحويلات صادرة';

  @override
  String get treasuryPayrollAssumptionNote =>
      'الرواتب محسوبة نقدًا. إن كنت تدفعها تحويلًا، سجّل تحويلًا من المصرف إلى الخزينة.';

  @override
  String treasuryCountSheetTitle(String account) {
    return 'جرد $account';
  }

  @override
  String get treasuryCountSheetPrompt => 'كم المبلغ الموجود فعلًا؟';

  @override
  String get treasuryCountFieldLabel => 'المبلغ الفعلي';

  @override
  String get treasuryCountNoteLabel => 'ملاحظة (اختياري)';

  @override
  String get treasuryCountSubmit => 'حفظ الجرد';

  @override
  String get treasuryCountResultMatched => 'مطابق تمامًا.';

  @override
  String treasuryCountResultShort(String amount) {
    return 'عجز $amount عن المتوقع.';
  }

  @override
  String treasuryCountResultOver(String amount) {
    return 'زيادة $amount عن المتوقع.';
  }

  @override
  String get treasuryCountFailed => 'تعذر حفظ الجرد.';

  @override
  String get treasuryTransferSheetTitle => 'تحويل أموال';

  @override
  String get treasuryTransferFrom => 'من';

  @override
  String get treasuryTransferTo => 'إلى';

  @override
  String get treasuryTransferOutside => 'خارج المحل';

  @override
  String get treasuryTransferAmount => 'المبلغ';

  @override
  String get treasuryTransferReason => 'السبب (اختياري)';

  @override
  String get treasuryTransferSubmit => 'تسجيل التحويل';

  @override
  String get treasuryTransferSaved => 'تم تسجيل التحويل.';

  @override
  String get treasuryTransferFailed => 'تعذر تسجيل التحويل.';

  @override
  String get treasuryTransferNeedsSide => 'اختر حسابًا على الأقل.';

  @override
  String get treasuryTransferSameAccount => 'لا يمكن التحويل إلى نفس الحساب.';

  @override
  String get treasuryAmountInvalid => 'أدخل مبلغًا صحيحًا.';

  @override
  String get treasuryLedgerLink => 'سجل المقبوضات والمدفوعات';

  @override
  String get exchangeRatesTitle => 'أسعار الصرف';

  @override
  String get exchangeRatesDrawerLabel => 'أسعار الصرف';

  @override
  String get exchangeRatesLoadError => 'تعذر تحميل أسعار الصرف.';

  @override
  String get exchangeRatesEmpty => 'لا توجد أسعار صرف بعد.';

  @override
  String get exchangeRatesEmptyHint =>
      'سيتم جلب الأسعار تلقائيًا، أو أدخل سعرًا يدويًا.';

  @override
  String get exchangeRatesSyncNow => 'تحديث الآن';

  @override
  String get exchangeRatesSyncedMessage => 'تم تحديث أسعار الصرف.';

  @override
  String get exchangeRatesSyncError =>
      'تعذر تحديث أسعار الصرف. سيتم استخدام آخر سعر معروف.';

  @override
  String get exchangeRateSourceRelay => 'من المزوّد';

  @override
  String get exchangeRateSourceManual => 'مُدخل يدويًا';

  @override
  String get exchangeRateStaleBadge => 'سعر قديم';

  @override
  String exchangeRateAgeHours(int hours) {
    return 'منذ $hours ساعة';
  }

  @override
  String exchangeRateAgeDays(int days) {
    return 'منذ $days يوم';
  }

  @override
  String exchangeRateSubstitutedWarning(String instrument) {
    return 'لا يوجد سعر لطريقة الدفع المختارة؛ تم استخدام سعر $instrument.';
  }

  @override
  String get settlementInstrumentCash => 'نقدًا';

  @override
  String get settlementInstrumentBank => 'تحويل مصرفي';

  @override
  String get settlementInstrumentLabel => 'طريقة دفع المشتريات';

  @override
  String get settlementInstrumentHelp =>
      'كلا السعرين من السوق الموازي. اختر كيف تدفع فعليًا لمورديك.';

  @override
  String get settlementBankLabel => 'المصرف';

  @override
  String get manualRateTitle => 'إدخال سعر صرف';

  @override
  String get manualRateCurrencyLabel => 'العملة';

  @override
  String manualRateValueLabel(String base) {
    return 'سعر الصرف مقابل $base';
  }

  @override
  String get manualRateNoteLabel => 'ملاحظة (اختياري)';

  @override
  String get manualRateSave => 'حفظ السعر';

  @override
  String get manualRateSavedMessage => 'تم حفظ سعر الصرف.';

  @override
  String get manualRateInvalid => 'أدخل سعر صرف أكبر من صفر.';

  @override
  String get manualRateWinsHint => 'السعر الذي تُدخله يعلو على سعر المزوّد.';

  @override
  String get repricingTitle => 'تحديث الأسعار';

  @override
  String get repricingNothingToDo => 'جميع الأسعار محدّثة.';

  @override
  String repricingDriftCount(int count) {
    return '$count منتج تغيّر سعره بسبب تغيّر سعر الصرف';
  }

  @override
  String get repricingApply => 'تطبيق على المحدد';

  @override
  String repricingAppliedMessage(int count) {
    return 'تم تحديث $count سعر.';
  }

  @override
  String get repricingUnpriceable => 'لا يوجد سعر صرف لهذه العملة';

  @override
  String repricingOldNewRate(String oldRate, String newRate) {
    return 'من $oldRate إلى $newRate';
  }

  @override
  String get productPricingCurrencyLabel => 'عملة التسعير';

  @override
  String get productPricingCurrencyBase => 'عملة المتجر';

  @override
  String get productPricingCurrencyHelp =>
      'سعر المنتج مُسجَّل بهذه العملة ويُحوَّل إلى عملة المتجر عند البيع.';

  @override
  String get productForeignPriceLabel => 'السعر بالعملة الأجنبية';

  @override
  String productPriceFrozenRateHint(String rate) {
    return 'محسوب بسعر صرف $rate';
  }

  @override
  String productPricingNoRate(String currency) {
    return 'لا يوجد سعر صرف لـ $currency بعد؛ سيُحدَّث السعر تلقائيًا عند وصوله.';
  }

  @override
  String get productPricingCurrencyChanged =>
      'سيتم إعادة حساب السعر بالعملة الجديدة.';

  @override
  String get supplierCurrencyLabel => 'عملة المورّد';

  @override
  String supplierExchangeRateLabel(String currency) {
    return 'سعر الصرف مقابل $currency';
  }

  @override
  String get supplierExchangeRateHelp =>
      'اتركه فارغًا لاستخدام سعر الصرف بتاريخ فاتورة المورّد.';

  @override
  String supplierExchangeRateMissing(String currency) {
    return 'لا يوجد سعر صرف لـ $currency. أدخل سعر الصرف يدويًا.';
  }

  @override
  String get supplierExchangeRateTyped => 'سعر صرف مُدخل يدويًا';

  @override
  String get supplierExchangeRateFromFeed => 'سعر الصرف من المزوّد';

  @override
  String get supplierRateAsOfToday => 'يُحسب بسعر اليوم';

  @override
  String supplierRateAsOfInvoiceDate(String date) {
    return 'يُحسب بسعر تاريخ الفاتورة ($date)';
  }

  @override
  String supplierInvoiceTotalPreview(String foreign, String base) {
    return 'إجمالي الفاتورة $foreign ≈ $base';
  }

  @override
  String get shopSetupForeignCurrencyTitle => 'أشتري ببضاعة بعملة أجنبية';

  @override
  String get shopSetupForeignCurrencySubtitle =>
      'فعّل هذا إن كانت فواتير مورّديك أو قوائم أسعارك بالدولار أو عملة أخرى. الأسعار والتقارير تبقى بالدينار في كل الأحوال.';

  @override
  String get shopSetupSettlementTitle => 'كيف تدفع لمورّديك؟';

  @override
  String get shopSetupSettlementSubtitle =>
      'كلا السعرين من السوق الموازي؛ الفرق هو طريقة الدفع.';

  @override
  String get pricingSheetTitle => 'تسعير المنتج';

  @override
  String get pricingSheetTooltip => 'تسعير هذا المنتج بعد تغيّر التكلفة';

  @override
  String get pricingSheetVariantsSectionTitle => 'أسعار الخيارات';

  @override
  String get pricingSheetBasePriceSectionTitle => 'سعر البيع';

  @override
  String pricingSheetVariantsSectionSubtitle(String unit) {
    return 'السعر لكل $unit';
  }

  @override
  String get pricingSheetPackSectionTitle => 'أسعار العبوات';

  @override
  String get pricingSheetPackSectionSubtitle =>
      'سعر بيع الكرتونة أو العلبة — يمكن أن يقل عن سعر القطعة مضروبًا في عددها.';

  @override
  String get pricingSheetNewCostLabel => 'التكلفة الجديدة';

  @override
  String pricingSheetCostPerPackSubtitle(String cost, String unit) {
    return '$cost لكل $unit';
  }

  @override
  String get pricingSheetPreviousCostLabel => 'التكلفة السابقة';

  @override
  String pricingSheetCostUp(String percent) {
    return 'ارتفعت $percent٪';
  }

  @override
  String pricingSheetCostDown(String percent) {
    return 'انخفضت $percent٪';
  }

  @override
  String get pricingSheetLowestCostLabel => 'أقل تكلفة';

  @override
  String get pricingSheetHighestCostLabel => 'أعلى تكلفة';

  @override
  String get pricingSheetMarkupTitle => 'تسعير بنسبة ربح';

  @override
  String get pricingSheetMarkupSubtitle =>
      'طبّق نسبة ربح على التكلفة الجديدة لكل الأسعار دفعة واحدة.';

  @override
  String pricingSheetSuggestedMarkupChip(String percent) {
    return 'المعتاد $percent٪';
  }

  @override
  String pricingSheetMarkupChip(String percent) {
    return '$percent٪';
  }

  @override
  String get pricingSheetCustomMarkupLabel => 'نسبة أخرى ٪';

  @override
  String get pricingSheetApplyMarkupTooltip => 'تطبيق النسبة';

  @override
  String get pricingSheetDerivedBadge => 'محسوب';

  @override
  String pricingSheetPackFactor(String count) {
    return 'تحتوي $count';
  }

  @override
  String pricingSheetRowCost(String cost) {
    return 'التكلفة $cost';
  }

  @override
  String get pricingSheetUnpriced => 'بدون سعر';

  @override
  String get pricingSheetBelowCost => 'أقل من التكلفة';

  @override
  String pricingSheetMargin(String profit, String percent) {
    return 'ربح $profit ($percent٪ على التكلفة)';
  }

  @override
  String pricingSheetWasPrice(String price) {
    return 'كان $price';
  }

  @override
  String get pricingSheetSetOwnPriceButton => 'سعر خاص';

  @override
  String get pricingSheetUseDerivedButton => 'احسبه تلقائيًا';

  @override
  String get pricingSheetNoChanges => 'لا تغييرات';

  @override
  String pricingSheetChangeCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count تغييرات',
      two: 'تغييران',
      one: 'تغيير واحد',
    );
    return '$_temp0';
  }

  @override
  String get pricingSheetResetButton => 'تراجع';

  @override
  String purchaseLineMargin(String profit, String percent) {
    return 'ربح $profit ($percent٪)';
  }

  @override
  String purchaseLinePackSellingPrice(String unit, String price) {
    return '$unit $price';
  }

  @override
  String purchaseLineCostPerUnitLabel(String unit) {
    return 'التكلفة / $unit';
  }

  @override
  String purchaseLineCostPerBaseHelper(String cost, String unit) {
    return '= $cost لكل $unit';
  }

  @override
  String get purchaseLineTotalEntryTooltip => 'إدخال الإجمالي بدل سعر الوحدة';

  @override
  String get purchaseLineTotalEntryTitle => 'إجمالي السطر';

  @override
  String get purchaseLineTotalEntryFieldLabel => 'الإجمالي';

  @override
  String purchaseLineTotalEntryMessage(String quantity, String unit) {
    return 'سيُقسم الإجمالي على $quantity $unit لحساب تكلفة الوحدة.';
  }

  @override
  String get purchasingShortcutsTooltip => 'اختصارات لوحة المفاتيح';

  @override
  String get purchasingShortcutsTitle => 'اختصارات الشراء';

  @override
  String get purchasingShortcutsSectionLines => 'السطور';

  @override
  String get purchasingShortcutsSectionQuantity => 'الكمية';

  @override
  String get purchasingShortcutsSectionOrder => 'أمر الشراء';

  @override
  String get purchasingShortcutCycleUnit => 'تبديل وحدة السطر المحدد';

  @override
  String get purchasingShortcutCycleUnitArrows => 'تبديل الوحدة للأمام والخلف';

  @override
  String get purchasingShortcutOpenPricing => 'تسعير المنتج في السطر المحدد';

  @override
  String get purchasingShortcutDeleteLine => 'حذف السطر المحدد (مع التراجع)';

  @override
  String get purchasingShortcutTypeQuantity => 'اكتب الكمية ثم Enter لتطبيقها';

  @override
  String get purchasingShortcutStepQuantity => 'زيادة أو إنقاص واحد';

  @override
  String get purchasingShortcutClearEntry => 'مسح ما كُتب ثم إلغاء التحديد';

  @override
  String get purchasingShortcutOpenSettings =>
      'بيانات المورد والفاتورة والتكاليف';

  @override
  String get purchasingShortcutSubmit => 'حفظ أو تسجيل أمر الشراء';

  @override
  String get purchaseDraftLineRemovedMessage => 'تم حذف السطر.';

  @override
  String get aiUiTableTotalRow => 'الإجمالي';

  @override
  String get aiUiSurfaceFailed => 'تعذّر عرض هذه البطاقة.';

  @override
  String get aiUiSurfaceFailedDetail => 'وصلت بيانات عرض غير صالحة من المساعد.';

  @override
  String get purchaseSuggestionsTitle => 'اقتراحات';

  @override
  String get purchaseSuggestionsHideTooltip => 'إخفاء الاقتراحات لهذا الأمر';

  @override
  String get purchaseSuggestionsMuteAction => 'لا تقترح هذا المنتج';

  @override
  String purchaseSuggestionMutedMessage(String product) {
    return 'لن يُقترح $product مرة أخرى.';
  }

  @override
  String purchaseSuggestionReasonOftenWith(String product) {
    return 'يُشترى عادة مع $product';
  }

  @override
  String purchaseSuggestionReasonDueAgain(num days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'اشتُري قبل $days يوم — وحان موعده',
      two: 'اشتُري قبل يومين — وحان موعده',
      one: 'اشتُري أمس — وحان موعده',
      zero: 'اشتُري اليوم — وحان موعده',
    );
    return '$_temp0';
  }

  @override
  String get purchaseSuggestionReasonUsual =>
      'من مشترياتك المعتادة من هذا المورد';

  @override
  String purchaseSuggestionEvidence(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count مرات',
      two: 'مرتان',
      one: 'مرة واحدة',
    );
    return '$_temp0 خلال آخر فترة';
  }

  @override
  String purchaseUsualBasketChip(num count) {
    return 'الطلب المعتاد · $count';
  }

  @override
  String purchaseUsualBasketFilledMessage(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'تمت إضافة $count أصناف',
      two: 'تمت إضافة صنفين',
      one: 'تمت إضافة صنف واحد',
    );
    return '$_temp0 من الطلب المعتاد.';
  }

  @override
  String purchaseSuggestionQuantityHint(String quantity, String unit) {
    return 'المعتاد $quantity $unit';
  }

  @override
  String purchaseSuggestionQuantityHintTooltip(String quantity, String unit) {
    return 'اضبط الكمية على $quantity $unit — الكمية المعتادة من هذا المورد';
  }

  @override
  String get purchasingShortcutAcceptQuantity =>
      'قبول الكمية المعتادة للسطر المحدد';

  @override
  String get enablePurchaseSuggestionsLabel => 'اقتراحات الشراء';

  @override
  String get enablePurchaseSuggestionsSubtitle =>
      'اقترح على شاشة المشتريات الأصناف والكميات التي يشتريها المحل عادة من المورد المختار.';

  @override
  String get companionSheetTitle => 'كاميرا الجوال';

  @override
  String get companionSheetSubtitle =>
      'امسح الرمز بكاميرا هاتفك ليصبح ماسحًا للرموز وكاميرا للمنتجات.';

  @override
  String get companionScanQrInstruction =>
      'افتح كاميرا الهاتف ووجّهها إلى الرمز، ثم افتح الرابط الذي يظهر.';

  @override
  String get companionCodeFallbackLabel => 'أو أدخل هذا الرمز في صفحة الكاميرا';

  @override
  String companionCodeExpiresIn(int seconds) {
    return 'ينتهي الرمز خلال $seconds ثانية';
  }

  @override
  String get companionCodeExpired => 'انتهت صلاحية الرمز';

  @override
  String get companionNewCode => 'رمز جديد';

  @override
  String get companionPairingFailed => 'تعذّر إنشاء رمز الاقتران';

  @override
  String get companionPairedDevicesTitle => 'الهواتف المقترنة';

  @override
  String get companionNoPairedDevices => 'لا يوجد هاتف مقترن بعد';

  @override
  String companionDeviceLastSeen(String time) {
    return 'آخر نشاط: $time';
  }

  @override
  String get companionUnpair => 'إلغاء الاقتران';

  @override
  String get companionPause => 'إيقاف مؤقت';

  @override
  String get companionResume => 'استئناف';

  @override
  String get companionPausedNotice =>
      'الهاتف موقوف مؤقتًا — لن تصل عمليات المسح.';

  @override
  String get companionStatusConnected => 'الهاتف متصل';

  @override
  String get companionStatusConnecting => 'جارٍ الاتصال بالهاتف…';

  @override
  String get companionStatusPolling => 'الهاتف متصل (وضع بطيء)';

  @override
  String get companionStatusIdle => 'لا يوجد هاتف مقترن';

  @override
  String get companionOpenSheetTooltip => 'كاميرا الجوال';

  @override
  String get companionScanReceived => 'وصل رمز من الهاتف';

  @override
  String get companionPhotoReceived => 'وصلت صورة من الهاتف';

  @override
  String get companionUsePhoneCamera => 'التقط بالهاتف';

  @override
  String get companionCaptureRequested => 'اطلب الصورة من الهاتف المقترن';

  @override
  String get companionCaptureWaiting => 'بانتظار الصورة من الهاتف…';

  @override
  String get companionCaptureCancel => 'إلغاء الطلب';

  @override
  String get companionCaptureFailed => 'تعذّر طلب الصورة من الهاتف';

  @override
  String companionCapturePromptProduct(String name) {
    return 'صوّر: $name';
  }

  @override
  String get companionPairFirst => 'اقترن بهاتف أولًا لاستخدام الكاميرا';

  @override
  String get migrationStepChoose => 'الملف';

  @override
  String get migrationStepUpload => 'الرفع';

  @override
  String get migrationStepPrepare => 'التحضير';

  @override
  String get migrationStepReview => 'المراجعة';

  @override
  String get migrationStepImport => 'النقل';

  @override
  String get migrationChooseTitle => 'أحضر بيانات نظامك القديم';

  @override
  String get migrationChooseSubtitle =>
      'اختر ملف قاعدة بيانات نظامك القديم وسنتولى الباقي: نقرأه، نتعرف على النظام، ننقل البيانات، ثم نحذف الملف من الخادم.';

  @override
  String get migrationPickFileButton => 'اختيار ملف';

  @override
  String get migrationChooseAnotherFile => 'اختيار ملف آخر';

  @override
  String migrationAcceptedFormats(String formats) {
    return 'الصيغ المقبولة: $formats';
  }

  @override
  String migrationMaxFileSize(String size) {
    return 'الحد الأقصى لحجم الملف: $size';
  }

  @override
  String get migrationFileTooLarge => 'هذا الملف أكبر من الحد المسموح به.';

  @override
  String get migrationWhereIsMyFileTitle => 'أين أجد هذا الملف؟';

  @override
  String get migrationWhereIsMyFileBody =>
      'الملف موجود عادةً على الجهاز الذي يعمل عليه نظامك القديم، داخل مجلد البرنامج. إن لم تجده، اسأل من ركّب لك النظام عن «ملف قاعدة البيانات». انسخه على ذاكرة USB وأحضره إلى هنا.';

  @override
  String get migrationSupportedSystemsTitle => 'الأنظمة التي نقرأها';

  @override
  String get migrationSystemDetectedAutomatically =>
      'لا حاجة لاختيار نظامك — نتعرف عليه من الملف نفسه.';

  @override
  String get migrationStartUploadButton => 'ابدأ الرفع';

  @override
  String get migrationUploadingTitle => 'جارٍ رفع الملف';

  @override
  String migrationUploadedOf(String sent, String total) {
    return '$sent من $total';
  }

  @override
  String migrationUploadRate(String rate) {
    return '$rate/ث';
  }

  @override
  String migrationUploadRemaining(String duration) {
    return 'يتبقى $duration';
  }

  @override
  String get migrationUploadResumeNote =>
      'إن انقطع الاتصال يمكنك المتابعة من حيث توقف الرفع — لن تبدأ من جديد.';

  @override
  String get migrationCancelUploadButton => 'إلغاء الرفع';

  @override
  String get migrationUploadFailedTitle => 'توقف الرفع';

  @override
  String get migrationResumeUploadButton => 'متابعة الرفع';

  @override
  String get migrationPreparingTitle => 'جارٍ تحضير البيانات';

  @override
  String get migrationPreparingSubtitle =>
      'يمكنك إغلاق هذه الصفحة والعودة لاحقًا — تستمر العملية على الخادم.';

  @override
  String get migrationPreparationFailedTitle => 'تعذر قراءة هذا الملف';

  @override
  String get migrationTryAnotherFileButton => 'تجربة ملف آخر';

  @override
  String get migrationFoundTitle => 'هذا ما وجدناه';

  @override
  String get migrationDetectedSystemLabel => 'النظام';

  @override
  String migrationHistoryRange(String from, String to) {
    return 'السجل من $from إلى $to';
  }

  @override
  String get migrationNothingToImport =>
      'لم نعثر على بيانات قابلة للنقل في هذا الملف.';

  @override
  String get migrationWhatToTransferTitle => 'ما الذي ننقله؟';

  @override
  String get migrationPreviewButton => 'معاينة قبل النقل';

  @override
  String get migrationDiscardFileButton => 'حذف الملف';

  @override
  String get migrationDiscardFileConfirm =>
      'سيُحذف الملف من الخادم ولن تتمكن من النقل منه دون رفعه مرة أخرى. هل تريد المتابعة؟';

  @override
  String get migrationDryRunningTitle => 'جارٍ فحص البيانات';

  @override
  String get migrationImportingTitle => 'جارٍ نقل البيانات';

  @override
  String get migrationDryRunCleanTitle => 'المعاينة نظيفة';

  @override
  String get migrationDryRunCleanMessage =>
      'فحصنا كل شيء دون كتابة أي بيانات. يمكنك النقل الآن.';

  @override
  String get migrationDryRunIssuesTitle => 'وجدنا مشاكل في المعاينة';

  @override
  String get migrationDoneTitle => 'تم نقل بياناتك';

  @override
  String get migrationFileDeletedNotice => 'تم حذف ملفك من الخادم.';

  @override
  String get migrationFileKeptNotice =>
      'احتفظنا بالملف مؤقتًا لتتمكن من إعادة المحاولة بعد إصلاح المشاكل.';

  @override
  String get migrationStartAnotherButton => 'نقل ملف آخر';

  @override
  String migrationRecordsImported(String count) {
    return '$count سجل';
  }

  @override
  String get warehousesTitle => 'المخازن';

  @override
  String get warehousesDrawerLabel => 'المخازن';

  @override
  String get warehousesEmptyTitle => 'لديك مكان واحد';

  @override
  String warehousesEmptyBody(String name) {
    return 'كل المخزون في $name. أضف مخزناً أو مستودعاً إذا كنت تحتفظ ببضاعة في مكان آخر.';
  }

  @override
  String get warehousesAddAction => 'إضافة مكان';

  @override
  String get warehouseEditTitle => 'تعديل المكان';

  @override
  String get warehouseCreateTitle => 'مكان جديد';

  @override
  String get warehouseNameLabel => 'الاسم';

  @override
  String get warehouseCodeLabel => 'الرمز';

  @override
  String get warehouseCodeHelp =>
      'رمز قصير بالإنجليزية، يُستخدم في التقارير ولا يتغير.';

  @override
  String get warehouseKindLabel => 'النوع';

  @override
  String get warehouseKindShopFloor => 'معرض';

  @override
  String get warehouseKindStoreRoom => 'مخزن';

  @override
  String get warehouseKindVan => 'سيارة';

  @override
  String get warehouseKindTransit => 'في الطريق';

  @override
  String get warehouseDefaultBadge => 'الافتراضي';

  @override
  String get warehouseInactiveBadge => 'غير مفعّل';

  @override
  String get warehouseActiveLabel => 'مفعّل';

  @override
  String get warehouseOversellLabel => 'البيع بدون رصيد';

  @override
  String get warehouseOversellShopDefault => 'حسب إعداد المحل';

  @override
  String get warehouseOversellAllow => 'مسموح هنا';

  @override
  String get warehouseOversellRefuse => 'ممنوع هنا';

  @override
  String warehouseProductsHeld(String count) {
    return '$count صنف بها رصيد هنا';
  }

  @override
  String get warehouseDeleteAction => 'حذف';

  @override
  String warehouseDeleteConfirmTitle(String name) {
    return 'حذف $name؟';
  }

  @override
  String get warehouseDeleteConfirmBody => 'لا يمكن التراجع عن هذا.';

  @override
  String get warehouseDeleteBlockedTitle => 'لا يمكن حذف هذا المكان';

  @override
  String get warehouseSaved => 'تم الحفظ';

  @override
  String get warehouseDeleted => 'تم حذف المكان';

  @override
  String get warehouseFilterAll => 'كل الأماكن';

  @override
  String get warehouseFilterLabel => 'المكان';

  @override
  String get warehouseStockBreakdownTitle => 'أين يوجد هذا الصنف';

  @override
  String get warehouseStockBreakdownEmpty =>
      'لا يوجد رصيد لهذا الصنف في أي مكان.';

  @override
  String warehouseCommittedShort(String value) {
    return 'محجوز $value';
  }

  @override
  String warehouseExpectedShort(String value) {
    return 'متوقع $value';
  }

  @override
  String get registerWarehouseTitle => 'المكان الذي يبيع منه هذا الصندوق';

  @override
  String get registerWarehouseBody =>
      'المبيعات تُخصم من رصيد هذا المكان، والجرد والتقارير تتبعه.';

  @override
  String get registerWarehouseUnassigned =>
      'هذا الجهاز يبيع من المكان الافتراضي للمحل.';

  @override
  String get registerWarehouseChangeAction => 'تغيير المكان';

  @override
  String registerWarehouseSaved(String name) {
    return 'هذا الصندوق يبيع الآن من $name';
  }

  @override
  String get registerWarehouseManagerOnly =>
      'تغيير مكان الصندوق يحتاج صلاحية مدير.';

  @override
  String get warehousesSectionTitle => 'المخازن والأماكن';

  @override
  String get warehousesSectionSubtitle =>
      'أين يوجد مخزونك، ومن أين يبيع كل صندوق';

  @override
  String get transfersTitle => 'التحويلات';

  @override
  String get transfersSectionTitle => 'تحويل بضاعة';

  @override
  String get transfersSectionSubtitle => 'نقل مخزون بين أماكن المحل';

  @override
  String get transfersNewAction => 'تحويل جديد';

  @override
  String get transfersEmptyTitle => 'لا توجد تحويلات';

  @override
  String get transfersEmptyBody =>
      'عندما تنقل بضاعة من مكان لآخر، ستظهر الرحلة هنا.';

  @override
  String get transfersNeedsAttention => 'في الطريق';

  @override
  String get transfersDrafts => 'مسودات';

  @override
  String get transfersSettled => 'منتهية';

  @override
  String get transferStatusDraft => 'مسودة';

  @override
  String get transferStatusInTransit => 'في الطريق';

  @override
  String get transferStatusPartial => 'وصل جزء';

  @override
  String get transferStatusReceived => 'وصلت';

  @override
  String get transferStatusCancelled => 'ملغاة';

  @override
  String transferItemsCount(String count) {
    return '$count صنف';
  }

  @override
  String transferArrivedOf(String received, String total) {
    return 'وصل $received من $total';
  }

  @override
  String get transferSendAction => 'إرسال';

  @override
  String get transferReceiveAction => 'استلام';

  @override
  String get transferCancelAction => 'إلغاء التحويل';

  @override
  String get transferCancelReasonLabel => 'سبب الإلغاء';

  @override
  String get transferCancelReasonRequired =>
      'اكتب سبباً حتى يُعرف لاحقاً لماذا رجعت البضاعة.';

  @override
  String transferSent(String name) {
    return 'البضاعة في الطريق إلى $name';
  }

  @override
  String transferReceived(String name) {
    return 'تم استلام البضاعة في $name';
  }

  @override
  String get transferCancelled => 'أُلغي التحويل ورجعت البضاعة';

  @override
  String get transferComposerTitle => 'تحويل جديد';

  @override
  String get transferFromLabel => 'من';

  @override
  String get transferToLabel => 'إلى';

  @override
  String get transferSwapTooltip => 'عكس الاتجاه';

  @override
  String get transferAddProduct => 'إضافة صنف';

  @override
  String get transferNoLinesYet => 'أضف الأصناف التي ستُنقل.';

  @override
  String transferAvailableAtSource(String value) {
    return 'متوفر: $value';
  }

  @override
  String transferExceedsSource(String name) {
    return 'أكثر مما هو موجود في $name';
  }

  @override
  String get transferNoteLabel => 'ملاحظة (اختياري)';

  @override
  String get transferSaveDraftAction => 'حفظ كمسودة';

  @override
  String get transferSendNowAction => 'إرسال الآن';

  @override
  String transferReceiveTitle(String number) {
    return 'استلام $number';
  }

  @override
  String get transferReceiveAllAction => 'وصل كل شيء';

  @override
  String get transferReceiveSomeHint => 'عدّل الكميات إذا وصل جزء فقط.';

  @override
  String get transferReceiveConfirm => 'تأكيد الاستلام';

  @override
  String get transferOnTheRoadLabel => 'على الطريق';

  @override
  String transferJourneyLabel(String source, String destination) {
    return '$source ← $destination';
  }

  @override
  String transferCancelledByLabel(String name) {
    return 'أُلغي بواسطة $name';
  }

  @override
  String get purchaseDestinationLabel => 'مكان الاستلام';

  @override
  String get purchaseDestinationHint => 'أين ستصل هذه البضاعة';

  @override
  String get purchaseDestinationSearchHint => 'ابحث عن مكان';

  @override
  String get camerasDrawerLabel => 'الكاميرات';

  @override
  String get camerasTitle => 'كاميرات المراقبة';

  @override
  String get camerasEmptyTitle => 'لا توجد كاميرات بعد';

  @override
  String get camerasEmptyBody =>
      'أضف جهاز التسجيل (DVR/NVR) من إعدادات المتجر لتظهر كاميرات المحل هنا.';

  @override
  String get camerasOpenSettingsButton => 'إعداد جهاز التسجيل';

  @override
  String get camerasLoadErrorTitle => 'تعذّر تحميل الكاميرات';

  @override
  String get camerasLayoutTooltip => 'توزيع الشاشة';

  @override
  String get camerasLayoutSingle => 'كاميرا واحدة';

  @override
  String get camerasLayoutFour => 'أربع كاميرات';

  @override
  String get camerasLayoutNine => 'تسع كاميرات';

  @override
  String get camerasRefreshTooltip => 'تحديث';

  @override
  String get camerasPauseAllTooltip => 'إيقاف البث';

  @override
  String get camerasResumeAllTooltip => 'استئناف البث';

  @override
  String get camerasPausedBanner =>
      'البث متوقف — لا يتم سحب أي فيديو من جهاز التسجيل.';

  @override
  String get cameraRenameTitle => 'تسمية الكاميرا';

  @override
  String get cameraRenameHint => 'مثال: الصندوق، الباب الأمامي، المخزن';

  @override
  String get cameraRenameAction => 'إعادة التسمية';

  @override
  String get cameraOfflineLabel => 'غير متصلة';

  @override
  String get cameraConnectingLabel => 'جارٍ الاتصال…';

  @override
  String get cameraStreamFailedLabel => 'تعذّر عرض البث';

  @override
  String get cameraRetryAction => 'إعادة المحاولة';

  @override
  String get cameraFullScreenTooltip => 'ملء الشاشة';

  @override
  String get cameraExitFullScreenTooltip => 'إنهاء ملء الشاشة';

  @override
  String get cameraSmoothModeTooltip => 'جودة أعلى (إطارات أكثر)';

  @override
  String get cameraOpenPlaybackTooltip => 'مراجعة التسجيلات';

  @override
  String get cameraSaveFrameTooltip => 'حفظ اللقطة';

  @override
  String get cameraFrameSavedMessage => 'تم حفظ اللقطة';

  @override
  String get cameraFrameSaveFailedMessage => 'تعذّر حفظ اللقطة';

  @override
  String get cameraPlaybackTitle => 'مراجعة التسجيلات';

  @override
  String get cameraPlaybackPickDateAction => 'اختيار التاريخ والوقت';

  @override
  String get cameraPlaybackJumpBack => 'رجوع';

  @override
  String get cameraPlaybackJumpForward => 'تقدّم';

  @override
  String get cameraPlaybackPlayTooltip => 'تشغيل';

  @override
  String get cameraPlaybackPauseTooltip => 'إيقاف مؤقت';

  @override
  String get cameraPlaybackSpeedLabel => 'السرعة';

  @override
  String get cameraPlaybackEndedMessage => 'انتهى المقطع';

  @override
  String get cameraPlaybackUnavailableTitle => 'المراجعة غير متاحة';

  @override
  String get cameraPlaybackUnavailableBody =>
      'خادم المتجر لا يملك أداة معالجة الفيديو المطلوبة (ffmpeg). المشاهدة المباشرة تعمل كالمعتاد.';

  @override
  String get cameraPlaybackNoFootageBody =>
      'لا يوجد تسجيل محفوظ في هذا الوقت على هذه الكاميرا.';

  @override
  String get cameraExportAction => 'تصدير المقطع';

  @override
  String get cameraExportRunningMessage => 'جارٍ تجهيز المقطع…';

  @override
  String get cameraExportSavedMessage => 'تم حفظ المقطع';

  @override
  String get cameraExportFailedMessage => 'تعذّر تصدير المقطع';

  @override
  String get cameraExportSelectionLabel => 'المقطع المحدد';

  @override
  String get cameraSelectionStartAction => 'بداية التحديد';

  @override
  String get cameraSelectionEndAction => 'نهاية التحديد';

  @override
  String get cameraSelectionClearAction => 'مسح التحديد';

  @override
  String get cameraSettingsTitle => 'الكاميرات وجهاز التسجيل';

  @override
  String get cameraSettingsSubtitle => 'ربط جهاز DVR/NVR وتسمية الكاميرات';

  @override
  String get cameraSettingsEnableTitle => 'تفعيل الكاميرات';

  @override
  String get cameraSettingsEnableSubtitle =>
      'إظهار شاشة الكاميرات ولقطة الفاتورة في التطبيق.';

  @override
  String get cameraSettingsRecordersSection => 'أجهزة التسجيل';

  @override
  String get cameraSettingsAddRecorder => 'إضافة جهاز تسجيل';

  @override
  String get cameraSettingsCamerasSection => 'الكاميرات';

  @override
  String get cameraSettingsPlaybackSection => 'لقطة الفاتورة';

  @override
  String get cameraSettingsPreRollLabel => 'ثوانٍ قبل البيع';

  @override
  String get cameraSettingsPostRollLabel => 'ثوانٍ بعد البيع';

  @override
  String get cameraSettingsCoversCheckoutLabel => 'تظهر مع الفواتير';

  @override
  String get cameraSettingsCoversCheckoutHint =>
      'اختر الكاميرات التي تصوّر الصندوق حتى تظهر في صفحة الفاتورة.';

  @override
  String get cameraSettingsCameraEnabledLabel => 'مفعّلة';

  @override
  String get cameraSettingsLiveQualityLabel => 'جودة البث المباشر';

  @override
  String get cameraSettingsPlaybackQualityLabel => 'جودة التسجيلات';

  @override
  String get cameraQualityMain => 'عالية';

  @override
  String get cameraQualitySub => 'خفيفة';

  @override
  String get cameraQualityMainHint =>
      'أوضح صورة، وحمل أكبر على الجهاز والشبكة.';

  @override
  String get cameraQualitySubHint => 'الخيار المناسب لعرض عدة كاميرات معاً.';

  @override
  String get recorderFormTitle => 'جهاز التسجيل';

  @override
  String get recorderNameLabel => 'اسم الجهاز';

  @override
  String get recorderNameHint => 'مثال: جهاز المحل';

  @override
  String get recorderBrandLabel => 'النوع';

  @override
  String get recorderBrandAuto => 'تحديد تلقائي';

  @override
  String get recorderBrandHikvision => 'Hikvision';

  @override
  String get recorderBrandDahua => 'Dahua';

  @override
  String get recorderBrandXiongmai => 'Xiongmai / XMEye';

  @override
  String get recorderBrandOnvif => 'ONVIF (أنواع أخرى)';

  @override
  String get recorderBrandGenericRtsp => 'بث مباشر RTSP (مشاهدة حية فقط)';

  @override
  String get recorderRtspTemplateLabel => 'عنوان البث (RTSP)';

  @override
  String get recorderRtspTemplateHelp =>
      'اختر قالبًا جاهزًا من الأسفل، أو اكتب العنوان بنفسك.';

  @override
  String get recorderChannelCountLabel => 'عدد الكاميرات';

  @override
  String get recorderChannelCountHelp =>
      'هذا الجهاز لا يمكن سؤاله، لذا أدخل العدد يدويًا.';

  @override
  String get recorderPresetLabel => 'قالب جاهز';

  @override
  String get recorderLiveOnlyNotice =>
      'هذا الجهاز يعرض البث الحي فقط — لا يمكن ربط الفواتير بالتسجيلات.';

  @override
  String get recorderHostLabel => 'عنوان الجهاز على الشبكة';

  @override
  String get recorderHostHint => 'مثال: 192.168.1.64';

  @override
  String get recorderPortLabel => 'منفذ الويب';

  @override
  String get recorderRtspPortLabel => 'منفذ الفيديو (RTSP)';

  @override
  String get recorderUsernameLabel => 'اسم المستخدم';

  @override
  String get recorderPasswordLabel => 'كلمة المرور';

  @override
  String get recorderPasswordKeptHint =>
      'اتركها فارغة للإبقاء على كلمة المرور المحفوظة.';

  @override
  String get recorderUseHttpsLabel => 'اتصال آمن (HTTPS)';

  @override
  String get recorderEnabledLabel => 'مفعّل';

  @override
  String get recorderTestAction => 'اختبار الاتصال';

  @override
  String get recorderTestRunningMessage => 'جارٍ الاتصال بالجهاز…';

  @override
  String get recorderTestFailedTitle => 'تعذّر الاتصال';

  @override
  String get recorderSyncAction => 'تحديث قائمة الكاميرات';

  @override
  String get recorderDeleteAction => 'حذف الجهاز';

  @override
  String get recorderDeleteConfirmTitle => 'حذف جهاز التسجيل؟';

  @override
  String get recorderDeleteConfirmBody =>
      'ستختفي كاميراته وأسماؤها من التطبيق. لن يتأثر الجهاز نفسه ولا تسجيلاته.';

  @override
  String get recorderStatusOk => 'متصل';

  @override
  String get recorderStatusError => 'فشل الاتصال';

  @override
  String get recorderStatusNever => 'لم يتم الاتصال بعد';

  @override
  String get invoiceFootageSectionTitle => 'لقطة الكاميرا';

  @override
  String get invoiceFootageSubtitle =>
      'ما سجّلته الكاميرا وقت إصدار هذه الفاتورة';

  @override
  String get invoiceFootageNoCamerasBody =>
      'لم يتم تحديد أي كاميرا تصوّر الصندوق. حدّدها من إعدادات الكاميرات.';

  @override
  String get invoiceFootageOpenAction => 'فتح المراجعة الكاملة';

  @override
  String get invoiceFootageWatchAction => 'تشغيل اللقطة';

  @override
  String cameraChannelCountLabel(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count كاميرات',
      two: 'كاميرتان',
      one: 'كاميرا واحدة',
      zero: 'لا توجد كاميرات',
    );
    return '$_temp0';
  }

  @override
  String cameraChannelLabel(String channel) {
    return 'القناة $channel';
  }

  @override
  String get cameraLiveBadge => 'مباشر';

  @override
  String get cameraWindow15Minutes => 'نافذة ١٥ دقيقة';

  @override
  String get cameraWindow1Hour => 'نافذة ساعة';

  @override
  String get cameraWindow6Hours => 'نافذة ٦ ساعات';

  @override
  String get cameraSelectionHint =>
      'اسحب طرفي الشريط لتحديد بداية المقطع ونهايته.';

  @override
  String get cameraSelectionLoopHint =>
      'يُعاد تشغيل ما بين الطرفين لتراه قبل الحفظ.';

  @override
  String get cameraExportConfirmAction => 'حفظ المقطع';

  @override
  String get cameraJumpLastHour => 'آخر ساعة';

  @override
  String get cameraJumpThreeHoursAgo => 'قبل ٣ ساعات';

  @override
  String get cameraJumpThisMorning => 'صباح اليوم';

  @override
  String get cameraJumpYesterdayEvening => 'مساء أمس';

  @override
  String get camerasLayoutLarge => 'بلاطات كبيرة';

  @override
  String get camerasLayoutMedium => 'بلاطات متوسطة';

  @override
  String get camerasLayoutSmall => 'بلاطات صغيرة';

  @override
  String get camerasTileSizeTooltip => 'حجم البلاطات';

  @override
  String get cameraOpenLiveTooltip => 'فتح الكاميرا';

  @override
  String cameraSelectionRangeLabel(String start, String end, String duration) {
    return 'من $start إلى $end · $duration';
  }

  @override
  String get recorderClockMatchesShop => 'ساعة الجهاز مطابقة لتوقيت المحل';

  @override
  String get recorderClockDiffersTitle => 'ساعة الجهاز لا تطابق توقيت المحل';

  @override
  String recorderClockDiffersBody(String minutes) {
    return 'فرق $minutes دقيقة. لقطة الفاتورة تعتمد على هذا الفرق، ونحن نطبّقه تلقائياً — لكن ضبط ساعة الجهاز على توقيت ليبيا يجعل الأمر أوضح لمن يراجع التسجيلات على شاشة الجهاز نفسه.';
  }

  @override
  String get recorderActionsMenuTooltip => 'إجراءات الجهاز';

  @override
  String get recorderScanTitle => 'البحث عن جهاز التسجيل';

  @override
  String get recorderScanRunning => 'جارٍ البحث في الشبكة…';

  @override
  String get recorderScanRetryAction => 'بحث مرة أخرى';

  @override
  String get recorderScanEmptyTitle => 'لم يُعثر على جهاز';

  @override
  String get recorderScanEmptyBody =>
      'تأكد أن جهاز التسجيل موصول بنفس الشبكة ومشغّل، أو أدخل عنوانه يدوياً بالأسفل.';

  @override
  String get recorderScanFoundHint =>
      'اختر جهازك من القائمة، وسنملأ العنوان نيابة عنك.';

  @override
  String get recorderManualSectionTitle => 'الإعداد اليدوي';

  @override
  String recorderScanFoundCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count أجهزة في الشبكة',
      two: 'جهازان في الشبكة',
      one: 'جهاز واحد في الشبكة',
    );
    return '$_temp0';
  }

  @override
  String get recorderScanIdlePrompt =>
      'اضغط «بحث مرة أخرى» للبحث عن جهاز تسجيل في الشبكة.';

  @override
  String get dashboardCamerasTitle => 'الكاميرات مباشرة';

  @override
  String get dashboardCamerasChooseTooltip => 'اختيار الكاميرات المعروضة';

  @override
  String get dashboardCamerasPickerTitle => 'كاميرات لوحة المعلومات';

  @override
  String get dashboardCamerasPickerBody =>
      'اختر ما تريد رؤيته على اللوحة في هذا الجهاز.';

  @override
  String get dashboardCamerasAutoLabel => 'اختيار تلقائي';

  @override
  String get dashboardCamerasAutoDescription =>
      'نعرض كاميرات الصندوق أولاً، وهذا ما يحدث إن لم تختر شيئاً.';

  @override
  String get dashboardCamerasResetAction => 'العودة للاختيار التلقائي';

  @override
  String get dashboardCamerasNoneSelected => 'لن تظهر أي كاميرا على اللوحة.';

  @override
  String get dashboardCamerasOpenWallAction => 'كل الكاميرات';
}
