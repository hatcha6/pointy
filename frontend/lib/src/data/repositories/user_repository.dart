import '../../core/result.dart';
import '../models/pos_user.dart';
import '../services/pos_api_service.dart';

class UserRepository {
  UserRepository(this._service);

  final PosApiService _service;

  Future<Result<List<PosUser>>> loadUsers() async {
    return Result.guard(_service.fetchUsers);
  }

  Future<Result<PosUser>> createUser(UserCreateDraft draft) async {
    return Result.guard(() => _service.createUser(draft));
  }

  Future<Result<PosUser>> updateUser({
    required int id,
    required UserUpdateDraft draft,
  }) async {
    return Result.guard(() => _service.updateUser(id: id, draft: draft));
  }
}
