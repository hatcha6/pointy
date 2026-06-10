class OnboardingStatus {
  const OnboardingStatus({required this.requiresOnboarding});

  final bool requiresOnboarding;

  factory OnboardingStatus.fromJson(Map<String, Object?> json) {
    return OnboardingStatus(
      requiresOnboarding: json['requires_onboarding'] == true,
    );
  }
}

class InitialAdminDraft {
  const InitialAdminDraft({
    required this.username,
    required this.password,
    this.email = '',
    this.firstName = '',
    this.lastName = '',
  });

  final String username;
  final String password;
  final String email;
  final String firstName;
  final String lastName;

  Map<String, Object?> toJson() {
    return {
      'username': username.trim(),
      'email': email.trim(),
      'first_name': firstName.trim(),
      'last_name': lastName.trim(),
      'password': password,
    };
  }
}
