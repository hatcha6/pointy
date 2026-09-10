# Camera frames

The stills behind the wall tiles and the invoice player.

## What these are

Real photographs of real interiors, **CC0 / public domain**, graded in `<Cam>`
(desaturate, cool, soften, vignette, grain, burnt-in clock) so they read as
security footage rather than as stock photography. Sourced via Openverse,
filtered to `cc0,pdm` — free for commercial use, no attribution required.

| File | Tile | Subject |
|---|---|---|
| `counter.jpg` | الصندوق | Belvidere Tollway Oasis interior |
| `door.jpg` | الباب الأمامي | Café window, stools and blinds |
| `aisle.jpg` | الممر | West Side Market hall, Cleveland |
| `shelves.jpg` | الرفوف | Supermarket produce shelving |
| `till2.jpg` | الصندوق ٢ | Backlit restaurant window |
| `window.jpg` | الواجهة | Café with arched windows |
| `storeroom.jpg` | المخزن | Archive shelving, boxes and binders |
| `backdoor.jpg` | الباب الخلفي | Workshop panorama (Poly Haven), graded to IR |

## What they are NOT

Not real CCTV. That was tried and it does not exist in usable form: the freely
licensed CCTV footage on the open web is almost entirely police evidence and
news imagery from violent crimes, and the rest of what a web search surfaces is
Getty / Shutterstock / iStock preview comps, which are unlicensed for use.

## Replacing them

Frames off an actual Hikvision or Dahua box are better than any of this, and
would be strongest of all shot in a Libyan shop — the poster's claim is "works
with the recorder already on your wall", and a real frame from one proves it.

Drop the exports in here and point `TILES` in `src/posters/Cameras.tsx` at them
(`photo: 'counter.jpg'`). Any landscape size works — the tile crops to 16:9 with
`object-fit: cover`, and the grade is applied by `<Cam>`, so a straight export
off the recorder needs no retouching.
