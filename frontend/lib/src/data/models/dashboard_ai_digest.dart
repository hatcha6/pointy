/// The dashboard's inline AI text, generated server-side and cached per day:
/// a short owner-facing [brief] plus per-card [explainers] keyed by a widget id
/// (see the backend's `DIGEST_EXPLAINER_KEYS`). Empty when the shop has no AI
/// entitlement or there's nothing worth narrating.
class DashboardAiDigest {
  const DashboardAiDigest({
    this.brief = '',
    this.explainers = const {},
    this.generatedAt,
  });

  /// A one-or-two sentence summary of the period, shown as the dashboard's AI
  /// headline. Empty when the model had nothing to say.
  final String brief;

  /// One short explainer line per dashboard card, keyed by the card's digest id
  /// (e.g. `low_stock`, `sales_trend`). Only the cards the model chose to
  /// annotate are present.
  final Map<String, String> explainers;

  final DateTime? generatedAt;

  bool get isEmpty => brief.isEmpty && explainers.isEmpty;

  /// The explainer for [key], or null when the digest didn't annotate that card.
  String? explainerFor(String key) {
    final value = explainers[key];
    return (value == null || value.isEmpty) ? null : value;
  }

  static const empty = DashboardAiDigest();

  factory DashboardAiDigest.fromJson(Map<String, Object?> json) {
    final rawExplainers = json['explainers'];
    final explainers = <String, String>{};
    if (rawExplainers is Map) {
      rawExplainers.forEach((key, value) {
        final text = value?.toString().trim() ?? '';
        if (text.isNotEmpty) {
          explainers[key.toString()] = text;
        }
      });
    }
    return DashboardAiDigest(
      brief: json['brief']?.toString().trim() ?? '',
      explainers: Map.unmodifiable(explainers),
      generatedAt: DateTime.tryParse(json['generated_at']?.toString() ?? ''),
    );
  }
}
