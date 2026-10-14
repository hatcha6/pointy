// Dev-only preview harness for التحقق من البطاقات (the Moamalat link) and the
// till's live card line. Safe to delete — a separate entrypoint, never
// imported by lib/main.dart.
//
// Run it with `make frontend-moamalat-preview`, then open:
//   ?screen=board      every state side by side (phone + wide)
//   ?screen=unlinked   the page before the first link
//   ?screen=alive      linked, kept warm by both holders
//   ?screen=at-risk    linked, keepalive failing for a while
//   ?screen=reauth     the token died; re-link form showing
//   ?screen=switched   switched off fleet-wide by Daftar
//   ?screen=sheet      the till's payment sheet with a card swipe seen
//   ?screen=sheet-short  the terminal took 20 of 25: split automatically
//   ?screen=sheet-early  cash line, a 25 swipe taken before the sheet opened
//   ?screen=sheet-over   the terminal took 30 of 25: warn only
//
// See AGENTS.md — a black canvas after start is a browser refresh issue, not a
// slow compile. Reload once.

import 'package:flutter/material.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/moamalat.dart';
import 'package:pointy_frontend/src/data/repositories/moamalat_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/card_verification/view_models/moamalat_link_view_model.dart';
import 'package:pointy_frontend/src/features/card_verification/views/moamalat_page.dart';
import 'package:pointy_frontend/src/features/pos/views/payment/payment.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() {
  runApp(const MoamalatPreviewApp());
}

class MoamalatPreviewApp extends StatelessWidget {
  const MoamalatPreviewApp({super.key});

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
        'board' => const _Board(),
        'sheet' => const _SheetPreview(swiped: 25),
        'sheet-short' => const _SheetPreview(swiped: 20),
        'sheet-over' => const _SheetPreview(swiped: 30),
        'sheet-early' => const _SheetPreview(swiped: 25, cashFirst: true),
        _ => _page(_statusFor(screen)),
      },
    );
  }
}

MoamalatStatus _statusFor(String screen) {
  final now = DateTime.now();
  const linked = MoamalatStatus(
    state: MoamalatLinkState.alive,
    canManage: true,
    username: 'shop-user',
    mid: '000000000145771',
    merchantName: 'CARD SHOP',
    linkedBy: 'supervisor',
    pendingCount: 1,
    relay: MoamalatRelayCopy(holdsCopy: true, inStep: true, state: 'alive'),
  );
  MoamalatStatus copy({
    MoamalatLinkState? state,
    bool atRisk = false,
    bool switchedOff = false,
    int pending = 1,
    int overdue = 0,
  }) => MoamalatStatus(
    state: state ?? linked.state,
    atRisk: atRisk,
    switchedOff: switchedOff,
    canManage: true,
    username: linked.username,
    mid: linked.mid,
    merchantName: linked.merchantName,
    linkedBy: linked.linkedBy,
    linkedAt: now.subtract(const Duration(days: 3)),
    lastOkAt: now.subtract(const Duration(minutes: 2)),
    pendingCount: pending,
    pendingOverdueCount: overdue,
    relay: linked.relay,
  );
  return switch (screen) {
    'unlinked' => const MoamalatStatus(canManage: true),
    'at-risk' => copy(atRisk: true),
    'reauth' => copy(
      state: MoamalatLinkState.needsReauth,
      pending: 7,
      overdue: 2,
    ),
    'switched' => copy(switchedOff: true),
    _ => copy(),
  };
}

Widget _page(MoamalatStatus status) =>
    MoamalatPage(viewModel: MoamalatLinkViewModel(_FakeRepository(status)));

class _FakeRepository extends MoamalatRepository {
  _FakeRepository(this.status, {this.swiped}) : super(PosApiService());

  final MoamalatStatus status;
  final double? swiped;

  @override
  Future<Result<MoamalatStatus>> loadStatus() async => Ok(status);

  @override
  Future<Result<MoamalatWatch>> watch({
    double? amount,
    Duration? lookback,
  }) async => Ok(
    MoamalatWatch(
      state: MoamalatLinkState.alive,
      watching: true,
      swipes: [
        if (swiped != null)
          MoamalatSwipe(
            rrn: '627416000329',
            terminalId: '0JNSWZ11',
            amount: swiped!,
            at: DateTime.now().subtract(const Duration(minutes: 2)),
          ),
      ],
    ),
  );
}

class _Board extends StatelessWidget {
  const _Board();

  @override
  Widget build(BuildContext context) {
    Widget frame(String screen, double width) => SizedBox(
      width: width,
      height: 900,
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          size: Size(width, 900),
          padding: EdgeInsets.zero,
          viewInsets: EdgeInsets.zero,
        ),
        child: ClipRect(child: _page(_statusFor(screen))),
      ),
    );
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Wrap(
          spacing: 24,
          runSpacing: 24,
          children: [
            for (final screen in ['unlinked', 'alive', 'at-risk', 'reauth'])
              frame(screen, 390),
            frame('alive', 900),
          ],
        ),
      ),
    );
  }
}

class _SheetPreview extends StatelessWidget {
  const _SheetPreview({required this.swiped, this.cashFirst = false});

  final double swiped;
  final bool cashFirst;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SizedBox.expand(
        child: PaymentSheet(
          total: 25,
          // Card first, as a card sale opens — or cash, the till's default.
          enableCashPayments: cashFirst,
          enableCardPayments: true,
          enableTransferPayments: false,
          requireCardReceipt: false,
          trustedCardTerminalIds: const [],
          showPrintInvoiceToggle: false,
          printInvoiceAfterPayment: false,
          onPrintInvoiceChanged: (_) {},
          showShareInvoiceToggle: false,
          shareInvoiceAfterPayment: false,
          onShareInvoiceChanged: (_) {},
          moamalatRepository: _FakeRepository(
            _statusFor('alive'),
            swiped: swiped,
          ),
          onSubmit: (_) {},
          onCancel: () {},
        ),
      ),
    );
  }
}
