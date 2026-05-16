import '../../core/result.dart';
import '../models/pos_user.dart';
import '../services/pos_api_service.dart';

class UserRepository {
  UserRepository(this._service);

  final PosApiService _service;

  Future<Result<List<PosUser>>> loadUsers() async {
    try {
      return Ok(await _service.fetchUsers());
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<PosUser>> createUser(UserCreateDraft draft) async {
    try {
      return Ok(await _service.createUser(draft));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<PosUser>> updateUser({
    required int id,
    required UserUpdateDraft draft,
  }) async {
    try {
      return Ok(await _service.updateUser(id: id, draft: draft));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }
}
