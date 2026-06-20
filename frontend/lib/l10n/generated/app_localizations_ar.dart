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
  String get assetHistoryTitle => 'سجل الجهاز';

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
    return 'بعد نجاح النسخ يحتفظ Pointy بآخر $count نسخ ويحذف الأقدم من مجلد النسخ.';
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
  String get preventSellingAtLossLabel => 'منع البيع بخسارة';

  @override
  String get preventSellingAtLossSubtitle =>
      'عند إيقافه سيظهر تحذير للكاشير قبل إتمام بيع بخسارة.';

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
  String get detectBarcodeLabelLanguageButton => 'اكتشاف لغة طابعة الملصقات';

  @override
  String get printerLabelWidthLabel => 'عرض الملصق مم';

  @override
  String get printerLabelHeightLabel => 'ارتفاع الملصق مم';

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
  String get productImageSearchButton => 'بحث في الإنترنت';

  @override
  String get productImageClearSelectionButton => 'إلغاء الاختيار';

  @override
  String get productImagePickError => 'تعذر قراءة الصورة المختارة.';

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
  String get variantOptionsLabel => 'قوالب الخيارات';

  @override
  String get variantOptionsHelper =>
      'اختر الخيارات التي تميز المنتج مثل اللون أو السعة. سيتم استخدام قيمها لتوليد الخيارات تلقائيًا.';

  @override
  String get variantOptionsEmpty => 'لا توجد قوالب خيارات جاهزة.';

  @override
  String get variantOptionsLoadError => 'تعذر تحميل قوالب الخيارات.';

  @override
  String get addVariantOptionButton => 'إضافة قالب';

  @override
  String get newVariantOptionTitle => 'قالب خيار جديد';

  @override
  String get variantOptionNameLabel => 'اسم القالب';

  @override
  String get variantOptionNameHint => 'مثال: اللون';

  @override
  String get variantOptionCodeLabel => 'رمز القالب';

  @override
  String get variantOptionCodeHint => 'مثال: color';

  @override
  String get createVariantOptionButton => 'حفظ القالب';

  @override
  String get variantOptionCreateError => 'تعذر إنشاء قالب الخيار.';

  @override
  String get variantValuesNoOptions =>
      'اختر قالب خيار واحدًا على الأقل لتحديد القيم.';

  @override
  String get variantOptionNoValues => 'لا توجد قيم جاهزة لهذا الخيار.';

  @override
  String get variantOptionValueRequired => 'اختر قيمة واحدة على الأقل.';

  @override
  String get addVariantOptionValueButton => 'إضافة قيمة';

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
      'اختر قيمة واحدة على الأقل لكل قالب خيار.';

  @override
  String get generatedVariantsDuplicateSku =>
      'رموز الخيارات المولدة يجب أن تكون غير مكررة.';

  @override
  String get generatedVariantsTooMany =>
      'عدد الخيارات المولدة كبير جدًا. قلل القيم المحددة.';

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
  String get cameraScannerSingleTitle => 'مسح باركود';

  @override
  String get cameraScannerMultipleTitle => 'مسح عدة منتجات';

  @override
  String get cameraScannerStarting => 'جار تشغيل الكاميرا...';

  @override
  String get cameraScannerPermissionError =>
      'تعذر تشغيل الكاميرا. تحقق من صلاحية الكاميرا وحاول مرة أخرى.';

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
  String purchaseAdjustmentLineRemaining(int remaining, int quantity) {
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
    int quantity,
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
  String purchaseReceiveExpectedValue(int quantity) {
    return 'المطلوب $quantity';
  }

  @override
  String purchaseReceiveAlreadyValue(int quantity) {
    return 'استلم سابقًا $quantity';
  }

  @override
  String purchaseReceiveOpenValue(int quantity) {
    return 'المفتوح $quantity';
  }

  @override
  String purchaseReceiveOpenAfterValue(int quantity) {
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
  String purchaseOrderLineQuantity(int quantity) {
    return 'الكمية $quantity';
  }

  @override
  String purchaseLineReceivedQuantity(int quantity) {
    return 'مستلم $quantity';
  }

  @override
  String purchaseLineOpenQuantity(int quantity) {
    return 'مفتوح/متأخر $quantity';
  }

  @override
  String purchaseLineDamagedQuantity(int quantity) {
    return 'تالف $quantity';
  }

  @override
  String purchaseLineRejectedQuantity(int quantity) {
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
  String get quickCreateProductTitle => 'إضافة منتج سريع';

  @override
  String quickCreateProductMessage(String barcode) {
    return 'الباركود $barcode غير موجود. أضف المنتج الآن لمتابعة أمر الشراء.';
  }

  @override
  String get quickCreateProductNameHint => 'اسم المنتج على فاتورة المورد';

  @override
  String get quickCreateUnitCostLabel => 'تكلفة الشراء';

  @override
  String get quickCreateProductButton => 'إضافة للشراء';

  @override
  String get quickCreateProductSaving => 'جار الإضافة...';

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
      'تعذر الاتصال بجلسة الدرج. حاول مرة أخرى.';

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
  String get sessionSalesLoadError => 'تعذر تحميل مبيعات هذه الجلسة.';

  @override
  String get emptySessionSales => 'لا توجد مبيعات مسجلة في هذه الجلسة.';

  @override
  String get allCustomersFilterLabel => 'كل العملاء';

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
  String get emptyInvoices => 'لا توجد فواتير تطابق الفلاتر الحالية.';

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
  String get discountWizardAdvancedToggle => 'إظهار خيارات متقدمة';

  @override
  String get discountWizardFixStepError =>
      'راجع الخطوة المحددة وأكمل البيانات المطلوبة.';

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
  String get discountEmptyRules => 'لا توجد خصومات مطابقة.';

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
  String get expensesNoMatchingMessage => 'لا توجد بنود مطابقة للتصفية.';

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
  String get expenseDeleteTitle => 'حذف المصروف؟';

  @override
  String get expenseDeleteMessage => 'لا يمكن التراجع عن هذا الإجراء.';

  @override
  String get expenseDeleteError => 'تعذّر حذف المصروف.';

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
  String get aiAssistantDrawerLabel => 'المساعد الذكي';

  @override
  String get aiAssistantTitle => 'المساعد الذكي';

  @override
  String get aiAssistantInputHint => 'اكتب رسالتك هنا…';

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
  String get aiAssistantEmptySubtitle => 'اسأل المساعد عن أي شيء يخص متجرك.';

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
  String get aiAssistantErrorNotEntitled =>
      'المساعد الذكي غير مفعّل لهذا المتجر.';

  @override
  String get aiAssistantErrorNetwork =>
      'تعذّر الاتصال بالمساعد. تحقق من الشبكة وحاول مجددًا.';

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
}
