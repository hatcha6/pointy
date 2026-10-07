// Dev-only preview harness for the "update ready" dialog a till shows right
// after its backend is updated.
//
// No backend: the manifest, the download and the installer are all faked.
// Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/app_update_preview.dart
//
// Screens (`?screen=`):
//   board    — every state side by side: the offer, downloading, opening the
//              installer, a failed download, and the "later" reminder.
//   live     — the real flow over a stand-in screen: the prompter finds the
//              build, the dialog opens on its own, and "update now" runs a fake
//              download. Reload to see it again.
// Add `&theme=dark` for the dark palette.
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/services/client_update_service.dart';
import 'package:pointy_frontend/src/features/app_updates/view_models/app_update_prompter.dart';
import 'package:pointy_frontend/src/features/app_updates/views/app_update_dialog.dart';
import 'package:pointy_frontend/src/features/app_updates/views/app_update_dialog_views.dart';
import 'package:pointy_frontend/src/features/app_updates/views/app_update_prompt_host.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() => runApp(const _PreviewApp());

const _offer = AppUpdateOffer(
  currentVersion: '0.7.9',
  release: ClientRelease(
    version: '0.8.0',
    file: 'pointy-0.8.0-android-universal.apk',
    sha256: '',
    size: 79 * 1024 * 1024 + 512 * 1024,
    url: '/clients/files/pointy-0.8.0-android-universal.apk',
  ),
);

String _param(String name, String fallback) {
  final uri = Uri.base;
  final direct = uri.queryParameters[name];
  if (direct != null) return direct;
  final fragment = uri.fragment;
  final parsed = Uri.tryParse(
    fragment.startsWith('/') ? fragment.substring(1) : fragment,
  );
  return parsed?.queryParameters[name] ?? fallback;
}

class _PreviewApp extends StatefulWidget {
  const _PreviewApp();

  @override
  State<_PreviewApp> createState() => _PreviewAppState();
}

class _PreviewAppState extends State<_PreviewApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _calm = ValueNotifier<bool>(true);
  late final AppUpdatePrompter _prompter = AppUpdatePrompter(
    check: () async => ClientUpdateStatus(
      currentVersion: _offer.currentVersion,
      platform: ClientPlatform.android,
      available: _offer.release,
    ),
    serverVersion: ValueNotifier<String?>('0.8.0'),
    loadPostponed: () async => null,
    savePostponed: (_) async {},
  );
  final String _screen = _param('screen', 'board');

  @override
  void initState() {
    super.initState();
    if (_screen == 'live') {
      _prompter.start();
    }
  }

  @override
  void dispose() {
    _prompter.dispose();
    _calm.dispose();
    super.dispose();
  }

  /// A download that takes about four seconds, then the installer "opens".
  static Future<void> _fakeInstall(
    ClientRelease release,
    void Function(double progress) onProgress,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 900));
    for (var step = 1; step <= 60; step += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      onProgress(step / 60);
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  @override
  Widget build(BuildContext context) {
    final dark = _param('theme', 'light') == 'dark';
    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: dark ? PointyTheme.dark() : PointyTheme.light(),
      builder: (context, child) => AppUpdatePromptHost(
        prompter: _prompter,
        navigatorKey: _navigatorKey,
        canPrompt: () => _calm.value,
        promptConditions: _calm,
        install: _fakeInstall,
        child: child ?? const SizedBox.shrink(),
      ),
      home: _screen == 'live' ? const _StandInScreen() : const _Board(),
    );
  }
}

/// Something for the dialog to sit over.
class _StandInScreen extends StatelessWidget {
  const _StandInScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('نقطة البيع')),
      body: const Center(child: Icon(Icons.point_of_sale, size: 96)),
    );
  }
}

class _Board extends StatelessWidget {
  const _Board();

  @override
  Widget build(BuildContext context) {
    final frames = <(String, Widget)>[
      (
        'offer',
        AppUpdateOfferView(
          offer: _offer,
          installing: false,
          failed: false,
          progress: 0,
          onUpdate: () {},
          onLater: () {},
        ),
      ),
      (
        'starting',
        AppUpdateOfferView(
          offer: _offer,
          installing: true,
          failed: false,
          progress: 0,
          onUpdate: () {},
          onLater: () {},
        ),
      ),
      (
        'downloading 42%',
        AppUpdateOfferView(
          offer: _offer,
          installing: true,
          failed: false,
          progress: 0.42,
          onUpdate: () {},
          onLater: () {},
        ),
      ),
      (
        'opening installer',
        AppUpdateOfferView(
          offer: _offer,
          installing: true,
          failed: false,
          progress: 1,
          onUpdate: () {},
          onLater: () {},
        ),
      ),
      (
        'failed',
        AppUpdateOfferView(
          offer: _offer,
          installing: false,
          failed: true,
          progress: 0,
          onUpdate: () {},
          onLater: () {},
        ),
      ),
      (
        'later → reminder',
        AppUpdateReminderView(
          version: _offer.release.version,
          onDismiss: () {},
        ),
      ),
    ];

    return Scaffold(
      backgroundColor: context.pointyColors.page,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Wrap(
          spacing: 24,
          runSpacing: 24,
          children: [
            for (final (label, view) in frames)
              _Frame(label: label, child: view),
          ],
        ),
      ),
    );
  }
}

/// A phone-sized window with the scrim, so each state reads as it would on a
/// till.
class _Frame extends StatelessWidget {
  const _Frame({required this.label, required this.child});

  final String label;
  final Widget child;

  static const _size = Size(400, 640);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Directionality(
          textDirection: TextDirection.ltr,
          child: Text(label, style: Theme.of(context).textTheme.labelLarge),
        ),
        const SizedBox(height: 6),
        SizedBox.fromSize(
          size: _size,
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(size: _size, padding: EdgeInsets.zero),
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const _StandInScreen(),
                  const ColoredBox(color: Colors.black54),
                  AppUpdateDialogFrame(child: child),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
