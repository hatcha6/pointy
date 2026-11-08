/// A card that is not a code but credit sent straight to an account: a game
/// topped up by its player ID, Telegram Stars sent to a username, a Steam wallet
/// topped up by its login, a Steam game sent as a gift through a friend invite.
/// The brand's target says what the cashier asks for; the server and the relay
/// read it again the same way before anything is bought.
library;

enum VoucherTargetKind {
  gameAccount,
  telegram,
  steamLogin,
  steamInvite;

  static VoucherTargetKind? parse(Object? raw) => switch (raw) {
    'game_account' => gameAccount,
    'telegram_username' => telegram,
    'steam_login' => steamLogin,
    'steam_invite' => steamInvite,
    _ => null,
  };

  /// The word the till's `kind` strings choose by, as the cards app does: what
  /// the cashier checks is a username, a login or a link, not always an ID.
  String get textKey => switch (this) {
    telegram => 'telegram',
    steamLogin => 'steam',
    steamInvite => 'invite',
    gameAccount => 'game',
  };
}

class VoucherTarget {
  const VoucherTarget({
    required this.kind,
    required this.fields,
    this.check = '',
    this.hint = '',
  });

  /// Null for a kind this build cannot ask for: the brand then cannot be sold
  /// here, rather than being sold without its account.
  static VoucherTarget? fromJson(Map<String, Object?> json) {
    final kind = VoucherTargetKind.parse(json['kind']);
    final raw = json['fields'];
    final fields = [
      for (final field in raw is List ? raw : const <Object?>[])
        if (field is Map<String, Object?>) VoucherTargetField.fromJson(field),
    ];
    if (kind == null || fields.isEmpty) {
      return null;
    }
    return VoucherTarget(
      kind: kind,
      fields: fields,
      check: json['check']?.toString() ?? '',
      hint: json['hint']?.toString() ?? '',
    );
  }

  final VoucherTargetKind kind;
  final List<VoucherTargetField> fields;

  /// The game's look-up ("pubg_mobile"); empty when there is none.
  final String check;

  /// Where the customer finds what they give, in Arabic.
  final String hint;

  /// Whether the account can be looked up before the sale.
  bool get checkable =>
      check.isNotEmpty || kind == VoucherTargetKind.steamLogin;

  /// A Steam invite link is used once, so it is never kept in the book.
  bool get remembers => kind != VoucherTargetKind.steamInvite;

  /// The account on one line, as the server writes it ("5123 · 1001", "@name").
  String line(Map<String, String> account) => [
    for (final field in fields)
      if ((account[field.key] ?? '').isNotEmpty)
        kind == VoucherTargetKind.telegram
            ? '@${account[field.key]}'
            : account[field.key]!,
  ].join(' · ');

  /// [value] as typed into [field], read the way the server will: Arabic digits
  /// and spaces gone from an ID, a username's @ and t.me/ dropped, an invite
  /// link cut out of whatever was pasted round it.
  String clean(VoucherTargetField field, String value) {
    var text = asciiDigits(value).trim();
    if (field.isSelect) {
      return text;
    }
    switch (kind) {
      case VoucherTargetKind.telegram:
        final link = _telegramLink.firstMatch(text);
        if (link != null) {
          text = link.group(1)!;
        }
        return text.replaceFirst(RegExp(r'^@+'), '');
      case VoucherTargetKind.steamInvite:
        final link = _steamInvite.firstMatch(text);
        if (link == null) {
          return text;
        }
        final token = link.group(2);
        return 'https://s.team/p/${link.group(1)!.toLowerCase()}'
            '${token == null ? '' : '/$token'}';
      case VoucherTargetKind.steamLogin || VoucherTargetKind.gameAccount:
        return text.replaceAll(RegExp(r'\s+'), '');
    }
  }

  /// What is wrong with a cleaned [value]; null when the server will take it.
  VoucherAccountProblem? problemWith(VoucherTargetField field, String value) {
    if (value.isEmpty) {
      return VoucherAccountProblem.required;
    }
    if (value.runes.length > maxValueLength) {
      return VoucherAccountProblem.tooLong;
    }
    if (field.isSelect) {
      return field.options.any((option) => option.value == value)
          ? null
          : VoucherAccountProblem.notAChoice;
    }
    return switch (kind) {
      VoucherTargetKind.telegram when !_telegram.hasMatch(value) =>
        VoucherAccountProblem.notTelegram,
      VoucherTargetKind.steamLogin when !_steamLogin.hasMatch(value) =>
        VoucherAccountProblem.notSteamLogin,
      VoucherTargetKind.steamInvite when !_steamInviteWhole.hasMatch(value) =>
        VoucherAccountProblem.notInvite,
      _ => null,
    };
  }

  static const maxValueLength = 64;

