import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/onboarding.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/auth_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/auth/view_models/auth_view_model.dart';

void main() {
  test('a fresh install reaches the wizard when the first probe times out',
      () async {
    // The onboarding probe gives up after five seconds — a timeout sized for a
    // till mid-shift, not for the cold start of a backend installed minutes
    // ago. Settling on the login screen because of one slow request strands the
    // owner: a fresh install has no account for them to sign in with.
    final repo = _FakeAuthRepository(
      onboardingResults: [
        const Error(_Unreachable()),
        const Ok(OnboardingStatus(requiresOnboarding: true)),
      ],
    );
    final viewModel = AuthViewModel(repo, autoLoad: false);
    addTearDown(viewModel.dispose);

    await viewModel.loadCurrentUser();

    expect(viewModel.status, AuthStatus.setupRequired);
    expect(repo.onboardingProbeCount, 2);
  });

  test('an unreachable server still settles, rather than retrying forever',
      () async {
    final repo = _FakeAuthRepository(
      onboardingResults: const [
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
  });

  test('logout goes straight to the login screen without retrying', () async {
    // Signing out proves accounts exist, so there is nothing for a retry to
    // learn. A cashier whose server has just gone down must not wait through
    // three timeouts to be shown the login screen.
    final repo = _FakeAuthRepository(
      currentUser: _user,
      onboardingResults: const [Error(_Unreachable())],
    );
    final viewModel = AuthViewModel(repo, autoLoad: false);
    addTearDown(viewModel.dispose);
    await viewModel.loadCurrentUser();
    expect(viewModel.status, AuthStatus.authenticated);

    await viewModel.logout();

    expect(viewModel.status, AuthStatus.unauthenticated);
    expect(repo.onboardingProbeCount, 1);
  });
}

const _user = PosUser(
  id: 1,
  username: 'owner',
  role: UserRole.manager,
  isActive: true,
);

class _Unreachable implements Exception {
  const _Unreachable();
}

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository({required this.onboardingResults, this.currentUser})
    : super(PosApiService());

  final List<Result<OnboardingStatus>> onboardingResults;
  final PosUser? currentUser;
  int onboardingProbeCount = 0;

  @override
  Future<Result<PosUser?>> loadCurrentUser() async => Ok(currentUser);

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
