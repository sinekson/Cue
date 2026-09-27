# UI design — the redesign (Home, Detail, navigation)

The rules behind the new UI, what was tried and rejected, and what's still
open. Read this before changing Home (`HomeSpotlightRow.swift`), the Detail
page (`DetailView.swift`), the top navigation (`GlassSidebar.swift`) or the
shared pieces (`Components/TitleBlock.swift`, glass in `Components.swift`).

The new Home is switched on by the launch argument `-spotlightHome` (kept in
`project.yml` — xcodegen regenerates the scheme).

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
- **Rims on artwork**: `GlassRim` (thin light edge, top-left bright, faint
  catch bottom-right) on every poster / card / box; `GlassFocusRim` (bold,
  nearly white, faint glow) marks focus. Static, cheap — no live glass on
  artwork, no transparency.
- **Buttons** (Detail): Apple's system glass `.buttonStyle(.glass)`.
- **Colour**: controls are neutral glass (no accent colours anywhere).
  Colour only for INFORMATION: parental-guide severities, rating sources.
- One dark layer over artwork everywhere: `StageScrim` (left + bottom + a
  light top ramp for the navigation). It never dims when the top bar has
  focus — only content may step back.

## 2. Motion — one system

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
  billboard dots' marker (a drop: front edge runs ahead, back follows; never
  more than one step long), the box's gentle stretch on Left/Right
  (`boxStretch` — kept, but may look less smooth; revisit).
- **Detail page sections**: fast-then-slow page scroll (`detailPageScroll`).

## 3. Layout anchors

- **Title block** (billboard == Detail overview, pixel for pixel, so Select on
  the billboard is an instant swap): the logo's BOTTOM on the screen's
  vertical centre; below at fixed distances the meta line, the ratings row
  (reserved even when empty), the button row (billboard: its dots). The
  description is hidden for now (`TitleBlock.showsDescription = false`) so
  the block never changes height.
- **Meta line** (one builder, `TitleBlock.metaSegments`, used by Home's
  caption, billboard, Detail): Type • ONE genre (skip "Animation"/"Anime" if
  another exists) • Years ("1999–Present") • Seasons/Episodes or runtime •
  ★ rating.
- **Section hints** (`SectionHint`): left-aligned at the content margin, the
  chevron (text-sized) first, small spaced capitals, half white, gentle bob.
  Always at ONE of two fixed spots: `hintBottomInset` from the bottom, or the
  same from the top — never attached to content.
- **Top navigation**: a Liquid Glass pill, `🔍 Home Library Settings (avatar)`,
  centred as one group; focus follows the tab (moving focus switches the
  tab; entering from the page does NOT); gliding glass highlight — circle on
  the icon/avatar, capsule on text; the focused tab gets the bright focus
  glass. Home remembers its row and title per row across tab switches.

## 4. Tried and rejected (don't reintroduce)

- A glow behind the focused top-bar tab; an underline indicator; dimming the
  whole screen while the top bar has focus; a text "wipe" light between tabs;
  growing the whole bar AND the tab.
- Up/Down variants: two-step with a pause, pure fade, `.glide`, a three-line
  rotating header, posters that widen while scrolling diagonally. (`.fade` and
  `.glide` still exist behind `verticalStyle` for comparison.)
- Logo/info INSIDE the box at the bottom of the screen; buttons above the
  logo; the Detail logo pinned to Home's box logo position; centring the whole
  Detail block (it jumps per title); a large "Details" button on the billboard;
  an "i" / icon in the billboard marker; the billboard dots sliding past a
  fixed pill.
- Chevrons as separate floating layers (they belong to their row); the
  outline handed from box to box; outlines with their own animation (they
  came loose from the box).

## 5. Open / next

- More page: the hold menu on posters; the fast-then-slow scroll between its
  rows; remove the now-unused `CastChip`, `CompanyLogo`, `SeasonChip`.
- The zoom transition Home box → Detail (system `navigationTransition(.zoom)`
  plus the logo gliding) — discussed, not built.
- Back from Detail to Home still uses the push slide.
- Description on the overview is hidden (see above) — decide how to bring it
  back (synopsis teaser is the way to read it now).
- Ratings badges: move to glass chips with the sources' coloured icons.
- The billboard → Details swap has not been checked on a device since the
  latest layout change.