  // The server's own shapes (apps/integrations/voucher_accounts.py).
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

/// 0–9 for Arabic-Indic and Persian digits, which a phone keyboard types.
String asciiDigits(String value) {
  final out = StringBuffer();
  for (final rune in value.runes) {
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

class VoucherTargetField {
  const VoucherTargetField({
    required this.key,
    required this.label,
    this.options = const [],
  });

  factory VoucherTargetField.fromJson(Map<String, Object?> json) {
    final raw = json['options'];
    return VoucherTargetField(
      key: json['key']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      options: json['type'] == 'select'
          ? [
              for (final option in raw is List ? raw : const <Object?>[])
                if (option is Map)
                  VoucherTargetOption(
                    value: option['value']?.toString() ?? '',
                    label: option['label']?.toString() ?? '',
                  ),
            ]
          : const [],
    );
  }

  final String key;
  final String label;
  final List<VoucherTargetOption> options;

  bool get isSelect => options.isNotEmpty;
}

class VoucherTargetOption {
  const VoucherTargetOption({required this.value, required this.label});

  final String value;
  final String label;
}

enum VoucherAccountProblem {
  required,
  tooLong,
  notAChoice,
  notTelegram,
  notSteamLogin,
  notInvite,
}

enum VoucherAccountStatus {
  /// Found: the top-up lands there.
  valid,

  /// The game has no such account.
  invalid,

  /// The game was asked and could not say.
  unconfirmed,

  /// There is no way to look this account up.
  unchecked,
}

/// What the look-up found.
class VoucherAccountCheck {
  const VoucherAccountCheck({
    required this.status,
    this.name = '',
    this.detail = '',
  });

  factory VoucherAccountCheck.fromJson(Map<String, Object?> json) {
    if (json['ok'] != true) {
      // The server read what was typed and refused it; any other refusal says
      // nothing about the account.
      return VoucherAccountCheck(
        status: json['error_code'] == 'invalid_account'
            ? VoucherAccountStatus.invalid
            : VoucherAccountStatus.unconfirmed,
        detail: json['detail']?.toString() ?? '',
      );
    }
    return VoucherAccountCheck(
      status: switch (json['status']) {
        'valid' => VoucherAccountStatus.valid,
        'invalid' => VoucherAccountStatus.invalid,
        'unchecked' => VoucherAccountStatus.unchecked,
        _ => VoucherAccountStatus.unconfirmed,
      },
      name: json['name']?.toString() ?? '',
    );
  }

  final VoucherAccountStatus status;

  /// The player's own name, when the game gives it.
  final String name;

  /// The server's own Arabic words for a refusal.
  final String detail;
}

/// One account in the shop's book: shared by every till, written by the sale.
class SavedVoucherAccount {
  const SavedVoucherAccount({
    required this.id,
    required this.ref,
    required this.values,
    this.playerName = '',
    this.label = '',
    this.customerId,
    this.customerName = '',
    this.useCount = 1,
    this.lastUsedAt,
  });

  factory SavedVoucherAccount.fromJson(Map<String, Object?> json) {
    final raw = json['values'];
    return SavedVoucherAccount(
      id: int.tryParse(json['id']?.toString() ?? '') ?? 0,
      ref: json['ref']?.toString() ?? '',
      values: raw is Map
          ? {
              for (final entry in raw.entries)
                entry.key.toString(): entry.value.toString(),
            }
          : const {},
      playerName: json['player_name']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      customerId: int.tryParse(json['customer']?.toString() ?? ''),
      customerName: json['customer_name']?.toString() ?? '',
      useCount: int.tryParse(json['use_count']?.toString() ?? '') ?? 1,
      lastUsedAt: DateTime.tryParse(
        json['last_used_at']?.toString() ?? '',
      )?.toLocal(),
    );
  }

  final int id;

  /// The account on one line, as the sale wrote it.
  final String ref;
  final Map<String, String> values;
  final String playerName;

  /// What the shop calls them, typed at the till.
  final String label;
  final int? customerId;
  final String customerName;
  final int useCount;
  final DateTime? lastUsedAt;

  /// Who to show first: the shop's own word, then the customer, then the game's.
  String get title => label.isNotEmpty
      ? label
      : customerName.isNotEmpty
      ? customerName
      : playerName;

  SavedVoucherAccount named(String newLabel) => SavedVoucherAccount(
    id: id,
    ref: ref,
    values: values,
    playerName: playerName,
    label: newLabel,
    customerId: customerId,
    customerName: customerName,
    useCount: useCount,
    lastUsedAt: lastUsedAt,
  );
}

class SavedVoucherAccountPage {
  const SavedVoucherAccountPage({
    this.accounts = const [],
    this.hasMore = false,
  });

  factory SavedVoucherAccountPage.fromJson(Map<String, Object?> json) {
    final raw = json['results'];
    return SavedVoucherAccountPage(
      accounts: [
        for (final row in raw is List ? raw : const <Object?>[])
          if (row is Map<String, Object?>) SavedVoucherAccount.fromJson(row),
      ],
      hasMore: json['has_more'] == true,
    );
  }

  final List<SavedVoucherAccount> accounts;

  /// More match than one page: typing narrows them.
  final bool hasMore;
}
