// Dev-only preview harness for the navigation drawer/rail itself.
//
// Renders the real `AppNavigationDrawer` inside real `PointyScaffold` routes,
// pushed and replaced with the same stack rules the authenticated shell uses:
// a section is pushed over the first route and replaced afterwards, and the
// dashboard pops back to the first route. That is the arrangement in which the
// navigation's scroll offset means anything — several rails are alive at once,
// one per route on the stack — so it is the only way to see it behave.
//
// Scroll the rail, walk between screens, and read the panel: it names the route
// stack and the offset the shared store holds for each surface. The rail must
// come back to the same place every time, whichever way the screen was reached.
// Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/navigation_preview.dart
//
// Resize below 1024 to get the compact drawer instead of the rail.
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

const _user = PosUser(
  id: 1,
  username: 'manager',
  displayName: 'مدير النظام',
  role: UserRole.manager,
  isActive: true,
);

final PointyNavigationScrollStore _store = PointyNavigationScrollStore();
final PointyNavigationRailController _railController =
    PointyNavigationRailController();
final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
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
        controller: _railController,
        navigationScrollStore: _store,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const _PreviewScreen(
        destination: AppNavigationDestination.dashboard,
      ),
    );
  }
}

/// The authenticated shell's stack rules, kept in step with
/// `_AuthenticatedRoutes` in `lib/src/authenticated_home.dart`: sections are
/// pushed over the first route and replace each other afterwards, and the
/// dashboard is the first route rather than a push.
class _PreviewNavigation implements AppNavigation {
  const _PreviewNavigation();

  @override
  PosUser get currentUser => _user;

  @override
  AuthorizationCapabilities get capabilities =>
      AuthorizationCapabilities.forUser(_user);

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {
    if (destination == from) {
      return;
    }
    final navigator = Navigator.of(context);
    if (destination == AppNavigationDestination.dashboard) {
      navigator.popUntil((route) => route.isFirst);
      return;
    }
    final route = MaterialPageRoute<void>(
      builder: (_) => _PreviewScreen(destination: destination),
    );
    if (ModalRoute.of(context)?.isFirst ?? false) {
      navigator.push(route);
    } else {
      navigator.pushReplacement(route);
    }
  }

  @override
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {
    navigateTo(context, AppNavigationDestination.aiAssistant, from: from);
  }

  @override
  void logout(BuildContext context) {}
}

class _PreviewScreen extends StatelessWidget {
  const _PreviewScreen({required this.destination});

  final AppNavigationDestination destination;

  @override
  Widget build(BuildContext context) {
    final isFirst = ModalRoute.of(context)?.isFirst ?? true;
    return PointyScaffold(
      drawer: AppNavigationDrawer(
        selectedDestination: destination,
        navigation: const _PreviewNavigation(),
      ),
      appBar: PointyAppBar(
        leading: const PointyNavigationMenuButton(),
        title: Text(destination.name),
      ),
      body: Center(
        child: _OffsetPanel(destination: destination, isFirst: isFirst),
      ),
    );
  }
}

/// What the shared store holds, refreshed on a timer: the rail's place is
/// meant to be one number the whole app agrees on, so seeing it next to the
/// rail is the whole point of this harness.
class _OffsetPanel extends StatefulWidget {
  const _OffsetPanel({required this.destination, required this.isFirst});

  final AppNavigationDestination destination;
  final bool isFirst;

  @override
  State<_OffsetPanel> createState() => _OffsetPanelState();
}

class _OffsetPanelState extends State<_OffsetPanel> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.destination.name,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            Text(
              widget.isFirst ? 'first route' : 'pushed over the first route',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
            const Divider(height: 32),
            for (final kind in PointyNavigationSurfaceKind.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${kind.name}: ${_store.offsetOf(kind).toStringAsFixed(1)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
