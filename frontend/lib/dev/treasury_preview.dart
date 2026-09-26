// Dev-only preview harness for الخزينة (the money position). Safe to delete —
// it is a separate entrypoint and is never imported by lib/main.dart.
//
// Run it with `make frontend-treasury-preview`, then open:
//   ?screen=board      every state side by side (phone + wide)
//   ?screen=position   the screen full-viewport, for responsive QA
//   ?screen=variance   a shop whose cash box disagrees with its count
//   ?screen=details    the account drill-down sheet, already open
//   ?screen=empty      a shop with no accounts yet
//   ?screen=banks      a shop with TWO identified banks (marks, IBAN, QR)
//   ?screen=editor     the account editor, already open
//   ?screen=funding    the "add funds" sheet (capital in), already open
//   ?screen=bankqr     the IBAN / account-number code a customer scans
//   ?screen=bankqr-partial  the same sheet when only one of the two is saved
//   ?screen=picker     the checkout bank picker, in each of its three states
//
// See AGENTS.md — a black canvas after start is a browser refresh issue, not a
// slow compile. Reload once.

import 'package:flutter/material.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/money_position.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/treasury_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/treasury/view_models/money_position_view_model.dart';
import 'package:pointy_frontend/src/features/treasury/views/money_account_details_sheet.dart';
import 'package:pointy_frontend/src/features/treasury/views/money_account_editor_sheet.dart';
import 'package:pointy_frontend/src/features/treasury/views/money_funding_sheet.dart';
import 'package:pointy_frontend/src/features/treasury/views/money_position_screen.dart';
import 'package:pointy_frontend/src/shared/payments/bank_account_details_sheet.dart';
import 'package:pointy_frontend/src/shared/payments/bank_account_picker.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() {
  runApp(const TreasuryPreviewApp());
}

class TreasuryPreviewApp extends StatelessWidget {
  const TreasuryPreviewApp({super.key});

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
        'position' => _screen(_healthyPosition()),
        'variance' => _screen(_variancePosition()),
        'empty' => _screen(_emptyPosition()),
        'details' => _DetailsHost(position: _healthyPosition()),
        'banks' => _screen(_twoBankPosition()),
        'editor' => _SheetHost(
          position: _twoBankPosition(),
          open: (context, viewModel) async {
            await showMoneyAccountEditorSheet(
              context,
              viewModel: viewModel,
              account: viewModel.accountById(2)?.account,
            );
          },
        ),
        'funding' => _SheetHost(
          position: _twoBankPosition(),
          open: (context, viewModel) => showMoneyFundingSheet(
            context,
            viewModel: viewModel,
            direction: MoneyFundingDirection.addFunds,
          ),
        ),
        'bankqr' => _SheetHost(
          position: _twoBankPosition(),
          open: (context, viewModel) => showBankAccountDetailsSheet(
            context,
            account: viewModel.accountById(2)!.account,
          ),
        ),
        // The same sheet for an account that carries only an IBAN.
        'bankqr-partial' => _SheetHost(
          position: _twoBankPosition(),
          open: (context, viewModel) => showBankAccountDetailsSheet(
            context,
            account: viewModel.accountById(3)!.account,
          ),
        ),
        'picker' => const _PickerGallery(),
        _ => const _Board(),
      },
    );
  }
}

Widget _screen(MoneyPosition position) {
  final viewModel = MoneyPositionViewModel(_FakeRepository(position));
  return MoneyPositionScreen(
    viewModel: viewModel,
    capabilities: _navigation.capabilities,
    navigation: _navigation,
    onOpenPaymentsLedger: () {},
  );
}

/// Opens the account sheet on load, so the drill-down can be screenshotted
/// without driving a tap through a Flutter-web canvas.
class _DetailsHost extends StatefulWidget {
  const _DetailsHost({required this.position});

  final MoneyPosition position;

  @override
  State<_DetailsHost> createState() => _DetailsHostState();
}

