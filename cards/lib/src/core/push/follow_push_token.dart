import '../result.dart';
import '../../dependencies.dart';

/// Keeps the relay told where this device takes notifications while a
/// customer is signed in: the token once they sign in with notifications on,
/// a new one when Firebase replaces it, nothing ("") once they turn them off.
/// That is how the company's console reaches one customer's phones.
void followPushToken(CardsDependencies dependencies) {
  final push = dependencies.push;
  if (!push.available) {
    return;
  }
  final session = dependencies.auth.session;
  // What the relay was last told, for which session.
  String? toldSession;
  String? told;
  var running = false;
  var again = false;

  Future<void> sync() async {
    if (running) {
      again = true;
      return;
    }
    running = true;
    try {
      do {
        again = false;
        final current = session.value?.sessionId;
        if (current == null) {
          toldSession = told = null;
          continue;
        }
        final token = push.enabled ? await push.deviceToken() ?? '' : '';
        if (current == toldSession && token == told) {
          continue;
        }
        final result = await dependencies.auth.registerPushToken(token);
        if (result is Ok && session.value?.sessionId == current) {
          toldSession = current;
          told = token;
        }
      } while (again);
    } finally {
      running = false;
    }
  }

  session.addListener(sync);
  push.addListener(sync);
  push.tokenChanges.listen((_) {
    // Firebase replaced it: tell the relay the new one.
    told = null;
    sync();
  });
  sync();
}
