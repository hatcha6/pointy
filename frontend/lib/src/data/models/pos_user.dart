enum UserRole {
  manager,
  supervisor,
  accountant,
  auditor,
  purchasingAgent,
  inventoryClerk,
  technician,
  cashier;

  bool get isManager => this == UserRole.manager;
  bool get isSupervisor => this == UserRole.supervisor;
  bool get isAccountant => this == UserRole.accountant;
  bool get isAuditor => this == UserRole.auditor;
  bool get isPurchasingAgent => this == UserRole.purchasingAgent;
  bool get isInventoryClerk => this == UserRole.inventoryClerk;
  bool get isTechnician => this == UserRole.technician;
  bool get isCashier => this == UserRole.cashier;

  /// The roles an admin can assign, ordered from most to least privileged.
  static const List<UserRole> assignable = [
    UserRole.manager,
    UserRole.supervisor,
    UserRole.accountant,
    UserRole.auditor,
    UserRole.purchasingAgent,
    UserRole.inventoryClerk,
    UserRole.technician,
    UserRole.cashier,
  ];

  static UserRole fromJson(Object? value) {
    return switch (value?.toString().toLowerCase()) {
      'manager' => UserRole.manager,
      'supervisor' => UserRole.supervisor,
      'accountant' => UserRole.accountant,
      'auditor' => UserRole.auditor,
      'purchasing_agent' => UserRole.purchasingAgent,
      'inventory_clerk' => UserRole.inventoryClerk,
      'technician' => UserRole.technician,
      'cashier' => UserRole.cashier,
      _ => UserRole.cashier,
    };
  }

  String toJson() {
    return switch (this) {
      UserRole.manager => 'manager',
      UserRole.supervisor => 'supervisor',
      UserRole.accountant => 'accountant',
      UserRole.auditor => 'auditor',
      UserRole.purchasingAgent => 'purchasing_agent',
      UserRole.inventoryClerk => 'inventory_clerk',
      UserRole.technician => 'technician',
      UserRole.cashier => 'cashier',
    };
  }
}

class PosUser {
  const PosUser({
    required this.id,
    required this.username,
    required this.role,
    required this.isActive,
    this.firstName = '',
    this.lastName = '',
    this.displayName = '',
    this.email = '',
    this.permissions = const {},
    this.rolePermissions = const {},
    this.extraPermissions = const {},
    this.extraPermissionCount = 0,
    this.hasPermissionSnapshot = false,
    this.aiAvailable = false,
    this.allowCashierCustomerAccess = false,
    this.surveillanceEnabled = false,
    this.serializedInventoryEnabled = false,
    this.batchTrackingEnabled = false,
  });

  final int id;
  final String username;
  final String firstName;
  final String lastName;
  final String displayName;
  final String email;
  final UserRole role;
  final bool isActive;

  /// Effective permissions (role ∪ directly-granted), used to derive
  /// capabilities. May contain the `*` sentinel for managers.
  final Set<String> permissions;

  /// Permission codes inherited from the role (shown locked in the editor).
  final Set<String> rolePermissions;

  /// Permission codes granted directly to this user, on top of the role.
  final Set<String> extraPermissions;

  /// Count of directly-granted permissions (cheap field sent on the list view
  /// even when the full [extraPermissions] set is omitted).
  final int extraPermissionCount;

  final bool hasPermissionSnapshot;

  /// Whether this user has any directly-granted permissions beyond their role.
  bool get hasExtraPermissions => extraPermissionCount > 0;

  /// Whether the shop's AI entitlement is active for this session. Sourced from
  /// the auth response's top-level `ai_available` flag, not a user attribute.
  final bool aiAvailable;

  /// Whether cashiers may look up customers and collect customer debt (a
  /// manager-controlled shop setting). Top-level auth-response flag, like
  /// [aiAvailable].
  final bool allowCashierCustomerAccess;

  /// Whether this shop has cameras configured. Another top-level auth-response
  /// flag, and the one that keeps every camera surface — the drawer entry, the
  /// command palette, the invoice panel — out of a shop with no DVR.
  final bool surveillanceEnabled;

  /// Identified stock is opt-in per shop. Both default to off, and a shop that
  /// counts rather than identifies must not see the surfaces at all.
  final bool serializedInventoryEnabled;
  final bool batchTrackingEnabled;

  String get label => displayName.trim().isEmpty ? username : displayName;

  factory PosUser.fromJson(Map<String, Object?> json) {
    final firstName = json['first_name']?.toString() ?? '';
    final lastName = json['last_name']?.toString() ?? '';
    final fullName = '$firstName $lastName'.trim();

    return PosUser(
      id: (json['id'] as num?)?.toInt() ?? 0,
      username: json['username']?.toString() ?? '',
      firstName: firstName,
      lastName: lastName,
      displayName:
          json['display_name']?.toString() ??
          json['full_name']?.toString() ??
          json['name']?.toString() ??
          fullName,
      email: json['email']?.toString() ?? '',
      role: UserRole.fromJson(json['role'] ?? json['assigned_role']),
      isActive: json['is_active'] is bool
          ? json['is_active'] as bool
          : json['is_active']?.toString() != 'false',
      permissions: _permissionsFromJson(_permissionPayload(json)),
      rolePermissions: _permissionsFromJson(json['role_permissions']),
      extraPermissions: _permissionsFromJson(json['extra_permissions']),
      extraPermissionCount: _extraPermissionCount(json),
      hasPermissionSnapshot: _permissionPayload(json) != null,
      aiAvailable: json['ai_available'] == true,
      allowCashierCustomerAccess: json['allow_cashier_customer_access'] == true,
      surveillanceEnabled: json['surveillance_enabled'] == true,
      serializedInventoryEnabled: json['serialized_inventory_enabled'] == true,
      batchTrackingEnabled: json['batch_tracking_enabled'] == true,
    );
  }