class _DetailsHostState extends State<_DetailsHost> {
  late final MoneyPositionViewModel _viewModel = MoneyPositionViewModel(
    _FakeRepository(widget.position),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _viewModel.load();
      if (!mounted) {
        return;
      }
      await showMoneyAccountDetailsSheet(
        context,
        viewModel: _viewModel,
        capabilities: _navigation.capabilities,
        accountId: 1,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return MoneyPositionScreen(
      viewModel: _viewModel,
      capabilities: _navigation.capabilities,
      navigation: _navigation,
    );
  }
}

/// Opens an arbitrary sheet on load, so a sheet can be screenshotted without
/// driving a tap through a Flutter-web canvas.
class _SheetHost extends StatefulWidget {
  const _SheetHost({required this.position, required this.open});

  final MoneyPosition position;
  final Future<void> Function(BuildContext, MoneyPositionViewModel) open;

  @override
  State<_SheetHost> createState() => _SheetHostState();
}

class _SheetHostState extends State<_SheetHost> {
  late final MoneyPositionViewModel _viewModel = MoneyPositionViewModel(
    _FakeRepository(widget.position),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _viewModel.load();
      if (!mounted) {
        return;
      }
      await widget.open(context, _viewModel);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MoneyPositionScreen(
      viewModel: _viewModel,
      capabilities: _navigation.capabilities,
      navigation: _navigation,
    );
  }
}

/// The checkout control in each state it can be in, side by side: hidden,
/// stated, chosen, and chosen by the terminal that printed the slip.
class _PickerGallery extends StatefulWidget {
  const _PickerGallery();

  @override
  State<_PickerGallery> createState() => _PickerGalleryState();
}

class _PickerGalleryState extends State<_PickerGallery> {
  int? _selected = 2;

  static const _oneGeneric = [
    MoneyAccount(id: 9, name: 'المصرف', kind: MoneyAccountKind.bank),
  ];
  static const _oneIdentified = [
    MoneyAccount(
      id: 2,
      name: 'حساب المحل',
      kind: MoneyAccountKind.bank,
      bankName: 'مصرف الجمهورية',
      bankSlug: 'jbank',
      iban: 'LY83002104000000201050050',
      isDefault: true,
    ),
  ];
  static const _two = [
    ..._oneIdentified,
    MoneyAccount(
      id: 3,
      name: 'حساب الأمان',
      kind: MoneyAccountKind.bank,
      bankName: 'مصرف الأمان',
      bankSlug: 'aman',
      accountNumber: '9930114477',
      iban: 'LY19002200000000993011447',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            _case('متجر بحساب واحد غير معرّف — لا يظهر شيء', const [
              BankAccountPicker(
                accounts: _oneGeneric,
                selectedId: null,
                onChanged: _ignore,
              ),
            ]),
            _case('حساب واحد معرّف — يُذكر ولا يُسأل عنه', [
              BankAccountPicker(
                accounts: _oneIdentified,
                selectedId: 2,
                onChanged: (_) {},
              ),
            ]),
            _case('مصرفان — اختيار', [
              BankAccountPicker(
                accounts: _two,
                selectedId: _selected,
                onChanged: (value) => setState(() => _selected = value),
              ),
            ]),
            _case('اختير تلقائيًا من الماكينة', [
              BankAccountPicker(
                accounts: _two,
                selectedId: 3,
                autoSelectedTerminal: '9XQQPL42',
                onChanged: (_) {},
              ),
            ]),
          ],
        ),
      ),
    );
  }

  static void _ignore(int? value) {}

  Widget _case(String label, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
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
              _frame('الوضع الطبيعي — هاتف', 390, 844, _healthyPosition()),
              _frame('فروقات في الجرد — هاتف', 390, 844, _variancePosition()),
              _frame('لا حسابات — هاتف', 390, 844, _emptyPosition()),
              _frame('مصرفان — هاتف', 390, 844, _twoBankPosition()),
              _frame('الوضع الطبيعي — عريض', 900, 844, _healthyPosition()),
              _frame('مصرفان — عريض', 900, 844, _twoBankPosition()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _frame(String label, double width, double height, MoneyPosition p) {
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
              child: _screen(p),
            ),
          ),
        ),
      ],
    );
  }
}

