import '../../core/result.dart';
import '../models/moamalat.dart';
import '../services/pos_api_service.dart';

/// The Moamalat link, wrapped in [Result]. A refused link step arrives as a
/// [MoamalatLinkFailure] error.
class MoamalatRepository {
  const MoamalatRepository(this._service);

  final PosApiService _service;

  Future<Result<MoamalatStatus>> loadStatus() =>
      Result.guard(() => _service.moamalat.fetchStatus());

  Future<Result<String>> startLink({
    required String username,
    required String password,
  }) => Result.guard(
    () => _service.moamalat.startLink(username: username, password: password),
  );

  Future<Result<MoamalatLinked>> verifyLink({
    required String challengeId,
    required String code,
  }) => Result.guard(
    () => _service.moamalat.verifyLink(challengeId: challengeId, code: code),
  );

  Future<Result<MoamalatStatus>> chooseMerchant(String mid) =>
      Result.guard(() => _service.moamalat.chooseMerchant(mid));

  Future<Result<MoamalatStatus>> unlink() =>
      Result.guard(() => _service.moamalat.unlink());

  Future<Result<MoamalatWatch>> watch({double? amount, Duration? lookback}) =>
      Result.guard(
        () => _service.moamalat.watch(amount: amount, lookback: lookback),
      );
}
