// Dev-only preview harness for the counter camera's UI: the F8 preview panel
// and the camera section of device settings.
//
// Renders the real widgets over a fake camera source that paints its own
// frames (a label with bars on a grey counter), with no native library, no
// backend and no auth. Pick the surface with `?screen=`:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/camera_wedge_preview.dart
//
// Screens: board | panel | settings
//
// `board` lays every state out at once for a single screenshot (size the
// viewport large so Flutter paints it all); `panel` is the F8 panel floating
// over a till-like screen, at the viewport's real size. See AGENTS.md ("UI
// preview harness"). Not part of the shipping app. Safe to delete.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/features/device_settings/views/camera_wedge_settings_panel.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_controller.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_health.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_policy.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_preview_panel.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_scope.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_source.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/responsive/responsive.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: cameraWedgePreviewSurface(_selectedScreen()),
    );
  }
}

/// One preview surface by name. Public so the headless capture test
/// (test/screens/camera_wedge_capture_test.dart) renders the same states the
/// browser shows.
Widget cameraWedgePreviewSurface(String screen) => switch (screen) {
  'panel' => const _PanelOverTill(),
  'settings' => const _SettingsStates(),
  _ => const _Board(),
};

String _selectedScreen() {
  final uri = Uri.base;
  return uri.queryParameters['screen'] ??
      Uri.tryParse(
        uri.fragment.startsWith('/') ? uri.fragment.substring(1) : uri.fragment,
      )?.queryParameters['screen'] ??
      'board';
}

const _lastScan = CameraWedgeScan(
  value: '3600523434725',
  symbology: 'EAN13',
  confirmations: 2,
);

const _running = CameraWedgeHealth(
  state: CameraWedgeState.running,
  deviceLabel: 'HUE HD Pro camera',
  width: 1280,
  height: 720,
  fps: 30,
  pixelFormat: 'MJPG>NV12',
  stats: CameraWedgeStats(captureFps: 29.8, decodeMilliseconds: 9.4),
  lastScan: _lastScan,
);

/// A camera that paints its own frames: a white label with bars on a grey
/// counter, drifting a little so the preview visibly lives.
class _FakeCamera implements CameraWedgeSource {
  _FakeCamera(CameraWedgeHealth health, {this.painting = true})
    : _health = ValueNotifier(health);

  final bool painting;
  final ValueNotifier<CameraWedgeHealth> _health;
  final _preview = ValueNotifier<CameraWedgePreviewFrame?>(null);
  Timer? _timer;
  int _tick = 0;

  @override
  Stream<CameraWedgeScan> get scans => const Stream.empty();

  @override
  ValueListenable<CameraWedgeHealth> get health => _health;

  @override
  ValueListenable<CameraWedgePreviewFrame?> get preview => _preview;

  @override
  bool get supportsPreview => true;

  @override
  void setPreviewEnabled(bool enabled) {
    _timer?.cancel();
    _timer = null;
    if (!enabled || !painting) return;
    _preview.value = _frame();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _tick += 1;
      _preview.value = _frame();
    });
  }

  CameraWedgePreviewFrame _frame() {
    const width = 480;
    const height = 270;
    final luma = Uint8List(width * height);
    final random = math.Random(_tick);
    final shift = (math.sin(_tick / 8) * 6).round();
    // Bars for the eye only, one module per character: nothing decodes them
    // here (the native tests decode real, zxing-drawn codes).
    const bars =
        '10100010110111001001110101100010100011010001101010100001011100101'
        '0010001110100101110010001001101010011101001000101';
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        var value = 110 + (x + y) ~/ 12;
        final lx = x - 130 - shift;
        final ly = y - 70;
        if (lx >= 0 && lx < 220 && ly >= 0 && ly < 130) {
          value = 232;
          final module = (lx - 12) ~/ 2;
          if (ly >= 12 &&
              ly < 110 &&
              module >= 0 &&
              module < bars.length &&
              bars[module] == '1') {
            value = 28;
          }
        }
        luma[y * width + x] = (value + random.nextInt(9) - 4).clamp(0, 255);
      }
    }
    return CameraWedgePreviewFrame(width: width, height: height, luma: luma);
  }

  @override
  Future<List<CameraWedgeDevice>> devices() async => const [];

  @override
  Future<void> start({String? deviceId}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async => _timer?.cancel();
}

