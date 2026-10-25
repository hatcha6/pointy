// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppLocalizationsAr extends AppLocalizations {
  AppLocalizationsAr([String locale = 'ar']) : super(locale);

  @override
  String get appTitle => 'دفتر كروت';

  @override
  String get tabHome => 'الرئيسية';

  @override
  String get tabMyCards => 'كروتي';

  @override
  String get tabAccount => 'حسابي';

  @override
  String get homeSearchHint => 'ابحث عن كرت: ليبيانا، ببجي، آيتونز…';

  @override
  String get homeTagline => 'كروت الاتصالات والإنترنت والألعاب، تصلك فوراً';

  @override
  String get myCardsEmptyTitle => 'لا كروت بعد';

  @override
  String get myCardsEmptyBody =>
      'الكروت التي تشتريها تُحفظ هنا، جاهزة متى احتجتها.';

  @override
  String get accountSignedOutTitle => 'سجّل الدخول برقم هاتفك';

  @override
  String get accountSignedOutBody =>
      'نرسل لك رمزاً في رسالة نصية، دون كلمة مرور.';

  @override
  String get signInAction => 'تسجيل الدخول';

  @override
  String get browseAction => 'تصفّح الكروت';

  @override
  String moneyAmount(String amount) {
    return '$amount د.ل';
  }

  @override
  String get errorNetwork => 'تعذّر الاتصال. تحقّق من الإنترنت وحاول مجدداً.';

  @override
  String get errorGeneric => 'حدث خطأ غير متوقع. حاول مجدداً.';

  @override
  String get retryAction => 'إعادة المحاولة';

  @override
  String get buyAgainTitle => 'اشترِ مجدداً';

  @override
  String get allCategories => 'الكل';

  @override
  String fromPrice(String price) {
    return 'من $price';
  }

  @override
  String get unavailableNow => 'غير متوفر الآن';

  @override
  String searchNoResultsTitle(String query) {
    return 'لا نتائج لـ «$query»';
  }

  @override
  String get searchNoResultsBody => 'جرّب اسماً آخر أو تصفّح الأقسام.';

  @override
  String get catalogEmptyTitle => 'لا كروت متاحة الآن';

  @override
  String get catalogEmptyBody => 'نعمل على توفير الكروت. عُد بعد قليل.';

  @override
  String get catalogLoadFailedTitle => 'تعذّر تحميل الكروت';

  @override
  String get savedShelfNote => 'تعرض آخر نسخة محفوظة';

  @override
  String creditChip(String amount) {
    return 'رصيدك $amount';
  }

  @override
  String get chooseValue => 'اختر الفئة';

  @override
  String get chooseCountry => 'الدولة';

  @override
  String get howToRedeem => 'طريقة الاستخدام';

  @override
  String get quantityLabel => 'الكمية';

  @override
  String buyFor(String amount) {
    return 'اشترِ بـ $amount';
  }

  @override
  String get increaseQuantity => 'زيادة الكمية';

  @override
  String get decreaseQuantity => 'إنقاص الكمية';

  @override
  String get signInTitle => 'تسجيل الدخول';

  @override
  String get signInSubtitle =>
      'أدخل رقم هاتفك لنرسل لك رمز الدخول. لا حاجة لكلمة مرور.';

  @override
  String get phoneLabel => 'رقم الهاتف';

  @override
  String get sendCode => 'أرسل الرمز';

  @override
  String get codeTitle => 'أدخل الرمز';

  @override
  String get codeSentTo => 'أرسلنا رمزاً من 6 أرقام إلى';

  @override
  String resendIn(int seconds) {
    return 'إعادة الإرسال بعد $seconds ث';
  }

  @override
  String get resendCode => 'أعد إرسال الرمز';

  @override
  String get changeNumber => 'تعديل الرقم';

  @override
  String get signInDone => 'أهلاً بك! تم تسجيل الدخول';

  @override
  String get errInvalidPhone => 'أدخل رقم هاتف ليبياً صحيحاً يبدأ بـ 09';

  @override
  String errWrongCode(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'الرمز غير صحيح. بقيت $count محاولة.',
      few: 'الرمز غير صحيح. بقيت $count محاولات.',
      two: 'الرمز غير صحيح. بقيت محاولتان.',
      one: 'الرمز غير صحيح. بقيت محاولة واحدة.',
      zero: 'الرمز غير صحيح.',
    );
    return '$_temp0';
  }

  @override
  String get errCodeExpired => 'انتهت صلاحية الرمز. اطلب رمزاً جديداً.';

  @override
  String get errTooManyAttempts => 'محاولات كثيرة. اطلب رمزاً جديداً.';

  @override
  String get errTooSoon => 'انتظر قليلاً قبل طلب رمز جديد.';

  @override
  String get errDailyLimit => 'وصلت إلى الحد اليومي للرموز. حاول غداً.';

  @override
  String get errSendFailed => 'تعذّر إرسال الرمز. حاول مجدداً.';

  @override
  String get errRateLimited => 'طلبات كثيرة. حاول بعد قليل.';

  @override
  String get errSignInRequired => 'سجّل الدخول للمتابعة.';

  @override
  String get checkoutTitle => 'إتمام الشراء';

  @override
  String get payWith => 'ادفع عبر';

  @override
  String get bankCards => 'البطاقات المصرفية';

  @override
  String useCredit(String amount) {
    return 'استخدم رصيدك ($amount)';
  }

  @override
  String get lineSubtotal => 'السعر';

  @override
  String get lineCredit => 'من رصيدك';

  @override
  String get lineFee => 'رسوم الدفع';

  @override
  String get lineTotal => 'المطلوب دفعه';

  @override
  String payAmount(String amount) {
    return 'ادفع $amount';
  }

  @override
  String get payFromCredit => 'ادفع من رصيدك';

  @override
  String get instantDelivery => 'يصلك الرقم السري فوراً بعد الدفع.';

  @override
  String payerTitle(String method) {
    return 'الدفع عبر $method';
  }

  @override
  String get payerPhone => 'رقم المحفظة';

  @override
  String get payerCard => 'رقم بطاقة المحفظة';

  @override
  String get payerBirthYear => 'سنة الميلاد';

  @override
  String get continueAction => 'متابعة';

  @override
  String get cancelAction => 'إلغاء';

  @override
  String walletCodeTitle(String method) {
    return 'رمز تأكيد $method';
  }

  @override
  String walletCodeBody(String method, String amount) {
    return 'أرسلت $method رمزاً إلى هاتفك لتأكيد دفع $amount. هذا ليس رمز الدخول.';
  }

  @override
  String get confirmPayment => 'تأكيد الدفع';

  @override
  String errOtpRejected(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'رمز الدفع غير صحيح. بقيت $count محاولة.',
      few: 'رمز الدفع غير صحيح. بقيت $count محاولات.',
      two: 'رمز الدفع غير صحيح. بقيت محاولتان.',
      one: 'رمز الدفع غير صحيح. بقيت محاولة واحدة.',
      zero: 'رمز الدفع غير صحيح.',
    );
    return '$_temp0';
  }

  @override
  String get errDeclined => 'رفض المصرف أو المحفظة الدفع. لم يُخصم شيء.';

  @override
  String errPriceChanged(String amount) {
    return 'تغيّر السعر إلى $amount. راجعه ثم أكمل.';
  }

  @override
  String get errItemUnavailable => 'هذا الكرت غير متوفر الآن.';

  @override
  String get errPaymentFailed =>
      'تعذّر بدء الدفع. حاول مجدداً أو اختر طريقة أخرى.';

  @override
  String get errPaymentsUnavailable => 'الدفع غير متاح الآن. حاول بعد قليل.';

  @override
  String get errInvalidPayer => 'تحقّق من بيانات الدفع.';

  @override
  String get hostedTitle => 'أكمل الدفع في صفحة البطاقة';

  @override
  String get hostedBody =>
      'فتحنا صفحة الدفع الآمنة. بعد إتمام الدفع ارجع هنا، وسيظهر كرتك تلقائياً.';

  @override
  String get openPaymentPage => 'افتح صفحة الدفع';

  @override
  String get cancelOrder => 'إلغاء الطلب';

  @override
  String get preparingTitle => 'نجهّز كرتك…';

  @override
  String get preparingBody =>
      'عادةً خلال ثوانٍ. يمكنك إغلاق التطبيق، وسيُحفظ الكرت في «كروتي».';

  @override
  String get refundedTitle => 'لم نتمكن من شراء الكرت';

  @override
  String refundedBody(String amount) {
    return 'أعدنا $amount إلى رصيدك، ويُستخدم في طلبك القادم.';
  }

  @override
  String get unpaidTitle => 'لم يكتمل الدفع';

  @override
  String get unpaidBody => 'لم يُخصم أي مبلغ. يمكنك المحاولة مجدداً.';

  @override
  String get tryAgain => 'حاول مجدداً';

  @override
  String get backToShop => 'العودة إلى الكروت';

  @override
  String get revealTitle => 'كرتك جاهز';

  @override
  String get secretCode => 'الرقم السري';

  @override
  String serialNumber(String serial) {
    return 'الرقم التسلسلي: $serial';
  }

  @override
  String get copyAction => 'نسخ';

  @override
  String get copiedNotice => 'تم نسخ الرقم السري';

  @override
  String get rechargeNow => 'اشحن الآن';

  @override
  String get showQr => 'رمز QR';

  @override
  String get sendAsGift => 'أرسلها هدية';

  @override
  String giftMessage(String name, String code) {
    return 'هدية لك من دفتر كروت\n$name\nالرقم السري: $code';
  }

  @override
  String get markUsed => 'تحديد كمستخدم';

  @override
  String get markUnused => 'إلغاء تحديد الاستخدام';

  @override
  String get usedBadge => 'مستخدم';

  @override
  String get doneAction => 'تم';

  @override
  String get codesLockedTitle => 'رموزك محمية';

  @override
  String get codesLockedBody => 'أكّد هويتك لعرض الأرقام السرية.';

  @override
  String get unlockAction => 'اعرض الرموز';

  @override
  String get unlockReason => 'تأكيد هويتك لعرض رموز كروتك';

  @override
  String get codesPendingTitle => 'نقرأ الرمز من المورّد…';

  @override
  String get codesPendingBody =>
      'الكرت مدفوع ومحفوظ. سيظهر رقمه السري هنا خلال لحظات.';

  @override
  String get filterUnused => 'غير مستخدم';

  @override
  String get filterUsed => 'مستخدم';

  @override
  String get statusPreparing => 'قيد التجهيز';

  @override
  String get statusAwaitingPayment => 'بانتظار الدفع';

  @override
  String get statusRefunded => 'أُعيد لرصيدك';

  @override
  String get statusUnpaid => 'لم يكتمل';

  @override
  String cardCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count كرتاً',
      few: '$count كروت',
      two: 'كرتان',
      one: 'كرت واحد',
    );
    return '$_temp0';
  }

  @override
  String get myCardsSignedOutBody => 'سجّل الدخول لترى كروتك على أي جهاز.';

  @override
  String get creditTitle => 'رصيدك';

  @override
  String get creditBody => 'يُستخدم في طلباتك القادمة.';

  @override
  String get creditOrder => 'دفع طلب';

  @override
  String get creditRefund => 'استرداد طلب';

  @override
  String get creditRelease => 'إعادة رصيد طلب لم يكتمل';

  @override
  String get creditLatePayment => 'دفعة وصلت بعد إغلاق الطلب';

  @override
  String get devicesTitle => 'الأجهزة المسجّلة';

  @override
  String get thisDevice => 'هذا الجهاز';

  @override
  String get signOutOthers => 'تسجيل الخروج من الأجهزة الأخرى';

  @override
  String get signOutOthersDone => 'تم تسجيل الخروج من الأجهزة الأخرى';

  @override
  String get signOut => 'تسجيل الخروج';

  @override
  String get deleteAccount => 'حذف الحساب';

  @override
  String get deleteAccountTitle => 'حذف حسابك؟';

  @override
  String get deleteAccountBody =>
      'سنحذف رقمك وكل جلساتك نهائياً. انسخ الأرقام السرية لكروتك قبل الحذف.';

  @override
  String get deleteAction => 'احذف';

  @override
  String get accountDeleted => 'تم حذف حسابك';

  @override
  String get deviceBrowser => 'متصفح';

  @override
  String get paymentReviewTitle => 'نراجع دفعتك';

  @override
  String get paymentReviewBody =>
      'وصلت دفعة بمبلغ يختلف عن الطلب، فأوقفناها للمراجعة. سنتواصل معك، ولن تخسر شيئاً.';

  @override
  String get statusReview => 'قيد المراجعة';

  @override
  String get homeTitle => 'اكتشف الكروت';

  @override
  String get seeAll => 'عرض الكل';

  @override
  String get featuredTitle => 'الأكثر طلباً';

  @override
  String get paymentMethodLabel => 'طريقة الدفع';

  @override
  String get changeAction => 'تغيير';

  @override
  String get choosePaymentMethod => 'اختر طريقة الدفع';

  @override
  String get securePaymentNote =>
      'يتم الدفع عبر بوابة «دفع» الآمنة، ولا نحتفظ ببيانات الدفع.';

  @override
  String get purchaseSuccess => 'تم الشراء بنجاح';

  @override
  String cardIndex(int index, int count) {
    return 'الكرت $index من $count';
  }

  @override
  String get closeAction => 'إغلاق';

  @override
  String get perCard => 'للكرت الواحد';

  @override
  String get creditHistory => 'سجل الرصيد';

  @override
  String get accountSection => 'الحساب';

  @override
  String get inProgressSection => 'قيد التجهيز';

  @override
  String get myCardsSection => 'كروتك';

  @override
  String get searchResults => 'نتائج البحث';

  @override
  String get startingFrom => 'تبدأ من';

  @override
  String get buyNow => 'اشترِ';

  @override
  String get splashDaftar => 'دفتر';

  @override
  String get splashCards => 'كروت';

  @override
  String get refundedToCredit => 'أُضيف إلى رصيدك';

  @override
  String get settingsSection => 'الإعدادات';

  @override
  String get codeLockTitle => 'حماية الرموز';

  @override
  String get codeLockBody => 'اطلب Face ID أو البصمة قبل عرض الأرقام السرية';

  @override
  String get codeLockOffReason => 'تأكيد هويتك لإيقاف حماية الرموز';

  @override
  String get themeTitle => 'المظهر';

  @override
  String get themeSystem => 'تلقائي';

  @override
  String get themeLight => 'فاتح';

  @override
  String get themeDark => 'داكن';

  @override
  String get languageTitle => 'اللغة';

  @override
  String get aboutSection => 'حول التطبيق';

  @override
  String get aboutTitle => 'حول دفتر كروت';

  @override
  String get aboutTagline => 'كروت الشحن والإنترنت، تصلك فوراً.';

  @override
  String get aboutBody =>
      '«دفتر كروت» تطبيق من «دفتر»، نظام المبيعات الذي تعمل به المتاجر في ليبيا. اختر الكرت وادفع بمحفظتك أو بطاقتك، فيصلك رقمه السري خلال ثوانٍ، ويبقى محفوظاً في «كروتي» متى احتجت إليه.';

  @override
  String aboutVersion(String version) {
    return 'الإصدار $version';
  }

  @override
  String get aboutCopyright => '© 2026 دفتر';

  @override
  String get contactWhatsApp => 'تواصل معنا عبر واتساب';

  @override
  String get websiteTitle => 'الموقع الإلكتروني';

  @override
  String get privacyPolicy => 'سياسة الخصوصية';

  @override
  String get termsOfUse => 'شروط الاستخدام';

  @override
  String get openSourceLicenses => 'تراخيص البرامج مفتوحة المصدر';

  @override
  String signInConsent(String terms, String privacy) {
    return 'بالمتابعة، أنت توافق على $terms و$privacy.';
  }

  @override
  String get cardPayTitle => 'الدفع بالبطاقة المصرفية';

  @override
  String get cardThroughMoamalat => 'عبر بوابة معاملات';

  @override
  String get cardNumberLabel => 'رقم البطاقة';

  @override
  String get cardExpiryLabel => 'تاريخ الانتهاء';

  @override
  String get cardNumberInvalid => 'رقم البطاقة غير صحيح.';

  @override
  String get cardExpiryInvalid =>
      'أدخل تاريخ الانتهاء كما على البطاقة: شهر/سنة.';

  @override
  String get cardSecureNote =>
      'تذهب بيانات بطاقتك من هاتفك إلى بوابة معاملات مباشرة، فلا تمرّ بخوادمنا ولا نحتفظ بها.';

  @override
  String get cardOpening => 'نجهّز الدفع الآمن…';

  @override
  String get cardCharging => 'نتواصل مع بنكك…';

  @override
  String get cardConfirming => 'تم الدفع، نؤكّد طلبك…';

  @override
  String get cardVerifyTitle => 'تأكيد من بنكك';

  @override
  String get cardVerifyBody =>
      'أرسل بنكك رمزاً إلى هاتفك. أدخله في صفحة البنك أدناه لإتمام الدفع.';

  @override
  String get cardVerifyCancel => 'إلغاء';

  @override
  String get cardErrDeclined =>
      'رفض البنك العملية. تأكّد من بيانات البطاقة ورصيدها، أو جرّب بطاقة أخرى.';

  @override
  String get cardErrExpiry => 'تاريخ انتهاء البطاقة غير صحيح.';

  @override
  String get cardErrNetwork =>
      'تعذّر الوصول إلى بوابة الدفع. تحقّق من الإنترنت وحاول مجدداً.';

  @override
  String get cardErrVerification =>
      'لم يكتمل التأكيد من بنكك، ولم يُخصم شيء. حاول مجدداً.';

  @override
  String get cardErrExpired => 'انتهت مهلة الدفع. حاول مجدداً.';

  @override
  String get cardUsePaymentPage => 'الدفع من صفحة البوابة بدلاً من ذلك';

  @override
  String get cardNameLabel => 'اسم حامل البطاقة';

  @override
  String get cardNameInvalid => 'أدخل الاسم كما هو مكتوب على البطاقة.';

  @override
  String get savedCardsTitle => 'بطاقاتك المحفوظة';

  @override
  String get useAnotherCard => 'استخدم بطاقة أخرى';

  @override
  String get saveCardTitle => 'احفظ البطاقة على هذا الهاتف';

  @override
  String get saveCardBody =>
      'لتدفع بها أسرع في المرة القادمة. تبقى مشفّرة على هاتفك وحده، وتُفتح ببصمة الوجه أو رمز الهاتف، ولا تصلنا أبداً.';

  @override
  String get savedCardUnlockReason => 'تأكيد هويتك للدفع بالبطاقة المحفوظة';

  @override
  String savedCardExpires(String expiry) {
    return 'تنتهي $expiry';
  }

  @override
  String get savedCardsSettings => 'البطاقات المحفوظة';

  @override
  String get savedCardsEmpty =>
      'لا توجد بطاقات محفوظة على هذا الهاتف. يمكنك حفظ بطاقة عند الدفع بها.';

  @override
  String get savedCardsNote =>
      'تُحفظ البطاقات على هذا الهاتف وحده، مشفّرة وخلف بصمة الوجه أو رمز الهاتف، ولا تصل إلى خوادمنا. تُحذف عند تسجيل الخروج.';

  @override
  String get removeCard => 'إزالة';

  @override
  String get removeCardTitle => 'إزالة البطاقة؟';

  @override
  String get removeCardBody =>
      'ستُحذف من هذا الهاتف. يمكنك حفظها مجدداً عند الدفع بها.';

  @override
  String get savedCardLocked =>
      'لم يتم التحقق من هويتك، فلم نستخدم البطاقة المحفوظة.';
}
