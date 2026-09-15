// Dev-only preview harness for the Learning module. Safe to delete — it is a
// separate entrypoint and is never imported by lib/main.dart.
//
// Run it with `make frontend-learning-preview`, then open:
//   ?screen=board        catalogue + reader side by side (phone + wide)
//   ?screen=catalogue    the catalogue full-viewport, for responsive QA
//   ?screen=search       the catalogue mid-search ("اجل")
//   ?screen=filtered     a track filter applied, sorted shortest-first
//   ?screen=cashier      the catalogue as a cashier sees it (permissions filter)
//   ?screen=guide        the split-payment guide, full-viewport
//   ?screen=concept      the variants explainer (a long concept guide)
//   ?screen=remote       the remote-access guide
//   ?screen=empty        a search that matches nothing
//   ?screen=filters      the filter/sort sheet, already open
//   ?screen=lesson       the sandboxed practice shop + coach panel
//
// See AGENTS.md — a black canvas after start is a browser refresh issue, not a
// slow compile. Reload once.

import 'package:flutter/material.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/features/learning/content/learning_library.dart';
import 'package:pointy_frontend/src/features/learning/models/learning_guide.dart';
import 'package:pointy_frontend/src/features/learning/models/learning_query.dart';
import 'package:pointy_frontend/src/features/learning/view_models/learning_view_model.dart';
import 'package:pointy_frontend/src/features/learning/lessons/lessons.dart';
import 'package:pointy_frontend/src/features/learning/views/learning_filter_sheet.dart';
import 'package:pointy_frontend/src/features/learning/views/lesson_runner_screen.dart';
import 'package:pointy_frontend/src/features/learning/views/learning_guide_view.dart';
import 'package:pointy_frontend/src/features/learning/views/learning_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';
import 'package:pointy_frontend/src/shared/responsive/responsive.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() {
  runApp(const LearningPreviewApp());
}

class LearningPreviewApp extends StatelessWidget {
  const LearningPreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    final screen = Uri.base.queryParameters['screen'] ?? 'board';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: switch (screen) {
        'catalogue' => _catalogue(),
        'search' => _catalogue(query: const LearningQuery(search: 'اجل')),
        'filtered' => _catalogue(
          query: const LearningQuery(
            track: LearningTrack.purchasing,
            sort: LearningSort.shortest,
          ),
        ),
        'cashier' => _catalogue(
          manager: false,
          query: const LearningQuery(
            audience: LearningAudienceFilter.myPermissions,
          ),
        ),
        'empty' => _catalogue(query: const LearningQuery(search: 'زرافة')),
        'guide' => _guide('money.split_tender'),
        'concept' => _guide('catalog.variants_concept'),
        'remote' => _guide('setup.remote_access'),
        'filters' => const _FiltersHost(),
        // Any lesson by id: ?screen=lesson&id=pos.split_tender. Defaults to the
        // cash sale, which is the one every other lesson builds on.
        'lesson' => LessonRunnerScreen(
          lesson: allLessons.firstWhere(
            (lesson) => lesson.id == (Uri.base.queryParameters['id'] ?? ''),
            orElse: () => posCashSaleLesson,
          ),
        ),
        _ => const _Board(),
      },
    );
  }
}

LearningViewModel _viewModel({
  LearningQuery query = const LearningQuery(),
  bool manager = true,
}) {
  final user = PosUser(
    id: manager ? 1 : 2,
    username: manager ? 'manager' : 'cashier',
    role: manager ? UserRole.manager : UserRole.cashier,
    isActive: true,
  );
  return LearningViewModel(
    capabilities: AuthorizationCapabilities.forUser(user),
  )..setQuery(query);
}

Widget _catalogue({
  LearningQuery query = const LearningQuery(),
  bool manager = true,
}) {
  return LearningScreen(
    viewModel: _viewModel(query: query, manager: manager),
    navigation: const _PreviewNavigation(),
  );
}

Widget _guide(String id) {
  final viewModel = _viewModel();
  return PointyScaffold(
    appBar: AppBar(title: Text(learningGuidesById[id]!.title)),
    body: LearningGuideView(
      guide: learningGuidesById[id]!,
      viewModel: viewModel,
      onOpenGuide: (_) {},
      onOpenDestination: (_) {},
    ),
  );
}

/// Opens the filter sheet on load, so it can be screenshotted without driving
/// a tap through a Flutter-web canvas.
class _FiltersHost extends StatefulWidget {
  const _FiltersHost();

  @override
  State<_FiltersHost> createState() => _FiltersHostState();
}

class _FiltersHostState extends State<_FiltersHost> {
  late final LearningViewModel _model = _viewModel();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }
      await showAdaptiveModalBottomSheet<LearningQuery>(
        context: context,
        size: AdaptiveModalSize.standard,
        builder: (context) => LearningFilterSheet(query: _model.query),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return LearningScreen(
      viewModel: _model,
      navigation: const _PreviewNavigation(),
    );
  }
}

class _Board extends StatelessWidget {
  const _Board();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFEEF1F5),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Wrap(
            spacing: 24,
            runSpacing: 24,
            children: [
              _frame('الكتالوج — هاتف', 390, 900, _catalogue()),
              _frame(
                'بحث «اجل» — هاتف',
                390,
                900,
                _catalogue(query: const LearningQuery(search: 'اجل')),
              ),
              _frame(
                'كاشير + فلتر الصلاحيات — هاتف',
                390,
                900,
                _catalogue(
                  manager: false,
                  query: const LearningQuery(
                    audience: LearningAudienceFilter.myPermissions,
                  ),
                ),
              ),
              _frame(
                'دليل: تقسيم الدفع — هاتف',
                390,
                900,
                _guide('money.split_tender'),
              ),
              _frame(
                'دليل: الخيارات — هاتف',
                390,
                900,
                _guide('catalog.variants_concept'),
              ),
              _frame('الكتالوج — عريض', 1000, 900, _catalogue()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _frame(String label, double width, double height, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
        ),
        SizedBox(
          width: width,
          height: height,
          child: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                size: Size(width, height),
                padding: EdgeInsets.zero,
                viewInsets: EdgeInsets.zero,
              ),
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}

class _PreviewNavigation implements AppNavigation {
  const _PreviewNavigation();

  static const _user = PosUser(
    id: 1,
    username: 'manager',
    role: UserRole.manager,
    isActive: true,
  );

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
  }) {}

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
