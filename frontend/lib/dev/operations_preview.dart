// Dev-only preview harness for the operations route.
//
// Renders one operations surface at a time, full-viewport, with fake
// repositories and no backend/auth. Pick the surface with a `?screen=` query
// param and resize the browser to test responsiveness. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/operations_preview.dart
//
// Screens: board | board-empty | board-done | details | details-done
//          | intake | recipes
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/bill_of_materials.dart';
import 'package:pointy_frontend/src/data/models/customer_asset.dart';
import 'package:pointy_frontend/src/data/models/operations_job.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/workflow.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/employee_repository.dart';
import 'package:pointy_frontend/src/data/repositories/operations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/operations/view_models/job_details_view_model.dart';
import 'package:pointy_frontend/src/features/operations/view_models/jobs_board_view_model.dart';
import 'package:pointy_frontend/src/features/operations/view_models/recipes_view_model.dart';
import 'package:pointy_frontend/src/features/operations/views/job_details_screen.dart';
import 'package:pointy_frontend/src/features/operations/views/job_intake_wizard.dart';
import 'package:pointy_frontend/src/features/operations/views/jobs_screen.dart';
import 'package:pointy_frontend/src/features/operations/views/recipes_page.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';
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
      home: const _Router(),
    );
  }
}

String _screen() {
  final uri = Uri.base;
  final direct = uri.queryParameters['screen'];
  if (direct != null) {
    return direct;
  }
  final fragment = uri.fragment;
  final parsed = Uri.tryParse(
    fragment.startsWith('/') ? fragment.substring(1) : fragment,
  );
  return parsed?.queryParameters['screen'] ?? 'board';
}

class _Router extends StatelessWidget {
  const _Router();

  @override
  Widget build(BuildContext context) {
    switch (_screen()) {
      case 'board-empty':
        return _board(jobs: const []);
      case 'board-done':
        return _board(status: OperationsJobStatus.completed);
      case 'details':
        return _details(_richJob);
      case 'details-done':
        return _details(_doneJob);
      case 'intake':
        return _intake();
      case 'recipes':
        return _recipes();
      case 'board':
      default:
        return _board();
    }
  }
}

Widget _board({
  List<OperationsJob>? jobs,
  OperationsJobStatus status = OperationsJobStatus.open,
}) {
  final repo = _FakeOperationsRepository(
    jobs: jobs ?? _boardJobs,
    templates: _templates,
    boms: _boms,
  );
  final vm = JobsBoardViewModel(repo);
  vm.statusFilter = status;
  return JobsScreen(
    viewModel: vm,
    capabilities: _managerCaps,
    navigation: _FakeNavigation(_managerCaps, _managerUser),
    currentUser: _managerUser,
    contactRepository: _FakeContactRepository(),
    operationsRepository: repo,
    catalogRepository: _FakeCatalogRepository(),
    recipesViewModel: RecipesViewModel(repo),
    onOpenJob: (_) {},
  );
}

Widget _details(OperationsJob job) {
  final repo = _FakeOperationsRepository(
    jobs: [job],
    templates: _templates,
    boms: _boms,
  );
  return JobDetailsScreen(
    viewModel: JobDetailsViewModel(repo, jobId: job.id),
    capabilities: _managerCaps,
    currentUser: _managerUser,
    catalogRepository: _FakeCatalogRepository(),
    operationsRepository: repo,
    employeeRepository: _FakeEmployeeRepository(),
  );
}

Widget _intake() {
  final repo = _FakeOperationsRepository(
    jobs: _boardJobs,
    templates: _templates,
    boms: _boms,
  );
  return JobIntakeWizard(
    template: _repairTemplate,
    boardViewModel: JobsBoardViewModel(repo),
    contactRepository: _FakeContactRepository(),
    operationsRepository: repo,
  );
}

Widget _recipes() {
  final repo = _FakeOperationsRepository(
    jobs: _boardJobs,
    templates: _templates,
    boms: _boms,
  );
  final vm = RecipesViewModel(repo);
  return RecipesPage(
    viewModel: vm,
    catalogRepository: _FakeCatalogRepository(),
  );
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

final PosUser _managerUser = PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'role': 'manager',
  'permissions': <String>[],
});

final AuthorizationCapabilities _managerCaps =
    AuthorizationCapabilities.forUser(_managerUser);

class _FakeNavigation implements AppNavigation {
  _FakeNavigation(this.capabilities, this.currentUser);

  @override
  final AuthorizationCapabilities capabilities;
  @override
  final PosUser currentUser;

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

class _FakeOperationsRepository extends OperationsRepository {
  _FakeOperationsRepository({
    required this.jobs,
    required this.templates,
    required this.boms,
  }) : super(PosApiService());

  final List<OperationsJob> jobs;
  final List<WorkflowTemplate> templates;
  final List<BillOfMaterials> boms;

