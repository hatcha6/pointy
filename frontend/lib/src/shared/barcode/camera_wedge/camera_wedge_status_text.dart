import 'package:flutter/foundation.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../formatters.dart';
import 'camera_wedge_health.dart';

/// How bad a camera status is, for the colour of the message that says it.
enum CameraWedgeStatusTone { ok, pending, problem }

/// One sentence a cashier can act on, for whatever the camera is doing.
///
/// Every fault that has a fix names it ("close the other program", "turn on
/// camera access for desktop apps"); every one that fixes itself says so,
/// because the wedge does retry on its own and a shop should not go looking
/// for a button. A refused camera is worded per [platform], because the fix
/// is: a Windows privacy switch, Linux's "video" group, or the app's camera
/// permission everywhere else. Callers pass `Theme.of(context).platform`, so
/// a preview or a test can show any platform's wording.
({String message, CameraWedgeStatusTone tone}) cameraWedgeStatusText(
  AppLocalizations l10n,
  CameraWedgeHealth health, {
  required TargetPlatform platform,
}) {
  if (health.state == CameraWedgeState.running) {
    return (message: l10n.cameraWedgeRunning, tone: CameraWedgeStatusTone.ok);
  }
  final fault = switch (health.fault) {
    CameraWedgeFault.none => null,
    CameraWedgeFault.noCamera => l10n.cameraWedgeFaultNoCamera,
    CameraWedgeFault.deviceNotFound => l10n.cameraWedgeFaultDeviceNotFound,
    CameraWedgeFault.accessDenied => _accessDenied(l10n, platform),
    CameraWedgeFault.inUse => l10n.cameraWedgeFaultInUse,
    CameraWedgeFault.deviceLost => l10n.cameraWedgeFaultDeviceLost,
    CameraWedgeFault.noUsableFormat => l10n.cameraWedgeFaultNoUsableFormat,
    CameraWedgeFault.stalled => l10n.cameraWedgeFaultStalled,
    CameraWedgeFault.platform => l10n.cameraWedgeFaultPlatform,
    CameraWedgeFault.unsupported => l10n.cameraWedgeUnsupported,
  };
  if (fault != null) {
    return (message: fault, tone: CameraWedgeStatusTone.problem);
  }
  return (
    message: l10n.cameraWedgeStarting,
    tone: CameraWedgeStatusTone.pending,
  );
}

String _accessDenied(AppLocalizations l10n, TargetPlatform platform) {
  if (kIsWeb) return l10n.cameraWedgeFaultAccessDeniedDevice;
  return switch (platform) {
    TargetPlatform.windows => l10n.cameraWedgeFaultAccessDenied,
    TargetPlatform.linux => l10n.cameraWedgeFaultAccessDeniedLinux,
    _ => l10n.cameraWedgeFaultAccessDeniedDevice,
  };
}

/// Whether a refused camera has a settings page the app can open for it:
/// Windows' "let desktop apps access your camera". Linux has none (the fix is
/// a group membership), and elsewhere the permission lives with the app.
bool cameraWedgeHasPrivacySettingsPage(TargetPlatform platform) =>
    !kIsWeb && platform == TargetPlatform.windows;

/// "1280×720 · 30 إطار/ث", or null before a camera has opened.
///
/// The resolution is isolated left-to-right: inside Arabic text the bidi
/// algorithm would otherwise lay "1280×720" out as "720×1280".
String? cameraWedgeStreamText(AppLocalizations l10n, CameraWedgeHealth health) {
  if (health.width <= 0 || health.height <= 0) return null;
  final fps = health.stats?.captureFps ?? health.fps;
  return l10n.cameraWedgeStreamDetails(
    ltrIsolated('${health.width}×${health.height}'),
    fps.toStringAsFixed(0),
  );
}
