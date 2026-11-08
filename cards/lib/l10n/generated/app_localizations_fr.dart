// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String get appTitle => 'Daftar Cartes';

  @override
  String get tabHome => 'Accueil';

  @override
  String get tabMyCards => 'Mes cartes';

  @override
  String get tabAccount => 'Compte';

  @override
  String get homeSearchHint => 'Rechercher une carte : Libyana, PUBG, iTunes…';

  @override
  String get homeTagline =>
      'Cartes téléphone, internet et jeux, livrées instantanément';

  @override
  String get myCardsEmptyTitle => 'Aucune carte pour l\'instant';

  @override
  String get myCardsEmptyBody =>
      'Les cartes que vous achetez sont gardées ici, prêtes quand vous en avez besoin.';

  @override
  String get accountSignedOutTitle => 'Connectez-vous avec votre numéro';

  @override
  String get accountSignedOutBody =>
      'Nous vous envoyons un code par SMS. Pas de mot de passe.';

  @override
  String get signInAction => 'Se connecter';

  @override
  String get browseAction => 'Parcourir les cartes';

  @override
  String moneyAmount(String amount) {
    return '$amount LYD';
  }

  @override
  String get errorNetwork =>
      'Connexion impossible. Vérifiez votre internet et réessayez.';

  @override
  String get errorGeneric => 'Une erreur s\'est produite. Veuillez réessayer.';

  @override
  String get retryAction => 'Réessayer';

  @override
  String get buyAgainTitle => 'Racheter';

  @override
  String get allCategories => 'Tout';

  @override
  String fromPrice(String price) {
    return 'Dès $price';
  }

  @override
  String get unavailableNow => 'Indisponible pour le moment';

  @override
  String searchNoResultsTitle(String query) {
    return 'Aucun résultat pour « $query »';
  }

  @override
  String get searchNoResultsBody =>
      'Essayez un autre nom ou parcourez les catégories.';

  @override
  String get catalogEmptyTitle => 'Aucune carte disponible pour le moment';

  @override
  String get catalogEmptyBody => 'Nous réapprovisionnons. Revenez bientôt.';

  @override
  String get catalogLoadFailedTitle => 'Impossible de charger les cartes';

  @override
  String get savedShelfNote => 'Affiche la dernière copie enregistrée';

  @override
  String creditChip(String amount) {
    return 'Crédit $amount';
  }

  @override
  String get chooseValue => 'Choisissez un montant';

  @override
  String get chooseCountry => 'Pays ou région';

  @override
  String get howToRedeem => 'Mode d\'emploi';

  @override
  String get quantityLabel => 'Quantité';

  @override
  String buyFor(String amount) {
    return 'Acheter pour $amount';
  }

  @override
  String get increaseQuantity => 'Augmenter la quantité';

  @override
  String get decreaseQuantity => 'Diminuer la quantité';

  @override
  String get signInTitle => 'Connexion';

  @override
  String get signInSubtitle =>
      'Saisissez votre numéro et nous vous enverrons un code de connexion. Pas de mot de passe.';

  @override
  String get phoneLabel => 'Numéro de téléphone';

  @override
  String get sendCode => 'Envoyer le code';

  @override
  String get codeTitle => 'Saisissez le code';

  @override
  String get codeSentTo => 'Nous avons envoyé un code à 6 chiffres au';

  @override
  String resendIn(int seconds) {
    return 'Renvoyer dans $seconds s';
  }

  @override
  String get resendCode => 'Renvoyer le code';

  @override
  String get changeNumber => 'Modifier le numéro';

  @override
  String get signInDone => 'Bienvenue ! Vous êtes connecté';

  @override
  String get errInvalidPhone =>
      'Saisissez un numéro libyen valide commençant par 09';

  @override
  String errWrongCode(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Code incorrect. Il reste $count essais.',
      one: 'Code incorrect. Il reste 1 essai.',
      zero: 'Code incorrect.',
    );
    return '$_temp0';
  }

  @override
  String get errCodeExpired => 'Le code a expiré. Demandez-en un nouveau.';

  @override
  String get errTooManyAttempts => 'Trop d\'essais. Demandez un nouveau code.';

  @override
  String get errAccountBlocked =>
      'Ce compte est suspendu. Contactez-nous pour le réactiver.';

  @override
  String get errTooSoon =>
      'Patientez un instant avant de demander un nouveau code.';

  @override
  String get errDailyLimit =>
      'Limite de codes atteinte pour aujourd\'hui. Réessayez demain.';

  @override
  String get errSendFailed =>
      'Impossible d\'envoyer le code. Veuillez réessayer.';

  @override
  String get errRateLimited => 'Trop de demandes. Réessayez dans un instant.';

  @override
  String get errSignInRequired => 'Connectez-vous pour continuer.';

  @override
  String get checkoutTitle => 'Paiement';

  @override
  String get payWith => 'Payer avec';

  @override
  String get bankCards => 'Cartes bancaires';

  @override
  String useCredit(String amount) {
    return 'Utiliser votre crédit ($amount)';
  }

  @override
  String get lineSubtotal => 'Prix';

  @override
  String get lineCredit => 'De votre crédit';

  @override
  String get lineFee => 'Frais de paiement';

  @override
  String get lineTotal => 'À payer';

  @override
  String payAmount(String amount) {
    return 'Payer $amount';
  }

  @override
  String get payFromCredit => 'Payer avec votre crédit';

  @override
  String get instantDelivery => 'Votre code arrive dès le paiement.';

  @override
  String payerTitle(String method) {
    return 'Payer avec $method';
  }

  @override
  String get payerPhone => 'Numéro du portefeuille';

  @override
  String get payerCard => 'Numéro de carte du portefeuille';

  @override
  String get payerBirthYear => 'Année de naissance';

  @override
  String get continueAction => 'Continuer';

  @override
  String get cancelAction => 'Annuler';

  @override
  String walletCodeTitle(String method) {
    return 'Code de confirmation $method';
  }

  @override
  String walletCodeBody(String method, String amount) {
    return '$method a envoyé un code sur votre téléphone pour confirmer le paiement de $amount. Ce n\'est pas votre code de connexion.';
  }

  @override
  String get confirmPayment => 'Confirmer le paiement';

  @override
  String errOtpRejected(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Code de paiement incorrect. Il reste $count essais.',
      one: 'Code de paiement incorrect. Il reste 1 essai.',
      zero: 'Code de paiement incorrect.',
    );
    return '$_temp0';
  }

  @override
  String get errDeclined =>
      'Votre banque ou portefeuille a refusé le paiement. Rien n\'a été débité.';

  @override
  String errPriceChanged(String amount) {
    return 'Le prix est passé à $amount. Vérifiez-le, puis continuez.';
  }

  @override
  String get errItemUnavailable =>
      'Cette carte est indisponible pour le moment.';

  @override
  String get errPaymentFailed =>
      'Impossible de lancer le paiement. Réessayez ou choisissez un autre moyen.';

  @override
  String get errPaymentsUnavailable =>
      'Le paiement est indisponible pour le moment. Réessayez bientôt.';

  @override
  String get errInvalidPayer => 'Vérifiez vos informations de paiement.';

  @override
  String get hostedTitle => 'Vérification du paiement';

  @override
  String get hostedBody =>
      'Votre paiement par carte est passé et nous le confirmons. Votre carte apparaîtra ici dans un instant.';

  @override
  String get cancelOrder => 'Annuler la commande';

  @override
  String get preparingTitle => 'Nous préparons votre carte…';

  @override
  String get preparingBody =>
      'En général en quelques secondes. Vous pouvez fermer l\'app ; la carte sera gardée dans « Mes cartes ».';

  @override
  String get preparingSlowTitle => 'Le fournisseur est plus lent cette fois';

  @override
  String get preparingSlowNotify =>
      'Inutile d\'attendre ici : dès que votre commande est prête, une notification l\'ouvre dans Mes cartes.';

  @override
  String get preparingSlowAsk =>
      'Activez les notifications et nous vous préviendrons quand votre commande sera prête, ou revenez-y plus tard dans Mes cartes.';

  @override
  String get preparingSlowLater =>
      'Inutile d\'attendre ici : vous trouverez votre commande dans Mes cartes dès qu\'elle sera prête.';

  @override
  String get goToMyCards => 'Aller à Mes cartes';

  @override
  String get refundedTitle => 'Nous n\'avons pas pu acheter la carte';

  @override
  String refundedBody(String amount) {
    return 'Nous avons reversé $amount sur votre crédit pour votre prochaine commande.';
  }

  @override
  String get unpaidTitle => 'Paiement non terminé';

  @override
  String get unpaidBody => 'Rien n\'a été débité. Vous pouvez réessayer.';

  @override
  String get tryAgain => 'Réessayer';

  @override
  String get backToShop => 'Retour aux cartes';

  @override
  String get revealTitle => 'Votre carte est prête';

  @override
  String get secretCode => 'Code secret';

  @override
  String serialNumber(String serial) {
    return 'Numéro de série : $serial';
  }

  @override
  String get copyAction => 'Copier';

  @override
  String get copiedNotice => 'Code secret copié';

  @override
  String get shareAction => 'Partager';

  @override
  String get linkCopiedNotice => 'Lien copié';

  @override
  String get redeemAction => 'Utiliser';

  @override
  String get dialCopiedNotice =>
      'Code à composer copié. Collez-le dans Téléphone, puis appelez.';

  @override
  String get redeemCopiedNotice =>
      'Code secret copié. Si la page ne l\'affiche pas, collez-le.';

  @override
  String get rechargeNow => 'Recharger';

  @override
  String get showQr => 'Code QR';

  @override
  String get qrRevealHint => 'Touchez la carte pour afficher le QR';

  @override
  String get qrScanHint =>
      'Scannez-le avec un appareil photo pour lire le code secret';

  @override
  String get sendAsGift => 'Offrir';

  @override
  String giftMessage(String name, String code) {
    return 'Un cadeau pour vous de Daftar Cartes\n$name\nCode secret : $code';
  }

  @override
  String get markUsed => 'Marquer comme utilisée';

  @override
  String get markUnused => 'Marquer comme non utilisée';

  @override
  String get usedBadge => 'Utilisée';

  @override
  String get doneAction => 'Terminé';

  @override
  String get codesLockedTitle => 'Vos codes sont protégés';

  @override
  String get codesLockedBody =>
      'Confirmez votre identité pour voir les codes secrets.';

  @override
  String get unlockAction => 'Afficher les codes';

  @override
  String get unlockReason =>
      'Confirmez votre identité pour voir les codes de vos cartes';

  @override
  String get codesPendingTitle => 'Lecture du code chez le fournisseur…';

  @override
  String get codesPendingBody =>
      'La carte est payée et enregistrée. Son code secret apparaîtra ici dans un instant.';

  @override
  String get filterUnused => 'Non utilisées';

  @override
  String get filterUsed => 'Utilisées';

  @override
  String get statusPreparing => 'En préparation';

  @override
  String get statusAwaitingPayment => 'En attente de paiement';

  @override
  String get statusRefunded => 'Reversé sur votre crédit';

  @override
  String get statusUnpaid => 'Non terminé';

  @override
  String cardCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count cartes',
      one: '1 carte',
    );
    return '$_temp0';
  }

  @override
  String get myCardsSignedOutBody =>
      'Connectez-vous pour voir vos cartes sur n\'importe quel appareil.';

  @override
  String get creditTitle => 'Votre crédit';

  @override
  String get creditBody => 'Utilisé pour vos prochaines commandes.';

  @override
  String get creditOrder => 'Paiement de commande';

  @override
  String get creditRefund => 'Remboursement de commande';

  @override
  String get creditRelease => 'Crédit rendu d\'une commande inachevée';

  @override
  String get creditLatePayment =>
      'Paiement reçu après la clôture de la commande';

  @override
  String get devicesTitle => 'Appareils connectés';

  @override
  String get thisDevice => 'Cet appareil';

  @override
  String get signOutOthers => 'Déconnecter les autres appareils';

  @override
  String get signOutOthersDone => 'Autres appareils déconnectés';

  @override
  String get signOut => 'Se déconnecter';

  @override
  String get deleteAccount => 'Supprimer le compte';

  @override
  String get deleteAccountTitle => 'Supprimer votre compte ?';

  @override
  String get deleteAccountBody =>
      'Nous supprimerons définitivement votre numéro et toutes vos sessions. Copiez les codes secrets de vos cartes avant de supprimer.';

  @override
  String get deleteAction => 'Supprimer';

  @override
  String get accountDeleted => 'Votre compte a été supprimé';

  @override
  String get deviceBrowser => 'Navigateur';

  @override
  String get paymentReviewTitle => 'Nous vérifions votre paiement';

  @override
  String get paymentReviewBody =>
      'Un paiement d\'un montant différent de la commande est arrivé ; nous l\'avons mis en attente pour vérification. Nous vous contacterons, et vous ne perdrez rien.';

  @override
  String get statusReview => 'En vérification';

  @override
  String get homeTitle => 'Découvrir les cartes';

  @override
  String get seeAll => 'Tout voir';

  @override
  String get featuredTitle => 'Les plus demandées';

  @override
  String get paymentMethodLabel => 'Moyen de paiement';

  @override
  String get changeAction => 'Modifier';

  @override
  String get choosePaymentMethod => 'Choisissez un moyen de paiement';

  @override
  String get securePaymentNote =>
      'Le paiement passe par la passerelle sécurisée Dafa. Nous ne conservons pas vos données de paiement.';

  @override
  String get purchaseSuccess => 'Achat réussi';

  @override
  String cardIndex(int index, int count) {
    return 'Carte $index sur $count';
  }

  @override
  String get closeAction => 'Fermer';

  @override
  String get perCard => 'par carte';

  @override
  String get creditHistory => 'Historique du crédit';

  @override
  String get accountSection => 'Compte';

  @override
  String get inProgressSection => 'En cours';

  @override
  String get myCardsSection => 'Vos cartes';

  @override
  String get searchResults => 'Résultats de recherche';

  @override
  String get startingFrom => 'À partir de';

  @override
  String get buyNow => 'Acheter';

  @override
  String get splashDaftar => 'دفتر';

  @override
  String get splashCards => 'كروت';

  @override
  String get refundedToCredit => 'Ajouté à votre crédit';

  @override
  String get settingsSection => 'Réglages';

  @override
  String get codeLockTitle => 'Protéger les codes';

  @override
  String get codeLockBody =>
      'Demander Face ID ou l\'empreinte avant d\'afficher les codes secrets';

  @override
  String get codeLockOffReason =>
      'Confirmez votre identité pour désactiver la protection des codes';

  @override
  String get shareUsageTitle => 'Partager les données d\'utilisation';

  @override
  String get notificationOpenAction => 'Voir';

  @override
  String get notificationsTitle => 'Notifications';

  @override
  String get notificationsBlockedNotice =>
      'Les notifications sont désactivées dans les réglages du téléphone';

  @override
  String get themeTitle => 'Apparence';

  @override
  String get themeSystem => 'Automatique';

  @override
  String get themeLight => 'Clair';

  @override
  String get themeDark => 'Sombre';

  @override
  String get languageTitle => 'Langue';

  @override
  String get aboutSection => 'À propos';

  @override
  String get aboutTitle => 'À propos de Daftar Cartes';

  @override
  String get aboutTagline =>
      'Cartes de recharge et d’internet, livrées instantanément.';

  @override
  String get aboutBody =>
      'Daftar Cartes est une application de Daftar, le système de vente utilisé par les commerces en Libye. Choisissez une carte, payez avec votre portefeuille ou votre carte bancaire, et son code arrive en quelques secondes, conservé dans Mes cartes.';

  @override
  String aboutVersion(String version) {
    return 'Version $version';
  }

  @override
  String get aboutCopyright => '© 2026 Daftar';

  @override
  String get contactWhatsApp => 'Nous contacter sur WhatsApp';

  @override
  String get websiteTitle => 'Site web';

  @override
  String get privacyPolicy => 'Politique de confidentialité';

  @override
  String get termsOfUse => 'Conditions d’utilisation';

  @override
  String get openSourceLicenses => 'Licences open source';

  @override
  String signInConsent(String terms, String privacy) {
    return 'En continuant, vous acceptez les $terms et la $privacy.';
  }

  @override
  String get cardPayTitle => 'Payer par carte bancaire';

  @override
  String get cardThroughMoamalat => 'Via la passerelle Moamalat';

  @override
  String get cardNumberLabel => 'Numéro de carte';

  @override
  String get cardExpiryLabel => 'Date d’expiration';

  @override
  String get cardNumberInvalid => 'Ce numéro de carte n’est pas valide.';

  @override
  String get cardExpiryInvalid =>
      'Saisissez l’expiration comme sur la carte : mois/année.';

  @override
  String get cardSecureNote =>
      'Vos données de carte vont directement de votre téléphone à la passerelle Moamalat. Elles ne passent jamais par nos serveurs et nous ne les gardons pas.';

  @override
  String get cardOpening => 'Préparation du paiement sécurisé…';

  @override
  String get cardCharging => 'Contact avec votre banque…';

  @override
  String get cardConfirming => 'Payé. Confirmation de votre commande…';

  @override
  String get cardVerifyTitle => 'Confirmer avec votre banque';

  @override
  String get cardVerifyBody =>
      'Votre banque vous a envoyé un code par SMS. Saisissez-le sur la page de la banque ci-dessous.';

  @override
  String get cardVerifyCancel => 'Annuler';

  @override
  String get cardErrDeclined =>
      'Votre banque a refusé le paiement. Vérifiez la carte et son solde, ou essayez une autre carte.';

  @override
  String get cardErrExpiry => 'La date d’expiration n’est pas correcte.';

  @override
  String get cardErrNetwork =>
      'Passerelle de paiement injoignable. Vérifiez votre connexion et réessayez.';

  @override
  String get cardErrVerification =>
      'Votre banque n’a pas terminé la confirmation, rien n’a été débité. Réessayez.';

  @override
  String get cardErrExpired => 'Le paiement a expiré. Réessayez.';

  @override
  String get cardUsePaymentPage => 'Payer plutôt sur la page de la passerelle';

  @override
  String get cardNameLabel => 'Nom du titulaire';

  @override
  String get cardNameInvalid =>
      'Saisissez le nom tel qu’il figure sur la carte.';

  @override
  String get savedCardsTitle => 'Vos cartes enregistrées';

  @override
  String get useAnotherCard => 'Utiliser une autre carte';

  @override
  String get saveCardTitle => 'Enregistrer la carte sur ce téléphone';

  @override
  String get saveCardBody =>
      'Pour payer plus vite la prochaine fois. Elle reste chiffrée sur ce téléphone uniquement, s’ouvre avec Face ID ou votre code, et ne nous parvient jamais.';

  @override
  String get savedCardUnlockReason =>
      'Confirmez votre identité pour payer avec la carte enregistrée';

  @override
  String savedCardExpires(String expiry) {
    return 'Expire $expiry';
  }

  @override
  String get savedCardsSettings => 'Cartes enregistrées';

  @override
  String get savedCardsEmpty =>
      'Aucune carte enregistrée sur ce téléphone. Vous pouvez en enregistrer une en payant.';

  @override
  String get savedCardsNote =>
      'Les cartes restent sur ce téléphone uniquement, chiffrées et protégées par Face ID ou votre code. Elles ne parviennent jamais à nos serveurs et sont supprimées à la déconnexion.';

  @override
  String get removeCard => 'Retirer';

  @override
  String get removeCardTitle => 'Retirer cette carte ?';

  @override
  String get removeCardBody =>
      'Elle sera supprimée de ce téléphone. Vous pourrez l’enregistrer à nouveau en payant.';

  @override
  String get savedCardLocked =>
      'Votre identité n’a pas été confirmée, la carte enregistrée n’a pas été utilisée.';

  @override
  String get payNotFinishedTitle => 'Paiement non terminé';

  @override
  String get payNotFinishedBody =>
      'Rien n’a encore été débité. Terminez le paiement par carte, ou annulez la commande.';

  @override
  String get finishPaying => 'Terminer le paiement';

  @override
  String get orderCancelled => 'Commande annulée.';

  @override
  String get onboardingSkip => 'Passer';

  @override
  String get onboardingNext => 'Suivant';

  @override
  String get onboardingStart => 'Commencer';

  @override
  String onboardingStep(int current, int total) {
    return 'Étape $current sur $total';
  }

  @override
  String get onboardingShelfTitle => 'Toutes vos cartes au même endroit';

  @override
  String get onboardingShelfBody =>
      'Crédit Libyana et Almadar, forfaits internet et plus, choisis en quelques secondes à des prix clairs.';

  @override
  String get onboardingInstantTitle => 'Payez, le code arrive aussitôt';

  @override
  String get onboardingInstantBody =>
      'Payez avec votre portefeuille ou votre carte bancaire : le code de votre carte s\'affiche en quelques secondes.';

  @override
  String get onboardingVaultTitle => 'Vos cartes en sécurité';

  @override
  String get onboardingVaultBody =>
      'Chaque carte achetée reste dans Mes cartes, protégée par le verrou de votre téléphone, prête quand vous en avez besoin.';

  @override
  String get onboardingNotifyTitle => 'Les offres d\'abord pour vous';

  @override
  String get onboardingNotifyBody =>
      'Activez les notifications : nous vous signalons les offres et les nouvelles cartes dès leur arrivée.';

  @override
  String get onboardingNotifyAllow => 'Activer les notifications';

  @override
  String get onboardingNotifyLater => 'Plus tard';

  @override
  String get onboardingNotifyOnBody =>
      'Les notifications sont activées : nous vous signalons les offres et les nouvelles cartes dès leur arrivée.';

  @override
  String get onboardingReplay => 'Faire la visite';

  @override
  String get getAppBody =>
      'Plus rapide sur votre téléphone, vos cartes toujours avec vous';

  @override
  String get getAppAction => 'Obtenir';

  @override
  String get licensesIntro =>
      'Daftar Cartes repose sur des logiciels libres, avec nos remerciements à leurs auteurs. Voici leurs licences, telles que publiées.';

  @override
  String get searchTitle => 'Recherche';

  @override
  String get searchBrowseCategories => 'Parcourir les catégories';

  @override
  String get filterIncomplete => 'Inachevées';

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
  String get webOnlyBadge => 'Sur le site';

  @override
  String get webOnlyTitle => 'Disponible sur le site';

  @override
  String get webOnlyBody =>
      'Cette carte ne s\'achète pas dans cette app. Retrouvez-la sur cards.dftr.ly';

  @override
  String get steamBadge => 'Steam';

  @override
  String get xboxBadge => 'Xbox';

  @override
  String get eaBadge => 'EA';

  @override
  String get rockstarBadge => 'Rockstar';

  @override
  String get heardFromTitle => 'Où avez-vous entendu parler de Daftar Cards ?';

  @override
  String get heardFromBody =>
      'Choisissez une réponse : cela nous aide à toucher ceux qui en ont besoin.';

  @override
  String get heardFromFacebook => 'Facebook';

  @override
  String get heardFromInstagram => 'Instagram';

  @override
  String get heardFromTiktok => 'TikTok';

  @override
  String get heardFromWhatsapp => 'WhatsApp';

  @override
  String get heardFromFriend => 'Un ami ou un proche';

  @override
  String get heardFromShop => 'Un magasin';

  @override
  String get heardFromBillboard => 'Un panneau publicitaire';

  @override
  String get heardFromStoreSearch => 'Une recherche dans le store';

  @override
  String get heardFromOther => 'Autre';

  @override
  String get campaignCodeLabel => 'Un code reçu d’une pub ou d’un ami ?';

  @override
  String get campaignCodeHint => 'ex. UNI1';

  @override
  String get campaignCodeCheck => 'Vérifier';

  @override
  String get campaignCodeUnknown => 'Ce code est inconnu ou a expiré.';

  @override
  String get campaignCodeValid => 'Code accepté, merci.';

  @override
  String campaignCodeRewardLater(String amount) {
    return 'Code accepté : $amount sera ajouté à votre solde à la connexion.';
  }

  @override
  String campaignCodeRewardNow(String amount) {
    return 'Code accepté : $amount est ajouté à votre solde.';
  }

  @override
  String campaignLinkReward(String code, String amount) {
    return 'Vous êtes venu avec le code $code : $amount sera ajouté à votre solde à la connexion.';
  }

  @override
  String rewardTitle(String amount) {
    return '$amount ajouté à votre solde';
  }

  @override
  String rewardBecauseCode(String code) {
    return 'Parce que vous avez utilisé le code $code.';
  }

  @override
  String rewardBecauseCreator(String name) {
    return 'Parce que vous êtes venu via $name.';
  }

  @override
  String get rewardBecauseCreatorUnnamed =>
      'Parce que vous êtes venu via un créateur partenaire.';

  @override
  String rewardBecauseFlyer(String name) {
    return 'Parce que vous avez scanné le code $name.';
  }

  @override
  String get rewardBecauseFlyerUnnamed =>
      'Parce que vous avez scanné le code de l’affiche.';

  @override
  String get rewardBecauseBillboardUnnamed =>
      'Parce que vous avez scanné le code du panneau.';

  @override
  String rewardBecauseInvite(String name) {
    return 'Parce que $name vous a invité.';
  }

  @override
  String get rewardBecauseInviteUnnamed => 'Parce qu’un ami vous a invité.';

  @override
  String get rewardBecauseAd => 'Parce que vous êtes venu via notre publicité.';

  @override
  String get rewardBody =>
      'Il est déduit automatiquement du prix de votre prochaine carte, sans frais.';

  @override
  String get rewardAction => 'Acheter maintenant';

  @override
  String topUpPill(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Cadeau sur votre compte',
      'other': 'Recharge directe',
    });
    return '$_temp0';
  }

  @override
  String topUpAccountTitle(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'telegram': 'Compte Telegram',
      'steam': 'Compte Steam',
      'invite': 'Compte Steam',
      'other': 'Compte du joueur',
    });
    return '$_temp0';
  }

  @override
  String topUpAccountBody(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'telegram': 'Envoyé directement sur le compte, sans code à saisir.',
      'steam': 'Ajouté directement à votre portefeuille Steam.',
      'invite':
          'Le jeu arrive en cadeau sur votre compte Steam, sans code à saisir.',
      'other':
          'Envoyé directement sur votre compte de jeu, sans code à saisir.',
    });
    return '$_temp0';
  }

  @override
  String topUpHintTitle(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'telegram': 'Où trouver mon nom d’utilisateur ?',
      'steam': 'Quel est mon identifiant ?',
      'invite': 'Comment obtenir le lien ?',
      'other': 'Où trouver mon ID ?',
    });
    return '$_temp0';
  }

  @override
  String get chooseAmount => 'Choisissez un montant';

  @override
  String get savedAccounts => 'Vos comptes';

  @override
  String get otherAccount => 'Autre compte';

  @override
  String forgetAccount(String account) {
    return 'Oublier $account';
  }

  @override
  String get pasteAction => 'Coller';

  @override
  String get chooseOption => 'Choisir';

  @override
  String accountRequired(String field) {
    return 'Saisissez $field';
  }

  @override
  String accountChoose(String field) {
    return 'Choisissez $field';
  }

  @override
  String get accountTooLong => 'Trop long.';

  @override
  String get accountNotTelegram =>
      'Un nom d’utilisateur compte 5 à 32 lettres latines, chiffres ou _, et commence par une lettre.';

  @override
  String get accountNotSteamLogin =>
      'Un identifiant ne contient que des lettres latines, des chiffres et _, sans espace.';

  @override
  String get accountNotInvite =>
      'Ce n’est pas un lien d’invitation Steam. Copiez le lien « Invitation rapide » de Steam tel quel et collez-le ici.';

  @override
  String get accountChecking => 'Vérification du compte…';

  @override
  String accountPlayer(String name) {
    return 'Joueur : $name';
  }

  @override
  String accountFound(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'steam': 'Ce compte peut être rechargé',
      'other': 'Compte trouvé',
    });
    return '$_temp0';
  }

  @override
  String accountNotFound(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'steam':
          'Ce compte Steam ne peut pas être rechargé. Vérifiez l’identifiant.',
      'other':
          'Aucun compte n’a cet ID. Vérifiez-le sur votre profil dans le jeu.',
    });
    return '$_temp0';
  }

  @override
  String get accountUnconfirmed =>
      'Impossible de confirmer le compte pour l’instant. Vérifiez-le bien avant de payer.';

  @override
  String accountUnchecked(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Vérifiez le lien : le cadeau va à son propriétaire.',
      'telegram':
          'Vérifiez le nom d’utilisateur : l’envoi est direct et sans retour.',
      'other': 'Vérifiez l’ID : la recharge y va directement et sans retour.',
    });
    return '$_temp0';
  }

  @override
  String topUpAction(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Acheter',
      'telegram': 'Acheter',
      'other': 'Recharger',
    });
    return '$_temp0';
  }

  @override
  String buyBarTo(String account) {
    return 'Pour $account';
  }

  @override
  String buyBarNeedsAccount(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'telegram': 'Saisissez le nom d’utilisateur',
      'steam': 'Saisissez l’identifiant',
      'invite': 'Collez le lien d’invitation',
      'other': 'Saisissez l’ID',
    });
    return '$_temp0';
  }

  @override
  String get sendToLabel => 'Pour';

  @override
  String get editAction => 'Modifier';

  @override
  String topUpPreparingTitle(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Envoi de votre cadeau…',
      'telegram': 'Recharge du compte Telegram…',
      'steam': 'Ajout au portefeuille Steam…',
      'other': 'Recharge du compte du joueur…',
    });
    return '$_temp0';
  }

  @override
  String topUpPreparingBody(String kind, String item, String account) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Steam vous enverra une demande d’ami, puis le cadeau : acceptez les deux.',
      'other':
          'Envoi de $item à $account. Cela prend en général une à deux minutes.',
    });
    return '$_temp0';
  }

  @override
  String topUpSlowTitle(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Le cadeau prend plus de temps cette fois',
      'steam': 'L\'ajout prend plus de temps cette fois',
      'other': 'La recharge prend plus de temps cette fois',
    });
    return '$_temp0';
  }

  @override
  String topUpRefundedTitle(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Le cadeau n\'a pas été envoyé',
      'steam': 'Les fonds n\'ont pas été ajoutés',
      'other': 'La recharge n\'a pas abouti',
    });
    return '$_temp0';
  }

  @override
  String topUpRefundedBody(String kind, String amount) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite':
          'Le cadeau n\'a pas été envoyé : $amount reviennent sur votre crédit. Vérifiez le lien d\'invitation et réessayez.',
      'telegram':
          'La recharge n\'a pas atteint le compte Telegram : $amount reviennent sur votre crédit. Vérifiez le nom d\'utilisateur et réessayez.',
      'steam':
          'Les fonds n\'ont pas été ajoutés au portefeuille Steam : $amount reviennent sur votre crédit. Vérifiez le nom de connexion et réessayez.',
      'other':
          'La recharge n\'a pas atteint le compte du joueur : $amount reviennent sur votre crédit. Vérifiez l\'identifiant et réessayez.',
    });
    return '$_temp0';
  }

  @override
  String toppedUpTitle(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Cadeau envoyé',
      'other': 'Recharge effectuée',
    });
    return '$_temp0';
  }

  @override
  String get receiptTo => 'Pour';

  @override
  String get receiptPlayer => 'Joueur';

  @override
  String get receiptPaid => 'Montant';

  @override
  String get receiptWhen => 'Heure';

  @override
  String get receiptOrder => 'Numéro de commande';

  @override
  String get whatNextTitle => 'Et ensuite ?';

  @override
  String topUpNext(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'telegram':
          'Ouvrez Telegram : c’est sur votre compte en quelques minutes.',
      'steam': 'Ouvrez Steam : le solde apparaît dans votre portefeuille en quelques minutes.',
      'invite': 'Dans Steam : acceptez la demande d’ami reçue, puis le cadeau depuis vos notifications. Le cadeau arrive quelques minutes après.',
      'other': 'Ouvrez le jeu : le solde apparaît sur votre compte en quelques minutes. Sinon, fermez le jeu et rouvrez-le.',
    });
    return '$_temp0';
  }

  @override
  String topUpAgain(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Acheter un autre cadeau',
      'other': 'Recharger à nouveau',
    });
    return '$_temp0';
  }

  @override
  String get topUpHelp => 'Pas reçu ? Écrivez-nous sur WhatsApp';

  @override
  String topUpHelpMessage(String kind, String order) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Bonjour, commande $order : le cadeau n\'est pas arrivé.',
      'telegram':
          'Bonjour, la commande $order n\'a pas atteint le compte Telegram.',
      'steam':
          'Bonjour, la commande $order n\'a pas été ajoutée au portefeuille Steam.',
      'other':
          'Bonjour, la commande $order n\'a pas atteint le compte du joueur.',
    });
    return '$_temp0';
  }

  @override
  String get orderIdCopied => 'Numéro de commande copié';

  @override
  String statusToppedUp(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Cadeau envoyé',
      'other': 'Rechargé',
    });
    return '$_temp0';
  }

  @override
  String get statusToppingUp => 'Recharge en cours';

  @override
  String orderTo(String account) {
    return 'Pour $account';
  }

  @override
  String get removeAccount => 'Retirer';

  @override
  String accountRemoved(String account) {
    return '$account retiré de ce téléphone';
  }

  @override
  String get undoAction => 'Annuler';

  @override
  String get chooseEdition => 'Choisissez une édition';

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
  String get orderStatusHeading => 'État de la commande';

  @override
  String get orderDetailsHeading => 'Détails';

  @override
  String get orderStepPlaced => 'Commandé';

  @override
  String get orderStepPaid => 'Payé';

  @override
  String orderStepSending(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Envoi du cadeau',
      'telegram': 'Envoi vers le compte Telegram',
      'steam': 'Ajout au portefeuille Steam',
      'other': 'Envoi vers le compte du joueur',
    });
    return '$_temp0';
  }

  @override
  String get orderStepRefunded => 'Remboursé sur votre crédit';

  @override
  String get reportProblem => 'Signaler un problème';

  @override
  String get reportAgain => 'Signaler un autre problème';

  @override
  String get reportTitle => 'Quel est le problème ?';

  @override
  String get reportBody =>
      'Dites-nous ce qui s\'est passé. Nous vérifions votre commande et répondons ici et par notification.';

  @override
  String reportNotArrived(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Le cadeau n\'est pas arrivé',
      'steam': 'Les fonds n\'ont pas été ajoutés',
      'other': 'Rien n\'est arrivé',
    });
    return '$_temp0';
  }

  @override
  String reportWrongAccount(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Le cadeau est allé à un autre compte',
      'telegram': 'Envoyé à un autre nom d\'utilisateur',
      'steam': 'Ajouté à un autre compte Steam',
      'other': 'Envoyé à un autre identifiant de joueur',
    });
    return '$_temp0';
  }

  @override
  String reportWrongAmount(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Un autre jeu ou une autre édition est arrivé',
      'other': 'La quantité est incorrecte',
    });
    return '$_temp0';
  }

  @override
  String get reportOther => 'Autre chose';

  @override
  String get reportNote => 'Des détails pour nous aider (facultatif)';

  @override
  String reportNoteHint(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'invite': 'Par exemple : aucune demande d\'ami reçue',
      'steam': 'Par exemple : seule une partie des fonds est arrivée',
      'other': 'Par exemple : seule une partie est arrivée',
    });
    return '$_temp0';
  }

  @override
  String get reportSend => 'Envoyer le signalement';

  @override
  String get reportSent => 'Signalement reçu. Nous vérifions et répondons.';

  @override
  String get reportOpenTitle => 'Nous examinons votre signalement';

  @override
  String reportOpenBody(String reason) {
    return 'Vous avez signalé : $reason. Nous répondrons ici et par notification.';
  }

  @override
  String get reportReplyTitle => 'Notre réponse à votre signalement';

  @override
  String get reportResolvedBody =>
      'Nous avons examiné votre signalement sur cette commande.';

  @override
  String get reportWhatsApp => 'Ou écrivez-nous sur WhatsApp';
}
