import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/navigation/ai_deep_link.dart';

void main() {
  group('AiDeepLink.tryParse', () {
    test('parses an entity link', () {
      expect(
        AiDeepLink.tryParse('pointy://product/42'),
        const AiEntityLink('product', 42),
      );
      expect(
        AiDeepLink.tryParse('pointy://order/99'),
        const AiEntityLink('order', 99),
      );
      expect(
        AiDeepLink.tryParse('pointy://purchase-order/7'),
        const AiEntityLink('purchase-order', 7),
      );
    });

    test('parses a screen link', () {
      expect(
        AiDeepLink.tryParse('pointy://screen/invoices'),
        const AiScreenLink('invoices'),
      );
    });

    test('tolerates the app/ host form', () {
      expect(
        AiDeepLink.tryParse('pointy://app/product/42'),
        const AiEntityLink('product', 42),
      );
      expect(
        AiDeepLink.tryParse('pointy://app/screen/catalog'),
        const AiScreenLink('catalog'),
      );
    });

    test('normalises the type/key to lowercase', () {
      expect(
        AiDeepLink.tryParse('pointy://Product/42'),
        const AiEntityLink('product', 42),
      );
      expect(
        AiDeepLink.tryParse('pointy://screen/Invoices'),
        const AiScreenLink('invoices'),
      );
    });

    test('parses a bare chat link with no seed', () {
      expect(AiDeepLink.tryParse('pointy://chat'), const AiChatLink());
      expect(AiDeepLink.tryParse('pointy://chat/ask'), const AiChatLink());
    });

    test('parses a chat link seeded with a prompt', () {
      expect(
        AiDeepLink.tryParse(
          'pointy://chat/ask?prompt=Why%20did%20sales%20drop%3F',
        ),
        const AiChatLink(prompt: 'Why did sales drop?'),
      );
    });

    test('auto-sends the seed when send=1 or send=true', () {
      expect(
        AiDeepLink.tryParse('pointy://chat/ask?prompt=Reorder%20advice&send=1'),
        const AiChatLink(prompt: 'Reorder advice', autoSend: true),
      );
      expect(
        AiDeepLink.tryParse(
          'pointy://chat/ask?prompt=Reorder%20advice&send=true',
        ),
        const AiChatLink(prompt: 'Reorder advice', autoSend: true),
      );
    });

    test('drops a blank prompt and ignores a non-truthy send flag', () {
      expect(
        AiDeepLink.tryParse('pointy://chat/ask?prompt='),
        const AiChatLink(),
      );
      expect(
        AiDeepLink.tryParse('pointy://chat/ask?prompt=Hi&send=0'),
        const AiChatLink(prompt: 'Hi'),
      );
    });

    test('tolerates the app/ host form for chat links', () {
      expect(
        AiDeepLink.tryParse('pointy://app/chat/ask?prompt=Hi'),
        const AiChatLink(prompt: 'Hi'),
      );
    });

    test('rejects non-pointy links and leaves web URLs alone', () {
      expect(AiDeepLink.tryParse('https://example.com/x'), isNull);
      expect(AiDeepLink.tryParse('mailto:a@b.com'), isNull);
      expect(AiDeepLink.tryParse('just some text'), isNull);
    });

    test('rejects malformed deep links', () {
      expect(
        AiDeepLink.tryParse('pointy://product/abc'),
        isNull,
      ); // non-numeric id
      expect(
        AiDeepLink.tryParse('pointy://product/0'),
        isNull,
      ); // id must be > 0
      expect(AiDeepLink.tryParse('pointy://product/-3'), isNull);
      expect(AiDeepLink.tryParse('pointy://product'), isNull); // no id
      expect(AiDeepLink.tryParse('pointy://screen'), isNull); // no key
    });
  });
}
