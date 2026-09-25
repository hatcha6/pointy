import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/onboarding.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/auth_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/auth/view_models/auth_view_model.dart';
import 'package:pointy_frontend/src/features/auth/view_models/login_failure.dart';

void main() {
  test(
    'a fresh install reaches the wizard when the first probe times out',
    () async {
      // The onboarding probe gives up after five seconds — a timeout sized for a
      // till mid-shift, not for the cold start of a backend installed minutes
      // ago. Settling on the login screen because of one slow request strands the
      // owner: a fresh install has no account for them to sign in with.
      final repo = _FakeAuthRepository(
        onboardingResults: [
          Error(_Unreachable()),
          const Ok(OnboardingStatus(requiresOnboarding: true)),
        ],
      );
      final viewModel = AuthViewModel(repo, autoLoad: false);
      addTearDown(viewModel.dispose);

      await viewModel.loadCurrentUser();

      expect(viewModel.status, AuthStatus.setupRequired);
      expect(repo.onboardingProbeCount, 2);
    },
  );

  test(
    'an unreachable server still settles, rather than retrying forever',
    () async {
      final repo = _FakeAuthRepository(
        onboardingResults: [
          Error(_Unreachable()),
          Error(_Unreachable()),
          Error(_Unreachable()),
          Error(_Unreachable()),
        ],
      );
      final viewModel = AuthViewModel(repo, autoLoad: false);
      addTearDown(viewModel.dispose);

      await viewModel.loadCurrentUser();

      expect(viewModel.status, AuthStatus.unauthenticated);
      expect(repo.onboardingProbeCount, 3);
    },
  );

  test('logout goes straight to the login screen without retrying', () async {
    // Signing out proves accounts exist, so there is nothing for a retry to
    // learn. A cashier whose server has just gone down must not wait through
    // three timeouts to be shown the login screen.
    final repo = _FakeAuthRepository(
      currentUser: _user,
      onboardingResults: [Error(_Unreachable())],
    );
    final viewModel = AuthViewModel(repo, autoLoad: false);
    addTearDown(viewModel.dispose);
    await viewModel.loadCurrentUser();
    expect(viewModel.status, AuthStatus.authenticated);

    await viewModel.logout();

    expect(viewModel.status, AuthStatus.unauthenticated);
    expect(repo.onboardingProbeCount, 1);
  });

  group('what a failed sign-in is reported as', () {
    // Every failure used to be one message — check the username and password
    // — including a relay that no longer held the phone's ticket. A cashier
    // outside the shop retyped a correct password against a server that was
    // never reached, and support heard "wrong password".
    test('a ticket the relay refused is a remote-access problem', () async {
      final repo = _FakeAuthRepository(
        onboardingResults: [],
        loginResult: const Error(
          PosApiException(
            message: 'Login failed with status 401',
            statusCode: 401,
            responseBody: '{"error":"relay token rejected"}',
            fromRelay: true,
          ),
        ),
      );
      final viewModel = AuthViewModel(repo, autoLoad: false);
      addTearDown(viewModel.dispose);

      expect(await viewModel.login(username: 'owner', password: 'pw'), isFalse);

      expect(viewModel.loginFailure, LoginFailure.relayRejected);
      expect(viewModel.connectionProblem, LoginFailure.relayRejected);
      expect(viewModel.hasError, isTrue);
    });

    test('a refused password is still a refused password', () async {
      final repo = _FakeAuthRepository(
        onboardingResults: [],
        loginResult: const Error(
          PosApiException(
            message: 'Login failed with status 400',
            statusCode: 400,
            responseBody: '{"detail":["Invalid username or password."]}',
          ),
        ),
      );
      final viewModel = AuthViewModel(repo, autoLoad: false);
      addTearDown(viewModel.dispose);

      expect(await viewModel.login(username: 'owner', password: 'pw'), isFalse);

      expect(viewModel.loginFailure, LoginFailure.invalidCredentials);
      expect(viewModel.connectionProblem, isNull);
    });

    test(
      'a probe that could not reach the server is said before anyone types',
      () async {
        final repo = _FakeAuthRepository(
          currentUserResult: Error(_Unreachable()),
          onboardingResults: [
            Error(_Unreachable()),
            Error(_Unreachable()),
            Error(_Unreachable()),
          ],
        );
        final viewModel = AuthViewModel(repo, autoLoad: false);
        addTearDown(viewModel.dispose);

        await viewModel.loadCurrentUser();

        expect(viewModel.status, AuthStatus.unauthenticated);
        expect(viewModel.connectionProblem, LoginFailure.serverUnreachable);
        expect(viewModel.loginFailure, isNull);
      },
    );

    // The first probe found no way to the server; the next reached it and
    // was answered with a server error. The warning belongs to the probe
    // that recorded it, not to the screen forever after.
    test('a stale connectivity warning does not outlive its probe', () async {
      final repo = _FakeAuthRepository(
        currentUserResults: [
          Error(_Unreachable()),
          const Error(
            PosApiException(
              message: 'Current user request failed with status 500',
              statusCode: 500,
              responseBody: '',
            ),
          ),
        ],
        onboardingResults: [
          Error(_Unreachable()),
          Error(_Unreachable()),
          Error(_Unreachable()),
          const Ok(OnboardingStatus(requiresOnboarding: false)),
        ],
      );
      final viewModel = AuthViewModel(repo, autoLoad: false);
      addTearDown(viewModel.dispose);

      await viewModel.loadCurrentUser();
      expect(viewModel.connectionProblem, LoginFailure.serverUnreachable);

      await viewModel.loadCurrentUser();

      expect(viewModel.status, AuthStatus.unauthenticated);
      expect(viewModel.connectionProblem, isNull);
    });

    test('a refused password ends an earlier connection problem', () async {
      final repo = _FakeAuthRepository(
        currentUserResults: [Error(_Unreachable())],
        onboardingResults: [
          Error(_Unreachable()),
          Error(_Unreachable()),
          Error(_Unreachable()),
        ],
        loginResult: const Error(
          PosApiException(
            message: 'Login failed with status 400',
            statusCode: 400,
            responseBody: '{"detail":["Invalid username or password."]}',
          ),
        ),
      );
      final viewModel = AuthViewModel(repo, autoLoad: false);
      addTearDown(viewModel.dispose);
      await viewModel.loadCurrentUser();
      expect(viewModel.connectionProblem, LoginFailure.serverUnreachable);

      expect(await viewModel.login(username: 'owner', password: 'pw'), isFalse);

      expect(viewModel.loginFailure, LoginFailure.invalidCredentials);
      expect(viewModel.connectionProblem, isNull);
    });

    test('a server that answers again clears the problem', () async {
      final repo = _FakeAuthRepository(
        currentUserResult: Error(_Unreachable()),
        onboardingResults: [
          Error(_Unreachable()),
          Ok(OnboardingStatus(requiresOnboarding: false)),
        ],
      );
      final viewModel = AuthViewModel(repo, autoLoad: false);
      addTearDown(viewModel.dispose);

      await viewModel.loadCurrentUser();

      expect(viewModel.status, AuthStatus.unauthenticated);
      expect(viewModel.connectionProblem, isNull);
    });
  });

  group('classifyLoginFailure', () {
    PosApiException api(int status, String body, {bool fromRelay = false}) {
      return PosApiException(
        message: 'Login failed with status $status',
        statusCode: status,
        responseBody: body,
        fromRelay: fromRelay,
      );
    }

    test('reads the relay\'s own refusals', () {
      expect(
        classifyLoginFailure(
          api(
            503,
            '{"error":"installation connector offline"}',
            fromRelay: true,
          ),
          viaRelay: true,
        ),
        LoginFailure.relayConnectorOffline,
      );
      expect(
        classifyLoginFailure(
          api(402, '{"error":"relay subscription inactive"}', fromRelay: true),
          viaRelay: true,
        ),
        LoginFailure.relaySubscriptionInactive,
      );
      expect(
        classifyLoginFailure(
          api(504, '{"error":"relay request timed out"}', fromRelay: true),
          viaRelay: true,
        ),
        LoginFailure.relayUnavailable,
      );
    });

    test('reads the backend\'s', () {
      expect(
        classifyLoginFailure(
          api(400, '{"detail":["This user account is disabled."]}'),
          viaRelay: false,
        ),
        LoginFailure.accountDisabled,
      );
      expect(
        classifyLoginFailure(
          api(429, '{"detail":"Request was throttled."}'),
          viaRelay: false,
        ),
        LoginFailure.tooManyAttempts,
      );
      expect(
        classifyLoginFailure(api(500, ''), viaRelay: true),
        LoginFailure.serverError,
      );
    });

    test('a connection that failed names the route it was on', () {
      final unreachable = http.ClientException('Network is unreachable');
      expect(
        classifyLoginFailure(unreachable, viaRelay: true),
        LoginFailure.relayUnreachable,
      );
      expect(
        classifyLoginFailure(unreachable, viaRelay: false),
        LoginFailure.serverUnreachable,
      );
      expect(
        classifyLoginFailure(TimeoutException('login'), viaRelay: false),
        LoginFailure.serverUnreachable,
      );
    });
  });
}

