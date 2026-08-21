import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/models/conversation.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/crm_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/crm/view_models/conversations_view_model.dart';
import 'package:pointy_frontend/src/features/crm/views/conversations_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../shared/fake_app_navigation.dart';

const _manager = PosUser(
  id: 1,
  username: 'manager',
  displayName: 'مدير',
  role: UserRole.manager,
  isActive: true,
);

const _customer = Customer(
  id: 7,
  customerNumber: 'C-7',
  fullName: 'علي',
  phone: '0910000000',
  email: '',
  gender: CustomerGender.unspecified,
  marketingConsent: true,
  notes: '',
  isActive: true,
);

const _summary = Conversation(id: 4, phone: '0910000000', customerName: 'علي');

/// One outbound message per backend status, so the thread renders every branch
/// the bubble can take. Statuses mirror `OutboundMessage.Status` in
/// apps.messaging.
const _statuses = [
  'queued',
  'scheduled',
  'sending',
  'sent',
  'delivered',
  'failed',
  'cancelled',
  'blocked_consent',
  'expired',
];

Conversation _threadWithEveryStatus() {
  return Conversation(
    id: 4,
    phone: '0910000000',
    customerName: 'علي',
    messages: [
      for (final (index, status) in _statuses.indexed)
        ConversationMessage(
          id: index + 1,
          direction: MessageDirection.outbound,
          body: 'رسالة $status',
          outboundStatus: status,
        ),
    ],
  );
}

class _FakeCrmRepository extends CrmRepository {
  _FakeCrmRepository({Conversation? thread})
    : thread = thread ?? _summary,
      super(PosApiService());

  final Conversation thread;

  /// Lets a test hold `startConversation` open and inspect the in-flight frame.
  Completer<Result<Conversation>>? startGate;

  @override
  Future<Result<Conversation>> loadConversation(int id) async {
    return Ok(thread);
  }

  @override
  Future<Result<List<Conversation>>> loadConversations({String? status}) async {
    return const Ok([]);
  }

  @override
  Future<Result<Conversation>> markRead(int id) async => Ok(thread);

  @override
  Future<Result<Conversation>> startConversation(int customerId) {
    final gate = startGate;
    if (gate != null) return gate.future;
    return Future.value(Ok(thread));
  }
}

Widget _app(Widget home) {
  return MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: PointyTheme.light(),
    home: home,
  );
}

Future<ConversationThreadViewModel> _pumpThread(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final repository = _FakeCrmRepository(thread: _threadWithEveryStatus());
  final viewModel = ConversationThreadViewModel(repository, _summary);
  addTearDown(viewModel.dispose);

  await tester.pumpWidget(
    _app(ConversationThreadScreen(viewModel: viewModel, canReply: true)),
  );
  await tester.pumpAndSettle();
  return viewModel;
}

/// The tooltip a status icon carries, by the status string. Reads the widget
/// tree rather than hovering, so it also proves the semantics label the icon
/// exposes to a screen reader.
Tooltip _tooltipFor(WidgetTester tester, String status) {
  return tester.widget<Tooltip>(
    find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is ConversationMessageStatus && w.status == status,
      ),
      matching: find.byType(Tooltip),
    ),
  );
}

Icon _iconFor(WidgetTester tester, String status) {
  return tester.widget<Icon>(
    find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is ConversationMessageStatus && w.status == status,
      ),
      matching: find.byType(Icon),
    ),
  );
}

void main() {
  testWidgets('every outbound status names itself instead of a bare glyph', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await _pumpThread(tester);

    // A status the reader cannot act on stays an icon, but the icon is now
    // labelled — for the tooltip on a till PC and for a screen reader.
    expect(
      _tooltipFor(tester, 'delivered').message,
      l10n.conversationMessageStatusDelivered,
    );
    expect(
      _iconFor(tester, 'delivered').semanticLabel,
      l10n.conversationMessageStatusDelivered,
    );
    expect(
      _tooltipFor(tester, 'sent').message,
      l10n.conversationMessageStatusSent,
    );
    expect(
      _tooltipFor(tester, 'sending').message,
      l10n.conversationMessageStatusSending,
    );
    expect(
      _tooltipFor(tester, 'scheduled').message,
      l10n.conversationMessageStatusScheduled,
    );
    expect(
      _tooltipFor(tester, 'queued').message,
      l10n.conversationMessageStatusQueued,
    );
  });

  testWidgets('a message that needs attention spells its state out', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await _pumpThread(tester);

    // These four are the states someone has to do something about — resend,
    // or stop messaging a customer who opted out — so they are readable at a
    // glance, not hidden behind a long-press.
    expect(find.text(l10n.conversationMessageStatusFailed), findsOneWidget);
    expect(find.text(l10n.conversationMessageStatusBlocked), findsOneWidget);
    expect(find.text(l10n.conversationMessageStatusCancelled), findsOneWidget);
    expect(find.text(l10n.conversationMessageStatusExpired), findsOneWidget);

    // The spelled-out label is not read twice by a screen reader.
    expect(_iconFor(tester, 'failed').semanticLabel, isNull);

    // States still on their way stay quiet — the thread must not turn into a
    // wall of status text.
    expect(find.text(l10n.conversationMessageStatusDelivered), findsNothing);
    expect(find.text(l10n.conversationMessageStatusQueued), findsNothing);
  });

  testWidgets('a message that will never arrive no longer looks queued', (
    tester,
  ) async {
    await _pumpThread(tester);

    // `cancelled` and `expired` both fell through to the same clock icon as a
    // message still waiting its turn, which is the confusion this fixes.
    final queued = _iconFor(tester, 'queued').icon;
    expect(_iconFor(tester, 'cancelled').icon, isNot(queued));
    expect(_iconFor(tester, 'expired').icon, isNot(queued));
    expect(_iconFor(tester, 'blocked_consent').icon, isNot(queued));
  });

  testWidgets('the new-conversation button says it is working', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final repository = _FakeCrmRepository();
    final viewModel = ConversationsViewModel(repository);
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      _app(
        ConversationsScreen(
          viewModel: viewModel,
          navigation: FakeAppNavigation(currentUser: _manager),
          capabilities: AuthorizationCapabilities.forUser(_manager),
          contactRepository: ContactRepository(PosApiService()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // At rest the button invites, and it works.
    expect(find.text(l10n.newConversationTitle), findsOneWidget);
    expect(
      tester
          .widget<FloatingActionButton>(find.byType(FloatingActionButton))
          .onPressed,
      isNotNull,
    );

    // Hold the request open and pump the in-flight frame: the button must say
    // what it is doing, not just go inert while the cashier taps it again.
    final gate = Completer<Result<Conversation>>();
    repository.startGate = gate;
    unawaited(viewModel.startConversation(_customer));
    await tester.pump();

    expect(find.text(l10n.newConversationStarting), findsOneWidget);
    expect(find.text(l10n.newConversationTitle), findsNothing);
    expect(
      find.descendant(
        of: find.byType(FloatingActionButton),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FloatingActionButton>(find.byType(FloatingActionButton))
          .onPressed,
      isNull,
    );

    gate.complete(Ok(_summary));
    await tester.pumpAndSettle();
    expect(find.text(l10n.newConversationTitle), findsOneWidget);
  });
}
