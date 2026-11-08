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
  String get chooseCountry => 'الدولة أو المنطقة';

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
  String get errAccountBlocked => 'هذا الحساب موقوف. تواصل معنا لإعادة تفعيله.';

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
  String get hostedTitle => 'نتحقق من الدفع';

  @override
  String get hostedBody =>
      'تم الدفع في صفحة البطاقة، ونتأكد الآن من وصوله. سيظهر كرتك هنا خلال لحظات.';

  @override
  String get cancelOrder => 'إلغاء الطلب';

  @override
  String get preparingTitle => 'نجهّز كرتك…';

  @override
  String get preparingBody =>
      'عادةً خلال ثوانٍ. يمكنك إغلاق التطبيق، وسيُحفظ الكرت في «كروتي».';

  @override
  String get preparingSlowTitle => 'يتأخر المورّد هذه المرة';

  @override
  String get preparingSlowNotify =>
      'لا داعي للانتظار هنا: حين يجهز طلبك نرسل لك إشعاراً يفتحه مباشرةً في «كروتي».';

  @override
  String get preparingSlowAsk =>
      'فعّل الإشعارات ونخبرك حين يجهز طلبك، أو عُد إليه لاحقاً في «كروتي».';

  @override
  String get preparingSlowLater =>
      'لا داعي للانتظار هنا: تجد طلبك في «كروتي» حين يجهز.';

  @override
  String get goToMyCards => 'اذهب إلى «كروتي»';

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
  String get shareAction => 'مشاركة';

  @override
  String get linkCopiedNotice => 'تم نسخ الرابط';

  @override
  String get redeemAction => 'استرداد';

  @override
  String get dialCopiedNotice =>
      'تم نسخ كود الشحن. الصقه في تطبيق الهاتف ثم اضغط اتصال.';

  @override
  String get redeemCopiedNotice =>
      'تم نسخ الرقم السري. إن لم يظهر في الصفحة فالصقه هناك.';

  @override
  String get rechargeNow => 'اشحن الآن';

  @override
  String get showQr => 'رمز QR';

  @override
  String get qrRevealHint => 'المس الكرت لإظهار رمز QR';

  @override
  String get qrScanHint => 'امسحه بالكاميرا لقراءة الرقم السري';

  @override
  String get sendAsGift => 'أرسلها هدية';

  @override
  String giftMessage(String name, String code) {
    return 'هدية لك من دفتر كروت\n$name\nالرقم السري: $code';
  }

  @override
  String get markUsed => 'استخدمته';

  @override
  String get markUnused => 'لم أستخدمه';

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
  String get shareUsageTitle => 'مشاركة بيانات الاستخدام';

  @override
  String get notificationOpenAction => 'عرض';

  @override
  String get notificationsTitle => 'الإشعارات';

  @override
  String get notificationsBlockedNotice => 'الإشعارات متوقفة في إعدادات الهاتف';

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

  @override
  String get payNotFinishedTitle => 'لم يكتمل الدفع';

  @override
  String get payNotFinishedBody =>
      'لم يُخصم شيء بعد. أكمل الدفع بالبطاقة، أو ألغِ الطلب.';

  @override
  String get finishPaying => 'أكمل الدفع';

  @override
  String get orderCancelled => 'تم إلغاء الطلب.';

  @override
  String get onboardingSkip => 'تخطَّ';

  @override
  String get onboardingNext => 'التالي';

  @override
  String get onboardingStart => 'ابدأ الآن';

  @override
  String onboardingStep(int current, int total) {
    return 'الخطوة $current من $total';
  }

  @override
  String get onboardingShelfTitle => 'كل كروتك في مكان واحد';

  @override
  String get onboardingShelfBody =>
      'رصيد ليبيانا والمدار وباقات الإنترنت وغيرها، تختارها في ثوانٍ وبأسعار واضحة.';

  @override
  String get onboardingInstantTitle => 'ادفع، ويصلك الرقم فوراً';

  @override
  String get onboardingInstantBody =>
      'ادفع بمحفظتك أو ببطاقتك المصرفية، فيظهر الرقم السري لكرتك خلال ثوانٍ.';

  @override
  String get onboardingVaultTitle => 'كروتك محفوظة بأمان';

  @override
  String get onboardingVaultBody =>
      'كل كرت تشتريه يبقى في «كروتي» محمياً بقفل هاتفك، جاهزاً متى احتجته.';

  @override
  String get onboardingNotifyTitle => 'العروض تصلك أولاً';

  @override
  String get onboardingNotifyBody =>
      'فعّل الإشعارات لنخبرك بالعروض والكروت الجديدة لحظة وصولها.';

  @override
  String get onboardingNotifyAllow => 'تفعيل الإشعارات';

  @override
  String get onboardingNotifyLater => 'ليس الآن';

  @override
  String get onboardingNotifyOnBody =>
      'الإشعارات مفعّلة: نخبرك بالعروض والكروت الجديدة لحظة وصولها.';

  @override
  String get onboardingReplay => 'جولة في التطبيق';

  @override
  String get getAppBody => 'أسرع على هاتفك، وكروتك معك دائماً';

  @override
  String get getAppAction => 'تحميل';

  @override
  String get licensesIntro =>
      'يقوم «دفتر كروت» على برامج مفتوحة المصدر، والشكر لأصحابها. هذه تراخيصها كما نُشرت، بلغتها الأصلية.';

  @override
  String get searchTitle => 'البحث';

  @override
  String get searchBrowseCategories => 'تصفّح الأقسام';

  @override
  String get filterIncomplete => 'لم تكتمل';

  @override
  String get myCardsNoneUnusedTitle => 'استخدمت كل كروتك';

  @override
  String get myCardsNoneUnusedBody =>
      'الكروت التي لم تستخدم رمزها بعد تظهر هنا.';

  @override
  String get myCardsNoneUsedTitle => 'لا كروت مستخدمة بعد';

  @override
  String get myCardsNoneUsedBody =>
      'بعد أن تشحن كرتاً، اضغط «استخدمته» في صفحته لينتقل إلى هنا.';

  @override
  String get myCardsNoneIncompleteTitle => 'كل طلباتك اكتملت';

  @override
  String get myCardsNoneIncompleteBody =>
      'إن تعذّر طلب يوماً يظهر هنا، ويعود ثمنه إلى رصيدك.';

  @override
  String get webOnlyBadge => 'على الموقع';

  @override
  String get webOnlyTitle => 'متوفرة على الموقع';

  @override
  String get webOnlyBody =>
      'هذه البطاقة لا تُشترى من هذا التطبيق. تجدها على موقعنا cards.dftr.ly';

  @override
  String get steamBadge => 'ستيم';

  @override
  String get xboxBadge => 'إكس بوكس';

  @override
  String get eaBadge => 'EA';

  @override
  String get rockstarBadge => 'روكستار';

  @override
  String get heardFromTitle => 'من أين سمعت عن دفتر كروت؟';

  @override
  String get heardFromBody =>
      'اختر جواباً واحداً، يساعدنا على الوصول لمن يحتاج التطبيق.';

  @override
  String get heardFromFacebook => 'فيسبوك';

  @override
  String get heardFromInstagram => 'إنستغرام';

  @override
  String get heardFromTiktok => 'تيك توك';

  @override
  String get heardFromWhatsapp => 'واتساب';

  @override
  String get heardFromFriend => 'صديق أو قريب';

  @override
  String get heardFromShop => 'محل';

  @override
  String get heardFromBillboard => 'لوحة إعلانية';

  @override
  String get heardFromStoreSearch => 'البحث في المتجر';

  @override
  String get heardFromOther => 'غير ذلك';

  @override
  String get campaignCodeLabel => 'عندك رمز من إعلان أو صديق؟';

  @override
  String get campaignCodeHint => 'مثل UNI1';

  @override
  String get campaignCodeCheck => 'تحقّق';

  @override
  String get campaignCodeUnknown => 'هذا الرمز غير معروف أو انتهى.';

  @override
  String get campaignCodeValid => 'رمز صحيح، شكراً لك.';

  @override
  String campaignCodeRewardLater(String amount) {
    return 'رمز صحيح: يُضاف $amount إلى رصيدك حين تسجّل الدخول.';
  }

  @override
  String campaignCodeRewardNow(String amount) {
    return 'رمز صحيح: يُضاف $amount إلى رصيدك.';
  }

  @override
  String campaignLinkReward(String code, String amount) {
    return 'وصلت برمز $code: يُضاف $amount إلى رصيدك حين تسجّل الدخول.';
  }

  @override
  String rewardTitle(String amount) {
    return 'أُضيف $amount إلى رصيدك';
  }

  @override
  String rewardBecauseCode(String code) {
    return 'لأنك استخدمت الرمز $code.';
  }

  @override
  String rewardBecauseCreator(String name) {
    return 'لأنك جئت عن طريق $name.';
  }

  @override
  String get rewardBecauseCreatorUnnamed =>
      'لأنك جئت عن طريق صانع محتوى نتعاون معه.';

  @override
  String rewardBecauseFlyer(String name) {
    return 'لأنك مسحت رمز $name.';
  }

  @override
  String get rewardBecauseFlyerUnnamed => 'لأنك مسحت رمز الملصق.';

  @override
  String get rewardBecauseBillboardUnnamed => 'لأنك مسحت رمز اللوحة الإعلانية.';

  @override
  String rewardBecauseInvite(String name) {
    return 'لأنك جئت بدعوة من $name.';
  }

  @override
  String get rewardBecauseInviteUnnamed => 'لأنك جئت بدعوة صديق.';

  @override
  String get rewardBecauseAd => 'لأنك جئت من إعلاننا.';

  @override
  String get rewardBody => 'يُخصم تلقائياً من سعر كرتك القادم، دون أي رسوم.';

  @override
  String get rewardAction => 'تسوّق الآن';

  @override
  String topUpPill(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'هدية على حسابك',
      'other': 'شحن مباشر',
    });
    return '$_temp0';
  }

  @override
  String topUpAccountTitle(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'telegram': 'حساب تيليجرام',
      'steam': 'حساب ستيم',
      'invite': 'حساب ستيم',
      'other': 'حساب اللاعب',
    });
    return '$_temp0';
  }

  @override
  String topUpAccountBody(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'telegram': 'تصل مباشرة إلى الحساب، دون رمز تُدخله.',
      'steam': 'يُضاف الرصيد مباشرة إلى محفظتك في ستيم.',
      'invite': 'تصلك اللعبة هدية على حسابك في ستيم، دون رمز تُدخله.',
      'other': 'يصل الشحن مباشرة إلى حسابك في اللعبة، دون رمز تُدخله.',
    });
    return '$_temp0';
  }

  @override
  String topUpHintTitle(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'telegram': 'أين أجد اسم المستخدم؟',
      'steam': 'ما اسم الدخول؟',
      'invite': 'كيف أحصل على الرابط؟',
      'other': 'أين أجد المعرّف؟',
    });
    return '$_temp0';
  }

  @override
  String get chooseAmount => 'اختر الكمية';

  @override
  String get savedAccounts => 'حساباتك';

  @override
  String get otherAccount => 'حساب آخر';

  @override
  String forgetAccount(String account) {
    return 'انسَ $account';
  }

  @override
  String get pasteAction => 'لصق';

  @override
  String get chooseOption => 'اختر';

  @override
  String accountRequired(String field) {
    return 'أدخل $field';
  }

  @override
  String accountChoose(String field) {
    return 'اختر $field';
  }

  @override
  String get accountTooLong => 'أطول مما يجب.';

  @override
  String get accountNotTelegram =>
      'اسم المستخدم من 5 إلى 32 حرفاً إنجليزياً أو رقماً أو _، ويبدأ بحرف.';

  @override
  String get accountNotSteamLogin =>
      'اسم الدخول حروف إنجليزية وأرقام و _ فقط، دون مسافات.';

  @override
  String get accountNotInvite =>
      'هذا ليس رابط دعوة من ستيم. انسخ «رابط الدعوة السريعة» من ستيم كما هو والصقه هنا.';

  @override
  String get accountChecking => 'نتحقق من الحساب…';

  @override
  String accountPlayer(String name) {
    return 'اللاعب: $name';
  }

  @override
  String accountFound(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'steam': 'يمكن شحن هذا الحساب',
      'other': 'وجدنا الحساب',
    });
    return '$_temp0';
  }

  @override
  String accountNotFound(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'steam': 'لا يمكن شحن حساب ستيم هذا. تأكد من اسم الدخول.',
      'other': 'لا يوجد حساب بهذا المعرّف. تأكد منه في ملفك داخل اللعبة.',
    });
    return '$_temp0';
  }

  @override
  String get accountUnconfirmed =>
      'تعذّر التأكد من الحساب الآن. راجعه جيداً قبل الدفع.';

  @override
  String accountUnchecked(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'تأكد من الرابط: تُرسل الهدية إلى صاحبه.',
      'telegram': 'تأكد من اسم المستخدم: تُرسل إليه مباشرة ولا تُسترجع.',
      'other': 'تأكد من المعرّف: يصل الشحن إليه مباشرة ولا يُسترجع.',
    });
    return '$_temp0';
  }

  @override
  String topUpAction(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'اشترِ',
      'telegram': 'اشترِ',
      'other': 'اشحن',
    });
    return '$_temp0';
  }

  @override
  String buyBarTo(String account) {
    return 'إلى $account';
  }

  @override
  String buyBarNeedsAccount(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'telegram': 'أدخل اسم المستخدم',
      'steam': 'أدخل اسم الدخول',
      'invite': 'الصق رابط الدعوة',
      'other': 'أدخل المعرّف',
    });
    return '$_temp0';
  }

  @override
  String get sendToLabel => 'إلى';

  @override
  String get editAction => 'تعديل';

  @override
  String topUpPreparingTitle(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'نرسل لك الهدية…',
      'telegram': 'نشحن حساب تيليجرام…',
      'steam': 'نضيف الرصيد إلى محفظة ستيم…',
      'other': 'نشحن حساب اللاعب…',
    });
    return '$_temp0';
  }

  @override
  String topUpPreparingBody(String kind, String item, String account) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'يصلك من ستيم طلب صداقة ثم الهدية: اقبلهما حين يصلان.',
      'other': 'نرسل $item إلى $account. يصل عادةً خلال دقيقة أو دقيقتين.',
    });
    return '$_temp0';
  }

  @override
  String topUpSlowTitle(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'تتأخر الهدية هذه المرة',
      'steam': 'تتأخر إضافة الرصيد هذه المرة',
      'other': 'يتأخر الشحن هذه المرة',
    });
    return '$_temp0';
  }

  @override
  String topUpRefundedTitle(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'لم تُرسل الهدية',
      'steam': 'لم يُضف الرصيد',
      'other': 'لم يكتمل الشحن',
    });
    return '$_temp0';
  }

  @override
  String topUpRefundedBody(String kind, String amount) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite':
          'لم تُرسل الهدية، فأعدنا $amount إلى رصيدك. تأكد من رابط الدعوة ثم حاول مجدداً.',
      'telegram':
          'لم يصل الشحن إلى حساب تيليجرام، فأعدنا $amount إلى رصيدك. تأكد من اسم المستخدم ثم حاول مجدداً.',
      'steam':
          'لم يُضف الرصيد إلى محفظة ستيم، فأعدنا $amount إلى رصيدك. تأكد من اسم الدخول ثم حاول مجدداً.',
      'other':
          'لم يصل الشحن إلى حساب اللاعب، فأعدنا $amount إلى رصيدك. تأكد من المعرّف ثم حاول مجدداً.',
    });
    return '$_temp0';
  }

  @override
  String toppedUpTitle(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'أُرسلت الهدية',
      'other': 'تمّ الشحن',
    });
    return '$_temp0';
  }

  @override
  String get receiptTo => 'إلى';

  @override
  String get receiptPlayer => 'اللاعب';

  @override
  String get receiptPaid => 'المبلغ';

  @override
  String get receiptWhen => 'الوقت';

  @override
  String get receiptOrder => 'رقم الطلب';

  @override
  String get whatNextTitle => 'ماذا بعد؟';

  @override
  String topUpNext(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'telegram': 'افتح تيليجرام: تجدها في حسابك خلال دقائق.',
      'steam': 'افتح ستيم: يظهر الرصيد في محفظتك خلال دقائق.',
      'invite': 'من ستيم: اقبل طلب الصداقة الذي يصلك، ثم الهدية من الإشعارات. تصل الهدية بعد قبول الصداقة بدقائق.',
      'other': 'افتح اللعبة: يظهر الرصيد في حسابك خلال دقائق. إن لم يظهر، أغلق اللعبة وافتحها من جديد.',
    });
    return '$_temp0';
  }

  @override
  String topUpAgain(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'اشترِ هدية أخرى',
      'other': 'اشحن مجدداً',
    });
    return '$_temp0';
  }

  @override
  String get topUpHelp => 'لم يصلك؟ راسلنا على واتساب';

  @override
  String topUpHelpMessage(String kind, String order) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'مرحباً، الطلب رقم $order: لم تصلني الهدية.',
      'telegram': 'مرحباً، الطلب رقم $order لم يصل إلى حساب تيليجرام.',
      'steam': 'مرحباً، الطلب رقم $order لم يُضف إلى محفظة ستيم.',
      'other': 'مرحباً، الطلب رقم $order لم يصل إلى حساب اللاعب.',
    });
    return '$_temp0';
  }

  @override
  String get orderIdCopied => 'نُسخ رقم الطلب';

  @override
  String statusToppedUp(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'أُرسلت الهدية',
      'other': 'تمّ الشحن',
    });
    return '$_temp0';
  }

  @override
  String get statusToppingUp => 'قيد الشحن';

  @override
  String orderTo(String account) {
    return 'إلى $account';
  }

  @override
  String get removeAccount => 'إزالة';

  @override
  String accountRemoved(String account) {
    return 'أُزيل $account من هذا الهاتف';
  }

  @override
  String get undoAction => 'تراجع';

  @override
  String get chooseEdition => 'اختر الإصدار';

  @override
  String get esimStoreTitle => 'إلى أين تسافر؟';

  @override
  String get esimEntryTitle => 'سافر متصلاً من أول لحظة';

  @override
  String get esimEntryBody => 'إنترنت لأكثر من 200 وجهة، تثبّته بلمسة واحدة.';

  @override
  String get esimEntryAction => 'اختر وجهتك';

  @override
  String get esimMineTitle => 'شرائحي';

  @override
  String get esimSearchHint => 'ابحث عن دولة أو منطقة';

  @override
  String get esimSearchClear => 'مسح البحث';

  @override
  String get esimKindLocal => 'دول';

  @override
  String get esimKindRegional => 'مناطق';

  @override
  String get esimKindGlobal => 'عالمية';

  @override
  String get esimPopular => 'الأكثر طلباً';

  @override
  String get esimAllCountries => 'كل الدول';

  @override
  String get esimNoMatch => 'لا توجد وجهة بهذا الاسم.';

  @override
  String get esimFrom => 'تبدأ من';

  @override
  String get esimClosedTitle => 'الشرائح غير متاحة الآن';

  @override
  String get esimClosedBody =>
      'عُد بعد قليل، أو تواصل معنا إذا كنت تحتاجها الآن.';

  @override
  String get esimLoadFailed => 'تعذّر التحميل';

  @override
  String get esimTryAgain => 'أعد المحاولة';

  @override
  String get esimPhoneSupported => 'هاتفك يدعم الشرائح الإلكترونية';

  @override
  String get esimPhoneNotSupported =>
      'يبدو أن هاتفك لا يدعم الشرائح الإلكترونية';

  @override
  String get esimPhoneNotSupportedBody =>
      'ما زال بإمكانك شراء شريحة لشخص تعرفه وإرسالها إليه. وإن كنت متأكداً أن هاتفك يدعمها، فتحقق من إعدادات الهاتف أولاً.';

  @override
  String get esimUnlimited => 'غير محدودة';

  @override
  String get esimNetworks => 'الشبكات';

  @override
  String get esimFactData => 'البيانات';

  @override
  String get esimFactValidity => 'الصلاحية';

  @override
  String get esimFactNetwork => 'الشبكة';

  @override
  String get esimFactTopUp => 'الشحن';

  @override
  String get esimTopUpYes => 'يمكن شحنها';

  @override
  String get esimTopUpNo => 'لا يمكن شحنها';

  @override
  String get esimStartsOnFirstUse =>
      'تبدأ الصلاحية عند أول اتصال بالشبكة في وجهتك، لا عند الشراء ولا عند التثبيت.';

  @override
  String get esimUnlockedNote =>
      'يجب أن يكون هاتفك غير مقفل على شركة اتصالات. الهواتف المقفلة قد لا تقبل الشريحة.';

  @override
  String get esimDataOnlyNote =>
      'بيانات فقط: لا تتضمن رقم هاتف ولا مكالمات عادية.';

  @override
  String get esimWhoFor => 'لمن هذه الشريحة؟';

  @override
  String get esimForMe => 'لهاتفي';

  @override
  String get esimForSomeoneElse => 'لشخص آخر';

  @override
  String get esimRecipientName => 'اسمه (اختياري)';

  @override
  String get esimForSomeoneElseNote =>
      'بعد الدفع نعطيك رابطاً ترسله إليه، ويثبّتها من هاتفه بلمسة. الشريحة تعمل على هاتف واحد فقط.';

  @override
  String get esimForMeUnsupportedNote =>
      'قد لا تعمل الشريحة على هذا الهاتف، ولا يمكن استرداد شريحة بعد تثبيتها. تأكد أولاً من الإعدادات.';

  @override
  String get esimStatusNotActive => 'لم تُفعَّل بعد';

  @override
  String get esimStatusActive => 'فعّالة';

  @override
  String get esimStatusFinished => 'نفدت';

  @override
  String get esimStatusExpired => 'انتهت';

  @override
  String get esimStatusUnknown => 'قيد التحقق';

  @override
  String get esimLeftOf => 'متبقية من';

  @override
  String get esimEndsToday => 'تنتهي اليوم';

  @override
  String get esimRunningOutTopUp => 'قاربت على الانتهاء: اشحنها لتبقى متصلاً.';

  @override
  String get esimRunningOutNew =>
      'قاربت على الانتهاء: اشترِ شريحة جديدة لتبقى متصلاً.';

  @override
  String get esimReadyTitle => 'شريحتك جاهزة';

  @override
  String get esimReadyBody =>
      'بقيت خطوة واحدة: ثبّتها الآن أثناء اتصالك بالإنترنت، وستبدأ العمل عند وصولك.';

  @override
  String get esimReadyBodyGift =>
      'أرسلها الآن، وسيثبّتها صاحبها من هاتفه بلمسة.';

  @override
  String get esimInstallNow => 'ثبّت الشريحة الآن';

  @override
  String get esimInstallHere => 'ثبّتها على هذا الهاتف';

  @override
  String get esimInstallHint =>
      'سيفتح هاتفك شاشة إضافة الشريحة، ولا تحتاج إلى مسح أي رمز.';

  @override
  String get esimInstallFailedNote =>
      'لم يفتح هاتفك شاشة التثبيت. استخدم الرمز أو أدخل البيانات يدوياً.';

  @override
  String get esimSendTo => 'أرسلها إلى شخص آخر';

  @override
  String get esimOtherWays => 'طرق أخرى للتثبيت';

  @override
  String get esimAlreadyInstalled => 'ثبّتها بالفعل';

  @override
  String get esimShowInstallAgain => 'عرض طرق التثبيت مجدداً';

  @override
  String get esimNeedsInternetNote =>
      'تحتاج إلى اتصال بالإنترنت أثناء التثبيت.';

  @override
  String get esimOneDeviceNote =>
      'تعمل الشريحة على هاتف واحد ولا تُنقل إلى غيره. لا تحذفها بعد تثبيتها.';

  @override
  String get esimInstallAskTitle => 'هل أُضيفت الشريحة؟';

  @override
  String get esimInstallAskBody =>
      'إذا ظهرت في إعدادات الهاتف ضمن شرائح الجوال، فقد تم التثبيت.';

  @override
  String get esimInstallAskYes => 'نعم، أُضيفت';

  @override
  String get esimInstallAskNo => 'لم تُضَف';

  @override
  String get esimInstallUnreadable => 'تعذّر تحميل بيانات التثبيت.';

  @override
  String get esimQrTitle => 'امسح الرمز من هاتف آخر';

  @override
  String get esimQrStepsIos =>
      'افتح هذا الرمز على شاشة أخرى، ثم في الهاتف: الإعدادات ← شبكة الجوال ← إضافة شريحة eSIM ← استخدام رمز QR.';

  @override
  String get esimQrStepsAndroid =>
      'افتح هذا الرمز على شاشة أخرى، ثم في الهاتف: الإعدادات ← الشبكة والإنترنت ← شرائح SIM ← إضافة شريحة eSIM.';

  @override
  String get esimQrStepsOther =>
      'في الهاتف الذي ستعمل عليه الشريحة، افتح إعدادات شبكة الجوال، واختر إضافة شريحة eSIM، ثم امسح هذا الرمز.';

  @override
  String get esimManualTitle => 'أو أدخل البيانات يدوياً';

  @override
  String get esimSmdp => 'عنوان SM-DP+';

  @override
  String get esimActivationCode => 'رمز التفعيل';

  @override
  String get esimConfirmationCode => 'رمز التأكيد';

  @override
  String get esimCopy => 'نسخ';

  @override
  String get esimCopied => 'تم النسخ';

  @override
  String get esimNextStepsTitle => 'لتعمل الشريحة';

  @override
  String get esimStepDataLine =>
      'في إعدادات شبكة الجوال، اختر هذه الشريحة لبيانات الجوال.';

  @override
  String get esimStepRoaming => 'شغّل «تجوال البيانات» لهذه الشريحة.';

  @override
  String get esimStepApn =>
      'أدخل نقطة الوصول (APN) التالية في إعدادات الشريحة:';

  @override
  String get esimStepArrive =>
      'عند وصولك إلى وجهتك، ستتصل الشريحة بالشبكة تلقائياً.';

  @override
  String get esimApn => 'نقطة الوصول (APN)';

  @override
  String get esimEndedNote => 'انتهت هذه الشريحة ولا يمكن استخدامها مجدداً.';

  @override
  String get esimBuyAnother => 'اشترِ شريحة جديدة';

  @override
  String get esimTopUpTitle => 'اشحن هذه الشريحة';

  @override
  String get esimNoTopUps => 'لا تتوفر باقات شحن لهذه الشريحة الآن.';

  @override
  String get esimTopUpDone => 'أُضيفت الباقة إلى شريحتك.';

  @override
  String get esimRenameTitle => 'تسمية الشريحة';

  @override
  String get esimCancel => 'إلغاء';

  @override
  String get esimSave => 'حفظ';

  @override
  String get esimNumber => 'رقم الشريحة (ICCID)';

  @override
  String get esimHelp => 'تحتاج إلى مساعدة؟';

  @override
  String esimCountriesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count دولة',
      few: '$count دول',
      two: 'دولتان',
      one: 'دولة واحدة',
    );
    return '$_temp0';
  }

  @override
  String esimValidDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days يوماً',
      few: '$days أيام',
      two: 'ليومين',
      one: 'ليوم واحد',
    );
    return 'صالحة $_temp0';
  }

  @override
  String esimVoiceAndText(int voice, int text) {
    return '$voice دقيقة · $text رسالة';
  }

  @override
  String esimInstallWithin(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days يوماً',
      few: '$days أيام',
      two: 'يومين',
      one: 'يوم واحد',
    );
    return 'ثبّتها خلال $_temp0 من الشراء، وإلا فلن تعود صالحة.';
  }

  @override
  String esimBuyFor(String price) {
    return 'متابعة · $price';
  }

  @override
  String esimForName(String name) {
    return 'لـ $name';
  }

  @override
  String esimEndsInDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days يوماً',
      few: '$days أيام',
      two: 'يومين',
      one: 'يوم واحد',
    );
    return 'تنتهي بعد $_temp0';
  }

  @override
  String esimShareText(
    String destination,
    String plan,
    String link,
    String code,
  ) {
    return 'شريحة إنترنت (eSIM) لـ $destination: $plan\nافتح هذا الرابط من الهاتف الذي ستعمل عليه:\n$link\nرمز الدخول: $code';
  }

  @override
  String esimPlanDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days يوماً',
      few: '$days أيام',
      two: 'يومان',
      one: 'يوم واحد',
    );
    return '$_temp0';
  }

  @override
  String get esimPreparingTitle => 'نجهّز شريحتك…';

  @override
  String get esimPreparingBody =>
      'عادةً خلال ثوانٍ. يمكنك إغلاق التطبيق، وستجدها في «كروتي» وسنخبرك حين تصبح جاهزة.';

  @override
  String get esimRefundedTitle => 'لم نتمكن من إصدار الشريحة';

  @override
  String get esimEntryKicker => 'شرائح eSIM';

  @override
  String esimEntryFrom(String price) {
    return 'من $price';
  }

  @override
  String get esimStoreSubtitle => 'إنترنت فور وصولك، بلا شريحة بلاستيكية.';

  @override
  String get esimHowTitle => 'كيف تعمل؟';

  @override
  String get esimHow1Title => 'اختر وجهتك';

  @override
  String get esimHow1Body => 'دولة، أو منطقة، أو باقة عالمية تناسب رحلتك.';

  @override
  String get esimHow2Title => 'ثبّتها بلمسة';

  @override
  String get esimHow2Body => 'يضيفها هاتفك بنفسه، بلا رمز ولا خطوات طويلة.';

  @override
  String get esimHow3Title => 'اتصل عند وصولك';

  @override
  String get esimHow3Body => 'تعمل الشريحة بجانب خطك، ويبقى رقمك كما هو.';

  @override
  String get esimTapToInstall => 'اضغط لتثبيتها';

  @override
  String get esimTapToSend => 'اضغط لإرسالها أو تثبيتها';

  @override
  String get esimSearchSection => 'شرائح eSIM للسفر';

  @override
  String get esimSearchTag => 'شريحة eSIM';

  @override
  String esimSearchRowLabel(String name) {
    return 'شريحة eSIM إلى $name';
  }

  @override
  String get esimOneStepTitle => 'بقيت خطوة واحدة';

  @override
  String get esimInstallAction => 'ثبّت الشريحة';

  @override
  String get esimScanBody =>
      'هذا الهاتف لا يثبّتها بلمسة. امسح الرمز من الهاتف الذي ستعمل عليه.';

  @override
  String get esimSendNow => 'أرسلها الآن';

  @override
  String get esimSendAgain => 'أرسلها مرة أخرى';

  @override
  String get esimSendBody => 'يصله رابط ورمز، ويثبّتها من هاتفه بلمسة.';

  @override
  String get esimSentBody => 'أرسلتها. إن لم تصله، أرسلها مرة أخرى.';

  @override
  String get esimGiftKicker => 'هدية';

  @override
  String get esimGiftTo => 'هدية إلى';

  @override
  String get esimShareLink => 'رابط الشريحة';

  @override
  String get esimShareCode => 'رمز الدخول';

  @override
  String get esimShowQr => 'إظهار رمز QR ليمسحه';

  @override
  String get esimTopUpNow => 'اشحنها الآن';

  @override
  String get esimTopUpAction => 'اشحن الشريحة';

  @override
  String get esimLowTitle => 'قاربت على الانتهاء';

  @override
  String get esimWhoForTitle => 'لمن سترسلها؟';

  @override
  String get esimContinue => 'متابعة';

  @override
  String get esimDetailsTitle => 'التفاصيل';

  @override
  String esimSendToName(String name) {
    return 'أرسلها إلى $name';
  }

  @override
  String get esimLowBodyTopUp => 'اشحنها الآن لتبقى متصلاً.';

  @override
  String get esimLowBodyNew =>
      'لا تُشحن هذه الباقة. اشترِ شريحة جديدة لتبقى متصلاً.';

  @override
  String get orderStatusHeading => 'حالة الطلب';

  @override
  String get orderDetailsHeading => 'التفاصيل';

  @override
  String get orderStepPlaced => 'تم الطلب';

  @override
  String get orderStepPaid => 'تم الدفع';

  @override
  String orderStepSending(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'إرسال الهدية',
      'telegram': 'الإرسال إلى حساب تيليجرام',
      'steam': 'الإضافة إلى محفظة ستيم',
      'other': 'الإرسال إلى حساب اللاعب',
    });
    return '$_temp0';
  }

  @override
  String get orderStepRefunded => 'أُعيد المبلغ إلى رصيدك';

  @override
  String get reportProblem => 'الإبلاغ عن مشكلة';

  @override
  String get reportAgain => 'الإبلاغ عن مشكلة أخرى';

  @override
  String get reportTitle => 'ما المشكلة؟';

  @override
  String get reportBody => 'اختر ما حدث، ونراجع طلبك ونرد عليك هنا وفي إشعار.';

  @override
  String reportNotArrived(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'لم تصل الهدية',
      'steam': 'لم يُضف الرصيد',
      'other': 'لم يصل الشحن',
    });
    return '$_temp0';
  }

  @override
  String reportWrongAccount(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'وصلت الهدية إلى حساب آخر',
      'telegram': 'وصل إلى اسم مستخدم آخر',
      'steam': 'أُضيف إلى حساب ستيم آخر',
      'other': 'وصل إلى معرّف لاعب آخر',
    });
    return '$_temp0';
  }

  @override
  String reportWrongAmount(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'وصلت لعبة أو نسخة غير التي طلبتها',
      'other': 'الكمية غير صحيحة',
    });
    return '$_temp0';
  }

  @override
  String get reportOther => 'مشكلة أخرى';

  @override
  String get reportNote => 'تفاصيل تساعدنا (اختياري)';

  @override
  String reportNoteHint(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'مثلاً: لم يصلني طلب الصداقة',
      'steam': 'مثلاً: أُضيف جزء من الرصيد فقط',
      'other': 'مثلاً: وصل جزء من الشحن فقط',
    });
    return '$_temp0';
  }

  @override
  String get reportSend => 'إرسال البلاغ';

  @override
  String get reportSent => 'وصلنا بلاغك. نراجعه ونرد عليك.';

  @override
  String get reportOpenTitle => 'بلاغك قيد المراجعة';

  @override
  String reportOpenBody(String reason) {
    return 'أبلغت: $reason. نرد عليك هنا وفي إشعار.';
  }

  @override
  String get reportReplyTitle => 'ردّنا على بلاغك';

  @override
  String get reportResolvedBody => 'راجعنا بلاغك عن هذا الطلب.';

  @override
  String get reportWhatsApp => 'أو راسلنا على واتساب';
}
