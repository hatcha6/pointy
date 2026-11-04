import 'json.dart';

/// A card that is not a code but credit sent straight to an account: a game
/// topped up by its player ID, Telegram Stars sent to a username, a Steam
/// wallet topped up by its login, a Steam game sent as a gift through a
/// friend invite link. The brand's target says what the buyer types; the
/// relay reads it again the same way (vouchers/target.go) before it orders.
enum TargetKind {
  gameAccount,
  telegram,
  steamLogin,
  steamInvite;

  static TargetKind? parse(String raw) => switch (raw) {
    'game_account' => gameAccount,
    'telegram_username' => telegram,
    'steam_login' => steamLogin,
    'steam_invite' => steamInvite,
    _ => null,
  };
}

/// What a brand's buyer types for the credit to be sent to.
class AccountTarget {
  const AccountTarget({
    required this.kind,
    required this.fields,
    this.check = '',
    this.hint = '',
  });

  /// Null for a kind this build does not know: the brand is then left off
  /// the shelf rather than sold without asking for its account.
  static AccountTarget? fromJson(Map<String, dynamic> json) {
    final kind = TargetKind.parse(readString(json, 'kind'));
    final fields = [
      for (final f in readList(json, 'fields')) TargetField.fromJson(f),
    ];
    if (kind == null || fields.isEmpty) {
      return null;
    }
    return AccountTarget(
      kind: kind,
      fields: fields,
      check: readString(json, 'check'),
      hint: readString(json, 'hint'),
    );
  }

  final TargetKind kind;
  final List<TargetField> fields;

  /// The supplier's look-up for this game ("pubg_mobile"), empty when the
  /// account cannot be looked up before paying.
  final String check;

  /// Where the buyer finds what they type, in Arabic.
  final String hint;

  /// Whether the relay can look the account up before the order: a game
  /// with a check names the player; a Steam login says it can be topped up.
  bool get checkable => check.isNotEmpty || kind == TargetKind.steamLogin;

  /// The account on one line, in field order ("5123456789 · 1001",
  /// "@name"), the way the relay writes it on the order.
  String line(Map<String, String> account) => [
    for (final field in fields)
      if ((account[field.key] ?? '').isNotEmpty)
        kind == TargetKind.telegram
            ? '@${account[field.key]}'
            : field.isSelect
            ? field.optionLabel(account[field.key]!)
            : account[field.key]!,
  ].join(' · ');

  /// [value] as typed into [field], tidied the way the relay will read it:
  /// spaces and the phone's Arabic digits gone from an ID, a username's @
  /// and t.me/ dropped, an invite link cut out of whatever was pasted round
  /// it.
  String clean(TargetField field, String value) {
    var text = asciiDigits(value).trim();
    if (field.isSelect) {
      return text;
    }
    switch (kind) {
      case TargetKind.telegram:
        final link = _telegramLink.firstMatch(text);
        if (link != null) {
          text = link.group(1)!;
        }
        return text.replaceFirst(RegExp(r'^@+'), '');
      case TargetKind.steamInvite:
        final link = _steamInvite.firstMatch(text);
        if (link == null) {
          return text;
        }
        final token = link.group(2);
        return 'https://s.team/p/${link.group(1)!.toLowerCase()}'
            '${token == null ? '' : '/$token'}';
      case TargetKind.steamLogin || TargetKind.gameAccount:
        return text.replaceAll(RegExp(r'\s+'), '');
    }
  }

  /// What is wrong with [value] for [field], once cleaned; null when it
  /// reads as the relay will take it.
  AccountProblem? problemWith(TargetField field, String value) {
    if (value.isEmpty) {
      return AccountProblem.required;
    }
    if (value.runes.length > maxValueLength) {
      return AccountProblem.tooLong;
    }
    if (field.isSelect) {
      return field.options.any((o) => o.value == value)
          ? null
          : AccountProblem.notAChoice;
    }
    return switch (kind) {
      TargetKind.telegram when !_telegram.hasMatch(value) =>
        AccountProblem.notTelegram,
      TargetKind.steamLogin when !_steamLogin.hasMatch(value) =>
        AccountProblem.notSteamLogin,
      TargetKind.steamInvite when !_steamInviteWhole.hasMatch(value) =>
        AccountProblem.notInvite,
      _ => null,
    };
  }

  static const maxValueLength = 64;

  // The relay's own shapes (vouchers/target.go).
  static final _telegram = RegExp(r'^[A-Za-z][A-Za-z0-9_]{3,31}$');
  static final _telegramLink = RegExp(
    r'(?:https?://)?(?:t\.me|telegram\.me)/([A-Za-z0-9_]+)',
    caseSensitive: false,
  );
  static final _steamLogin = RegExp(r'^[A-Za-z0-9_]{2,64}$');
  static const _invite =
      r's\.team/p/([a-z0-9]{2,16}(?:-[a-z0-9]{2,16})*)(?:/([a-z0-9]{2,32}))?';
  static final _steamInvite = RegExp(_invite, caseSensitive: false);
  static final _steamInviteWhole = RegExp(
    '^(?:https?://)?$_invite/?\$',
    caseSensitive: false,
  );
}

/// One thing the buyer types: a player ID, a server picked from a list.
class TargetField {
  const TargetField({
    required this.key,
    required this.label,
    this.options = const [],
  });

  factory TargetField.fromJson(Map<String, dynamic> json) => TargetField(
    key: readString(json, 'key'),
    label: readString(json, 'label'),
    options: readString(json, 'type') == 'select'
        ? [for (final o in readList(json, 'options')) TargetOption.fromJson(o)]
        : const [],
  );

  final String key;
  final String label;

  /// A select field's choices; empty for one that is typed.
  final List<TargetOption> options;

  bool get isSelect => options.isNotEmpty;

  String optionLabel(String value) =>
      options.where((o) => o.value == value).firstOrNull?.label ?? value;
}

class TargetOption {
  const TargetOption({required this.value, required this.label});

  factory TargetOption.fromJson(Map<String, dynamic> json) => TargetOption(
    value: readString(json, 'value'),
    label: readString(json, 'label'),
  );

  final String value;
  final String label;
}

/// Why a field cannot be sent as it is.
enum AccountProblem {
  required,
  tooLong,
  notAChoice,
  notTelegram,
  notSteamLogin,
  notInvite,
}

/// What the relay's look-up found (`POST /v1/customers/accounts/check`).
class AccountCheck {
  const AccountCheck({required this.status, this.name = '', this.region = ''});

  factory AccountCheck.fromJson(Map<String, dynamic> json) => AccountCheck(
    status: AccountStatus.parse(readString(json, 'status')),
    name: readString(json, 'name'),
    region: readString(json, 'region'),
  );

  final AccountStatus status;

  /// The player's own nickname, when the game gives it.
  final String name;
  final String region;
}

enum AccountStatus {
  /// Found: the top-up will land there.
  valid,

  /// The game has no such account.
  invalid,

  /// The game was asked and could not say.
  unconfirmed,

  /// There is no way to look this account up.
  unchecked;

  static AccountStatus parse(String raw) => switch (raw) {
    'valid' => valid,
    'invalid' => invalid,
    'unconfirmed' => unconfirmed,
    _ => unchecked,
  };
}

/// [text] with Arabic-Indic and Persian digits read as 0–9: an Arabic
/// keyboard types «٥١٢٣», and a game's ID is «5123».
String asciiDigits(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    if (rune >= 0x0660 && rune <= 0x0669) {
      out.writeCharCode(0x30 + rune - 0x0660);
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      out.writeCharCode(0x30 + rune - 0x06F0);
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}
