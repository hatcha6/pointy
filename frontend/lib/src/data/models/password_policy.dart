/// The password rules the backend serves — the one it enforces, and the ones it
/// only advises.
///
/// The split matters. Staff here sign in on a shared terminal all shift and pick
/// a short numeric PIN, so the backend enforces nothing but a length floor; the
/// stronger rules ship as guidance shown beside the field. Nothing in this file
/// may turn advice into a blocker: [PasswordAdvice] is never allowed to gate a
/// submit, only [PasswordRequirement] is.
///
/// The rules come from `GET /api/auth/password/policy/` rather than being
/// duplicated here, so raising the floor on a deployment moves the UI with it.
library;

/// A rule the server will actually reject a password for.
enum PasswordRequirement { minLength }

/// A suggestion. Failing one is fine — the password still saves.
enum PasswordAdvice {
  recommendedLength,
  notNumeric,
  notCommon,
  notSimilarToUser,
}

/// Where a rule stands for the password currently typed. [pending] is not a
/// failure: it is "nothing typed yet", or — for [PasswordAdvice.notCommon] —
/// "only the server holds that list".
enum PasswordRuleState { pending, satisfied, failed }

PasswordRequirement? passwordRequirementFromKey(String key) {
  return switch (key) {
    'min_length' => PasswordRequirement.minLength,
    _ => null,
  };
}

PasswordAdvice? passwordAdviceFromKey(String key) {
  return switch (key) {
    'recommended_length' => PasswordAdvice.recommendedLength,
    'not_numeric' => PasswordAdvice.notNumeric,
    'not_common' => PasswordAdvice.notCommon,
    'not_similar_to_user' => PasswordAdvice.notSimilarToUser,
    _ => null,
  };
}

/// Django's validator codes, as they arrive in a rejected change's `codes`.
/// Only requirements can appear here — a deployment that tightens the policy
/// promotes an advice line into a requirement server-side, and the client picks
/// that up from the policy rather than guessing.
PasswordRequirement? passwordRequirementFromServerCode(String code) {
  return switch (code) {
    'password_too_short' => PasswordRequirement.minLength,
    _ => null,
  };
}

class PasswordPolicy {
  const PasswordPolicy({
    required this.required,
    required this.advisory,
    required this.minLength,
    required this.recommendedMinLength,
  });

  /// Used only when the policy call fails — a checklist built from the shipped
  /// configuration beats no checklist at all, which is the state that prompted
  /// all of this.
  static const fallback = PasswordPolicy(
    required: [PasswordRequirement.minLength],
    advisory: [
      PasswordAdvice.recommendedLength,
      PasswordAdvice.notNumeric,
      PasswordAdvice.notCommon,
      PasswordAdvice.notSimilarToUser,
    ],
    minLength: 4,
    recommendedMinLength: 8,
  );

  final List<PasswordRequirement> required;
  final List<PasswordAdvice> advisory;

  /// 0 when no length validator is configured, in which case the requirement is
  /// absent from [required] too and nothing invents a limit.
  final int minLength;
  final int recommendedMinLength;

  factory PasswordPolicy.fromJson(Map<String, Object?> json) {
    List<String> keys(Object? value) => (value as List<Object?>? ?? const [])
        .map((item) => item?.toString() ?? '')
        .toList(growable: false);

    return PasswordPolicy(
      required: keys(json['required'])
          .map(passwordRequirementFromKey)
          .whereType<PasswordRequirement>()
          .toList(growable: false),
      advisory: keys(json['advisory'])
          .map(passwordAdviceFromKey)
          .whereType<PasswordAdvice>()
          .toList(growable: false),
      minLength: int.tryParse(json['min_length']?.toString() ?? '') ?? 0,
      recommendedMinLength:
          int.tryParse(json['recommended_min_length']?.toString() ?? '') ?? 8,
    );
  }
}

/// The identity a password is compared against for the "doesn't look like you"
/// advice.
class PasswordOwner {
  const PasswordOwner({
    this.username = '',
    this.firstName = '',
    this.lastName = '',
    this.email = '',
  });

