import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/ai/views/ai_streaming_markdown.dart';

const _ms = Duration(milliseconds: 1);

/// Strip the fade markers, leaving the text a reader would see.
String _visible(String markup) => markup.replaceAll(RegExp('\uE000\\d\\d\uE001|\uE002'), '');

bool _isMarked(String markup, String word) =>
    RegExp('\uE000\\d\\d\uE001${RegExp.escape(word)}\uE002').hasMatch(markup);

void main() {
  group('WordRevealTimeline', () {
    test('words cascade: later words start a stagger after earlier ones', () {
      final timeline = WordRevealTimeline()
        ..observe('one two three', Duration.zero, animate: true);
      // At t=0 only the first word has started; the rest are not shown yet.
      expect(_visible(timeline.markup('one two three', Duration.zero)), 'one');
      final later = AiStreamingReveal.wordStagger * 2;
      expect(
        _visible(timeline.markup('one two three', later)),
        'one two three',
      );
    });

    test('a big burst never lags more than maxLag behind the network', () {
      final words = List.generate(200, (i) => 'w$i').join(' ');
      final timeline = WordRevealTimeline()
        ..observe(words, Duration.zero, animate: true);
      final atCeiling = AiStreamingReveal.maxLag + _ms;
      expect(_visible(timeline.markup(words, atCeiling)), words);
      expect(
        timeline.isSettled(atCeiling + AiStreamingReveal.fadeDuration),
        isTrue,
      );
    });

    test('a word mid-fade is wrapped; a settled word is plain', () {
      final timeline = WordRevealTimeline()
        ..observe('hello', Duration.zero, animate: true);
      final mid = AiStreamingReveal.fadeDuration ~/ 2;
      expect(_isMarked(timeline.markup('hello', mid), 'hello'), isTrue);
      final done = AiStreamingReveal.fadeDuration + _ms;
      expect(timeline.markup('hello', done), 'hello');
      expect(timeline.isSettled(done), isTrue);
    });

    test('history replies are registered settled and never animate', () {
      final timeline = WordRevealTimeline()
        ..observe('old reply text', Duration.zero, animate: false);
      expect(timeline.isSettled(Duration.zero), isTrue);
      expect(
        timeline.markup('old reply text', Duration.zero),
        'old reply text',
      );
    });

    test('markdown syntax is never wrapped', () {
      const text =
          '1. **bold** and `code here` see [the link](pointy://product/1)\n'
          '| a | b |\n'
          '```\ninside fence\n```';
      final timeline = WordRevealTimeline()
        ..observe(text, Duration.zero, animate: true);
      // Every word has started and none has finished: all are mid-fade, so
      // only the safety rules decide what gets wrapped.
      final wordCount = RegExp(r'\S+').allMatches(text).length;
      final mid = AiStreamingReveal.wordStagger * (wordCount - 1) + _ms * 10;
      expect(mid < AiStreamingReveal.fadeDuration, isTrue);
      final markup = timeline.markup(text, mid);
      expect(_visible(markup), text);
      for (final word in [
        '1.',
        '**bold**',
        '`code',
        'here`',
        '[the',
        'link](pointy://product/1)',
        'a',
        'inside',
        'fence',
      ]) {
        expect(_isMarked(markup, word), isFalse, reason: word);
      }
      // A plain word in the same paragraph still fades.
      expect(_isMarked(markup, 'and'), isTrue);
    });
  });

  testWidgets('a streamed reply settles into the full plain text', (
    tester,
  ) async {
    Widget build(String text, {required bool streaming}) => MaterialApp(
      home: Scaffold(
        body: AiStreamingMarkdown(
          text: text,
          streaming: streaming,
          style: const TextStyle(fontSize: 14),
          onLinkTap: (_, _) {},
        ),
      ),
    );

    await tester.pumpWidget(build('مرحبا', streaming: true));
    await tester.pumpWidget(build('مرحبا بك في المتجر', streaming: true));
    await tester.pumpWidget(build('مرحبا بك في المتجر', streaming: false));
    await tester.pumpAndSettle();

    expect(find.textContaining('مرحبا بك في المتجر'), findsOneWidget);
    expect(find.textContaining('\uE000'), findsNothing);
  });
}
