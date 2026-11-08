import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../data/repositories/esim_repository.dart';

/// What the phone itself says about eSIMs.
class EsimDeviceFacts {
  const EsimDeviceFacts({
    required this.platform,
    required this.model,
    required this.osVersion,
    required this.supportsEsim,
    required this.simulator,
    required this.directInstall,
  });

  /// A build with no phone under it (the web, a desktop).
  static const none = EsimDeviceFacts(
    platform: '',
    model: '',
    osVersion: '',
    supportsEsim: false,
    simulator: false,
    directInstall: false,
  );

  final String platform;
  final String model;
  final String osVersion;

  /// The system's own word. On Android it is reliable when true; on iPhone it
  /// is a hint, so the model's check counts too.
  final bool supportsEsim;
  final bool simulator;

  /// The system can install from a link: iOS 17.4+, Android 10+.
  final bool directInstall;

  bool get isPhone => platform.isNotEmpty;
  bool get isIos => platform == 'ios';
  bool get isAndroid => platform == 'android';
}

/// The native side of eSIMs (EsimBridge.swift, MainActivity.kt).
class EsimDevice {
  const EsimDevice();

  static const _channel = MethodChannel('ly.dftr.cards/esim');

  Future<EsimDeviceFacts> facts() async {
    if (kIsWeb) {
      return EsimDeviceFacts.none;
    }
    try {
      final answer = await _channel.invokeMapMethod<String, dynamic>('device');
      if (answer == null) {
        return EsimDeviceFacts.none;
      }
      return EsimDeviceFacts(
        platform: answer['platform'] as String? ?? '',
        model: answer['model'] as String? ?? '',
        osVersion: answer['os_version'] as String? ?? '',
        supportsEsim: answer['supports_esim'] == true,
        simulator: answer['simulator'] == true,
        directInstall: answer['direct_install'] == true,
      );
    } on PlatformException {
      return EsimDeviceFacts.none;
    } on MissingPluginException {
      return EsimDeviceFacts.none;
    }
  }

  /// Opens the system's own install sheet. False when nothing took the link.
  Future<bool> install(String url) async {
    try {
      return await _channel.invokeMethod<bool>('install', {'url': url}) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// Whether this phone takes eSIMs, as well as can be told.
enum EsimSupport {
  /// It does.
  yes,

  /// It looks as if it does not. Never a refusal: the customer may know better,
  /// and may be buying for someone else.
  no,

  /// Nobody can tell: the web, no connection, a phone the sources disagree on.
  unknown,
}

/// The verdict, from what the phone says and what Airalo's list says.
///
/// | Phone says | Model check             | Verdict                        |
/// | ---------- | ----------------------- | ------------------------------ |
/// | yes        | anything                | yes                            |
/// | no         | supported               | iPhone: yes (its word is a     |
/// |            |                         | hint); Android: unknown (the   |
/// |            |                         | maker or carrier may disable   |
/// |            |                         | it on this very unit)          |
/// | no         | not supported           | no                             |
/// | no         | no answer               | unknown                        |
EsimSupport esimSupportOf(EsimDeviceFacts facts, EsimModelCheck? check) {
  if (!facts.isPhone || facts.simulator) {
    return EsimSupport.unknown;
  }
  if (facts.supportsEsim) {
    return EsimSupport.yes;
  }
  if (check == null) {
    return EsimSupport.unknown;
  }
  if (check.supported) {
    return facts.isIos ? EsimSupport.yes : EsimSupport.unknown;
  }
  return EsimSupport.no;
}

/// What the eSIM pages know about this phone, read once per launch.
class EsimCompatibility {
  EsimCompatibility({required this.repository, EsimDevice? device})
    : device = device ?? const EsimDevice();

  final EsimRepository repository;
  final EsimDevice device;

  EsimDeviceFacts facts = EsimDeviceFacts.none;
  final ValueNotifier<EsimSupport> support = ValueNotifier(EsimSupport.unknown);

  Future<void>? _loading;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    facts = await device.facts();
    if (!facts.isPhone || facts.simulator) {
      support.value = EsimSupport.unknown;
      return;
    }
    // The phone's own yes counts at once; the list only adds to a no.
    if (facts.supportsEsim) {
      support.value = EsimSupport.yes;
      return;
    }
    final check = facts.model.isEmpty
        ? null
        : await repository.checkModel(facts.model);
    support.value = esimSupportOf(facts, check);
    if (check == null) {
      // No answer now: ask again next time a page opens.
      _loading = null;
    }
  }
}
