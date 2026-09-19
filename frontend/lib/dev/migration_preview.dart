// Design harness for the Data Migration wizard.
//
//   make frontend-migration-preview
//   ?screen=choose|uploading|preparing|failed|review|dryrun|importing|done
//   ?screen=collapse|collapse-building|collapse-approved  (the §12 review)
//   ?theme=light|dark
//
// The wizard's steps are server-state-driven and some of them only appear after
// a real twenty-minute conversion, which makes them hard to look at while
// designing. The fake repository below fabricates each state directly so every
// screen can be opened on demand — and `?screen=board` lays them all out side by
// side, which is the only way to see whether they read as one flow.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/migration.dart';
import 'package:pointy_frontend/src/data/models/migration_collapse.dart';
import 'package:pointy_frontend/src/data/repositories/migration_repository.dart';
import 'package:pointy_frontend/src/data/services/migration_uploader.dart';
import 'package:pointy_frontend/src/features/migration/view_models/collapse_view_model.dart';
import 'package:pointy_frontend/src/features/migration/view_models/migration_view_model.dart';
import 'package:pointy_frontend/src/features/migration/views/collapse_review_page.dart';
import 'package:pointy_frontend/src/features/migration/views/data_migration_page.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

String _param(String name, String fallback) {
  final query = Uri.base.queryParameters[name];
  if (query != null && query.isNotEmpty) return query;
  final fragment = Uri.base.fragment;
  final index = fragment.indexOf('?');
  if (index >= 0) {
    final parsed = Uri.splitQueryString(fragment.substring(index + 1));
    final value = parsed[name];
    if (value != null && value.isNotEmpty) return value;
  }
  return fallback;
}

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    final dark = _param('theme', 'light') == 'dark';
    final screen = _param('screen', 'choose');
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: dark ? PointyTheme.dark() : PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: screen == 'board' ? const _Board() : _Single(screen: screen),
    );
  }
}

class _Single extends StatelessWidget {
  const _Single({required this.screen});

  final String screen;

  @override
  Widget build(BuildContext context) {
    if (screen.startsWith('collapse')) {
      return CollapseReviewPage(viewModel: _collapseViewModelFor(screen));
    }
    return DataMigrationPage(viewModel: _viewModelFor(screen));
  }
}

/// Every step at once, so the flow can be judged as a whole rather than one
/// screen at a time.
class _Board extends StatelessWidget {
  const _Board();

