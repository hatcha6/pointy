// Dev-only preview harness for the discounts route.
//
// Renders the redesigned discount surfaces full-viewport with in-memory fakes
// and no backend/auth. Pick the surface with a `?screen=` query param and
// resize the browser to test responsiveness. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/discounts_preview.dart
//
// Screens: manage | form-create | form-edit | details
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/discount_rule.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/discount_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/discounts/view_models/discount_management_view_model.dart';
import 'package:pointy_frontend/src/features/discounts/views/discount_details_screen.dart';
import 'package:pointy_frontend/src/features/discounts/views/discount_management_screen.dart';
import 'package:pointy_frontend/src/features/discounts/views/discount_rule_form.dart';
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
  return parsed?.queryParameters['screen'] ?? 'manage';
}

class _Router extends StatelessWidget {
  const _Router();

  @override
  Widget build(BuildContext context) {
    switch (_screen()) {
      case 'form-create':
        return _form(rule: null);
      case 'form-edit':
        return _form(rule: _rules.first);
      case 'details':
        return _details();
      case 'manage':
      default:
        return _manage();
    }
  }
}

Widget _details() {
  final repo = _FakeDiscountRepository();
  return DiscountDetailsScreen(
    initialRule: _rules.first,
    discountRepository: repo,
    managementViewModel: DiscountManagementViewModel(repo),
    catalogRepository: _FakeCatalogRepository(),
    contactRepository: _FakeContactRepository(),
    capabilities: _managerCaps,
  );
}

Widget _manage() {
  final repo = _FakeDiscountRepository();
  return DiscountManagementScreen(
    viewModel: DiscountManagementViewModel(repo),
    catalogRepository: _FakeCatalogRepository(),
    contactRepository: _FakeContactRepository(),
    capabilities: _managerCaps,
    navigation: _FakeNavigation(),
  );
}

Widget _form({required DiscountRule? rule}) {
  final repo = _FakeDiscountRepository();
  return Scaffold(
    backgroundColor: PointyColors.surface,
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: DiscountRuleForm(
            viewModel: DiscountManagementViewModel(repo),
            catalogRepository: _FakeCatalogRepository(),
            contactRepository: _FakeContactRepository(),
            rule: rule,
            onSaved: () {},
          ),
        ),
      ),
    ),
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
  _FakeNavigation();

  @override
  final AuthorizationCapabilities capabilities = _managerCaps;
  @override
  final PosUser currentUser = _managerUser;

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

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository() : super(PosApiService());
}

class _FakeContactRepository extends ContactRepository {
  _FakeContactRepository() : super(PosApiService());
}

class _FakeDiscountRepository extends DiscountRepository {
  _FakeDiscountRepository() : super(PosApiService());

  @override
  Future<Result<DiscountRulePage>> loadDiscountRules({
    required DiscountRuleQuery query,
    int page = 1,
  }) async {
    return Ok(DiscountRulePage(rules: _rules, hasMore: false));
  }

  @override
  Future<Result<DiscountRule>> loadDiscountRule(int id) async {
    return Ok(_rules.firstWhere((r) => r.id == id, orElse: () => _rules.first));
  }

  @override
  Future<Result<DiscountRulePerformance>> loadDiscountRulePerformance(
    int id,
  ) async {
    return Ok(_performance);
  }

  @override
  Future<Result<DiscountBeneficiaryPage>> loadDiscountRuleBeneficiaries({
    required int id,
    int page = 1,
  }) async {
    return Ok(
      DiscountBeneficiaryPage(beneficiaries: _beneficiaries, hasMore: false),
    );
  }

  @override
  Future<Result<DiscountRule>> createDiscountRule(
    DiscountRuleDraft draft,
  ) async {
    return Ok(_rules.first);
  }

  @override
  Future<Result<DiscountRule>> updateDiscountRule({
    required int id,
    required DiscountRuleDraft draft,
  }) async {
    return Ok(_rules.first);
  }

  @override
  Future<Result<DiscountRule>> enableDiscountRule(int id) async =>
      Ok(_rules.first);

  @override
  Future<Result<DiscountRule>> disableDiscountRule(int id) async =>
      Ok(_rules.first);

