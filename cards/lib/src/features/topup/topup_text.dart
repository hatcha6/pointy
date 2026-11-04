import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/models/account_target.dart';

/// The word the strings' `kind` choices are keyed by: a game's player ID
/// when the kind is unknown (an order whose brand left the shelf).
String kindKey(TargetKind? kind) => switch (kind) {
  TargetKind.telegram => 'telegram',
  TargetKind.steamLogin => 'steam',
  TargetKind.steamInvite => 'invite',
  TargetKind.gameAccount || null => 'game',
};

/// [text] kept left to right inside an Arabic sentence: «إلى 5123 · 1001»
/// would otherwise read «إلى 1001 · 5123».
String isolated(String text) => '\u2066$text\u2069';

/// [text] in its own direction inside a sentence: «520 جوهرة» stays as it
/// is, «Genesis Crystals» reads left to right.
String isolatedName(String text) => '\u2068$text\u2069';

/// An account as it is shown: a Steam invite link by its friend code alone
/// («s.team/p/gkcp-mvn»), since the rest is what lets anyone befriend it.
String accountShown(String line) => line.replaceAllMapped(
  RegExp(
    r'(?:https?://)?s\.team/p/([^/\s·]+)(?:/[^\s·]*)?',
    caseSensitive: false,
  ),
  (m) => 's.team/p/${m.group(1)!.toLowerCase()}',
);

/// The mark of each kind of account.
IconData kindIcon(TargetKind? kind) => switch (kind) {
  TargetKind.telegram => Icons.send_rounded,
  TargetKind.steamLogin => Icons.account_balance_wallet_rounded,
  TargetKind.steamInvite => Icons.card_giftcard_rounded,
  TargetKind.gameAccount || null => Icons.sports_esports_rounded,
};

String problemText(
  AppLocalizations l10n,
  TargetField field,
  AccountProblem problem,
) => switch (problem) {
  AccountProblem.required => l10n.accountRequired(field.label),
  AccountProblem.notAChoice => l10n.accountChoose(field.label),
  AccountProblem.tooLong => l10n.accountTooLong,
  AccountProblem.notTelegram => l10n.accountNotTelegram,
  AccountProblem.notSteamLogin => l10n.accountNotSteamLogin,
  AccountProblem.notInvite => l10n.accountNotInvite,
};
