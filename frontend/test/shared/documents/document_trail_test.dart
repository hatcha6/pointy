import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/document_trail_event.dart';
import 'package:pointy_frontend/src/data/repositories/document_trail_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/documents/document_lifecycle.dart';
import 'package:pointy_frontend/src/shared/documents/document_trail_sheet.dart';

void main() {
  group('the trail reads back what happened', () {
    testWidgets('a retraction shows its reason in the person\'s own words', (
      tester,
    ) async {
      await _pumpSheet(tester, events: [_cancelled()]);
      await tester.pumpAndSettle();

      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      expect(find.text(l10n.documentTrailActionCancelled), findsOneWidget);
      expect(find.text('سُجّل مرتين'), findsOneWidget);
      expect(find.text(l10n.documentTrailReasonLabel), findsOneWidget);
    });

    testWidgets('a correction says which figure moved, and where to', (
      tester,
    ) async {
      await _pumpSheet(tester, events: [_corrected()]);
      await tester.pumpAndSettle();

      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      expect(find.text(l10n.documentTrailFieldTotal), findsOneWidget);
      expect(
        find.text(l10n.documentTrailChangeValue('96.00', '144.00')),
        findsOneWidget,
      );
    });

    testWidgets('an empty value is named rather than left blank', (
      tester,
    ) async {
      await _pumpSheet(tester, events: [_filledIn()]);
      await tester.pumpAndSettle();

      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      expect(
        find.text(
          l10n.documentTrailChangeValue(
            l10n.documentTrailEmptyValue,
            'INV-7741',
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a field the app has no word for still shows its name', (
      tester,
    ) async {
      await _pumpSheet(tester, events: [_unknownField()]);
      await tester.pumpAndSettle();

      expect(find.text('rate_source'), findsOneWidget);
    });

    testWidgets('an empty history says so instead of showing nothing', (
      tester,
    ) async {
      await _pumpSheet(tester, events: const []);
      await tester.pumpAndSettle();

      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      expect(find.text(l10n.documentTrailEmptyTitle), findsOneWidget);
    });

    testWidgets('a failure offers a retry rather than an empty list', (
      tester,
    ) async {
      await _pumpSheet(tester, events: null);
      await tester.pumpAndSettle();

      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      expect(find.text(l10n.documentTrailLoadError), findsOneWidget);
      expect(find.text(l10n.retryButton), findsOneWidget);
    });
  });

  group('what a retracted document says about itself', () {
    test('who and when and why, in one sentence', () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      final sentence = const DocumentRetraction(
        docStatus: 'cancelled',
        cancelledByUsername: 'أحمد',
        cancelReason: 'سُجّل مرتين',
      ).sentence(l10n);

      expect(sentence, isNotNull);
      expect(sentence, contains('أحمد'));
      expect(sentence, contains('سُجّل مرتين'));
    });

    test('a live document says nothing at all', () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      const live = DocumentRetraction(docStatus: 'submitted');

      expect(live.isRetracted, isFalse);
      expect(live.sentence(l10n), isNull);
      expect(live.messageWith(l10n, 'الأصل'), 'الأصل');
    });

    test('an unattributed retraction still says when', () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      final sentence = DocumentRetraction(
        docStatus: 'cancelled',
        cancelledAt: DateTime(2026, 9, 5, 16, 4),
      ).sentence(l10n);

      expect(sentence, isNotNull);
      expect(sentence, contains('2026'));
    });

    test('and one with nothing recorded adds no empty line', () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      const bare = DocumentRetraction(docStatus: 'cancelled');

      expect(bare.sentence(l10n), isNull);
      expect(bare.messageWith(l10n, 'الأصل'), 'الأصل');
    });
  });
}

Future<void> _pumpSheet(
  WidgetTester tester, {
  required List<DocumentTrailEvent>? events,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Material(
          child: SizedBox(
            width: 390,
            height: 700,
            child: DocumentTrailSheet(
              repository: _FakeTrailRepository(events),
              documentType: 'purchase_order',
              documentId: 1,
              documentNumber: 'P20260905000042',
            ),
          ),
        ),
      ),
    ),
  );
}

class _FakeTrailRepository extends DocumentTrailRepository {
  _FakeTrailRepository(this._events) : super(PosApiService());

  /// Null stands for a failed load, which is its own state on screen.
  final List<DocumentTrailEvent>? _events;

  @override
  Future<Result<List<DocumentTrailEvent>>> loadTrail({
    required String documentType,
    required int documentId,
  }) async {
    final events = _events;
    return events == null
        ? Error(Exception('offline'))
        : Ok(events);
  }
}

DocumentTrailEvent _cancelled() {
  return DocumentTrailEvent(
    id: 3,
    documentType: 'purchase_order',
    objectId: 1,
    documentNumber: 'P20260905000042',
    action: DocumentTrailAction.cancelled,
    reason: 'سُجّل مرتين',
    changes: const [],
    actorUsername: 'أحمد',
    createdAt: DateTime(2026, 9, 5, 14, 32),
  );
}

DocumentTrailEvent _corrected() {
  return DocumentTrailEvent(
    id: 2,
    documentType: 'purchase_order',
    objectId: 1,
    documentNumber: 'P20260905000042',
    action: DocumentTrailAction.corrected,
    reason: '',
    changes: const [
      DocumentFieldChange(field: 'total', from: '96.00', to: '144.00'),
    ],
    actorUsername: 'سالم',
    createdAt: DateTime(2026, 9, 5, 11, 8),
  );
}

DocumentTrailEvent _filledIn() {
  return DocumentTrailEvent(
    id: 4,
    documentType: 'purchase_order',
    objectId: 1,
    documentNumber: 'P20260905000042',
    action: DocumentTrailAction.corrected,
    reason: '',
    changes: const [
      DocumentFieldChange(
        field: 'supplier_invoice_number',
        from: '',
        to: 'INV-7741',
      ),
    ],
    actorUsername: 'سالم',
    createdAt: DateTime(2026, 9, 5, 11, 9),
  );
}

DocumentTrailEvent _unknownField() {
  return DocumentTrailEvent(
    id: 5,
    documentType: 'purchase_order',
    objectId: 1,
    documentNumber: 'P20260905000042',
    action: DocumentTrailAction.corrected,
    reason: '',
    changes: const [
      DocumentFieldChange(field: 'rate_source', from: 'manual', to: 'relay'),
    ],
    actorUsername: 'سالم',
    createdAt: DateTime(2026, 9, 5, 11, 10),
  );
}
