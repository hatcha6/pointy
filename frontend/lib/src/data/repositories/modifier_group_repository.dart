import '../../core/result.dart';
import '../models/modifier_group.dart';
import '../services/pos_api_service.dart';

class ModifierGroupRepository {
  ModifierGroupRepository(this._service);

  final PosApiService _service;

  Future<Result<List<ModifierGroup>>> loadGroups() async {
    return Result.guard(() async {
      final groups = <ModifierGroup>[];
      var page = 1;
      var hasMore = true;
      while (hasMore) {
        final result = await _service.fetchModifierGroups(page: page);
        groups.addAll(result.groups);
        hasMore = result.hasMore;
        page += 1;
      }
      return groups;
    });
  }

  Future<Result<ModifierGroup>> createGroup(ModifierGroupDraft draft) async {
    return Result.guard(() => _service.createModifierGroup(draft));
  }

  Future<Result<ModifierGroup>> updateGroup(
    int groupId,
    ModifierGroupDraft draft,
  ) async {
    return Result.guard(() => _service.updateModifierGroup(groupId, draft));
  }

  Future<Result<void>> deleteGroup(int groupId) async {
    return Result.guard(() => _service.deleteModifierGroup(groupId));
  }
}
