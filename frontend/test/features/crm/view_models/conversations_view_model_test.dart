import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/models/conversation.dart';
import 'package:pointy_frontend/src/data/repositories/crm_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/crm/view_models/conversations_view_model.dart';

const _customer = Customer(
  id: 7,
  customerNumber: 'C-7',
  fullName: 'علي محمد',
  phone: '0912345678',
  email: '',
  gender: CustomerGender.male,
  marketingConsent: false,
  notes: '',
  isActive: true,
);

class _FakeCrmRepository extends CrmRepository {
  _FakeCrmRepository({this.started, this.fail = false}) : super(PosApiService());

  final Conversation? started;
  final bool fail;
  int startCalls = 0;
  int? lastCustomerId;

  @override
  Future<Result<Conversation>> startConversation(int customerId) async {
    startCalls++;
    lastCustomerId = customerId;
    if (fail) return const Error(FormatException('boom'));
    return Ok(started!);
  }
}

void main() {
  group('ConversationsViewModel.startConversation', () {
    test('opens the thread and surfaces it at the top of the inbox', () async {
      final repo = _FakeCrmRepository(
        started: const Conversation(
          id: 42,
          phone: '+218912345678',
          customerName: 'علي محمد',
        ),
      );
      final vm = ConversationsViewModel(repo);

      final result = await vm.startConversation(_customer);

      expect(result?.id, 42);
      expect(repo.lastCustomerId, 7);
      expect(vm.conversations.first.id, 42);
      expect(vm.isStarting, isFalse);
    });

    test('resuming an existing thread does not duplicate its inbox row', () async {
      final repo = _FakeCrmRepository(
        started: const Conversation(id: 42, phone: '+218912345678'),
      );
      final vm = ConversationsViewModel(repo);

      await vm.startConversation(_customer);
      await vm.startConversation(_customer);

      expect(vm.conversations.where((c) => c.id == 42).length, 1);
      expect(repo.startCalls, 2);
    });

    test('returns null and leaves the inbox untouched when the start fails', () async {
      final repo = _FakeCrmRepository(fail: true);
      final vm = ConversationsViewModel(repo);

      final result = await vm.startConversation(_customer);

      expect(result, isNull);
      expect(vm.conversations, isEmpty);
      expect(vm.isStarting, isFalse);
    });
  });
}
