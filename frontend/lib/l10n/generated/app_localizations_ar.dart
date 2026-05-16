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
  String get catalogDrawerLabel => 'المنتجات';

  @override
  String get registerSessionsDrawerLabel => 'جلسات الدرج';

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
  String get shopIdentitySectionTitle => 'هوية المتجر';

  @override
  String get shopBehaviorSectionTitle => 'سلوك التطبيق';

  @override
  String get receiptSettingsSectionTitle => 'الإيصالات';

  @override
  String get registerSessionSettingsSectionTitle => 'جلسة الدرج';

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
  String registerSessionSettingsSummary(String status) {
    return 'نقدية الافتتاح: $status';
  }

  @override
  String inventorySettingsSummary(int count) {
    return 'تنبيه عند $count قطع أو أقل';
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
  String get autoPrintReceiptsLabel => 'طباعة الإيصالات تلقائيًا';

  @override
  String get lowStockThresholdLabel => 'حد تنبيه المخزون المنخفض';

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
  String get noBarcode => 'لا يوجد باركود';

  @override
  String get noDescription => 'لا يوجد وصف لهذا المنتج';

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
  String get checkoutInProgressButton => 'جار الدفع...';

  @override
  String get saleCheckoutSuccess => 'تم تسجيل البيع.';

  @override
  String saleCheckoutSuccessWithReceipt(String receiptNumber) {
    return 'تم تسجيل البيع. رقم الإيصال: $receiptNumber';
  }

  @override
  String get saleCheckoutError =>
      'تعذر تسجيل البيع. تحقق من جلسة الدرج وحاول مرة أخرى.';

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
  String get sessionSalesLoadError => 'تعذر تحميل مبيعات هذه الجلسة.';

  @override
  String get emptySessionSales => 'لا توجد مبيعات مسجلة في هذه الجلسة.';

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
}
