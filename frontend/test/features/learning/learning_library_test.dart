import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/learning/content/learning_library.dart';
import 'package:pointy_frontend/src/features/learning/models/learning_guide.dart';

/// The library is content, and content rots quietly: a cross-link to a guide
/// someone renamed, a section left empty mid-edit, a duplicate id that silently
/// shadows an older guide. These are the checks that turn all of that into a
/// red build instead of a confused cashier.
void main() {
  test('every guide id is unique', () {
    final seen = <String>{};
    final duplicates = <String>[];
    for (final guide in learningLibrary) {
      if (!seen.add(guide.id)) {
        duplicates.add(guide.id);
      }
    }
    expect(duplicates, isEmpty);
  });

  test('every cross-link resolves to a guide that exists', () {
    final dangling = <String>[];
    for (final guide in learningLibrary) {
      for (final id in guide.related) {
        if (!learningGuidesById.containsKey(id)) {
          dangling.add('${guide.id} -> $id');
        }
      }
    }
    expect(dangling, isEmpty);
  });

  test('no guide links to itself', () {
    for (final guide in learningLibrary) {
      expect(guide.related, isNot(contains(guide.id)), reason: guide.id);
    }
  });

  test('every guide carries readable content', () {
    for (final guide in learningLibrary) {
      expect(guide.title.trim(), isNotEmpty, reason: guide.id);
      expect(guide.summary.trim(), isNotEmpty, reason: guide.id);
      expect(guide.minutes, greaterThan(0), reason: guide.id);
      expect(guide.sections, isNotEmpty, reason: guide.id);
      for (final section in guide.sections) {
        expect(section.title.trim(), isNotEmpty, reason: guide.id);
        expect(
          section.blocks,
          isNotEmpty,
          reason: '${guide.id}/${section.title}',
        );
        for (final block in section.blocks) {
          _expectBlockHasContent(block, '${guide.id}/${section.title}');
        }
      }
    }
  });

  test('every track has at least one guide', () {
    for (final track in LearningTrack.values) {
      expect(
        learningLibrary.where((guide) => guide.track == track),
        isNotEmpty,
        reason: track.name,
      );
    }
  });

  test('the library covers the workflows a shop cannot run without', () {
    // Named explicitly rather than counted: these are the operations that move
    // money or stock, and a refactor that drops one should not pass because the
    // total still looks healthy.
    const required = [
      'selling.first_sale',
      'money.split_tender',
      'money.credit_sale',
      'money.credit_down_payment',
      'money.collect_debt',
      'returns.return_items',
      'returns.exchange',
      'register.open',
      'register.close',
      'register.zreport',
      'catalog.variants_concept',
      'catalog.variants_create',
      'inventory.stock_count',
      'purchasing.create_po',
      'purchasing.receive',
      'purchasing.pay_supplier',
      'setup.remote_access',
    ];
    for (final id in required) {
      expect(learningGuidesById, contains(id));
    }
  });

  test('search indexes and ordering cover the whole library', () {
    expect(learningSearchIndexes.length, learningLibrary.length);
    expect(learningGuideOrder.length, learningLibrary.length);
  });
}

void _expectBlockHasContent(LearningBlock block, String where) {
  switch (block) {
    case LearningParagraph(:final text):
      expect(text.trim(), isNotEmpty, reason: where);
    case LearningSteps(:final steps):
      expect(steps, isNotEmpty, reason: where);
      for (final step in steps) {
        expect(step.text.trim(), isNotEmpty, reason: where);
        expect(step.detail?.trim() ?? 'x', isNotEmpty, reason: where);
      }
    case LearningBullets(:final items):
      expect(items, isNotEmpty, reason: where);
      for (final item in items) {
        expect(item.trim(), isNotEmpty, reason: where);
      }
    case LearningDefinitions(:final entries):
      expect(entries, isNotEmpty, reason: where);
      for (final entry in entries) {
        expect(entry.term.trim(), isNotEmpty, reason: where);
        expect(entry.meaning.trim(), isNotEmpty, reason: where);
      }
    case LearningNote(:final title, :final message):
      expect(title.trim(), isNotEmpty, reason: where);
      expect(message?.trim() ?? 'x', isNotEmpty, reason: where);
  }
}
