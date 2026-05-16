enum UserRole {
  manager,
  cashier;

  bool get isManager => this == UserRole.manager;

  static UserRole fromJson(Object? value) {
    return switch (value?.toString().toLowerCase()) {
      'manager' => UserRole.manager,
      'cashier' => UserRole.cashier,
      _ => UserRole.cashier,
    };
  }

  String toJson() {
    return switch (this) {
      UserRole.manager => 'manager',
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
    this.displayName = '',
    this.email = '',
  });

  final int id;
  final String username;
  final String displayName;
  final String email;
  final UserRole role;
  final bool isActive;

  String get label => displayName.trim().isEmpty ? username : displayName;

  factory PosUser.fromJson(Map<String, Object?> json) {
    final firstName = json['first_name']?.toString() ?? '';
    final lastName = json['last_name']?.toString() ?? '';
    final fullName = '$firstName $lastName'.trim();

    return PosUser(
      id: (json['id'] as num?)?.toInt() ?? 0,
      username: json['username']?.toString() ?? '',
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
    );
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
