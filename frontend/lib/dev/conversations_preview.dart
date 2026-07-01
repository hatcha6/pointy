// Dev-only preview harness for the customer conversation thread (CRM inbox).
//
// Renders a single chat thread full-viewport with a fake repository (no
// backend). Pick the scenario with `?screen=`. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/conversations_preview.dart
//
// Scenarios: active (messages + composer) | empty | readonly
//
// See AGENTS.md ("UI preview harness"). Not part of the shipping app.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/models/conversation.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/crm_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/crm/view_models/conversations_view_model.dart';
import 'package:pointy_frontend/src/features/crm/views/conversations_screen.dart';
import 'package:pointy_frontend/src/features/crm/views/new_conversation_dialog.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    final scenario = _screen();
    const summary = Conversation(
      id: 1,
      phone: '+218912345678',
      customerName: 'علي محمد',
      unreadCount: 2,
    );
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
      home: scenario == 'new'
          ? const _NewConversationSurface()
          : ConversationThreadScreen(
              viewModel: ConversationThreadViewModel(
                _FakeCrmRepository(scenario),
                summary,
              ),
              canReply: scenario != 'readonly',
            ),
    );
  }
}

/// Previews the "start a new conversation" flow: the FAB opens the picker dialog
/// (select or create a customer, phone required), then drops into the thread.
class _NewConversationSurface extends StatelessWidget {
  const _NewConversationSurface();

  Future<void> _start(BuildContext context) async {
    final customer = await showNewConversationDialog(
      context: context,
      contactRepository: _FakeContactRepository(),
    );
    if (customer == null || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConversationThreadScreen(
          viewModel: ConversationThreadViewModel(
            _FakeCrmRepository('empty'),
            Conversation(
              id: 1,
              phone: customer.phone,
              customerName: customer.fullName,
            ),
          ),
          canReply: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyScaffold(
      appBar: PointyAppBar(title: Text(l10n.conversationsTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _start(context),
        icon: const Icon(Icons.add_comment_outlined),
        label: Text(l10n.newConversationTitle),
      ),
      body: Center(child: Text(l10n.conversationsEmpty)),
    );
  }
}

class _FakeContactRepository extends ContactRepository {
  _FakeContactRepository() : super(PosApiService());

  @override
  Future<Result<CustomerPage>> loadCustomers({
    required ContactQuery query,
    int page = 1,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return const Ok(
      CustomerPage(
        customers: [
          Customer(
            id: 1,
            customerNumber: 'C-1',
            fullName: 'علي محمد',
            phone: '0912345678',
            email: '',
            gender: CustomerGender.male,
            marketingConsent: false,
            notes: '',
            isActive: true,
          ),
          Customer(
            id: 2,
            customerNumber: 'C-2',
            fullName: 'سارة (بدون هاتف)',
            phone: '',
            email: '',
            gender: CustomerGender.female,
            marketingConsent: false,
            notes: '',
            isActive: true,
          ),
        ],
        hasMore: false,
      ),
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
  return parsed?.queryParameters['screen'] ?? 'active';
}

class _FakeCrmRepository extends CrmRepository {
  _FakeCrmRepository(this.scenario) : super(PosApiService());

  final String scenario;

  @override
  Future<Result<Conversation>> loadConversation(int id) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (scenario == 'empty') {
      return const Ok(
        Conversation(id: 1, phone: '+218912345678', customerName: 'علي محمد'),
      );
    }
    return Ok(
      Conversation(
        id: 1,
        phone: '+218912345678',
        customerName: 'علي محمد',
        messages: [
          ConversationMessage(
            id: 1,
            direction: MessageDirection.inbound,
            body: 'مرحبًا، هل الطلب جاهز؟',
            createdAt: DateTime(2026, 6, 30, 12, 5),
          ),
          ConversationMessage(
            id: 2,
            direction: MessageDirection.outbound,
            body: 'نعم، جاهز للاستلام الآن ✅',
            outboundStatus: 'delivered',
            createdAt: DateTime(2026, 6, 30, 12, 7),
          ),
          ConversationMessage(
            id: 3,
            direction: MessageDirection.inbound,
            body: 'شكرًا جزيلًا',
            createdAt: DateTime(2026, 6, 30, 12, 9),
          ),
        ],
      ),
    );
  }

  @override
  Future<Result<Conversation>> markRead(int id) async {
    return const Ok(Conversation(id: 1, phone: '+218912345678'));
  }

  @override
  Future<Result<ConversationMessage>> reply(int id, String body) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return Ok(
      ConversationMessage(
        id: 99,
        direction: MessageDirection.outbound,
        body: body,
        outboundStatus: 'sent',
        createdAt: DateTime(2026, 6, 30, 12, 12),
      ),
    );
  }
}
