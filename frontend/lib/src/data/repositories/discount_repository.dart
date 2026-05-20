import '../../core/result.dart';
import '../models/discount_rule.dart';
import '../services/pos_api_service.dart';

class DiscountRepository {
  const DiscountRepository(this._service);

  final PosApiService _service;

  Future<Result<DiscountRulePage>> loadDiscountRules({
    required DiscountRuleQuery query,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchDiscountRules(query: query, page: page),
    );
  }

  Future<Result<DiscountRule>> createDiscountRule(
    DiscountRuleDraft draft,
  ) async {
    return Result.guard(() => _service.createDiscountRule(draft));
  }

  Future<Result<DiscountRule>> updateDiscountRule({
    required int id,
    required DiscountRuleDraft draft,
  }) async {
    return Result.guard(
      () => _service.updateDiscountRule(id: id, draft: draft),
    );
  }

  Future<Result<DiscountRule>> enableDiscountRule(int id) async {
    return Result.guard(() => _service.enableDiscountRule(id));
  }

  Future<Result<DiscountRule>> disableDiscountRule(int id) async {
    return Result.guard(() => _service.disableDiscountRule(id));
  }

  Future<Result<DiscountRule>> archiveDiscountRule(int id) async {
    return Result.guard(() => _service.archiveDiscountRule(id));
  }
}
