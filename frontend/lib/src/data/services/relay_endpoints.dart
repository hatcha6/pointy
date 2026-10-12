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
/// The default is the relay's own domain. Builds already in the field carry
/// the older platform host (env-9493505.tip2.libyanspider.cloud), which stays
/// bound to the same relay, so it must never be removed.
const String kDefaultRelayApiBaseUrl = String.fromEnvironment(
  'POINTY_RELAY_API_BASE_URL',
  defaultValue: 'https://my.dftr.ly/api',
);
