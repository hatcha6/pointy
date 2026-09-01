// Dev-only sweep script: settings group — my account, device settings, users
// & permissions, shop settings.
import 'common.dart';

List<SweepSurface> settingsSurfaces() => [
  screen('user_settings'),
  screen('device_settings'),
  screen('users'),
  screen('shop_settings'),
];
