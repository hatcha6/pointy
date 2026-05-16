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
    try {
      return Ok(await _service.login(username: username, password: password));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<PosUser?>> loadCurrentUser() async {
    try {
      return Ok(await _service.fetchCurrentUser());
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<void>> logout() async {
    try {
      await _service.logout();
      return const Ok(null);
    } on Exception catch (exception) {
      return Error(exception);
    }
  }
}