  final String username;
  final String firstName;
  final String lastName;
  final String email;

  Iterable<String> get attributes sync* {
    for (final value in [username, firstName, lastName, email]) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) yield trimmed;
    }
  }
}

/// How a typed password measures up. Only [meetsRequirements] may gate a submit.
class PasswordAssessment {
  const PasswordAssessment({required this.requirements, required this.advice});

  final Map<PasswordRequirement, PasswordRuleState> requirements;
  final Map<PasswordAdvice, PasswordRuleState> advice;

  bool get meetsRequirements =>
      !requirements.values.contains(PasswordRuleState.failed);

  /// How many suggestions the password already follows, for the "قوية / مقبولة"
  /// summary. Pending advice counts as neither followed nor broken.
  int get adviceFollowed =>
      advice.values.where((s) => s == PasswordRuleState.satisfied).length;

  int get adviceBroken =>
      advice.values.where((s) => s == PasswordRuleState.failed).length;
}

/// Measures [password] against [policy], as far as the client honestly can.
///
/// [serverFailures] are requirements a submitted attempt was actually rejected
/// for — they win over the local guess, because the server checked the real
/// thing and the client only approximates it.
PasswordAssessment assessPassword({
  required String password,
  required PasswordPolicy policy,
  PasswordOwner owner = const PasswordOwner(),
  Set<PasswordRequirement> serverFailures = const {},
}) {
  final requirements = <PasswordRequirement, PasswordRuleState>{};
  for (final rule in policy.required) {
    if (serverFailures.contains(rule)) {
      requirements[rule] = PasswordRuleState.failed;
      continue;
    }
    if (password.isEmpty) {
      requirements[rule] = PasswordRuleState.pending;
      continue;
    }
    requirements[rule] = switch (rule) {
      PasswordRequirement.minLength =>
        _length(password) >= policy.minLength
            ? PasswordRuleState.satisfied
            : PasswordRuleState.failed,
    };
  }

  final advice = <PasswordAdvice, PasswordRuleState>{};
  for (final item in policy.advisory) {
    if (password.isEmpty) {
      advice[item] = PasswordRuleState.pending;
      continue;
    }
    advice[item] = switch (item) {
      PasswordAdvice.recommendedLength =>
        _length(password) >= policy.recommendedMinLength
            ? PasswordRuleState.satisfied
            : PasswordRuleState.failed,
      PasswordAdvice.notNumeric =>
        _isEntirelyNumeric(password)
            ? PasswordRuleState.failed
            : PasswordRuleState.satisfied,
      PasswordAdvice.notSimilarToUser =>
        _resemblesOwner(password, owner)
            ? PasswordRuleState.failed
            : PasswordRuleState.satisfied,
      // Only the server holds the common-password list, and it no longer
      // enforces it — so this line stays advice we cannot evaluate rather than
      // a false green tick.
      PasswordAdvice.notCommon => PasswordRuleState.pending,
    };
  }

  return PasswordAssessment(requirements: requirements, advice: advice);
}

/// Length in user-perceived characters. `String.length` counts UTF-16 units,
/// which over-counts an emoji; Django counts Python characters, so this is the
/// closer match.
int _length(String password) => password.runes.length;

bool _isEntirelyNumeric(String password) {
  return RegExp(r'^[0-9]+$').hasMatch(password);
}

/// A deliberately coarse stand-in for Django's `SequenceMatcher` similarity
/// check: containment either way, on values long enough for that to mean
/// something. It catches what people actually do — build a password out of
/// their own username — without pretending to be the real algorithm. Since this
/// only drives advice, a miss costs nothing.
bool _resemblesOwner(String password, PasswordOwner owner) {
  final candidate = password.toLowerCase();
  for (final attribute in owner.attributes) {
    final value = attribute.toLowerCase();
    if (value.length < 3) continue;
    if (candidate.contains(value)) return true;
    if (candidate.length >= 3 && value.contains(candidate)) return true;
    // An email's local part is what a password usually echoes, not the domain.
    final localPart = value.split('@').first;
    if (localPart.length >= 3 && candidate.contains(localPart)) return true;
  }
  return false;
}