  static Object? _permissionPayload(Map<String, Object?> json) {
    return json['permissions'] ??
        json['effective_permissions'] ??
        json['user_permissions'] ??
        json['permission_codenames'];
  }

  static int _extraPermissionCount(Map<String, Object?> json) {
    final raw = json['extra_permission_count'];
    if (raw is num) {
      return raw.toInt();
    }
    final extras = json['extra_permissions'];
    return extras is Iterable ? extras.length : 0;
  }

  static Set<String> _permissionsFromJson(Object? value) {
    if (value is Iterable) {
      return value
          .map(_permissionNameFromJson)
          .where((permission) => permission.isNotEmpty)
          .toSet();
    }

    final permission = _permissionNameFromJson(value);
    return permission.isEmpty ? const {} : {permission};
  }

  static String _permissionNameFromJson(Object? value) {
    if (value is Map) {
      final appLabel = value['app_label']?.toString();
      final codename = value['codename']?.toString();
      if (appLabel != null &&
          appLabel.isNotEmpty &&
          codename != null &&
          codename.isNotEmpty) {
        return '$appLabel.$codename';
      }
      return value['name']?.toString() ?? '';
    }
    return value?.toString() ?? '';
  }
}

class CurrentUserProfileDraft {
  const CurrentUserProfileDraft({
    required this.username,
    required this.firstName,
    required this.lastName,
    required this.email,
  });

  final String username;
  final String firstName;
  final String lastName;
  final String email;

  Map<String, Object?> toJson() {
    return {
      'username': username.trim(),
      'first_name': firstName.trim(),
      'last_name': lastName.trim(),
      'email': email.trim(),
    };
  }
}

class PasswordChangeDraft {
  const PasswordChangeDraft({
    required this.currentPassword,
    required this.newPassword,
  });

  final String currentPassword;
  final String newPassword;

  Map<String, Object?> toJson() {
    return {'current_password': currentPassword, 'new_password': newPassword};
  }
}

class PosUserPage {
  const PosUserPage({
    required this.users,
    required this.hasMore,
    this.totalCount,
  });

  final List<PosUser> users;
  final bool hasMore;

  /// Total number of users matching the query across all pages (from the
  /// paginated `count`), independent of how many are currently loaded.
  final int? totalCount;

  factory PosUserPage.fromAny(Object? decoded) {
    if (decoded is Map<String, Object?>) {
      final results = decoded['results'];
      final users = results is List<Object?>
          ? results
                .whereType<Map<String, Object?>>()
                .map(PosUser.fromJson)
                .toList(growable: false)
          : const <PosUser>[];
      final count = decoded['count'];
      return PosUserPage(
        users: users,
        hasMore: decoded['next'] != null,
        totalCount: count is num ? count.toInt() : null,
      );
    }
    if (decoded is List<Object?>) {
      final users = decoded
          .whereType<Map<String, Object?>>()
          .map(PosUser.fromJson)
          .toList(growable: false);
      return PosUserPage(
        users: users,
        hasMore: false,
        totalCount: users.length,
      );
    }
    return const PosUserPage(users: [], hasMore: false, totalCount: 0);
  }
}

class UserCreateDraft {
  const UserCreateDraft({
    required this.username,
    required this.password,
    required this.role,
    this.displayName = '',
    this.email = '',
    this.isActive = true,
    this.extraPermissions,
  });

  final String username;
  final String password;
  final UserRole role;
  final String displayName;
  final String email;
  final bool isActive;
  final List<String>? extraPermissions;

  Map<String, Object?> toJson() {
    return {
      'username': username,
      'password': password,
      'role': role.toJson(),
      'first_name': displayName,
      'email': email,
      'is_active': isActive,
      if (extraPermissions != null) 'extra_permissions': extraPermissions,
    };
  }
}

class UserUpdateDraft {
  const UserUpdateDraft({
    this.role,
    this.isActive,
    this.displayName,
    this.email,
    this.password,
    this.extraPermissions,
  });

  final UserRole? role;
  final bool? isActive;
  final String? displayName;
  final String? email;
  final String? password;
  final List<String>? extraPermissions;

  Map<String, Object?> toJson() {
    return {
      if (role != null) 'role': role!.toJson(),
      if (isActive != null) 'is_active': isActive,
      if (displayName != null) 'first_name': displayName,
      if (email != null) 'email': email,
      if (password != null && password!.isNotEmpty) 'password': password,
      if (extraPermissions != null) 'extra_permissions': extraPermissions,
    };
  }
}
