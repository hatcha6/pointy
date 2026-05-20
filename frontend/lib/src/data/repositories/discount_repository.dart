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
    try {
      return Ok(await _service.fetchDiscountRules(query: query, page: page));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<DiscountRule>> createDiscountRule(
    DiscountRuleDraft draft,
  ) async {
    try {
      return Ok(await _service.createDiscountRule(draft));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<DiscountRule>> updateDiscountRule({
    required int id,
    required DiscountRuleDraft draft,
  }) async {
    try {
      return Ok(await _service.updateDiscountRule(id: id, draft: draft));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<DiscountRule>> enableDiscountRule(int id) async {
    try {
      return Ok(await _service.enableDiscountRule(id));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<DiscountRule>> disableDiscountRule(int id) async {
    try {
      return Ok(await _service.disableDiscountRule(id));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<DiscountRule>> archiveDiscountRule(int id) async {
    try {
      return Ok(await _service.archiveDiscountRule(id));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }
}
