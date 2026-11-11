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
  String get chooseCountry => 'Country or region';

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
  String get errAccountBlocked =>
      'This account is stopped. Contact us to restart it.';

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
  String get hostedTitle => 'Checking your payment';

  @override
  String get hostedBody =>
      'Your card payment went through and we\'re confirming it. Your card will appear here in a moment.';

  @override
  String get cancelOrder => 'Cancel order';

  @override
  String get preparingTitle => 'Getting your card ready…';

  @override
  String get preparingBody =>
      'Usually within seconds. You can close the app; the card will be saved in “My cards”.';

  @override
  String get preparingSlowTitle => 'The supplier is slower this time';

  @override
  String get preparingSlowNotify =>
      'No need to wait here: when your order is ready we\'ll send you a notification that opens it in My cards.';

  @override
  String get preparingSlowAsk =>
      'Turn on notifications and we\'ll tell you when your order is ready, or come back to it later in My cards.';

  @override
  String get preparingSlowLater =>
      'No need to wait here: you\'ll find your order in My cards when it\'s ready.';

  @override
  String get goToMyCards => 'Go to My cards';

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
  String get shareAction => 'Share';

  @override
  String get linkCopiedNotice => 'Link copied';

  @override
  String get redeemAction => 'Redeem';

  @override
  String get dialCopiedNotice =>
      'Dial code copied. Paste it into Phone, then call.';

  @override
  String get redeemCopiedNotice =>
      'Secret code copied. If the page does not show it, paste it there.';

  @override
  String get rechargeNow => 'Recharge now';

  @override
  String get showQr => 'QR code';

  @override
  String get qrRevealHint => 'Tap the card to show the QR';

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
  String get notificationOpenAction => 'View';

  @override
  String get notificationsTitle => 'Notifications';

  @override
  String get notificationsBlockedNotice =>
      'Notifications are off in the phone\'s settings';

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
  String get payNotFinishedWalletBody =>
      'Nothing has been charged yet. A wallet’s code is only asked for at purchase, so cancel this order and buy again.';

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
  String get onboardingNotifyTitle => 'Offers reach you first';

  @override
  String get onboardingNotifyBody =>
      'Turn on notifications and we\'ll tell you about offers and new cards the moment they arrive.';

  @override
  String get onboardingNotifyAllow => 'Turn on notifications';

  @override
  String get onboardingNotifyLater => 'Not now';

  @override
  String get onboardingNotifyOnBody =>
      'Notifications are on: we\'ll tell you about offers and new cards the moment they arrive.';

  @override
  String get onboardingReplay => 'Take the tour';

  @override
  String get getAppBody => 'Faster on your phone, your cards always with you';

  @override
  String get getAppAction => 'Get';

  @override
  String get licensesIntro =>
      'Daftar Cards is built on open-source software, with thanks to its authors. Here are their licenses, as published.';

  @override
  String get searchTitle => 'Search';

  @override
  String get searchBrowseCategories => 'Browse categories';

  @override
  String get filterIncomplete => 'Incomplete';

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
  String get webOnlyBadge => 'Web only';

  @override
  String get webOnlyTitle => 'Available on the website';

  @override
  String get webOnlyBody =>
      'This card can\'t be bought in this app. Find it on cards.dftr.ly';

  @override
  String get steamBadge => 'Steam';

  @override
  String get xboxBadge => 'Xbox';

  @override
  String get eaBadge => 'EA';

  @override
  String get rockstarBadge => 'Rockstar';

  @override
  String get heardFromTitle => 'Where did you hear about Daftar Cards?';

  @override
  String get heardFromBody =>
      'Pick one: it helps us reach people who need the app.';

  @override
  String get heardFromFacebook => 'Facebook';

  @override
  String get heardFromInstagram => 'Instagram';

  @override
  String get heardFromTiktok => 'TikTok';

  @override
  String get heardFromWhatsapp => 'WhatsApp';

  @override
  String get heardFromFriend => 'A friend or relative';

  @override
  String get heardFromShop => 'A shop';

  @override
  String get heardFromBillboard => 'A billboard';

  @override
  String get heardFromStoreSearch => 'Searching the app store';

  @override
  String get heardFromOther => 'Something else';

  @override
  String get campaignCodeLabel => 'Got a code from an ad or a friend?';

  @override
  String get campaignCodeHint => 'e.g. UNI1';

  @override
  String get campaignCodeCheck => 'Check';

  @override
  String get campaignCodeUnknown => 'This code is unknown or has ended.';

  @override
  String get campaignCodeValid => 'Code accepted, thank you.';

  @override
  String campaignCodeRewardLater(String amount) {
    return 'Code accepted: $amount goes into your balance when you sign in.';
  }

  @override
  String campaignCodeRewardNow(String amount) {
    return 'Code accepted: $amount goes into your balance.';
  }

  @override
  String campaignLinkReward(String code, String amount) {
    return 'You came with code $code: $amount goes into your balance when you sign in.';
  }

  @override
  String rewardTitle(String amount) {
    return '$amount added to your balance';
  }

  @override
  String rewardBecauseCode(String code) {
    return 'Because you used the code $code.';
  }

  @override
  String rewardBecauseCreator(String name) {
    return 'Because you came through $name.';
  }

  @override
  String get rewardBecauseCreatorUnnamed =>
      'Because you came through a creator we work with.';

  @override
  String rewardBecauseFlyer(String name) {
    return 'Because you scanned the $name code.';
  }

  @override
  String get rewardBecauseFlyerUnnamed =>
      'Because you scanned the flyer\'s code.';

  @override
  String get rewardBecauseBillboardUnnamed =>
      'Because you scanned the billboard\'s code.';

  @override
  String rewardBecauseInvite(String name) {
    return 'Because $name invited you.';
  }

  @override
  String get rewardBecauseInviteUnnamed => 'Because a friend invited you.';

  @override
  String get rewardBecauseAd => 'Because you came from our ad.';

  @override
  String get rewardBody =>
      'It comes off the price of your next card automatically, with no fees.';

  @override
  String get rewardAction => 'Shop now';

  @override
  String topUpPill(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Gift to your account',
      'other': 'Direct top-up',
    });
    return '$_temp0';
  }

  @override
  String topUpAccountTitle(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'telegram': 'Telegram account',
      'steam': 'Steam account',
      'invite': 'Steam account',
      'other': 'Player account',
    });
    return '$_temp0';
  }

  @override
  String topUpAccountBody(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'telegram': 'Sent straight to the account, no code to enter.',
      'steam': 'Added straight to your Steam wallet.',
      'invite':
          'The game arrives as a gift on your Steam account, no code to enter.',
      'other': 'Sent straight to your game account, no code to enter.',
    });
    return '$_temp0';
  }

  @override
  String topUpHintTitle(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'telegram': 'Where do I find my username?',
      'steam': 'What is my login?',
      'invite': 'How do I get the link?',
      'other': 'Where do I find my ID?',
    });
    return '$_temp0';
  }

  @override
  String get chooseAmount => 'Choose an amount';

  @override
  String get savedAccounts => 'Your accounts';

  @override
  String get otherAccount => 'Another account';

  @override
  String forgetAccount(String account) {
    return 'Forget $account';
  }

  @override
  String get pasteAction => 'Paste';

  @override
  String get pasteFailed =>
      'Couldn\'t paste from the clipboard. Paste straight into the field.';

  @override
  String get chooseOption => 'Choose';

  @override
  String accountRequired(String field) {
    return 'Enter $field';
  }

  @override
  String accountChoose(String field) {
    return 'Choose $field';
  }

  @override
  String get accountTooLong => 'Too long.';

  @override
  String get accountNotTelegram =>
      'A username is 5 to 32 English letters, digits or _, starting with a letter.';

  @override
  String get accountNotSteamLogin =>
      'A login is English letters, digits and _ only, with no spaces.';

  @override
  String get accountNotInvite =>
      'This is not a Steam invite link. Copy the “Quick Invite” link from Steam as it is and paste it here.';

  @override
  String get accountChecking => 'Checking the account…';

  @override
  String accountPlayer(String name) {
    return 'Player: $name';
  }

  @override
  String accountFound(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'steam': 'This account can be topped up',
      'other': 'Account found',
    });
    return '$_temp0';
  }

  @override
  String accountNotFound(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'steam': 'This Steam account cannot be topped up. Check the login.',
      'other': 'No account has this ID. Check it on your profile in the game.',
    });
    return '$_temp0';
  }

  @override
  String get accountUnconfirmed =>
      'We could not confirm the account right now. Check it carefully before paying.';

  @override
  String accountUnchecked(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Check the link: the gift goes to its owner.',
      'telegram': 'Check the username: it is sent straight there and cannot be returned.',
      'other': 'Check the ID: the top-up goes straight there and cannot be returned.',
    });
    return '$_temp0';
  }

  @override
  String topUpAction(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Buy',
      'telegram': 'Buy',
      'other': 'Top up',
    });
    return '$_temp0';
  }

  @override
  String buyBarTo(String account) {
    return 'To $account';
  }

  @override
  String buyBarNeedsAccount(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'telegram': 'Enter the username',
      'steam': 'Enter the login',
      'invite': 'Paste the invite link',
      'other': 'Enter the ID',
    });
    return '$_temp0';
  }

  @override
  String get sendToLabel => 'To';

  @override
  String get editAction => 'Edit';

  @override
  String topUpPreparingTitle(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Sending your gift…',
      'telegram': 'Topping up the Telegram account…',
      'steam': 'Adding funds to the Steam wallet…',
      'other': 'Topping up the player\'s account…',
    });
    return '$_temp0';
  }

  @override
  String topUpPreparingBody(String kind, String item, String account) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Steam will send you a friend request, then the gift: accept both when they arrive.',
      'other': 'Sending $item to $account. It usually takes a minute or two.',
    });
    return '$_temp0';
  }

  @override
  String topUpSlowTitle(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Your gift is taking longer this time',
      'steam': 'The funds are taking longer this time',
      'other': 'The top-up is taking longer this time',
    });
    return '$_temp0';
  }

  @override
  String topUpRefundedTitle(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'The gift wasn\'t sent',
      'steam': 'The funds weren\'t added',
      'other': 'The top-up didn\'t go through',
    });
    return '$_temp0';
  }

  @override
  String topUpRefundedBody(String kind, String amount) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite':
          'The gift wasn\'t sent, so we put $amount back in your credit. Check the invite link and try again.',
      'telegram':
          'The top-up didn\'t reach the Telegram account, so we put $amount back in your credit. Check the username and try again.',
      'steam':
          'The funds weren\'t added to the Steam wallet, so we put $amount back in your credit. Check the login name and try again.',
      'other':
          'The top-up didn\'t reach the player\'s account, so we put $amount back in your credit. Check the player ID and try again.',
    });
    return '$_temp0';
  }

  @override
  String toppedUpTitle(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Gift sent',
      'other': 'Topped up',
    });
    return '$_temp0';
  }

  @override
  String get receiptTo => 'To';

  @override
  String get receiptPlayer => 'Player';

  @override
  String get receiptPaid => 'Amount';

  @override
  String get receiptWhen => 'Time';

  @override
  String get receiptOrder => 'Order number';

  @override
  String get whatNextTitle => 'What next?';

  @override
  String topUpNext(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'telegram': 'Open Telegram: it is in your account within minutes.',
      'steam': 'Open Steam: the balance shows in your wallet within minutes.',
      'invite': 'In Steam: accept the friend request you get, then the gift from your notifications. The gift arrives minutes after the friend request is accepted.',
      'other': 'Open the game: the balance shows in your account within minutes. If it does not, close the game and open it again.',
    });
    return '$_temp0';
  }

  @override
  String topUpAgain(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Buy another gift',
      'other': 'Top up again',
    });
    return '$_temp0';
  }

  @override
  String get topUpHelp => 'Not arrived? Message us on WhatsApp';

  @override
  String topUpHelpMessage(String kind, String order) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Hello, order $order: the gift didn\'t arrive.',
      'telegram': 'Hello, order $order didn\'t reach the Telegram account.',
      'steam': 'Hello, order $order wasn\'t added to the Steam wallet.',
      'other': 'Hello, order $order didn\'t reach the player\'s account.',
    });
    return '$_temp0';
  }

  @override
  String get orderIdCopied => 'Order number copied';

  @override
  String statusToppedUp(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Gift sent',
      'other': 'Topped up',
    });
    return '$_temp0';
  }

  @override
  String get statusToppingUp => 'Topping up';

  @override
  String orderTo(String account) {
    return 'To $account';
  }

  @override
  String get removeAccount => 'Remove';

  @override
  String accountRemoved(String account) {
    return '$account removed from this phone';
  }

  @override
  String get undoAction => 'Undo';

  @override
  String get chooseEdition => 'Choose an edition';

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
  String esimShareTextNoCode(String destination, String plan, String link) {
    return 'شريحة إنترنت (eSIM) لـ $destination: $plan\nافتح هذا الرابط من الهاتف الذي ستعمل عليه:\n$link';
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
  String get orderStatusHeading => 'Order status';

  @override
  String get orderDetailsHeading => 'Details';

  @override
  String get orderStepPlaced => 'Ordered';

  @override
  String get orderStepPaid => 'Paid';

  @override
  String orderStepSending(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Sending the gift',
      'telegram': 'Sending to the Telegram account',
      'steam': 'Adding to the Steam wallet',
      'other': 'Sending to the player\'s account',
    });
    return '$_temp0';
  }

  @override
  String get orderStepRefunded => 'Refunded to your credit';

  @override
  String get reportProblem => 'Report a problem';

  @override
  String get reportAgain => 'Report another problem';

  @override
  String get reportTitle => 'What went wrong?';

  @override
  String get reportBody =>
      'Tell us what happened. We\'ll check your order and reply here and in a notification.';

  @override
  String reportNotArrived(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'The gift didn\'t arrive',
      'steam': 'The funds weren\'t added',
      'other': 'It didn\'t arrive',
    });
    return '$_temp0';
  }

  @override
  String reportWrongAccount(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'The gift went to another account',
      'telegram': 'It went to another username',
      'steam': 'It went to another Steam account',
      'other': 'It went to another player ID',
    });
    return '$_temp0';
  }

  @override
  String reportWrongAmount(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'A different game or edition arrived',
      'other': 'The amount is wrong',
    });
    return '$_temp0';
  }

  @override
  String get reportOther => 'Something else';

  @override
  String get reportNote => 'Details that help us (optional)';

  @override
  String reportNoteHint(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'For example: no friend request came',
      'steam': 'For example: only part of the funds arrived',
      'other': 'For example: only part of it arrived',
    });
    return '$_temp0';
  }

  @override
  String get reportSend => 'Send report';

  @override
  String get reportSent => 'We got your report. We\'ll check and reply.';

  @override
  String get reportOpenTitle => 'We\'re looking into your report';

  @override
  String reportOpenBody(String reason) {
    return 'You reported: $reason. We\'ll reply here and in a notification.';
  }

  @override
  String get reportReplyTitle => 'Our reply to your report';

  @override
  String get reportResolvedBody =>
      'We looked into your report about this order.';

  @override
  String get reportWhatsApp => 'Or message us on WhatsApp';

  @override
  String get esimPerkInstant => 'Instant activation';

  @override
  String get esimPerkNoPlastic => 'No plastic SIM';

  @override
  String get esimPerkTopUp => 'Top up in the app';

  @override
  String get esimPlansTitle => 'Choose your plan';

  @override
  String esimPromoOff(int percent) {
    return '$percent% off';
  }

  @override
  String get esimOffersTitle => 'Today\'s offers';

  @override
  String get esimFilterOffers => 'Offers';

  @override
  String get esimFilterDays => 'Trip length';

  @override
  String esimFilterDaysOption(int days) {
    return '$days+ days';
  }

  @override
  String get esimFilterData => 'Data';

  @override
  String get esimFilterAny => 'Any';

  @override
  String get esimSortTitle => 'Sort';

  @override
  String get esimSortName => 'A to Z';

  @override
  String get esimSortCheapest => 'Cheapest first';

  @override
  String get esimFilterClear => 'Clear';

  @override
  String esimResultsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count destinations',
      one: '1 destination',
    );
    return '$_temp0';
  }

  @override
  String get esimFilterNone =>
      'No destination fits. Try a shorter trip or less data.';

  @override
  String get esimShareDestination => 'Share';
}
