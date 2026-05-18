import '../models/pos_user.dart';
import 'api_session.dart';

class UserApiClient {
  const UserApiClient(this._session);

  final PosApiSession _session;

  Future<List<PosUser>> fetchUsers() async {
    final response = await _session.get('users/');
    _session.ensureSuccess(response, 'Users request failed with status');
    return decodeListResponse(_session.decodedBody(response), PosUser.fromJson);
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
}
