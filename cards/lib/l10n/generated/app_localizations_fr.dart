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
  String get chooseCountry => 'Pays';

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
  String get hostedTitle => 'Terminez le paiement sur la page de la carte';

  @override
  String get hostedBody =>
      'Nous avons ouvert la page de paiement sécurisée. Une fois payé, revenez ici : votre carte apparaîtra d\'elle-même.';

  @override
  String get openPaymentPage => 'Ouvrir la page de paiement';

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
      'other': 'Recharge du compte…',
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
  String get topUpSlowTitle => 'La recharge prend plus de temps cette fois';

  @override
  String get topUpRefundedTitle => 'La recharge n’a pas abouti';

  @override
  String topUpRefundedBody(String amount) {
    return 'La recharge n’a pas atteint le compte : $amount a été remis sur votre solde. Vérifiez le compte et réessayez.';
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
  String topUpHelpMessage(String order) {
    return 'Bonjour, la commande $order n’est pas arrivée sur le compte.';
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
}
