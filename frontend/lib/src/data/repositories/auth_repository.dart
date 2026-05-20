import '../../core/result.dart';
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

  Future<Result<void>> logout() async {
    return Result.guard(_service.logout);
  }
}
