import 'dart:async';

import 'package:pointy_frontend/src/data/repositories/companion_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/companion/companion_bridge.dart';

/// A paired phone, reduced to the one thing a screen uses it for: a stream of
/// scans. Nothing here talks to a backend, so a screen test can hand itself a
/// phone scan without standing up a transport.
class FakeCompanionBridge extends CompanionBridge {
  FakeCompanionBridge()
    : super(
        repository: CompanionRepository(PosApiService()),
        tillKey: 'test-till',
      );

  final _scans = StreamController<String>.broadcast();

  @override
  Stream<String> get scans => _scans.stream;

  void emitScan(String value) => _scans.add(value);

  @override
  void dispose() {
    _scans.close();
    super.dispose();
  }
}
