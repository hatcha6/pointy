import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/features/learning/models/learning_guide.dart';
import 'package:pointy_frontend/src/features/learning/views/learning_block_view.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// Guide bodies are read as a column of text, so every line in a block has to
/// start on the same edge. A plain `Column` centres its children at their
/// intrinsic width, which left a short definition inset from both sides while a
/// long one filled — so no two terms down the list began at the same place.
void main() {
  testWidgets('definition rows all start on the same edge', (tester) async {
    await _pumpBlock(
      tester,
      const LearningDefinitions([
        LearningDefinition(
          'خصم تلقائي',
          'قاعدة يضبطها المدير وتنطبق وحدها متى '
              'تحققت شروطها، فلا يفعل الكاشير شيئًا على الإطلاق.',
        ),
        LearningDefinition('كود خصم', 'لا ينطبق حتى يُدخَل.'),
      ]),
    );

    final first = tester.getRect(find.text('خصم تلقائي'));
    final second = tester.getRect(find.text('كود خصم'));

    // RTL: text starts at the right edge, so both terms share a right edge.
    expect(second.right, moreOrLessEquals(first.right, epsilon: 0.5));
    expect(second.left, lessThan(second.right));
  });

  testWidgets('steps and bullets start on the same edge as each other', (
    tester,
  ) async {
    await _pumpBlock(
      tester,
      const LearningSteps([
        LearningStep(
          'خطوة أولى طويلة بما يكفي لتملأ السطر كاملًا في هذا الاختبار.',
        ),
        LearningStep('خطوة ثانية قصيرة.'),
      ]),
    );

    final first = tester.getRect(
      find.text('خطوة أولى طويلة بما يكفي لتملأ السطر كاملًا في هذا الاختبار.'),
    );
    final second = tester.getRect(find.text('خطوة ثانية قصيرة.'));
    expect(second.right, moreOrLessEquals(first.right, epsilon: 0.5));
  });

  testWidgets('bullet items share a start edge', (tester) async {
    await _pumpBlock(
      tester,
      const LearningBullets([
        'عنصر أول طويل بما يكفي ليملأ عرض السطر كله في هذا الاختبار تمامًا.',
        'عنصر ثانٍ قصير.',
      ]),
    );

    final first = tester.getRect(
      find.text(
        'عنصر أول طويل بما يكفي ليملأ عرض السطر كله في هذا الاختبار تمامًا.',
      ),
    );
    final second = tester.getRect(find.text('عنصر ثانٍ قصير.'));
    expect(second.right, moreOrLessEquals(first.right, epsilon: 0.5));
  });
}

Future<void> _pumpBlock(WidgetTester tester, LearningBlock block) async {
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
        body: Center(
          child: SizedBox(
            width: 420,
            // Stretch, like the section the reader puts blocks in.
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [LearningBlockView(block: block)],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