  @override
  Future<Result<DiscountRule>> archiveDiscountRule(int id) async =>
      Ok(_rules.first);
}

DiscountRule _rule({
  required int id,
  required String name,
  String description = '',
  DiscountChannel channel = DiscountChannel.sales,
  DiscountApplicationType applicationType = DiscountApplicationType.automatic,
  String couponCode = '',
  DiscountScope scope = DiscountScope.document,
  DiscountValueType valueType = DiscountValueType.percentage,
  double value = 10,
  int? groupSize,
  int? buyQuantity,
  int? getQuantity,
  DiscountBuyGetReward? rewardType,
  List<DiscountTier> tiers = const [],
  double minOrderSubtotal = 0,
  bool exclusive = true,
  bool isActive = true,
  DateTime? endsAt,
  List<int> productCategories = const [],
  List<int> suppliers = const [],
  int redemptionCount = 0,
}) {
  return DiscountRule(
    id: id,
    name: name,
    description: description,
    channel: channel,
    applicationType: applicationType,
    couponCode: couponCode,
    scope: scope,
    valueType: valueType,
    value: value,
    groupSize: groupSize,
    buyQuantity: buyQuantity,
    getQuantity: getQuantity,
    rewardType: rewardType,
    tiers: tiers,
    maxDiscountAmount: null,
    roundingMode: DiscountRoundingMode.none,
    roundingIncrement: null,
    minOrderSubtotal: minOrderSubtotal,
    minLineQuantity: null,
    priority: 100,
    exclusive: exclusive,
    isActive: isActive,
    startsAt: null,
    endsAt: endsAt,
    usageLimit: null,
    perCustomerUsageLimit: null,
    perSupplierUsageLimit: null,
    products: const [],
    variants: const [],
    productCategories: productCategories,
    customers: const [],
    customerRanks: const [],
    suppliers: suppliers,
    metadata: const {},
    redemptionCount: redemptionCount,
    appliedCount: redemptionCount,
    createdAt: DateTime(2026, 6, 1),
    updatedAt: DateTime(2026, 6, 10),
  );
}

final List<DiscountRule> _rules = [
  _rule(
    id: 1,
    name: 'خصم القهوة',
    description: 'خصم ترويجي على مشروبات القهوة بكود الصيف.',
    channel: DiscountChannel.sales,
    applicationType: DiscountApplicationType.couponCode,
    couponCode: 'SUMMER20',
    value: 20,
    minOrderSubtotal: 50,
    endsAt: DateTime(2026, 6, 30),
    productCategories: const [1],
    redemptionCount: 18,
  ),
  _rule(
    id: 2,
    name: 'تخفيض الجملة',
    channel: DiscountChannel.purchasing,
    valueType: DiscountValueType.fixedAmount,
    value: 5,
    suppliers: const [1],
    redemptionCount: 4,
  ),
  _rule(
    id: 3,
    name: 'تصفية الصيف',
    channel: DiscountChannel.both,
    scope: DiscountScope.line,
    value: 15,
    exclusive: false,
    isActive: false,
  ),
  _rule(
    id: 4,
    name: 'زبادي النسيم ٣ بدينار',
    scope: DiscountScope.line,
    valueType: DiscountValueType.multiBuy,
    value: 1.0,
    groupSize: 3,
    productCategories: const [1],
    redemptionCount: 12,
  ),
  _rule(
    id: 5,
    name: 'سعر الجملة المتدرّج',
    scope: DiscountScope.line,
    valueType: DiscountValueType.tiered,
    value: 0.35,
    tiers: const [
      DiscountTier(minQuantity: 6, unitPrice: 0.40),
      DiscountTier(minQuantity: 12, unitPrice: 0.35),
    ],
    redemptionCount: 7,
  ),
  _rule(
    id: 6,
    name: 'اشترِ ٢ والثالث مجانًا',
    scope: DiscountScope.line,
    valueType: DiscountValueType.buyXGetY,
    value: 100,
    buyQuantity: 2,
    getQuantity: 1,
    rewardType: DiscountBuyGetReward.free,
    productCategories: const [1],
    redemptionCount: 9,
  ),
];

