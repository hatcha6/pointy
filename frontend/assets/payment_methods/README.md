# Wallet top-up method marks

The marks of the ways a shop pays into its Daftar wallet, as Dafa (the payment
gateway) shows them on its own dashboard
(`https://dashboard.dafa.ly/images/gateways/<provider>.png`).

## Naming

One file per method, named for **Dafa's provider id** — the `provider` the relay
lists with each top-up method:

    sadad.png  edfali.png  mobicash.png  yussor-pay.png  masrafi-pay.png  sahara-pay.png

Local bank cards (`moamalat`) has no file on purpose: it is no one brand, so the
sheet draws a card icon for it.

## Sizing

Transparent margin trimmed, longest edge 128px, like `assets/banks/`. They are
not all square — Yussor Pay's is 5:2 — so they render `BoxFit.contain` on a
white chip (they are drawn for a light background) in both themes.

A missing file is not an error: the widget falls back to a themed icon. Add the
file here **and** keep `assets/payment_methods/` under `assets:` in
`pubspec.yaml` — Flutter only bundles what is declared.
