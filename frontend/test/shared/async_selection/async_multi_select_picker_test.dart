import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/shared/async_selection/async_multi_select_picker.dart';
import 'package:pointy_frontend/src/shared/components/pointy_error_state.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() {
  testWidgets('search field keeps focus while results load', (tester) async {
    // Regression: the search field was disabled while a page loaded, and a disabled
    // TextField drops focus — so every keystroke that triggered a reload kicked the
    // user out of the field. It must stay focused across the in-flight load.
    const searchKey = ValueKey('picker_search');

    Future<AsyncSelectionPage<int>> loadPage(String search, int page) async {
      // A long-ish delay so the in-flight (loading) frame is clearly observable
      // between the debounce firing and the results arriving.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return const AsyncSelectionPage<int>(
        options: [
          AsyncSelectionOption<int>(id: 1, label: 'حليب', subtitle: ''),
        ],
        hasMore: false,
      );
    }

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
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showAsyncMultiSelectPicker<int>(
                  context: context,
                  searchFieldKey: searchKey,
                  selected: const [],
                  loadPage: loadPage,
                  strings: AsyncSelectionPickerStrings<int>(
                    title: 'العنوان',
                    searchHint: 'ابحث',
                    emptyText: 'لا شيء',
                    clearText: 'مسح',
                    clearSearchTooltip: 'مسح البحث',
                    loadErrorText: 'خطأ',
                    confirmText: 'تأكيد',
                    fallbackLabelForId: (id) => '#$id',
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle(); // sheet opens + initial load settles

    // The reliable, bug-tied signal: the field must NOT be disabled while a page is
    // loading (a disabled TextField is what drops focus on-device).
    bool? searchEnabled() =>
        tester.widget<TextField>(find.byKey(searchKey)).enabled;

    expect(searchEnabled(), isTrue);
    // Type — focuses the field, and after the debounce kicks off a reload.
    await tester.enterText(find.byKey(searchKey), 'حل');
    await tester.pump(
      const Duration(milliseconds: 360),
    ); // debounce fired → load in flight
    expect(
      searchEnabled(),
      isTrue,
      reason: 'field disabled mid-load → focus drops',
    );
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    // Advance past the in-flight load (explicit, so its delayed timer fires and
    // isn't left pending at teardown).
    await tester.pump(const Duration(milliseconds: 350)); // results arrive
    expect(searchEnabled(), isTrue);
  });

  testWidgets('a failed first page offers a retry instead of "no results"', (
    tester,
  ) async {
    // Regression: a failed load emptied the list and left a red line above an
    // "empty" list — so the picker said "no results" for a search it never got
    // to run, and the only way to ask again was to edit the search text.
    var shouldFail = true;

    Future<AsyncSelectionPage<int>> loadPage(String search, int page) async {
      if (shouldFail) {
        throw Exception('offline');
      }
      return const AsyncSelectionPage<int>(
        options: [
          AsyncSelectionOption<int>(id: 1, label: 'حليب', subtitle: ''),
        ],
        hasMore: false,
      );
    }

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
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showAsyncMultiSelectPicker<int>(
                  context: context,
                  selected: const [],
                  loadPage: loadPage,
                  strings: AsyncSelectionPickerStrings<int>(
                    title: 'العنوان',
                    searchHint: 'ابحث',
                    emptyText: 'لا توجد نتائج',
                    clearText: 'مسح',
                    clearSearchTooltip: 'مسح البحث',
                    loadErrorText: 'تعذّر تحميل القائمة',
                    confirmText: 'تأكيد',
                    fallbackLabelForId: (id) => '#$id',
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    // The failure is reported as a failure — not as an empty result set.
    expect(find.byType(PointyErrorState), findsOneWidget);
    expect(find.text('تعذّر تحميل القائمة'), findsOneWidget);
    expect(find.text('لا توجد نتائج'), findsNothing);

    // And it is escapable without touching the search field. Match the label,
    // not the button type: the action is a `FilledButton.icon`, whose private
    // subclass `find.widgetWithText(FilledButton, …)` never matches.
    final retry = find.text(l10n.retryButton);
    expect(retry, findsOneWidget);

    shouldFail = false;
    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(find.byType(PointyErrorState), findsNothing);
    expect(find.text('حليب'), findsOneWidget);
  });
}
