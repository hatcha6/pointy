/// Production hosted-relay endpoints, baked as the default for clients.
///
/// [kDefaultRelayApiBaseUrl] is the relay's public API base the app falls back to
/// when the local backend can't be reached on the LAN and the stored connection
/// profile has no relay URL of its own (e.g. a device paired before its backend
/// reported a relay URL). Using it still requires a stored relay refresh token,
/// so a device that has never paired is unaffected.
///
/// Overridable at build time so a stable custom domain can replace the
/// platform-generated host without a code change:
///   flutter build … --dart-define=POINTY_RELAY_API_BASE_URL=https://relay.example/api
///
/// NOTE: the default points at a LibyanSpider JPaaS environment — the env id and
/// node/endpoint port are platform-generated and will change if the environment
/// or its TCP endpoint is recreated. Prefer a stable DNS name you control for
/// long-lived client builds (Android/Windows ship this value baked in).
const String kDefaultRelayApiBaseUrl = String.fromEnvironment(
  'POINTY_RELAY_API_BASE_URL',
  defaultValue: 'https://env-9493505.tip2.libyanspider.cloud/api',
);