const _user = PosUser(
  id: 1,
  username: 'owner',
  role: UserRole.manager,
  isActive: true,
);

/// A connection that failed, the way `dart:io` reports it.
class _Unreachable extends http.ClientException {
  _Unreachable() : super('Connection refused');
}

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository({
    required this.onboardingResults,
    this.currentUser,
    this.currentUserResult,
    this.currentUserResults,
    this.loginResult,
  }) : super(PosApiService());

  final List<Result<OnboardingStatus>> onboardingResults;
  final PosUser? currentUser;
  final Result<PosUser?>? currentUserResult;

  /// One answer per probe, in order; the last one repeats.
  final List<Result<PosUser?>>? currentUserResults;
  final Result<PosUser>? loginResult;
  int onboardingProbeCount = 0;
  int currentUserProbeCount = 0;

  @override
  Future<Result<PosUser?>> loadCurrentUser() async {
    final sequence = currentUserResults;
    if (sequence != null && sequence.isNotEmpty) {
      final index = currentUserProbeCount < sequence.length
          ? currentUserProbeCount
          : sequence.length - 1;
      currentUserProbeCount++;
      return sequence[index];
    }
    return currentUserResult ?? Ok(currentUser);
  }

  @override
  Future<Result<PosUser>> login({
    required String username,
    required String password,
  }) async => loginResult ?? Ok(_user);

  @override
  Future<Result<OnboardingStatus>> loadOnboardingStatus() async {
    final result = onboardingResults[onboardingProbeCount];
    onboardingProbeCount++;
    return result;
  }

  @override
  Future<Result<void>> logout() async => const Ok(null);

  @override
  Future<Result<void>> forgetCurrentUser() async => const Ok(null);
}
