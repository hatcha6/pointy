/// Client mirror of `apps.integrations` — the outside services a shop resells.
///
/// The backend hands over the *whole* catalog, configured or not, so the
/// settings screen can list "HD Box works, LNET is coming" without knowing
/// anything about either. Provider keys, availability, blocked reasons and
/// capability names are stable API contract; all Arabic wording lives in the
/// Flutter layer, the same arrangement the treasury component codes use.
///
/// Credentials are one-way: the server never returns a stored password, only
/// [IntegrationAccount.hasPassword], and [IntegrationCredentialsDraft] carries
/// a new one when the owner types it.
library;

enum IntegrationProviderKey { hdbox, lnet, qareeb, unknown }

IntegrationProviderKey integrationProviderKeyFromJson(Object? value) {
  return switch (value?.toString()) {
    'hdbox' => IntegrationProviderKey.hdbox,
    'lnet' => IntegrationProviderKey.lnet,
    'qareeb' => IntegrationProviderKey.qareeb,
    _ => IntegrationProviderKey.unknown,
  };
}

String integrationProviderKeyToJson(IntegrationProviderKey key) {
  return switch (key) {
    IntegrationProviderKey.hdbox => 'hdbox',
    IntegrationProviderKey.lnet => 'lnet',
    IntegrationProviderKey.qareeb => 'qareeb',
    IntegrationProviderKey.unknown => '',
  };
}

enum IntegrationAvailability {
  /// A driver exists; credentials can be entered and will be used.
  available,

  /// Listed so the owner can see it is coming; not configurable yet.
  planned,
  unknown,
}

IntegrationAvailability integrationAvailabilityFromJson(Object? value) {
  return switch (value?.toString()) {
    'available' => IntegrationAvailability.available,
    'planned' => IntegrationAvailability.planned,
    _ => IntegrationAvailability.unknown,
  };
}

/// How a provider's portal can be asked to find a subscriber.
///
/// Stable codes, matching ``apps.integrations.providers.lnet``. A phone
/// number and a contract number are both digits, so nothing on the server
/// can tell them apart: it either guesses and pays a round trip per wrong
/// guess, or the person holding the number says which it is. The till asks.
///
/// The pick ORDERS the search, it does not fence it — a cashier who leaves
/// the picker on the wrong entry waits a moment longer and still finds the
/// customer.
enum IntegrationSearchMode { phone, username, contract }

String integrationSearchModeToJson(IntegrationSearchMode mode) {
  return switch (mode) {
    IntegrationSearchMode.phone => 'mobile',
    IntegrationSearchMode.username => 'username',
    IntegrationSearchMode.contract => 'contract_number',
  };
}

/// Which searches this provider offers, best first — empty where there is
/// only one way to look and therefore no choice worth putting on screen.
///
/// Lives here rather than arriving from the server because the picker is on
/// screen BEFORE the first lookup, and because it is the same kind of
/// per-provider knowledge `integrationSubscriberPrompt` already keeps client
/// side. The codes are the contract; the Arabic is in
/// `integration_presentation.dart`.
List<IntegrationSearchMode> integrationSearchModes(IntegrationProviderKey key) {
  return switch (key) {
    IntegrationProviderKey.lnet => const [
      IntegrationSearchMode.phone,
      IntegrationSearchMode.username,
      IntegrationSearchMode.contract,
    ],
    // HD Box knows a subscriber by the number printed on their card, and
    // nothing else. A picker with one row is worse than no picker.
    _ => const [],
  };
}

/// Why a planned provider is not ready. Stable codes; the page phrases them.
abstract final class IntegrationBlockedReason {
  static const portalUnreachable = 'portal_unreachable';
  static const awaitingAccess = 'awaiting_access';
  static const driverInProgress = 'driver_in_progress';
}

/// What a provider can do, once it works.
abstract final class IntegrationCapability {
  static const balance = 'balance';
  static const lookup = 'lookup';
  static const recharge = 'recharge';
}

/// Credential field keys. The form renders whatever the backend lists.
/// Stable keys for the settings a provider may declare. Mirrors
/// `catalog.SETTING_*`; never renamed, only added to.
abstract final class IntegrationSettingKey {
  static const commissionPercent = 'commission_percent';
  static const denominations = 'denominations';

  /// Warn when the prepaid float drops to this much or less. Declared by
  /// every provider that can report a balance, so "where do I set this?" has
  /// one answer for all of them. Zero means the owner asked not to be told.
  static const lowBalanceThreshold = 'low_balance_threshold';
}

