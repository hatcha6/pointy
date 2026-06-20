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
}
