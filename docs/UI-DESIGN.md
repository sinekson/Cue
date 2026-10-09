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

## 1. Glass and flat — one rule (locked 2026-10-03)

**Glass only for what floats above the page; everything in the page is
flat.** (A fully flat look — our own hold menu, a loose top bar — was built
and compared, then dropped: the system's menus are glass anyway.)

- **Glass** (`liquidGlass(in:)`, `Components.swift`) — the ONE glass: Liquid
  Glass `.regular` tinted `AppGlass.surfaceTint` (black 30%), nothing added
  on top (no extra tint layer, border or shadow per surface). The slower
  boxes get `FusionMaterials.dialog` instead (`AppGlass.isReal`). Always as a
  BACKGROUND: a `glassEffect` wrapped around focusable content hides it
  from the focus engine. Used by: the top bar, the system hold menus (the
  system's own), the source picker, dropdowns' lists, the "Finding a
  source" card, overlays (About's full text), toasts. ONE exception in the
  page: Details' action buttons (Play, Library, Trailer) — the top bar's
  look, glass at rest and the bright glass highlight focused (decided
  2026-10-04; watch the billboard ⇄ Details swap: glass renders differently
  below full opacity, which is why they had gone flat once).
- **Highlight on glass** (`GlassHighlight`): tinted glass — bright when
  focused (dark text), faint when merely current (the top bar's).
- **Flat** (`FlatControl`, `Components.swift`) — every control in the page:
  `rest` translucent white (`restSubtle` for long lists like Settings rows),
  `selected` brighter, `focus` solid white with dark content, a small grow.
  Each control keeps its own shape and size; the colours come from here.
  Shared parts: `FlatChip` (pills: filters, tabs, shapes), `FlatIconCircle`
  (round icon controls), `PillButtonStyle`, the
  Settings rows, the source picker's rows, tiles ("See All", About's card).
  Page markers are flat too: the billboard's and the seasons' dots.
- **Settings rows** (`SettingsKit`): fully rounded like Apple TV's own
  Settings; a faint fill at rest, the top bar's bright glass highlight
  when focused (decided 2026-10-04). The info pane on the right has no
  box: the category's symbol large in its own soft colour
  (`SettingsCategory.tint`), its name and the description centred below
  (a preview, like the account card, keeps a rounded card). The older pages still on
  `SettingsRowBackground` (Playback, Performance) aren't converted yet.
- **Text**: `AppGlass.text` (white), `.textMuted`, `.textOnFocus`.
- **Artwork** keeps its own focus: `GlassFocusRim`, a solid white outline
  (no glow, no gradient), and a small grow. One meaning, everywhere.

- **Buttons** (Detail): exactly three, always there — Play, Add to
  Library, Watch Trailer (without a trailer: a toast). `DetailActionButton`:
  a circle with its icon at rest (glass, as the top bar); the
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
  The overview is its own screen; below it ONE list of rows, no page break:
  a show's Episodes (the box at Home's box spot), then the More rows right
  under it — the collection, More Like This, Cast & Crew, About (only those
  with content; About always). More Like This, the collection and Cast
  scroll the system's way (`MoreScrollRow`: focus moves along, rim + small
  grow, captions below) — not Home's fixed spot. The season progress
  (label, then ticks) sits above the season names. Rows scrolled above the
  current one fade out. Each More row scrolls the same way to ONE
  spot (its title below the hint); the "▴" hint shows on the first row
  only. The overview's "▾" hint names the first row below it.
