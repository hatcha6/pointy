// Dev-only sweep script: the app shell — login, navigation rail/drawer,
// command palette, notification center, theme switch. These sit under every
// screen, so a cost here is paid everywhere.
import 'package:flutter/material.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/notifications/views/notification_bell.dart';

import 'common.dart';

const _perfUser = 'perf';
const _perfPassword = 'perfperf';

List<SweepSurface> shellSurfaces() => [
  // Runs first: the login screen is only there before sign-in. Typing into
  // the two fields and submitting is measured; the surface is skipped (with
  // a note) when the app is already signed in.
  SweepSurface('login', (d) async {
    d.surface = 'login';
    if (!d.any(find.text('دخول'))) {
      d.status.notes.add('already signed in; login screen not shown');
      return;
    }
    await d.measureSurface(
      'login',
      scroll: false,
      idleFrames: 20,
      reach: () async {},
      extras: () async {
        await d.typeSearch(
          find.widgetWithText(TextFormField, 'اسم المستخدم'),
          _perfUser,
        );
        await d.enterText(
          find.widgetWithText(TextFormField, 'كلمة المرور'),
          _perfPassword,
        );
        await d.measurePhase('submit', () async {
          await d.tap(find.text('دخول'));
          await d.settle(timeout: const Duration(seconds: 30));
        });
      },
    );
  }),
  // The rail's expand/collapse and the drawer on narrow widths.
  screen(
    'dashboard',
    scroll: false,
    extras: (d) async {
      final collapse = find.byTooltip('طي التنقل');
      final expand = find.byTooltip('توسيع التنقل');
      if (d.any(collapse) || d.any(expand)) {
        d.surface = 'navigation_rail';
        await d.measurePhase('collapse', () async {
          await d.tap(d.any(collapse) ? collapse : expand);
        });
        d.beginPhase('idle');
        await d.frames(20);
        await d.measurePhase('expand', () async {
          await d.tap(d.any(expand) ? expand : collapse);
        });
      }
      final menu = find.byTooltip('فتح القائمة');
      if (d.any(menu)) {
        d.surface = 'navigation_drawer';
        await d.openAndClose('drawer', open: () => d.tap(menu), scroll: true);
      }
      // Command palette: opened from the rail/drawer tile, then a search.
      d.surface = 'command_palette';
      await d.openAndClose(
        'palette',
        open: () => d.tapText('بحث وتنقّل سريع'),
        inside: () async {
          await d.typeSearch(
            find.descendant(
              of: find.byType(Dialog),
              matching: find.byType(TextField),
            ),
            'فواتير',
          );
        },
      );
      // Notification center (smart alerts panel) from the app bar bell.
      d.surface = 'notification_center';
      await d.openAndClose(
        'alerts',
        open: () => d.tap(find.byType(NotificationBell), what: 'alerts bell'),
        scroll: true,
      );
      // Theme switch: the whole app re-themes. The rail tile toggles
      // light/dark; measured there and back.
      d.surface = 'theme_switch';
      if (d.any(find.text('المظهر'))) {
        await d.measurePhase('toggle', () async {
          await d.tapText('المظهر');
        });
        d.beginPhase('idle');
        await d.frames(20);
        await d.measurePhase('toggle_back', () async {
          await d.tapText('المظهر');
        });
      } else {
        d.status.notes.add('theme tile not visible (rail collapsed?)');
      }
    },
  ),
];
