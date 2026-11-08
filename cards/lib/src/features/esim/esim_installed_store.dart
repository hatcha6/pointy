import 'package:shared_preferences/shared_preferences.dart';

/// What this phone remembers about an eSIM. Nothing can ask the system whether
/// it is installed, so the page goes by the customer's word, and remembers a
/// share that went through.
class EsimInstalledStore {
  const EsimInstalledStore(this.preferences);

  final SharedPreferencesAsync? preferences;

  static String _installed(String iccid) => 'cards.esim_installed.$iccid';
  static String _sent(String iccid) => 'cards.esim_sent.$iccid';

  Future<bool> isInstalled(String iccid) async =>
      await preferences?.getBool(_installed(iccid)) ?? false;

  Future<void> setInstalled(String iccid, bool installed) async {
    await preferences?.setBool(_installed(iccid), installed);
  }

  Future<bool> wasSent(String iccid) async =>
      await preferences?.getBool(_sent(iccid)) ?? false;

  Future<void> setSent(String iccid, bool sent) async {
    await preferences?.setBool(_sent(iccid), sent);
  }
}
