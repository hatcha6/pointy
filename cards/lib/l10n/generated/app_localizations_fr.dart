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
  String get rechargeNow => 'Recharger';

  @override
  String get showQr => 'Code QR';

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
}
