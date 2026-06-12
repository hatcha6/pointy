import '../../core/result.dart';
import '../models/fraud_finding.dart';
import '../services/pos_api_service.dart';

class FraudRepository {
  FraudRepository(this._service);

  final PosApiService _service;

  Future<Result<FraudFindingPage>> loadFindings({
    int page = 1,
    String status = '',
  }) {
    return Result.guard(
      () => _service.fetchFraudFindings(page: page, status: status),
    );
  }

  Future<Result<FraudFinding>> reviewFinding(int id, {String note = ''}) {
    return Result.guard(() => _service.reviewFraudFinding(id, note: note));
  }

  Future<Result<FraudFinding>> dismissFinding(int id, {String note = ''}) {
    return Result.guard(() => _service.dismissFraudFinding(id, note: note));
  }

  Future<Result<FraudFinding>> reopenFinding(int id) {
    return Result.guard(() => _service.reopenFraudFinding(id));
  }
}
