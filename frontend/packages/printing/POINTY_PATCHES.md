# Pointy's copy of `printing` 5.14.3

This is `printing` 5.14.3 from pub.dev with Windows print fixes. Only
`windows/print_job.cpp` differs from upstream; every change there is marked
`POINTY PATCH`. The pub.dev example, tests, screenshot and changelog were left
out.

## Why it is vendored

After the update to 0.6.7 (2026-09-24), a Windows till's HPRT label printer
stopped printing. Every job reached the Windows print queue and the app
reported each print as sent, but nothing came out. A printer that states its
own page (a receipt roll, a test receipt) goes through the plugin's custom
paper path, and 5.14.3 builds that path's settings (the DEVMODE) from
uninitialised memory:

- It zeroed only the public part of the DEVMODE and told the driver the
  `DC_EXTRA` private bytes that follow were valid. That is where a driver keeps
  its media type, gap sensing and print mode, so the driver read garbage.
- It gave the print dialog no owner window. On a full-screen till the dialog
  opens behind the app, shows only in the taskbar, and the print waits on it.
- It never answered Dart when `CreateDC` failed, or when PDFium could not read
  the document. The print call then never returned. In the second case the
  job was also left open in the Windows queue, where it blocks every job
  behind it.

Upstream fixed the first two in 5.15.1 ("Fix Windows memory initialization in
print_job.cpp", "Fix the Windows print dialog not being owned by the window
that started the job"). 5.15 needs Dart 3.12, and this app is on 3.10.

## What changed

1. The custom-paper DEVMODE starts from the driver's own settings
   (`DocumentProperties`, `DM_OUT_BUFFER`). Only the paper size and orientation
   change, and the result goes back to the driver to validate
   (`DM_IN_BUFFER | DM_OUT_BUFFER`). If the driver will not describe itself,
   the fallback is a DEVMODE zeroed whole, with no private section. This goes
   further than upstream's zeroing: the shop's driver setup (label media, gap
   sensing) survives.
2. The print dialog is owned by the active window.
3. A `CreateDC` failure, an unreadable document, or a `StartDoc` refusal
   completes the print with an error, and no job is left open.
4. The DEVMODE is released with `GlobalFree`. Upstream passed it to
   `ClosePrinter`, as if it were a printer handle.

## Dropping this copy

Once the app is on Dart >= 3.12, go back to `printing: ^5.15.1` (or newer) in
`frontend/pubspec.yaml` and delete this directory. Upstream 5.15.1 has item 2,
item 4, and the unreadable-document part of item 3. For item 1 it zeroes the
DEVMODE rather than starting from the driver's settings, and it still does not
answer a `CreateDC` failure. Before dropping this copy, check that an HPRT or
Xprinter receipt still prints on Windows.
