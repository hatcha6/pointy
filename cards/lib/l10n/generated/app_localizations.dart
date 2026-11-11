import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_en.dart';
import 'app_localizations_fr.dart';

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

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
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
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('en'),
    Locale('fr'),
  ];

  /// The app's name: Daftar Cards.
  ///
  /// In ar, this message translates to:
  /// **'دفتر كروت'**
  String get appTitle;

  /// Bottom navigation: the card shelf.
  ///
  /// In ar, this message translates to:
  /// **'الرئيسية'**
  String get tabHome;

  /// Bottom navigation: the cards the customer bought.
  ///
  /// In ar, this message translates to:
  /// **'كروتي'**
  String get tabMyCards;

  /// Bottom navigation: the customer's account.
  ///
  /// In ar, this message translates to:
  /// **'حسابي'**
  String get tabAccount;

  /// Placeholder of the home search field.
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن كرت: ليبيانا، ببجي، آيتونز…'**
  String get homeSearchHint;

  /// One-line promise under the app name on home.
  ///
  /// In ar, this message translates to:
  /// **'كروت الاتصالات والإنترنت والألعاب، تصلك فوراً'**
  String get homeTagline;

  /// Empty state title of My cards.
  ///
  /// In ar, this message translates to:
  /// **'لا كروت بعد'**
  String get myCardsEmptyTitle;

  /// Empty state body of My cards.
  ///
  /// In ar, this message translates to:
  /// **'الكروت التي تشتريها تُحفظ هنا، جاهزة متى احتجتها.'**
  String get myCardsEmptyBody;

  /// Account tab title when signed out.
  ///
  /// In ar, this message translates to:
  /// **'سجّل الدخول برقم هاتفك'**
  String get accountSignedOutTitle;

  /// Account tab body when signed out: sign-in is by SMS code, no password.
  ///
  /// In ar, this message translates to:
  /// **'نرسل لك رمزاً في رسالة نصية، دون كلمة مرور.'**
  String get accountSignedOutBody;

  /// Button that starts phone sign-in.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الدخول'**
  String get signInAction;

  /// Button that goes to the card shelf.
  ///
  /// In ar, this message translates to:
  /// **'تصفّح الكروت'**
  String get browseAction;

  /// An amount of Libyan dinars, e.g. 10.00 د.ل.
  ///
  /// In ar, this message translates to:
  /// **'{amount} د.ل'**
  String moneyAmount(String amount);

  /// Generic error when the relay cannot be reached.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر الاتصال. تحقّق من الإنترنت وحاول مجدداً.'**
  String get errorNetwork;

  /// Generic error for anything else.
  ///
  /// In ar, this message translates to:
  /// **'حدث خطأ غير متوقع. حاول مجدداً.'**
  String get errorGeneric;

  /// Button to retry a failed load.
  ///
  /// In ar, this message translates to:
  /// **'إعادة المحاولة'**
  String get retryAction;

  /// Home row of items bought before.
  ///
  /// In ar, this message translates to:
  /// **'اشترِ مجدداً'**
  String get buyAgainTitle;

  /// Category chip that shows every category.
  ///
  /// In ar, this message translates to:
  /// **'الكل'**
  String get allCategories;

  /// Brand tile: the cheapest price, e.g. من 5.00 د.ل.
  ///
  /// In ar, this message translates to:
  /// **'من {price}'**
  String fromPrice(String price);

  /// Badge on a card that cannot be bought right now.
  ///
  /// In ar, this message translates to:
  /// **'غير متوفر الآن'**
  String get unavailableNow;

  /// Search found nothing.
  ///
  /// In ar, this message translates to:
  /// **'لا نتائج لـ «{query}»'**
  String searchNoResultsTitle(String query);

  /// Search found nothing: what to do.
  ///
  /// In ar, this message translates to:
  /// **'جرّب اسماً آخر أو تصفّح الأقسام.'**
  String get searchNoResultsBody;

  /// The shelf is empty.
  ///
  /// In ar, this message translates to:
  /// **'لا كروت متاحة الآن'**
  String get catalogEmptyTitle;

  /// The shelf is empty: reassurance.
  ///
  /// In ar, this message translates to:
  /// **'نعمل على توفير الكروت. عُد بعد قليل.'**
  String get catalogEmptyBody;

  /// The shelf could not load and none is saved.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل الكروت'**
  String get catalogLoadFailedTitle;

  /// Shown when the shelf is the saved copy because the network failed.
  ///
  /// In ar, this message translates to:
  /// **'تعرض آخر نسخة محفوظة'**
  String get savedShelfNote;

  /// Home chip showing the customer's credit.
  ///
  /// In ar, this message translates to:
  /// **'رصيدك {amount}'**
  String creditChip(String amount);

  /// Brand page: heading above the denominations.
  ///
  /// In ar, this message translates to:
  /// **'اختر الفئة'**
  String get chooseValue;

  /// Brand page: heading above the country and region chips.
  ///
  /// In ar, this message translates to:
  /// **'الدولة أو المنطقة'**
  String get chooseCountry;

  /// Brand page / reveal: how to redeem the card.
  ///
  /// In ar, this message translates to:
  /// **'طريقة الاستخدام'**
  String get howToRedeem;

  /// Quantity stepper label.
  ///
  /// In ar, this message translates to:
  /// **'الكمية'**
  String get quantityLabel;

  /// Sticky buy button with the total, e.g. اشترِ بـ 10.00 د.ل.
  ///
  /// In ar, this message translates to:
  /// **'اشترِ بـ {amount}'**
  String buyFor(String amount);

  /// Tooltip of the + button.
  ///
  /// In ar, this message translates to:
  /// **'زيادة الكمية'**
  String get increaseQuantity;

  /// Tooltip of the − button.
  ///
  /// In ar, this message translates to:
  /// **'إنقاص الكمية'**
  String get decreaseQuantity;

  /// Sign-in sheet title.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الدخول'**
  String get signInTitle;

  /// Sign-in sheet: phone step help.
  ///
  /// In ar, this message translates to:
  /// **'أدخل رقم هاتفك لنرسل لك رمز الدخول. لا حاجة لكلمة مرور.'**
  String get signInSubtitle;

  /// Phone field label.
  ///
  /// In ar, this message translates to:
  /// **'رقم الهاتف'**
  String get phoneLabel;

  /// Button that asks for the SMS code.
  ///
  /// In ar, this message translates to:
  /// **'أرسل الرمز'**
  String get sendCode;

  /// Sign-in sheet: code step title.
  ///
  /// In ar, this message translates to:
  /// **'أدخل الرمز'**
  String get codeTitle;

  /// Code step: where the code went; the number is shown on its own line below, left to right.
  ///
  /// In ar, this message translates to:
  /// **'أرسلنا رمزاً من 6 أرقام إلى'**
  String get codeSentTo;

  /// Countdown before another code may be asked.
  ///
  /// In ar, this message translates to:
  /// **'إعادة الإرسال بعد {seconds} ث'**
  String resendIn(int seconds);

  /// Button to ask for another code.
  ///
  /// In ar, this message translates to:
  /// **'أعد إرسال الرمز'**
  String get resendCode;

  /// Go back to the phone step.
  ///
  /// In ar, this message translates to:
  /// **'تعديل الرقم'**
  String get changeNumber;

  /// Snackbar after signing in.
  ///
  /// In ar, this message translates to:
  /// **'أهلاً بك! تم تسجيل الدخول'**
  String get signInDone;

  /// Phone is not a Libyan mobile.
  ///
  /// In ar, this message translates to:
  /// **'أدخل رقم هاتف ليبياً صحيحاً يبدأ بـ 09'**
  String get errInvalidPhone;

  /// Wrong sign-in code with attempts left.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{الرمز غير صحيح.} =1{الرمز غير صحيح. بقيت محاولة واحدة.} =2{الرمز غير صحيح. بقيت محاولتان.} few{الرمز غير صحيح. بقيت {count} محاولات.} other{الرمز غير صحيح. بقيت {count} محاولة.}}'**
  String errWrongCode(int count);

  /// Code expired.
  ///
  /// In ar, this message translates to:
  /// **'انتهت صلاحية الرمز. اطلب رمزاً جديداً.'**
  String get errCodeExpired;

  /// Too many wrong codes.
  ///
  /// In ar, this message translates to:
  /// **'محاولات كثيرة. اطلب رمزاً جديداً.'**
  String get errTooManyAttempts;

  /// No description provided for @errAccountBlocked.
  ///
  /// In ar, this message translates to:
  /// **'هذا الحساب موقوف. تواصل معنا لإعادة تفعيله.'**
  String get errAccountBlocked;

  /// Asked for a code too soon.
  ///
  /// In ar, this message translates to:
  /// **'انتظر قليلاً قبل طلب رمز جديد.'**
  String get errTooSoon;

  /// Daily code cap reached.
  ///
  /// In ar, this message translates to:
  /// **'وصلت إلى الحد اليومي للرموز. حاول غداً.'**
  String get errDailyLimit;

  /// SMS could not be sent.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر إرسال الرمز. حاول مجدداً.'**
  String get errSendFailed;

  /// Rate limited.
  ///
  /// In ar, this message translates to:
  /// **'طلبات كثيرة. حاول بعد قليل.'**
  String get errRateLimited;

  /// Session gone; sign in again.
  ///
  /// In ar, this message translates to:
  /// **'سجّل الدخول للمتابعة.'**
  String get errSignInRequired;

  /// Checkout sheet title.
  ///
  /// In ar, this message translates to:
  /// **'إتمام الشراء'**
  String get checkoutTitle;

  /// Heading above the payment methods.
  ///
  /// In ar, this message translates to:
  /// **'ادفع عبر'**
  String get payWith;

  /// The bank-card (Moamalat) method.
  ///
  /// In ar, this message translates to:
  /// **'البطاقات المصرفية'**
  String get bankCards;

  /// Switch to pay from the customer's credit first.
  ///
  /// In ar, this message translates to:
  /// **'استخدم رصيدك ({amount})'**
  String useCredit(String amount);

  /// Checkout line: the cards' price.
  ///
  /// In ar, this message translates to:
  /// **'السعر'**
  String get lineSubtotal;

  /// Checkout line: paid from credit.
  ///
  /// In ar, this message translates to:
  /// **'من رصيدك'**
  String get lineCredit;

  /// Checkout line: the payment gateway's fee.
  ///
  /// In ar, this message translates to:
  /// **'رسوم الدفع'**
  String get lineFee;

  /// Checkout line: what the payer is charged.
  ///
  /// In ar, this message translates to:
  /// **'المطلوب دفعه'**
  String get lineTotal;

  /// Pay button, e.g. ادفع 10.21 د.ل.
  ///
  /// In ar, this message translates to:
  /// **'ادفع {amount}'**
  String payAmount(String amount);

  /// Pay button when credit covers everything.
  ///
  /// In ar, this message translates to:
  /// **'ادفع من رصيدك'**
  String get payFromCredit;

  /// Checkout reassurance line.
  ///
  /// In ar, this message translates to:
  /// **'يصلك الرقم السري فوراً بعد الدفع.'**
  String get instantDelivery;

  /// Payer dialog title.
  ///
  /// In ar, this message translates to:
  /// **'الدفع عبر {method}'**
  String payerTitle(String method);

  /// Payer phone field.
  ///
  /// In ar, this message translates to:
  /// **'رقم المحفظة'**
  String get payerPhone;

  /// Payer wallet card number field.
  ///
  /// In ar, this message translates to:
  /// **'رقم بطاقة المحفظة'**
  String get payerCard;

  /// Payer birth year (Sadad).
  ///
  /// In ar, this message translates to:
  /// **'سنة الميلاد'**
  String get payerBirthYear;

  /// Continue button.
  ///
  /// In ar, this message translates to:
  /// **'متابعة'**
  String get continueAction;

  /// Cancel button.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء'**
  String get cancelAction;

  /// Wallet OTP sheet title.
  ///
  /// In ar, this message translates to:
  /// **'رمز تأكيد {method}'**
  String walletCodeTitle(String method);

  /// Wallet OTP explanation, distinct from the sign-in code.
  ///
  /// In ar, this message translates to:
  /// **'أرسلت {method} رمزاً إلى هاتفك لتأكيد دفع {amount}. هذا ليس رمز الدخول.'**
  String walletCodeBody(String method, String amount);

  /// Confirm the wallet payment.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد الدفع'**
  String get confirmPayment;

  /// Wrong wallet code.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{رمز الدفع غير صحيح.} =1{رمز الدفع غير صحيح. بقيت محاولة واحدة.} =2{رمز الدفع غير صحيح. بقيت محاولتان.} few{رمز الدفع غير صحيح. بقيت {count} محاولات.} other{رمز الدفع غير صحيح. بقيت {count} محاولة.}}'**
  String errOtpRejected(int count);

  /// Payment declined.
  ///
  /// In ar, this message translates to:
  /// **'رفض المصرف أو المحفظة الدفع. لم يُخصم شيء.'**
  String get errDeclined;

  /// Price changed before paying.
  ///
  /// In ar, this message translates to:
  /// **'تغيّر السعر إلى {amount}. راجعه ثم أكمل.'**
  String errPriceChanged(String amount);

  /// Card cannot be bought now.
  ///
  /// In ar, this message translates to:
  /// **'هذا الكرت غير متوفر الآن.'**
  String get errItemUnavailable;

  /// Payment could not start.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر بدء الدفع. حاول مجدداً أو اختر طريقة أخرى.'**
  String get errPaymentFailed;

  /// Payments not configured / down.
  ///
  /// In ar, this message translates to:
  /// **'الدفع غير متاح الآن. حاول بعد قليل.'**
  String get errPaymentsUnavailable;

  /// Payer details refused.
  ///
  /// In ar, this message translates to:
  /// **'تحقّق من بيانات الدفع.'**
  String get errInvalidPayer;

  /// Dafa's card page said paid; the relay is confirming the payment.
  ///
  /// In ar, this message translates to:
  /// **'نتحقق من الدفع'**
  String get hostedTitle;

  /// Shown while the relay confirms a payment made on Dafa's card page.
  ///
  /// In ar, this message translates to:
  /// **'تم الدفع في صفحة البطاقة، ونتأكد الآن من وصوله. سيظهر كرتك هنا خلال لحظات.'**
  String get hostedBody;

  /// Cancel an unpaid order.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء الطلب'**
  String get cancelOrder;

  /// Order paid, card on its way.
  ///
  /// In ar, this message translates to:
  /// **'نجهّز كرتك…'**
  String get preparingTitle;

  /// Order progress reassurance.
  ///
  /// In ar, this message translates to:
  /// **'عادةً خلال ثوانٍ. يمكنك إغلاق التطبيق، وسيُحفظ الكرت في «كروتي».'**
  String get preparingBody;

  /// Order paid, the card still not here after a few minutes.
  ///
  /// In ar, this message translates to:
  /// **'يتأخر المورّد هذه المرة'**
  String get preparingSlowTitle;

  /// Slow order, notifications on: the customer may leave.
  ///
  /// In ar, this message translates to:
  /// **'لا داعي للانتظار هنا: حين يجهز طلبك نرسل لك إشعاراً يفتحه مباشرةً في «كروتي».'**
  String get preparingSlowNotify;

  /// Slow order, notifications off: offer to turn them on.
  ///
  /// In ar, this message translates to:
  /// **'فعّل الإشعارات ونخبرك حين يجهز طلبك، أو عُد إليه لاحقاً في «كروتي».'**
  String get preparingSlowAsk;

  /// Slow order, no notifications on this device.
  ///
  /// In ar, this message translates to:
  /// **'لا داعي للانتظار هنا: تجد طلبك في «كروتي» حين يجهز.'**
  String get preparingSlowLater;

  /// Leave the waiting screen for the My cards tab.
  ///
  /// In ar, this message translates to:
  /// **'اذهب إلى «كروتي»'**
  String get goToMyCards;

  /// Paid but no card: refunded to credit.
  ///
  /// In ar, this message translates to:
  /// **'لم نتمكن من شراء الكرت'**
  String get refundedTitle;

  /// Refund explanation.
  ///
  /// In ar, this message translates to:
  /// **'أعدنا {amount} إلى رصيدك، ويُستخدم في طلبك القادم.'**
  String refundedBody(String amount);

  /// Order closed without payment.
  ///
  /// In ar, this message translates to:
  /// **'لم يكتمل الدفع'**
  String get unpaidTitle;

  /// Nothing was charged.
  ///
  /// In ar, this message translates to:
  /// **'لم يُخصم أي مبلغ. يمكنك المحاولة مجدداً.'**
  String get unpaidBody;

  /// Try again.
  ///
  /// In ar, this message translates to:
  /// **'حاول مجدداً'**
  String get tryAgain;

  /// Back to the shelf.
  ///
  /// In ar, this message translates to:
  /// **'العودة إلى الكروت'**
  String get backToShop;

  /// Reveal page title.
  ///
  /// In ar, this message translates to:
  /// **'كرتك جاهز'**
  String get revealTitle;

  /// The card PIN label.
  ///
  /// In ar, this message translates to:
  /// **'الرقم السري'**
  String get secretCode;

  /// Card serial.
  ///
  /// In ar, this message translates to:
  /// **'الرقم التسلسلي: {serial}'**
  String serialNumber(String serial);

  /// Copy button.
  ///
  /// In ar, this message translates to:
  /// **'نسخ'**
  String get copyAction;

  /// Snackbar after copying.
  ///
  /// In ar, this message translates to:
  /// **'تم نسخ الرقم السري'**
  String get copiedNotice;

  /// No description provided for @shareAction.
  ///
  /// In ar, this message translates to:
  /// **'مشاركة'**
  String get shareAction;

  /// No description provided for @linkCopiedNotice.
  ///
  /// In ar, this message translates to:
  /// **'تم نسخ الرابط'**
  String get linkCopiedNotice;

  /// No description provided for @redeemAction.
  ///
  /// In ar, this message translates to:
  /// **'استرداد'**
  String get redeemAction;

  /// No description provided for @dialCopiedNotice.
  ///
  /// In ar, this message translates to:
  /// **'تم نسخ كود الشحن. الصقه في تطبيق الهاتف ثم اضغط اتصال.'**
  String get dialCopiedNotice;

  /// No description provided for @redeemCopiedNotice.
  ///
  /// In ar, this message translates to:
  /// **'تم نسخ الرقم السري. إن لم يظهر في الصفحة فالصقه هناك.'**
  String get redeemCopiedNotice;

  /// Open the dialer with the recharge code.
  ///
  /// In ar, this message translates to:
  /// **'اشحن الآن'**
  String get rechargeNow;

  /// Show the code as a QR.
  ///
  /// In ar, this message translates to:
  /// **'رمز QR'**
  String get showQr;

  /// No description provided for @qrRevealHint.
  ///
  /// In ar, this message translates to:
  /// **'المس الكرت لإظهار رمز QR'**
  String get qrRevealHint;

  /// Beside the QR on the card's back: what the QR is for.
  ///
  /// In ar, this message translates to:
  /// **'امسحه بالكاميرا لقراءة الرقم السري'**
  String get qrScanHint;

  /// Share the card by WhatsApp.
  ///
  /// In ar, this message translates to:
  /// **'أرسلها هدية'**
  String get sendAsGift;

  /// WhatsApp gift text.
  ///
  /// In ar, this message translates to:
  /// **'هدية لك من دفتر كروت\n{name}\nالرقم السري: {code}'**
  String giftMessage(String name, String code);

  /// Mark a card used.
  ///
  /// In ar, this message translates to:
  /// **'استخدمته'**
  String get markUsed;

  /// Unmark a used card.
  ///
  /// In ar, this message translates to:
  /// **'لم أستخدمه'**
  String get markUnused;

  /// Used badge.
  ///
  /// In ar, this message translates to:
  /// **'مستخدم'**
  String get usedBadge;

  /// Done.
  ///
  /// In ar, this message translates to:
  /// **'تم'**
  String get doneAction;

  /// Codes hidden until unlock.
  ///
  /// In ar, this message translates to:
  /// **'رموزك محمية'**
  String get codesLockedTitle;

  /// Unlock explanation.
  ///
  /// In ar, this message translates to:
  /// **'أكّد هويتك لعرض الأرقام السرية.'**
  String get codesLockedBody;

  /// Unlock button.
  ///
  /// In ar, this message translates to:
  /// **'اعرض الرموز'**
  String get unlockAction;

  /// OS biometric prompt reason.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد هويتك لعرض رموز كروتك'**
  String get unlockReason;

  /// Codes not readable right now.
  ///
  /// In ar, this message translates to:
  /// **'نقرأ الرمز من المورّد…'**
  String get codesPendingTitle;

  /// Codes pending explanation.
  ///
  /// In ar, this message translates to:
  /// **'الكرت مدفوع ومحفوظ. سيظهر رقمه السري هنا خلال لحظات.'**
  String get codesPendingBody;

  /// Filter: unused cards.
  ///
  /// In ar, this message translates to:
  /// **'غير مستخدم'**
  String get filterUnused;

  /// Filter: used cards.
  ///
  /// In ar, this message translates to:
  /// **'مستخدم'**
  String get filterUsed;

  /// Order status chip.
  ///
  /// In ar, this message translates to:
  /// **'قيد التجهيز'**
  String get statusPreparing;

  /// Order status chip.
  ///
  /// In ar, this message translates to:
  /// **'بانتظار الدفع'**
  String get statusAwaitingPayment;

  /// Order status chip.
  ///
  /// In ar, this message translates to:
  /// **'أُعيد لرصيدك'**
  String get statusRefunded;

  /// Order status chip.
  ///
  /// In ar, this message translates to:
  /// **'لم يكتمل'**
  String get statusUnpaid;

  /// Number of cards in an order.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{كرت واحد} =2{كرتان} few{{count} كروت} other{{count} كرتاً}}'**
  String cardCount(int count);

  /// My cards when signed out.
  ///
  /// In ar, this message translates to:
  /// **'سجّل الدخول لترى كروتك على أي جهاز.'**
  String get myCardsSignedOutBody;

  /// Credit card title.
  ///
  /// In ar, this message translates to:
  /// **'رصيدك'**
  String get creditTitle;

  /// Credit explanation.
  ///
  /// In ar, this message translates to:
  /// **'يُستخدم في طلباتك القادمة.'**
  String get creditBody;

  /// Credit entry: spent on an order.
  ///
  /// In ar, this message translates to:
  /// **'دفع طلب'**
  String get creditOrder;

  /// Credit entry: refund.
  ///
  /// In ar, this message translates to:
  /// **'استرداد طلب'**
  String get creditRefund;

  /// Credit entry: released hold.
  ///
  /// In ar, this message translates to:
  /// **'إعادة رصيد طلب لم يكتمل'**
  String get creditRelease;

  /// Credit entry: late payment.
  ///
  /// In ar, this message translates to:
  /// **'دفعة وصلت بعد إغلاق الطلب'**
  String get creditLatePayment;

  /// Devices section.
  ///
  /// In ar, this message translates to:
  /// **'الأجهزة المسجّلة'**
  String get devicesTitle;

  /// Current device badge.
  ///
  /// In ar, this message translates to:
  /// **'هذا الجهاز'**
  String get thisDevice;

  /// Sign out other devices.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الخروج من الأجهزة الأخرى'**
  String get signOutOthers;

  /// Snackbar.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل الخروج من الأجهزة الأخرى'**
  String get signOutOthersDone;

  /// Sign out.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الخروج'**
  String get signOut;

  /// Delete account.
  ///
  /// In ar, this message translates to:
  /// **'حذف الحساب'**
  String get deleteAccount;

  /// Delete confirmation title.
  ///
  /// In ar, this message translates to:
  /// **'حذف حسابك؟'**
  String get deleteAccountTitle;

  /// Delete confirmation body.
  ///
  /// In ar, this message translates to:
  /// **'سنحذف رقمك وكل جلساتك نهائياً. انسخ الأرقام السرية لكروتك قبل الحذف.'**
  String get deleteAccountBody;

  /// Confirm delete.
  ///
  /// In ar, this message translates to:
  /// **'احذف'**
  String get deleteAction;

  /// Snackbar after deletion.
  ///
  /// In ar, this message translates to:
  /// **'تم حذف حسابك'**
  String get accountDeleted;

  /// Devices list: a session signed in from a web browser.
  ///
  /// In ar, this message translates to:
  /// **'متصفح'**
  String get deviceBrowser;

  /// A payment arrived for a different amount than the order; held for review.
  ///
  /// In ar, this message translates to:
  /// **'نراجع دفعتك'**
  String get paymentReviewTitle;

  /// Payment held for review: reassurance.
  ///
  /// In ar, this message translates to:
  /// **'وصلت دفعة بمبلغ يختلف عن الطلب، فأوقفناها للمراجعة. سنتواصل معك، ولن تخسر شيئاً.'**
  String get paymentReviewBody;

  /// Order status chip: payment held for review.
  ///
  /// In ar, this message translates to:
  /// **'قيد المراجعة'**
  String get statusReview;

  /// Home large title.
  ///
  /// In ar, this message translates to:
  /// **'اكتشف الكروت'**
  String get homeTitle;

  /// Shelf header action: show every card of the shelf.
  ///
  /// In ar, this message translates to:
  /// **'عرض الكل'**
  String get seeAll;

  /// Home: the featured shelf.
  ///
  /// In ar, this message translates to:
  /// **'الأكثر طلباً'**
  String get featuredTitle;

  /// Checkout row: the payment method.
  ///
  /// In ar, this message translates to:
  /// **'طريقة الدفع'**
  String get paymentMethodLabel;

  /// Change the chosen option.
  ///
  /// In ar, this message translates to:
  /// **'تغيير'**
  String get changeAction;

  /// Payment method picker title.
  ///
  /// In ar, this message translates to:
  /// **'اختر طريقة الدفع'**
  String get choosePaymentMethod;

  /// Checkout footnote about the gateway.
  ///
  /// In ar, this message translates to:
  /// **'يتم الدفع عبر بوابة «دفع» الآمنة، ولا نحتفظ ببيانات الدفع.'**
  String get securePaymentNote;

  /// Reveal: purchase succeeded headline.
  ///
  /// In ar, this message translates to:
  /// **'تم الشراء بنجاح'**
  String get purchaseSuccess;

  /// Reveal: which of several cards is shown.
  ///
  /// In ar, this message translates to:
  /// **'الكرت {index} من {count}'**
  String cardIndex(int index, int count);

  /// Close a sheet.
  ///
  /// In ar, this message translates to:
  /// **'إغلاق'**
  String get closeAction;

  /// Under a unit price: per card.
  ///
  /// In ar, this message translates to:
  /// **'للكرت الواحد'**
  String get perCard;

  /// Account: credit history section.
  ///
  /// In ar, this message translates to:
  /// **'سجل الرصيد'**
  String get creditHistory;

  /// Account: account actions section.
  ///
  /// In ar, this message translates to:
  /// **'الحساب'**
  String get accountSection;

  /// My cards: section of orders on their way.
  ///
  /// In ar, this message translates to:
  /// **'قيد التجهيز'**
  String get inProgressSection;

  /// My cards: section of delivered cards.
  ///
  /// In ar, this message translates to:
  /// **'كروتك'**
  String get myCardsSection;

  /// Home: search results heading.
  ///
  /// In ar, this message translates to:
  /// **'نتائج البحث'**
  String get searchResults;

  /// Label before a starting price.
  ///
  /// In ar, this message translates to:
  /// **'تبدأ من'**
  String get startingFrom;

  /// Brand page buy button (the total is shown beside it).
  ///
  /// In ar, this message translates to:
  /// **'اشترِ'**
  String get buyNow;

  /// The first word of the name, shown as the opening starts
  ///
  /// In ar, this message translates to:
  /// **'دفتر'**
  String get splashDaftar;

  /// The second word of the name, joining the first as the opening ends
  ///
  /// In ar, this message translates to:
  /// **'كروت'**
  String get splashCards;

  /// Beside the refunded amount on a refunded order: where the money went
  ///
  /// In ar, this message translates to:
  /// **'أُضيف إلى رصيدك'**
  String get refundedToCredit;

  /// No description provided for @settingsSection.
  ///
  /// In ar, this message translates to:
  /// **'الإعدادات'**
  String get settingsSection;

  /// No description provided for @codeLockTitle.
  ///
  /// In ar, this message translates to:
  /// **'حماية الرموز'**
  String get codeLockTitle;

  /// No description provided for @codeLockBody.
  ///
  /// In ar, this message translates to:
  /// **'اطلب Face ID أو البصمة قبل عرض الأرقام السرية'**
  String get codeLockBody;

  /// No description provided for @codeLockOffReason.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد هويتك لإيقاف حماية الرموز'**
  String get codeLockOffReason;

  /// Settings switch: product analytics and masked session recordings.
  ///
  /// In ar, this message translates to:
  /// **'مشاركة بيانات الاستخدام'**
  String get shareUsageTitle;

  /// No description provided for @notificationOpenAction.
  ///
  /// In ar, this message translates to:
  /// **'عرض'**
  String get notificationOpenAction;

  /// No description provided for @notificationsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الإشعارات'**
  String get notificationsTitle;

  /// No description provided for @notificationsBlockedNotice.
  ///
  /// In ar, this message translates to:
  /// **'الإشعارات متوقفة في إعدادات الهاتف'**
  String get notificationsBlockedNotice;

  /// No description provided for @themeTitle.
  ///
  /// In ar, this message translates to:
  /// **'المظهر'**
  String get themeTitle;

  /// No description provided for @themeSystem.
  ///
  /// In ar, this message translates to:
  /// **'تلقائي'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In ar, this message translates to:
  /// **'فاتح'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In ar, this message translates to:
  /// **'داكن'**
  String get themeDark;

  /// No description provided for @languageTitle.
  ///
  /// In ar, this message translates to:
  /// **'اللغة'**
  String get languageTitle;

  /// No description provided for @aboutSection.
  ///
  /// In ar, this message translates to:
  /// **'حول التطبيق'**
  String get aboutSection;

  /// No description provided for @aboutTitle.
  ///
  /// In ar, this message translates to:
  /// **'حول دفتر كروت'**
  String get aboutTitle;

  /// No description provided for @aboutTagline.
  ///
  /// In ar, this message translates to:
  /// **'كروت الشحن والإنترنت، تصلك فوراً.'**
  String get aboutTagline;

  /// No description provided for @aboutBody.
  ///
  /// In ar, this message translates to:
  /// **'«دفتر كروت» تطبيق من «دفتر»، نظام المبيعات الذي تعمل به المتاجر في ليبيا. اختر الكرت وادفع بمحفظتك أو بطاقتك، فيصلك رقمه السري خلال ثوانٍ، ويبقى محفوظاً في «كروتي» متى احتجت إليه.'**
  String get aboutBody;

  /// About page: the app version.
  ///
  /// In ar, this message translates to:
  /// **'الإصدار {version}'**
  String aboutVersion(String version);

  /// No description provided for @aboutCopyright.
  ///
  /// In ar, this message translates to:
  /// **'© 2026 دفتر'**
  String get aboutCopyright;

  /// No description provided for @contactWhatsApp.
  ///
  /// In ar, this message translates to:
  /// **'تواصل معنا عبر واتساب'**
  String get contactWhatsApp;

  /// No description provided for @websiteTitle.
  ///
  /// In ar, this message translates to:
  /// **'الموقع الإلكتروني'**
  String get websiteTitle;

  /// No description provided for @privacyPolicy.
  ///
  /// In ar, this message translates to:
  /// **'سياسة الخصوصية'**
  String get privacyPolicy;

  /// No description provided for @termsOfUse.
  ///
  /// In ar, this message translates to:
  /// **'شروط الاستخدام'**
  String get termsOfUse;

  /// No description provided for @openSourceLicenses.
  ///
  /// In ar, this message translates to:
  /// **'تراخيص البرامج مفتوحة المصدر'**
  String get openSourceLicenses;

  /// Under the sign-in button; {terms} and {privacy} are links named by termsOfUse and privacyPolicy.
  ///
  /// In ar, this message translates to:
  /// **'بالمتابعة، أنت توافق على {terms} و{privacy}.'**
  String signInConsent(String terms, String privacy);

  /// No description provided for @cardPayTitle.
  ///
  /// In ar, this message translates to:
  /// **'الدفع بالبطاقة المصرفية'**
  String get cardPayTitle;

  /// No description provided for @cardThroughMoamalat.
  ///
  /// In ar, this message translates to:
  /// **'عبر بوابة معاملات'**
  String get cardThroughMoamalat;

  /// No description provided for @cardNumberLabel.
  ///
  /// In ar, this message translates to:
  /// **'رقم البطاقة'**
  String get cardNumberLabel;

  /// No description provided for @cardExpiryLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الانتهاء'**
  String get cardExpiryLabel;

  /// No description provided for @cardNumberInvalid.
  ///
  /// In ar, this message translates to:
  /// **'رقم البطاقة غير صحيح.'**
  String get cardNumberInvalid;

  /// No description provided for @cardExpiryInvalid.
  ///
  /// In ar, this message translates to:
  /// **'أدخل تاريخ الانتهاء كما على البطاقة: شهر/سنة.'**
  String get cardExpiryInvalid;

  /// No description provided for @cardSecureNote.
  ///
  /// In ar, this message translates to:
  /// **'تذهب بيانات بطاقتك من هاتفك إلى بوابة معاملات مباشرة، فلا تمرّ بخوادمنا ولا نحتفظ بها.'**
  String get cardSecureNote;

  /// No description provided for @cardOpening.
  ///
  /// In ar, this message translates to:
  /// **'نجهّز الدفع الآمن…'**
  String get cardOpening;

  /// No description provided for @cardCharging.
  ///
  /// In ar, this message translates to:
  /// **'نتواصل مع بنكك…'**
  String get cardCharging;

  /// No description provided for @cardConfirming.
  ///
  /// In ar, this message translates to:
  /// **'تم الدفع، نؤكّد طلبك…'**
  String get cardConfirming;

  /// No description provided for @cardVerifyTitle.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد من بنكك'**
  String get cardVerifyTitle;

  /// No description provided for @cardVerifyBody.
  ///
  /// In ar, this message translates to:
  /// **'أرسل بنكك رمزاً إلى هاتفك. أدخله في صفحة البنك أدناه لإتمام الدفع.'**
  String get cardVerifyBody;

  /// No description provided for @cardVerifyCancel.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء'**
  String get cardVerifyCancel;

  /// No description provided for @cardErrDeclined.
  ///
  /// In ar, this message translates to:
  /// **'رفض البنك العملية. تأكّد من بيانات البطاقة ورصيدها، أو جرّب بطاقة أخرى.'**
  String get cardErrDeclined;

  /// No description provided for @cardErrExpiry.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ انتهاء البطاقة غير صحيح.'**
  String get cardErrExpiry;

  /// No description provided for @cardErrNetwork.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر الوصول إلى بوابة الدفع. تحقّق من الإنترنت وحاول مجدداً.'**
  String get cardErrNetwork;

  /// No description provided for @cardErrVerification.
  ///
  /// In ar, this message translates to:
  /// **'لم يكتمل التأكيد من بنكك، ولم يُخصم شيء. حاول مجدداً.'**
  String get cardErrVerification;

  /// No description provided for @cardErrExpired.
  ///
  /// In ar, this message translates to:
  /// **'انتهت مهلة الدفع. حاول مجدداً.'**
  String get cardErrExpired;

  /// No description provided for @cardUsePaymentPage.
  ///
  /// In ar, this message translates to:
  /// **'الدفع من صفحة البوابة بدلاً من ذلك'**
  String get cardUsePaymentPage;

  /// No description provided for @cardNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم حامل البطاقة'**
  String get cardNameLabel;

  /// No description provided for @cardNameInvalid.
  ///
  /// In ar, this message translates to:
  /// **'أدخل الاسم كما هو مكتوب على البطاقة.'**
  String get cardNameInvalid;

  /// No description provided for @savedCardsTitle.
  ///
  /// In ar, this message translates to:
  /// **'بطاقاتك المحفوظة'**
  String get savedCardsTitle;

  /// No description provided for @useAnotherCard.
  ///
  /// In ar, this message translates to:
  /// **'استخدم بطاقة أخرى'**
  String get useAnotherCard;

  /// No description provided for @saveCardTitle.
  ///
  /// In ar, this message translates to:
  /// **'احفظ البطاقة على هذا الهاتف'**
  String get saveCardTitle;

  /// No description provided for @saveCardBody.
  ///
  /// In ar, this message translates to:
  /// **'لتدفع بها أسرع في المرة القادمة. تبقى مشفّرة على هاتفك وحده، وتُفتح ببصمة الوجه أو رمز الهاتف، ولا تصلنا أبداً.'**
  String get saveCardBody;

  /// No description provided for @savedCardUnlockReason.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد هويتك للدفع بالبطاقة المحفوظة'**
  String get savedCardUnlockReason;

  /// Under a saved card: its expiry, e.g. 01/30.
  ///
  /// In ar, this message translates to:
  /// **'تنتهي {expiry}'**
  String savedCardExpires(String expiry);

  /// No description provided for @savedCardsSettings.
  ///
  /// In ar, this message translates to:
  /// **'البطاقات المحفوظة'**
  String get savedCardsSettings;

  /// No description provided for @savedCardsEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد بطاقات محفوظة على هذا الهاتف. يمكنك حفظ بطاقة عند الدفع بها.'**
  String get savedCardsEmpty;

  /// No description provided for @savedCardsNote.
  ///
  /// In ar, this message translates to:
  /// **'تُحفظ البطاقات على هذا الهاتف وحده، مشفّرة وخلف بصمة الوجه أو رمز الهاتف، ولا تصل إلى خوادمنا. تُحذف عند تسجيل الخروج.'**
  String get savedCardsNote;

  /// No description provided for @removeCard.
  ///
  /// In ar, this message translates to:
  /// **'إزالة'**
  String get removeCard;

  /// No description provided for @removeCardTitle.
  ///
  /// In ar, this message translates to:
  /// **'إزالة البطاقة؟'**
  String get removeCardTitle;

  /// No description provided for @removeCardBody.
  ///
  /// In ar, this message translates to:
  /// **'ستُحذف من هذا الهاتف. يمكنك حفظها مجدداً عند الدفع بها.'**
  String get removeCardBody;

  /// No description provided for @savedCardLocked.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم التحقق من هويتك، فلم نستخدم البطاقة المحفوظة.'**
  String get savedCardLocked;

  /// No description provided for @payNotFinishedTitle.
  ///
  /// In ar, this message translates to:
  /// **'لم يكتمل الدفع'**
  String get payNotFinishedTitle;

  /// No description provided for @payNotFinishedBody.
  ///
  /// In ar, this message translates to:
  /// **'لم يُخصم شيء بعد. أكمل الدفع بالبطاقة، أو ألغِ الطلب.'**
  String get payNotFinishedBody;

  /// No description provided for @payNotFinishedWalletBody.
  ///
  /// In ar, this message translates to:
  /// **'لم يُخصم شيء بعد. رمز المحفظة يُطلب عند الشراء فقط، فألغِ هذا الطلب ثم اشترِ من جديد.'**
  String get payNotFinishedWalletBody;

  /// No description provided for @finishPaying.
  ///
  /// In ar, this message translates to:
  /// **'أكمل الدفع'**
  String get finishPaying;

  /// No description provided for @orderCancelled.
  ///
  /// In ar, this message translates to:
  /// **'تم إلغاء الطلب.'**
  String get orderCancelled;

  /// No description provided for @onboardingSkip.
  ///
  /// In ar, this message translates to:
  /// **'تخطَّ'**
  String get onboardingSkip;

  /// No description provided for @onboardingNext.
  ///
  /// In ar, this message translates to:
  /// **'التالي'**
  String get onboardingNext;

  /// No description provided for @onboardingStart.
  ///
  /// In ar, this message translates to:
  /// **'ابدأ الآن'**
  String get onboardingStart;

  /// Onboarding progress for screen readers, e.g. Step 1 of 3.
  ///
  /// In ar, this message translates to:
  /// **'الخطوة {current} من {total}'**
  String onboardingStep(int current, int total);

  /// No description provided for @onboardingShelfTitle.
  ///
  /// In ar, this message translates to:
  /// **'كل كروتك في مكان واحد'**
  String get onboardingShelfTitle;

  /// No description provided for @onboardingShelfBody.
  ///
  /// In ar, this message translates to:
  /// **'رصيد ليبيانا والمدار وباقات الإنترنت وغيرها، تختارها في ثوانٍ وبأسعار واضحة.'**
  String get onboardingShelfBody;

  /// No description provided for @onboardingInstantTitle.
  ///
  /// In ar, this message translates to:
  /// **'ادفع، ويصلك الرقم فوراً'**
  String get onboardingInstantTitle;

  /// No description provided for @onboardingInstantBody.
  ///
  /// In ar, this message translates to:
  /// **'ادفع بمحفظتك أو ببطاقتك المصرفية، فيظهر الرقم السري لكرتك خلال ثوانٍ.'**
  String get onboardingInstantBody;

  /// No description provided for @onboardingVaultTitle.
  ///
  /// In ar, this message translates to:
  /// **'كروتك محفوظة بأمان'**
  String get onboardingVaultTitle;

  /// No description provided for @onboardingVaultBody.
  ///
  /// In ar, this message translates to:
  /// **'كل كرت تشتريه يبقى في «كروتي» محمياً بقفل هاتفك، جاهزاً متى احتجته.'**
  String get onboardingVaultBody;

  /// No description provided for @onboardingNotifyTitle.
  ///
  /// In ar, this message translates to:
  /// **'العروض تصلك أولاً'**
  String get onboardingNotifyTitle;

  /// No description provided for @onboardingNotifyBody.
  ///
  /// In ar, this message translates to:
  /// **'فعّل الإشعارات لنخبرك بالعروض والكروت الجديدة لحظة وصولها.'**
  String get onboardingNotifyBody;

  /// No description provided for @onboardingNotifyAllow.
  ///
  /// In ar, this message translates to:
  /// **'تفعيل الإشعارات'**
  String get onboardingNotifyAllow;

  /// No description provided for @onboardingNotifyLater.
  ///
  /// In ar, this message translates to:
  /// **'ليس الآن'**
  String get onboardingNotifyLater;

  /// No description provided for @onboardingNotifyOnBody.
  ///
  /// In ar, this message translates to:
  /// **'الإشعارات مفعّلة: نخبرك بالعروض والكروت الجديدة لحظة وصولها.'**
  String get onboardingNotifyOnBody;

  /// No description provided for @onboardingReplay.
  ///
  /// In ar, this message translates to:
  /// **'جولة في التطبيق'**
  String get onboardingReplay;

  /// No description provided for @getAppBody.
  ///
  /// In ar, this message translates to:
  /// **'أسرع على هاتفك، وكروتك معك دائماً'**
  String get getAppBody;

  /// No description provided for @getAppAction.
  ///
  /// In ar, this message translates to:
  /// **'تحميل'**
  String get getAppAction;

  /// No description provided for @licensesIntro.
  ///
  /// In ar, this message translates to:
  /// **'يقوم «دفتر كروت» على برامج مفتوحة المصدر، والشكر لأصحابها. هذه تراخيصها كما نُشرت، بلغتها الأصلية.'**
  String get licensesIntro;

  /// Search page: its title.
  ///
  /// In ar, this message translates to:
  /// **'البحث'**
  String get searchTitle;

  /// Search page: heading over the categories to browse before typing.
  ///
  /// In ar, this message translates to:
  /// **'تصفّح الأقسام'**
  String get searchBrowseCategories;

  /// My cards filter: purchases that did not go through (failed, expired, refunded).
  ///
  /// In ar, this message translates to:
  /// **'لم تكتمل'**
  String get filterIncomplete;

  /// «كروتي»: a filter with nothing in it.
  ///
  /// In ar, this message translates to:
  /// **'استخدمت كل كروتك'**
  String get myCardsNoneUnusedTitle;

  /// «كروتي»: a filter with nothing in it.
  ///
  /// In ar, this message translates to:
  /// **'الكروت التي لم تستخدم رمزها بعد تظهر هنا.'**
  String get myCardsNoneUnusedBody;

  /// «كروتي»: a filter with nothing in it.
  ///
  /// In ar, this message translates to:
  /// **'لا كروت مستخدمة بعد'**
  String get myCardsNoneUsedTitle;

  /// «كروتي»: a filter with nothing in it.
  ///
  /// In ar, this message translates to:
  /// **'بعد أن تشحن كرتاً، اضغط «استخدمته» في صفحته لينتقل إلى هنا.'**
  String get myCardsNoneUsedBody;

  /// «كروتي»: a filter with nothing in it.
  ///
  /// In ar, this message translates to:
  /// **'كل طلباتك اكتملت'**
  String get myCardsNoneIncompleteTitle;

  /// «كروتي»: a filter with nothing in it.
  ///
  /// In ar, this message translates to:
  /// **'إن تعذّر طلب يوماً يظهر هنا، ويعود ثمنه إلى رصيدك.'**
  String get myCardsNoneIncompleteBody;

  /// Badge on a card a store build (iPhone, Google Play) lists but cannot sell: it is bought on the website.
  ///
  /// In ar, this message translates to:
  /// **'على الموقع'**
  String get webOnlyBadge;

  /// Brand page, in place of the buy button, on a card bought on the website only.
  ///
  /// In ar, this message translates to:
  /// **'متوفرة على الموقع'**
  String get webOnlyTitle;

  /// Brand page: where a website-only card is bought.
  ///
  /// In ar, this message translates to:
  /// **'هذه البطاقة لا تُشترى من هذا التطبيق. تجدها على موقعنا cards.dftr.ly'**
  String get webOnlyBody;

  /// Badge, with Steam's logo, on a game played on Steam: a Steam key or a game sent as a Steam gift.
  ///
  /// In ar, this message translates to:
  /// **'ستيم'**
  String get steamBadge;

  /// Badge, with Xbox's logo, on a game key activated on Xbox or the Microsoft Store.
  ///
  /// In ar, this message translates to:
  /// **'إكس بوكس'**
  String get xboxBadge;

  /// Badge, with EA's logo, on a game key activated in the EA app. EA is the brand's own name.
  ///
  /// In ar, this message translates to:
  /// **'EA'**
  String get eaBadge;

  /// Badge, with Rockstar Games' logo, on a game key activated with a Rockstar Games account.
  ///
  /// In ar, this message translates to:
  /// **'روكستار'**
  String get rockstarBadge;

  /// First-run question: how the customer found the app.
  ///
  /// In ar, this message translates to:
  /// **'من أين سمعت عن دفتر كروت؟'**
  String get heardFromTitle;

  /// No description provided for @heardFromBody.
  ///
  /// In ar, this message translates to:
  /// **'اختر جواباً واحداً، يساعدنا على الوصول لمن يحتاج التطبيق.'**
  String get heardFromBody;

  /// No description provided for @heardFromFacebook.
  ///
  /// In ar, this message translates to:
  /// **'فيسبوك'**
  String get heardFromFacebook;

  /// No description provided for @heardFromInstagram.
  ///
  /// In ar, this message translates to:
  /// **'إنستغرام'**
  String get heardFromInstagram;

  /// No description provided for @heardFromTiktok.
  ///
  /// In ar, this message translates to:
  /// **'تيك توك'**
  String get heardFromTiktok;

  /// No description provided for @heardFromWhatsapp.
  ///
  /// In ar, this message translates to:
  /// **'واتساب'**
  String get heardFromWhatsapp;

  /// No description provided for @heardFromFriend.
  ///
  /// In ar, this message translates to:
  /// **'صديق أو قريب'**
  String get heardFromFriend;

  /// No description provided for @heardFromShop.
  ///
  /// In ar, this message translates to:
  /// **'محل'**
  String get heardFromShop;

  /// No description provided for @heardFromBillboard.
  ///
  /// In ar, this message translates to:
  /// **'لوحة إعلانية'**
  String get heardFromBillboard;

  /// No description provided for @heardFromStoreSearch.
  ///
  /// In ar, this message translates to:
  /// **'البحث في المتجر'**
  String get heardFromStoreSearch;

  /// No description provided for @heardFromOther.
  ///
  /// In ar, this message translates to:
  /// **'غير ذلك'**
  String get heardFromOther;

  /// Field for a campaign code.
  ///
  /// In ar, this message translates to:
  /// **'عندك رمز من إعلان أو صديق؟'**
  String get campaignCodeLabel;

  /// No description provided for @campaignCodeHint.
  ///
  /// In ar, this message translates to:
  /// **'مثل UNI1'**
  String get campaignCodeHint;

  /// No description provided for @campaignCodeCheck.
  ///
  /// In ar, this message translates to:
  /// **'تحقّق'**
  String get campaignCodeCheck;

  /// No description provided for @campaignCodeUnknown.
  ///
  /// In ar, this message translates to:
  /// **'هذا الرمز غير معروف أو انتهى.'**
  String get campaignCodeUnknown;

  /// No description provided for @campaignCodeValid.
  ///
  /// In ar, this message translates to:
  /// **'رمز صحيح، شكراً لك.'**
  String get campaignCodeValid;

  /// A valid code with a reward, before sign-in.
  ///
  /// In ar, this message translates to:
  /// **'رمز صحيح: يُضاف {amount} إلى رصيدك حين تسجّل الدخول.'**
  String campaignCodeRewardLater(String amount);

  /// A valid code with a reward, signed in.
  ///
  /// In ar, this message translates to:
  /// **'رمز صحيح: يُضاف {amount} إلى رصيدك.'**
  String campaignCodeRewardNow(String amount);

  /// A followed campaign link with a reward, shown in the question.
  ///
  /// In ar, this message translates to:
  /// **'وصلت برمز {code}: يُضاف {amount} إلى رصيدك حين تسجّل الدخول.'**
  String campaignLinkReward(String code, String amount);

  /// After sign-in: a campaign's credit landed.
  ///
  /// In ar, this message translates to:
  /// **'أُضيف {amount} إلى رصيدك'**
  String rewardTitle(String amount);

  /// No description provided for @rewardBecauseCode.
  ///
  /// In ar, this message translates to:
  /// **'لأنك استخدمت الرمز {code}.'**
  String rewardBecauseCode(String code);

  /// No description provided for @rewardBecauseCreator.
  ///
  /// In ar, this message translates to:
  /// **'لأنك جئت عن طريق {name}.'**
  String rewardBecauseCreator(String name);

  /// No description provided for @rewardBecauseCreatorUnnamed.
  ///
  /// In ar, this message translates to:
  /// **'لأنك جئت عن طريق صانع محتوى نتعاون معه.'**
  String get rewardBecauseCreatorUnnamed;

  /// No description provided for @rewardBecauseFlyer.
  ///
  /// In ar, this message translates to:
  /// **'لأنك مسحت رمز {name}.'**
  String rewardBecauseFlyer(String name);

  /// No description provided for @rewardBecauseFlyerUnnamed.
  ///
  /// In ar, this message translates to:
  /// **'لأنك مسحت رمز الملصق.'**
  String get rewardBecauseFlyerUnnamed;

  /// No description provided for @rewardBecauseBillboardUnnamed.
  ///
  /// In ar, this message translates to:
  /// **'لأنك مسحت رمز اللوحة الإعلانية.'**
  String get rewardBecauseBillboardUnnamed;

  /// No description provided for @rewardBecauseInvite.
  ///
  /// In ar, this message translates to:
  /// **'لأنك جئت بدعوة من {name}.'**
  String rewardBecauseInvite(String name);

  /// No description provided for @rewardBecauseInviteUnnamed.
  ///
  /// In ar, this message translates to:
  /// **'لأنك جئت بدعوة صديق.'**
  String get rewardBecauseInviteUnnamed;

  /// No description provided for @rewardBecauseAd.
  ///
  /// In ar, this message translates to:
  /// **'لأنك جئت من إعلاننا.'**
  String get rewardBecauseAd;

  /// No description provided for @rewardBody.
  ///
  /// In ar, this message translates to:
  /// **'يُخصم تلقائياً من سعر كرتك القادم، دون أي رسوم.'**
  String get rewardBody;

  /// No description provided for @rewardAction.
  ///
  /// In ar, this message translates to:
  /// **'تسوّق الآن'**
  String get rewardAction;

  /// Brand page pill: credit sent straight to an account, no code.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, invite{هدية على حسابك} other{شحن مباشر}}'**
  String topUpPill(String kind);

  /// Brand page: heading of the account a top-up goes to.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, telegram{حساب تيليجرام} steam{حساب ستيم} invite{حساب ستيم} other{حساب اللاعب}}'**
  String topUpAccountTitle(String kind);

  /// Brand page: how a top-up arrives.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, telegram{تصل مباشرة إلى الحساب، دون رمز تُدخله.} steam{يُضاف الرصيد مباشرة إلى محفظتك في ستيم.} invite{تصلك اللعبة هدية على حسابك في ستيم، دون رمز تُدخله.} other{يصل الشحن مباشرة إلى حسابك في اللعبة، دون رمز تُدخله.}}'**
  String topUpAccountBody(String kind);

  /// Brand page: opens the help on finding the account.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, telegram{أين أجد اسم المستخدم؟} steam{ما اسم الدخول؟} invite{كيف أحصل على الرابط؟} other{أين أجد المعرّف؟}}'**
  String topUpHintTitle(String kind);

  /// Brand page heading for a top-up's amounts.
  ///
  /// In ar, this message translates to:
  /// **'اختر الكمية'**
  String get chooseAmount;

  /// Accounts this phone topped up before.
  ///
  /// In ar, this message translates to:
  /// **'حساباتك'**
  String get savedAccounts;

  /// Start typing an account not used before.
  ///
  /// In ar, this message translates to:
  /// **'حساب آخر'**
  String get otherAccount;

  /// Removes a saved account (screen readers).
  ///
  /// In ar, this message translates to:
  /// **'انسَ {account}'**
  String forgetAccount(String account);

  /// Paste from the clipboard.
  ///
  /// In ar, this message translates to:
  /// **'لصق'**
  String get pasteAction;

  /// Shown when the browser refuses to let the paste button read the clipboard.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر اللصق من الحافظة. الصق داخل الخانة مباشرة.'**
  String get pasteFailed;

  /// Placeholder of a choice field.
  ///
  /// In ar, this message translates to:
  /// **'اختر'**
  String get chooseOption;

  /// A typed account field is empty.
  ///
  /// In ar, this message translates to:
  /// **'أدخل {field}'**
  String accountRequired(String field);

  /// A choice field is empty.
  ///
  /// In ar, this message translates to:
  /// **'اختر {field}'**
  String accountChoose(String field);

  /// An account field is too long.
  ///
  /// In ar, this message translates to:
  /// **'أطول مما يجب.'**
  String get accountTooLong;

  /// Not a Telegram username.
  ///
  /// In ar, this message translates to:
  /// **'اسم المستخدم من 5 إلى 32 حرفاً إنجليزياً أو رقماً أو _، ويبدأ بحرف.'**
  String get accountNotTelegram;

  /// Not a Steam login.
  ///
  /// In ar, this message translates to:
  /// **'اسم الدخول حروف إنجليزية وأرقام و _ فقط، دون مسافات.'**
  String get accountNotSteamLogin;

  /// Not a Steam friend invite link.
  ///
  /// In ar, this message translates to:
  /// **'هذا ليس رابط دعوة من ستيم. انسخ «رابط الدعوة السريعة» من ستيم كما هو والصقه هنا.'**
  String get accountNotInvite;

  /// The account is being looked up.
  ///
  /// In ar, this message translates to:
  /// **'نتحقق من الحساب…'**
  String get accountChecking;

  /// The game found the account under this name.
  ///
  /// In ar, this message translates to:
  /// **'اللاعب: {name}'**
  String accountPlayer(String name);

  /// The account exists (no name given).
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, steam{يمكن شحن هذا الحساب} other{وجدنا الحساب}}'**
  String accountFound(String kind);

  /// The game has no such account.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, steam{لا يمكن شحن حساب ستيم هذا. تأكد من اسم الدخول.} other{لا يوجد حساب بهذا المعرّف. تأكد منه في ملفك داخل اللعبة.}}'**
  String accountNotFound(String kind);

  /// The look-up could not tell.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر التأكد من الحساب الآن. راجعه جيداً قبل الدفع.'**
  String get accountUnconfirmed;

  /// Checkout: the account cannot be looked up, so check it.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, invite{تأكد من الرابط: تُرسل الهدية إلى صاحبه.} telegram{تأكد من اسم المستخدم: تُرسل إليه مباشرة ولا تُسترجع.} other{تأكد من المعرّف: يصل الشحن إليه مباشرة ولا يُسترجع.}}'**
  String accountUnchecked(String kind);

  /// Brand page buy button for a card sent to an account.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, invite{اشترِ} telegram{اشترِ} other{اشحن}}'**
  String topUpAction(String kind);

  /// Buy bar: where the top-up goes.
  ///
  /// In ar, this message translates to:
  /// **'إلى {account}'**
  String buyBarTo(String account);

  /// Buy bar: the account is still to be typed.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, telegram{أدخل اسم المستخدم} steam{أدخل اسم الدخول} invite{الصق رابط الدعوة} other{أدخل المعرّف}}'**
  String buyBarNeedsAccount(String kind);

  /// Checkout: label of the account row.
  ///
  /// In ar, this message translates to:
  /// **'إلى'**
  String get sendToLabel;

  /// Edit what was typed.
  ///
  /// In ar, this message translates to:
  /// **'تعديل'**
  String get editAction;

  /// Order paid, the top-up on its way.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, invite{نرسل لك الهدية…} telegram{نشحن حساب تيليجرام…} steam{نضيف الرصيد إلى محفظة ستيم…} other{نشحن حساب اللاعب…}}'**
  String topUpPreparingTitle(String kind);

  /// Order paid, the top-up on its way.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, invite{يصلك من ستيم طلب صداقة ثم الهدية: اقبلهما حين يصلان.} other{نرسل {item} إلى {account}. يصل عادةً خلال دقيقة أو دقيقتين.}}'**
  String topUpPreparingBody(String kind, String item, String account);

  /// Top-up paid, still not arrived after the relay's wait; by the kind of account.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, invite{تتأخر الهدية هذه المرة} steam{تتأخر إضافة الرصيد هذه المرة} other{يتأخر الشحن هذه المرة}}'**
  String topUpSlowTitle(String kind);

  /// Paid but the top-up failed: refunded to credit; by the kind of account.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, invite{لم تُرسل الهدية} steam{لم يُضف الرصيد} other{لم يكتمل الشحن}}'**
  String topUpRefundedTitle(String kind);

  /// Refund of a failed top-up, naming what to check for the kind of account.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, invite{لم تُرسل الهدية، فأعدنا {amount} إلى رصيدك. تأكد من رابط الدعوة ثم حاول مجدداً.} telegram{لم يصل الشحن إلى حساب تيليجرام، فأعدنا {amount} إلى رصيدك. تأكد من اسم المستخدم ثم حاول مجدداً.} steam{لم يُضف الرصيد إلى محفظة ستيم، فأعدنا {amount} إلى رصيدك. تأكد من اسم الدخول ثم حاول مجدداً.} other{لم يصل الشحن إلى حساب اللاعب، فأعدنا {amount} إلى رصيدك. تأكد من المعرّف ثم حاول مجدداً.}}'**
  String topUpRefundedBody(String kind, String amount);

  /// A top-up arrived.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, invite{أُرسلت الهدية} other{تمّ الشحن}}'**
  String toppedUpTitle(String kind);

  /// Receipt row: the account.
  ///
  /// In ar, this message translates to:
  /// **'إلى'**
  String get receiptTo;

  /// Receipt row: the player's name.
  ///
  /// In ar, this message translates to:
  /// **'اللاعب'**
  String get receiptPlayer;

  /// Receipt row: what was paid.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ'**
  String get receiptPaid;

  /// Receipt row: when.
  ///
  /// In ar, this message translates to:
  /// **'الوقت'**
  String get receiptWhen;

  /// Receipt row: the order's number.
  ///
  /// In ar, this message translates to:
  /// **'رقم الطلب'**
  String get receiptOrder;

  /// Receipt: what to do now.
  ///
  /// In ar, this message translates to:
  /// **'ماذا بعد؟'**
  String get whatNextTitle;

  /// Receipt: what to do after a top-up.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, telegram{افتح تيليجرام: تجدها في حسابك خلال دقائق.} steam{افتح ستيم: يظهر الرصيد في محفظتك خلال دقائق.} invite{من ستيم: اقبل طلب الصداقة الذي يصلك، ثم الهدية من الإشعارات. تصل الهدية بعد قبول الصداقة بدقائق.} other{افتح اللعبة: يظهر الرصيد في حسابك خلال دقائق. إن لم يظهر، أغلق اللعبة وافتحها من جديد.}}'**
  String topUpNext(String kind);

  /// Receipt: buy the same again.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, invite{اشترِ هدية أخرى} other{اشحن مجدداً}}'**
  String topUpAgain(String kind);

  /// Receipt: support link.
  ///
  /// In ar, this message translates to:
  /// **'لم يصلك؟ راسلنا على واتساب'**
  String get topUpHelp;

  /// Prefilled support message, by the kind of account.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, invite{مرحباً، الطلب رقم {order}: لم تصلني الهدية.} telegram{مرحباً، الطلب رقم {order} لم يصل إلى حساب تيليجرام.} steam{مرحباً، الطلب رقم {order} لم يُضف إلى محفظة ستيم.} other{مرحباً، الطلب رقم {order} لم يصل إلى حساب اللاعب.}}'**
  String topUpHelpMessage(String kind, String order);

  /// Snackbar after copying the order number.
  ///
  /// In ar, this message translates to:
  /// **'نُسخ رقم الطلب'**
  String get orderIdCopied;

  /// Order status chip: sent to the account.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, invite{أُرسلت الهدية} other{تمّ الشحن}}'**
  String statusToppedUp(String kind);

  /// Order status chip: top-up on its way.
  ///
  /// In ar, this message translates to:
  /// **'قيد الشحن'**
  String get statusToppingUp;

  /// My cards row: where a top-up went.
  ///
  /// In ar, this message translates to:
  /// **'إلى {account}'**
  String orderTo(String account);

  /// Swipe action: forget a saved account.
  ///
  /// In ar, this message translates to:
  /// **'إزالة'**
  String get removeAccount;

  /// Snackbar after forgetting a saved account.
  ///
  /// In ar, this message translates to:
  /// **'أُزيل {account} من هذا الهاتف'**
  String accountRemoved(String account);

  /// Undo the last step.
  ///
  /// In ar, this message translates to:
  /// **'تراجع'**
  String get undoAction;

  /// Brand page heading for a game's editions.
  ///
  /// In ar, this message translates to:
  /// **'اختر الإصدار'**
  String get chooseEdition;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'إلى أين تسافر؟'**
  String get esimStoreTitle;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'سافر متصلاً من أول لحظة'**
  String get esimEntryTitle;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'إنترنت لأكثر من 200 وجهة، تثبّته بلمسة واحدة.'**
  String get esimEntryBody;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'اختر وجهتك'**
  String get esimEntryAction;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'شرائحي'**
  String get esimMineTitle;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن دولة أو منطقة'**
  String get esimSearchHint;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'مسح البحث'**
  String get esimSearchClear;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'دول'**
  String get esimKindLocal;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'مناطق'**
  String get esimKindRegional;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'عالمية'**
  String get esimKindGlobal;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'الأكثر طلباً'**
  String get esimPopular;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'كل الدول'**
  String get esimAllCountries;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد وجهة بهذا الاسم.'**
  String get esimNoMatch;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'تبدأ من'**
  String get esimFrom;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'الشرائح غير متاحة الآن'**
  String get esimClosedTitle;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'عُد بعد قليل، أو تواصل معنا إذا كنت تحتاجها الآن.'**
  String get esimClosedBody;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر التحميل'**
  String get esimLoadFailed;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'أعد المحاولة'**
  String get esimTryAgain;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'هاتفك يدعم الشرائح الإلكترونية'**
  String get esimPhoneSupported;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'يبدو أن هاتفك لا يدعم الشرائح الإلكترونية'**
  String get esimPhoneNotSupported;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'ما زال بإمكانك شراء شريحة لشخص تعرفه وإرسالها إليه. وإن كنت متأكداً أن هاتفك يدعمها، فتحقق من إعدادات الهاتف أولاً.'**
  String get esimPhoneNotSupportedBody;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'غير محدودة'**
  String get esimUnlimited;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'الشبكات'**
  String get esimNetworks;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'البيانات'**
  String get esimFactData;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'الصلاحية'**
  String get esimFactValidity;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'الشبكة'**
  String get esimFactNetwork;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'الشحن'**
  String get esimFactTopUp;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'يمكن شحنها'**
  String get esimTopUpYes;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكن شحنها'**
  String get esimTopUpNo;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'تبدأ الصلاحية عند أول اتصال بالشبكة في وجهتك، لا عند الشراء ولا عند التثبيت.'**
  String get esimStartsOnFirstUse;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'يجب أن يكون هاتفك غير مقفل على شركة اتصالات. الهواتف المقفلة قد لا تقبل الشريحة.'**
  String get esimUnlockedNote;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'بيانات فقط: لا تتضمن رقم هاتف ولا مكالمات عادية.'**
  String get esimDataOnlyNote;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'لمن هذه الشريحة؟'**
  String get esimWhoFor;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'لهاتفي'**
  String get esimForMe;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'لشخص آخر'**
  String get esimForSomeoneElse;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'اسمه (اختياري)'**
  String get esimRecipientName;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'بعد الدفع نعطيك رابطاً ترسله إليه، ويثبّتها من هاتفه بلمسة. الشريحة تعمل على هاتف واحد فقط.'**
  String get esimForSomeoneElseNote;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'قد لا تعمل الشريحة على هذا الهاتف، ولا يمكن استرداد شريحة بعد تثبيتها. تأكد أولاً من الإعدادات.'**
  String get esimForMeUnsupportedNote;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'لم تُفعَّل بعد'**
  String get esimStatusNotActive;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'فعّالة'**
  String get esimStatusActive;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'نفدت'**
  String get esimStatusFinished;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'انتهت'**
  String get esimStatusExpired;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'قيد التحقق'**
  String get esimStatusUnknown;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'متبقية من'**
  String get esimLeftOf;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'تنتهي اليوم'**
  String get esimEndsToday;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'قاربت على الانتهاء: اشحنها لتبقى متصلاً.'**
  String get esimRunningOutTopUp;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'قاربت على الانتهاء: اشترِ شريحة جديدة لتبقى متصلاً.'**
  String get esimRunningOutNew;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'شريحتك جاهزة'**
  String get esimReadyTitle;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'بقيت خطوة واحدة: ثبّتها الآن أثناء اتصالك بالإنترنت، وستبدأ العمل عند وصولك.'**
  String get esimReadyBody;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'أرسلها الآن، وسيثبّتها صاحبها من هاتفه بلمسة.'**
  String get esimReadyBodyGift;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'ثبّت الشريحة الآن'**
  String get esimInstallNow;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'ثبّتها على هذا الهاتف'**
  String get esimInstallHere;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'سيفتح هاتفك شاشة إضافة الشريحة، ولا تحتاج إلى مسح أي رمز.'**
  String get esimInstallHint;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'لم يفتح هاتفك شاشة التثبيت. استخدم الرمز أو أدخل البيانات يدوياً.'**
  String get esimInstallFailedNote;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'أرسلها إلى شخص آخر'**
  String get esimSendTo;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'طرق أخرى للتثبيت'**
  String get esimOtherWays;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'ثبّتها بالفعل'**
  String get esimAlreadyInstalled;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'عرض طرق التثبيت مجدداً'**
  String get esimShowInstallAgain;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'تحتاج إلى اتصال بالإنترنت أثناء التثبيت.'**
  String get esimNeedsInternetNote;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'تعمل الشريحة على هاتف واحد ولا تُنقل إلى غيره. لا تحذفها بعد تثبيتها.'**
  String get esimOneDeviceNote;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'هل أُضيفت الشريحة؟'**
  String get esimInstallAskTitle;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'إذا ظهرت في إعدادات الهاتف ضمن شرائح الجوال، فقد تم التثبيت.'**
  String get esimInstallAskBody;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'نعم، أُضيفت'**
  String get esimInstallAskYes;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'لم تُضَف'**
  String get esimInstallAskNo;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل بيانات التثبيت.'**
  String get esimInstallUnreadable;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'امسح الرمز من هاتف آخر'**
  String get esimQrTitle;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'افتح هذا الرمز على شاشة أخرى، ثم في الهاتف: الإعدادات ← شبكة الجوال ← إضافة شريحة eSIM ← استخدام رمز QR.'**
  String get esimQrStepsIos;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'افتح هذا الرمز على شاشة أخرى، ثم في الهاتف: الإعدادات ← الشبكة والإنترنت ← شرائح SIM ← إضافة شريحة eSIM.'**
  String get esimQrStepsAndroid;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'في الهاتف الذي ستعمل عليه الشريحة، افتح إعدادات شبكة الجوال، واختر إضافة شريحة eSIM، ثم امسح هذا الرمز.'**
  String get esimQrStepsOther;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'أو أدخل البيانات يدوياً'**
  String get esimManualTitle;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'عنوان SM-DP+'**
  String get esimSmdp;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'رمز التفعيل'**
  String get esimActivationCode;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'رمز التأكيد'**
  String get esimConfirmationCode;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'نسخ'**
  String get esimCopy;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'تم النسخ'**
  String get esimCopied;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'لتعمل الشريحة'**
  String get esimNextStepsTitle;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'في إعدادات شبكة الجوال، اختر هذه الشريحة لبيانات الجوال.'**
  String get esimStepDataLine;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'شغّل «تجوال البيانات» لهذه الشريحة.'**
  String get esimStepRoaming;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'أدخل نقطة الوصول (APN) التالية في إعدادات الشريحة:'**
  String get esimStepApn;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'عند وصولك إلى وجهتك، ستتصل الشريحة بالشبكة تلقائياً.'**
  String get esimStepArrive;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'نقطة الوصول (APN)'**
  String get esimApn;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'انتهت هذه الشريحة ولا يمكن استخدامها مجدداً.'**
  String get esimEndedNote;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'اشترِ شريحة جديدة'**
  String get esimBuyAnother;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'اشحن هذه الشريحة'**
  String get esimTopUpTitle;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'لا تتوفر باقات شحن لهذه الشريحة الآن.'**
  String get esimNoTopUps;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'أُضيفت الباقة إلى شريحتك.'**
  String get esimTopUpDone;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'تسمية الشريحة'**
  String get esimRenameTitle;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء'**
  String get esimCancel;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'حفظ'**
  String get esimSave;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'رقم الشريحة (ICCID)'**
  String get esimNumber;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'تحتاج إلى مساعدة؟'**
  String get esimHelp;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{دولة واحدة} =2{دولتان} few{{count} دول} other{{count} دولة}}'**
  String esimCountriesCount(int count);

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'صالحة {days, plural, =1{ليوم واحد} =2{ليومين} few{{days} أيام} other{{days} يوماً}}'**
  String esimValidDays(int days);

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'{voice} دقيقة · {text} رسالة'**
  String esimVoiceAndText(int voice, int text);

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'ثبّتها خلال {days, plural, =1{يوم واحد} =2{يومين} few{{days} أيام} other{{days} يوماً}} من الشراء، وإلا فلن تعود صالحة.'**
  String esimInstallWithin(int days);

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'متابعة · {price}'**
  String esimBuyFor(String price);

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'لـ {name}'**
  String esimForName(String name);

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'تنتهي بعد {days, plural, =1{يوم واحد} =2{يومين} few{{days} أيام} other{{days} يوماً}}'**
  String esimEndsInDays(int days);

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'شريحة إنترنت (eSIM) لـ {destination}: {plan}\nافتح هذا الرابط من الهاتف الذي ستعمل عليه:\n{link}\nرمز الدخول: {code}'**
  String esimShareText(
    String destination,
    String plan,
    String link,
    String code,
  );

  /// eSIM screens. Shared when the eSIM's page needs no access code.
  ///
  /// In ar, this message translates to:
  /// **'شريحة إنترنت (eSIM) لـ {destination}: {plan}\nافتح هذا الرابط من الهاتف الذي ستعمل عليه:\n{link}'**
  String esimShareTextNoCode(String destination, String plan, String link);

  /// eSIM screens: a plan's length.
  ///
  /// In ar, this message translates to:
  /// **'{days, plural, =1{يوم واحد} =2{يومان} few{{days} أيام} other{{days} يوماً}}'**
  String esimPlanDays(int days);

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'نجهّز شريحتك…'**
  String get esimPreparingTitle;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'عادةً خلال ثوانٍ. يمكنك إغلاق التطبيق، وستجدها في «كروتي» وسنخبرك حين تصبح جاهزة.'**
  String get esimPreparingBody;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'لم نتمكن من إصدار الشريحة'**
  String get esimRefundedTitle;

  /// eSIM banner: the small line above the title.
  ///
  /// In ar, this message translates to:
  /// **'شرائح eSIM'**
  String get esimEntryKicker;

  /// eSIM banner button, with the lowest price.
  ///
  /// In ar, this message translates to:
  /// **'من {price}'**
  String esimEntryFrom(String price);

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'إنترنت فور وصولك، بلا شريحة بلاستيكية.'**
  String get esimStoreSubtitle;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'كيف تعمل؟'**
  String get esimHowTitle;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'اختر وجهتك'**
  String get esimHow1Title;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'دولة، أو منطقة، أو باقة عالمية تناسب رحلتك.'**
  String get esimHow1Body;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'ثبّتها بلمسة'**
  String get esimHow2Title;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'يضيفها هاتفك بنفسه، بلا رمز ولا خطوات طويلة.'**
  String get esimHow2Body;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'اتصل عند وصولك'**
  String get esimHow3Title;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'تعمل الشريحة بجانب خطك، ويبقى رقمك كما هو.'**
  String get esimHow3Body;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'اضغط لتثبيتها'**
  String get esimTapToInstall;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'اضغط لإرسالها أو تثبيتها'**
  String get esimTapToSend;

  /// eSIM results in the home search.
  ///
  /// In ar, this message translates to:
  /// **'شرائح eSIM للسفر'**
  String get esimSearchSection;

  /// Tag on an eSIM search result.
  ///
  /// In ar, this message translates to:
  /// **'شريحة eSIM'**
  String get esimSearchTag;

  /// Screen reader label of an eSIM search result.
  ///
  /// In ar, this message translates to:
  /// **'شريحة eSIM إلى {name}'**
  String esimSearchRowLabel(String name);

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'بقيت خطوة واحدة'**
  String get esimOneStepTitle;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'ثبّت الشريحة'**
  String get esimInstallAction;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'هذا الهاتف لا يثبّتها بلمسة. امسح الرمز من الهاتف الذي ستعمل عليه.'**
  String get esimScanBody;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'أرسلها الآن'**
  String get esimSendNow;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'أرسلها مرة أخرى'**
  String get esimSendAgain;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'يصله رابط ورمز، ويثبّتها من هاتفه بلمسة.'**
  String get esimSendBody;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'أرسلتها. إن لم تصله، أرسلها مرة أخرى.'**
  String get esimSentBody;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'هدية'**
  String get esimGiftKicker;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'هدية إلى'**
  String get esimGiftTo;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'رابط الشريحة'**
  String get esimShareLink;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'رمز الدخول'**
  String get esimShareCode;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'إظهار رمز QR ليمسحه'**
  String get esimShowQr;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'اشحنها الآن'**
  String get esimTopUpNow;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'اشحن الشريحة'**
  String get esimTopUpAction;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'قاربت على الانتهاء'**
  String get esimLowTitle;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'لمن سترسلها؟'**
  String get esimWhoForTitle;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'متابعة'**
  String get esimContinue;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'التفاصيل'**
  String get esimDetailsTitle;

  /// eSIM page's main button, for someone else's eSIM.
  ///
  /// In ar, this message translates to:
  /// **'أرسلها إلى {name}'**
  String esimSendToName(String name);

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'اشحنها الآن لتبقى متصلاً.'**
  String get esimLowBodyTopUp;

  /// eSIM screens.
  ///
  /// In ar, this message translates to:
  /// **'لا تُشحن هذه الباقة. اشترِ شريحة جديدة لتبقى متصلاً.'**
  String get esimLowBodyNew;

  /// Heading over a top-up order's timeline.
  ///
  /// In ar, this message translates to:
  /// **'حالة الطلب'**
  String get orderStatusHeading;

  /// Heading over a top-up order's receipt.
  ///
  /// In ar, this message translates to:
  /// **'التفاصيل'**
  String get orderDetailsHeading;

  /// Timeline step: the order was placed.
  ///
  /// In ar, this message translates to:
  /// **'تم الطلب'**
  String get orderStepPlaced;

  /// Timeline step: the payment went through.
  ///
  /// In ar, this message translates to:
  /// **'تم الدفع'**
  String get orderStepPaid;

  /// Timeline step: the supplier is topping the account up; by the kind of account.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, invite{إرسال الهدية} telegram{الإرسال إلى حساب تيليجرام} steam{الإضافة إلى محفظة ستيم} other{الإرسال إلى حساب اللاعب}}'**
  String orderStepSending(String kind);

  /// Timeline step: the order ended without a top-up and the money went back.
  ///
  /// In ar, this message translates to:
  /// **'أُعيد المبلغ إلى رصيدك'**
  String get orderStepRefunded;

  /// Opens the report sheet for an order.
  ///
  /// In ar, this message translates to:
  /// **'الإبلاغ عن مشكلة'**
  String get reportProblem;

  /// Report again after our reply.
  ///
  /// In ar, this message translates to:
  /// **'الإبلاغ عن مشكلة أخرى'**
  String get reportAgain;

  /// Report sheet title.
  ///
  /// In ar, this message translates to:
  /// **'ما المشكلة؟'**
  String get reportTitle;

  /// Report sheet explanation.
  ///
  /// In ar, this message translates to:
  /// **'اختر ما حدث، ونراجع طلبك ونرد عليك هنا وفي إشعار.'**
  String get reportBody;

  /// Report reason, by the kind of account.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, invite{لم تصل الهدية} steam{لم يُضف الرصيد} other{لم يصل الشحن}}'**
  String reportNotArrived(String kind);

  /// Report reason, by the kind of account.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, invite{وصلت الهدية إلى حساب آخر} telegram{وصل إلى اسم مستخدم آخر} steam{أُضيف إلى حساب ستيم آخر} other{وصل إلى معرّف لاعب آخر}}'**
  String reportWrongAccount(String kind);

  /// Report reason, by the kind of account.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, invite{وصلت لعبة أو نسخة غير التي طلبتها} other{الكمية غير صحيحة}}'**
  String reportWrongAmount(String kind);

  /// Report reason.
  ///
  /// In ar, this message translates to:
  /// **'مشكلة أخرى'**
  String get reportOther;

  /// Label of the report's note field.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل تساعدنا (اختياري)'**
  String get reportNote;

  /// Hint in the report's note field, by the kind of account.
  ///
  /// In ar, this message translates to:
  /// **'{kind, select, invite{مثلاً: لم يصلني طلب الصداقة} steam{مثلاً: أُضيف جزء من الرصيد فقط} other{مثلاً: وصل جزء من الشحن فقط}}'**
  String reportNoteHint(String kind);

  /// Sends the report.
  ///
  /// In ar, this message translates to:
  /// **'إرسال البلاغ'**
  String get reportSend;

  /// Snackbar after a report was sent.
  ///
  /// In ar, this message translates to:
  /// **'وصلنا بلاغك. نراجعه ونرد عليك.'**
  String get reportSent;

  /// Card title while a report is open.
  ///
  /// In ar, this message translates to:
  /// **'بلاغك قيد المراجعة'**
  String get reportOpenTitle;

  /// Card body while a report is open.
  ///
  /// In ar, this message translates to:
  /// **'أبلغت: {reason}. نرد عليك هنا وفي إشعار.'**
  String reportOpenBody(String reason);

  /// Card title once a report was resolved.
  ///
  /// In ar, this message translates to:
  /// **'ردّنا على بلاغك'**
  String get reportReplyTitle;

  /// Shown when a report was resolved without a written reply.
  ///
  /// In ar, this message translates to:
  /// **'راجعنا بلاغك عن هذا الطلب.'**
  String get reportResolvedBody;

  /// Secondary way to reach us from the report sheet.
  ///
  /// In ar, this message translates to:
  /// **'أو راسلنا على واتساب'**
  String get reportWhatsApp;

  /// eSIM banner: a short perk.
  ///
  /// In ar, this message translates to:
  /// **'تفعيل فوري'**
  String get esimPerkInstant;

  /// eSIM banner: a short perk.
  ///
  /// In ar, this message translates to:
  /// **'بلا شريحة بلاستيكية'**
  String get esimPerkNoPlastic;

  /// eSIM banner: a short perk.
  ///
  /// In ar, this message translates to:
  /// **'شحن من التطبيق'**
  String get esimPerkTopUp;

  /// eSIM destination page: the heading over its plans.
  ///
  /// In ar, this message translates to:
  /// **'اختر باقتك'**
  String get esimPlansTitle;

  /// eSIM shelf: promotions and filters.
  ///
  /// In ar, this message translates to:
  /// **'خصم {percent}%'**
  String esimPromoOff(int percent);

  /// eSIM shelf: promotions and filters.
  ///
  /// In ar, this message translates to:
  /// **'عروض اليوم'**
  String get esimOffersTitle;

  /// eSIM shelf: promotions and filters.
  ///
  /// In ar, this message translates to:
  /// **'عروض'**
  String get esimFilterOffers;

  /// eSIM shelf: promotions and filters.
  ///
  /// In ar, this message translates to:
  /// **'مدة الرحلة'**
  String get esimFilterDays;

  /// eSIM shelf: promotions and filters.
  ///
  /// In ar, this message translates to:
  /// **'{days, plural, few{{days} أيام فأكثر} other{{days} يوماً فأكثر}}'**
  String esimFilterDaysOption(int days);

  /// eSIM shelf: promotions and filters.
  ///
  /// In ar, this message translates to:
  /// **'حجم البيانات'**
  String get esimFilterData;

  /// eSIM shelf: promotions and filters.
  ///
  /// In ar, this message translates to:
  /// **'الكل'**
  String get esimFilterAny;

  /// eSIM shelf: promotions and filters.
  ///
  /// In ar, this message translates to:
  /// **'الترتيب'**
  String get esimSortTitle;

  /// eSIM shelf: promotions and filters.
  ///
  /// In ar, this message translates to:
  /// **'أبجدياً'**
  String get esimSortName;

  /// eSIM shelf: promotions and filters.
  ///
  /// In ar, this message translates to:
  /// **'الأرخص أولاً'**
  String get esimSortCheapest;

  /// eSIM shelf: promotions and filters.
  ///
  /// In ar, this message translates to:
  /// **'مسح'**
  String get esimFilterClear;

  /// eSIM shelf: promotions and filters.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{وجهة واحدة} =2{وجهتان} few{{count} وجهات} other{{count} وجهة}}'**
  String esimResultsCount(int count);

  /// eSIM shelf: promotions and filters.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد وجهة بهذه المواصفات. جرّب مدة أقصر أو بيانات أقل.'**
  String get esimFilterNone;

  /// eSIM shelf: promotions and filters.
  ///
  /// In ar, this message translates to:
  /// **'مشاركة'**
  String get esimShareDestination;
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
      <String>['ar', 'en', 'fr'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsAr();
    case 'en':
      return AppLocalizationsEn();
    case 'fr':
      return AppLocalizationsFr();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
