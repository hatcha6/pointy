/// The curated, grouped catalog of permissions an admin may grant to a user on
/// top of their role. Mirrors the backend `permission_catalog` endpoint; labels
/// and descriptions are Arabic and come straight from the server.
class PermissionCatalog {
  const PermissionCatalog({required this.groups});

  final List<PermissionCatalogGroup> groups;

  static const PermissionCatalog empty = PermissionCatalog(groups: []);

  factory PermissionCatalog.fromJson(Map<String, Object?> json) {
    final groups = json['groups'];
    return PermissionCatalog(
      groups: groups is List
          ? groups
                .whereType<Map<String, Object?>>()
                .map(PermissionCatalogGroup.fromJson)
                .toList(growable: false)
          : const [],
    );
  }

  /// Every permission code an admin is allowed to grant (across all groups).
  Set<String> get grantableCodes => {
    for (final group in groups)
      for (final entry in group.permissions)
        if (entry.grantable) entry.code,
  };

  /// Map of code → human label, for rendering inherited/extra codes that may
  /// not be visible in the (search-)filtered view.
  Map<String, String> get labelsByCode => {
    for (final group in groups)
      for (final entry in group.permissions) entry.code: entry.label,
  };

  int get totalCount =>
      groups.fold(0, (sum, group) => sum + group.permissions.length);

  bool get isEmpty => groups.isEmpty;
}

class PermissionCatalogGroup {
  const PermissionCatalogGroup({
    required this.key,
    required this.label,
    required this.description,
    required this.permissions,
  });

  final String key;
  final String label;
  final String description;
  final List<PermissionCatalogEntry> permissions;

  factory PermissionCatalogGroup.fromJson(Map<String, Object?> json) {
    final permissions = json['permissions'];
    return PermissionCatalogGroup(
      key: json['key']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      permissions: permissions is List
          ? permissions
                .whereType<Map<String, Object?>>()
                .map(PermissionCatalogEntry.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}

class PermissionCatalogEntry {
  const PermissionCatalogEntry({
    required this.code,
    required this.label,
    required this.description,
    required this.grantable,
  });

  final String code;
  final String label;
  final String description;

  /// Whether the current admin is allowed to grant this permission (i.e. they
  /// hold it themselves). Non-grantable entries render disabled.
  final bool grantable;

  factory PermissionCatalogEntry.fromJson(Map<String, Object?> json) {
    return PermissionCatalogEntry(
      code: json['code']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      grantable: json['grantable'] == true,
    );
  }
}
