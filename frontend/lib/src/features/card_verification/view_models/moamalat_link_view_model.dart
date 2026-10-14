import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/moamalat.dart';
import '../../../data/repositories/moamalat_repository.dart';

/// Where the supervisor is in linking the account.
enum MoamalatLinkStep {
  /// Enter the username and password.
  credentials,

  /// Moamalat texted an OTP to the merchant's phone; enter it.
  code,
}

/// The shop's Moamalat link: status, the two-step OTP link, the merchant
/// choice, and unlinking. The password is sent once and never kept here.
class MoamalatLinkViewModel extends ChangeNotifier {
  MoamalatLinkViewModel(this._repository);

  final MoamalatRepository _repository;

  MoamalatStatus? status;
  bool isLoading = false;
  bool isBusy = false;
  bool hasLoadError = false;
  MoamalatLinkStep step = MoamalatLinkStep.credentials;
  MoamalatLinkFailure? failure;

  /// The merchants the account may use, as of the last link. More than one
  /// is a choice to offer.
  List<MoamalatMerchant> merchants = const [];
  String _challengeId = '';

  Future<void> load() async {
    isLoading = true;
    hasLoadError = false;
    notifyListeners();
    final result = await _repository.loadStatus();
    isLoading = false;
    switch (result) {
      case Ok(:final value):
        status = value;
      case Error():
        hasLoadError = true;
    }
    notifyListeners();
  }

  Future<bool> startLink({
    required String username,
    required String password,
  }) async {
    final result = await _busy(
      () => _repository.startLink(username: username, password: password),
    );
    if (result case Ok(:final value)) {
      _challengeId = value;
      step = MoamalatLinkStep.code;
      notifyListeners();
      return true;
    }
    return false;
  }

  Future<bool> verify(String code) async {
    final result = await _busy(
      () => _repository.verifyLink(challengeId: _challengeId, code: code),
    );
    if (result case Ok(:final value)) {
      status = value.status;
      merchants = value.merchants;
      step = MoamalatLinkStep.credentials;
      _challengeId = '';
      notifyListeners();
      return true;
    }
    // An expired challenge cannot be retried: start again.
    if (failure?.code == 'challenge_expired') {
      step = MoamalatLinkStep.credentials;
      notifyListeners();
    }
    return false;
  }

  void cancelCode() {
    step = MoamalatLinkStep.credentials;
    _challengeId = '';
    failure = null;
    notifyListeners();
  }

  Future<bool> chooseMerchant(String mid) async {
    final result = await _busy(() => _repository.chooseMerchant(mid));
    if (result case Ok(:final value)) {
      status = value;
      notifyListeners();
      return true;
    }
    return false;
  }

  Future<bool> unlink() async {
    final result = await _busy(_repository.unlink);
    if (result case Ok(:final value)) {
      status = value;
      merchants = const [];
      notifyListeners();
      return true;
    }
    return false;
  }

  Future<Result<T>> _busy<T>(Future<Result<T>> Function() run) async {
    isBusy = true;
    failure = null;
    notifyListeners();
    final result = await run();
    isBusy = false;
    if (result case Error(exception: final error)) {
      failure = error is MoamalatLinkFailure
          ? error
          : const MoamalatLinkFailure('unavailable');
    }
    notifyListeners();
    return result;
  }
}
