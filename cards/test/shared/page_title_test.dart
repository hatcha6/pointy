import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/shared/page_title.dart';

Route<void> _route(String? name) => MaterialPageRoute<void>(
  settings: RouteSettings(name: name),
  builder: (_) => const SizedBox(),
);

void main() {
  const served = 'شحن ببجي موبايل في ليبيا | دفتر كروت';
  const app = 'دفتر كروت';

  testWidgets('the page the browser opened on keeps its served title', (
    tester,
  ) async {
    final titles = PageTitles(served: served, path: '/brand/pubg');
    var changes = 0;
    titles.addListener(() => changes++);
    final shell = _route('/');
    final brand = _route('/brand/pubg');

    // The app starts on its shell, then the link's page opens over it.
    titles.didPush(shell, null);
    expect(titles.title(app), served);
    titles.didPush(brand, shell);
    expect(titles.title(app), served);

    // A sheet over the page changes nothing.
    final sheet = _route(null);
    titles.didPush(sheet, brand);
    titles.didPop(sheet, brand);
    expect(titles.title(app), served);
    await tester.pump();
    expect(changes, 0);

    // Back on the shelf, the tab says the app's name; the app is told once.
    titles.didPop(brand, shell);
    expect(titles.title(app), app);
    await tester.pump();
    expect(changes, 1);

    // Another brand is not the served page; the first one again is.
    titles.didPush(_route('/brand/libyana'), shell);
    expect(titles.title(app), app);
    titles.didPush(_route('/brand/pubg?item=pubg-60'), shell);
    expect(titles.title(app), served);
  });

  test('a category the shelf opened on keeps its title on the shell', () {
    final titles = PageTitles(served: served, path: '/category/gaming');
    titles.didPush(_route('/'), null);
    expect(titles.title(app), served);
  });

  test('off the web the title is the app name', () {
    final titles = PageTitles(served: '', path: '/');
    titles.didPush(_route('/'), null);
    expect(titles.title(app), app);
  });
}
