import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('ar')];

  /// Application title.
  ///
  /// In ar, this message translates to:
  /// **'نقطة البيع'**
  String get appTitle;

  /// No description provided for @refreshCatalogTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث المنتجات'**
  String get refreshCatalogTooltip;

  /// No description provided for @searchProductsHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث باسم المنتج أو الرمز'**
  String get searchProductsHint;

  /// No description provided for @clearSearchTooltip.
  ///
  /// In ar, this message translates to:
  /// **'مسح البحث'**
  String get clearSearchTooltip;

  /// No description provided for @openCameraScannerTooltip.
  ///
  /// In ar, this message translates to:
  /// **'فتح ماسح الكاميرا'**
  String get openCameraScannerTooltip;

  /// No description provided for @openFiltersTooltip.
  ///
  /// In ar, this message translates to:
  /// **'الفلاتر والترتيب'**
  String get openFiltersTooltip;

  /// No description provided for @filtersButtonLabel.
  ///
  /// In ar, this message translates to:
  /// **'الفلاتر'**
  String get filtersButtonLabel;

  /// No description provided for @filtersSheetTitle.
  ///
  /// In ar, this message translates to:
  /// **'الفلاتر والترتيب'**
  String get filtersSheetTitle;

  /// No description provided for @availabilityFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'حالة المنتج'**
  String get availabilityFilterTitle;

  /// No description provided for @availabilityAll.
  ///
  /// In ar, this message translates to:
  /// **'كل المنتجات'**
  String get availabilityAll;

  /// No description provided for @availabilityActive.
  ///
  /// In ar, this message translates to:
  /// **'المتاحة فقط'**
  String get availabilityActive;

  /// No description provided for @availabilityInactive.
  ///
  /// In ar, this message translates to:
  /// **'المتوقفة فقط'**
  String get availabilityInactive;

  /// No description provided for @orderingTitle.
  ///
  /// In ar, this message translates to:
  /// **'ترتيب النتائج'**
  String get orderingTitle;

  /// No description provided for @orderingName.
  ///
  /// In ar, this message translates to:
  /// **'الاسم'**
  String get orderingName;

  /// No description provided for @orderingPriceAsc.
  ///
  /// In ar, this message translates to:
  /// **'السعر: من الأقل إلى الأعلى'**
  String get orderingPriceAsc;

  /// No description provided for @orderingPriceDesc.
  ///
  /// In ar, this message translates to:
  /// **'السعر: من الأعلى إلى الأقل'**
  String get orderingPriceDesc;

  /// No description provided for @orderingNewest.
  ///
  /// In ar, this message translates to:
  /// **'الأحدث أولًا'**
  String get orderingNewest;

  /// No description provided for @resetFiltersButton.
  ///
  /// In ar, this message translates to:
  /// **'إعادة ضبط'**
  String get resetFiltersButton;

  /// No description provided for @applyFiltersButton.
  ///
  /// In ar, this message translates to:
  /// **'تطبيق'**
  String get applyFiltersButton;

  /// No description provided for @navigationMenuTooltip.
  ///
  /// In ar, this message translates to:
  /// **'فتح القائمة'**
  String get navigationMenuTooltip;

  /// No description provided for @navigationMenuTitle.
  ///
  /// In ar, this message translates to:
  /// **'القائمة'**
  String get navigationMenuTitle;

  /// No description provided for @navigationMenuSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'تنقل سريع بين شاشات نقطة البيع'**
  String get navigationMenuSubtitle;

  /// No description provided for @posDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'شاشة البيع'**
  String get posDrawerLabel;

  /// No description provided for @purchasingDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'المشتريات'**
  String get purchasingDrawerLabel;

  /// No description provided for @contactsDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'الجهات'**
  String get contactsDrawerLabel;

  /// No description provided for @catalogDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'المنتجات'**
  String get catalogDrawerLabel;

  /// No description provided for @registerSessionsDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'جلسات الدرج'**
  String get registerSessionsDrawerLabel;

  /// No description provided for @deviceSettingsDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات الجهاز'**
  String get deviceSettingsDrawerLabel;

  /// No description provided for @usersDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'المستخدمون'**
  String get usersDrawerLabel;

  /// No description provided for @settingsDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات المتجر'**
  String get settingsDrawerLabel;

  /// No description provided for @logoutButton.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الخروج'**
  String get logoutButton;

  /// No description provided for @unauthorizedTitle.
  ///
  /// In ar, this message translates to:
  /// **'غير مصرح'**
  String get unauthorizedTitle;

  /// No description provided for @unauthorizedMessage.
  ///
  /// In ar, this message translates to:
  /// **'لا يملك هذا المستخدم صلاحية الوصول إلى هذه الشاشة.'**
  String get unauthorizedMessage;

  /// No description provided for @authCheckingSession.
  ///
  /// In ar, this message translates to:
  /// **'جار فحص الجلسة...'**
  String get authCheckingSession;

  /// No description provided for @loginTitle.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الدخول'**
  String get loginTitle;

  /// No description provided for @usernameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم المستخدم'**
  String get usernameLabel;

  /// No description provided for @passwordLabel.
  ///
  /// In ar, this message translates to:
  /// **'كلمة المرور'**
  String get passwordLabel;

  /// No description provided for @loginButton.
  ///
  /// In ar, this message translates to:
  /// **'دخول'**
  String get loginButton;

  /// No description provided for @loggingInButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الدخول...'**
  String get loggingInButton;

  /// No description provided for @loginError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تسجيل الدخول. تحقق من اسم المستخدم وكلمة المرور.'**
  String get loginError;

  /// No description provided for @managerRoleLabel.
  ///
  /// In ar, this message translates to:
  /// **'مدير'**
  String get managerRoleLabel;

  /// No description provided for @cashierRoleLabel.
  ///
  /// In ar, this message translates to:
  /// **'كاشير'**
  String get cashierRoleLabel;

  /// No description provided for @usersManagementTitle.
  ///
  /// In ar, this message translates to:
  /// **'إدارة المستخدمين'**
  String get usersManagementTitle;

  /// No description provided for @refreshUsersTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث المستخدمين'**
  String get refreshUsersTooltip;

  /// No description provided for @addUserButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة مستخدم'**
  String get addUserButton;

  /// No description provided for @userCreateTitle.
  ///
  /// In ar, this message translates to:
  /// **'مستخدم جديد'**
  String get userCreateTitle;

  /// No description provided for @displayNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'الاسم المعروض'**
  String get displayNameLabel;

  /// No description provided for @emailLabel.
  ///
  /// In ar, this message translates to:
  /// **'البريد الإلكتروني'**
  String get emailLabel;

  /// No description provided for @roleLabel.
  ///
  /// In ar, this message translates to:
  /// **'الدور'**
  String get roleLabel;

  /// No description provided for @activeUserLabel.
  ///
  /// In ar, this message translates to:
  /// **'مستخدم نشط'**
  String get activeUserLabel;

  /// No description provided for @createUserButton.
  ///
  /// In ar, this message translates to:
  /// **'إنشاء المستخدم'**
  String get createUserButton;

  /// No description provided for @createUserError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إنشاء المستخدم. راجع البيانات وحاول مرة أخرى.'**
  String get createUserError;

  /// No description provided for @usersLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل المستخدمين.'**
  String get usersLoadError;

  /// No description provided for @emptyUsers.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد مستخدمون بعد.'**
  String get emptyUsers;

  /// No description provided for @userStatusActive.
  ///
  /// In ar, this message translates to:
  /// **'نشط'**
  String get userStatusActive;

  /// No description provided for @userStatusInactive.
  ///
  /// In ar, this message translates to:
  /// **'متوقف'**
  String get userStatusInactive;

  /// No description provided for @shopSettingsTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات المتجر'**
  String get shopSettingsTitle;

  /// No description provided for @refreshShopSettingsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث إعدادات المتجر'**
  String get refreshShopSettingsTooltip;

  /// No description provided for @shopSettingsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل إعدادات المتجر.'**
  String get shopSettingsLoadError;

  /// No description provided for @shopSettingsSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ إعدادات المتجر. راجع البيانات وحاول مرة أخرى.'**
  String get shopSettingsSaveError;

  /// No description provided for @shopSettingsSavedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ إعدادات المتجر.'**
  String get shopSettingsSavedMessage;

  /// No description provided for @deviceSettingsTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات الجهاز'**
  String get deviceSettingsTitle;

  /// No description provided for @refreshDeviceSettingsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث إعدادات الجهاز'**
  String get refreshDeviceSettingsTooltip;

  /// No description provided for @deviceSettingsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل إعدادات الجهاز المحلية.'**
  String get deviceSettingsLoadError;

  /// No description provided for @deviceSettingsSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ إعدادات الجهاز المحلية.'**
  String get deviceSettingsSaveError;

  /// No description provided for @devicePrinterSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'الطابعة الافتراضية'**
  String get devicePrinterSectionTitle;

  /// No description provided for @shopIdentitySectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'هوية المتجر'**
  String get shopIdentitySectionTitle;

  /// No description provided for @shopBehaviorSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'سلوك التطبيق'**
  String get shopBehaviorSectionTitle;

  /// No description provided for @receiptSettingsSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'الإيصالات'**
  String get receiptSettingsSectionTitle;

  /// No description provided for @registerSessionSettingsSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'جلسة الدرج'**
  String get registerSessionSettingsSectionTitle;

  /// No description provided for @paymentSettingsSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'طرق الدفع'**
  String get paymentSettingsSectionTitle;

  /// No description provided for @inventorySettingsSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'تنبيهات المخزون'**
  String get inventorySettingsSectionTitle;

  /// No description provided for @shopSettingsEmptyValue.
  ///
  /// In ar, this message translates to:
  /// **'غير محدد'**
  String get shopSettingsEmptyValue;

  /// No description provided for @shopSettingsEnabledValue.
  ///
  /// In ar, this message translates to:
  /// **'مفعل'**
  String get shopSettingsEnabledValue;

  /// No description provided for @shopSettingsDisabledValue.
  ///
  /// In ar, this message translates to:
  /// **'متوقف'**
  String get shopSettingsDisabledValue;

  /// Summary for receipt settings in the shop settings index.
  ///
  /// In ar, this message translates to:
  /// **'الطباعة التلقائية: {status}'**
  String receiptSettingsSummary(String status);

  /// Summary for register session settings in the shop settings index.
  ///
  /// In ar, this message translates to:
  /// **'نقدية الافتتاح: {status}، صلاحية الكاشير للإرجاع: {window}'**
  String registerSessionSettingsSummary(String status, String window);

  /// Summary for inventory settings in the shop settings index.
  ///
  /// In ar, this message translates to:
  /// **'تنبيه عند {count} قطع أو أقل، البيع فوق المخزون: {status}'**
  String inventorySettingsSummary(int count, String status);

  /// Summary for payment settings in the shop settings index.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد طرق دفع مفعلة} =1{طريقة دفع واحدة مفعلة} =2{طريقتان مفعّلتان} other{{count} طرق دفع مفعلة}}، بطاقة {cardCommission}%، تحويل {transferCommission}%'**
  String paymentSettingsSummary(
    num count,
    String cardCommission,
    String transferCommission,
  );

  /// No description provided for @shopNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم المتجر'**
  String get shopNameLabel;

  /// No description provided for @receiptHeaderLabel.
  ///
  /// In ar, this message translates to:
  /// **'ترويسة الإيصال'**
  String get receiptHeaderLabel;

  /// No description provided for @receiptFooterLabel.
  ///
  /// In ar, this message translates to:
  /// **'خاتمة الإيصال'**
  String get receiptFooterLabel;

  /// No description provided for @requireOpeningCashLabel.
  ///
  /// In ar, this message translates to:
  /// **'طلب نقدية افتتاح الجلسة'**
  String get requireOpeningCashLabel;

  /// No description provided for @cashierReturnWindowLabel.
  ///
  /// In ar, this message translates to:
  /// **'مدة صلاحية الإرجاع للكاشير'**
  String get cashierReturnWindowLabel;

  /// No description provided for @cashierReturnWindowDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'مدة صلاحية الإرجاع'**
  String get cashierReturnWindowDialogTitle;

  /// No description provided for @cashierReturnWindowDaysLabel.
  ///
  /// In ar, this message translates to:
  /// **'الأيام'**
  String get cashierReturnWindowDaysLabel;

  /// No description provided for @cashierReturnWindowHoursLabel.
  ///
  /// In ar, this message translates to:
  /// **'الساعات'**
  String get cashierReturnWindowHoursLabel;

  /// Duration value when only hours are shown.
  ///
  /// In ar, this message translates to:
  /// **'{hours} ساعة'**
  String cashierReturnWindowHoursValue(int hours);

  /// Duration value when only days are shown.
  ///
  /// In ar, this message translates to:
  /// **'{days} يوم'**
  String cashierReturnWindowDaysValue(int days);

  /// Duration value when days and hours are shown.
  ///
  /// In ar, this message translates to:
  /// **'{days} يوم و{hours} ساعة'**
  String cashierReturnWindowDaysHoursValue(int days, int hours);

  /// No description provided for @autoPrintReceiptsLabel.
  ///
  /// In ar, this message translates to:
  /// **'طباعة الإيصالات تلقائيًا'**
  String get autoPrintReceiptsLabel;

  /// No description provided for @allowOversellingLabel.
  ///
  /// In ar, this message translates to:
  /// **'السماح بالبيع فوق المخزون'**
  String get allowOversellingLabel;

  /// No description provided for @paymentMethodCash.
  ///
  /// In ar, this message translates to:
  /// **'نقد'**
  String get paymentMethodCash;

  /// No description provided for @paymentMethodCard.
  ///
  /// In ar, this message translates to:
  /// **'بطاقة'**
  String get paymentMethodCard;

  /// No description provided for @paymentMethodTransfer.
  ///
  /// In ar, this message translates to:
  /// **'تحويل'**
  String get paymentMethodTransfer;

  /// No description provided for @cardCommissionPercentLabel.
  ///
  /// In ar, this message translates to:
  /// **'عمولة البطاقة (%)'**
  String get cardCommissionPercentLabel;

  /// No description provided for @transferCommissionPercentLabel.
  ///
  /// In ar, this message translates to:
  /// **'عمولة التحويل (%)'**
  String get transferCommissionPercentLabel;

  /// No description provided for @paymentMethodsRequiredError.
  ///
  /// In ar, this message translates to:
  /// **'فعّل طريقة دفع واحدة على الأقل.'**
  String get paymentMethodsRequiredError;

  /// No description provided for @lowStockThresholdLabel.
  ///
  /// In ar, this message translates to:
  /// **'حد تنبيه المخزون المنخفض'**
  String get lowStockThresholdLabel;

  /// No description provided for @printerTransportLabel.
  ///
  /// In ar, this message translates to:
  /// **'طريقة الاتصال'**
  String get printerTransportLabel;

  /// No description provided for @printerTransportSerial.
  ///
  /// In ar, this message translates to:
  /// **'تسلسلي'**
  String get printerTransportSerial;

  /// No description provided for @printerTransportBluetooth.
  ///
  /// In ar, this message translates to:
  /// **'بلوتوث'**
  String get printerTransportBluetooth;

  /// No description provided for @printerTransportWifi.
  ///
  /// In ar, this message translates to:
  /// **'شبكة'**
  String get printerTransportWifi;

  /// No description provided for @printerTransportFake.
  ///
  /// In ar, this message translates to:
  /// **'محاكاة'**
  String get printerTransportFake;

  /// No description provided for @selectedPrinterLabel.
  ///
  /// In ar, this message translates to:
  /// **'الطابعة الافتراضية لهذا الجهاز'**
  String get selectedPrinterLabel;

  /// No description provided for @noSelectedPrinter.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم اختيار طابعة'**
  String get noSelectedPrinter;

  /// No description provided for @paperWidthLabel.
  ///
  /// In ar, this message translates to:
  /// **'عرض الورق بالملليمتر'**
  String get paperWidthLabel;

  /// No description provided for @printerCodeTableLabel.
  ///
  /// In ar, this message translates to:
  /// **'جدول ترميز الطابعة'**
  String get printerCodeTableLabel;

  /// No description provided for @discoveredPrintersLabel.
  ///
  /// In ar, this message translates to:
  /// **'الطابعات المكتشفة'**
  String get discoveredPrintersLabel;

  /// No description provided for @selectDiscoveredPrinterHint.
  ///
  /// In ar, this message translates to:
  /// **'اختر طابعة'**
  String get selectDiscoveredPrinterHint;

  /// No description provided for @noDiscoveredPrinters.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم اكتشاف طابعات بعد'**
  String get noDiscoveredPrinters;

  /// No description provided for @discoverPrintersButton.
  ///
  /// In ar, this message translates to:
  /// **'اكتشاف الطابعات'**
  String get discoverPrintersButton;

  /// No description provided for @printerDiscoveryError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر اكتشاف الطابعات. يمكنك إدخال بيانات الطابعة يدويًا.'**
  String get printerDiscoveryError;

  /// No description provided for @testPrinterButton.
  ///
  /// In ar, this message translates to:
  /// **'اختبار الطابعة'**
  String get testPrinterButton;

  /// No description provided for @testingPrinterButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الاختبار...'**
  String get testingPrinterButton;

  /// No description provided for @fakePrintButton.
  ///
  /// In ar, this message translates to:
  /// **'طباعة تجريبية بالمحاكاة'**
  String get fakePrintButton;

  /// No description provided for @printerTestSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال اختبار الطباعة.'**
  String get printerTestSuccess;

  /// No description provided for @printerTestFailure.
  ///
  /// In ar, this message translates to:
  /// **'تعذر اختبار الطابعة. تحقق من الاتصال والإعدادات وحاول مرة أخرى.'**
  String get printerTestFailure;

  /// No description provided for @printerTestUnsupported.
  ///
  /// In ar, this message translates to:
  /// **'طريقة الاتصال غير متاحة على هذا الجهاز.'**
  String get printerTestUnsupported;

  /// No description provided for @fakePrintSuccess.
  ///
  /// In ar, this message translates to:
  /// **'نجحت الطباعة التجريبية بالمحاكاة.'**
  String get fakePrintSuccess;

  /// No description provided for @fakePrintFailure.
  ///
  /// In ar, this message translates to:
  /// **'تعذرت الطباعة التجريبية بالمحاكاة.'**
  String get fakePrintFailure;

  /// No description provided for @saveSettingsButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ الإعدادات'**
  String get saveSettingsButton;

  /// No description provided for @savingSettingsButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الحفظ...'**
  String get savingSettingsButton;

  /// No description provided for @catalogTitle.
  ///
  /// In ar, this message translates to:
  /// **'المنتجات'**
  String get catalogTitle;

  /// No description provided for @catalogManagementTitle.
  ///
  /// In ar, this message translates to:
  /// **'إدارة المنتجات'**
  String get catalogManagementTitle;

  /// No description provided for @backTooltip.
  ///
  /// In ar, this message translates to:
  /// **'رجوع'**
  String get backTooltip;

  /// No description provided for @sampleCatalogNotice.
  ///
  /// In ar, this message translates to:
  /// **'يتم عرض منتجات تجريبية إلى أن يعمل الخادم.'**
  String get sampleCatalogNotice;

  /// No description provided for @emptyCatalog.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد منتجات'**
  String get emptyCatalog;

  /// No description provided for @productListTitle.
  ///
  /// In ar, this message translates to:
  /// **'قائمة المنتجات'**
  String get productListTitle;

  /// No description provided for @addProductButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة منتج'**
  String get addProductButton;

  /// No description provided for @newProductTitle.
  ///
  /// In ar, this message translates to:
  /// **'منتج جديد'**
  String get newProductTitle;

  /// No description provided for @productNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم المنتج'**
  String get productNameLabel;

  /// No description provided for @productNameHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: قهوة عربية'**
  String get productNameHint;

  /// No description provided for @skuLabel.
  ///
  /// In ar, this message translates to:
  /// **'رمز المنتج'**
  String get skuLabel;

  /// No description provided for @skuHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: COF-100'**
  String get skuHint;

  /// No description provided for @barcodeLabel.
  ///
  /// In ar, this message translates to:
  /// **'الباركود'**
  String get barcodeLabel;

  /// No description provided for @barcodeHint.
  ///
  /// In ar, this message translates to:
  /// **'اختياري'**
  String get barcodeHint;

  /// No description provided for @descriptionLabel.
  ///
  /// In ar, this message translates to:
  /// **'الوصف'**
  String get descriptionLabel;

  /// No description provided for @descriptionHint.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل قصيرة للمنتج'**
  String get descriptionHint;

  /// No description provided for @unitPriceLabel.
  ///
  /// In ar, this message translates to:
  /// **'السعر'**
  String get unitPriceLabel;

  /// No description provided for @activeProductLabel.
  ///
  /// In ar, this message translates to:
  /// **'متاح للبيع'**
  String get activeProductLabel;

  /// No description provided for @createProductButton.
  ///
  /// In ar, this message translates to:
  /// **'إنشاء المنتج'**
  String get createProductButton;

  /// No description provided for @creatingProductButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الإنشاء...'**
  String get creatingProductButton;

  /// No description provided for @requiredField.
  ///
  /// In ar, this message translates to:
  /// **'هذا الحقل مطلوب'**
  String get requiredField;

  /// No description provided for @invalidNumber.
  ///
  /// In ar, this message translates to:
  /// **'أدخل رقمًا صحيحًا'**
  String get invalidNumber;

  /// No description provided for @invalidDate.
  ///
  /// In ar, this message translates to:
  /// **'أدخل تاريخًا صحيحًا'**
  String get invalidDate;

  /// No description provided for @productCreatedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم إنشاء المنتج'**
  String get productCreatedMessage;

  /// No description provided for @productCreateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إنشاء المنتج. راجع البيانات وحاول مرة أخرى.'**
  String get productCreateError;

  /// No description provided for @catalogLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل المنتجات من الخادم.'**
  String get catalogLoadError;

  /// No description provided for @activeStatus.
  ///
  /// In ar, this message translates to:
  /// **'متاح'**
  String get activeStatus;

  /// No description provided for @inactiveStatus.
  ///
  /// In ar, this message translates to:
  /// **'متوقف'**
  String get inactiveStatus;

  /// No description provided for @productDetailsTitle.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل المنتج'**
  String get productDetailsTitle;

  /// No description provided for @productSummaryTitle.
  ///
  /// In ar, this message translates to:
  /// **'ملخص المنتج'**
  String get productSummaryTitle;

  /// No description provided for @productPriceTitle.
  ///
  /// In ar, this message translates to:
  /// **'السعر'**
  String get productPriceTitle;

  /// No description provided for @productIdentifierTitle.
  ///
  /// In ar, this message translates to:
  /// **'بيانات التعريف'**
  String get productIdentifierTitle;

  /// No description provided for @productDescriptionTitle.
  ///
  /// In ar, this message translates to:
  /// **'الوصف'**
  String get productDescriptionTitle;

  /// No description provided for @productAvailabilityTitle.
  ///
  /// In ar, this message translates to:
  /// **'حالة البيع'**
  String get productAvailabilityTitle;

  /// No description provided for @productAvailableForSale.
  ///
  /// In ar, this message translates to:
  /// **'هذا المنتج متاح للبيع في نقطة البيع.'**
  String get productAvailableForSale;

  /// No description provided for @productUnavailableForSale.
  ///
  /// In ar, this message translates to:
  /// **'هذا المنتج متوقف ولا يظهر للبيع.'**
  String get productUnavailableForSale;

  /// No description provided for @stockSummaryTitle.
  ///
  /// In ar, this message translates to:
  /// **'المخزون'**
  String get stockSummaryTitle;

  /// No description provided for @stockOnHandLabel.
  ///
  /// In ar, this message translates to:
  /// **'المتاح'**
  String get stockOnHandLabel;

  /// No description provided for @stockLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل المخزون.'**
  String get stockLoadError;

  /// No description provided for @stockMovementsButton.
  ///
  /// In ar, this message translates to:
  /// **'حركات المخزون'**
  String get stockMovementsButton;

  /// No description provided for @stockMovementsTitle.
  ///
  /// In ar, this message translates to:
  /// **'حركات المخزون'**
  String get stockMovementsTitle;

  /// No description provided for @emptyStockMovements.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد حركات مخزون لهذا المنتج.'**
  String get emptyStockMovements;

  /// No description provided for @stockMovementLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل حركات المخزون.'**
  String get stockMovementLoadError;

  /// No description provided for @newStockMovementButton.
  ///
  /// In ar, this message translates to:
  /// **'حركة مخزون جديدة'**
  String get newStockMovementButton;

  /// No description provided for @newStockMovementTitle.
  ///
  /// In ar, this message translates to:
  /// **'حركة مخزون جديدة'**
  String get newStockMovementTitle;

  /// No description provided for @stockMovementTypeLabel.
  ///
  /// In ar, this message translates to:
  /// **'نوع الحركة'**
  String get stockMovementTypeLabel;

  /// No description provided for @stockMovementQuantityLabel.
  ///
  /// In ar, this message translates to:
  /// **'الكمية'**
  String get stockMovementQuantityLabel;

  /// No description provided for @stockMovementNoteLabel.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظة'**
  String get stockMovementNoteLabel;

  /// No description provided for @saveStockMovementButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ الحركة'**
  String get saveStockMovementButton;

  /// No description provided for @savingStockMovementButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الحفظ...'**
  String get savingStockMovementButton;

  /// No description provided for @stockMovementCreateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ حركة المخزون. راجع الكمية وحاول مرة أخرى.'**
  String get stockMovementCreateError;

  /// No description provided for @stockMovementIncrease.
  ///
  /// In ar, this message translates to:
  /// **'زيادة المخزون'**
  String get stockMovementIncrease;

  /// No description provided for @stockMovementDecrease.
  ///
  /// In ar, this message translates to:
  /// **'نقص المخزون'**
  String get stockMovementDecrease;

  /// No description provided for @stockMovementDamaged.
  ///
  /// In ar, this message translates to:
  /// **'تالف'**
  String get stockMovementDamaged;

  /// Quantity shown on a stock movement row.
  ///
  /// In ar, this message translates to:
  /// **'{quantity} قطعة'**
  String stockMovementQuantityValue(int quantity);

  /// No description provided for @barcodeLabelPrintTitle.
  ///
  /// In ar, this message translates to:
  /// **'طباعة ملصق الباركود'**
  String get barcodeLabelPrintTitle;

  /// No description provided for @barcodeLabelPrintButton.
  ///
  /// In ar, this message translates to:
  /// **'طباعة ملصقات'**
  String get barcodeLabelPrintButton;

  /// No description provided for @barcodeLabelPrintInProgressButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الطباعة...'**
  String get barcodeLabelPrintInProgressButton;

  /// No description provided for @barcodeLabelPrintNoBarcode.
  ///
  /// In ar, this message translates to:
  /// **'أضف باركودًا للمنتج قبل طباعة الملصق.'**
  String get barcodeLabelPrintNoBarcode;

  /// No description provided for @barcodeLabelCopiesDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'طباعة ملصقات الباركود'**
  String get barcodeLabelCopiesDialogTitle;

  /// No description provided for @barcodeLabelCopiesLabel.
  ///
  /// In ar, this message translates to:
  /// **'عدد النسخ'**
  String get barcodeLabelCopiesLabel;

  /// No description provided for @barcodeLabelCopiesHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: 10'**
  String get barcodeLabelCopiesHint;

  /// No description provided for @barcodeLabelCopiesPrintButton.
  ///
  /// In ar, this message translates to:
  /// **'طباعة'**
  String get barcodeLabelCopiesPrintButton;

  /// Message shown after barcode label copies are sent to the printer.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{تم إرسال ملصق باركود واحد للطابعة.} =2{تم إرسال ملصقي باركود للطابعة.} other{تم إرسال {count} ملصقات باركود للطابعة.}}'**
  String barcodeLabelPrintSuccess(num count);

  /// No description provided for @barcodeLabelPrintError.
  ///
  /// In ar, this message translates to:
  /// **'تعذرت طباعة ملصق الباركود. تحقق من إعدادات الطابعة.'**
  String get barcodeLabelPrintError;

  /// No description provided for @noBarcode.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد باركود'**
  String get noBarcode;

  /// No description provided for @noDescription.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد وصف لهذا المنتج'**
  String get noDescription;

  /// No description provided for @posProductLookupHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن منتج أو امسح الباركود'**
  String get posProductLookupHint;

  /// No description provided for @clearBarcodeStatusTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إخفاء حالة الباركود'**
  String get clearBarcodeStatusTooltip;

  /// No description provided for @barcodeScanResolving.
  ///
  /// In ar, this message translates to:
  /// **'جار البحث عن الباركود...'**
  String get barcodeScanResolving;

  /// Status shown after a barcode scan adds a product to the cart.
  ///
  /// In ar, this message translates to:
  /// **'تمت إضافة {productName}'**
  String barcodeScanAdded(String productName);

  /// Status shown when a barcode scan does not match a product.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم العثور على منتج للباركود {barcode}'**
  String barcodeScanNotFound(String barcode);

  /// No description provided for @barcodeScanError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر البحث عن الباركود. حاول مرة أخرى.'**
  String get barcodeScanError;

  /// No description provided for @cameraScannerSingleTitle.
  ///
  /// In ar, this message translates to:
  /// **'مسح باركود'**
  String get cameraScannerSingleTitle;

  /// No description provided for @cameraScannerMultipleTitle.
  ///
  /// In ar, this message translates to:
  /// **'مسح عدة منتجات'**
  String get cameraScannerMultipleTitle;

  /// No description provided for @cameraScannerStarting.
  ///
  /// In ar, this message translates to:
  /// **'جار تشغيل الكاميرا...'**
  String get cameraScannerStarting;

  /// No description provided for @cameraScannerPermissionError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تشغيل الكاميرا. تحقق من صلاحية الكاميرا وحاول مرة أخرى.'**
  String get cameraScannerPermissionError;

  /// Status shown while camera scanner resolves a barcode into a product.
  ///
  /// In ar, this message translates to:
  /// **'جار البحث عن منتج للباركود {barcode}...'**
  String cameraScannerResolvingProduct(String barcode);

  /// No description provided for @cameraScannerScanQuantityLabel.
  ///
  /// In ar, this message translates to:
  /// **'كمية كل مسح'**
  String get cameraScannerScanQuantityLabel;

  /// No description provided for @cameraScannerEmptyScans.
  ///
  /// In ar, this message translates to:
  /// **'وجّه الكاميرا نحو الباركود أو رمز QR.'**
  String get cameraScannerEmptyScans;

  /// No description provided for @cameraScannerDoneButton.
  ///
  /// In ar, this message translates to:
  /// **'اعتماد المسح'**
  String get cameraScannerDoneButton;

  /// Quantity shown for a scanned camera barcode entry.
  ///
  /// In ar, this message translates to:
  /// **'الكمية: {quantity}'**
  String cameraScannerQuantityValue(int quantity);

  /// No description provided for @removeScannedCodeTooltip.
  ///
  /// In ar, this message translates to:
  /// **'حذف الرمز الممسوح'**
  String get removeScannedCodeTooltip;

  /// No description provided for @switchCameraTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تبديل الكاميرا'**
  String get switchCameraTooltip;

  /// No description provided for @toggleTorchTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تشغيل أو إيقاف الفلاش'**
  String get toggleTorchTooltip;

  /// No description provided for @currentSaleTitle.
  ///
  /// In ar, this message translates to:
  /// **'البيع الحالي'**
  String get currentSaleTitle;

  /// No description provided for @clearCartTooltip.
  ///
  /// In ar, this message translates to:
  /// **'مسح السلة'**
  String get clearCartTooltip;

  /// No description provided for @emptyCart.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عناصر في السلة'**
  String get emptyCart;

  /// No description provided for @purchasingTitle.
  ///
  /// In ar, this message translates to:
  /// **'المشتريات'**
  String get purchasingTitle;

  /// No description provided for @purchaseOrdersTitle.
  ///
  /// In ar, this message translates to:
  /// **'فواتير المشتريات'**
  String get purchaseOrdersTitle;

  /// No description provided for @refreshPurchaseOrdersTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث فواتير المشتريات'**
  String get refreshPurchaseOrdersTooltip;

  /// No description provided for @refreshPurchaseOrderDetailsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث تفاصيل أمر الشراء'**
  String get refreshPurchaseOrderDetailsTooltip;

  /// No description provided for @newPurchaseOrderButton.
  ///
  /// In ar, this message translates to:
  /// **'أمر شراء جديد'**
  String get newPurchaseOrderButton;

  /// No description provided for @newPurchaseOrderTitle.
  ///
  /// In ar, this message translates to:
  /// **'أمر شراء جديد'**
  String get newPurchaseOrderTitle;

  /// No description provided for @searchPurchaseOrdersHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث برقم الفاتورة أو المورد أو المنتج'**
  String get searchPurchaseOrdersHint;

  /// No description provided for @purchaseOrderSupplierFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'المورد'**
  String get purchaseOrderSupplierFilterTitle;

  /// No description provided for @allSuppliersFilterLabel.
  ///
  /// In ar, this message translates to:
  /// **'كل الموردين'**
  String get allSuppliersFilterLabel;

  /// No description provided for @clearSupplierFilterTooltip.
  ///
  /// In ar, this message translates to:
  /// **'مسح فلتر المورد'**
  String get clearSupplierFilterTooltip;

  /// No description provided for @purchaseOrderStatusFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'حالة أمر الشراء'**
  String get purchaseOrderStatusFilterTitle;

  /// No description provided for @purchaseOrderStatusAll.
  ///
  /// In ar, this message translates to:
  /// **'كل أوامر الشراء'**
  String get purchaseOrderStatusAll;

  /// No description provided for @purchaseOrderStatusDraft.
  ///
  /// In ar, this message translates to:
  /// **'مسودة'**
  String get purchaseOrderStatusDraft;

  /// No description provided for @purchaseOrderStatusSubmitted.
  ///
  /// In ar, this message translates to:
  /// **'مرسل'**
  String get purchaseOrderStatusSubmitted;

  /// No description provided for @purchaseOrderStatusReceived.
  ///
  /// In ar, this message translates to:
  /// **'مستلم'**
  String get purchaseOrderStatusReceived;

  /// No description provided for @purchaseOrderStatusCancelled.
  ///
  /// In ar, this message translates to:
  /// **'ملغى'**
  String get purchaseOrderStatusCancelled;

  /// No description provided for @purchaseOrderOrderingNewest.
  ///
  /// In ar, this message translates to:
  /// **'الأحدث أولًا'**
  String get purchaseOrderOrderingNewest;

  /// No description provided for @purchaseOrderOrderingUpdated.
  ///
  /// In ar, this message translates to:
  /// **'آخر تحديث'**
  String get purchaseOrderOrderingUpdated;

  /// No description provided for @purchaseOrderOrderingTotalDesc.
  ///
  /// In ar, this message translates to:
  /// **'الإجمالي: من الأعلى إلى الأقل'**
  String get purchaseOrderOrderingTotalDesc;

  /// No description provided for @purchaseOrderOrderingNumber.
  ///
  /// In ar, this message translates to:
  /// **'رقم أمر الشراء'**
  String get purchaseOrderOrderingNumber;

  /// No description provided for @purchaseOrdersLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل فواتير المشتريات.'**
  String get purchaseOrdersLoadError;

  /// No description provided for @purchaseOrderDetailsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل تفاصيل أمر الشراء.'**
  String get purchaseOrderDetailsLoadError;

  /// No description provided for @emptyPurchaseOrders.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد فواتير مشتريات بعد.'**
  String get emptyPurchaseOrders;

  /// Fallback purchase order title when the generated order number is unavailable.
  ///
  /// In ar, this message translates to:
  /// **'أمر شراء #{id}'**
  String purchaseOrderFallbackTitle(int id);

  /// Line count label shown in a purchase order list item.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد عناصر} =1{عنصر واحد} =2{عنصران} other{{count} عناصر}}'**
  String purchaseOrderLineCount(num count);

  /// No description provided for @purchaseOrderDetailsSummaryTitle.
  ///
  /// In ar, this message translates to:
  /// **'ملخص أمر الشراء'**
  String get purchaseOrderDetailsSummaryTitle;

  /// No description provided for @purchaseOrderLineCountLabel.
  ///
  /// In ar, this message translates to:
  /// **'العناصر'**
  String get purchaseOrderLineCountLabel;

  /// No description provided for @purchaseOrderCreatedAtLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الإنشاء'**
  String get purchaseOrderCreatedAtLabel;

  /// No description provided for @purchaseOrderSubmittedAtLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الإرسال'**
  String get purchaseOrderSubmittedAtLabel;

  /// No description provided for @purchaseOrderReceivedAtLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الاستلام'**
  String get purchaseOrderReceivedAtLabel;

  /// No description provided for @purchaseOrderActionsTitle.
  ///
  /// In ar, this message translates to:
  /// **'إجراءات الحالة'**
  String get purchaseOrderActionsTitle;

  /// No description provided for @submitPurchaseOrderAction.
  ///
  /// In ar, this message translates to:
  /// **'إرسال'**
  String get submitPurchaseOrderAction;

  /// No description provided for @receivePurchaseOrderAction.
  ///
  /// In ar, this message translates to:
  /// **'تحديد كمستلم'**
  String get receivePurchaseOrderAction;

  /// No description provided for @cancelPurchaseOrderAction.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء'**
  String get cancelPurchaseOrderAction;

  /// No description provided for @purchaseOrderAdjustmentsTitle.
  ///
  /// In ar, this message translates to:
  /// **'المرتجعات والاستبدالات'**
  String get purchaseOrderAdjustmentsTitle;

  /// No description provided for @returnPurchaseItemsAction.
  ///
  /// In ar, this message translates to:
  /// **'إرجاع'**
  String get returnPurchaseItemsAction;

  /// No description provided for @refundPurchaseItemsAction.
  ///
  /// In ar, this message translates to:
  /// **'استرداد'**
  String get refundPurchaseItemsAction;

  /// No description provided for @exchangePurchaseItemsAction.
  ///
  /// In ar, this message translates to:
  /// **'استبدال'**
  String get exchangePurchaseItemsAction;

  /// No description provided for @purchaseOrderStatusChangeError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تغيير حالة أمر الشراء. حاول مرة أخرى.'**
  String get purchaseOrderStatusChangeError;

  /// No description provided for @purchaseOrderAdjustmentError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تسجيل تعديل المشتريات. راجع الكميات والمخزون وحاول مرة أخرى.'**
  String get purchaseOrderAdjustmentError;

  /// No description provided for @purchaseReturnTitle.
  ///
  /// In ar, this message translates to:
  /// **'إرجاع مشتريات'**
  String get purchaseReturnTitle;

  /// No description provided for @purchaseRefundTitle.
  ///
  /// In ar, this message translates to:
  /// **'استرداد مشتريات'**
  String get purchaseRefundTitle;

  /// No description provided for @purchaseExchangeTitle.
  ///
  /// In ar, this message translates to:
  /// **'استبدال مشتريات'**
  String get purchaseExchangeTitle;

  /// No description provided for @purchaseAdjustmentReasonLabel.
  ///
  /// In ar, this message translates to:
  /// **'سبب التعديل'**
  String get purchaseAdjustmentReasonLabel;

  /// No description provided for @purchaseAdjustmentReasonHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: تالف، خطأ في الفاتورة، استبدال مع المورد'**
  String get purchaseAdjustmentReasonHint;

  /// No description provided for @purchaseNoAdjustableItems.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عناصر قابلة للتعديل.'**
  String get purchaseNoAdjustableItems;

  /// No description provided for @purchaseAdjustmentNoItemsSelected.
  ///
  /// In ar, this message translates to:
  /// **'اختر عنصرًا واحدًا على الأقل.'**
  String get purchaseAdjustmentNoItemsSelected;

  /// Message shown after returning purchase items.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل إرجاع المشتريات رقم {orderNumber}.'**
  String purchaseReturnSuccess(String orderNumber);

  /// Message shown after refunding purchase items.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل استرداد المشتريات رقم {orderNumber}.'**
  String purchaseRefundSuccess(String orderNumber);

  /// Message shown after exchanging purchase items.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل استبدال المشتريات رقم {orderNumber}.'**
  String purchaseExchangeSuccess(String orderNumber);

  /// Remaining adjustable purchase line quantity.
  ///
  /// In ar, this message translates to:
  /// **'المتبقي {remaining} من {quantity}'**
  String purchaseAdjustmentLineRemaining(int remaining, int quantity);

  /// No description provided for @purchaseAdjustmentHistoryEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مرتجعات أو استبدالات مسجلة.'**
  String get purchaseAdjustmentHistoryEmpty;

  /// No description provided for @purchaseAdjustmentTypeReturn.
  ///
  /// In ar, this message translates to:
  /// **'إرجاع'**
  String get purchaseAdjustmentTypeReturn;

  /// No description provided for @purchaseAdjustmentTypeRefund.
  ///
  /// In ar, this message translates to:
  /// **'استرداد'**
  String get purchaseAdjustmentTypeRefund;

  /// No description provided for @purchaseAdjustmentTypeExchange.
  ///
  /// In ar, this message translates to:
  /// **'استبدال'**
  String get purchaseAdjustmentTypeExchange;

  /// Line count label for a purchase adjustment history item.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد عناصر} =1{عنصر واحد} =2{عنصران} other{{count} عناصر}}'**
  String purchaseAdjustmentHistoryLineCount(num count);

  /// Message shown after a purchase order is submitted from details.
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال أمر الشراء رقم {orderNumber}.'**
  String purchaseOrderSubmitSuccess(String orderNumber);

  /// Message shown after a purchase order is received.
  ///
  /// In ar, this message translates to:
  /// **'تم استلام أمر الشراء رقم {orderNumber}.'**
  String purchaseOrderReceiveSuccess(String orderNumber);

  /// Message shown after a purchase order is cancelled.
  ///
  /// In ar, this message translates to:
  /// **'تم إلغاء أمر الشراء رقم {orderNumber}.'**
  String purchaseOrderCancelSuccess(String orderNumber);

  /// No description provided for @purchaseOrderLinesTitle.
  ///
  /// In ar, this message translates to:
  /// **'محتويات أمر الشراء'**
  String get purchaseOrderLinesTitle;

  /// No description provided for @purchaseOrderUnknownProduct.
  ///
  /// In ar, this message translates to:
  /// **'منتج غير محدد'**
  String get purchaseOrderUnknownProduct;

  /// Purchase order line quantity label.
  ///
  /// In ar, this message translates to:
  /// **'الكمية {quantity}'**
  String purchaseOrderLineQuantity(int quantity);

  /// Previous product purchase cost shown on a purchase order line.
  ///
  /// In ar, this message translates to:
  /// **'آخر تكلفة {amount}'**
  String purchaseOrderPreviousCostValue(String amount);

  /// Purchase order line cost change compared with the previous cost.
  ///
  /// In ar, this message translates to:
  /// **'تغير التكلفة {amount}'**
  String purchaseOrderCostChangeValue(String amount);

  /// Purchase order line cost change percent.
  ///
  /// In ar, this message translates to:
  /// **'{percent}%'**
  String purchaseOrderCostChangePercentValue(String percent);

  /// No description provided for @purchaseCatalogTitle.
  ///
  /// In ar, this message translates to:
  /// **'كتالوج الشراء'**
  String get purchaseCatalogTitle;

  /// No description provided for @purchaseProductLookupHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن منتج لإضافته للمشتريات'**
  String get purchaseProductLookupHint;

  /// No description provided for @purchaseDraftTitle.
  ///
  /// In ar, this message translates to:
  /// **'مسودة الشراء'**
  String get purchaseDraftTitle;

  /// No description provided for @clearPurchaseDraftTooltip.
  ///
  /// In ar, this message translates to:
  /// **'مسح مسودة الشراء'**
  String get clearPurchaseDraftTooltip;

  /// No description provided for @emptyPurchaseDraft.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عناصر في مسودة الشراء'**
  String get emptyPurchaseDraft;

  /// No description provided for @purchaseLineCostLabel.
  ///
  /// In ar, this message translates to:
  /// **'التكلفة'**
  String get purchaseLineCostLabel;

  /// No description provided for @receivePurchaseImmediatelyLabel.
  ///
  /// In ar, this message translates to:
  /// **'استلام أمر الشراء فورًا'**
  String get receivePurchaseImmediatelyLabel;

  /// No description provided for @quickCreateProductTitle.
  ///
  /// In ar, this message translates to:
  /// **'إضافة منتج سريع'**
  String get quickCreateProductTitle;

  /// Explains that a scanned barcode is missing and can be created quickly.
  ///
  /// In ar, this message translates to:
  /// **'الباركود {barcode} غير موجود. أضف المنتج الآن لمتابعة أمر الشراء.'**
  String quickCreateProductMessage(String barcode);

  /// No description provided for @quickCreateProductNameHint.
  ///
  /// In ar, this message translates to:
  /// **'اسم المنتج على فاتورة المورد'**
  String get quickCreateProductNameHint;

  /// No description provided for @quickCreateUnitCostLabel.
  ///
  /// In ar, this message translates to:
  /// **'تكلفة الشراء'**
  String get quickCreateUnitCostLabel;

  /// No description provided for @quickCreateProductButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة للشراء'**
  String get quickCreateProductButton;

  /// No description provided for @quickCreateProductSaving.
  ///
  /// In ar, this message translates to:
  /// **'جار الإضافة...'**
  String get quickCreateProductSaving;

  /// No description provided for @quickCreateProductError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إنشاء المنتج. راجع البيانات وحاول مرة أخرى.'**
  String get quickCreateProductError;

  /// Submit purchase order button label with total amount.
  ///
  /// In ar, this message translates to:
  /// **'إرسال أمر الشراء {amount}'**
  String submitPurchaseDraftButton(String amount);

  /// No description provided for @purchaseSubmitInProgressButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الإرسال...'**
  String get purchaseSubmitInProgressButton;

  /// Message shown after a purchase order is submitted.
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال أمر الشراء رقم {draftNumber}.'**
  String purchaseDraftSubmitSuccess(String draftNumber);

  /// No description provided for @purchaseDraftSubmitError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إرسال أمر الشراء. راجع العناصر وحاول مرة أخرى.'**
  String get purchaseDraftSubmitError;

  /// No description provided for @contactsTitle.
  ///
  /// In ar, this message translates to:
  /// **'العملاء والموردون'**
  String get contactsTitle;

  /// No description provided for @customersTab.
  ///
  /// In ar, this message translates to:
  /// **'العملاء'**
  String get customersTab;

  /// No description provided for @suppliersTab.
  ///
  /// In ar, this message translates to:
  /// **'الموردون'**
  String get suppliersTab;

  /// No description provided for @refreshContactsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث العملاء والموردين'**
  String get refreshContactsTooltip;

  /// No description provided for @contactSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث بالاسم أو الهاتف أو البريد'**
  String get contactSearchHint;

  /// No description provided for @contactsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل العملاء والموردين.'**
  String get contactsLoadError;

  /// No description provided for @emptyCustomers.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد عملاء بعد.'**
  String get emptyCustomers;

  /// No description provided for @emptySuppliers.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد موردون بعد.'**
  String get emptySuppliers;

  /// No description provided for @addCustomerButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة عميل'**
  String get addCustomerButton;

  /// No description provided for @addSupplierButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة مورد'**
  String get addSupplierButton;

  /// No description provided for @customerFullNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم العميل'**
  String get customerFullNameLabel;

  /// No description provided for @supplierNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم المورد'**
  String get supplierNameLabel;

  /// No description provided for @contactPersonLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم جهة التواصل'**
  String get contactPersonLabel;

  /// No description provided for @phoneOptionalLabel.
  ///
  /// In ar, this message translates to:
  /// **'رقم الهاتف (اختياري)'**
  String get phoneOptionalLabel;

  /// No description provided for @emailOptionalLabel.
  ///
  /// In ar, this message translates to:
  /// **'البريد الإلكتروني (اختياري)'**
  String get emailOptionalLabel;

  /// No description provided for @birthdayOptionalLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الميلاد (اختياري)'**
  String get birthdayOptionalLabel;

  /// No description provided for @birthdayHint.
  ///
  /// In ar, this message translates to:
  /// **'YYYY-MM-DD'**
  String get birthdayHint;

  /// No description provided for @genderLabel.
  ///
  /// In ar, this message translates to:
  /// **'الجنس'**
  String get genderLabel;

  /// No description provided for @genderUnspecified.
  ///
  /// In ar, this message translates to:
  /// **'غير محدد'**
  String get genderUnspecified;

  /// No description provided for @genderFemale.
  ///
  /// In ar, this message translates to:
  /// **'أنثى'**
  String get genderFemale;

  /// No description provided for @genderMale.
  ///
  /// In ar, this message translates to:
  /// **'ذكر'**
  String get genderMale;

  /// No description provided for @genderNonBinary.
  ///
  /// In ar, this message translates to:
  /// **'غير ثنائي'**
  String get genderNonBinary;

  /// No description provided for @genderPreferNotToSay.
  ///
  /// In ar, this message translates to:
  /// **'يفضل عدم الإفصاح'**
  String get genderPreferNotToSay;

  /// No description provided for @marketingConsentLabel.
  ///
  /// In ar, this message translates to:
  /// **'وافق على التواصل التسويقي'**
  String get marketingConsentLabel;

  /// No description provided for @addressOptionalLabel.
  ///
  /// In ar, this message translates to:
  /// **'العنوان (اختياري)'**
  String get addressOptionalLabel;

  /// No description provided for @notesOptionalLabel.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظات (اختياري)'**
  String get notesOptionalLabel;

  /// No description provided for @activeContactLabel.
  ///
  /// In ar, this message translates to:
  /// **'نشط'**
  String get activeContactLabel;

  /// No description provided for @saveCustomerButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ العميل'**
  String get saveCustomerButton;

  /// No description provided for @saveSupplierButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ المورد'**
  String get saveSupplierButton;

  /// No description provided for @contactSavingButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الحفظ...'**
  String get contactSavingButton;

  /// No description provided for @customerCreateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ العميل. راجع البيانات وحاول مرة أخرى.'**
  String get customerCreateError;

  /// No description provided for @supplierCreateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ المورد. راجع البيانات وحاول مرة أخرى.'**
  String get supplierCreateError;

  /// No description provided for @customerNumberLabel.
  ///
  /// In ar, this message translates to:
  /// **'رقم العميل'**
  String get customerNumberLabel;

  /// No description provided for @customerBirthdayLabel.
  ///
  /// In ar, this message translates to:
  /// **'الميلاد'**
  String get customerBirthdayLabel;

  /// No description provided for @marketingAllowedLabel.
  ///
  /// In ar, this message translates to:
  /// **'يسمح بالتسويق'**
  String get marketingAllowedLabel;

  /// No description provided for @inactiveContactLabel.
  ///
  /// In ar, this message translates to:
  /// **'غير نشط'**
  String get inactiveContactLabel;

  /// No description provided for @supplierContactLabel.
  ///
  /// In ar, this message translates to:
  /// **'جهة التواصل'**
  String get supplierContactLabel;

  /// No description provided for @selectedCustomerLabel.
  ///
  /// In ar, this message translates to:
  /// **'العميل'**
  String get selectedCustomerLabel;

  /// No description provided for @selectedSupplierLabel.
  ///
  /// In ar, this message translates to:
  /// **'المورد'**
  String get selectedSupplierLabel;

  /// No description provided for @walkInCustomerLabel.
  ///
  /// In ar, this message translates to:
  /// **'عميل عابر'**
  String get walkInCustomerLabel;

  /// No description provided for @noSupplierSelectedLabel.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد مورد محدد'**
  String get noSupplierSelectedLabel;

  /// No description provided for @chooseCustomerTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختيار العميل'**
  String get chooseCustomerTitle;

  /// No description provided for @chooseSupplierTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختيار المورد'**
  String get chooseSupplierTitle;

  /// No description provided for @changeContactAction.
  ///
  /// In ar, this message translates to:
  /// **'تغيير'**
  String get changeContactAction;

  /// No description provided for @clearContactTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إزالة الاختيار'**
  String get clearContactTooltip;

  /// No description provided for @createNewCustomerAction.
  ///
  /// In ar, this message translates to:
  /// **'عميل جديد'**
  String get createNewCustomerAction;

  /// No description provided for @createNewSupplierAction.
  ///
  /// In ar, this message translates to:
  /// **'مورد جديد'**
  String get createNewSupplierAction;

  /// Payment button label with the payable amount.
  ///
  /// In ar, this message translates to:
  /// **'ادفع {amount}'**
  String payAmount(String amount);

  /// No description provided for @checkoutInProgressButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الدفع...'**
  String get checkoutInProgressButton;

  /// No description provided for @paymentDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'إتمام الدفع'**
  String get paymentDialogTitle;

  /// No description provided for @paymentMethodLabel.
  ///
  /// In ar, this message translates to:
  /// **'طريقة الدفع'**
  String get paymentMethodLabel;

  /// No description provided for @cashReceivedLabel.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ المستلم'**
  String get cashReceivedLabel;

  /// No description provided for @cashReceivedTooLowError.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ المستلم أقل من الإجمالي.'**
  String get cashReceivedTooLowError;

  /// No description provided for @paymentTenderAmountLabel.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ'**
  String get paymentTenderAmountLabel;

  /// No description provided for @addSplitTenderButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة دفعة'**
  String get addSplitTenderButton;

  /// No description provided for @removeTenderTooltip.
  ///
  /// In ar, this message translates to:
  /// **'حذف الدفعة'**
  String get removeTenderTooltip;

  /// No description provided for @paidAmountLabel.
  ///
  /// In ar, this message translates to:
  /// **'المدفوع'**
  String get paidAmountLabel;

  /// No description provided for @remainingAmountLabel.
  ///
  /// In ar, this message translates to:
  /// **'المتبقي'**
  String get remainingAmountLabel;

  /// No description provided for @changeDueLabel.
  ///
  /// In ar, this message translates to:
  /// **'الباقي للعميل'**
  String get changeDueLabel;

  /// No description provided for @paymentTotalTooLowError.
  ///
  /// In ar, this message translates to:
  /// **'يجب أن يغطي مجموع الدفعات إجمالي البيع.'**
  String get paymentTotalTooLowError;

  /// No description provided for @confirmPaymentButton.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد الدفع'**
  String get confirmPaymentButton;

  /// No description provided for @noEnabledPaymentMethods.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد طريقة دفع مفعلة. راجع إعدادات المتجر.'**
  String get noEnabledPaymentMethods;

  /// No description provided for @printInvoiceAfterPaymentLabel.
  ///
  /// In ar, this message translates to:
  /// **'طباعة الفاتورة بعد الدفع'**
  String get printInvoiceAfterPaymentLabel;

  /// No description provided for @saleCheckoutSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل البيع.'**
  String get saleCheckoutSuccess;

  /// Checkout success message with the receipt number.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل البيع. رقم الإيصال: {receiptNumber}'**
  String saleCheckoutSuccessWithReceipt(String receiptNumber);

  /// No description provided for @invoicePrintSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال الفاتورة للطابعة.'**
  String get invoicePrintSuccess;

  /// No description provided for @invoicePrintError.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل البيع، لكن تعذرت طباعة الفاتورة.'**
  String get invoicePrintError;

  /// No description provided for @invoiceProfitLabel.
  ///
  /// In ar, this message translates to:
  /// **'الربح'**
  String get invoiceProfitLabel;

  /// Compact invoice profit label with amount.
  ///
  /// In ar, this message translates to:
  /// **'الربح {amount}'**
  String invoiceProfitValue(String amount);

  /// Invoice profit margin percent label.
  ///
  /// In ar, this message translates to:
  /// **'هامش {percent}%'**
  String invoiceProfitMarginValue(String percent);

  /// No description provided for @saleCheckoutError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تسجيل البيع. تحقق من جلسة الدرج وحاول مرة أخرى.'**
  String get saleCheckoutError;

  /// No description provided for @oversellWarningTitle.
  ///
  /// In ar, this message translates to:
  /// **'تنبيه المخزون'**
  String get oversellWarningTitle;

  /// No description provided for @oversellWarningMessage.
  ///
  /// In ar, this message translates to:
  /// **'تتجاوز بعض عناصر السلة الكمية المتاحة. هل تريد إتمام البيع رغم ذلك؟'**
  String get oversellWarningMessage;

  /// No description provided for @oversellBlockedMessage.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكن إتمام البيع لأن الكمية المطلوبة تتجاوز المخزون المتاح.'**
  String get oversellBlockedMessage;

  /// Stock shortage line in the oversell warning dialog.
  ///
  /// In ar, this message translates to:
  /// **'{productName}: المطلوب {requested}، المتاح {available}'**
  String oversellLine(String productName, int requested, int available);

  /// No description provided for @reviewCartButton.
  ///
  /// In ar, this message translates to:
  /// **'مراجعة السلة'**
  String get reviewCartButton;

  /// No description provided for @continueSaleButton.
  ///
  /// In ar, this message translates to:
  /// **'إتمام البيع'**
  String get continueSaleButton;

  /// No description provided for @paymentUnauthorizedMessage.
  ///
  /// In ar, this message translates to:
  /// **'لا يملك هذا المستخدم صلاحية إتمام الدفع.'**
  String get paymentUnauthorizedMessage;

  /// Unit price label for a cart item.
  ///
  /// In ar, this message translates to:
  /// **'{amount} للقطعة'**
  String unitPriceEach(String amount);

  /// No description provided for @removeOneTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إنقاص عنصر'**
  String get removeOneTooltip;

  /// No description provided for @addOneTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إضافة عنصر'**
  String get addOneTooltip;

  /// No description provided for @subtotal.
  ///
  /// In ar, this message translates to:
  /// **'المجموع الفرعي'**
  String get subtotal;

  /// No description provided for @total.
  ///
  /// In ar, this message translates to:
  /// **'الإجمالي'**
  String get total;

  /// No description provided for @registerSessionGateTitle.
  ///
  /// In ar, this message translates to:
  /// **'جلسة الدرج'**
  String get registerSessionGateTitle;

  /// No description provided for @checkingRegisterSession.
  ///
  /// In ar, this message translates to:
  /// **'جار فحص جلسة الدرج...'**
  String get checkingRegisterSession;

  /// No description provided for @noOpenRegisterSession.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد جلسة درج مفتوحة. ابدأ جلسة جديدة قبل البيع.'**
  String get noOpenRegisterSession;

  /// No description provided for @registerSessionLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر الاتصال بجلسة الدرج. حاول مرة أخرى.'**
  String get registerSessionLoadError;

  /// No description provided for @retryRegisterSessionButton.
  ///
  /// In ar, this message translates to:
  /// **'إعادة المحاولة'**
  String get retryRegisterSessionButton;

  /// No description provided for @openingCashInputLabel.
  ///
  /// In ar, this message translates to:
  /// **'نقدية الافتتاح'**
  String get openingCashInputLabel;

  /// No description provided for @openingCashRequiredError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل نقدية الافتتاح قبل بدء الجلسة.'**
  String get openingCashRequiredError;

  /// No description provided for @startRegisterSessionButton.
  ///
  /// In ar, this message translates to:
  /// **'بدء الجلسة'**
  String get startRegisterSessionButton;

  /// No description provided for @startingRegisterSessionButton.
  ///
  /// In ar, this message translates to:
  /// **'جار بدء الجلسة...'**
  String get startingRegisterSessionButton;

  /// Title for an open register session that can be resumed.
  ///
  /// In ar, this message translates to:
  /// **'جلسة {sessionNumber}'**
  String resumeRegisterSessionTitle(String sessionNumber);

  /// Opening cash amount for a register session.
  ///
  /// In ar, this message translates to:
  /// **'نقدية الافتتاح: {amount}'**
  String registerSessionOpeningCash(String amount);

  /// No description provided for @resumeRegisterSessionButton.
  ///
  /// In ar, this message translates to:
  /// **'متابعة البيع'**
  String get resumeRegisterSessionButton;

  /// Compact app bar label for the active register session.
  ///
  /// In ar, this message translates to:
  /// **'جلسة {sessionNumber}'**
  String activeRegisterSessionLabel(String sessionNumber);

  /// No description provided for @cashMovementMenuTooltip.
  ///
  /// In ar, this message translates to:
  /// **'حركات نقدية للدرج'**
  String get cashMovementMenuTooltip;

  /// No description provided for @payInRegisterSessionTitle.
  ///
  /// In ar, this message translates to:
  /// **'إضافة نقدية للدرج'**
  String get payInRegisterSessionTitle;

  /// No description provided for @payOutRegisterSessionTitle.
  ///
  /// In ar, this message translates to:
  /// **'سحب نقدية من الدرج'**
  String get payOutRegisterSessionTitle;

  /// No description provided for @payInRegisterSessionButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة نقدية'**
  String get payInRegisterSessionButton;

  /// No description provided for @payOutRegisterSessionButton.
  ///
  /// In ar, this message translates to:
  /// **'سحب نقدية'**
  String get payOutRegisterSessionButton;

  /// No description provided for @cashMovementAmountLabel.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ'**
  String get cashMovementAmountLabel;

  /// No description provided for @cashMovementReasonLabel.
  ///
  /// In ar, this message translates to:
  /// **'سبب الحركة'**
  String get cashMovementReasonLabel;

  /// No description provided for @cashMovementReasonRequiredError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل سبب الحركة قبل الحفظ.'**
  String get cashMovementReasonRequiredError;

  /// No description provided for @positiveAmountRequiredError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل مبلغًا أكبر من صفر.'**
  String get positiveAmountRequiredError;

  /// No description provided for @savingCashMovementButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الحفظ...'**
  String get savingCashMovementButton;

  /// No description provided for @cashMovementCreateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ الحركة النقدية. راجع المبلغ والسبب وحاول مرة أخرى.'**
  String get cashMovementCreateError;

  /// No description provided for @cashMovementCreatedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ الحركة النقدية.'**
  String get cashMovementCreatedMessage;

  /// No description provided for @closeRegisterSessionTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إغلاق جلسة الدرج'**
  String get closeRegisterSessionTooltip;

  /// No description provided for @closeRegisterSessionTitle.
  ///
  /// In ar, this message translates to:
  /// **'إغلاق جلسة الدرج'**
  String get closeRegisterSessionTitle;

  /// No description provided for @closingCashInputLabel.
  ///
  /// In ar, this message translates to:
  /// **'النقد عند الإغلاق'**
  String get closingCashInputLabel;

  /// Label for a denomination count input.
  ///
  /// In ar, this message translates to:
  /// **'عدد فئة {denomination}'**
  String denominationCountLabel(String denomination);

  /// No description provided for @cancelButton.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء'**
  String get cancelButton;

  /// No description provided for @closeRegisterSessionButton.
  ///
  /// In ar, this message translates to:
  /// **'إغلاق الجلسة'**
  String get closeRegisterSessionButton;

  /// No description provided for @closingRegisterSessionButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الإغلاق...'**
  String get closingRegisterSessionButton;

  /// No description provided for @closeRegisterSessionError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إغلاق جلسة الدرج. راجع القيم وحاول مرة أخرى.'**
  String get closeRegisterSessionError;

  /// No description provided for @registerSessionHistoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'سجل جلسات الدرج'**
  String get registerSessionHistoryTitle;

  /// No description provided for @refreshRegisterSessionsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث سجل الجلسات'**
  String get refreshRegisterSessionsTooltip;

  /// No description provided for @registerSessionsListTitle.
  ///
  /// In ar, this message translates to:
  /// **'جلسات الدرج'**
  String get registerSessionsListTitle;

  /// No description provided for @registerSessionHistoryLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل سجل الجلسات.'**
  String get registerSessionHistoryLoadError;

  /// No description provided for @emptyRegisterSessionHistory.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد جلسات درج مسجلة بعد.'**
  String get emptyRegisterSessionHistory;

  /// No description provided for @registerSessionStatusOpen.
  ///
  /// In ar, this message translates to:
  /// **'مفتوحة'**
  String get registerSessionStatusOpen;

  /// No description provided for @registerSessionStatusClosed.
  ///
  /// In ar, this message translates to:
  /// **'مغلقة'**
  String get registerSessionStatusClosed;

  /// No description provided for @sessionSalesPlaceholderTitle.
  ///
  /// In ar, this message translates to:
  /// **'مبيعات الجلسة'**
  String get sessionSalesPlaceholderTitle;

  /// No description provided for @selectRegisterSessionPrompt.
  ///
  /// In ar, this message translates to:
  /// **'اختر جلسة درج لعرض مبيعاتها.'**
  String get selectRegisterSessionPrompt;

  /// Title for sales linked to a register session.
  ///
  /// In ar, this message translates to:
  /// **'مبيعات جلسة {sessionNumber}'**
  String sessionSalesTitle(String sessionNumber);

  /// No description provided for @sessionSalesTab.
  ///
  /// In ar, this message translates to:
  /// **'المبيعات'**
  String get sessionSalesTab;

  /// No description provided for @sessionCashMovementsTab.
  ///
  /// In ar, this message translates to:
  /// **'حركات النقد'**
  String get sessionCashMovementsTab;

  /// No description provided for @sessionSummaryTab.
  ///
  /// In ar, this message translates to:
  /// **'الملخص'**
  String get sessionSummaryTab;

  /// No description provided for @sessionCashSummaryTitle.
  ///
  /// In ar, this message translates to:
  /// **'ملخص النقد'**
  String get sessionCashSummaryTitle;

  /// No description provided for @sessionOpeningCashMetric.
  ///
  /// In ar, this message translates to:
  /// **'نقدية الافتتاح'**
  String get sessionOpeningCashMetric;

  /// No description provided for @sessionCashSalesMetric.
  ///
  /// In ar, this message translates to:
  /// **'المبيعات النقدية'**
  String get sessionCashSalesMetric;

  /// No description provided for @sessionPayInMetric.
  ///
  /// In ar, this message translates to:
  /// **'إضافات الدرج'**
  String get sessionPayInMetric;

  /// No description provided for @sessionPayOutMetric.
  ///
  /// In ar, this message translates to:
  /// **'سحوبات الدرج'**
  String get sessionPayOutMetric;

  /// No description provided for @sessionCashRefundMetric.
  ///
  /// In ar, this message translates to:
  /// **'مبالغ الإرجاع النقدية'**
  String get sessionCashRefundMetric;

  /// No description provided for @sessionExpectedCashMetric.
  ///
  /// In ar, this message translates to:
  /// **'النقد المتوقع'**
  String get sessionExpectedCashMetric;

  /// No description provided for @sessionClosingCashMetric.
  ///
  /// In ar, this message translates to:
  /// **'النقد المعدود'**
  String get sessionClosingCashMetric;

  /// No description provided for @sessionDenominationTotalMetric.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الفئات'**
  String get sessionDenominationTotalMetric;

  /// No description provided for @sessionCashVarianceMetric.
  ///
  /// In ar, this message translates to:
  /// **'فرق النقد'**
  String get sessionCashVarianceMetric;

  /// No description provided for @sessionDenominationsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الفئات عند الإغلاق'**
  String get sessionDenominationsTitle;

  /// Compact cash variance label.
  ///
  /// In ar, this message translates to:
  /// **'فرق {amount}'**
  String sessionVarianceFlag(String amount);

  /// No description provided for @sessionNoVariance.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد فرق مسجل'**
  String get sessionNoVariance;

  /// No description provided for @sessionSalesLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل مبيعات هذه الجلسة.'**
  String get sessionSalesLoadError;

  /// No description provided for @emptySessionSales.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مبيعات مسجلة في هذه الجلسة.'**
  String get emptySessionSales;

  /// No description provided for @allCustomersFilterLabel.
  ///
  /// In ar, this message translates to:
  /// **'كل العملاء'**
  String get allCustomersFilterLabel;

  /// No description provided for @clearCustomerFilterTooltip.
  ///
  /// In ar, this message translates to:
  /// **'مسح فلتر العميل'**
  String get clearCustomerFilterTooltip;

  /// No description provided for @sessionCashMovementsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل حركات النقد لهذه الجلسة.'**
  String get sessionCashMovementsLoadError;

  /// No description provided for @emptySessionCashMovements.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد حركات نقد مسجلة في هذه الجلسة.'**
  String get emptySessionCashMovements;

  /// No description provided for @cashMovementPayInLabel.
  ///
  /// In ar, this message translates to:
  /// **'إضافة نقدية'**
  String get cashMovementPayInLabel;

  /// No description provided for @cashMovementPayOutLabel.
  ///
  /// In ar, this message translates to:
  /// **'سحب نقدية'**
  String get cashMovementPayOutLabel;

  /// No description provided for @saleReceiptFallback.
  ///
  /// In ar, this message translates to:
  /// **'بدون رقم'**
  String get saleReceiptFallback;

  /// Sale receipt title.
  ///
  /// In ar, this message translates to:
  /// **'إيصال {receiptNumber}'**
  String saleReceiptTitle(String receiptNumber);

  /// Number of sale lines.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد عناصر} =1{عنصر واحد} =2{عنصران} other{{count} عناصر}}'**
  String saleLineCount(num count);

  /// Fallback product label in a sale line.
  ///
  /// In ar, this message translates to:
  /// **'منتج رقم {productId}'**
  String saleProductFallback(int productId);

  /// Sale line quantity and unit price.
  ///
  /// In ar, this message translates to:
  /// **'{quantity} × {unitPrice}'**
  String saleLineQuantityAndPrice(int quantity, String unitPrice);

  /// No description provided for @saleReprintButton.
  ///
  /// In ar, this message translates to:
  /// **'إعادة طباعة الإيصال'**
  String get saleReprintButton;

  /// No description provided for @saleReprintInProgressButton.
  ///
  /// In ar, this message translates to:
  /// **'جار طلب الطباعة...'**
  String get saleReprintInProgressButton;

  /// No description provided for @saleReprintQueuedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال طلب إعادة الطباعة.'**
  String get saleReprintQueuedMessage;

  /// No description provided for @saleReprintError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إرسال طلب إعادة الطباعة.'**
  String get saleReprintError;

  /// No description provided for @saleVoidButton.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء الفاتورة'**
  String get saleVoidButton;

  /// No description provided for @saleVoidTitle.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء الفاتورة'**
  String get saleVoidTitle;

  /// No description provided for @saleVoidMessage.
  ///
  /// In ar, this message translates to:
  /// **'سيتم عكس كامل المبلغ وإرجاع الكميات المتبقية إلى المخزون.'**
  String get saleVoidMessage;

  /// No description provided for @saleVoidSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم إلغاء الفاتورة.'**
  String get saleVoidSuccess;

  /// No description provided for @saleVoidError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إلغاء الفاتورة.'**
  String get saleVoidError;

  /// No description provided for @saleReturnButton.
  ///
  /// In ar, this message translates to:
  /// **'إرجاع منتجات'**
  String get saleReturnButton;

  /// No description provided for @saleReturnTitle.
  ///
  /// In ar, this message translates to:
  /// **'إرجاع منتجات'**
  String get saleReturnTitle;

  /// No description provided for @saleReturnSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل الإرجاع.'**
  String get saleReturnSuccess;

  /// No description provided for @saleReturnError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تسجيل الإرجاع.'**
  String get saleReturnError;

  /// No description provided for @saleAdjustmentReasonLabel.
  ///
  /// In ar, this message translates to:
  /// **'سبب اختياري'**
  String get saleAdjustmentReasonLabel;

  /// No description provided for @saleAdjustmentReasonHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: طلب العميل الإرجاع'**
  String get saleAdjustmentReasonHint;

  /// No description provided for @saleReturnQuantityLabel.
  ///
  /// In ar, this message translates to:
  /// **'كمية الإرجاع'**
  String get saleReturnQuantityLabel;

  /// No description provided for @salePaymentsTitle.
  ///
  /// In ar, this message translates to:
  /// **'المدفوعات'**
  String get salePaymentsTitle;

  /// Commission line for a recorded payment.
  ///
  /// In ar, this message translates to:
  /// **'العمولة {amount} بنسبة {percent}%'**
  String salePaymentCommission(String amount, String percent);

  /// Returned quantity status for a sale line.
  ///
  /// In ar, this message translates to:
  /// **'تم إرجاع {returned} من {quantity}'**
  String saleLineReturnedQuantity(int returned, int quantity);

  /// No description provided for @saleReturnNoItemsSelected.
  ///
  /// In ar, this message translates to:
  /// **'اختر كمية واحدة على الأقل للإرجاع.'**
  String get saleReturnNoItemsSelected;

  /// No description provided for @saleNoReturnableItems.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد كميات متاحة للإرجاع.'**
  String get saleNoReturnableItems;

  /// No description provided for @confirmButton.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد'**
  String get confirmButton;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['ar'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsAr();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
