import '../../core/result.dart';
import '../models/pos_user.dart';
import '../models/user_activity.dart';
import '../services/pos_api_service.dart';

class UserRepository {
  UserRepository(this._service);

  final PosApiService _service;

  Future<Result<PosUserPage>> loadUsers({
    int page = 1,
    String search = '',
  }) async {
    return Result.guard(() => _service.fetchUsers(page: page, search: search));
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

  Future<Result<UserActivityOverview>> loadUserActivity(int id) async {
    return Result.guard(() => _service.fetchUserActivity(id));
  }
}
