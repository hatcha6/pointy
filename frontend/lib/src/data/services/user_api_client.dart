import '../models/permission_catalog.dart';
import '../models/pos_user.dart';
import '../models/user_activity.dart';
import 'api_session.dart';

class UserApiClient {
  const UserApiClient(this._session);

  final PosApiSession _session;

  Future<PosUserPage> fetchUsers({
    int page = 1,
    String search = '',
    String role = '',
  }) async {
    final response = await _session.get(
      'users/',
      query: {
        'page': '$page',
        if (search.trim().isNotEmpty) 'search': search.trim(),
        if (role.trim().isNotEmpty) 'groups__name': role.trim(),
      },
    );
    _session.ensureSuccess(response, 'Users request failed with status');
    return PosUserPage.fromAny(_session.decodedBody(response));
  }

  Future<PermissionCatalog> fetchPermissionCatalog() async {
    final response = await _session.get('users/permission-catalog/');
    _session.ensureSuccess(
      response,
      'Permission catalog request failed with status',
    );
    return PermissionCatalog.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PosUser> createUser(UserCreateDraft draft) async {
    final response = await _session.post('users/', body: draft.toJson());
    _session.ensureSuccess(response, 'User create failed with status');
    return PosUser.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PosUser> updateUser({
    required int id,
    required UserUpdateDraft draft,
  }) async {
    final response = await _session.patch('users/$id/', body: draft.toJson());
    _session.ensureSuccess(response, 'User update failed with status');
    return PosUser.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<UserActivityOverview> fetchUserActivity(int id) async {
    final response = await _session.get('users/$id/activity/');
    _session.ensureSuccess(
      response,
      'User activity request failed with status',
    );
    return UserActivityOverview.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