final DiscountRulePerformance _performance = DiscountRulePerformance(
  summary: const DiscountPerformanceSummary(
    redemptionCount: 18,
    applicationCount: 24,
    documentCount: 18,
    salesDocumentCount: 18,
    purchaseDocumentCount: 0,
    uniqueCustomerCount: 11,
    uniqueSupplierCount: 0,
    anonymousBeneficiaryCount: 5,
    beneficiaryCount: 16,
    influencedGross: 4200,
    discountAmount: 640,
    influencedNet: 3560,
    averageDiscountAmount: 35.5,
    averageDocumentValue: 233,
    discountRatePercent: 15.2,
    usageLimit: 100,
    remainingUsage: 82,
    usagePercent: 18,
  ),
  incrementality: DiscountIncrementality(
    method: 'baseline',
    confidence: 'medium',
    baselinePeriodStart: DateTime(2026, 5, 1),
    baselinePeriodEnd: DateTime(2026, 5, 31),
    campaignPeriodStart: DateTime(2026, 6, 1),
    campaignPeriodEnd: DateTime(2026, 6, 30),
    baselineDays: 31,
    activeDays: 30,
    baselineDocumentCount: 14,
    baselineGross: 3200,
    baselineAverageDocumentValue: 228,
    expectedDocumentsWithoutDiscount: 13.5,
    expectedGrossWithoutDiscount: 3080,
    incrementalDocuments: 4.5,
    incrementalGross: 1120,
    estimatedIncrementalNetValue: 480,
    liftPercent: 12,
  ),
  channelBreakdown: const [
    DiscountChannelPerformance(
      channel: DiscountChannel.sales,
      redemptionCount: 18,
      documentCount: 18,
      discountAmount: 640,
      influencedGross: 4200,
      influencedNet: 3560,
    ),
    DiscountChannelPerformance(
      channel: DiscountChannel.purchasing,
      redemptionCount: 3,
      documentCount: 3,
      discountAmount: 90,
      influencedGross: 900,
      influencedNet: 810,
    ),
  ],
  monthlyTrend: const [
    DiscountTrendPoint(
      period: '2026-04',
      redemptionCount: 6,
      documentCount: 6,
      discountAmount: 180,
      influencedGross: 1400,
      influencedNet: 1220,
    ),
    DiscountTrendPoint(
      period: '2026-05',
      redemptionCount: 5,
      documentCount: 5,
      discountAmount: 150,
      influencedGross: 1200,
      influencedNet: 1050,
    ),
    DiscountTrendPoint(
      period: '2026-06',
      redemptionCount: 18,
      documentCount: 18,
      discountAmount: 640,
      influencedGross: 4200,
      influencedNet: 3560,
    ),
  ],
);

final List<DiscountBeneficiary> _beneficiaries = [
  DiscountBeneficiary(
    id: 'c1',
    partyType: 'customer',
    partyId: 1,
    name: 'أحمد علي',
    secondary: '0911234567',
    channel: DiscountChannel.sales,
    redemptionCount: 3,
    documentCount: 3,
    discountAmount: 90,
    influencedGross: 600,
    influencedNet: 510,
    firstRedeemedAt: DateTime(2026, 6, 4),
    lastRedeemedAt: DateTime(2026, 6, 14),
  ),
  DiscountBeneficiary(
    id: 'c2',
    partyType: 'customer',
    partyId: 2,
    name: 'سارة محمد',
    secondary: '0921112223',
    channel: DiscountChannel.sales,
    redemptionCount: 2,
    documentCount: 2,
    discountAmount: 60,
    influencedGross: 420,
    influencedNet: 360,
    firstRedeemedAt: DateTime(2026, 6, 6),
    lastRedeemedAt: DateTime(2026, 6, 12),
  ),
  DiscountBeneficiary(
    id: 'anon',
    partyType: 'walk_in',
    partyId: null,
    name: '',
    secondary: '',
    channel: DiscountChannel.sales,
    redemptionCount: 5,
    documentCount: 5,
    discountAmount: 150,
    influencedGross: 980,
    influencedNet: 830,
    firstRedeemedAt: DateTime(2026, 6, 2),
    lastRedeemedAt: DateTime(2026, 6, 15),
  ),
];
