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
  static const List<Locale> supportedLocales = <Locale>[Locale('ar')];

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

  /// Brand page: heading above the country chips.
  ///
  /// In ar, this message translates to:
  /// **'الدولة'**
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

  /// Hosted card page step title.
  ///
  /// In ar, this message translates to:
  /// **'أكمل الدفع في صفحة البطاقة'**
  String get hostedTitle;

  /// Hosted page explanation.
  ///
  /// In ar, this message translates to:
  /// **'فتحنا صفحة الدفع الآمنة. بعد إتمام الدفع ارجع هنا، وسيظهر كرتك تلقائياً.'**
  String get hostedBody;

  /// Reopen the hosted page.
  ///
  /// In ar, this message translates to:
  /// **'افتح صفحة الدفع'**
  String get openPaymentPage;

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
  /// **'تحديد كمستخدم'**
  String get markUsed;

  /// Unmark a used card.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء تحديد الاستخدام'**
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
