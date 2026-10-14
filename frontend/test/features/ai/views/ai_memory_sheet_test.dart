import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/ai_memory.dart';
import 'package:pointy_frontend/src/data/repositories/ai_chat_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/ai/view_models/ai_memory_view_model.dart';
import 'package:pointy_frontend/src/features/ai/views/ai_memory_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

class _MemoryRepo extends AiChatRepository {
  _MemoryRepo() : super(PosApiService());

  final List<AiMemory> memories = [
    const AiMemory(id: 1, content: 'المحل مغلق يوم الجمعة', isShop: true),
    const AiMemory(
      id: 2,
      content: 'أفضّل الإجابات المختصرة',
      isShop: false,
      editable: true,
    ),
  ];
  final List<int> deleted = [];

  @override
  Future<Result<List<AiMemory>>> loadMemories() async => Ok(memories);

  @override
  Future<Result<AiMemory>> updateMemory(int id, String content) async =>
      Ok(memories.firstWhere((m) => m.id == id).copyWith(content: content));

  @override
  Future<Result<bool>> deleteMemory(int id) async {
    deleted.add(id);
    return const Ok(true);
  }
}

Future<void> _pump(WidgetTester tester, AiMemoryViewModel viewModel) async {
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
      home: Scaffold(body: AiMemorySheet(viewModel: viewModel)),
    ),
  );
  await viewModel.load();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shop and personal memories show; only editable ones edit', (
    tester,
  ) async {
    final viewModel = AiMemoryViewModel(_MemoryRepo());
    addTearDown(viewModel.dispose);
    await _pump(tester, viewModel);

    expect(find.text('عن المتجر'), findsOneWidget);
    expect(find.text('خاصة بك'), findsOneWidget);
    expect(find.text('المحل مغلق يوم الجمعة'), findsOneWidget);
    // A shop memory this user may not edit shows a lock, not buttons.
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('ai_memory_edit_field')),
      'أفضّل الأرقام في جدول',
    );
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    expect(find.text('أفضّل الأرقام في جدول'), findsOneWidget);
  });

  testWidgets('deleting asks first, then removes the memory', (tester) async {
    final repo = _MemoryRepo();
    final viewModel = AiMemoryViewModel(repo);
    addTearDown(viewModel.dispose);
    await _pump(tester, viewModel);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('حذف هذه الذاكرة؟'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'حذف'));
    await tester.pumpAndSettle();

    expect(repo.deleted, [2]);
    expect(find.text('أفضّل الإجابات المختصرة'), findsNothing);
    expect(find.text('خاصة بك'), findsNothing);
  });
}
