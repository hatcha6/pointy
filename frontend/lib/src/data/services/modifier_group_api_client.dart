import '../models/modifier_group.dart';
import 'api_session.dart';

class ModifierGroupApiClient {
  const ModifierGroupApiClient(this._session);

  final PosApiSession _session;

  Future<ModifierGroupPage> fetchModifierGroups({int page = 1}) async {
    final response = await _session.get(
      'modifier-groups/',
      query: {'page': '$page'},
      conditionalCache: true, // rides the catalog-version ETag
    );
    _session.ensureSuccess(
      response,
      'Modifier groups request failed with status',
    );
    return ModifierGroupPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<ModifierGroup> createModifierGroup(ModifierGroupDraft draft) async {
    final response = await _session.post(
      'modifier-groups/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Modifier group create failed with status',
    );
    return ModifierGroup.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<ModifierGroup> updateModifierGroup(
    int groupId,
    ModifierGroupDraft draft,
  ) async {
    final response = await _session.patch(
      'modifier-groups/$groupId/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Modifier group update failed with status',
    );
    return ModifierGroup.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> deleteModifierGroup(int groupId) async {
    final response = await _session.delete('modifier-groups/$groupId/');
    _session.ensureSuccess(
      response,
      'Modifier group delete failed with status',
    );
  }
}
