# UI design — the redesign (Home, Detail, navigation)

The rules behind the new UI, what was tried and rejected, and what's still
open. Read this before changing Home (`HomeSpotlightRow.swift`), the Detail
page (`DetailView.swift`), the top navigation (`GlassSidebar.swift`) or the
shared pieces (`Components/TitleBlock.swift`, glass in `Components.swift`).

The new Home is the only Home (the old layout was removed). Collections show
on it as plain rows for now (`HomeView.spotlightRows`) — not styled yet.

## 0. Direction (locked 2026-09-28)

**Flat artwork, glass controls, one outline for focus. Motion calm and
quick.** Priority is a stable 60 fps; smooth over fancy. Tried and dropped
the same day: a warm "cozy flat" variant (warm neutrals, cream, rounded
type, grain) — looked wrong; fancier poster hairlines — not needed.

**Top bar (locked 2026-09-29):** one floating Liquid Glass pill (tabs +
profile); a white capsule glides to the focused tab (dark text). The flat
tab names and the dark top fade were tried and removed.

## 1. Glass language — one set of parts, used everywhere

Defined once in `Components.swift` (`AppGlass`, `GlassHighlight`, `GlassRim`,
`GlassFocusRim`) and `TitleBlock.swift` (`GlassChevron`, `SectionHint`).

- **Surface**: `glassSurface(in:)` — real Liquid Glass (`glassEffect`) on
  tvOS 26+ capable boxes, frosted material otherwise (`AppGlass.isReal` is the
  one rule). Always as a BACKGROUND: a `glassEffect` wrapped around focusable
  content hides it from the focus engine.
- **Highlight on glass** (`GlassHighlight`): itself tinted glass — bright when
  focused (dark text, the tvOS focus look), faint when merely current.
- **Text on glass**: `AppGlass.text` (white), `.textMuted`, `.textOnFocus`.
- **Artwork carries no line** (locked 2026-09-28): posters, cards and the
  box are artwork + rounded corners only — no rim, no glow. The glass rim
  (`GlassRim`) is gone from Home's posters and box.
- **Only focus gets a line**: `GlassFocusRim` is a solid white outline, no
  glow, no gradient. One meaning, everywhere.
- **Glass is for controls, never content**: top bar, buttons, chips,
  chevrons. Anything that slides with content stays flat.
