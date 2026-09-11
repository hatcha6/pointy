# Bank marks

Logos for the issuing banks in `lib/src/shared/payments/libyan_banks.dart`.

## Naming

One file per bank, named for its **Central Bank slug**, as PNG:

    assets/banks/<slug>.png

The slug is the `slug` field of the matching `LibyanBank` entry — `jbank.png`,
`sb.png`, `ejmaa.png`. Do **not** reuse the filenames from the Central Bank's
own site: they do not identify the bank they sit next to.

    nub-logo.png   belongs to National Union Bank  -> save it as  ejmaa.png
    nuran-bank.jpeg  is Nuran Bank                 -> save it as  nub.png
    bnp-bank.png     is Sahara Bank                -> save it as  sb.png

Getting that wrong puts one bank's mark on another bank's card.

All 25 are present. `libyan_banks_test.dart` fails if a declared mark is
missing, or if a file sits here that no bank claims — the second being the
signature of a file saved under the source's own name.

## Missing files are still tolerated at runtime

`BankLogo` falls back to the bank's Arabic name when an asset will not load, so
a build that drops one still renders correctly. That is a safety net, not a
licence to leave gaps; the test above is what keeps the set complete.

## Sizing

Transparent background, longest edge 128px. They are **not** all square — Waha's
is nearly 2:1 and Aman's is a wide oval — so they render `BoxFit.contain` inside
a square box with a gentle rounded-rect clip. Do not clip these to a circle: it
cuts both ends off exactly the marks whose name you could otherwise read.
