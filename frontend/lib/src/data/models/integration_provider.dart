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

class IntegrationProvider {
  const IntegrationProvider({
    required this.key,
    required this.availability,
    this.blockedReason = '',
    this.capabilities = const [],
    this.fields = const [],
    this.secretFields = const [],
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
  });

  final String? baseUrl;
  final String? username;
  final String? password;
  final bool? isActive;

  Map<String, Object?> toJson() => {
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
