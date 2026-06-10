import '../../core/result.dart';
import '../models/onboarding.dart';
import '../models/pos_user.dart';
import '../services/pos_api_service.dart';

class AuthRepository {
  AuthRepository(this._service);

  final PosApiService _service;

  Future<Result<PosUser>> login({
    required String username,
    required String password,
  }) async {
    return Result.guard(
      () => _service.login(username: username, password: password),
    );
  }

  Future<Result<PosUser?>> loadCurrentUser() async {
    return Result.guard(_service.fetchCurrentUser);
  }

  Future<Result<OnboardingStatus>> loadOnboardingStatus() async {
    return Result.guard(_service.fetchOnboardingStatus);
  }

  Future<Result<PosUser>> createInitialAdmin(InitialAdminDraft draft) async {
    return Result.guard(() => _service.createInitialAdmin(draft));
  }

  Future<Result<PosUser>> updateCurrentUser(
    CurrentUserProfileDraft draft,
  ) async {
    return Result.guard(() => _service.updateCurrentUser(draft));
  }

  Future<Result<void>> changePassword(PasswordChangeDraft draft) async {
    return Result.guard(() => _service.changePassword(draft));
  }

  Future<Result<void>> forgetCurrentUser() async {
    return Result.guard(() async {
      try {
        final user = await _service.fetchCurrentUser();
        if (user != null) {
          await _service.logout();
        }
      } finally {
        _service.clearAuthState();
      }
    });
  }

  Future<Result<void>> logout() async {
    return Result.guard(_service.logout);
  }
}
