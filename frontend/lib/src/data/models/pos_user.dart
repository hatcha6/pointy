enum UserRole {
  manager,
  cashier,
  accountant,
  technician;

  bool get isManager => this == UserRole.manager;
  bool get isAccountant => this == UserRole.accountant;
  bool get isTechnician => this == UserRole.technician;

  static UserRole fromJson(Object? value) {
    return switch (value?.toString().toLowerCase()) {
      'manager' => UserRole.manager,
      'accountant' => UserRole.accountant,
      'technician' => UserRole.technician,
      'cashier' => UserRole.cashier,
      _ => UserRole.cashier,
    };
  }

  String toJson() {
    return switch (this) {
      UserRole.manager => 'manager',
      UserRole.cashier => 'cashier',
      UserRole.accountant => 'accountant',
      UserRole.technician => 'technician',
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
    this.hasPermissionSnapshot = false,
  });

  final int id;
  final String username;
  final String firstName;
  final String lastName;
  final String displayName;
  final String email;
  final UserRole role;
  final bool isActive;
  final Set<String> permissions;
  final bool hasPermissionSnapshot;

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
      hasPermissionSnapshot: _permissionPayload(json) != null,
    );
  }

  static Object? _permissionPayload(Map<String, Object?> json) {
    return json['permissions'] ??
        json['user_permissions'] ??
        json['permission_codenames'];
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
  const PosUserPage({required this.users, required this.hasMore});

  final List<PosUser> users;
  final bool hasMore;

  factory PosUserPage.fromAny(Object? decoded) {
    if (decoded is Map<String, Object?>) {
      final results = decoded['results'];
      final users = results is List<Object?>
          ? results
                .whereType<Map<String, Object?>>()
                .map(PosUser.fromJson)
                .toList(growable: false)
          : const <PosUser>[];
      return PosUserPage(users: users, hasMore: decoded['next'] != null);
    }
    if (decoded is List<Object?>) {
      return PosUserPage(
        users: decoded
            .whereType<Map<String, Object?>>()
            .map(PosUser.fromJson)
            .toList(growable: false),
        hasMore: false,
      );
    }
    return const PosUserPage(users: [], hasMore: false);
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
  });

  final String username;
  final String password;
  final UserRole role;
  final String displayName;
  final String email;
  final bool isActive;

  Map<String, Object?> toJson() {
    return {
      'username': username,
      'password': password,
      'role': role.toJson(),
      'first_name': displayName,
      'email': email,
      'is_active': isActive,
    };
  }
}

class UserUpdateDraft {
  const UserUpdateDraft({this.role, this.isActive});

  final UserRole? role;
  final bool? isActive;

  Map<String, Object?> toJson() {
    return {
      if (role != null) 'role': role!.toJson(),
      if (isActive != null) 'is_active': isActive,
    };
  }
}