- **Details: billboard → rows** (decided 2026-10-05, `rigidRest` +
  `rigidNameY`): ONE PLAIN SCROLL where the name and its row MEET. On the
  billboard only the first row's name shows — Home's next-row look: 75%,
  ⌄ after it, dimmed — at the bottom left; the row itself waits at the
  bottom edge (as Home's: only the sliver tvOS needs on screen, contents
  hidden). Down moves everything up by one distance; the name rides
  lifted above its cards and the lift shrinks to nothing on the row's own
  curve (Home's `liftNextTitle`, same Render Lab choice: hold-then-join or
  same pace), growing to full size while its ⌄ turns into the season
  control's ›. The cards switch on at once as they start to rise; on the
  way up they stay until they're back at the edge. The billboard dims and
  stays above (a sliver of its buttons at the top). The season progress
  sits after the row's name (see below). Tried and dropped: the full-size name
  under the buttons; an "▾ EPISODES" hint with fading cards; a peek of
  the cards. Focus back on the billboard settles on Play from the window,
  sent by Details once its text is back in place (`settleOutside`). The
  picture stays (SwiftUI, behind the rows): sharp under the overview;
  below it its blurred copy fades in, dimmed, the shade lighter.
- **Details' billboard text is the engine's** (2026-10-05,
  `billboardOverlay`): the logo, summary, facts and buttons are SwiftUI
  hosted INSIDE the rows engine and moved (and dimmed) in the same Core
  Animation block as the rows — as a SwiftUI layer on top they were
  animated on the main thread and fell behind the rows whenever the page
  was busy (the "name pushes the text" look). The host reaches only down
  to the buttons (over the rows it would hide them from focus). The
  buttons' focus state lives with them (`FocusBridgeHost`; the page reads
  and sets it through `FocusBridge` — SwiftUI focus state doesn't cross
  hosts). Up into the billboard settles focus from the window; the
  engine's preferred focus there is the overlay (Play).