  @override
  Future<Result<List<WorkflowTemplate>>> loadAllWorkflowTemplates({
    bool? isActive,
    OperationsJobType? jobType,
  }) async {
    return Ok(templates);
  }

  @override
  Future<Result<List<BillOfMaterials>>> loadAllBoms({bool? isActive}) async {
    return Ok(boms);
  }

  @override
  Future<Result<List<OperationsJob>>> loadAllJobs({
    OperationsJobStatus? status,
    OperationsJobType? jobType,
    int? assignedTo,
    String search = '',
    int? asset,
    int? currentStage,
    int? customer,
    int? workflowTemplate,
  }) async {
    return Ok(
      jobs
          .where((job) => status == null || job.status == status)
          .where((job) => jobType == null || job.jobType == jobType)
          .toList(growable: false),
    );
  }

  @override
  Future<Result<OperationsJob>> loadJob(int jobId) async {
    return Ok(
      jobs.firstWhere((job) => job.id == jobId, orElse: () => jobs.first),
    );
  }
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository() : super(PosApiService());
}

class _FakeContactRepository extends ContactRepository {
  _FakeContactRepository() : super(PosApiService());
}

class _FakeEmployeeRepository extends EmployeeRepository {
  _FakeEmployeeRepository() : super(PosApiService());
}

// ---------------------------------------------------------------------------
// Fake data
// ---------------------------------------------------------------------------

WorkflowStage _stage(
  int id,
  String code,
  String name,
  int order, {
  bool initial = false,
  bool terminal = false,
  bool approval = false,
  bool consumes = false,
  bool produces = false,
}) {
  return WorkflowStage(
    id: id,
    code: code,
    name: name,
    displayOrder: order,
    isInitial: initial,
    isTerminal: terminal,
    requiresCustomerApproval: approval,
    consumesMaterials: consumes,
    producesOutput: produces,
  );
}

final List<WorkflowStage> _repairStages = [
  _stage(1, 'received', 'تم الاستلام', 0, initial: true),
  _stage(2, 'diagnosing', 'قيد التشخيص', 1),
  _stage(3, 'waiting_approval', 'بانتظار موافقة الزبون', 2, approval: true),
  _stage(4, 'repairing', 'قيد التصليح', 3),
  _stage(5, 'testing', 'قيد الاختبار', 4),
  _stage(6, 'ready', 'جاهز للتسليم', 5),
  _stage(7, 'delivered', 'تم التسليم', 6, terminal: true),
];

final WorkflowTemplate _repairTemplate = WorkflowTemplate(
  id: 1,
  name: 'تصليح الأجهزة',
  jobType: OperationsJobType.repair,
  isActive: true,
  isSystem: true,
  jobCount: 6,
  stages: _repairStages,
);

final List<WorkflowTemplate> _templates = [_repairTemplate];

OperationsJob _job({
  required int id,
  required String jobNumber,
  required int currentStage,
  WorkflowStage? nextStage,
  OperationsJobStatus status = OperationsJobStatus.open,
  OperationsJobPriority priority = OperationsJobPriority.normal,
  String customerName = '',
  String customerPhone = '',
  String assignedEmployeeName = '',
  String symptoms = '',
  String diagnosis = '',
  double? quotedPrice,
  double? approvedPrice,
  String orderReceiptNumber = '',
  DateTime? dueAt,
  List<JobAssetLink> assets = const [],
  List<JobMaterial> materials = const [],
  List<JobStageEvent> stageEvents = const [],
  double materialsTotal = 0,
  DateTime? createdAt,
}) {
  return OperationsJob(
    id: id,
    jobNumber: jobNumber,
    jobType: OperationsJobType.repair,
    workflowTemplate: 1,
    currentStage: currentStage,
    currentStageDetails: _repairStages.firstWhere((s) => s.id == currentStage),
    nextStage: nextStage,
    status: status,
    customerName: customerName,
    customerPhone: customerPhone,
    assignedToName: '',
    assignedEmployeeName: assignedEmployeeName,
    priority: priority,
    symptoms: symptoms,
    diagnosis: diagnosis,
    technicianNotes: '',
    warrantyDays: 30,
    outputVariantName: '',
    salesChannelName: 'نقطة البيع',
    orderReceiptNumber: orderReceiptNumber,
    publicToken: 'tok$id',
    assets: assets,
    materials: materials,
    stageEvents: stageEvents,
    materialsTotal: materialsTotal,
    quotedPrice: quotedPrice,
    approvedPrice: approvedPrice,
    dueAt: dueAt,
    createdAt: createdAt ?? DateTime(2026, 6, 14, 10, 30),
  );
}

final List<OperationsJob> _boardJobs = [
  _job(
    id: 1,
    jobNumber: 'REP-104',
    currentStage: 1,
    nextStage: _repairStages[1],
    priority: OperationsJobPriority.urgent,
    customerName: 'أحمد علي',
    customerPhone: '0911234567',
    symptoms: 'الشاشة مكسورة ولا تستجيب للمس',
    dueAt: DateTime(2026, 6, 16, 17, 0),
  ),
  _job(
    id: 2,
    jobNumber: 'REP-103',
    currentStage: 2,
    nextStage: _repairStages[2],
    customerName: 'سارة محمد',
    assignedEmployeeName: 'خالد',
    symptoms: 'البطارية تنفد بسرعة',
  ),
  _job(
    id: 3,
    jobNumber: 'REP-102',
    currentStage: 4,
    nextStage: _repairStages[4],
    priority: OperationsJobPriority.high,
    customerName: 'محمد عبدالله',
    assignedEmployeeName: 'سارة',
    symptoms: 'لا يشحن',
  ),
  _job(
    id: 4,
    jobNumber: 'REP-101',
    currentStage: 6,
    customerName: 'ليلى حسن',
    assignedEmployeeName: 'خالد',
    status: OperationsJobStatus.completed,
    orderReceiptNumber: 'INV-2042',
  ),
];

final OperationsJob _richJob = _job(
  id: 1,
  jobNumber: 'REP-104',
  currentStage: 4,
  nextStage: _repairStages[4],
  priority: OperationsJobPriority.urgent,
  customerName: 'أحمد علي',
  customerPhone: '0911234567',
  assignedEmployeeName: 'خالد العمري',
  symptoms: 'الشاشة مكسورة ولا تستجيب للمس بعد سقوط الجهاز.',
  diagnosis: 'تلف في الشاشة الأمامية ووحدة اللمس، يلزم استبدال كامل.',
  quotedPrice: 180,
  approvedPrice: 180,
  dueAt: DateTime(2026, 6, 16, 17, 0),
  materialsTotal: 120,
  assets: [
    JobAssetLink(
      id: 1,
      asset: 1,
      assetDetails: CustomerAsset.fromJson(const {
        'id': 1,
        'asset_type': 'phone',
        'brand': 'Apple',
        'model_name': 'iPhone 15 Pro',
        'imei': '356789012345678',
        'serial_number': 'F2LXK9',
      }),
    ),
  ],
  materials: [
    JobMaterial(
      id: 1,
      variant: 10,
      productName: 'شاشة آيفون 15 برو',
      variantName: 'شاشة آيفون 15 برو',
      quantity: 1,
      unitCost: 80,
      unitPrice: 120,
      lineTotal: 120,
      isConsumed: true,
      consumedAt: DateTime(2026, 6, 15, 9, 0),
    ),
    JobMaterial(
      id: 2,
      variant: 11,
      productName: 'لاصق مقاوم للماء',
      variantName: 'لاصق مقاوم للماء',
      quantity: 1,
      unitCost: 3,
      unitPrice: 5,
      lineTotal: 5,
      isConsumed: false,
    ),
  ],
  stageEvents: [
    JobStageEvent(
      id: 1,
      toStage: 1,
      toStageName: 'تم الاستلام',
      fromStageName: '',
      changedByName: 'منى',
      note: '',
      createdAt: DateTime(2026, 6, 14, 10, 30),
    ),
    JobStageEvent(
      id: 2,
      toStage: 2,
      toStageName: 'قيد التشخيص',
      fromStageName: 'تم الاستلام',
      changedByName: 'خالد العمري',
      note: '',
      createdAt: DateTime(2026, 6, 14, 12, 0),
    ),
    JobStageEvent(
      id: 3,
      toStage: 3,
      toStageName: 'بانتظار موافقة الزبون',
      fromStageName: 'قيد التشخيص',
      changedByName: 'خالد العمري',
      note: 'أبلغنا الزبون بالسعر التقديري',
      createdAt: DateTime(2026, 6, 14, 14, 30),
    ),
    JobStageEvent(
      id: 4,
      toStage: 4,
      toStageName: 'قيد التصليح',
      fromStageName: 'بانتظار موافقة الزبون',
      changedByName: 'خالد العمري',
      note: '',
      createdAt: DateTime(2026, 6, 15, 9, 0),
    ),
  ],
);

final OperationsJob _doneJob = _job(
  id: 1,
  jobNumber: 'REP-101',
  currentStage: 7,
  status: OperationsJobStatus.completed,
  customerName: 'ليلى حسن',
  customerPhone: '0921112223',
  assignedEmployeeName: 'خالد العمري',
  symptoms: 'لا يشحن',
  diagnosis: 'تلف منفذ الشحن، تم الاستبدال.',
  approvedPrice: 90,
  orderReceiptNumber: 'INV-2042',
  materialsTotal: 45,
  createdAt: DateTime(2026, 6, 10, 11, 0),
);

final List<BillOfMaterials> _boms = const [];
