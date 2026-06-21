import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/shared/async_selection/async_multi_select_picker.dart';
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
        options: [AsyncSelectionOption<int>(id: 1, label: 'حليب', subtitle: '')],
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
    bool? searchEnabled() => tester.widget<TextField>(find.byKey(searchKey)).enabled;

    expect(searchEnabled(), isTrue);
    // Type — focuses the field, and after the debounce kicks off a reload.
    await tester.enterText(find.byKey(searchKey), 'حل');
    await tester.pump(const Duration(milliseconds: 360)); // debounce fired → load in flight
    expect(searchEnabled(), isTrue, reason: 'field disabled mid-load → focus drops');
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    // Advance past the in-flight load (explicit, so its delayed timer fires and
    // isn't left pending at teardown).
    await tester.pump(const Duration(milliseconds: 350)); // results arrive
    expect(searchEnabled(), isTrue);
  });
}