- **Details' rows at Home's spot, buttons in full above** (2026-10-06):
  the scroll is as long as it takes to leave only the buttons at the top
  (the screen's edge halfway between the badges and them, 15 pt) and to
  bring the first row to Home's spot; so at rest its cards' top ~40 pt is
  on the screen, cut off by a LINE (`concealTravel`): the conceal mask is
  stretched past the cards inside the scroll, against the row's own move —
  the line stays put on the screen and the cards rise out from under it
  (no fade, no pop); Up the reverse. (Tried: the row 62 pt lower than
  Home's spot — "further down than the catalogs".) Its name is there from
  the first frame: before the list is in, the row exists with no cards and
  the season Play
  starts as the billboard handed it over ("Play S4:E19" → "Season 4");
  the row then never says "Season 1" first (`rowSeason` falls back to
  Play's season). Down from the buttons that the engine settles back on
  the button (the current episode isn't under it) goes to the row's
  current card (`shouldUpdateFocus`).
- **Billboard → Details swap with rows**: Home's kicker ("NEW EPISODE …")
  fades with the swap (Details has none); Home no longer shows a
  "▾ Episodes" hint in the swap — Details' first row's name comes down
  into place (`ModeSwap.lift`, the arriving curve) once its content is in.
  The backdrop keeps the swap's step-in zoom and the box path's scrim.
- **Season progress under the name** (decided 2026-10-06,
  `rowTitleAccessories`): on its own line under "Season 1 ›" — the name
  stays at Home's spot, the cards move 40 pt lower (`titleExtra`): its
  ticks, at most 360 pt (over 30 episodes: one bar with a marker), then
  "3 of 7" in the caption style. Part of the row in the engine (moves with
  it, not scaled with the focused name); shown only while the row has
  focus. Tried: under the captions (far from the name, crowded the next
  row's peek); beside the name on its line (busy next to the ‹ ›).
- **Vertical curve: SYSTEM SPRING** (decided 2026-10-06, the default;
  Render Lab → vertical curve): UIKit's duration + bounce 0 spring
  (`UIView.animate(springDuration:bounce:)`; SwiftUI `.spring(duration:
  bounce: 0)`) — reacts at once, lands smoothly, and a press during a move
  carries its speed on. Ease-in-out (slow start, read as lag on a TV) and
  a fast-then-long-settle cubic (0.2/0.8/0.2/1) were compared on the TV.
  Measured on the sim, share of Details' 797 pt scroll done at
  0.1 / 0.2 / 0.3 / 0.45 s: ease-in-out 3/17/44/85 %, settle 38/80/93/99 %,
  system spring 13/50/77/94 %. Home and Details share it; Details'
  backdrop blur / dim follows it too; the next row's name lift and size
  follow the row's spring, sampled (`springProgress`). Left/Right keep
  their own curve (ease-in-out).
- **Less white, lighter billboard — TRYING** (2026-10-06, Render Lab):
  Billboard scrim + "Bottom-left corner (soft)" and "Bottom only (soft)"
  (faint, only where the text is; the billboard text gets a soft shadow
  with them — `FixedFocusBillboardText.faintShade`); Text levels (row
  names 90 %, facts / secondary lines 55 % — `FixedFocusText`); Focus
  outline + "Soft, 3 pt 70 %" and "Faint, 2 pt 50 %" (`FixedFocusRing`).
  Per-picture boost of the shade (2026-10-07, `StageArt.boost`): the
  corner / bottom / black + title colour scrims scale 0.7–1.5× with the
  luminance of the picture's left 45 % (`SpotlightTint.textGround`); the
  corner's centre moved up to 82 % so it covers the kicker too. Details'
  own `BillboardShade()` is not boosted yet.
- **Black, smooth — TRYING** (2026-10-07, Render Lab → Billboard scrim,
  first option): the stage scrim's bands (left, bottom, top — darkening BY
  BAND: around the text alone looked patchy), each one smooth curve
  (`BillboardShade.smoothStops`, monotone cubic, 48 stops, level ends).
  Edges a little lighter (left 70 % for 80, bottom 72 for 85, top 45 for
  50), darker towards the info block (~50 % at the column's right edge for
  ~25); corner ~92 % for ~97. No per-picture boost, no text shadow. Tried
  and dropped the same day: a soft area fitted around the text plus a
  highlight cap baked into the picture (patchy, and the cap greyed pale
  skies).
- **Details = Home's billboard** (decided 2026-10-07): the same text block
  (no summary — the tagline line; no reason line; the buttons below the
  chips), the same rest spot for the first row's name ("Season 1" exactly
  where "Continue Watching" is), the same scroll distances (the text and
  buttons go up with the billboard). The picture STAYS behind the rows,
  blurred and dimmed (tried: Home's way — the picture going up, the rows on
  the title's colour layout; the blur looked better on Details).
- **Top peek = bottom gap** (2026-10-06, `aboveVisible`): the row above
  ends as far above the focused row's name as the next row's name is
  below the box's info (62 pt) — its cards show to y 120 (was the top
  bar's centre line, 70), on every row and the billboard (its travel and
  dots follow). A collection is placed by its panel's BORDERS: the top
  border the peek gap below the peek above, and the next row's name the
  same gap below the bottom border (that row rises — `shortBy`).
- **Left/Right during an opening: first land, then step** (decided
  2026-10-06): a Left/Right while Up/Down into a fixed-box row is still
  moving is HELD — the card beside never takes focus mid-move (it grew in
  both ways while moving, forever on repeated presses). The opening is
  hurried to its end (0.12 s from where it is, `hurryOpening`: every
  running animation in the rows replaced by a short one from what's on
  screen to its end — re-animating to the same target didn't retarget the
  spring, and the step waited ~0.45 s for it; the opening's own
  completion is then ignored, `hurriedMoves`), the box
  takes the row (`handOverToBox`), then the held presses run as normal
  steps, one after another (`pendingSteps`, `runPendingStep`). A press is
  counted once, when its move fails (`observeHeldSteps` — tvOS asks
  `shouldUpdateFocus` several times per press); the step goes through the
  controller's preferred focus (a request straight to a card in a strip
  is ignored). Tried: the cells carrying the step during the opening.
- **Home billboard ⇄ rows — TRYING** (2026-10-06, Render Lab → Home:
  billboard like Details, on by default): one move on one spring, but
  each part its own distance (as the Apple TV app does): the billboard
  (picture, text, dots) goes up until its HARD edge is at the top bar's
  middle (`rigidBillboardTravel` = 1080 − `aboveVisible` — the usual peek of
  the row above); the first row comes from just below the
  screen's edge (`rigidRest`: only the sliver tvOS needs on screen, so
  the edge is where cards appear — no line on the picture) ≈ 834 pt;
  "Continue Watching ⌄" from its billboard spot (`rigidNameY` =
  `nextNameY`) ≈ 796 pt — its gap to the cards closes. The dots sit lower
  on the billboard (centred 35 pt from the edge) so they end in the peek.
  The picture is the controller's own layer (`pinnedBillboardPicture` +
  travel: it moves, no blur), under the billboard text (hosted by the
  rows, `billboardOverlayBelowRows`), under the rows. Tried: the picture
  staying, blurring and fading to the colours, with the row at the dots'
  line (cards appeared at a line 40 pt above the edge, on the picture).
  Off: the old whole-screen scroll.
