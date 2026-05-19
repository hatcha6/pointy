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
  String get registerSessionsDrawerLabel => 'جلسات الدرج';

  @override
  String get deviceSettingsDrawerLabel => 'إعدادات الجهاز';

  @override
  String get usersDrawerLabel => 'المستخدمون';

  @override
  String get settingsDrawerLabel => 'إعدادات المتجر';

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
  String get devicePrinterSectionTitle => 'الطابعة الافتراضية';

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
  String get inventorySettingsSectionTitle => 'تنبيهات المخزون';

  @override
  String get shopSettingsEmptyValue => 'غير محدد';

  @override
  String get shopSettingsEnabledValue => 'مفعل';

  @override
  String get shopSettingsDisabledValue => 'متوقف';

  @override
  String receiptSettingsSummary(String status) {
    return 'الطباعة التلقائية: $status';
  }

  @override
  String registerSessionSettingsSummary(String status, String window) {
    return 'نقدية الافتتاح: $status، صلاحية الكاشير للإرجاع: $window';
  }

  @override
  String inventorySettingsSummary(int count, String status) {
    return 'تنبيه عند $count قطع أو أقل، البيع فوق المخزون: $status';
  }

  @override
  String paymentSettingsSummary(
    num count,
    String cardCommission,
    String transferCommission,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count طرق دفع مفعلة',
      two: 'طريقتان مفعّلتان',
      one: 'طريقة دفع واحدة مفعلة',
      zero: 'لا توجد طرق دفع مفعلة',
    );
    return '$_temp0، بطاقة $cardCommission%، تحويل $transferCommission%';
  }

  @override
  String get shopNameLabel => 'اسم المتجر';

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
  String get paymentMethodCash => 'نقد';

  @override
  String get paymentMethodCard => 'بطاقة';

  @override
  String get paymentMethodTransfer => 'تحويل';

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
  String get printerTransportFake => 'محاكاة';

  @override
  String get selectedPrinterLabel => 'الطابعة الافتراضية لهذا الجهاز';

  @override
  String get noSelectedPrinter => 'لم يتم اختيار طابعة';

  @override
  String get paperWidthLabel => 'عرض الورق بالملليمتر';

  @override
  String get printerCodeTableLabel => 'جدول ترميز الطابعة';

  @override
  String get discoveredPrintersLabel => 'الطابعات المكتشفة';

  @override
  String get selectDiscoveredPrinterHint => 'اختر طابعة';

  @override
  String get noDiscoveredPrinters => 'لم يتم اكتشاف طابعات بعد';

  @override
  String get discoverPrintersButton => 'اكتشاف الطابعات';

  @override
  String get printerDiscoveryError =>
      'تعذر اكتشاف الطابعات. يمكنك إدخال بيانات الطابعة يدويًا.';

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
  String get savingSettingsButton => 'جار الحفظ...';

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
  String get activeProductLabel => 'متاح للبيع';

  @override
  String get createProductButton => 'إنشاء المنتج';

  @override
  String get creatingProductButton => 'جار الإنشاء...';

  @override
  String get requiredField => 'هذا الحقل مطلوب';

  @override
  String get invalidNumber => 'أدخل رقمًا صحيحًا';

  @override
  String get invalidDate => 'أدخل تاريخًا صحيحًا';

  @override
  String get productCreatedMessage => 'تم إنشاء المنتج';

  @override
  String get productCreateError =>
      'تعذر إنشاء المنتج. راجع البيانات وحاول مرة أخرى.';

  @override
  String get catalogLoadError => 'تعذر تحميل المنتجات من الخادم.';

  @override
  String get activeStatus => 'متاح';

  @override
  String get inactiveStatus => 'متوقف';

  @override
  String get productDetailsTitle => 'تفاصيل المنتج';

  @override
  String get productSummaryTitle => 'ملخص المنتج';

  @override
  String get productPriceTitle => 'السعر';

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
  String get savingStockMovementButton => 'جار الحفظ...';

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
  String get emptyCart => 'لا توجد عناصر في السلة';

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
  String get emptyPurchaseOrders => 'لا توجد فواتير مشتريات بعد.';

  @override
  String purchaseOrderFallbackTitle(int id) {
    return 'أمر شراء #$id';
  }

  @override
  String purchaseOrderLineCount(num count) {
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
  String get submitPurchaseOrderAction => 'إرسال';

  @override
  String get receivePurchaseOrderAction => 'تحديد كمستلم';

  @override
  String get receivePurchaseLinesAction => 'استلام كميات';

  @override
  String get cancelPurchaseOrderAction => 'إلغاء';

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
  String purchaseAdjustmentHistoryLineCount(num count) {
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
  String purchaseReceiptHistoryLineCount(num count) {
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
  String get clearPurchaseDraftTooltip => 'مسح مسودة الشراء';

  @override
  String get emptyPurchaseDraft => 'لا توجد عناصر في مسودة الشراء';

  @override
  String get purchaseLineCostLabel => 'التكلفة';

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
  String get quickCreateProductError =>
      'تعذر إنشاء المنتج. راجع البيانات وحاول مرة أخرى.';

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
  String get contactSavingButton => 'جار الحفظ...';

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
  String get retryRegisterSessionButton => 'إعادة المحاولة';

  @override
  String get openingCashInputLabel => 'نقدية الافتتاح';

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
  String get savingCashMovementButton => 'جار الحفظ...';

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
  String get saleReceiptFallback => 'بدون رقم';

  @override
  String saleReceiptTitle(String receiptNumber) {
    return 'إيصال $receiptNumber';
  }

  @override
  String saleLineCount(num count) {
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
  String get confirmButton => 'تأكيد';
}