/// One controller per state, made once: a build must not start a new fake
/// camera (and its frame timer) every time it runs.
final _controllers = <(CameraWedgeHealth, bool), CameraWedgeController>{};

CameraWedgeController _controller(
  CameraWedgeHealth health, {
  bool painting = true,
}) => _controllers.putIfAbsent(
  (health, painting),
  () => CameraWedgeController(source: _FakeCamera(health, painting: painting)),
);

/// Every state at once, at a till's and a phone's width.
class _Board extends StatelessWidget {
  const _Board();

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    Widget panel(String title, CameraWedgeHealth health, {bool paint = true}) =>
        _Labelled(
          title: title,
          child: SizedBox(
            width: 380,
            child: CameraWedgePreviewPanel(
              controller: _controller(health, painting: paint),
              onClose: () {},
            ),
          ),
        );
    return Scaffold(
      backgroundColor: context.pointyColors.page,
      body: SingleChildScrollView(
        padding: EdgeInsets.all(spacing.lg),
        child: Wrap(
          spacing: spacing.lg,
          runSpacing: spacing.lg,
          children: [
            panel('F8: running', _running),
            panel(
              'F8: privacy blocks it',
              const CameraWedgeHealth(
                state: CameraWedgeState.recovering,
                fault: CameraWedgeFault.accessDenied,
                retryIn: Duration(seconds: 5),
              ),
              paint: false,
            ),
            panel(
              'F8: starting',
              const CameraWedgeHealth(state: CameraWedgeState.starting),
              paint: false,
            ),
            for (final (title, health) in _settingsCases)
              _Labelled(
                title: 'Settings: $title',
                child: SizedBox(width: 520, child: _SettingsSection(health)),
              ),
          ],
        ),
      ),
    );
  }
}

const _settingsCases = [
  ('running', _running),
  (
    'privacy',
    CameraWedgeHealth(
      state: CameraWedgeState.recovering,
      fault: CameraWedgeFault.accessDenied,
    ),
  ),
  (
    'in use',
    CameraWedgeHealth(
      state: CameraWedgeState.recovering,
      fault: CameraWedgeFault.inUse,
    ),
  ),
  (
    'substituted',
    CameraWedgeHealth(
      state: CameraWedgeState.running,
      deviceLabel: 'Integrated Webcam',
      substitutedDevice: true,
      width: 640,
      height: 480,
      fps: 30,
    ),
  ),
];

class _SettingsStates extends StatelessWidget {
  const _SettingsStates();

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return Scaffold(
      backgroundColor: context.pointyColors.page,
      body: ListView(
        padding: EdgeInsets.all(spacing.lg),
        children: [
          for (final (title, health) in _settingsCases) ...[
            _Labelled(title: title, child: _SettingsSection(health)),
            SizedBox(height: spacing.lg),
          ],
        ],
      ),
    );
  }
}

/// The camera section as device settings shows it once the switch is on.
class _SettingsSection extends StatelessWidget {
  const _SettingsSection(this.health);

  final CameraWedgeHealth health;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CameraWedgeScope(
      controller: _controller(health, painting: health.isRunning),
      child: PointyDetailSection(
        icon: Icons.photo_camera_outlined,
        title: l10n.cameraWedgeSectionTitle,
        child: const CameraWedgeSettingsStatus(),
      ),
    );
  }
}

/// The F8 panel where it floats in the real app: over the till, bottom
/// start corner.
class _PanelOverTill extends StatelessWidget {
  const _PanelOverTill();

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Scaffold(
      backgroundColor: colors.page,
      appBar: AppBar(title: const Text('نقطة البيع')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = (constraints.maxWidth * 0.28).clamp(300.0, 460.0);
          return Stack(
            children: [
              GridView.count(
                crossAxisCount: (constraints.maxWidth / 180).floor().clamp(
                  2,
                  8,
                ),
                padding: const EdgeInsets.all(16),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                children: [
                  for (var i = 0; i < 24; i++)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(PointyRadii.card),
                        border: Border.all(color: colors.line),
                      ),
                    ),
                ],
              ),
              PositionedDirectional(
                start: 16,
                bottom: 16,
                width: width,
                child: CameraWedgePreviewPanel(
                  controller: _controller(_running),
                  onClose: () {},
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Labelled extends StatelessWidget {
  const _Labelled({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}
