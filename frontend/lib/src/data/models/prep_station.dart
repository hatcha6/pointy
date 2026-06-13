/// A kitchen/production station (grill, bar, pastry, ...). Made-to-order lines
/// route to a station by product category; the station's chit prints on the
/// device that serves it. The default station catches lines that match no
/// other station's categories.
class PrepStation {
  const PrepStation({
    required this.id,
    required this.name,
    required this.printerProfileId,
    required this.printerProfileName,
    required this.categoryIds,
    required this.categoryNames,
    required this.isDefault,
    required this.isActive,
    required this.priority,
  });

  final int id;
  final String name;
  final int? printerProfileId;
  final String printerProfileName;
  final List<int> categoryIds;
  final List<String> categoryNames;
  final bool isDefault;
  final bool isActive;
  final int priority;

  factory PrepStation.fromJson(Map<String, Object?> json) {
    return PrepStation(
      id: json['id'] as int,
      name: json['name']?.toString() ?? '',
      printerProfileId: (json['printer_profile'] as num?)?.toInt(),
      printerProfileName: json['printer_profile_name']?.toString() ?? '',
      categoryIds: ((json['categories'] as List<Object?>?) ?? const [])
          .map((value) => (value as num).toInt())
          .toList(growable: false),
      categoryNames: ((json['category_names'] as List<Object?>?) ?? const [])
          .map((value) => value.toString())
          .toList(growable: false),
      isDefault: json['is_default'] == true,
      isActive: json['is_active'] == true,
      priority: (json['priority'] as num?)?.toInt() ?? 0,
    );
  }
}

class PrepStationPage {
  const PrepStationPage({required this.stations, required this.hasMore});

  final List<PrepStation> stations;
  final bool hasMore;

  factory PrepStationPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(PrepStation.fromJson)
        .toList(growable: false);

    return PrepStationPage(stations: results, hasMore: json['next'] != null);
  }
}

class PrepStationDraft {
  const PrepStationDraft({
    required this.name,
    this.printerProfileId,
    this.categoryIds = const [],
    this.isDefault = false,
    this.isActive = true,
    this.priority = 0,
  });

  final String name;
  final int? printerProfileId;
  final List<int> categoryIds;
  final bool isDefault;
  final bool isActive;
  final int priority;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'printer_profile': printerProfileId,
      'categories': categoryIds,
      'is_default': isDefault,
      'is_active': isActive,
      'priority': priority,
    };
  }
}