// --- fakes -------------------------------------------------------------------

class _FakeRepository extends TreasuryRepository {
  _FakeRepository(this._position) : super(PosApiService());

  final MoneyPosition _position;

  @override
  Future<Result<MoneyPosition>> loadPosition({DateTime? asOf}) async =>
      Ok(_position);

  @override
  Future<Result<MoneyMovementPage>> loadAccountMovements(
    int accountId, {
    DateTime? start,
    DateTime? end,
  }) async {
    return Ok(
      MoneyMovementPage(
        rows: [
          _movement('sales', 240.50, DateTime(2026, 8, 27)),
          _movement('expenses', -60, DateTime(2026, 8, 27), 'كهرباء · العداد'),
          _movement('suppliers', -180, DateTime(2026, 8, 26), 'مؤسسة النور'),
          _movement('drawer_out', -25, DateTime(2026, 8, 26), 'سلفة'),
          _movement('transfer_out', -500, DateTime(2026, 8, 25), 'إيداع'),
          _movement('payroll', -300, DateTime(2026, 8, 25)),
        ],
      ),
    );
  }

  MoneyMovement _movement(
    String source,
    double amount,
    DateTime date, [
    String description = '',
  ]) {
    return MoneyMovement(
      source: source,
      amount: amount,
      isInflow: amount >= 0,
      date: date,
      description: description,
    );
  }
}

final _navigation = _FakeNavigation();

class _FakeNavigation implements AppNavigation {
  @override
  final PosUser currentUser = PosUser.fromJson(const {
    'id': 1,
    'username': 'owner',
    'display_name': 'المالك',
    'email': '',
    'role': 'manager',
    'permissions': ['payments.view_payment', 'treasury.view_moneyaccount'],
    'is_active': true,
  });