abstract final class IntegrationField {
  static const baseUrl = 'base_url';
  static const username = 'username';
  static const password = 'password';
}

/// Why the last attempt failed. Stable codes; the page phrases them.
abstract final class IntegrationErrorCode {
  static const notConfigured = 'not_configured';
  static const unavailable = 'unavailable';
  static const unreachable = 'unreachable';
  static const unauthorized = 'unauthorized';
  static const notFound = 'not_found';
  static const providerError = 'provider_error';
  static const insufficientFloat = 'insufficient_float';
  static const indeterminate = 'indeterminate';
  static const unexpected = 'unexpected_response';
}

double? _toDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

DateTime? _toDate(Object? value) {
  final raw = value?.toString();
  if (raw == null || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toLocal();
}

class IntegrationAccount {
  const IntegrationAccount({
    required this.provider,
    this.baseUrl = '',
    this.username = '',
    this.hasPassword = false,
    this.isConfigured = false,
    this.isActive = true,
    this.balance,
    this.balanceAt,
    this.accountLabel = '',
    this.lastCheckedAt,
    this.lastConnectedAt,
    this.lastError = '',
    this.lastErrorCode = '',
    this.lastErrorAt,
  });

  final IntegrationProviderKey provider;
  final String baseUrl;
  final String username;

  /// A password is stored. Never the password itself.
  final bool hasPassword;

  /// Every required credential is present — not a claim that it still works.
  final bool isConfigured;
  final bool isActive;

  /// The agency's prepaid float, in LYD. HD Box's own screen prints a "$"
  /// glyph on this number and it is not dollars.
  final double? balance;
  final DateTime? balanceAt;

  /// What the provider calls this account.
  final String accountLabel;

  final DateTime? lastCheckedAt;
  final DateTime? lastConnectedAt;
  final String lastError;
  final String lastErrorCode;
  final DateTime? lastErrorAt;

  bool get hasFailed => lastErrorCode.isNotEmpty;

  factory IntegrationAccount.fromJson(Map<String, Object?> json) {
    return IntegrationAccount(
      provider: integrationProviderKeyFromJson(json['provider']),
      baseUrl: json['base_url']?.toString() ?? '',
      username: json['username']?.toString() ?? '',
      hasPassword: json['has_password'] == true,
      isConfigured: json['is_configured'] == true,
      isActive: json['is_active'] != false,
      balance: _toDouble(json['balance']),
      balanceAt: _toDate(json['balance_at']),
      accountLabel: json['account_label']?.toString() ?? '',
      lastCheckedAt: _toDate(json['last_checked_at']),
      lastConnectedAt: _toDate(json['last_connected_at']),
      lastError: json['last_error']?.toString() ?? '',
      lastErrorCode: json['last_error_code']?.toString() ?? '',
      lastErrorAt: _toDate(json['last_error_at']),
    );
  }
}

/// One owner-editable setting a provider declares.
///
/// Deliberately owner-facing: LNET's commission is a *percentage*, because a
/// shop knows it is "on 5%" and not that its cost ratio is 0.95. The server
/// does the arithmetic; nobody here converts anything.
class IntegrationSetting {
  const IntegrationSetting({
    required this.key,
    required this.kind,
    this.value,
    this.defaultValue,
    this.minimum,
    this.maximum,
  });

  final String key;

  /// `percent`, `amount` or `amount_list`. Stable codes; the Arabic label is
  /// chosen in the presentation layer like every other provider string.
  final String kind;

  /// What it is set to now — the default when nobody has chosen.
  final Object? value;
  final Object? defaultValue;
  final double? minimum;
  final double? maximum;

  bool get isPercent => kind == 'percent';
  bool get isAmountList => kind == 'amount_list';

  /// One money figure, in the provider's own currency. Bounded like a
  /// percentage but never rendered as one — and, unlike a percentage, its
  /// upper bound is a typo guard rather than a real ceiling, so the form must
  /// read the declared bounds instead of assuming 0–100.
  bool get isAmount => kind == 'amount';

  /// The current value as text a form field can hold.
  String get asText {
    final current = value ?? defaultValue;
    if (current == null) return '';
    if (current is List) return current.map((e) => e.toString()).join('، ');
    return current.toString();
  }

  factory IntegrationSetting.fromJson(Map<String, Object?> json) {
    return IntegrationSetting(
      key: json['key']?.toString() ?? '',
      kind: json['kind']?.toString() ?? '',
      value: json['value'],
      defaultValue: json['default'],
      minimum: double.tryParse(json['minimum']?.toString() ?? ''),
      maximum: double.tryParse(json['maximum']?.toString() ?? ''),
    );
  }
}

class IntegrationProvider {
  const IntegrationProvider({
    required this.key,
    required this.availability,
    this.blockedReason = '',
    this.capabilities = const [],
    this.fields = const [],
    this.secretFields = const [],
    this.settings = const [],
    this.currency = 'LYD',
    this.defaultBaseUrl = '',
    this.isConfigurable = false,
    this.account,
  });

  final IntegrationProviderKey key;
  final IntegrationAvailability availability;
  final String blockedReason;
  final List<String> capabilities;

  /// Credential fields to render, in order.
  final List<String> fields;

  /// Which of [fields] are write-only secrets.
  final List<String> secretFields;

  /// Knobs that are not credentials: the shop's own commercial terms, each
  /// with a working default. Rendered from this list rather than hand-written,
  /// so a provider's settings need no Flutter release — the same bargain
  /// [fields] already makes.
  final List<IntegrationSetting> settings;
  final String currency;
  final String defaultBaseUrl;

  /// Availability *and* a registered driver. The only flag the UI should gate
  /// the credentials form on.
  final bool isConfigurable;
  final IntegrationAccount? account;

  bool get isConnected =>
      account?.isConfigured == true && !(account?.hasFailed ?? true);
  bool get isConfigured => account?.isConfigured == true;

  static List<String> _strings(Object? value) =>
      (value as List<Object?>? ?? const [])
          .map((item) => item.toString())
          .toList(growable: false);

  factory IntegrationProvider.fromJson(Map<String, Object?> json) {
    final account = json['account'];
    return IntegrationProvider(
      key: integrationProviderKeyFromJson(json['key']),
      availability: integrationAvailabilityFromJson(json['availability']),
      blockedReason: json['blocked_reason']?.toString() ?? '',
      capabilities: _strings(json['capabilities']),
      fields: _strings(json['fields']),
      settings: (json['settings'] as List<Object?>? ?? const [])
          .whereType<Map<String, Object?>>()
          .map(IntegrationSetting.fromJson)
          .toList(growable: false),
      secretFields: _strings(json['secret_fields']),
      currency: json['currency']?.toString() ?? 'LYD',
      defaultBaseUrl: json['default_base_url']?.toString() ?? '',
      isConfigurable: json['is_configurable'] == true,
      account: account is Map<String, Object?>
          ? IntegrationAccount.fromJson(account)
          : null,
    );
  }
}

/// What the credentials form sends. A null/blank [password] means "keep the
/// stored one" — the form never received it, so it cannot resend it.
class IntegrationCredentialsDraft {
  const IntegrationCredentialsDraft({
    this.baseUrl,
    this.username,
    this.password,
    this.isActive,
    this.settings,
  });

  final String? baseUrl;
  final String? username;
  final String? password;
  final bool? isActive;

  /// Declared settings the owner changed. Absent keys keep what is stored, so
  /// saving a URL never resets a commission somebody set months ago.
  final Map<String, Object?>? settings;

  Map<String, Object?> toJson() => {
    if (settings != null && settings!.isNotEmpty) 'settings': settings,
    if (baseUrl != null) 'base_url': baseUrl,
    if (username != null) 'username': username,
    if (password != null && password!.isNotEmpty) 'password': password,
    if (isActive != null) 'is_active': isActive,
  };
}

/// Outcome of "test this connection now". A provider saying no is a fact to
/// render, not a failed request, so [ok] can be false on a perfectly good call.
class IntegrationProbeResult {
  const IntegrationProbeResult({
    required this.ok,
    required this.provider,
    this.errorCode = '',
    this.errorDetail = '',
  });

  final bool ok;
  final String errorCode;
  final String errorDetail;
  final IntegrationProvider? provider;

  factory IntegrationProbeResult.fromJson(Map<String, Object?> json) {
    final provider = json['provider'];
    return IntegrationProbeResult(
      ok: json['ok'] == true,
      errorCode: json['error_code']?.toString() ?? '',
      errorDetail: json['error_detail']?.toString() ?? '',
      provider: provider is Map<String, Object?>
          ? IntegrationProvider.fromJson(provider)
          : null,
    );
  }
}
