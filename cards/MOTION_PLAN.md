# دفتر كروت — motion plan

The app's motion is built on Material's motion system (the `animations`
package). One rule: each kind of change moves one way everywhere. The shared
pieces live in `lib/src/shared/motion.dart`.

| Kind of change | Pattern | Piece |
|---|---|---|
| A page opens from another | Shared Z axis (Android, web, desktop); the system slide on iOS | `CardsPageTransitionsBuilder` |
| A page opens over the whole screen | Shared Y axis | same, for `fullscreenDialog` routes |
| Places side by side (tabs) | Fade through | `FadeThroughStack` |
| Steps of one task | Shared X axis, mirrored right to left | `CardsSwitcher(kind: steps)` |
| A figure goes up or down | Shared Y axis, by direction | `ValueSwitcher` |
| Unrelated content swaps | Fade through | `CardsSwitcher()` |
| Something stands over the page | Fade and scale | `showCardsDialog` |
| One thing becomes a page | Container transform | `ContainerPageRoute` |

## Native gestures and buttons

- iOS keeps the system slide, so the edge swipe drags the page and the card
  art flies back under the finger.
- Android: a back swipe is the system's predictive back (the page shrinks and
  shows what is beneath; letting go leaves, dragging back cancels). The back
  button, the app's own back buttons and `pop` play the shared axis backwards.
- Dialogs close the same way for a button, a tap outside and the system back.
- The package's `OpenContainer` widget is not used: its route answers neither
  the iOS swipe nor predictive back. `ContainerPageRoute` is the same
  transform as a page route that answers both.
- Everything stands still under the system's "reduce motion".

## Built (2026-11-16)

Page transitions; tabs; dialogs (account, saved cards, payer, eSIM); sign-in
steps; checkout review ↔ wallet code; card payment stages; order progress
states; first run → shelf; «كروتي» signed-out ↔ list and skeleton → list;
quantity and total.

## Built, second pass (2026-11-16)

- `ContainerPageRoute` (`lib/src/shared/container_route.dart`): Material's
  container transform as a real page route. The iOS edge swipe and Android
  predictive back move the route's own animation, so the page shrinks towards
  what it opened from under the finger. Used for «كروتي» cards and eSIM
  destination tiles. The package's `OpenContainer` widget cannot do this: its
  route is private and is not a page route.
- Micro-interactions (`lib/src/shared/micro.dart`): `BusyButton` (pay and
  confirm narrow to a spinner), `MarkSwitcher` (copy turns into a check, the
  used mark, payment-method check), `Settle` (tab icon), `CountUp` (balance),
  `AppearRise` (rows 30 ms apart, empty-state mark), OTP boxes confirming one
  after another.
- «كروتي»: the list fades through when the filter changes.

## Built, third pass (2026-11-16)

- Brand cards (shelves, buy again, search results) open with
  `ContainerPageRoute`. The `Hero` flight and its tags are gone from the app.
- `ContainerSource` marks what a page opens out of.
- Kept cheap per frame: the page is laid out once and only scaled; it keeps
  one place in the tree from push to pop; nothing fades through an offscreen
  layer; a gesture moves it linearly to the end. All four are pinned in
  `test/shared/container_route_test.dart`.
- Not measured: GPU raster time on a real phone. The brand page's ambient
  blur is drawn inside the scaled, clipped container during the transition,
  which is the first place to look if a phone drops frames.

## Fixes from the phone (2026-11-17)

- The container starts as the tapped widget itself: the route draws the
  `ContainerSource`'s child again inside the container, at its place and
  size, and it enlarges from there. Its own place stands empty meanwhile.
- `ContainerLanding` marks the page's own copy of it (the brand's card). The
  source glides onto it; there the page's own takes over in the same frame,
  and the rest of the page fades in around it through a window in the cover.
  One card from the shelf to the page and back.
- The page and the source are never painted in the same frame: under the
  iPhone's renderer the page came out over the source on the way back.
- Everything goes by the container's size, not the clock, so the page is
  never seen squeezed into the tile.
- «اشترِ مجدداً» tiles open out of the tile tapped (each has its own context).
- Every order in «كروتي» (voucher, top-up, eSIM, in progress) and every eSIM
  destination opens out of its row or tile.
- Checked in slow motion on the iOS simulator, which widget tests cannot
  stand in for: they draw with another renderer and showed none of this.

## Both ends everywhere (2026-11-17)

Every tile that opens a page has a `ContainerSource` on its art and its page a
`ContainerLanding` on the matching art:

| From | To | Landing |
|---|---|---|
| Brand card (shelves, buy again, search) | Brand page card | same picture |
| «كروتي» row art | Voucher card page (arrives as the art, then turns to its code) | same picture |
| «كروتي» row art | Top-up order / done page card | same picture |
| «كروتي» row art | Order in progress | same while under way, else dissolves |
| eSIM card flag («شرائحي») | eSIM page banner | dissolves |
| eSIM destination tile, row flag, search row | Destination page banner | dissolves |

"Dissolves" means the source glides to the landing's place and size and fades
into it there: the banner is not the same picture as the flag or tile.

## Whole rows, and the picture in them (2026-11-18)

Three tiles open out of the whole tile, not only its picture: a «كروتي» row,
a «شرائحي» card and a «كل الدول» row. Each marks its picture (card art, flag)
with `ContainerHero`. The container still grows from the whole tile, but the
picture goes to the page's landing from its own place in the tile (the
tile's start, on the right in Arabic), and comes back to it. The rest of the
tile stays where it is and fades as the container's surface comes in. A flag
stays whole as it turns into the banner.

## Left out, and why

- Search page as a container: it opens from the tab bar's search button, a
  native control on iOS, so there is nothing to grow from.
- «عرض الكل»: changes the shelf's category in place (already has its reveal).
- eSIM plan sheet → checkout as one sheet: merges two sheets and their models;
  a refactor of its own.
- Category chip underline, field error outlines, top-up timeline: already
  animate.
- Search results fading on each keystroke: would flicker while typing.

Keep out: confetti, parallax on lists, anything over 450 ms, anything that
delays a tap.
