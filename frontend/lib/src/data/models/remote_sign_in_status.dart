/// Whether a shop takes sign-ins from the internet (the relay's sign-in
/// route), and — only when it does — its name.
class RemoteSignInStatus {
  const RemoteSignInStatus({required this.enabled, required this.shopName});

  final bool enabled;
  final String shopName;

  factory RemoteSignInStatus.fromJson(Map<String, Object?> json) {
    return RemoteSignInStatus(
      enabled: json['enabled'] == true,
      shopName: json['shop_name']?.toString() ?? '',
    );
  }
}
