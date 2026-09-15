import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/register_session.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/local_scoped_json_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/register_session_gate.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/responsive/responsive.dart';

final AuthorizationCapabilities _cashierCaps =
    AuthorizationCapabilities.forUser(
      PosUser.fromJson(const {
        'id': 1,
        'username': 'cashier',
        'role': 'cashier',
        'permissions': <String>[],
      }),
    );

/// Answers the "is a session open?" lookup either with a definite "no"
/// ([failing] false, a 204 from the backend) or with a failure — the case the
/// gate used to render as if it were a definite "no".
class _StubRegisterSessionRepository extends RegisterSessionRepository {
  _StubRegisterSessionRepository({required this.failing})
    : super(PosApiService());

  final bool failing;

  @override
  Future<Result<RegisterSession?>> loadCurrentSession() async {
    return failing
        ? Error<RegisterSession?>(Exception('register session unreachable'))
        : const Ok<RegisterSession?>(null);
  }
}

class _StubCatalogRepository extends CatalogRepository {
  _StubCatalogRepository() : super(PosApiService());
}

class _StubSaleRepository extends SaleRepository {
  _StubSaleRepository() : super(PosApiService());
}

class _StubShopSettingsRepository extends ShopSettingsRepository {
  _StubShopSettingsRepository() : super(PosApiService());
}

Future<PosViewModel> _gateViewModel({required bool failing}) async {
  final viewModel = PosViewModel(
    _StubCatalogRepository(),
    _StubRegisterSessionRepository(failing: failing),
    _StubSaleRepository(),
    _StubShopSettingsRepository(),
    PrintingRepository(PosApiService()),
    sessionStorage: MemoryScopedJsonStorage(),
  );
  await viewModel.loadCurrentRegisterSession();
  return viewModel;
}

Future<void> _pumpGate(WidgetTester tester, PosViewModel viewModel) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PointyTheme.light(),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: viewModel,
          builder: (context, _) => RegisterSessionGate(
            viewModel: viewModel,
            capabilities: _cashierCaps,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The gate's own retry/start buttons, by the keys the widget assigns them.
///
/// The start action is wrapped in a `TutorTarget` so a lesson can point at it,
/// and the key rides that wrapper — the action bar reads its contract off the
/// widget it is handed. These finders reach the button underneath, so the
/// assertions below still describe the control the cashier presses.
Finder _retryButton() =>
    find.byKey(const ValueKey('register_session_gate_retry_button'));
Finder _startButtonAction() =>
    find.byKey(const ValueKey('register_session_gate_start_button'));
Finder _startButton() => find.descendant(
  of: _startButtonAction(),
  matching: find.byWidgetPredicate(
    (widget) => widget is FilledButton || widget is OutlinedButton,
  ),
);

void main() {
  testWidgets('a definite "no open session" still leads with starting one', (
    tester,
  ) async {
    final viewModel = await _gateViewModel(failing: false);
    addTearDown(viewModel.dispose);

    await _pumpGate(tester, viewModel);

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    // The backend answered: there really is no open session, so say so.
    expect(find.text(l10n.noOpenRegisterSession), findsOneWidget);
    expect(find.text(l10n.registerSessionLoadError), findsNothing);
    expect(
      find.byType(PointyInlineMessage).evaluate().single.widget,
      isA<PointyInlineMessage>().having(
        (message) => message.tone,
        'tone',
        PointyInlineMessageTone.neutral,
      ),
    );

    // Starting the shift is the expected next step, so it stays the primary
    // (filled) action and the retry stays secondary.
    expect(tester.widget(_startButton()), isA<FilledButton>());
    expect(tester.widget(_retryButton()), isA<OutlinedButton>());
  });

  testWidgets('a failed lookup never claims there is no open session', (
    tester,
  ) async {
    final viewModel = await _gateViewModel(failing: true);
    addTearDown(viewModel.dispose);
    expect(viewModel.hasRegisterSessionError, isTrue);

    await _pumpGate(tester, viewModel);

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    // The lookup failed, so the app does not know whether a session is open —
    // asserting "there is none" would send the cashier to open a duplicate.
    expect(find.text(l10n.noOpenRegisterSession), findsNothing);
    expect(find.text(l10n.registerSessionLoadError), findsOneWidget);

    // And the copy has to name the fix, not just the failure.
    expect(l10n.registerSessionLoadError, contains('أعد المحاولة'));

    // Retry becomes the primary action; starting a second session is demoted
    // but stays reachable, so the cashier is never dead-ended.
    expect(tester.widget(_retryButton()), isA<FilledButton>());
    expect(tester.widget(_startButton()), isA<OutlinedButton>());
    expect(tester.widget<OutlinedButton>(_startButton()).onPressed, isNotNull);
  });

  testWidgets('the emphasised action is the last one in the bar', (
    tester,
  ) async {
    // The design system reads the trailing action as the primary one, so the
    // swap has to reorder the bar, not just restyle the buttons. Asserted on
    // the bar's own `actions` list rather than on screen coordinates: the two
    // buttons share a row here, and which side is "last" flips with RTL.
    Future<Key?> trailingActionKey({required bool failing}) async {
      final viewModel = await _gateViewModel(failing: failing);
      addTearDown(viewModel.dispose);
      await _pumpGate(tester, viewModel);
      final bar = tester.widget<ResponsiveActionBar>(
        find.byType(ResponsiveActionBar),
      );
      return bar.actions.last.key;
    }

    expect(
      await trailingActionKey(failing: false),
      const ValueKey('register_session_gate_start_button'),
    );
    expect(
      await trailingActionKey(failing: true),
      const ValueKey('register_session_gate_retry_button'),
    );
  });
}
