// Dev-only preview harness for the global command palette.
//
// Mounts the CommandPaletteScope over a stub home with the navigation drawer,
// and auto-opens the palette so it can be screenshotted. Also reachable via the
// on-screen button, the drawer's "search" tile, or Ctrl/⌘+K. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/command_palette_preview.dart
//
// Not part of the shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/command_palette/command_palette.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

final PosUser _managerUser = PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'role': 'manager',
  'permissions': <String>[],
});

final AppNavigation _navigation = _FakeNavigation();

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
      home: CommandPaletteScope(
        key: commandPaletteScopeKey,
        sources: [
          _fakeActionsSource(),
          RecentsCommandSource(
            label: 'المفتوحة مؤخرًا',
            onOpen: (context, entry) => ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('open ${entry.title}'))),
          ),
          NavigationCommandSource(_navigation),
          _fakeProductSource(),
        ],
        child: const _PreviewHome(),
      ),
    );
  }
}

class _PreviewHome extends StatefulWidget {
  const _PreviewHome();

  @override
  State<_PreviewHome> createState() => _PreviewHomeState();
}

class _PreviewHomeState extends State<_PreviewHome> {
  @override
  void initState() {
    super.initState();
    // Auto-open so the harness lands directly on the palette.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        openCommandPalette();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: AppNavigationDrawer(
        selectedDestination: AppNavigationDestination.dashboard,
        navigation: _navigation,
      ),
      appBar: AppBar(
        title: const Text('Command Palette Preview'),
        actions: [
          IconButton(
            tooltip: 'Open palette',
            onPressed: openCommandPalette,
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      body: Center(
        child: FilledButton.icon(
          onPressed: openCommandPalette,
          icon: const Icon(Icons.search),
          label: const Text('افتح لوحة الأوامر (Ctrl/⌘ + K)'),
        ),
      ),
    );
  }
}

typedef _FakeProduct = ({String name, String price, String barcode});

const List<_FakeProduct> _fakeProducts = [
  (name: 'قهوة عربية', price: '12.50 د.ل', barcode: '6291000000017'),
  (name: 'شاي أخضر', price: '8.00 د.ل', barcode: '6291000000024'),
  (name: 'سكر ناعم 1كغ', price: '3.25 د.ل', barcode: '6291000000031'),
  (name: 'حليب طازج 1ل', price: '2.75 د.ل', barcode: '6291000000048'),
];

AsyncCommandSource<_FakeProduct> _fakeProductSource() {
  return AsyncCommandSource<_FakeProduct>(
    labelBuilder: (l10n) => l10n.commandPaletteProductsSection,
    fetch: (query) async {
      // Simulate a backend round-trip so the loading bar is visible.
      await Future<void>.delayed(const Duration(milliseconds: 220));
      return _fakeProducts
          .where(
            (product) =>
                product.name.contains(query) || product.barcode.contains(query),
          )
          .toList();
    },
    toItem: (product) => CommandItem(
      id: 'fake-${product.barcode}',
      icon: Icons.inventory_2_outlined,
      title: product.name,
      subtitle: '8 في المخزون · ${product.barcode}',
      trailing: product.price,
      recent: RecentEntry(
        kind: RecentKind.product,
        id: product.barcode.hashCode,
        title: product.name,
        subtitle: product.barcode,
        trailing: product.price,
      ),
      actions: [
        CommandRowAction(
          icon: Icons.print_outlined,
          tooltip: 'طباعة الملصق',
          onRun: (ctx) => ScaffoldMessenger.of(
            ctx,
          ).showSnackBar(SnackBar(content: Text('print ${product.name}'))),
        ),
        CommandRowAction(
          icon: Icons.add_shopping_cart_outlined,
          tooltip: 'إعادة الطلب',
          onRun: (ctx) => ScaffoldMessenger.of(
            ctx,
          ).showSnackBar(SnackBar(content: Text('reorder ${product.name}'))),
        ),
      ],
      onSelect: (ctx) => ScaffoldMessenger.of(
        ctx,
      ).showSnackBar(SnackBar(content: Text('open ${product.name}'))),
    ),
  );
}

StaticCommandSource _fakeActionsSource() {
  return StaticCommandSource(
    label: 'إجراءات سريعة',
    items: [
      CommandItem(
        id: 'action-new-sale',
        icon: Icons.point_of_sale_outlined,
        title: 'بيع جديد',
        onSelect: (ctx) => ScaffoldMessenger.of(
          ctx,
        ).showSnackBar(const SnackBar(content: Text('new sale'))),
      ),
      CommandItem(
        id: 'action-new-po',
        icon: Icons.add_shopping_cart_outlined,
        title: 'أمر شراء جديد',
        onSelect: (ctx) => ScaffoldMessenger.of(
          ctx,
        ).showSnackBar(const SnackBar(content: Text('new purchase order'))),
      ),
      CommandItem(
        id: 'action-stock-count',
        icon: Icons.fact_check_outlined,
        title: 'بدء جرد',
        onSelect: (ctx) => ScaffoldMessenger.of(
          ctx,
        ).showSnackBar(const SnackBar(content: Text('stock count'))),
      ),
    ],
  );
}

class _FakeNavigation implements AppNavigation {
  _FakeNavigation();

  @override
  final PosUser currentUser = _managerUser;

  @override
  final AuthorizationCapabilities capabilities =
      AuthorizationCapabilities.forUser(_managerUser);

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('navigate → ${destination.name}')));
  }

  @override
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}
