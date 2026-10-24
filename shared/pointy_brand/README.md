# pointy_brand

The Daftar (دفتر) brand shared by the company's Flutter apps:

- `PointyColors` / `PointyColorsDark` — the palette.
- `PointyTypography` — the Arabic type ramp on the packaged IBM Plex Sans Arabic.
- `PaymentMethodMarks` — the Dafa method marks, keyed by provider id.
- `PointyLogos` — the Daftar master mark.

Brand primitives only. Each app builds its own theme on them: dense for the
till, roomier for the card app.

The card app (`cards/`) uses it. The till (`frontend/`) still keeps its own
copy of the colours and type ramp in `frontend/lib/src/shared/design/`; moving
it onto this package is a follow-up. Until then, change a colour in both
places. The class names match, so the till's files can become re-exports.
