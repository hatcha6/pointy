import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/ai_chat.dart';

void main() {
  group('AiMessage streaming notifications', () {
    test('appendContent mutates in place and notifies once per non-empty delta', () {
      final message = AiMessage(role: AiMessageRole.assistant, content: '');
      var notifications = 0;
      message.addListener(() => notifications++);

      message.appendContent('Hel');
      message.appendContent('lo');
      message.appendContent(''); // empty delta is a no-op (no rebuild)

      expect(message.content, 'Hello');
      expect(notifications, 2);
    });

    test('appendReasoning accumulates separately and notifies', () {
      final message = AiMessage(role: AiMessageRole.assistant, content: '');
      var notifications = 0;
      message.addListener(() => notifications++);

      message.appendReasoning('think ');
      message.appendReasoning('more');

      expect(message.reasoning, 'think more');
      expect(message.content, '');
      expect(notifications, 2);
    });

    test('startToolRun / finishToolRun update the matching run and notify', () {
      final message = AiMessage(role: AiMessageRole.assistant, content: '');
      var notifications = 0;
      message.addListener(() => notifications++);

      message.startToolRun(AiToolRun(name: 'query_resource', resource: 'orders'));
      message.finishToolRun(name: 'query_resource', resource: 'orders', ok: true);

      expect(message.toolRuns.length, 1);
      expect(message.toolRuns.single.done, isTrue);
      expect(message.toolRuns.single.ok, isTrue);
      expect(notifications, 2);
    });

    test('markStreamingComplete flips the flag and notifies only when streaming', () {
      final message = AiMessage(
        role: AiMessageRole.assistant,
        content: 'done',
        isStreaming: true,
      );
      var notifications = 0;
      message.addListener(() => notifications++);

      message.markStreamingComplete();
      message.markStreamingComplete(); // already complete — no second notify

      expect(message.isStreaming, isFalse);
      expect(notifications, 1);
    });
  });

  group('AiQuestion parsing', () {
    test('maps known types and reads typed config getters', () {
      final question = AiQuestion.fromJson({
        'id': 'q1',
        'type': 'single_select',
        'prompt': 'أي فرع؟',
        'help': 'اختر واحدًا',
        'config': {
          'options': [
            {'value': 'main', 'label': 'الرئيسي'},
            {'value': 'branch'},
          ],
          'allow_other': true,
          'min_select': 1,
          'unit': 'كجم',
        },
      });

      expect(question.type, AiQuestionType.singleSelect);
      expect(question.help, 'اختر واحدًا');
      expect(question.options.length, 2);
      expect(question.options.first.label, 'الرئيسي');
      // A missing label falls back to the value.
      expect(question.options.last.label, 'branch');
      expect(question.allowOther, isTrue);
      expect(question.minSelect, 1);
      expect(question.unit, 'كجم');
    });

    test('an unknown server type degrades to unknown (rendered as free text)', () {
      final question = AiQuestion.fromJson({
        'id': 'q1',
        'type': 'star_rating',
        'prompt': '?',
      });
      expect(question.type, AiQuestionType.unknown);
      expect(aiQuestionTypeWire(question.type), 'free_text');
      expect(question.isRequired, isTrue); // defaults to required
    });

    test('AiPendingQuestion.fromParts rejects missing id or empty questions', () {
      expect(
        AiPendingQuestion.fromParts(
          toolCallId: null,
          messageId: 1,
          questionsRaw: [
            {'id': 'q1', 'type': 'free_text', 'prompt': 'x'},
          ],
        ),
        isNull,
      );
      expect(
        AiPendingQuestion.fromParts(
          toolCallId: 'c1',
          messageId: 1,
          questionsRaw: const [],
        ),
        isNull,
      );
      final ok = AiPendingQuestion.fromParts(
        toolCallId: 'c1',
        messageId: 7,
        questionsRaw: [
          {'id': 'q1', 'type': 'confirm', 'prompt': 'متابعة؟'},
        ],
      );
      expect(ok, isNotNull);
      expect(ok!.questions.single.type, AiQuestionType.confirm);
    });

    test('AiAnswer.toJson carries the right shape per answer kind', () {
      final select = const AiAnswer(
        questionId: 'q1',
        type: AiQuestionType.singleSelect,
        value: 'other text',
        isOther: true,
      ).toJson();
      expect(select['question_id'], 'q1');
      expect(select['type'], 'single_select');
      expect(select['value'], 'other text');
      expect(select['is_other'], true);
      expect(select.containsKey('values'), isFalse);

      final multi = const AiAnswer(
        questionId: 'q2',
        type: AiQuestionType.multiSelect,
        values: ['a', 'b'],
        otherText: 'c',
        isOther: true,
      ).toJson();
      expect(multi['values'], ['a', 'b']);
      expect(multi['other_text'], 'c');
    });
  });

  group('tool-event rehydration', () {
    test('mutating events rehydrate as completed action chips; reads do not', () {
      final message = AiMessage.fromJson({
        'id': 7,
        'role': 'assistant',
        'content': 'تم تسجيل المصروف',
        'tool_events': [
          {
            'name': 'query_resource',
            'resource': 'expense-categories',
            'label': 'فئات المصروفات',
            'ok': true,
            'mutates': false,
          },
          {
            'name': 'create_resource',
            'resource': 'expenses',
            'label': 'إنشاء: المصروفات',
            'ok': true,
            'mutates': true,
          },
        ],
      });

      // Only the mutation survives as a durable chip; the read query is dropped.
      expect(message.toolRuns.length, 1);
      final run = message.toolRuns.single;
      expect(run.mutates, isTrue);
      expect(run.done, isTrue);
      expect(run.ok, isTrue);
      expect(run.label, 'إنشاء: المصروفات');
    });

    test('a message with no tool events has no chips', () {
      final message = AiMessage.fromJson({
        'id': 1,
        'role': 'assistant',
        'content': 'مرحبا',
      });
      expect(message.toolRuns, isEmpty);
    });
  });

  group('product_picker question', () {
    test('parses the type and config getters', () {
      final question = AiQuestion.fromJson({
        'id': 'line1',
        'type': 'product_picker',
        'prompt': 'اختر المنتج',
        'config': {
          'name': 'حليب المراعي',
          'barcode': '6291000111',
          'unit_cost': '2.50',
          'suggested_price': '3.25',
        },
      });
      expect(question.type, AiQuestionType.productPicker);
      expect(question.productName, 'حليب المراعي');
      expect(question.productBarcode, '6291000111');
      expect(question.productUnitCost, '2.50');
      expect(question.productSuggestedPrice, '3.25');
      expect(question.allowCreateNew, isTrue);
    });

    test('round-trips the wire name and coerces a numeric config value', () {
      expect(aiQuestionTypeWire(AiQuestionType.productPicker), 'product_picker');
      final question = AiQuestion.fromJson({
        'id': 'l',
        'type': 'product_picker',
        'prompt': 'x',
        'config': {'unit_cost': 2.5, 'allow_create_new': false},
      });
      expect(question.productUnitCost, '2.5');
      expect(question.allowCreateNew, isFalse);
    });
  });
}
