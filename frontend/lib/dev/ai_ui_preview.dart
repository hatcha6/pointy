// Dev-only preview harness for AI-generated UI (the Pointy catalog).
//
// Renders real generated surfaces through the real rendering engine — the same
// AiSurfaceHost, catalog and A2UI component payloads the backend emits — so the
// catalog can be reviewed visually instead of guessed at. No backend, no relay,
// no model: the surfaces here are hand-written A2UI, exactly as the assistant
// would produce them.
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/ai_ui_preview.dart
//
// Screens:
//   board     — every catalog item rendered from its own example data
//   answer    — a realistic analytics answer (metrics + trend + table + advice)
//   invoice   — the invoice-intake review surface
//   form      — an interactive surface; taps print the routed action
//   dark      — the answer surface in dark mode
//
// See AGENTS.md ("UI preview harness"). Not part of the shipping app.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/ai_chat.dart';
import 'package:pointy_frontend/src/features/ai/ui/ai_surface_host.dart';
import 'package:pointy_frontend/src/features/ai/ui/ai_surface_view.dart';
import 'package:pointy_frontend/src/features/ai/ui/pointy_ai_catalog.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import 'ai_ui_preview_surfaces.dart';

void main() => runApp(const _PreviewApp());

String _screen() {
  final uri = Uri.base;
  final direct = uri.queryParameters['screen'];
  if (direct != null && direct.isNotEmpty) return direct;
  final fragment = uri.fragment;
  if (fragment.contains('screen=')) {
    return Uri.splitQueryString(
          fragment.contains('?') ? fragment.split('?').last : fragment,
        )['screen'] ??
        'board';
  }
  return 'board';
}

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    final screen = _screen();
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
      theme: screen == 'dark' ? PointyTheme.dark() : PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: _PreviewHost(screen: screen),
    );
  }
}

class _PreviewHost extends StatefulWidget {
  const _PreviewHost({required this.screen});

  final String screen;

  @override
  State<_PreviewHost> createState() => _PreviewHostState();
}

class _PreviewHostState extends State<_PreviewHost> {
  final AiSurfaceHost _host = AiSurfaceHost();
  final List<AiUiSurface> _surfaces = <AiUiSurface>[];
  String _lastAction = '';

  @override
  void initState() {
    super.initState();
    _host.actions.listen((action) {
      setState(() {
        _lastAction =
            '${action.kind.name} · ${action.name} · '
            '${action.link ?? action.prompt ?? action.data}';
      });
    });
    for (final surface in _surfacesFor(widget.screen)) {
      _host.apply(surface);
      _surfaces.add(surface);
    }
  }

  List<AiUiSurface> _surfacesFor(String screen) => switch (screen) {
    'answer' || 'dark' => [analyticsAnswerSurface()],
    'invoice' => [invoiceReviewSurface()],
    'form' => [interactiveFormSurface()],
    _ => catalogBoardSurfaces(),
  };

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Scaffold(
      backgroundColor: colors.page,
      appBar: AppBar(
        title: Text('AI generated UI — ${widget.screen}'),
        backgroundColor: colors.surface,
      ),
      body: Column(
        children: [
          if (_lastAction.isNotEmpty)
            Container(
              width: double.infinity,
              color: colors.primaryContainer,
              padding: const EdgeInsets.all(10),
              child: Text(
                'action → $_lastAction',
                style: TextStyle(color: colors.primaryStrong),
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final surface in _surfaces) ...[
                        if (surface.title.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 18, bottom: 2),
                            child: Text(
                              surface.title,
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(color: colors.mutedInk),
                            ),
                          ),
                        AiSurfaceView(host: _host, surface: surface),
                      ],
                      const SizedBox(height: 40),
                      Text(
                        'catalog: ${PointyAiCatalog.itemNames.join(" · ")}',
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
