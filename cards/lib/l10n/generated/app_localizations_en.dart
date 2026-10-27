// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Daftar Cards';

  @override
  String get tabHome => 'Home';

  @override
  String get tabMyCards => 'My cards';

  @override
  String get tabAccount => 'Account';

  @override
  String get homeSearchHint => 'Search for a card: Libyana, PUBG, iTunes…';

  @override
  String get homeTagline =>
      'Phone, internet and gaming cards, delivered instantly';

  @override
  String get myCardsEmptyTitle => 'No cards yet';

  @override
  String get myCardsEmptyBody =>
      'Cards you buy are saved here, ready whenever you need them.';

  @override
  String get accountSignedOutTitle => 'Sign in with your phone number';

  @override
  String get accountSignedOutBody => 'We text you a code. No password needed.';

  @override
  String get signInAction => 'Sign in';

  @override
  String get browseAction => 'Browse cards';

  @override
  String moneyAmount(String amount) {
    return '$amount LYD';
  }

  @override
  String get errorNetwork =>
      'Couldn\'t connect. Check your internet and try again.';

  @override
  String get errorGeneric => 'Something went wrong. Please try again.';

  @override
  String get retryAction => 'Try again';

  @override
  String get buyAgainTitle => 'Buy again';

  @override
  String get allCategories => 'All';

  @override
  String fromPrice(String price) {
    return 'From $price';
  }

  @override
  String get unavailableNow => 'Unavailable right now';

  @override
  String searchNoResultsTitle(String query) {
    return 'No results for “$query”';
  }

  @override
  String get searchNoResultsBody =>
      'Try another name or browse the categories.';

  @override
  String get catalogEmptyTitle => 'No cards available right now';

  @override
  String get catalogEmptyBody => 'We\'re stocking up. Check back shortly.';

  @override
  String get catalogLoadFailedTitle => 'Couldn\'t load the cards';

  @override
  String get savedShelfNote => 'Showing the last saved copy';

  @override
  String creditChip(String amount) {
    return 'Credit $amount';
  }

  @override
  String get chooseValue => 'Choose a value';

  @override
  String get chooseCountry => 'Country';

  @override
  String get howToRedeem => 'How to use';

  @override
  String get quantityLabel => 'Quantity';

  @override
  String buyFor(String amount) {
    return 'Buy for $amount';
  }

  @override
  String get increaseQuantity => 'Increase quantity';

  @override
  String get decreaseQuantity => 'Decrease quantity';

  @override
  String get signInTitle => 'Sign in';

  @override
  String get signInSubtitle =>
      'Enter your phone number and we\'ll text you a sign-in code. No password needed.';

  @override
  String get phoneLabel => 'Phone number';

  @override
  String get sendCode => 'Send code';

  @override
  String get codeTitle => 'Enter the code';

  @override
  String get codeSentTo => 'We sent a 6-digit code to';

  @override
  String resendIn(int seconds) {
    return 'Resend in ${seconds}s';
  }

  @override
  String get resendCode => 'Resend code';

  @override
  String get changeNumber => 'Change number';

  @override
  String get signInDone => 'Welcome! You\'re signed in';

  @override
  String get errInvalidPhone => 'Enter a valid Libyan number starting with 09';

  @override
  String errWrongCode(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Wrong code. $count attempts left.',
      one: 'Wrong code. 1 attempt left.',
      zero: 'Wrong code.',
    );
    return '$_temp0';
  }

  @override
  String get errCodeExpired => 'The code has expired. Ask for a new one.';

  @override
  String get errTooManyAttempts => 'Too many attempts. Ask for a new code.';

  @override
  String get errTooSoon => 'Please wait a moment before asking for a new code.';

  @override
  String get errDailyLimit =>
      'You\'ve reached today\'s code limit. Try again tomorrow.';

  @override
  String get errSendFailed => 'Couldn\'t send the code. Please try again.';

  @override
  String get errRateLimited => 'Too many requests. Try again shortly.';

  @override
  String get errSignInRequired => 'Sign in to continue.';

  @override
  String get checkoutTitle => 'Checkout';

  @override
  String get payWith => 'Pay with';

  @override
  String get bankCards => 'Bank cards';

  @override
  String useCredit(String amount) {
    return 'Use your credit ($amount)';
  }

  @override
  String get lineSubtotal => 'Price';

  @override
  String get lineCredit => 'From your credit';

  @override
  String get lineFee => 'Payment fee';

  @override
  String get lineTotal => 'To pay';

  @override
  String payAmount(String amount) {
    return 'Pay $amount';
  }

  @override
  String get payFromCredit => 'Pay from your credit';

  @override
  String get instantDelivery => 'Your code arrives the moment you pay.';

  @override
  String payerTitle(String method) {
    return 'Pay with $method';
  }

  @override
  String get payerPhone => 'Wallet number';

  @override
  String get payerCard => 'Wallet card number';

  @override
  String get payerBirthYear => 'Year of birth';

  @override
  String get continueAction => 'Continue';

  @override
  String get cancelAction => 'Cancel';

  @override
  String walletCodeTitle(String method) {
    return '$method confirmation code';
  }

  @override
  String walletCodeBody(String method, String amount) {
    return '$method sent a code to your phone to confirm paying $amount. This is not your sign-in code.';
  }

  @override
  String get confirmPayment => 'Confirm payment';

  @override
  String errOtpRejected(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Wrong payment code. $count attempts left.',
      one: 'Wrong payment code. 1 attempt left.',
      zero: 'Wrong payment code.',
    );
    return '$_temp0';
  }

  @override
  String get errDeclined =>
      'Your bank or wallet declined the payment. Nothing was charged.';

  @override
  String errPriceChanged(String amount) {
    return 'The price changed to $amount. Check it, then continue.';
  }

  @override
  String get errItemUnavailable => 'This card is unavailable right now.';

  @override
  String get errPaymentFailed =>
      'Couldn\'t start the payment. Try again or choose another method.';

  @override
  String get errPaymentsUnavailable =>
      'Payments are unavailable right now. Try again shortly.';

  @override
  String get errInvalidPayer => 'Check your payment details.';

  @override
  String get hostedTitle => 'Finish paying on the card page';

  @override
  String get hostedBody =>
      'We opened the secure payment page. Once you\'ve paid, come back here and your card will appear by itself.';

  @override
  String get openPaymentPage => 'Open payment page';

  @override
  String get cancelOrder => 'Cancel order';

  @override
  String get preparingTitle => 'Getting your card ready…';

  @override
  String get preparingBody =>
      'Usually within seconds. You can close the app; the card will be saved in “My cards”.';

  @override
  String get refundedTitle => 'We couldn\'t buy the card';

  @override
  String refundedBody(String amount) {
    return 'We returned $amount to your credit for your next order.';
  }

  @override
  String get unpaidTitle => 'Payment not completed';

  @override
  String get unpaidBody => 'Nothing was charged. You can try again.';

  @override
  String get tryAgain => 'Try again';

  @override
  String get backToShop => 'Back to cards';

  @override
  String get revealTitle => 'Your card is ready';

  @override
  String get secretCode => 'Secret code';

  @override
  String serialNumber(String serial) {
    return 'Serial number: $serial';
  }

  @override
  String get copyAction => 'Copy';

  @override
  String get copiedNotice => 'Secret code copied';

  @override
  String get rechargeNow => 'Recharge now';

  @override
  String get showQr => 'QR code';

  @override
  String get qrScanHint => 'Scan it with a camera to read the secret code';

  @override
  String get sendAsGift => 'Send as a gift';

  @override
  String giftMessage(String name, String code) {
    return 'A gift for you from Daftar Cards\n$name\nSecret code: $code';
  }

  @override
  String get markUsed => 'Mark as used';

  @override
  String get markUnused => 'Mark as unused';

  @override
  String get usedBadge => 'Used';

  @override
  String get doneAction => 'Done';

  @override
  String get codesLockedTitle => 'Your codes are protected';

  @override
  String get codesLockedBody => 'Confirm it\'s you to see the secret codes.';

  @override
  String get unlockAction => 'Show codes';

  @override
  String get unlockReason => 'Confirm it\'s you to see your card codes';

  @override
  String get codesPendingTitle => 'Reading the code from the supplier…';

  @override
  String get codesPendingBody =>
      'The card is paid for and saved. Its secret code will appear here in a moment.';

  @override
  String get filterUnused => 'Unused';

  @override
  String get filterUsed => 'Used';

  @override
  String get statusPreparing => 'Preparing';

  @override
  String get statusAwaitingPayment => 'Awaiting payment';

  @override
  String get statusRefunded => 'Returned to credit';

  @override
  String get statusUnpaid => 'Not completed';

  @override
  String cardCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count cards',
      one: '1 card',
    );
    return '$_temp0';
  }

  @override
  String get myCardsSignedOutBody => 'Sign in to see your cards on any device.';

  @override
  String get creditTitle => 'Your credit';

  @override
  String get creditBody => 'Used on your next orders.';

  @override
  String get creditOrder => 'Order payment';

  @override
  String get creditRefund => 'Order refund';

  @override
  String get creditRelease => 'Credit back from an unfinished order';

  @override
  String get creditLatePayment => 'Payment that arrived after the order closed';

  @override
  String get devicesTitle => 'Signed-in devices';

  @override
  String get thisDevice => 'This device';

  @override
  String get signOutOthers => 'Sign out of other devices';

  @override
  String get signOutOthersDone => 'Signed out of other devices';

  @override
  String get signOut => 'Sign out';

  @override
  String get deleteAccount => 'Delete account';

  @override
  String get deleteAccountTitle => 'Delete your account?';

  @override
  String get deleteAccountBody =>
      'We\'ll permanently delete your number and all your sessions. Copy your cards\' secret codes before deleting.';

  @override
  String get deleteAction => 'Delete';

  @override
  String get accountDeleted => 'Your account was deleted';

  @override
  String get deviceBrowser => 'Browser';

  @override
  String get paymentReviewTitle => 'We\'re reviewing your payment';

  @override
  String get paymentReviewBody =>
      'A payment arrived for a different amount than the order, so we paused it for review. We\'ll contact you, and you won\'t lose anything.';

  @override
  String get statusReview => 'Under review';

  @override
  String get homeTitle => 'Discover cards';

  @override
  String get seeAll => 'See all';

  @override
  String get featuredTitle => 'Most popular';

  @override
  String get paymentMethodLabel => 'Payment method';

  @override
  String get changeAction => 'Change';

  @override
  String get choosePaymentMethod => 'Choose a payment method';

  @override
  String get securePaymentNote =>
      'Payments go through the secure Dafa gateway. We never keep your payment details.';

  @override
  String get purchaseSuccess => 'Purchase complete';

  @override
  String cardIndex(int index, int count) {
    return 'Card $index of $count';
  }

  @override
  String get closeAction => 'Close';

  @override
  String get perCard => 'per card';

  @override
  String get creditHistory => 'Credit history';

  @override
  String get accountSection => 'Account';

  @override
  String get inProgressSection => 'In progress';

  @override
  String get myCardsSection => 'Your cards';

  @override
  String get searchResults => 'Search results';

  @override
  String get startingFrom => 'Starting from';

  @override
  String get buyNow => 'Buy';

  @override
  String get splashDaftar => 'دفتر';

  @override
  String get splashCards => 'كروت';

  @override
  String get refundedToCredit => 'Added to your credit';

  @override
  String get settingsSection => 'Settings';

  @override
  String get codeLockTitle => 'Protect codes';

  @override
  String get codeLockBody =>
      'Ask for Face ID or fingerprint before showing secret codes';

  @override
  String get codeLockOffReason =>
      'Confirm it\'s you to turn off code protection';

  @override
  String get shareUsageTitle => 'Share usage data';

  @override
  String get themeTitle => 'Appearance';

  @override
  String get themeSystem => 'Automatic';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get languageTitle => 'Language';

  @override
  String get aboutSection => 'About';

  @override
  String get aboutTitle => 'About Daftar Cards';

  @override
  String get aboutTagline => 'Phone and internet cards, delivered instantly.';

  @override
  String get aboutBody =>
      'Daftar Cards is an app by Daftar, the sales system shops across Libya run on. Pick a card, pay with your wallet or bank card, and its code arrives in seconds, kept in My cards for whenever you need it.';

  @override
  String aboutVersion(String version) {
    return 'Version $version';
  }

  @override
  String get aboutCopyright => '© 2026 Daftar';

  @override
  String get contactWhatsApp => 'Contact us on WhatsApp';

  @override
  String get websiteTitle => 'Website';

  @override
  String get privacyPolicy => 'Privacy policy';

  @override
  String get termsOfUse => 'Terms of use';

  @override
  String get openSourceLicenses => 'Open-source licenses';

  @override
  String signInConsent(String terms, String privacy) {
    return 'By continuing, you agree to the $terms and the $privacy.';
  }

  @override
  String get cardPayTitle => 'Pay by bank card';

  @override
  String get cardThroughMoamalat => 'Through the Moamalat gateway';

  @override
  String get cardNumberLabel => 'Card number';

  @override
  String get cardExpiryLabel => 'Expiry date';

  @override
  String get cardNumberInvalid => 'That card number is not valid.';

  @override
  String get cardExpiryInvalid =>
      'Enter the expiry as on the card: month/year.';

  @override
  String get cardSecureNote =>
      'Your card details go from your phone straight to the Moamalat gateway. They never pass through our servers and we never keep them.';

  @override
  String get cardOpening => 'Preparing a secure payment…';

  @override
  String get cardCharging => 'Contacting your bank…';

  @override
  String get cardConfirming => 'Paid. Confirming your order…';

  @override
  String get cardVerifyTitle => 'Confirm with your bank';

  @override
  String get cardVerifyBody =>
      'Your bank texted a code to your phone. Enter it on the bank page below to finish paying.';

  @override
  String get cardVerifyCancel => 'Cancel';

  @override
  String get cardErrDeclined =>
      'Your bank declined the payment. Check the card details and balance, or try another card.';

  @override
  String get cardErrExpiry => 'The card expiry date is not right.';

  @override
  String get cardErrNetwork =>
      'Could not reach the payment gateway. Check your connection and try again.';

  @override
  String get cardErrVerification =>
      'Your bank did not finish confirming, and nothing was charged. Try again.';

  @override
  String get cardErrExpired => 'The payment timed out. Try again.';

  @override
  String get cardUsePaymentPage => 'Pay on the gateway page instead';

  @override
  String get cardNameLabel => 'Cardholder name';

  @override
  String get cardNameInvalid => 'Enter the name as written on the card.';

  @override
  String get savedCardsTitle => 'Your saved cards';

  @override
  String get useAnotherCard => 'Use another card';

  @override
  String get saveCardTitle => 'Save this card on this phone';

  @override
  String get saveCardBody =>
      'To pay faster next time. It stays encrypted on this phone only, opens with Face ID or your passcode, and never reaches us.';

  @override
  String get savedCardUnlockReason =>
      'Confirm it’s you to pay with your saved card';

  @override
  String savedCardExpires(String expiry) {
    return 'Expires $expiry';
  }

  @override
  String get savedCardsSettings => 'Saved cards';

  @override
  String get savedCardsEmpty =>
      'No cards saved on this phone. You can save one when you pay with it.';

  @override
  String get savedCardsNote =>
      'Cards are kept on this phone only, encrypted and behind Face ID or your passcode. They never reach our servers and are removed when you sign out.';

  @override
  String get removeCard => 'Remove';

  @override
  String get removeCardTitle => 'Remove this card?';

  @override
  String get removeCardBody =>
      'It will be deleted from this phone. You can save it again when you pay with it.';

  @override
  String get savedCardLocked =>
      'We could not confirm it’s you, so the saved card was not used.';

  @override
  String get payNotFinishedTitle => 'Payment not finished';

  @override
  String get payNotFinishedBody =>
      'Nothing has been charged yet. Finish paying by card, or cancel the order.';

  @override
  String get finishPaying => 'Finish paying';

  @override
  String get orderCancelled => 'Order cancelled.';

  @override
  String get onboardingSkip => 'Skip';

  @override
  String get onboardingNext => 'Next';

  @override
  String get onboardingStart => 'Get started';

  @override
  String onboardingStep(int current, int total) {
    return 'Step $current of $total';
  }

  @override
  String get onboardingShelfTitle => 'All your cards in one place';

  @override
  String get onboardingShelfBody =>
      'Libyana and Almadar credit, internet bundles and more, picked in seconds at clear prices.';

  @override
  String get onboardingInstantTitle => 'Pay, and get the code at once';

  @override
  String get onboardingInstantBody =>
      'Pay with your wallet or your bank card, and your card\'s code appears within seconds.';

  @override
  String get onboardingVaultTitle => 'Your cards, kept safe';

  @override
  String get onboardingVaultBody =>
      'Every card you buy stays in My cards behind your phone\'s lock, ready whenever you need it.';

  @override
  String get onboardingReplay => 'Take the tour';

  @override
  String get licensesIntro =>
      'Daftar Cards is built on open-source software, with thanks to its authors. Here are their licenses, as published.';

  @override
  String get searchTitle => 'Search';

  @override
  String get searchBrowseCategories => 'Browse categories';

  @override
  String get filterIncomplete => 'Incomplete';
}