  @override
  late final AuthorizationCapabilities capabilities =
      AuthorizationCapabilities.forUser(currentUser);

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

MoneyPosition _healthyPosition() => _buildPosition();

MoneyPosition _variancePosition() => _buildPosition(
  cashCount: const MoneyCount(
    id: 1,
    accountId: 1,
    countedAmount: 1155.25,
    expectedAmount: 1180.75,
    variance: -25.50,
    note: 'ناقص من درج المساء',
  ),
  accountsWithVariance: 1,
);

/// A shop that has outgrown one bank: two identified accounts, each with its
/// own mark and its own IBAN, which is the whole case this feature exists for.
MoneyPosition _twoBankPosition() {
  return MoneyPosition(
    accounts: [
      MoneyAccountPosition(
        account: MoneyAccount(
          id: 1,
          name: 'الخزينة',
          kind: MoneyAccountKind.cash,
          isDefault: true,
          isRouted: true,
          openingBalance: 300,
          openingAt: DateTime(2026, 8, 1),
        ),
        expectedBalance: 1180.75,
        components: const [
          MoneyPositionComponent(code: 'opening', amount: 300, isInflow: true),
          MoneyPositionComponent(code: 'sales', amount: 880.75, isInflow: true),
        ],
      ),
      MoneyAccountPosition(
        account: MoneyAccount(
          id: 2,
          name: 'حساب المحل',
          kind: MoneyAccountKind.bank,
          bankName: 'مصرف الجمهورية',
          bankSlug: 'jbank',
          accountNumber: '0021005050',
          iban: 'LY83002104000000201050050',
          isDefault: true,
          isRouted: true,
          openingAt: DateTime(2026, 8, 1),
        ),
        expectedBalance: 3420.00,
        components: const [
          MoneyPositionComponent(code: 'opening', amount: 2600, isInflow: true),
          MoneyPositionComponent(code: 'sales', amount: 832, isInflow: true),
          MoneyPositionComponent(
            code: 'commission',
            amount: -12,
            isInflow: false,
          ),
        ],
        lastCount: const MoneyCount(
          id: 2,
          accountId: 2,
          countedAmount: 3420.00,
          expectedAmount: 3420.00,
          variance: 0,
        ),
      ),
      MoneyAccountPosition(
        account: MoneyAccount(
          id: 3,
          name: 'حساب الأمان',
          kind: MoneyAccountKind.bank,
          bankName: 'مصرف الأمان',
          bankSlug: 'aman',
          // Deliberately IBAN-only: the shop that entered half its details,
          // which is the case the greyed toggle segment exists for.
          iban: 'LY19002200000000993011447',
          openingAt: DateTime(2026, 8, 1),
        ),
        expectedBalance: 1260.00,
        components: const [
          MoneyPositionComponent(code: 'opening', amount: 900, isInflow: true),
          MoneyPositionComponent(code: 'sales', amount: 360, isInflow: true),
        ],
      ),
    ],
    totals: const MoneyPositionTotals(
      cash: 1180.75,
      bank: 4680.00,
      total: 5860.75,
      accountsCounted: 1,
      accountsTotal: 3,
    ),
  );
}

MoneyPosition _emptyPosition() =>
    const MoneyPosition(accounts: [], totals: MoneyPositionTotals());

MoneyPosition _buildPosition({
  MoneyCount? cashCount,
  int accountsWithVariance = 0,
}) {
  return MoneyPosition(
    accounts: [
      MoneyAccountPosition(
        account: MoneyAccount(
          id: 1,
          name: 'الخزينة',
          kind: MoneyAccountKind.cash,
          isDefault: true,
          isRouted: true,
          openingBalance: 300,
          openingAt: DateTime(2026, 8, 1),
        ),
        expectedBalance: 1180.75,
        components: const [
          MoneyPositionComponent(code: 'opening', amount: 300, isInflow: true),
          MoneyPositionComponent(
            code: 'sales',
            amount: 2145.75,
            isInflow: true,
          ),
          MoneyPositionComponent(code: 'drawer_in', amount: 60, isInflow: true),
          MoneyPositionComponent(
            code: 'drawer_out',
            amount: -25,
            isInflow: false,
          ),
          MoneyPositionComponent(
            code: 'expenses',
            amount: -180,
            isInflow: false,
          ),
          MoneyPositionComponent(
            code: 'suppliers',
            amount: -320,
            isInflow: false,
          ),
          MoneyPositionComponent(
            code: 'payroll',
            amount: -300,
            isInflow: false,
          ),
          MoneyPositionComponent(
            code: 'transfer_out',
            amount: -500,
            isInflow: false,
          ),
        ],
        lastCount: cashCount,
      ),
      MoneyAccountPosition(
        account: MoneyAccount(
          id: 2,
          name: 'حساب التشغيل',
          kind: MoneyAccountKind.bank,
          bankName: 'مصرف الوحدة',
          accountNumber: '5050',
          isDefault: true,
          isRouted: true,
          openingAt: DateTime(2026, 8, 1),
        ),
        expectedBalance: 3420.00,
        components: const [
          MoneyPositionComponent(code: 'opening', amount: 2600, isInflow: true),
          MoneyPositionComponent(code: 'sales', amount: 640, isInflow: true),
          MoneyPositionComponent(
            code: 'commission',
            amount: -12,
            isInflow: false,
          ),
          MoneyPositionComponent(
            code: 'transfer_in',
            amount: 500,
            isInflow: true,
          ),
          MoneyPositionComponent(
            code: 'suppliers',
            amount: -308,
            isInflow: false,
          ),
        ],
        lastCount: const MoneyCount(
          id: 2,
          accountId: 2,
          countedAmount: 3420.00,
          expectedAmount: 3420.00,
          variance: 0,
        ),
      ),
      MoneyAccountPosition(
        account: const MoneyAccount(
          id: 3,
          name: 'صندوق الفرع',
          kind: MoneyAccountKind.cash,
        ),
        expectedBalance: 145.00,
        components: const [
          MoneyPositionComponent(code: 'opening', amount: 145, isInflow: true),
        ],
      ),
    ],
    totals: MoneyPositionTotals(
      cash: 1325.75,
      bank: 3420.00,
      total: 4745.75,
      accountsCounted: cashCount == null ? 1 : 2,
      accountsTotal: 3,
      accountsWithVariance: accountsWithVariance,
    ),
  );
}
