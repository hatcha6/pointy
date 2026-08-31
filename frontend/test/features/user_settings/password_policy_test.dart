import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/password_policy.dart';

void main() {
  const policy = PasswordPolicy.fallback;
  const owner = PasswordOwner(
    username: 'hatem',
    firstName: 'حاتم',
    lastName: 'علي',
    email: 'hatem@example.test',
  );

  group('what is enforced', () {
    test('a four-digit PIN satisfies the requirements', () {
      // The product decision: staff sign in dozens of times a shift and pick a
      // short PIN. Advice may go unmet; the save must not be blocked.
      final assessment = assessPassword(password: '1234', policy: policy);

      expect(assessment.meetsRequirements, isTrue);
      expect(
        assessment.requirements[PasswordRequirement.minLength],
        PasswordRuleState.satisfied,
      );
    });

    test('below the floor is the one thing that blocks', () {
      final assessment = assessPassword(password: '12', policy: policy);

      expect(assessment.meetsRequirements, isFalse);
      expect(
        assessment.requirements[PasswordRequirement.minLength],
        PasswordRuleState.failed,
      );
    });

    test('every rule is pending before anything is typed', () {
      final assessment = assessPassword(password: '', policy: policy);

      expect(
        assessment.requirements.values,
        everyElement(PasswordRuleState.pending),
      );
      expect(assessment.advice.values, everyElement(PasswordRuleState.pending));
    });
  });

  group('what is advised', () {
    test('a PIN breaks the suggestions without failing the form', () {
      final assessment = assessPassword(password: '1234', policy: policy);

      expect(assessment.meetsRequirements, isTrue);
      expect(
        assessment.advice[PasswordAdvice.notNumeric],
        PasswordRuleState.failed,
      );
      expect(
        assessment.advice[PasswordAdvice.recommendedLength],
        PasswordRuleState.failed,
      );
    });

    test('a long mixed password follows the suggestions', () {
      final assessment = assessPassword(
        password: 'qamar-7-zaytoun',
        policy: policy,
        owner: owner,
      );

      expect(assessment.meetsRequirements, isTrue);
      expect(
        assessment.advice[PasswordAdvice.recommendedLength],
        PasswordRuleState.satisfied,
      );
      expect(
        assessment.advice[PasswordAdvice.notNumeric],
        PasswordRuleState.satisfied,
      );
      expect(
        assessment.advice[PasswordAdvice.notSimilarToUser],
        PasswordRuleState.satisfied,
      );
    });

    test('a password built from the username is flagged', () {
      final assessment = assessPassword(
        password: 'hatem2026',
        policy: policy,
        owner: owner,
      );

      expect(
        assessment.advice[PasswordAdvice.notSimilarToUser],
        PasswordRuleState.failed,
      );
      // Still only advice — it saves.
      expect(assessment.meetsRequirements, isTrue);
    });

    test('the email local part counts as the owner too', () {
      final assessment = assessPassword(
        password: 'xxhatemxx',
        policy: policy,
        owner: const PasswordOwner(email: 'hatem@example.test'),
      );

      expect(
        assessment.advice[PasswordAdvice.notSimilarToUser],
        PasswordRuleState.failed,
      );
    });

    test('the common-password list is never guessed at locally', () {
      // Only the server holds it, so the honest state is "not checked yet" —
      // never a green tick the client cannot back up.
      final assessment = assessPassword(password: 'password', policy: policy);

      expect(
        assessment.advice[PasswordAdvice.notCommon],
        PasswordRuleState.pending,
      );
    });
  });

  group('the server has the last word', () {
    test('a rejection marks the rule failed regardless of the local guess', () {
      final assessment = assessPassword(
        password: 'longenough',
        policy: policy,
        serverFailures: const {PasswordRequirement.minLength},
      );

      expect(assessment.meetsRequirements, isFalse);
    });
  });

  group('policy wire format', () {
    test('parses the served split', () {
      final parsed = PasswordPolicy.fromJson(const {
        'required': ['min_length'],
        'advisory': ['recommended_length', 'not_numeric', 'not_common'],
        'min_length': 4,
        'recommended_min_length': 8,
      });

      expect(parsed.required, [PasswordRequirement.minLength]);
      expect(parsed.advisory, hasLength(3));
      expect(parsed.minLength, 4);
      expect(parsed.recommendedMinLength, 8);
    });

    test('unknown keys are ignored rather than crashing the form', () {
      final parsed = PasswordPolicy.fromJson(const {
        'required': ['min_length', 'something_new'],
        'advisory': ['not_numeric', 'also_new'],
        'min_length': 6,
      });

      expect(parsed.required, [PasswordRequirement.minLength]);
      expect(parsed.advisory, [PasswordAdvice.notNumeric]);
      expect(parsed.minLength, 6);
      expect(parsed.recommendedMinLength, 8);
    });

    test('a tightened floor drops the length suggestion server-side', () {
      // Mirrors password_policy.py: the advice list simply arrives without it.
      final parsed = PasswordPolicy.fromJson(const {
        'required': ['min_length'],
        'advisory': ['not_numeric'],
        'min_length': 12,
        'recommended_min_length': 8,
      });

      expect(
        parsed.advisory,
        isNot(contains(PasswordAdvice.recommendedLength)),
      );
    });
  });
}