- **Buttons** (Detail): exactly three, always there — Play, Add to
  Library, Watch Trailer (without a trailer: a toast). `DetailActionButton`:
  a circle with its icon at rest (plain fill + glass rim, not glass); the
  row's ONE pill (the focused button — or, focus elsewhere, the last
  focused, in the rest colours) is always as wide as the widest title needs,
  with its icon + title centred; the other two are circles. So the group's
  left and right edges never move — only where the pill is inside it. White
  while focused; one calm curve (0.24s), no focus lift ("Play" / "Play
  S1:E1", "Add to Library" / "In Library", "Watch Trailer"). Hold Play
  (0.5s): straight to Choose Source (no menu). From the billboard they grow
  out of dots together, one spring (`DotGrow`).
- **Colour**: controls are neutral glass (no accent colours anywhere).
  Colour only for INFORMATION: rating sources
  (each MDBList source by its own icon — `MDBListProvider.iconAsset`, from
  NuvioTVOS; MyAnimeList, with no icon yet, a chip in its blue). The billboard shows
  the same ratings row as the Detail page.
- One dark layer over artwork everywhere: `StageScrim` (left + bottom + a
  light top ramp for the navigation). It never dims when the top bar has
  focus — only content may step back.

## 2. Motion — one system

**Four tokens, nothing else** (`Motion` in `FusionTokens.swift`, locked
2026-09-28; durations tunable in Render Lab until final): `focus` 0.2s,
`move` 0.35s, `present` 0.45s — springs with NO bounce (they keep their
speed when a press interrupts them) — and `fade` 0.25s ease-in-out.
**One press, one movement.** Removed: the box stretch on Left/Right, the
wrap press-and-hold (the ring now wraps with a plain `move`), the end
bounce (now a small `endNudge`), the two-phase Down (open + scroll are one
`move`), the billboard dots' liquid stretch, the bouncy `DotGrow`.
Spotlight's named curves (`slide`, `wrapSlide`, `rowChange`, …) now just
return a token. Details below describe WHAT moves; where they name older
curves or timings, the tokens win.

- **Horizontal rows** (Home catalogs, episode row, More-page rows): a FIXED
  box at the focus position whose content CROSSFADES in place (neighbours
  mounted invisibly); the cards slide UNDER it (the current one hidden
  beneath, the previous one peeking into the left margin). The focus rim
  belongs to the box and never moves. Curve: `Spotlight.slide`.
- **Rings**: catalogs with ≥ `minRingCount` titles (and the billboard) loop.
  Between end and start a glass END CARD ("↺ Back to start", the row's card
  size). Crossing it: the resistance nudge (cards give, the end card is
  "pressed"), then `wrapSlide`. Continue Watching and short rows END: at the
  ends the same resistance, then spring back (`endBounce`).
- **Episode row**: one row, Specials → S1 → S2 …; a glass season SEAM card
  ("Season 2", n episodes) between seasons, crossed with the same heavy step.
- **Vertical (Home)**: `verticalStyle = .scroll`. Down: the preview row
  opens its box (fast, linear `prepare`) while the scroll (`downScroll`,
  slow start) barely moves, then everything scrolls up. Up: one movement,
  the old row folds back into posters on the way (`rowChange`). Each row
  carries its name (and the "▴" label) rigidly; names never change size
  mid-scroll. Logo, info and outline are PART OF THE BOX (they travel and
  grow with it).
- **Liquid touches**: chevron press (gives + brightens), end-card press, the
  Detail buttons growing out of dots (`DotGrow`), the box's gentle stretch on Left/Right
  (`boxStretch` — kept, but may look less smooth; revisit).
- **Billboard ⇄ Details** (`ModeSwap`): the title block, backdrop and scrim
  never move. Each screen animates only its OWN parts — the leaving
  screen's go out (`ModeSwap.out`, 0.16s, quick), the screen changes with
  no system animation, the arriving screen's come in (`ModeSwap.in`, the
  page scroll's fast-then-slow, 0.45s); fades on their own linear timing
  so the movement reads; the screens change at 75% of the going half
  (`handoverDelay`). The buttons fade through an always-present mask —
  fading glass's own opacity flickers at the end; Back runs
  the same halves the other way, so the reverse is exact. Home: top bar
  moves up 80pt and fades, "▾ Continue Watching" and the dots move down 40pt
  and fade (the mirror of the top bar). Details: the backdrop leans in (1.04) and darkens a step (25%) —
  the same on all three Details pages (scrolling doesn't change it). ONE
  motion with the rest: it starts on the press and ends as the arriving
  parts land — a 0…1 progress across the handover, the leaving screen
  taking it to `depthHandover` (35%), the arriving one on from there on the
  `in` curve; Back mirrors it; the buttons fade in place at
  their spot, "▾ Episodes" comes down into place from 20pt above — the
  bottom moves one way, like a flip.
  Details starts with the billboard's ratings, facts and season count (handed over in
  `ModeSwap`), so the title block is identical from the first frame. Back
  on a lower Details page first returns to the overview (focus on Play).
- **Catalog box → Details** (`ModeSwap.boxGrow`): the billboard swap
  plus ONE move — a copy of the box (at first its exact twin: artwork,
  the box's constant slight dimming `Spotlight.boxDim` 8%, its focus rim)
  grows from its spot to the full screen on the fast-then-slow curve
  (0.4s); the rim goes at once. The DARKENING spans the whole swap: the
  growing box takes the scrim most of the way (`boxScrimHandover` 75%) and
  the depth most of the way too (`boxDepthHandover` 80%), ON the grow's
  fast-then-slow curve (it darkens
  most while it moves most); Details finishes the small rest with its
  parts. (Tried: packed onto the grow's start — a switch; linear with a
  50% handover — "subtle, then dark all at once".) The copy is aimed at the TRUE screen (measured), not Home's
  area, so it lands exactly on Details' backdrop; while the
  rest of Home fades QUICKLY (0.15s — the bright rows below lingered
  around the box) and the top bar lifts. Then Details (no system slide)
  fades in its title block (it wasn't on screen), buttons and hint, and
  finishes the depth. Back: Details' parts fade, the backdrop shrinks back
  into the box, Home fades in around it.
- **Trailer mode** (`TrailerMode`, billboard and Details alike) — SWITCHED
  OFF for now (`TrailerMode.enabled = false`; misbehaved; the Watch Trailer
  button still works): after
  `TrailerMode.delay` (3s) of rest — on Details only while Play holds focus
  — the trailer plays WITH SOUND and everything vanishes but what you can
  act on: the "▾" hint (and the billboard's dots; Details' Play). Logo, text,
  ratings, the other buttons and the top bar go (the scrim eases to 40%).
  Navigating stops it (billboard: Left/Right/Down; Details: moving off Play);
  Up or Back first only brings the page back, the trailer running on muted.
  Nothing vanishes before the first video frame (a failed load changes
  nothing). No billboard → Details handoff of a playing trailer yet.
- **Detail page sections**: fast-then-slow page scroll (`detailPageScroll`).
  Within More, each row scrolls the same way to ONE spot (its title where
  the first row's is, below the hint).

- **Timing trap**: `.animation(_:value:)` re-times EVERY change in its
  view — size and position too, not just the modifier beside it. For a
  fade on something that also moves / grows, scope it:
  `.animation(curve) { $0.opacity(…) }`. (It made the top bar seem to only
  fade, and the growing box's rim and dimming detach from its edge.)

## 3. Layout anchors

- **Title block** (shared by billboard and Detail overview), top to
  bottom: logo (560×160 slot) · the ratings row (icon + score per MDBList
  source; without MDBList the catalog's IMDb score) · the description (26pt,
  82% white; at most 5 lines, in a FIXED room) · the meta line (the
  catalogs' own, without the rating) · the badges row (outlined chips:
  ENDED / ONGOING for now) · on Details only, the buttons. Everything from
  the meta line down sits at a fixed spot for every title — the meta line
  is the block's visual anchor; a short description leaves its room above
  the meta line.
- **Continue Watching** (Home): every card landscape, the box's size.
  INSIDE the card its state, one line — the episode row's own layout,
  which episode LEFT, its status RIGHT: "S1:E1 ▬▬▬░░ 38m left", "S1:E1 …
  Up Next", "S1:E1 … Airs in 3 days" (same wording as the episode row,
  `MetaVideo.airCountdownText`) — every card says where it is. RULE: one
  episode shows the same state everywhere (Continue Watching, episode row,
  Top Shelf) — on a dark foot (`continueFootOpacity`); no logo (box and cards alike). BELOW the box its
  identity, two lines: the name (+ status chips: "N new", "In Library"),
  then the episode's name (a movie: the catalogs' meta line). The show
  name leads (more prominent), the episode's name is muted. 
- **Episode row** (Details): the same rule. INSIDE each card one state
  line on the same dark foot — the episode LEFT, its status / time RIGHT:
  "S1:E4 ▬▬▬░░ 20m left", else "S1:E4 … ✓ Watched" / "… Airs …" / "… 45m". BELOW the box: the
  episode's title (prominent), then the synopsis (2 lines) — no meta line:
  the runtime is in the card, past air dates are dropped, and no rating
  (it hints at the "big" episodes). No number/title or corner badges on the cards.
- **Billboard dots**: one per title, each at a fixed spot; the current
  one is large and white, and changing title it shrinks back as the next
  grows, in place — the new one swells with a little overshoot,
  arrives stretched the way you paged and springs round. Bottom right, on the "▾" hint's line — the
  navigation cues together (hint: Down, dots: Left/Right).
- **Meta line** (one builder, `TitleBlock.metaSegments`): Type • ONE genre
  (skip "Animation"/"Anime" if another exists) • Years ("2021–Present") •
  runtime (movies) / Seasons, or Episodes for a single season • ★ rating
  (Home's caption only; the title block leaves it out).
- **Section hints** (`SectionHint`): left-aligned at the content margin, the
  chevron (text-sized) first, small spaced capitals, half white, gentle bob.
  Always at ONE of two fixed spots: `hintBottomInset` from the bottom, or the
  same from the top — never attached to content.
- **Top navigation**: `🔍 Home Library Settings (avatar)`, centred as one
  group; focus follows the tab (moving focus switches the tab; entering
  from the page does NOT). Home remembers its row and title per row across
  tab switches. Two looks (`GlassSidebar.topBarStyle`):
  - `.flat` (current): no pill, no highlight shape — the names straight on
    the screen in the section hints' typography (spaced capitals, 21pt,
    half white), tightly spaced, with the hints' soft shadow; grey, white for the current tab, the
    focused one also grows (×1.12); the avatar gets a thin white ring.
  - `.glass`: a Liquid Glass pill with a gliding glass highlight (circle on
    the icon/avatar, capsule on text; bright focus glass on the focused
    tab) — felt apart from the rest of the UI.

## 4. Tried and rejected (don't reintroduce)

- A glow behind the focused top-bar tab; an underline indicator; dimming the
  whole screen while the top bar has focus; a text "wipe" light between tabs;
  growing the whole bar AND the tab.
- Up/Down variants: two-step with a pause, pure fade, `.glide`, a three-line
  rotating header, posters that widen while scrolling diagonally. (`.fade` and
  `.glide` still exist behind `verticalStyle` for comparison.)
- Logo/info INSIDE the box at the bottom of the screen; buttons above the
  logo; the Detail logo pinned to Home's box logo position; centring the whole
  Detail block (it jumps per title — and breaks the billboard swap); a large "Details" button on the billboard;
  an "i" / icon in the billboard marker; the billboard dots sliding past a
  fixed pill.
- Chevrons as separate floating layers (they belong to their row); the
  outline handed from box to box; outlines with their own animation (they
  came loose from the box).

## 5. Open / next

- More page: hold menu (on the whole row, content follows the current
  poster) and the per-row scroll (`MoreRowAnchor`) are built — check both on
  a device, in particular what the menu's lift preview looks like.
- The zoom transition Home box → Detail (system `navigationTransition(.zoom)`
  plus the logo gliding) — discussed, not built.
- Back from a Detail page NOT opened from the billboard still uses the
  push slide.
- Tried: a "Watched n of m episodes" glass pill beside the Episodes
  heading (after Nuvio) — removed, looked out of place.
- Tried: dots in the buttons' row (paired with the buttons; the seamless
  swap made billboard and Details hard to tell apart); low at the left
  above the hint (detached).
- Tried: meta line + badges following a short description directly (no
  fixed anchor; the gap moved to below the badges).
- Tried: ratings at the end of the badges row / as a row under the badges
  (chips and icons side by side never looked aligned); top right on the
  top bar's line; the buttons between
  badges and description (the description had to slide on the swap);
  the description at full white 28pt (overwhelming).
- Tried: the button row opening mid-block (text sliding down to make room);
  meta line + badges on one line under the logo; meta line and badge row
  BELOW the description (a short
  description left a hole in the middle of the block).
- Tried: pills growing out of fixed circle slots over their neighbours
  (first → right, last → left, middle both ways).
- Tried: the focused button widening IN the row (the neighbours slid
  around) with the focus lift on its own timing (wobbly).
- Tried: a big "Episodes" title on the Episodes page; a toast on Add to /
  Remove from Library.
- Tried: a Play hold MENU (Choose Source / Start Over / Mark Watched);
  the buttons growing out of dots one after another (read as uneven);
  a pill-shaped Play at rest.
- Tried: glass buttons (flickered as they faded in — glass renders
  differently below full opacity); a ⋯ menu, Rate, Play in Infuse,
  "Play"/"Resume" in the Play label.
- Tried: the buttons rising in (moving read as odd; they fade in place).
- Tried: the flat top bar in 28pt bold names (read as a heading from
  another app).
- Tried: top bar / bottom cues travelling all the way off the screen
  (too far; the hint was long gone before Episodes came).
- Tried: Details darkening further on Episodes / More (60%).
- Tried (trailers): Details' idle → full-screen escalation with an
  invisible focus-catcher (now dormant); a muted billboard preview that
  kept the logo.
- Tried: the hint flipping on its horizontal axis (3D turn); the dots
  fading in place; the hint rolling down/up with a small lift.
- Tried: episode cards with "Episode 4" + a big title and top-right
  Watched / air-date badges on the art.
- Tried: a dark progress track for bright stills (barely better; apart
  from the Top Shelf).
- Tried: Continue Watching with the show's logo on the cards, and a third
  info line with the time left in the accent colour (cramped).
- Tried: the dots' neighbours rippling as the current one changes.
- Tried: a liquid marker travelling between the dots (stretched when
  paging fast; didn't fit).
- Tried: dots shrinking into the buttons' left end and the buttons growing
  out of it (read as shrink-then-grow; the grow's mask clipped the buttons);
  the parental-guide chips on the overview (removed); certification in the
  badge (only ENDED / ONGOING matters).
- Tried: a "Creator: …" line under the buttons — dropped, too often empty
  (`TitleFacts.creatorLine` is still computed).
- Title block redesign (Nuvio layout): tune the sizes in `TitleBlock` on a
  device; check `descriptionLineHeight` (5 lines must not clip).
- MyAnimeList: the MDBList source name `myanimelist` is unconfirmed; no icon.
- The billboard → Details swap has not been checked on a device since the
  latest layout change.
