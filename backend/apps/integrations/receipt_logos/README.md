# Provider logos, as receipts print them

One file per provider, named for its **backend key** (`hdbox.png`, `lnet.png`,
`qareeb.png`, `pointy.png`). The slip a top-up prints opens on its provider's logo, and so does
a card whose brand has no receipt logo of its own
(`voucher_logos.receipt_logo_for`).

These are thermal versions of the colour marks the till shows
(`frontend/assets/integrations/`): pure black ink on white, trimmed to the ink,
at most 320 px on the longer side, one to two KB each. A thermal head prints two
levels, so the files carry two — nothing is left for a threshold to guess.

- **HD Box** — the black "HD BOX" and the red frame both became ink.
- **LNET** — the red wordmark became ink.
- **Qareeb** — the app icon is a white wordmark knocked out of an orange tile. A
  head would print the tile as a solid black slab, so the wordmark itself is the
  ink and the tile is gone.
- **كروت دفتر** (`pointy`) — the Daftar mark (`frontend/assets/branding/
  logo_black.png`) is white pages and a pencil on a black tile. Same reasoning
  as Qareeb's: the pages are the ink, the pencil stays the paper cut out of
  them, and the tile is gone.

A new provider adds its file here; `test_voucher_logos` fails for a provider in
`catalog.PROVIDERS` without one.