  static const _screens = [
    'choose',
    'uploading',
    'preparing',
    'failed',
    'review',
    'dryrun',
    'importing',
    'done',
    'collapse-building',
    'collapse',
    'collapse-approved',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final screen in _screens)
              Padding(
                padding: const EdgeInsets.only(left: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        screen,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 420,
                      height: 900,
                      child: ClipRect(
                        child: screen.startsWith('collapse')
                            ? CollapseReviewPage(
                                viewModel: _collapseViewModelFor(screen),
                              )
                            : DataMigrationPage(
                                viewModel: _viewModelFor(screen),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

MigrationViewModel _viewModelFor(String screen) {
  final viewModel = MigrationViewModel(_FakeMigrationRepository(screen));
  viewModel.load();
  return viewModel;
}

CollapseViewModel _collapseViewModelFor(String screen) {
  final viewModel = CollapseViewModel(
    _FakeMigrationRepository(screen),
    sourceId: 1,
  );
  viewModel.load();
  return viewModel;
}

// --- fixtures ---------------------------------------------------------------
List<Map<String, Object?>> _stages({
  required List<String> statuses,
  Map<int, String> details = const {},
  Map<int, int> percents = const {},
}) {
  const labels = [
    'التعرف على الملف',
    'تحويل قاعدة البيانات',
    'إعادة بناء الفواتير',
    'التعرف على النظام',
    'قراءة المحتويات',
    'تنظيف الملفات المؤقتة',
  ];
  return [
    for (var index = 0; index < labels.length; index++)
      {
        'key': 'stage$index',
        'label': labels[index],
        'status': index < statuses.length ? statuses[index] : 'pending',
        'percent': percents[index] ?? 0,
        'detail': details[index] ?? '',
        'counts': const <String, Object?>{},
      },
  ];
}

Map<String, Object?> _sourceJson(String screen) {
  final base = <String, Object?>{
    'id': 1,
    'name': 'db.mdb',
    'original_filename': 'db.mdb',
    'declared_size_bytes': 1610612736,
    'received_bytes': 1610612736,
    'upload_percent': 100,
    'staged_size_bytes': 1610612736,
    'prepared_size_bytes': 231735296,
    'system_key': 'fahd',
    'detected_version': 'fahd-mdb-recon-1',
    'detection': {
      'matched': true,
      'system_key': 'fahd',
      'display_name': 'برنامج فهد',
      'detected_version': 'fahd-mdb-recon-1',
    },
    'analysis': {
      'entities': {
        'product': {'count': 34112},
        'customer': {'count': 1203},
        'supplier': {'count': 87},
        'sale': {'count': 892441, 'from': '2019-03-14', 'to': '2026-08-29'},
        'purchase_order': {'count': 14208},
        'category': {'count': 42},
      },
      'history_from': '2019-03-14',
      'history_to': '2026-08-29',
    },
    'supported_entities': [
      'category',
      'product',
      'variant',
      'customer',
      'supplier',
      'purchase_order',
      'sale',
    ],
  };

  switch (screen) {
    case 'preparing':
      return {
        ...base,
        'upload_state': 'preparing',
        'stages': _stages(
          statuses: ['done', 'running'],
          details: {
            0: 'قاعدة بيانات Microsoft Access',
            1: 'الجدول 34 من 61 · control · 840 ميجابايت',
          },
          percents: {1: 56},
        ),
      };
    case 'failed':
      return {
        ...base,
        'upload_state': 'failed',
        'system_key': '',
        'error_message':
            'هذا ملف مضغوط (ZIP) — نحتاج ملف قاعدة البيانات نفسه، غير مضغوط.',
        'stages': _stages(
          statuses: [
            'failed',
            'skipped',
            'skipped',
            'skipped',
            'skipped',
            'skipped',
          ],
          details: {
            0: 'هذا ملف مضغوط (ZIP) — نحتاج ملف قاعدة البيانات نفسه، غير مضغوط.',
          },
        ),
      };
    case 'done':
      return {
        ...base,
        'upload_state': 'purged',
        'purged_at': '2026-09-04T10:22:00Z',
        'stages': _stages(
          statuses: ['done', 'done', 'done', 'done', 'done', 'done'],
        ),
      };
    default:
      return {
        ...base,
        'upload_state': 'ready',
        'stages': _stages(
          statuses: ['done', 'done', 'done', 'done', 'done', 'done'],
          details: {
            0: 'قاعدة بيانات Microsoft Access',
            1: '61 جدول',
            2: '892,441 فاتورة بيع · 14,208 فاتورة شراء',
            3: 'برنامج فهد',
          },
        ),
      };
  }
}

Map<String, Object?>? _runJson(String screen) {
  final summary = {
    'category': {'created': 42, 'updated': 0, 'skipped': 0, 'failed': 0},
    'product': {'created': 34112, 'updated': 0, 'skipped': 0, 'failed': 0},
    'customer': {'created': 1203, 'updated': 0, 'skipped': 0, 'failed': 0},
    'sale': {'created': 892441, 'updated': 0, 'skipped': 0, 'failed': 0},
  };
  switch (screen) {
    case 'dryrun':
      return {
        'id': 9,
        'source': 1,
        'mode': 'dry_run',
        'status': 'succeeded',
        'progress_percent': 100,
        'progress_message': 'اكتملت المعاينة: 927,798 جديد، 0 تحديث، 0 مشكلة.',
        'summary': summary,
        'stages': const <Map<String, Object?>>[],
      };
    case 'importing':
      return {
        'id': 10,
        'source': 1,
        'mode': 'import',
        'status': 'running',
        'progress_percent': 62,
        'progress_message': 'جارٍ نقل: المبيعات',
        'summary': {
          'category': summary['category'],
          'product': summary['product'],
        },
        'stages': [
          {
            'key': 'category',
            'label': 'التصنيفات',
            'status': 'done',
            'percent': 100,
            'detail': '42 جديد',
            'counts': const <String, Object?>{},
          },
          {
            'key': 'product',
            'label': 'الأصناف',
            'status': 'done',
            'percent': 100,
            'detail': '34,112 جديد',
            'counts': const <String, Object?>{},
          },
          {
            'key': 'sale',
            'label': 'المبيعات',
            'status': 'running',
            'percent': 0,
            'detail': '412,000 سجل',
            'counts': const <String, Object?>{},
          },
        ],
      };
    case 'done':
      return {
        'id': 10,
        'source': 1,
        'mode': 'import',
        'status': 'succeeded',
        'progress_percent': 100,
        'progress_message': 'اكتمل النقل: 927,798 جديد، 0 تحديث، 0 فشل.',
        'summary': summary,
        'stages': const <Map<String, Object?>>[],
      };
    default:
      return null;
  }
}

/// The prospect's catalogue, as §12 describes it: 340 rows that are really a
/// dozen phones, with the handful of rows nobody can settle but the owner.
Map<String, Object?> _collapsePlanJson(String screen) {
  final status = switch (screen) {
    'collapse-building' => 'running',
    'collapse-approved' => 'approved',
    _ => 'ready',
  };
  return {
    'id': 7,
    'source': 1,
    'status': status,
    'is_editable': status == 'ready',
    'error_message': '',
    'asset_type': 1,
    'asset_type_name': 'هاتف',
    'warranty_days': 0,
    'thresholds': {'low': 0.5, 'high': 0.8},
    // The builder's own stages (apps.migration.collapse.planner), not the
    // preparation pipeline's — they are a different job.
    'stages': status == 'running'
        ? const [
            {
              'key': 'catalogue',
              'label': 'قراءة الأصناف',
              'status': 'done',
              'percent': 100,
              'detail': '34,112 صنف',
            },
            {
              'key': 'history',
              'label': 'قراءة الشراء والبيع',
              'status': 'running',
              'percent': 0,
              'detail': '14,208 شراء · 892,441 بيع',
            },
            {
              'key': 'cluster',
              'label': 'تجميع الأصناف المتشابهة',
              'status': 'pending',
              'percent': 0,
              'detail': '',
            },
            {
              'key': 'propose',
              'label': 'تجهيز الاقتراح',
              'status': 'pending',
              'percent': 0,
              'detail': '',
            },
          ]
        : const <Map<String, Object?>>[],
    'stats': {
      'source_products': 340,
      'products': 12,
      'variants': 31,
      'units': 331,
      'units_in_stock': 96,
      'units_sold': 235,
      'kept': 9,
      'needs_review': 14,
      'edited': 3,
    },
  };
}

List<Map<String, Object?>> _collapseClustersJson() => [
  {
    'stem_key': 'iphone 13 pro',
    'stem': 'iPhone 13 Pro',
    'variants': 6,
    'units': 84,
    'units_in_stock': 21,
    'units_sold': 63,
    'needs_review': 4,
    'option_values': {
      'storage': ['128GB', '256GB', '512GB'],
      'colour': ['black', 'blue'],
    },
    'option_labels': {
      'storage': ['128GB', '256GB', '512GB'],
      'colour': ['أسود', 'أزرق'],
    },
  },
  {
    'stem_key': 'iphone 12',
    'stem': 'iPhone 12',
    'variants': 4,
    'units': 61,
    'units_in_stock': 18,
    'units_sold': 43,
    'needs_review': 0,
    'option_values': {
      'storage': ['64GB', '128GB'],
      'colour': ['white', 'black'],
    },
    'option_labels': {
      'storage': ['64GB', '128GB'],
      'colour': ['أبيض', 'أسود'],
    },
  },
  {
    'stem_key': 'samsung s21 ultra',
    'stem': 'Samsung S21 Ultra',
    'variants': 3,
    'units': 37,
    'units_in_stock': 11,
    'units_sold': 26,
    'needs_review': 2,
    'option_values': {
      'storage': ['256GB', '512GB'],
      'colour': ['black'],
    },
    'option_labels': {
      'storage': ['256GB', '512GB'],
      'colour': ['أسود'],
    },
  },
];

List<Map<String, Object?>> _collapseCandidatesJson() => [
  {
    'id': 1,
    'source_key': '1042',
    'source_name': 'ايفون 13 برو 1TB 351234567890111',
    'decision': 'collapse',
    'stem': 'ايفون 13 برو',
    'stem_key': 'ايفون 13 برو',
    'identifier': '351234567890111',
    'identifier_kind': 'imei',
    'options': {'storage': '1TB'},
    'option_labels': {'storage': '1TB'},
    'attributes': <String, Object?>{},
    'unit_status': 'in_stock',
    'unit_cost': '2350.000000',
    'list_price': '2850.00',
    'sold_price': null,
    'confidence': '0.30',
    'reasons': [
      'imei_check_digit_failed',
      'singleton_cluster',
      'no_purchase_cost',
    ],
    'edited': false,
    'needs_review': true,
  },
  {
    'id': 2,
    'source_key': '1180',
    'source_name': 'جراب شفاف IMEI359900001111222',
    'decision': 'keep',
    'stem': '',
    'stem_key': '',
    'identifier': '',
    'identifier_kind': '',
    'options': <String, Object?>{},
    'option_labels': <String, Object?>{},
    'attributes': <String, Object?>{},
    'unit_status': 'in_stock',
    'unit_cost': '5.000000',
    'list_price': '15.00',
    'sold_price': '15.00',
    'confidence': '0.00',
    'reasons': ['sold_more_than_once'],
    'edited': false,
    'needs_review': false,
  },
  {
    'id': 3,
    'source_key': '1007',
    'source_name': 'iPhone 13 Pro 256GB Blue Battery86 IMEI351234567890129',
    'decision': 'collapse',
    'stem': 'iPhone 13 Pro',
    'stem_key': 'iphone 13 pro',
    'identifier': '351234567890129',
    'identifier_kind': 'imei',
    'options': {'storage': '256GB', 'colour': 'blue'},
    'option_labels': {'storage': '256GB', 'colour': 'أزرق'},
    'attributes': {'battery_health': 86},
    'unit_status': 'sold',
    'unit_cost': '2400.000000',
    'list_price': '2900.00',
    'sold_price': '2900.00',
    'confidence': '1.00',
    'reasons': <String>[],
    'edited': false,
    'needs_review': false,
  },
];

class _FakeMigrationRepository implements MigrationRepository {
  _FakeMigrationRepository(this.screen);

  final String screen;

  @override
  Future<Result<MigrationCatalog>> loadCatalog() async {
    return Ok(
      MigrationCatalog.fromJson(const {
        'systems': [
          {
            'system_key': 'fahd',
            'display_name': 'برنامج فهد',
            'supported_entities': ['product', 'sale'],
            'versions': ['fahd-mdb-recon-1'],
            'implemented': true,
          },
          {
            'system_key': 'aboghris',
            'display_name': 'AboGhris',
            'supported_entities': ['product', 'sale'],
            'versions': ['aboghris-v30-2025'],
            'implemented': true,
          },
        ],
        'entities': [
          {
            'entity_type': 'category',
            'label': 'التصنيفات',
            'implemented': true,
          },
          {'entity_type': 'product', 'label': 'الأصناف', 'implemented': true},
          {'entity_type': 'variant', 'label': 'المتغيرات', 'implemented': true},
          {'entity_type': 'customer', 'label': 'الزبائن', 'implemented': true},
          {'entity_type': 'supplier', 'label': 'الموردون', 'implemented': true},
          {
            'entity_type': 'purchase_order',
            'label': 'فواتير الشراء',
            'implemented': true,
          },
          {'entity_type': 'sale', 'label': 'المبيعات', 'implemented': true},
        ],
        'upload': {
          'chunk_size': 16777216,
          'max_bytes': 8589934592,
          'accepted_extensions': ['.mdb', '.accdb', '.sqlite', '.db'],
        },
      }),
    );
  }

  @override
  Future<Result<List<MigrationSource>>> loadSources() async {
    if (screen == 'choose' || screen == 'uploading') return const Ok([]);
    return Ok([MigrationSource.fromJson(_sourceJson(screen))]);
  }

  @override
  Future<Result<MigrationSource>> loadSource(int id) async {
    return Ok(MigrationSource.fromJson(_sourceJson(screen)));
  }

  @override
  Future<Result<List<MigrationRun>>> loadRuns({int? sourceId}) async {
    final run = _runJson(screen);
    return Ok(run == null ? const [] : [MigrationRun.fromJson(run)]);
  }

  @override
  Future<Result<MigrationRun>> loadRun(int id) async {
    return Ok(MigrationRun.fromJson(_runJson(screen) ?? const {}));
  }

  @override
  Future<Result<MigrationRun>> startRun({
    required int sourceId,
    required String mode,
    required List<String> entities,
    Map<String, Object?> options = const {},
  }) async {
    return Ok(MigrationRun.fromJson(_runJson('importing')!));
  }

  @override
  Future<Result<MigrationIssuePage>> loadIssues(
    int runId, {
    int page = 1,
    String? severity,
  }) async {
    return const Ok(MigrationIssuePage(issues: [], hasMore: false));
  }

  @override
  MigrationUploader newUploader() =>
      throw UnimplementedError('preview does not upload');

  @override
  Future<Result<MigrationSource>> uploadFile(
    PlatformFile file, {
    required MigrationUploader uploader,
    MigrationSource? resuming,
    void Function(MigrationUploadProgress)? onProgress,
  }) async {
    return Ok(MigrationSource.fromJson(_sourceJson('preparing')));
  }

  @override
  Future<Result<MigrationSource>> completeUpload(int id) async {
    return Ok(MigrationSource.fromJson(_sourceJson('preparing')));
  }

  @override
  Future<Result<MigrationSource>> discardSource(int id) async {
    return Ok(MigrationSource.fromJson(_sourceJson('done')));
  }

  // --- the collapse (§12) ----------------------------------------------

  @override
  Future<Result<CollapsePlan>> proposeCollapse(int sourceId) async {
    return Ok(CollapsePlan.fromJson(_collapsePlanJson('collapse-building')));
  }

  @override
  Future<Result<CollapsePlan>> loadCollapsePlan(int planId) async {
    return Ok(CollapsePlan.fromJson(_collapsePlanJson(screen)));
  }

  @override
  Future<Result<List<CollapsePlan>>> loadCollapsePlans({int? sourceId}) async {
    if (!screen.startsWith('collapse')) return const Ok([]);
    return Ok([CollapsePlan.fromJson(_collapsePlanJson(screen))]);
  }

  @override
  Future<Result<List<CollapseCluster>>> loadCollapseClusters(int planId) async {
    return Ok([
      for (final item in _collapseClustersJson())
        CollapseCluster.fromJson(item),
    ]);
  }

  @override
  Future<Result<CollapseCandidatePage>> loadCollapseCandidates(
    int planId, {
    int page = 1,
    String? decision,
    String? stemKey,
    bool needsReview = false,
    String search = '',
  }) async {
    final rows = [
      for (final item in _collapseCandidatesJson())
        CollapseCandidate.fromJson(item),
    ];
    return Ok(
      CollapseCandidatePage(
        candidates: [
          for (final row in rows)
            if (decision == null || row.decision == decision)
              if (!needsReview || row.needsReview) row,
        ],
        hasMore: false,
      ),
    );
  }

  @override
  Future<Result<({CollapseCandidate candidate, CollapseStats stats})>>
  updateCollapseCandidate(int candidateId, Map<String, Object?> changes) async {
    final row = CollapseCandidate.fromJson(_collapseCandidatesJson().first);
    return Ok((
      candidate: row,
      stats: CollapsePlan.fromJson(_collapsePlanJson(screen)).stats,
    ));
  }

  @override
  Future<Result<CollapsePlan>> renameCollapseCluster(
    int planId, {
    required String stemKey,
    required String stem,
  }) async {
    return Ok(CollapsePlan.fromJson(_collapsePlanJson(screen)));
  }

  @override
  Future<Result<CollapsePlan>> approveCollapsePlan(int planId) async {
    return Ok(CollapsePlan.fromJson(_collapsePlanJson('collapse-approved')));
  }
}