- **Season control** (Details, decided 2026-10-05; tabs and the white pill
  were tried and dropped): the episode row's OWN NAME, in the engine
  (`titleControlRowIDs`) — ‹ in the margin, › after the name, faint; no
  arrow past the first / last season. Up from the episodes focuses it:
  name and arrows white, the name a touch larger, no pill. Left / Right
  step seasons (the row follows), Down into the row, Up to Play. One
  season: no control, Up goes to Play. The progress label under the row
  drops the season name.
- **Into a moving-focus row from outside**, only its current card can take
  focus, and it's the strip's preferred card (no remembered index path).
  The nearest card is often the previous one's sliver, the engine's
  redirect fails when focus comes from SwiftUI, and a remembered card that
  is no longer current left focus on the strip itself — Down did nothing.
- **About** (`DetailAbout`): the full description in a focusable card
  (Select: the whole text over Details), the facts in two label/value
  columns (released/aired, runtime/episodes, genres, director/creator;
  original title, language, countries, rated, network, budget, box office),
  every shown rating source as chips, studios as logo plates that open
  their titles (replaces the old Production row).

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
- **Billboard position** (2026-10-08): round 12 pt dots in a small glass
  capsule (the top bar's glass, 16 pt around them), the current one a
  36 pt pill — filling from its left end while the billboard pages by
  itself (the iOS page control's timer look). Behind you 62 %, ahead 30 %.
  Changing title the old pill shrinks back as the new one widens, in place,
  on the billboard's Left/Right curve and time. Bottom right, on the "▾"
  hint's line (kept there: the calm corner, off the picture's subject, and
  the rows' peek is built around it). (Tried: segments in the glass capsule
  — pills in a pill; segments alone; circles in the map's levels; a
  page-control pill; 14 pt dots with a gliding 20 pt marker.)
- **Billboard pages by itself** (2026-10-08, Settings → Appearance →
  Billboard, on by default): resting on the billboard, the next title after
  5 s (`BillboardAutoPage`) — the current pill fills from its left end
  over that time (linear: a clock). It STOPS at the last title (no wrap;
  the last pill stays solid) and is DONE for that visit — reached by itself
  or by pressing, going back Left doesn't start it again; opening Home
  again, the app coming back or new billboard titles do. Presses don't
  wrap either: the end nudges, as every row's.
  Any press, and every arrival back on the billboard, starts it over; off
  the billboard (rows, top bar, Details, a hold menu, the app in the
  background) it waits — it never takes focus from elsewhere. It pages
  through the rows engine as a press would (`FixedFocusRowsCommand.select`).
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

- More rows: hold menu (on the whole row, content follows the current
  poster; `TitleMenu`'s items) and the per-row scroll (`MoreRowAnchor` — a
  real strip above the row; as a background moved by an alignment guide
  it scrolled to the row itself) — check both on a device.
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
