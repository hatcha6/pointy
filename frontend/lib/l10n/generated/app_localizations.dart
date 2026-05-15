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

  /// No description provided for @catalogDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'المنتجات'**
  String get catalogDrawerLabel;

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

  /// Payment button label with the payable amount.
  ///
  /// In ar, this message translates to:
  /// **'ادفع {amount}'**
  String payAmount(String amount);

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
