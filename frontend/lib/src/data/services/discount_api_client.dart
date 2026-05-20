import '../models/discount_rule.dart';
import 'api_session.dart';

class DiscountApiClient {
  const DiscountApiClient(this._session);

  final PosApiSession _session;

  Future<DiscountRulePage> fetchDiscountRules({
    required DiscountRuleQuery query,
    int page = 1,
  }) async {
    final response = await _session.get(
      'discount-rules/',
      query: query.toQueryParameters(page: page),
    );
    _session.throwApiException(
      response,
      'Discount rule list failed with status',
    );
    return DiscountRulePage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<DiscountRule> createDiscountRule(DiscountRuleDraft draft) async {
    final response = await _session.post(
      'discount-rules/',
      body: draft.toJson(),
    );
    _session.throwApiException(
      response,
      'Discount rule create failed with status',
    );
    return DiscountRule.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<DiscountRule> updateDiscountRule({
    required int id,
    required DiscountRuleDraft draft,
  }) async {
    final response = await _session.patch(
      'discount-rules/$id/',
      body: draft.toJson(),
    );
    _session.throwApiException(
      response,
      'Discount rule update failed with status',
    );
    return DiscountRule.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<DiscountRule> enableDiscountRule(int id) {
    return _postRuleAction(id: id, action: 'enable');
  }

  Future<DiscountRule> disableDiscountRule(int id) {
    return _postRuleAction(id: id, action: 'disable');
  }

  Future<DiscountRule> archiveDiscountRule(int id) async {
    final response = await _session.delete('discount-rules/$id/');
    _session.throwApiException(
      response,
      'Discount rule archive failed with status',
    );
    return DiscountRule.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<DiscountRule> _postRuleAction({
    required int id,
    required String action,
  }) async {
    final response = await _session.post('discount-rules/$id/$action/');
    _session.throwApiException(
      response,
      'Discount rule action failed with status',
    );
    return DiscountRule.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
