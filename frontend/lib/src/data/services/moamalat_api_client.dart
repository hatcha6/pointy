import 'package:http/http.dart' as http;

import '../models/moamalat.dart';
import 'api_session.dart';

/// `/api/moamalat/`: the shop's Moamalat link and live card verification.
class MoamalatApiClient {
  const MoamalatApiClient(this._session);

  final PosApiSession _session;

  Future<MoamalatStatus> fetchStatus() async {
    final response = await _session.get('moamalat/status/');
    _session.ensureSuccess(response, 'Moamalat status failed with status');
    return MoamalatStatus.fromJson(_map(response));
  }

  /// Sends the username and password; Moamalat texts an OTP. Returns the
  /// challenge id the OTP is verified against.
  Future<String> startLink({
    required String username,
    required String password,
  }) async {
    final response = await _session.post(
      'moamalat/login/',
      body: {'username': username, 'password': password},
    );
    _ensureLinkStep(response);
    return (_map(response)['challenge_id'] as String?) ?? '';
  }

  Future<MoamalatLinked> verifyLink({
    required String challengeId,
    required String code,
  }) async {
    final response = await _session.post(
      'moamalat/verify/',
      body: {'challenge_id': challengeId, 'code': code},
    );
    _ensureLinkStep(response);
    return MoamalatLinked.fromJson(_map(response));
  }

  Future<MoamalatStatus> chooseMerchant(String mid) async {
    final response = await _session.post(
      'moamalat/merchant/',
      body: {'mid': mid},
    );
    _ensureLinkStep(response);
    return MoamalatStatus.fromJson(_map(response));
  }

  Future<MoamalatStatus> unlink() async {
    final response = await _session.post('moamalat/unlink/');
    _session.ensureSuccess(response, 'Moamalat unlink failed with status');
    return MoamalatStatus.fromJson(_map(response));
  }

  /// Every swipe no payment has claimed, from [lookback] ago (a sheet asks
  /// from a while before it opened). [amount] narrows to one figure.
  Future<MoamalatWatch> watch({double? amount, Duration? lookback}) async {
    final response = await _session.post(
      'moamalat/watch/',
      body: {
        if (amount != null) 'amount': amount.toStringAsFixed(2),
        if (lookback != null) 'lookback_seconds': lookback.inSeconds,
      },
    );
    _session.ensureSuccess(response, 'Moamalat watch failed with status');
    return MoamalatWatch.fromJson(_map(response));
  }

  Map<String, Object?> _map(http.Response response) {
    final body = _session.decodedBody(response);
    return body is Map ? body.cast<String, Object?>() : const {};
  }

  void _ensureLinkStep(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }
    final body = _session.decodedBodyOrNull(response);
    if (body is Map && body['code'] is String) {
      throw MoamalatLinkFailure(
        body['code'] as String,
        (body['detail'] as String?) ?? '',
      );
    }
    throw MoamalatLinkFailure(
      response.statusCode == 403 ? 'forbidden' : 'unavailable',
    );
  }
}
