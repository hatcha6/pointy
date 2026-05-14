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

  /// No description provided for @catalogTitle.
  ///
  /// In ar, this message translates to:
  /// **'المنتجات'**
  String get catalogTitle;

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

  /// No description provided for @tax.
  ///
  /// In ar, this message translates to:
  /// **'الضريبة'**
  String get tax;

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
