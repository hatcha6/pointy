import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../data/repositories/price_checker_repository.dart';
import '../../data/services/auto_start_service.dart';
import '../../shared/price_checker/price_checker_mode_controller.dart';
import 'views/price_checker_setup_dialog.dart';

/// Enters price-checker (kiosk) mode. Re-enters immediately when the device is
/// already configured (just flip the flag — no PIN needed to *enter*), otherwise
/// runs first-time setup. Shared by the login-screen entry and Device Settings
/// so both paths self-register to the fleet and toggle auto-start identically.
Future<void> enterPriceCheckerMode(
  BuildContext context, {
  required PriceCheckerModeController controller,
  required PriceCheckerRepository repository,
}) async {
  if (controller.isConfigured) {
    await controller.enter();
    return;
  }
  final setup = await showPriceCheckerSetupDialog(
    context,
    initialName: controller.config.deviceName,
    initialLocation: controller.config.location,
  );
  if (setup == null) {
    return;
  }
  await applyPriceCheckerSetup(
    controller: controller,
    repository: repository,
    setup: setup,
  );
}

/// Applies a [PriceCheckerSetupResult]: persist + enable kiosk mode, then
/// best-effort announce to the fleet and (on Windows) turn on auto-start.
Future<void> applyPriceCheckerSetup({
  required PriceCheckerModeController controller,
  required PriceCheckerRepository repository,
  required PriceCheckerSetupResult setup,
}) async {
  await controller.configureAndEnable(
    pin: setup.pin,
    deviceName: setup.deviceName,
    location: setup.location,
  );
  unawaited(
    repository.selfRegister(
      identifier: controller.config.identifier,
      name: setup.deviceName,
      location: setup.location,
    ),
  );
  if (setup.autoStart) {
    unawaited(const AutoStartService().setEnabled(true));
  }
}
