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
  String get displayNameLabel => 'الاسم المعروض';

  @override
  String get emailLabel => 'البريد الإلكتروني';

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
  String get fakePrintButton => 'طباعة تجريبية بالمحاكاة';

  @override
  String get printerTestSuccess => 'تم إرسال اختبار الطباعة.';

  @override
  String get printerTestFailure =>
      'تعذر اختبار الطابعة. تحقق من الاتصال والإعدادات وحاول مرة أخرى.';

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
  String get activeProductLabel => 'متاح للبيع';

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
  String get productDetailsTitle => 'تفاصيل المنتج';

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
  String stockMovementQuantityValue(int quantity) {
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
  String get barcodeLabelCopiesDialogTitle => 'طباعة ملصقات الباركود';

  @override
  String get barcodeLabelCopiesLabel => 'عدد النسخ';

  @override
  String get barcodeLabelCopiesHint => 'مثال: 10';

  @override
  String get barcodeLabelCopiesPrintButton => 'طباعة';

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
  String posVariantPickerStock(int quantity) {
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
  String get clearCartTooltip => 'مسح السلة';

  @override
  String get removeCartLineTooltip => 'حذف العنصر من السلة';

  @override
  String get emptyCart => 'لا توجد عناصر في السلة';

  @override
  String get openCartSheetButton => 'مراجعة السلة';

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
  String get emptyPurchaseDraft => 'لا توجد عناصر في مسودة الشراء';

  @override
  String get purchaseLineCostLabel => 'التكلفة';

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
  String get oversellWarningTitle => 'تنبيه المخزون';

  @override
  String get oversellWarningMessage =>
      'تتجاوز بعض عناصر السلة الكمية المتاحة. هل تريد إتمام البيع رغم ذلك؟';

  @override
  String get oversellBlockedMessage =>
      'لا يمكن إتمام البيع لأن الكمية المطلوبة تتجاوز المخزون المتاح.';

  @override
  String oversellLine(String productName, int requested, int available) {
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
  String get closingCashInputLabel => 'النقد عند الإغلاق';

  @override
  String denominationCountLabel(String denomination) {
    return 'عدد فئة $denomination';
  }

  @override
  String get cancelButton => 'إلغاء';

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
  String get sessionDenominationTotalMetric => 'إجمالي الفئات';

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
  String saleLineQuantityAndPrice(int quantity, String unitPrice) {
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
  String saleLineReturnedQuantity(int returned, int quantity) {
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
  String get addEmployeeButton => 'إضافة موظف';

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
  String get employeeNoDetails => 'لا توجد تفاصيل إضافية';

  @override
  String get addCompensationPlanTooltip => 'إضافة خطة أجر';

  @override
  String get payrollRunsLoadError => 'تعذر تحميل مسيرات الرواتب.';

  @override
  String get emptyPayrollRuns => 'لا توجد مسيرات رواتب بعد.';

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
}
