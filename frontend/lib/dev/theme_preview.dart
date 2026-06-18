// Dev-only preview harness for the light/dark theme.
//
// Renders a gallery of the common surfaces (cards, buttons, chips, inputs,
// list tiles, status colours) wired to the real [ThemeController] +
// [PointyTheme.light]/[PointyTheme.dark], plus the shipping appearance
// controls. Start in dark with `?screen=dark`; toggle live with the app-bar
// button or the selector. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/theme_preview.dart
//
// Not part of the shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/theme/theme_controller.dart';
import 'package:pointy_frontend/src/shared/theme/theme_mode_controls.dart';

void main() => runApp(const _ThemePreviewApp());

ThemeMode _initialMode() {
  final screen = Uri.base.queryParameters['screen'];
  return switch (screen) {
    'dark' => ThemeMode.dark,
    'light' => ThemeMode.light,
    _ => ThemeMode.light,
  };
}

class _ThemePreviewApp extends StatefulWidget {
  const _ThemePreviewApp();

  @override
  State<_ThemePreviewApp> createState() => _ThemePreviewAppState();
}

class _ThemePreviewAppState extends State<_ThemePreviewApp> {
  late final ThemeController _controller = ThemeController(
    initialMode: _initialMode(),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => MaterialApp(
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
        darkTheme: PointyTheme.dark(),
        themeMode: _controller.mode,
        builder: (context, child) => ThemeControllerScope(
          controller: _controller,
          child: child ?? const SizedBox.shrink(),
        ),
        home: const _Gallery(),
      ),
    );
  }
}

class _Gallery extends StatelessWidget {
  const _Gallery();

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('المظهر · Theme'),
        actions: const [ThemeModeToggleButton(), SizedBox(width: 8)],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Align(
                alignment: AlignmentDirectional.centerStart,
                child: ThemeModeSelector(),
              ),
              const SizedBox(height: 24),
              Text('هياكل التحميل · Skeletons', style: text.titleMedium),
              const SizedBox(height: 12),
              SizedBox(
                height: 196,
                child: PointyDataList<int>(
                  items: const [],
                  isLoadingInitial: true,
                  isLoadingMore: false,
                  hasMore: false,
                  onLoadMore: () async {},
                  itemBuilder: (_, _) => const SizedBox.shrink(),
                  emptyBuilder: (_) => const SizedBox.shrink(),
                  skeletonItemCount: 3,
                ),
              ),
              const SizedBox(height: 16),
              const SizedBox(
                height: 150,
                child: PointySkeleton(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: PointySkeletonCard()),
                      SizedBox(width: 12),
                      Expanded(child: PointySkeletonCard()),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('عنوان البطاقة', style: text.titleLarge),
                      const SizedBox(height: 6),
                      Text(
                        'نص أساسي يوضح كيف يظهر المحتوى على سطح البطاقة في كلا الوضعين.',
                        style: text.bodyMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'نص ثانوي خافت',
                        style: text.bodySmall?.copyWith(color: colors.mutedInk),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton(onPressed: () {}, child: const Text('أساسي')),
                  OutlinedButton(onPressed: () {}, child: const Text('محدد')),
                  TextButton(onPressed: () {}, child: const Text('نصي')),
                  IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.favorite_border),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  Chip(label: const Text('وسم')),
                  InputChip(
                    selected: true,
                    label: const Text('محدد'),
                    onSelected: (_) {},
                  ),
                  const Chip(
                    avatar: Icon(Icons.local_offer_outlined, size: 18),
                    label: Text('عرض'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const TextField(
                decoration: InputDecoration(
                  labelText: 'حقل إدخال',
                  hintText: 'اكتب هنا…',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              const SizedBox(height: 20),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.inventory_2_outlined),
                      title: const Text('عنصر قائمة'),
                      subtitle: const Text('سطر وصفي ثانوي'),
                      trailing: const Icon(Icons.chevron_left),
                      onTap: () {},
                    ),
                    Divider(height: 1, color: colors.line),
                    ListTile(
                      leading: const Icon(Icons.payments_outlined),
                      title: const Text('عنصر آخر'),
                      trailing: const Icon(Icons.chevron_left),
                      onTap: () {},
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _Swatch('primary', colors.primary),
                  _Swatch('strong', colors.primaryStrong),
                  _Swatch('success', colors.success),
                  _Swatch('warning', colors.warning),
                  _Swatch('danger', colors.danger),
                  _Swatch('amber', colors.accentAmber),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(this.label, this.color);

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 40,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: context.pointyColors.line),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}
