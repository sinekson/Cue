# Cue: UI history

The redesign's full record, moved out of `CLAUDE.md`: every look and mechanism
as decided, with its measurements and what was tried and dropped. Read the
matching section before changing that part of the UI. Where this differs from
`CLAUDE.md` or the code, they win: this file is no longer kept up to date.

## Design rules

- **Direction:** flat artwork, glass controls, one outline for focus. Calm,
  quick motion; a stable 60 fps beats fancy.
- The top bar hides by moving out the top and shows by moving back in
  (`GlassSidebar.hidden`, `Motion.move`) — everywhere; it is always in the
  view tree, disabled while hidden. Auto-hide top bar: on every tab,
  Settings too (was: Settings kept it). Its hiding and showing:
  a 0.4 s no-bounce spring (`autoHidden`, `autoHideMotion`; alone on the
  screen, the move's 0.35 s read as a snap; the present's 0.45 s a little
  slow); with the page's parts (into Details in
  place, a trailer) it keeps the move's.
  (Tried: tvOS's own sidebar, `TabView` `.sidebarAdaptable` — closed a
  small pill top left, Back opening it; ours kept.)
- The top bar's tabs: flat words on the page, focused the season buttons'
  white capsule; the current tab keeps the season's flat grey pill at
  rest (`FlatControl.selected`; at first it had none, only the brighter
  word). Coming in from the page only the current tab (not the avatar)
  takes focus: the engine landed on the nearest tab first, Home lighting
  faintly before the snap to the current one.
- **Glass only for what floats above the page** (top bar, hold menus, source
  picker, dropdowns, toasts); `liquidGlass(in:)`, always as a background.
  One glass everywhere: Apple's `.regular`, tinted black 30 %
  (`AppGlass.surfaceTint`; tried: untinted — everywhere, and the panels
  alone), the hold menus too (tried for them: a
  smoked flat panel, near-black 90 %, a light top edge, a shadow; the
  scope pill's flat fill, see-through and solid).
  Everything in the page is flat (`FlatControl`). Details' and the
  billboard's buttons (`DetailActionButton`) and Details' season buttons
  (`FixedFocusSeasonFace`) share one face (`ActionFace`): at rest a
  pill on the top bar's glass (`liquidGlass`, its own edge; tried: the
  frost — the system's thin material, dark, a 1 pt edge brighter along the
  top — read too see-through over bright pictures; a flat white 16 %
  lacked contrast; a thicker frost, dark and light; the scope pill's flat look; on the
  billboard, flat raised fills — light grey read as light mode, black
  40 % with an edge and shadow — glass is the look over pictures), content in
  the text's colour; focused: a white capsule (the one pure white), dark content,
  5 % larger, soft shadow; in quick (0.15 s), out 0.35 s; pressed: back to its resting size, level with the buttons beside it (0.1 s, at least that long for a quick tap), back up on a no-bounce spring (0.3 s) (tried: 90 % of the focused size — it went smaller than its neighbours; 97 % went unnoticed); the player's round buttons and tabs, the hold menus' rows and Settings' rows and buttons the same (`SettingsPress`) — over a
  resting pill the capsule fades into it (same size: shrunk, two pills
  showed); with nothing at rest it shrinks into the button (88 %) as it fades, both from the start, the
  fade even (a delayed fade overlapped the next capsule); the content
  blends along with it (tried: a quick switch at half the fade).
  Seasons: only the row's season on a pill — the flat light grey
  (`FlatControl.selected`, the current one of a set; the blur looked
  odd there) — the others plain, muted. Text semibold, icons bold, 26 pt (the buttons 64 tall).
  The first button labelled — its name alone, no icon (tried: with its
  icon); searching, a spinner in the name's place, same width — (billboard:
  Details; Details: Play), the rest
  icon-only (billboard: Library, Next — only its chevron, no pill;
  Details: Library, About), their names under them while
  focused. (Tried, for later: Library's plus becoming the tick — its strokes
  morphing, with a quarter turn, the tick drawn from its left end; SF
  Symbols' Magic Replace and Draw Off / Draw On — on tvOS the plus's arms
  retracted to their outer ends, four dots, not into its middle as in the
  SF Symbols app.) (Tried: bold text; every button labelled.) (Tried and dropped: a dark fill
  at rest — grey, black, black with a light edge; nothing at rest.)
- No accent colours. Colour only for information (rating sources).
- Text: 24 pt regular is the base; 23–25 pt is the floor for TV text.
- Text levels: four, everywhere (`FixedFocusText`; the theme's
  `textPrimary/Secondary/Tertiary` and Settings' levels point at them) —
  at most 75 % (tried: 85 % — bright). Primary 75 %: names and titles — row names (40 pt
  semibold), page and panel names, Settings' titles and row names, a
  focused card's name, the fixed box's name, the billboard's reason.
  Body 65 %: text to read — summaries (About's, the Summary panel's), a
  bio, About's facts and genre chips, the billboard's facts, a source
  link's lines. Secondary 55 %: supporting lines — a focused card's
  second line, the box's facts, page subtitles and facts lines, the
  tagline, Settings' values and descriptions, the sources panel's
  episode. Tertiary 45 %: small labels (kind labels, "SUMMARY", Settings'
  section labels), what's off. Out of focus a caption steps down one
  level (name 55, second line 45). The system font (SF Pro). Badges on
  coloured fills stay white. (Tried: row and page names at tvOS's
  heading grey, 55 % — dimmer than the captions and About's 70 % under
  them; nine levels in all; 85 / 75 / 60 / 45 — too bright.)
- Motion tokens (`Motion`): focus 0.3 s, move 0.35 s, present 0.45 s
  (no-bounce springs), fade 0.25 s. One press, one movement.
- **A press mid-animation**: hurry motion, never waiting. Motion (its
  end already known — a scroll, a card growing, a focus move, a
  sidebar's settings about to show): the press finishes it quickly
  (0.1 s) and then acts, on a settled screen — held, never blocked (a
  press that does nothing reads as missed). Waiting (a cover over a
  load — pages, Details): presses are dropped until the page is whole,
  then focus goes in. Applied place by place, not one mechanism (Core
  Animation, UIView and SwiftUI each their own). Kept as they are: the
  billboard's paging (its own rule), hold menus and the source panel (a
  pick mid-unfold closes from where it is).
  Except a long journey — Back's scroll up to the billboard, the first
  row, a grid's top: it goes at its own pace (hurried, a whole screen
  in 0.1 s looked wrong) and a press in its first part is dropped, then
  acts as usual once it's nearly there (tried: hurrying it; holding the
  press and running it on landing — it came late, an action from the
  past; dropping it to the very end — the button lit but dead through
  the tail).
- Animate transforms and opacity only. Never alpha 0 on a focusable list
  (tvOS skips transparent views); hide cell contents or mask instead.

## Decided mechanisms

- **Tabs**: every tab stays alive once built; the top bar's are built
  ahead, hidden, one every 1.5 s after the launch lifts
  (`buildTabsAhead`), so a first visit is no build. A switch: the old
  page gone and the new one there in the same frame, no fade, no drift
  (as Netflix's) (`switchTab`). The switch's own update is never
  animated (the bar's focus move carries one). (Tried: a cut — abrupt;
  a dip through the background, out 0.1 s then in 0.2 s — the empty
  in-between looked weird; both pages fading at once — a dip, flickery;
  a 0.25 s dissolve, the new page whole under the old fading off it —
  heavy; Netflix's, the old page gone at once and the whole new page
  drifting in from 36 pt — its picture's edge showed (Netflix's
  billboard is a card on black), and the background flashed between
  them; a plain fade over the old picture, 0.3 and 0.15 s — didn't feel
  good; the content alone drifting, the picture still; a parallax, the
  picture 12 pt to the content's 36 — both should go the same distance;
  the picture starting grown to hide its edge — weird; the billboard's
  paging slide, the new page from all the way off over the old going
  half as far — too much, and confused with the billboard's own; the
  old content gone at once, its picture left under the new page fading
  in over it (0.3 s, easing out), with the drift — dimmed at its end,
  even with the old picture kept until the fade's completion; 36 pt on
  0.6 s — fine, a further drift wanted; 72 pt with no edges, the whole
  page (stage, clip, background) going over the old one, left under it
  until the drift ended, 1 s then 0.7 s — the edge wanted back; with
  the edge, 72 pt on 0.7 s — a little far, 50 pt — the first, 36 on
  0.6 s, was best; no drift, a plain swap — the drift back, a little
  quicker, 0.5 s; 36 pt on 0.5 s — halved for a gentler drift; 18 pt —
  the drift dropped. How it was built, in case it comes back: Home's
  page held aside from its first frame by an additive translation the
  drift's spring replaced (`holdAside`, `driftIn`), the billboard's
  pages moving inside the stage's clip (moving the stage moved its clip,
  a black edge), each picture and shade carried on past its sides by its
  last column, repeated (`Page.extendEdges`, `ATVBackground(shift:)`).
  Search and Settings by a SwiftUI offset on the whole page: fine slowed
  down on the sim, at speed on the TV it stuttered, only Search's
  keyboard moved, and Settings' picture, inside its navigation stack,
  was cut at the screen's edge; a UIKit container so Core Animation
  moves them was talked over.) An inactive
  Home-like tab's rows stay on screen, only out of the focus engine
  (`FixedFocusRowsController.setActive`; hidden, they vanished from the
  page going out and came on a few frames late on the one coming in).
- **Home rows are UIKit**: native focus, scrolling off; we move rows with Core
  Animation in `didUpdateFocus`. Fixed box at the focus spot for most rows;
  collections, Continue Watching and Saved for Later have moving focus (the
  row stays, focus moves across the cards — grown 5 % — a caption under
  each). The fixed rows' posters right of the box also get a
  caption (name, year — at rest's levels) while their row has focus, as
  moving-focus rows (`FixedFocusPosterCell.caption`; none under the box,
  left of it, or in rows out of focus — no extra room between rows).
  Going it fades out in 0.08 s (`captionFadeOut`; it rode the move's
  own duration a long way), coming back in as its mirror: over the
  same share of the way (the spring's first 0.08 s covers ~40 %), at its
  end (`captionFadeIn`; tried: the last 0.12 s — too late). The poster
  going under the box or coming out (its caption travels the box's width
  and more): the first and last 30 % of the way only
  (`grownFadeShare`; with the other captions' fades — ~40 % — it showed
  too much movement beside the box's barely drifting info; tried: 10 %
  — too little; 25 %).
  The box's content changes as one movement with the row: on its spring,
  the captions' timing (`FixedFocusBoxView.show`). The info drifts with the
  picture (~14 pt sideways, 8 up/down), crossfading over the whole move
  on the row's spring — the crossfade matters most. (Tried: 30 pt, the
  last commit's — much better than on the captions' timing; as a caption, on the captions' timing — moving a poster's
  step, `pitch`; on the path of the caption going under the box, ~750 pt
  — much better, maybe too far; 500 pt; 180 pt — half the captions'
  speed; with the picture, ~14 pt.) A caption sits under its poster wherever that is in its cell
  (under the box the cell is box-wide, the poster centred), so the one
  going under the box or coming out moves with its poster. (Tried: held
  back to travel 180 pt — detached from the poster, lining up only at
  the end; at the cell's left edge — off its poster while the cell
  narrowed.) The picture and logo drift a share
  of that on the same curve, old and new alike, inside the room the
  picture's zoom leaves (always 4 % larger than the box, `driftZoom`,
  `zoomRect`; the grown cell's landscape too, so they match): ~14 pt
  sideways, 8 up/down. The new picture fades in with the captions over the
  old, which stays opaque until covered (both fading at once, the posters
  passing under the box showed through). (Tried: the page itself shifted
  30 pt — the old picture showed in a strip at the edge; the new picture
  starting 4 % larger, settling back; the info 14–30 pt, on springs of
  its own, 0.45 s — every part its own pace and distance, disconnected;
  everything crossfading in place — the drift was missed.)
  The box's edge stays on meanwhile (waiting for the new picture, it flickered
  in); a new picture still on its way waits unseen over the old one —
  no placeholder fill, no shade or logo shown early (they flashed the
  box brighter, then dim) — and fades in when it's there (0.25 s); still
  on its way at the move's end: the placeholder, the old one fading
  (0.25 s), the edge with it. The next titles' pictures (±1, +2) are
  decoded ahead at the box's own size as focus moves
  (`FixedFocusBoxView.warm` — the preloader's are at the stage's size, a
  different key: the box decoded from disk on every move, a few frames
  late; with the placeholders that showed as a flash).
  While Left/Right drifts it, the box's place is cut out of the row (a
  mask, only while the move runs — `FixedFocusRowCell.cutOut`): the
  posters sliding under it showed at its rounded corners and beside its
  edges. Posters have rounded corners of their own (the one sliding out
  from under the box was square beside it), centred in their cell — under
  the box a box-wide gap — so they come out and go in on both sides alike
  (anchored left, the one leaving appeared at once at the box's left
  edge while the one coming in slid all the way across).
  After Up/Down the box takes over from the grown cell at once, with the
  cell's own picture and logo (`FixedFocusPosterCell.pictures(for:)` —
  the same files at the same size; the box's copy, often evicted from
  memory by a revisit, came back from disk late: its placeholder flashed
  the cell's poster, the logo popped in). (Tried: the box waiting for
  its own copy — Left/Right meanwhile left the cells carrying the step,
  growing into place; forcing it in then flickered.)
  Up/Down opening, the card is ONE shape: both pictures fill the growing
  card (centre cropped), on the move's spring (`FixedFocusPosterCell.reshape`;
  each at its own fixed size, the picture switched at once while the edge
  still grew around it), the landscape crossfading over the poster from
  the press (the code asks 25–75 % of the way, but nested in the spring it
  takes the spring's timing — and looks right). Closing: the landscape
  at the left, cropped as the card narrows, the edge on it; the poster stretched to fill the card
  (a 2:3 picture can't fill 16:9 without zooming or stretching — zooming
  looked bad — the best so far), crossfading in over it from 50 to 90 %
  of the way (`closeStretch`; 25–75 % — the stretch showed too much),
  less stretched as the card closes, its own shape at
  the end (`FixedFocusPosterCell.close`; good enough for now, not
  perfect).
  (2026-11-08: the first opening of each title flickered: its landscape was
  only loaded at the press, decoded from disk mid-move, the placeholder look
  flashing. Now the selected titles of the 3 nearest rows each way are
  decoded ahead, and a picture still late leaves the poster up until it's in.)
  (Tried: at the press the card the poster, at its own size at
  the card's left edge (or centred), the landscape fading away beside it
  in 0.3 s outside the edge; the poster fading in at 95 % in 0.15 s, stretched a
  few percent; at its own width at 90 % — the edge showed apart from it;
  only once the card was its width, within 1 pt — too late, the spring's
  tail; that swap blurring through — both pictures blurred over it, the
  poster sharpening — looked terrible.) (Tried for closing: a blurred
  copy of the poster filling the shrinking card around the sharp one, both
  fading in on the move's spring — not good; a closing window — the landscape at its own size, centred,
  cropped by the shrinking card, the poster fading in over it; as before — each
  picture at its own size, the poster back at once, the edge shrinking
  around it, apart from the picture; Netflix's way —
  the poster at its end size at the press, the landscape fading off it in
  0.2–0.3 s — too snappy; the opening's reverse — the landscape shrinking
  with the card, the poster crossfading in at 90 % of the way, filling the
  card (~1.2×, settling through the spring's tail) or at its own size; the
  poster filling the shrinking card from the press — centred, its foot
  cut off and the logo dropping to the edge; foot-pinned, it zoomed and
  slid against the row's own move, a wobble. Talked over, not built:
  paging as the billboard's.)
  (Tried and dropped: Left/Right as Up/Down — the box stepping aside,
  the card under it shrinking to a poster, the next growing into it:
  nice, but tiring on the eyes, and no longer a fixed box.)
  Landscape cards' and the box's logos (the add-on's `logo`, over a
  bottom shade) as the billboard's: trimmed of their transparent edges,
  sized by area (40 % of their room — 55 % × 28 % of the card), at its
  bottom left (`FixedFocusLogo`; fitted into the room, wide transparent
  ones sat centred, too far right). (Tried: no logo on the box — it
  never matches the one printed on the poster; brought back.)
  A Select during a move is held and runs as it lands (`heldSelect`;
  any running move finishes quickly first (0.1 s), as for a held
  Left/Right — `hurryOpening`, `hurryMoves` — then two frames drawn
  before Details takes its still; a later move drops it; 1 s at most):
  opened mid-move,
  Details took the screen with the box still empty (the grown card has
  the content until the hand-over). A press going down mid-move (a quick
  hold after Up/Down) alike: the move finishes quickly, then the landed
  box sinks (`pressWaiting`, `runWaitingPress`; sunk while the grown card
  still stood in for it, the card's edges showed around it). A page opened (`PageFade.push`)
  while rows on screen move waits for them alike (`FixedFocusRowsController
  .land` — its still taken mid-scroll, Back dissolved into the rows
  landed: Details seemed to scroll); moves into a custom or moving-focus
  row count too. Presses are held, never blocked (a
  press that does nothing reads as missed).
  SwiftUI scroll versions were rejected (main-thread animation, lost targets).
  The focused row stays at its fixed spot near the top (not centred). The
  row below always starts the same gap (`peekGap`) below what the focused
  row draws — box info, captions, a panel's edge — so the peek varies, the
  gap doesn't; at least `minimumPeek` (70) of its cards always shows. The
  rows after it keep the same gap, so a row doesn't move again as it
  becomes the next one; the rows above too (below the cards of the one
  over them). Into a custom row (About) the rows only scroll as far as
  needed to show all of it, ending `customBottomGap` (60) above the
  screen's bottom — not at all if it already shows (`customContent`).
- **Billboard**: Featured row with invisible cells; picture in UIKit, text in
  SwiftUI above. Content = `BillboardPicks` (new episodes → "Because you
  watched" → trending) with a reason label above the logo. Compact text: logo,
  chips (status + 3 ratings), facts, tagline — no summary (tried: 3 lines under the tagline, too alike). Down as on
  Details: one move, the picture stays (blurring into the colours), the
  first row peeking 60 pt up the bottom edge under the billboard (its name
  above its darkened cards, the page dots on that line). Pages by itself every 5 s, stops at the last title.
  Paging: the new picture slides in over the old from the side you went
  (0.7 s, a no-bounce spring: fast, then slow), the old one moving half
  the width the same way, no fade (`StagePictureView.slideDuration`,
  `outgoingShare`; tried: a crossfade drifting 16 pt). Each picture
  carries its own shade (one piece — a fixed shade showed in front of
  the moving pictures), and its text too: each picture card hosts its
  title's text (`FixedFocusRows.billboardPageText` → `StagePictureView`
  pages), so card, shade and text slide as one, the old text covered by
  the new card's edge. The buttons go with the cards in looks: a still
  copy at rest rides out on the old card (drawn — `ActionFace.still`, a
  flat stand-in for the glass, which can't be drawn), the buttons
  themselves come in with the new one (focus staying on its button) —
  sliding inside their own place, which only moves up and down (one
  layer for both: the rows' updates restarted the slide, detached).
  In the slide's first 75 %, a press the way it goes pages again from
  any button and focus goes to that side (right: Next, left: Details);
  the other way moves along the buttons, as at rest (tried: paging back
  too, reversing the slide — a quick Right, Left paged back); later a
  press moves along the buttons (when that's possible
  again is easy to tell). Back to the card still going out (Left from
  Details): the slide reverses (the front card returns where it came from), no new card
  stacked on the moving pair. A reverse starts the cards from where they are,
  at rest (blended into the running slide, they left the buttons). A
  leaving card in front hides the buttons behind it (a mask moving with
  its edge — the buttons are over everything). Cards no longer shown go once
  at rest (`prune` — a slide cut short reported "not finished" and its
  card stayed underneath, showing when a later slide uncovered it).
  Holding Left/Right: tvOS moves focus along the buttons; at the end
  (Details / Next) it pages on every 0.45 s while held (`holdTimer`).
  Up from the rows: the hidden card focus lands on is taken as the
  CURRENT title (the one above the row's card switched the billboard). The dots stay put. (Tried: the text crossfading in place, 0.35 s; the text as its
  own SwiftUI layer sliding in step — it drifted from the picture.)
  Effects kept minimal: the shade is one fade from the left
  (`BillboardShade`, a light 20 % at the right edge for bright pictures;
  the bottom fade and its dark corner were dropped),
  the text block has one small shadow (35 %, 4 pt) — no per-part shadows.
  Text block: reason → logo → chips → facts → tagline, one visible gap
  (`gap`, 19) between parts, a little more around the chips
  (`chipsSpace`, 26); the reason sits on the logo as drawn
  (`RemoteImage(logoFit:)`), not at a fixed spot. Logos sized by area
  (`LogoFit`, `logoArea` 46 000 pt² within 560 × 160; 65 000 within
  640 × 190 was too large), trimmed of their
  transparent edges first (they start at the text's edge). Chips: solid outlines, 1.75 pt (see-through
  ones took the picture's colour): the status badge off-white (white
  75 %, primary), a rating its source's colour (`RatingChip`). A rating's name is
  its mark (`RatingMark`, 18 pt, as far from the chip's left edge as from
  its top and bottom): IMDb, TMDB, MAL their wordmark on a plate of the
  outline's colour; Trakt its disc and ring, Letterboxd its three dots,
  Rotten Tomatoes the tomato, Popcornmeter the striped bucket, Metacritic
  its ring with the "m". MAL's blue lightened (#4F72CC) to show as an
  outline. (Tried: the names in their colours — "LBXD", "RT", "MC" meant
  little; Rotten Tomatoes' two names in two small lines; white outlines
  for all — colour was better.) Facts and tagline 26 pt (`textSize`); facts medium, 65 %
  (body), quieter than the chips; the tagline 55 %. Tagline fallback:
  the name (kept). (Tried and dropped: the tagline as a quote, 28 pt
  italic 85 %.)
  Buttons (Details' look, `BillboardControls`, in their own host over
  the rows — `FixedFocusRows.billboardControls`; the text and dots stay
  under them): ⓘ Details (labelled, first; no hold — tried: a menu with
  Play, Choose Source), + Library, › Next. No Play button: most picks are for discovering, Continue
  Watching right below plays, and playing (a source search) is heavy —
  behind Details (also safe to land on when paging left).
  Focus is the buttons' (`externalBillboard`, as Details); Details
  first. Left from Details: the title before, Right from › (or Select):
  the next — focus stays where it is, so Right again browses on (`.step`
  command); none past either end. Moving between the buttons stops the
  paging by itself. (Tried and dropped: no buttons; Select on the
  billboard opening Details; the text standing lower; a Play button
  first, the episode under it; wrapping round to the first.)
- **Trailers** (`StageTrailer`, `TrailerPlayer.swift`): resting on the
  billboard's buttons (Home) or Details' (focus on them, no panel, search
  or player — `TrailerGate`) for `Spotlight.trailerDelay` (2 s), the title's trailer (TMDB's keys → `TrailerResolver.backdropItem`; ranked in `trailerKeys`: names like recap / clip / TV spot last, the user's language, then English, Trailer over Teaser, official, "Official / Main / Final Trailer", the larger upload, the newest — in the app's language (TMDB's language setting; English for now, anime too, no subtitles); played from YouTube's HLS playlist, rewritten before the player sees it (`TrailerPlaylist`): only H.264 (hardware-decoded), nothing below 720p, so it adapts between 720p and 1080p and doesn't stall (tried: the 1080p video and audio files merged at play time — two whole downloads, it stalled; that pair stays as the fallback when a playlist fails); up to 5 tried, any below 720p skipped — none good enough, the still stays; not on Apple TV HD; a show's season first — the billboard's new episode / season pick's, Details' row's season, matched to TMDB's by its air date (the add-ons number seasons their own way: Bleach's TYBW is 17, TMDB's 2) — then the show's). Resolved ahead and kept: the billboard's first 3 titles' trailers from launch (under the curtain, not holding it), 4 s apart (`TrailerResolver.warm`, `warmCount`), the rest as they're rested on (tried: every title, again every 2 hours — with up to 5 keys each, 100+ requests a launch: YouTube flagged the TV's address). Gentle on YouTube: its watch page asked for once a session (the player script's address and config kept — `__sessionYtCfg`, YouTubeKit), then only the player answers; refused (its bot check, "Sign in to confirm you're not a bot", or a page that isn't the video's) — no remote extractor (it asks from the same address); a bot check or 3 keys in a row not resolving: no lookups for 30 min, kept across launches (`holdOff`, `cue.trailers.heldOffUntil` — asking on kept the flag on); on disk (`CueCache/trailers.json`) a key's URLs until googlevideo's expiry, a key that won't do (age restricted — not tried remotely, ~10 s lost; below 720p; nothing playable) for 30 days; TMDB's video and season lists a day. Loaded hidden at the rest's start (resolved, buffering), shown when the delay is up; a dead URL resolved again once
  fades in over its picture, in its place: on Home on the current card,
  under its shade and text (`StagePictureView.attachTrailer`); on Details
  over `rowsBackdrop`'s picture. The whole trailer (tried: the first
  45 s — didn't work; talked over, not wanted: rules for when one plays
  — titles not started, once a week; talked over, not built: cutting at
  YouTube's end screen, `endscreen.endscreenRenderer.startMs` — none of
  5 big trailers checked had one, and only the watch page gave it, a
  page per key; YouTube marks nothing at a video's start). Moving
  between the buttons: it plays on (tried: fading out on any move —
  annoying). Paging, leaving the buttons: fades out to the still (0.35 s);
  resting again it goes on where it was. At its end: the still, and the
  billboard moves on (if it pages by itself, after moves along the
  buttons too, which stop the timed paging) — that title's trailer not
  again this visit. The billboard doesn't page by itself while one plays
  (nor its dots' timer). While it's on the picture, the peek (the first
  row's name and cards), the dots and the top bar move out — the way
  into Details in place moves them: the same path and distance, on the
  move spring (0.35 s), from the trailer's fade in (`StageTrailer.shown`
  → `FixedFocusRows.peekHidden`, `movePeek`; the bar:
  `BillboardOpening.trailerShown`); back the same way as it fades out,
  or from the press when the billboard pages (the trailer's stop comes a
  few frames later, through SwiftUI — `onPeekBack`, `letPeekBack`). Up
  or Back brings the bar back (and focus leaving the buttons ends the
  trailer). The info block and buttons stay, as the Apple TV app's. The
  peek is drawn moved only (`sublayerTransform`): the focus engine
  counts it as off the screen, so a guide where it rests takes Down in
  (`peekGuide`). (Tried: the peek and dots fading in place, 0.6 s out,
  0.35 s back, the bar untouched; moving out over 0.6 s, back with the
  paging's 0.7 s spring — a setting on trial, "Trailers: move the row
  out"; everything but the buttons fading too — really clean, but the
  information went.)
  Details alike: its episodes' peek moves out with the trailer; come in
  carrying Home's trailer, it never shows. No trailer behind the profile
  gate or the welcome (`TrailerGate.coverUp`); after the gate, focus
  lands on the billboard's Details (not the top bar), the 2 s from there. Sound off by default. Not under Reduce Motion.
  Details pressed while it plays: the same player goes on into Details,
  not restarted — Home hands it over (`StageTrailer.handOver`), the
  transition's picture comes over Home with it on top
  (`DetailTransitionOverlay.video`), Home not dimmed (the video kept at
  full brightness, only Home's text and buttons fading), Details takes it
  as it opens (`adopt`), at full opacity, no delay. Back
  out to Home the same the other way: Home's billboard takes it on (if
  it's on that title; else let go within 1 s); the peek, dots and top bar stay
  out through Back while it's handed over — `trailerOut`; they came back
  with Home's parts, then moved out again).
  Details: Up from the buttons (nothing else above them) opens that same
  player full screen (`openFullTrailer`) — but not for 0.5 s after the
  billboard is reached from below (Up or Back), while the rows still move,
  or 0.5 s after an Up it ate (`DetailRowsDepth.upEaten`): one Up too many
  climbing back opened it (2026-11-08; swapping it for a Trailer button,
  Up opening About, was tried and reverted the same day); over the logo, in the reason's
  place on Home, a hint says so (tried: at the screen's top, centred) (`DetailTrailerHint`, the `SectionHint`
  look: a chevron up that bobs every 3.5 s, small capitals, 55 %) —
  "Watch full screen" while it plays on the picture, else "Watch the
  trailer"; it stays (tried: a Trailer button — a fourth button, and
  awkward with the trailer already playing behind it). Only once a
  trailer is known to play (the row's season's, else the show's —
  resolved ahead as Details opens, `lookUpTrailer`, kept as the rest's;
  none: no hint, Up does nothing). Full screen
  (`TrailerFullScreen`), where it was, with sound; none on the picture (not yet
  played, ended, trailers off): the title's from its start, the same
  resolving (HLS, 720p floor); it waits for its buffer there (played
  at once without waiting, it stalled on its first frame for good). No
  info panel. Was the system's player; now the player's own controls on
  the trailer's `AVPlayer` (`TrailerController` on `PlayerTransport` /
  `PlayerOverlay`, 2026-11-08): the title's name over the bar (no episode
  line), presses, scan and paused swipes as playback, no stills, no shelf,
  no Audio/Subtitles. With the controls up, Up hides them and Down closes:
  a chevron and "Back to Details" (`TrailerDownHint`, the tabs' words at
  rest) sit where the shelf's tabs peek, with the controls, gone in the
  scan and paused scrubbing; Down with them gone brings them up first (Up
  and Down only bringing them up was tried first).
  For 1 s after the controls hide by themselves, Down does nothing too, as
  Back. Back only reaches the controls with SwiftUI's `onExitCommand` kept
  to the loading and failed states (over the controls it took every Back).
  Opening and closing (2026-11-08): no picture of its own — a clear cover,
  no animation, over Details' picture where the same `AVPlayer` already
  plays (filled, no longer fitted on black); Details' text, buttons and
  shade fade out under it (0.45 s) and back as it closes; the sound rises
  from silence over 0.8 s and falls away (0.45 s) on the way out when
  Details' trailer sound is off. A full-screen crossfade was talked over
  (the same picture under it: nothing to cross, and two alike dip). Was:
  the system cover's own cut to a black page. Back hides the controls, then closes; 1 s after they hide
  by themselves it does nothing (pressed to hide them just as they went,
  it left the player). Out: on the picture again,
  playing on, with the setting's sound. (Was: a separate player resolving the
  trailer again from its start — `TrailerPlayerView`, removed.)
- **Details** uses the billboard's text and shade. Three buttons, as
  Home's billboard: Play, Library, About (`text.alignleft`; was "Summary" — the panel holds About's parts). Hold Play → straight to the
  source list. About opens full screen, on trial, as tvOS Settings' text pages
  (`DetailSummaryPanel`, `SummaryPanelMetrics`): the page blurred behind
  (the system's regular material, dark, black 25 % over it), the name
  centred at the top (57 pt semibold), the genres under it, then one
  column 680 wide (tried: 1092, Apple's, facts three across — too wide):
  the summary (29 pt, body level), the facts two across, the ratings. Up / Down scrolls it (the Up / Down steps 320 pt),
  fading at its ends; Select or Back closes it, focus back on the button.
  (Tried: a glass panel over the page — the name as a row's, About's
  summary and facts one under the other, 28 pt apart, 18–20 apart, side
  by side; the summary alone, 28 pt, 1240 then 920 wide — empty.) The
  source panel may follow.
  Play says "Play"; under it, while focused, a show's episode ("S2:E13";
  a film: nothing — the time left dropped; tried: the episode on the
  button), or "Finding a source…" while it searches.
- **Details' episode row**: under the billboard the episodes' cards peek
  60 pt up the bottom edge, darkened to 50 % (a black cover on the cards,
  not transparency — `FixedFocusRows.rigidPeek`). In the row, season buttons replace the row's name (moving focus; focusing one jumps the row
  there; Up from any card lands on the row's season); the season progress
  ("Season 2 • 3 of 13 watched", ticks) between the buttons and the cards.
  The season buttons and the map come up with the row, fading in (the
  Apple TV app's way). Up reverses it, the buttons and map gone over the move's first 40 % (`headerOutShare`; over the whole move they lingered beside the returning name; 30 % — too fast, 50 % — slow). In the peek the row is named
  "Episodes" (the peek's level, just above its cards — `rigidPeekShowsName`,
  `peekNameLift`), fading out on Down as the season buttons fade in, in
  its place on the cards (Up: back) (tried: no name — the peek didn't say
  what it was). (A shorter Details-only move,
  0.48 s, was tried and dropped: same time as Home's.)
  Tried and dropped: "Episodes ⌄" on the billboard instead of the peek;
  the row's name "‹ Season X ›" as the season control; the full progress
  on the billboard (also with Home's page-dots look); the show's logo over
  the season buttons (Apple TV app's way); progress inside each season
  button; the map above the buttons; the map under the episodes' captions.
- **Details' collection** (films; TMDB's collection — not Cue's Collections):
  the first row below the billboard, above More Like This, named as TMDB
  names the collection ("The Lord of the Rings Collection", "The Dollars
  Trilogy" — it says what the film belongs to; tried: "More from the …
  Collection" — with More Like This under it, repetitive; talked over:
  "In This Collection"). Moving focus, posters with a caption (as Cast &
  Crew's; tried: fixed focus); the other parts in release order (the film
  itself left out), starting on the first; upcoming parts kept, parts
  without a picture left out. Details' peek names its row, as Home's
  (a show's: "Episodes", below; tried: no name, Apple's rule for one
  title's page — the peek didn't say what it was).
- **Details' Cast & Crew**: after More Like This. Moving focus, portraits
  (2:3, smaller than the posters — seven across, `portraitCard`; many
  people; tried: the portrait poster's size), name + role under each; creators /
  director first, then the cast (a show: `aggregate_credits`, most episodes
  first), about 20; no photo: initials; Select: the person's page; no menu.
- **Details' About**: the page's last row — a SwiftUI view in the rows
  (`FixedFocusRows.customRows`), not cards. `DetailAbout`: three columns of
  one width, each as long as it needs (room to the screen's bottom), left
  to right: genres, then tags (TMDB keywords), as chips shaped like the
  ratings' (filled, no outline; focused: white, dark text) — Select: that
  genre's / keyword's films or shows (`Route.genre`, `Route.keyword`,
  `TMDBBrowseView`); focus comes in on the first genre — then the summary,
  whole, under "SUMMARY"; then the facts, two to a line (when/how long/rated → who → where
  from → budget/box office; no network — it's in the row above), and every
  rating, wrapping (not pressable). Behind it a dark band (black 50 %, a clean
  edge, no fade) from just above its name to the bottom — the page's end.
  Never dimmed, in focus or not.
  Before it, **Network & Studios**: a moving-focus row of logos on
  light plates (`logoRowIDs`), Select: their titles.
- **Browse pages** (Details' genres, tags, studios, networks, cast — one view,
  `TMDBBrowseView`): a kind label (GENRE / TAG / STUDIO / NETWORK / ACTOR…),
  the name, one facts line; a person has a portrait and a 3-line bio, a
  studio/network its logo on a light plate. Movies | Series in Search's
  scope pill (`ScopePill`; only where both have titles — studios and
  tags checked at load; none otherwise, the facts line says which ("128
  movies"); a genre maps to the other side's id) — moving along it switches, at
  once as Search's scopes: both sides' first page (posters decoded) are
  loaded ahead, no placeholders between; a switch while the page still
  scrolls up to the pill finishes the scroll first (0.1 s). No sort: one order,
  the best known first — a person's by votes + popularity (`fame`, as
  Search's `bestKnown`), discover pages by votes (TMDB can't sort by a
  blend; its popularity is mostly this week's — it felt random). (Tried
  and dropped: a sort button beside the pill — Popular / Top rated /
  Newest / A–Z, a round `ScopePillButton`, its list in the glass
  dropdown: with the pill switching on focus it was only reached through
  Series, and nothing else in the app sorts.)
  Then the folder pages' grid itself (`FolderPosterGrid`, hosting Home's
  `FixedFocusDestinationCell`; six across). The header and its controls
  are one view in the grid's top inset and scroll with it (a header *cell*
  is recycled once scrolled off, its controls with it). Its height is fixed
  from the first frame (room for the controls kept while loading; none
  without the pill). We choose where focus
  scrolls (`scrollViewWillEndDragging`): first line or controls → the page
  at its top, header whole; any other line only when it would come within
  60 pt of the screen's edge, then just enough to show it. Six posters to a
  line (Collections' grid: seven). A focus guide on the page (not in the
  scroll view — there it was never found), on while the page is at its
  top, takes Up from any column to the controls. Focus goes to the first title once the
  titles arrive — with Movies | Series, to the pill, always on Movies (a
  genre or tag opened from a show too; `FolderPosterGrid.headerFirst`);
  more pages as focus nears the end. (Tried and dropped:
  the header fixed above the grid — too much room lost; tvOS's own focus
  scroll plus resetting the page on the first line — it jumped.)
- **Details' More Like This**: moving focus, posters with a caption (as
  Cast & Crew's; tried: fixed focus, Home's catalog style). TMDB recommendations (else similar), 12 titles; titles
  not yet out or without any picture left out; watched films last.
- **Into Details** (`DetailTransition`, Core Animation overlay):
  - Fade everywhere: Home dims, the cover zooms (0.55 s), info fades in at 85 %. ~0.8 s.
  - The billboard uses the SAME transition as any card (Home dims, its
    picture zooms to Details' — `ModeSwap.depthScale`, 106 % — Details
    comes in; Back: a fade).
  - A trailer never zooms: always the screen's size, as on Home (1920 ×
    1080, not the picture's drift-wide strip — that was 1.7 % larger),
    in the transition, in Details (outside the picture's depth scale)
    and on Back; the still zooms under it, unseen (other footage, so a
    fade between them shows no change of size). It plays on through
    every step. (Tried: no zoom for any title — the zoom looked better;
    a Details at 100 % when entered with a trailer.)
  - From the billboard, on trial: in place, two phases on the move
    spring, 0.35 s each (`DetailTransition.openInPlace`, `BillboardOpening`;
    tried: the present spring, 0.45 s — with the hand-over ~1.2 s in all,
    too slow).
    Out: the top bar, the peek and the dots move out (as for a trailer),
    the reason fades; the buttons stay as they are (each phase changes
    only its own page's parts), the pressed one dimmed after its press
    dip — pressing not possible (`BillboardOpening.focusDimmed`); the
    picture stays. Then Details, built under a still of
    that (its picture at Home's size), takes over; in: its picture leans
    to 106 % (the picture only, a trailer never zooms —
    `BillboardOpening.leanDetails`, `DetailLean`) as its episodes' peek
    rises, its trailer hint appears and its buttons become its own
    (they come in wearing Home's — `DetailActionButton.arriving`:
    Details → Play, › → About), landing together — the picture
    moves with what arrives, as on Back (tried: the lean in the first
    phase, with the parts going — the second phase stood still) (`detailsArriving` — Details built with them held out; the
    peek follows it in its controller, `followsDetailsArriving`, the hint
    with its own `.animation` — changes from another host get no
    transaction). The still is 99.5 % opaque (`seeThrough`): wholly
    covered, Details was first drawn as it went, a stall the second
    phase's moves ran through — they popped in. `BillboardOpening` is
    `@Observable`, each view updating only for what it reads (as an
    `ObservableObject` its eight changes a transition re-ran the root's
    and Home's bodies mid-move). Home's own reset waits
    until the second phase ends (it stalled the move). Presses are
    dropped from the press until the last move ends (`InputHold`: the
    window drops them, the focus engine refuses moves) — the moves'
    end means you can go on. The pressed button stays at its resting size (no
    grow back) and its highlight dims to 50 % from the release,
    the press dip shrunk (0.2 s, eased; tried: from 0.1 s after it, 0.25 s
    — a gap; `DetailActionButton.dim`,
    `dimmedHighlight`), and Details' buttons undim as they arrive (dimmed
    while they wear Home's — `openingDimmed`), growing back to size, on
    the move's spring; on Back the same minus the shrink and grow (no button pressed —
    `closing`): Details' dim with Back, Home's come wearing Details'
    names (`homeWearsDetails`), becoming Home's and undimming with its
    parts — the sign it's over. (Tried: lit throughout, Details → Play in the
    second phase — better, the end still unclear; the highlight gone
    between the phases, back with Play; dimmed after the press had grown
    back. Tried, with Details → Play in the first phase — too much at once on
    one button: lit throughout — the end was unclear; the highlight going
    with the press and landing again with the last move — abrupt, the
    button going off and on; dimmed to 50 % and back; its own 0.15 s
    after the move — late; a beat for the press first — delayed.)
    Back: the reverse — the peek and hint go first (0.23 s,
    `peekOutTime`), then Home under a still of Details, its parts coming
    back (the dots moving with the peek both ways — the same distance
    in the rows' own animation, `setOpeningLook`; tried: faded in in
    place; their own SwiftUI move — a few frames early or late, a
    different distance), the reason fading back in with them (each card
    animates its own copy of `opened` — `BillboardPageText`; the change
    came with the host's new root view, unanimated: it was there at
    once, ahead of the rest); Play → Details and About → › with them
    (tried: with the peek going, the first phase). The buttons' names crossfade centred while the label's
    width goes from one to the other (Details ↔ Play, on the move's
    spring; the text's own content transition kept the old name
    left-aligned, cut off — choppy). (Tried: one phase, Details' peek rising after the move — it
    came late. Talked over, not built: Details built first, then one
    move — a pause at the press.)
    (Tried and dropped, 2026-10-11: Home's parts moving out, Details'
    rising in — seams, doubled pictures.)
  - Details from Home, Movies, Series (their root, not a folder): a layer
    over the page (`detailLayers` in `CueApp`, its own NavigationStack for
    the pages opened from it) — Home stays in the window, laid out,
    hidden (opacity 0, inactive: its rows hidden, out of the focus
    engine). Back: the tabs' dissolve — Home there at once, Details
    fading off it as soon as that's committed (0.25 s, ease in-out —
    `backTime`; `closeLayer`, `fadeOff`; tried: 0.35 s ease out from the
    press); the layer stays, hidden, until the fade is over and the
    remote has been still 1.5 s (`DetailLayer.leaving`,
    `InputHold.whenIdle` — taken down with the close, it held the main
    thread ~0.3 s before anything moved; as the move landed, a press
    just after came late); nothing rebuilt; focus
    back on the card it left (`returnRow`: the system picks the first
    card on screen, we move it on). (Pushed, Home left the window and
    was rebuilt on Back — the cause of the flicker. Tried, pushed: a
    crossfade into Home's still, the live Home taking over; from the
    billboard: text out first, the picture settling 106 % → Home's
    size, through the background picture 0.3 + 0.3 s and 0.4 + 0.6 s —
    every part twice or not gentle.)
  - Elsewhere (Search, Library, folders, the deep link) Details is still
    pushed. Back: the tabs' dissolve from the press (0.25 s, ease in-out,
    `backTime`; tried: 0.6 s, a soft start, a long settle):
    Details off the page's still from the opening's press (`PageFade`,
    see "Other pages in and out"); the live page, rebuilt under it,
    takes over as soon as it's drawn, the still fading off it in 0.2 s
    (`exitHandOver`). (Tried: 0.25 s fade + shrink after the rebuild —
    delayed, then rushed; a quick fade into Home dimmed, then
    brightening; shrinking — the dimmed Home a black border; growing to
    102 %.)
  - Lessons: a UIView animation nested in the moves' spring
    (`springDuration:`) takes the spring's timing, whatever its options —
    its own timing needs Core Animation; a bare sublayer (no view) resizes
    and hides on Core Animation's own 0.25 s, behind the views around it —
    make it a view (`FixedFocusShade`); two identical layers crossfading
    dip (flicker); a SwiftUI hosting view's own opacity faded darkens
    the whole screen mid-fade (~25 % at half way) — fade a plain view
    holding it (`PageFade`'s cover); never draw text
    twice; one shared shade (`StageArt.shade(for:)`); Details keeps Home's
    picture and logo; `CATransaction.flush()` or CA starts a runloop late.
- **Other pages in and out** (folders, browse pages — from Home,
  Search or Details): the same crossfade both ways, no system slide
  (`PageFade`; Details' way in stays its zoom). In: at the press the new
  page's background (`Route.pageBackground` — the Bands / title
  background, or Details' blurred picture) fades in over the page below
  (0.25 s, ease in-out, `backTime`; Core Animation, so it runs while the
  page is pushed and built under it) — the background alone, as on the
  way into Details — and stays until the page is whole (its data in, the
  first screen's pictures decoded; up to 4 s, `PageFade.coverWait`), then
  one 0.5 s crossfade off the whole page, header and content together
  (`handOver`; the dissolve's 0.25 s was abrupt). The cover is never
  quite opaque (`coverOpacity`, 99.5 %: wholly covered, the page was first
  drawn as it went — the fade's first frames skipped); the fade flushed
  before the page's own update. (Tried: the header at once, the titles
  later — came apart.)
  A folder doesn't wait for all its catalogs (the slowest add-on, often
  far below): once its first two rows are settled — every catalog above
  them in — it opens with those and their pictures (`CollectionResolver
  .catalogs(firstScreen:)`, `firstScreenRows`, `PageLoad.start` with
  `show`); the rest are inserted below, the rows on screen and focus
  untouched (`FixedFocusRowsController.update`); the header's catalog
  count as last time until all are in (`PageLoad.whole`). (On the sim
  the data was in ~0.3 s after the press, the fade starting at ~0.45 s;
  the sim then stalled ~0.8 s drawing the new page, skipping most of
  the fade.)
  (Tried: placeholder covers — the background with the page as it
  opens without its titles: the header, bars for its text, empty cards
  as the folder had last time — then the same wait and crossfade;
  removed: the background alone, as into Details, looked calmer.)
  (Tried with those: the header switching to the real one under the fade —
  the text drawn twice; the 0.35 s wait — the page's placeholders, then
  its content: a flicker; only the logo plate a placeholder. Tried before:
  the still of the page below fading off the new page once it was in —
  nothing moved for ~0.6 s after the press; pushed only after the data's
  wait, ~0.8 s; 0.6 s after two on-time frames.)
  Back: as Details' — the tabs' dissolve off that still at once, the
  live page taking over (`pageBack`, set per route; the pages call it,
  not `dismiss()`).
  Stills kept for the last 8 pages.
- **Background**: one still picture on every page, Bands (`BandsPicture.render`:
  Core Image pools, blur, grain added going 16 → 8 bit — no banding):
  tvOS's light Settings backdrop gone dark — tvOS Settings' neutral grey
  (28–29 of 255, measured) under tall soft bands of lighter and darker
  grey, ~30–54 of 255, no colour. (Tried: bands of violet, teal and blue
  on a slate base — the purple disliked; slate blue for the violet, 30 %
  less saturated — too blue, too lively; on the grey; grey at the sides,
  teal and blue only in the middle and top right. Before: Projector —
  tvOS's own dark backdrop recreated (Photos, the TV app; no API), a dark
  warm grey with a cool shadow and a mauve warmth — it read brownish;
  warmer and darker versions of it; tvOS Settings' backdrop itself, flat
  grey.) Settings → Appearance → Background, Static / Dynamic (default)
  (was the "Colours from the title" switch; same key). Dynamic: Home, Movies, Series follow the focused title
  (`TitleBackground`: Home's tint logic — pacing (fast scrolling, presses under 0.3 s apart: a change at most every 0.45 s, blended over 0.7 s; 0.3 and 0.5 were a little busy), fades; the picture's two main colours over a dark base, the first even over the screen at 50 %, the second coming in towards the bottom left; tried: the picture's colour layout, a 4 × 3 grid of its own colours where they sit — too distracting;
  only the tab in front sets it), the collection panels take its colour;
  a folder keeps the colour its tile set on Home (draws Home's
  background, so opening it changes nothing). Either way, a page opened from
  Details (person, studio/network, genre, tag — `Route…backdrop`) shows
  that title's Details picture as below its billboard: blurred and
  dimmed (`DetailsBackdropBackground`). Everything else, and
  everything with Static: Bands. Tried and dropped: a choice of pictures (Ink, Stage, Slate),
  Search / Library following the title, neutral pages keeping the last
  title's background, the old solid colours. No vignette anywhere; below
  Details' billboard only blur + one dim (`dimBelow`, 55 %; a bright
  picture more — enough for a mean luma of 0.18, `StageArt.dimBelow(for:)`;
  the pages opened from Details alike; the shade and the vignette there
  were dropped; tried: darkening bright pictures everywhere).
- **Where pictures come from**: posters and the fixed box: the add-ons'
  (they may draw on them — ratings, genre, trending; taken as they come).
  The billboard and Details: TMDB's main backdrop (`TMDBService.backdrop`,
  the original file; without one, the add-on's), decoded as focus settles
  on the title (`TitlePictures`, `TitlePreloader.focused`), so the press
  finds it in. (Tried: one of several at random each time Details opens —
  by average, by votes, bars on both, 5 / 3 / 2 at most: the others too
  often looked bad.) Not in within 0.5 s of the press
  (`DetailPreparer.choiceWait`): Details opens on the page's background
  (`ATVBackground`) and the picture fades in when it's there — the one
  late arrival allowed. (Logos: next, TMDB's in the user's language.)
- **Portrait posters** (Search, Saved for Later, Details' collection and
  More Like This, the folder and browse grids, the fixed-focus rows — not
  Cast & Crew's portraits): ONE size, six across the content's width
  with the rows' gaps (`FixedFocusMetrics.posterCard`, 265 × 398). The
  fixed rows are that tall (`Spotlight.rowHeight` = its height; was 420),
  the box 16:9 at it (~707 × 398), growing the same 4 %. Details' studio and
  network logo plates 16:9, five across (~320 × 180, `logoCard`; tried:
  the posters' width, 265 × 140 — a thin strip; four across — too
  large; logos white on dark cards — looked like placeholders, TMDB's
  logos are the brands' own, often dark); the browse page header's
  plate stays 265 × 140. (Tried: Saved for Later
  at Home's row height, Details' rows smaller, 330 tall.)
- **Card corners**: 22 pt, continuous (`Spotlight.cornerRadius`; the Apple
  TV app's size). (Tried: 16; 18 continuous; 22 circular, as measured in
  the Apple TV app; a user setting with five choices.)
- **Card edge**: every card (posters, the fixed box, Continue Watching,
  episodes, Saved for Later, cast, studios) has a printed
  card's light frame — a 2 pt line, white 30 %, inside its corner
  (`FixedFocusCardEdge.rim`). Focus: no ring — the same edge, bright (2 pt, white 75 %;
  `FixedFocusRing`), a soft shadow outside the card (`attachShadow`, the cards' shadow picture),
  moving-focus cards grow 6 %, the fixed box 4 % (8, 10 and 12 % were tried: kept as is) (`boxScale`: it
  overhangs its spot, its neighbours step aside, its info isn't scaled).
  Settings → Appearance → Card outlines, three levels (`FixedFocusRing.outlines`;
  switching relayouts every view — live): Edges and focus (default) the rim and the
  bright focus edge, Edges only the rim, Off neither (was the Focus outline
  switch — its off reads as Low). The
  fixed box's info sits `boxInfoGap` (21) below it, as far as a focused
  caption reads. On trial again: the row's name steps up out of the
  focused card's way as the captions step down — by the card's growth
  (half of it, above the card): a fixed row's box from Up/Down into the
  row until leaving it; a moving-focus row's card (collections' too) only
  while it's under the name, on the card's own timing — the move's spring, inside Up/Down's
  longer one too (on the row's, the card rose ahead and the gap closed up
  mid-move) (`applyNameRoom`; tried before — weird).
  (Tried and dropped: the 4 pt white ring.)
- **Back (Home, Movies, Series, Details)**: below the billboard, Back goes up to
  it first (Details: focus on Play; a source search or the summary panel
  first closes) (its title as it is, the rows keeping their places); on the
  billboard, Back goes to the top bar (Details: out, `DetailTransition`);
  there, down to the page (the top bar's own handler — the app is never
  left by Back). A Back no view takes (focus on a view whose handlers are
  disabled, or on nothing — a page, the player or a panel coming in)
  went to the system, which left the app: the window drops it
  (`BackCatch`). One scroll, the billboard's own (0.6 s), however deep. A press
  in its first 0.35 s (~95 % of the way, `backDropTime`) is dropped —
  moves, Select on a card or on the billboard's buttons (`backing`,
  `backScrolling`, `DetailActionButton`); after that it acts at once
  (the focus is already there, lit). A page pushed meanwhile waits for
  it (`land`). (A grid's scroll up moves focus only at its end, so its
  presses are dropped to the end.) Rows coming
  on screen in a move start from their old place, rows leaving go on to
  their new one (`FixedFocusRowsLayout` appearing/disappearing — by
  default they faded in/out in place and ran through each other). Tried
  and dropped: a fade. `HomeBack` (one handler: a nested
  `onExitCommand` took every press), `.focusBillboard`.
- **The trail** (pages opened from Details — a title, a person, a
  genre / tag, a studio / network): Back is never more than two pages
  from where you started (Home, Movies, Series, Search, Library, a
  folder): above it only the page on screen and the one it came from;
  opening another, the older ones go (`trail`, `detailLayerPath` in
  `CueApp`; the layer's root moves up). The page going first takes the
  first one's still for its Back. A page moved down the stack is a new
  view (`.id(route)`), so Back to it lands on its billboard, not on the
  card you left. (Talked over, not built: the full history plus a
  shortcut home; titles replacing each other.)
- **Back (folders, browse pages)**: the same — first to the top, then
  out. A folder's rows: below the first row, up to it (one move, the
  header back in view; `.focusBillboard` without a billboard = the first
  row). A grid (one-catalog folder, browse pages): below its first line,
  up to the top (focus on the first title); on the first line, out. With
  Movies | Series: from any line, the first too, to the pill; from the
  pill, out. A press during that scroll up (focus still on the card left
  — moved, it fought the scroll): dropped, the scroll at its own pace. The
  page's `onExitCommand` decides (`GridBack`): a press the grid took
  itself still reached the navigation, which left.
- **Back (Search)**: from the scopes or the row, Back goes to the keyboard
  (query, scope and results kept); on the keyboard, the top bar.
  `SearchBack` → `SearchKeyboardLine.Anchor.backToKeyboard`: a focus
  request into the keyboard is ignored, so the page is briefly not
  interactive and the search controller's own choice (its keyboard) takes
  focus.
- **Hold menus**: all are Cue's own `HoldMenu` (not the system's: it ate the
  next press; tried again as a switch — ours kept). Glass
  panel beside the card, sized as tvOS's context menu (measured): rows
  66 tall, no gaps, 28 pt medium, the icon in front; focused a white
  capsule (round ends — 30 pt corners read rectangular), 2 % larger;
  the panel 16 pt around them. A pressed row back to its resting size (−3 % was tried: below the rows around it); the card, open +3 % (`heldGrowth`; 2, 4 and 5 % were tried).
  It unfolds out of the card, as the Apple TV app's: from 50 % at its
  corner facing the card, on the present spring (0.45 s, no bounce),
  the glass in 0.12 s, the entries a moment later; closing, back into
  that corner (to 60 %, 0.22 s) (`HoldMenuController.openScale`; tried:
  90 % from that corner, 0.28 s — it appeared beside the card). Placed
  from the card at its held size (`FixedFocusDestinationCell.holdMenu`):
  16 pt from it (`gap`, as a focused card's to its neighbour; tried: 24,
  the cards' own spacing — fine too; its left edge on the next card's
  left edge — the gap changed with the card's growth and the row), opening left when it doesn't fit, level with its top — or, when it doesn't
  fit below that (Search's low row), with its bottom. Behind it the
  screen dims (black 15 %, `HoldMenu.dimming`; 35 % was heavy under the glass), the held card
  cut out (not its shadow) — the cut-out growing with the card from its
  pressed size, on its timing (`HoldMenuRequest.from`, `heldDuration`;
  at the held size at once, a lighter card showed around it); closing,
  back with it to its focused size (`rest`; kept as it was, a thin
  lighter ring; shrunk to the pressed size, the dim on the card's
  edges); dropdowns
  don't dim.
- **Sources**: no sorting or filtering — the add-ons' order (AIOStreams ranks).
  Play takes the first link. 5-min cache. No remembered source.
  The panel (`SourcePanel`), on trial as About's: full screen over the page
  blurred (`FullScreenBlur`, tvOS Settings' way), 0.25 s fade; the name
  centred at Settings' title size, the episode under it, the rest in one
  centred column, 1100 wide, the links fading out at the screen's foot;
  focus goes in at once, on Search Again until the first link
  (left on Details' Play — its own host, not disabled with the page — a
  Back reached nothing). (Tried and dropped: a glass pop-up on the right,
  48 pt in, 1100 × 900, over the page dimmed, with a slight grow from its
  right edge; full height, 1000 and 1240 wide; the
  title's picture alone behind it with its logo left of the panel, or
  with the billboard's shade and the panel in the middle, 0.5 s fade.)
  In it: a show's episode ("S1:E1 · Pilot") under
  the name; then Search Again (an
  icon only, a press) and one tab per add-on — a tab shows its links as
  focus reaches it, no press (no "All"); first, the first link's add-on —
  and at the row's end when the list was found ("Found 4 min ago" —
  a search's end or the cached list's, `foundAt`; "Searching…"). Then the
  links: each one's text as the add-on wrote it (not ours to change),
  Nuvio's badges under it (to become switchable), as tall as their
  lines; text 26 / 24 pt, focused near-black (the second lines 85 %).
- **Settings** (`ATVSettingsView`, `SettingsKit`): Apple TV's Settings
  recreated, measured off its screen (`SettingsMetrics`), on trial
  with a description in its picture's place: the page's title centred
  over the screen (57 pt; Apple's at 56 pt, ours at 121 — clear of the
  top bar; tried: 30 pt lower; at 101 it crowded the bar), the rows on
  the right (1060 pt in, 779 wide, the first — a row or a section label, the same line either way — at 254: as far under the title as Apple's 189 under its 56; tried: 209 — too close under the title), on the left,
  centred 525 in: Apple's tile (`SettingsIcon`, 537 pt square, 112 pt
  corners, white 29 %), its top 48 below the first row's (Apple's; tried: 80),
  a symbol cut out of it — the page's background showing through — all
  at one size (180 pt semibold; tried: 150 — small in the tile; 200): a gear (`gear`; tried: `gearshape`) on the
  categories (whatever row is focused; tried: the app's play), a category's own (outline, no
  fill) on its page and the pages opened from it, crossfading
  (`SettingsCategory.symbol`, `SettingsNav.category`; tried: on a
  category's pages no tile, the symbol alone in the tile's grey, light,
  filled where it has a fill, as Apple's lower levels draw theirs — one
  font size for all, 426 pt (Apple's globe's 490 wide); each fitted —
  into 490 pt, by area, to the tile's width — sizes off; SF Symbols —
  Nuvio `arrow.trianglehead.2.clockwise.rotate.90`, TMDB
  `photo.badge.magnifyingglass` (tried: `text.below.photo`), MDBList `hand.thumbsup` (tried: `star`), Appearance `paintpalette` (tried:
  `paintbrush`), Home & Details `rectangle.grid.3x1`, Playback
  `playpause`, About `info.circle`, Developer
  `chevron.left.forwardslash.chevron.right`); under it (56 pt) Apple's description text
  (`SettingsDescriptionText`, 880 wide, 29 pt regular, 65 %, centred),
  staying there: the focused row's description, else the page's,
  crossfading (0.25 s); nothing to say: it fades away (tried: a home
  screen icon's size, 400 × 240, a category's symbol on its pages, the
  text 24 pt medium 55 % 537 wide; the text alone, no icon; Apple's tall tile, 537 pt square, the symbol dark on it; no picture — the rows centred, a
  card right of them with the description following focus, the two
  centred together; the page's description centred under the title, the
  rows under it at 255; a row's description under its pill; tried: Apple's way — a tile on the left, 537 pt square at (525,
  527), grey, the category's symbol dark on it, the description under it,
  the rows on the right, 1060 pt in, the first at 209); 65 tall, 80 apart (rows holding buttons — lists in Edit, the add-ons and Home rows' lists: Apple's taller rows, 119 tall, 30 pt corners, 16 apart, round buttons 66 pt a lighter fill, centres 117 apart, the last 18 from the end — `tallRowHeight`, `rowButtonSize`); text 30 pt in, the chevron
  36 from the end; focused, the platter 4.5 pt larger each side (788 ×
  74, a capsule), its content 1.2 % larger; a section's label 46 below
  the row above. (Tried: one column, 860 wide, centred, the title over
  it; 780; with the tile, mirrored — the rows left under a left-aligned title, the tile
  right: looked bad.) A level at a time: first the
  categories, as rows ("Settings"; Accounts — Nuvio, TMDB, MDBList —
  General, Developer; an account shows a value only when something's
  missing: "Signed out", "Add key"; each category's line shows as its row is focused — what's behind it; tried: none here, the line heading the category's own page — pointless once inside, and shown for any row without a description),
  Select opens its settings, their rows open lower pages (Watched, Rows,
  Add-ons…), each in the column's place (`SettingsNav`), focus on its
  first row (`opening` — the engine took the row nearest the one left); Back goes up a
  level from any row (tried: below the first row up to it first, as Home's
  and Details' — often useless), focus back on the row that opened it (the only row taking focus
  as its page comes back, `returning` — else the first showed for a
  moment); on the categories, Back: the top bar. Up from the first row:
  the top bar; Down from it back to the row it left (first time: the
  first — only it takes focus meanwhile, `settingsOnlyRow`). The rows by
  name (`SettingsRowsKey`, `settingsRowFocus`); a list's entries
  (`SettingsEntryRow`) are rows by their first control. Playback,
  Developer (old cards) go by geometry. (Tried: the categories a sidebar
  320 wide beside the settings — floating on the page, the three centred
  together; the settings following the focused category, Right / Left
  between the columns; in a glass panel as macOS Tahoe's, inset with 44
  pt corners — it floated; flat and flush as macOS Sequoia's, white 5 %,
  a hairline along its edge — kind of worked, kind of not; before that:
  400 wide at the screen's left inset; 440 + 780 and 480 + 920 centred
  together; the categories a third of the width; their rows 80 % of the
  settings' size; icons.) Sign in is full screen (the first
  launch's). Descriptions: on the left (above), short, and only where
  they say what the name and rows don't — what a brand is (Nuvio, TMDB,
  MDBList's own lines), what a setting affects ("one-time", "this device
  only"), a count you need ("3 of 5 profiles"); else none, the tile alone
  (Nuvio's pages done; the rest one category at a time). (Tried: a row's under its pill, always (24 pt, 55 %, 10
  below it); the focused row's card 480 wide; under the pill, the
  rows below stepping down to make room — a lot of movement; inside the
  focused pill, under the name — the pill grew tall; opening after 0.4 s
  of rest, the rows above moving down to keep the focused one still —
  horrible.)
  The rows on a faint fill, focused white; 38 pt text (name medium,
  value regular). (Tried: focused 2 % larger, uniformly.)
  Section labels as Apple TV's too: 29 pt semibold capitals, no extra
  spacing, 45 % (tertiary; was 55 %) (tried: Home's section hint, small and widely spaced).
  (Tried: 72 pt rows with the cards' corners, 22; 29 / 27 pt text 22 pt
  in.) Section labels and headings lined up with what's inside the rows —
  the rows' text (`labelIndent` = `rowInset`;
  tried: 5 pt in from the rows' edge, as Home's row names, `textIndent`;
  on the edge itself). Choices open their options as a page in the column
  (`SettingsOptionsRow`: the options one row each, the current one
  checked, Select picks and stays — Back goes up; tried: going back on a pick) — no pop-up menus (tried: the
  glass dropdown, `HoldMenu.openDropdown`; MDBList's done, the other
  pages still to move over).
  Text at the app's levels (names 75 %, values 55 %, labels 45 %). (Tried
  and dropped: the rows beside an info pane — a box with the category's
  symbol, the description under it: room wasted, the words far from their
  row.) Playback, Developer still on the old cards (Right goes in,
  Select not yet) — to be redone one by one.
  Between levels, as Apple TV's Settings' (measured off a recording):
  into a page the rows go left and the new ones come from the right,
  200 pt on a 0.55 s no-bounce spring; Back the other way (`SettingsPageMove`,
  `AnyTransition.settingsPage`, `SettingsNav.forward`; tried: 80 pt — too
  little; the move's 0.35 s — quick beside Apple's). The old rows fade in
  0.25 s, the new ones over 0.5 s; left of the column the rows fade away
  at a soft edge, 960–1040 pt, never reaching the tile (`columnMask`).
  Only the rows (and a page's own buttons) move: the title and description
  are the screen's, not the page's (`SettingsPageHeaderKey`), the title
  crossfading in place 0.15 s after the press, 0.3 s; the tile's symbol
  as before; an old card page moves whole. The lit row rides out with its
  page, fading with it; the new page lights 0.7 s after the press
  (focus is there all along, unseen — `SettingsNav.settling`,
  `settingsFocusHidden`; tried: gone just ahead of the move; lit on the
  new page throughout — it didn't go with the others).
  (Lesson: a view going out is frozen — environment changes don't reach
  it, only its transition's own modifier; tried: shifting the rows
  through the environment, the page going out stayed put.)
  Only the rows scroll, fading out over 47 pt above where the first
  starts (as Apple's: from ~18 pt under the title; tried: 24 pt, from the title's foot — too close) — nothing goes higher (`SettingsScrollingPage`; tried: the whole
  page scrolling up past where it started).
  Not everything is a button: what's only to read takes no focus —
  Apple's look, a row's name and value, no fill (`SettingsInfoRow`), and
  only below the buttons, never a button under it: a page's rows to read
  come last (14 pt more room under a button above, `infoGap`). A page with nothing to press holds focus unseen (`SettingsFocusHolder`;
  without it focus left for the top bar). Every
  page — a category's own and those opened from it — its title alone,
  one title on the column, as Apple TV's Settings' (57 pt bold, at most
  800 wide, "…" past it — clear of the buttons on its line,
  `titleMaxWidth`; the section labels' grey, 45 % — as Apple's; tried: semibold at 75 %, the
  app's primary — much brighter than Apple's; the labels' grey, 55 %; a
  row's size, 29 then 38 pt semibold), the
  description on the left, the page's round
  buttons at the rows' right end on the title's line (`SettingsScrollingPage`). (Tried: titled as a row's
  name, 40 pt, 55 % — it outweighed the categories; the trail over the
  title, "NUVIO › PROFILES"; a category's own page untitled — a title
  at times and not at others; the description alone, on the "ACCOUNTS"
  label's line.) **Descriptions** say what's behind a row: the focused row's, else nothing (the tile alone). A page keeps a line of its own only where it explains the page and its rows have none: options pages, Add-ons, Rating Providers, a count ("3 of 5 profiles"). Nuvio, rows only (as MDBList's): "Nuvio", its row's line
  ("Keeps your profiles, add-ons and watch progress in sync across your
  devices.", signed in or out; tried: "Manage synced data across web,
  mobile, and TV."; "Overview");
  Account (the email; its page: Sign Out with the email on its right,
  confirmed — `NuvioAccountPage`), Profiles (the active one) — all profile
  management lives here, at the Nuvio website's parity: its page
  (`NuvioProfilesPage`, "N of 5 profiles") a row per profile (avatar,
  name, "Primary, Active", chevron) and Add Profile last (the keyboard
  for the name, then its page; gone at 5) — on trial, the guided steps
  instead (`ProfileSetup`, a setup assistant; the same on the gate): one
  question a screen in the gate's look, a dot per step under it, Back a
  step back (from the first, out) — the name (the keyboard at once), an
  avatar (the wizard's look: its heading centred and fixed, no line
  under it; the initials alone first, then the catalog by kind under
  Settings' labels, eight across in the gate's round tiles (132 pt) —
  `SetupAvatars`; the tiles scroll under the heading, fading out above
  the dots; tried: Settings' avatar page in the column — the title off
  centre, too narrow; the catalog eight across in a box of its own — it
  scrolled badly), "Where should
  titles come from?" (Use Primary's Add-ons, focused / Start Empty), "Lock
  this profile?" (Not Now, focused / Set a PIN — twice; signed in only),
  then the avatar large, "You're all set", Start Watching (gate) / Done
  (Settings: the new profile's page). Created at that last press. A profile's page
  (`ProfileSettingsPage`): Switch to This Profile (not the active one; a
  locked one asks its PIN), Name (keyboard), Avatar (its page: Use
  Initials, then the catalog six across under its kinds — Select picks
  and goes back), Colour (options with swatches), PIN (Set; or Change —
  the current one, then the new — and Remove), Collections (the active
  profile only: a collection's page, shown or not, then its folders);
  Shared from Primary: Use Primary's Add-ons (not Primary); Copy Settings
  (`ProfileCopyPage`, the website's `sync_copy_profile_setup`: Copy From,
  TV / Mobile / Desktop settings and API Keys toggles, Replace its keys
  when keys are on, Copy Settings confirmed — syncs first); Delete
  Profile (not Primary, confirmed). No plugins switch (no plugins), no
  picture links as avatars. The top bar's avatar and the launch gate
  (`ProfileGate`) switch and add (Add Profile on the gate: no lockout
  behind locked profiles, and no adding through another profile); the
  gate edits through these pages: holding an avatar opens its page
  over the gate (`.holdMenu(direct:)`); a locked one asks its PIN first,
  and there's no Switch row (picking switches — `fromProfileGate`); Back
  walks up, then the gate, focus on that avatar. Resting 0.5 s on an
  avatar shows "HOLD TO EDIT" under its name (`SectionHint`'s look, its
  room kept; `hintDelay`; tried: 1.5 s — late). (Tried: a hold menu with
  the edit steps on the gate; a gear under the avatars opening the
  Profiles overview — one step more than needed.)
  (Tried: switching from the Profiles page itself; the full-screen
  editor and Add / Edit tiles on the gate.)
  Then Sync: Sync Now, its value the last sync ("Today at
  22:34" / "Syncing…" / "Failed"), and a row per kind synced, its count
  as the value — every one a button with a chevron — Add-ons and
  Watched open their pages (Add-ons: a row per add-on (logo, name, "Off" when off), lit whole,
  Select its page (`AddonPage`: Configure, Rename, Remove — wide rows);
  Edit on the title's line (as Rating Providers') gives each row a round
  on / off (an eye, struck through when off; "Off" left of it
  only at rest — tried: a tick, empty when off — looked odd beside the handle) and the ≡ handle (`SettingsReorderRow`),
  Done or Back ends it (tried: one line each with Configure, Rename, Move,
  a switch, Remove — too many buttons); then Add Add-on, as Add Profile; tried:
  a round + by the heading; then Refresh Add-ons — every manifest fetched
  again past the cache, this device only, nothing pushed to Nuvio; its
  value "Refreshing…", then the last refresh ("Today at 22:34", kept —
  `cue.addons.refreshedAt`) or "2 didn't answer"; the add-ons 16 apart,
  the buttons 29 under them as Apple's Add Language…, `listButtonGap`; tried:
  one gap for all), Collections nothing
  yet, until they get one (tried: those only to read, no fill or focus). (Tried: ACCOUNT / ACTIVE PROFILE / LAST SYNC in outlined
  boxes, round Sync now and Sign out beside them, the counts in tiles, the
  profiles in tiles to read; before that: the website's tiles, rows under
  them, the info tiles pressable — actions hidden behind a label.)
  Watched (`WatchedSettingsPage`): "Watched", "M titles" under it; a
  title to a row, newest first, simply scrolling: a list's tall rows (as
  the add-ons'), a small poster (58 × 87), the name (38 pt medium) over
  what was watched last and when ("S2:E4, 14 Oct 2026"; a film the
  date), a chevron on every row (`WatchedRow`). Select opens the title's
  page (`WatchedTitlePage`): a show "N episodes, S seasons", a section
  per season in the show's order, an episode a tall row ("E3: name",
  when under it — "14 Oct 2026, 23:15"); a film its one row. Edit on the
  title's line, on both pages (on the title's page Select on a row too,
  focus on its button), gives each row a round trash; one press removes
  it (on the list the whole title, a show every episode), no confirming
  — Edit is the safety, and a title is easily marked again; focus to the
  next row's; a title's page left empty closes. Remove All beside Done
  (on the list it also clears Continue Watching, on every device). No
  hold menus, no alerts, no dropdowns. Names, posters, episode names from
  the add-on's meta on disk (only the rest fetched, else TMDB). (Tried:
  no title pages, the rows without chevrons, Select starting Edit —
  episodes couldn't be removed one by one; a minus for the button; Select
  on an episode asking to remove it in an alert; Clear All confirmed;
  "N records · M titles", a round trash Clear all; "Last watched" over
  "S2:E4 on 14 Oct 2026, 23:15"; hold for Remove; Remove in a dropdown;
  episodes as tiles two or three across — looked terrible; posters four
  across with captions — they hid the order. Talked over: Select mode
  with ticks and Remove (N) — not needed, one press removes.)
  Watch Progress (`WatchProgressPage`): every position the account holds
  (a film or episode, what Continue Watching is made from), newest first,
  Watched's rows: a small poster, the name, "S1:E1, 14:43 of 25:00, 14 Oct
  2026", no chevron. Select starts Edit on the row's button; Edit gives each
  a round trash, one press removes it, Remove All beside Done; both reach the
  account (every device). A row for an episode marked watched after it was
  last written is hidden and, on a pull, deleted from the account
  (`remoteKeysWatchedSince`; no time limit; hidden only, the website kept it).
  Library (`LibraryPage`): Home's Saved for Later, all of it, newest first,
  Watched's rows: a small poster, the name, "Added 14 Oct 2026", no chevron.
  Select and Edit as Watch Progress'; Remove All removes one by one
  (`LibraryStore.clearAll` queues no account deletes).
  TMDB (`TMDBServicePage`), its row's line "Search, artwork, cast and details
  for every title." (descriptions short; tried: "Powers search and
  everything Cue shows about a title." — too broad, posters are the
  add-ons'; a list of everything it feeds); then rows, as MDBList's: API Key (its page, below), Language
  (TMDB's; moved from Home & Content — an options page). No attribution
  line on the page (tried: "This product uses the TMDB API…" at its end;
  it stays in the old About's Licenses text). No feature
  switches: a key means on. No cache rows (tried: Clear Cache and Stored
  "9.2 MB of 134.2 MB" — only the URL cache's JSON, TMDB's own disk caches
  survived the clear: it did nothing useful). No request counts:
  TMDB has no quota and reports none (a soft per-second limit only). (Tried: STATUS and API KEY in outlined boxes
  with round buttons beside them — Type key, Send from phone, Remove key;
  no key: the QR on the page itself; Language as a tile under Status,
  `SettingsChoiceTile`, label over value.)
  MDBList (`MDBListServicePage`), its row's line "Ratings from IMDb, Rotten Tomatoes,
  Letterboxd and more."; only wide rows — no round buttons, no outlined
  boxes, no Status (the way the rest of Settings goes, one page at a
  time; what's only to read: Apple's way, a row's text and value with
  no fill or focus). API Key (`ServiceKeyRow`: the key masked, "Not
  added", or "Not working" — checked as the page opens) opens its page
  (`ServiceKeyDetailPage`): with a key, Remove Key with the key on its
  right, confirmed in the system's alert; without, Type Key and Send from
  Phone (the full-screen QR), the how-to under the name — a key saved or
  removed, back. No replacing in place: remove, then add. (Tried: the
  TMDB page's Status and API key boxes, round buttons beside them, the
  QR on the page without a key.) Then Usage, under API Key: a row with the requests ("312 of 1,000"), opening
  its page, to read, from `/user`'s
  body (asked with the key's check as MDBList's page opens; `MDBListUsage`; tried: last on the page, the rows themselves):
  Account (the username), Plan, Requests Today ("312 of 1,000"), Resets
  (local time), Paused ("Until …") only while a 429 holds requests back (moved off
  the Developer page). The Ratings section of wide rows,
  the value on the right: Show
  Ratings (Everywhere / Details Only / Off — Off hides the catalog's IMDb
  score too; `MDBListSettings.place`; its page's description says what
  every option does in running text, as Apple's Keyboard Layout page —
  "Choose where titles show their ratings. Everywhere shows them on …";
  tried: each option's line alone, changing as focus moved — better to
  see them all; a line per option under a blank line — too long, too
  far down); was "Show ratings"); Rating Providers (was Order), showing the first three as their chips (marks, no scores),
  opening its page in the column (`RatingOrderPage`: "The first three
  show on titles; the rest stand in when one is missing." under its
  name; Apple TV's list with Edit, as its Languages: under "PREFERRED ORDER" a row per source, the name only — no on / off (every source in the order; tried: Select turning it on / off); Edit, a capsule on the title's line (`SettingsCapsuleButton`, Apple's: 71 tall, 38 pt text 36 in), makes it Cancel and Done (focus on Done; Select on a row: Edit too, focus on that row) and gives each row its ≡ handle (`SettingsReorderRow`: at rest the whole row lights; in Edit focus is the handle's alone — a round button lighting white, the row as it is (tried: the whole row white, the handle plain lines); Select lifts the row — it lights whole, white, the handle its lines alone, Up / Down move it, Select or Back puts it down); Done keeps the order, Cancel or Back puts it back. No trash. Tried: Move and a switch on every row, `SettingsEntryRow`) —
  the chips on the billboard, Details and About, the same order for
  every title (MAL in it shows only where a title has one: anime); Ratings
  on Rows (1 / 2 / 3, `rowCount`, 1; only while Show Ratings is
  Everywhere; its page says what it does; was "On Home's rows" — "1
  rating"): how many of the same order the fixed box shows
  (`FixedFocusChipsView`). (Tried: the box's
  own rule — a source picked in a dropdown, "MyAnimeList for anime" as a
  tick after the sources; an Anime row — MyAnimeList first / Your order —
  for the chips and the box alike; a Rating priority tile opening its own page; the
  sources as tiles four across and the choices as tiles — looked
  terrible; the sources on the MDBList page itself — with "Shown first" /
  "Fallback" labels, a line after the third, a preview of a film's and an
  anime's chips on placeholder cards; a numbered list, one focus to a
  row, Select lifting it, hold to hide, an Off section — looked horrible.)
  About (`AboutDetail`; was the fork's card — a CUE logo, Diagnostics,
  Clear cache): Privacy and Licenses & Credits, pages in the column
  (running text, focus on `SettingsFocusHolder`), then to read: Version,
  Device, Software, Source Code. No updates line: there are none to
  check. Version: below 1.0 a pre-release, shown "0.9 Pre-release"
  (`MARKETING_VERSION`, was 9 — the Android version it tracked); 1.0
  after the playback rework. Orivio isn't named in the app (GPLv3 and
  the source address are); it stays in the repository.
  Appearance (its row's line "Change how Cue's pages and cards look."; tried: "Colours,
  the focus outline and the top bar."): switches in one list, no section
  labels (an untitled `SettingsSection` draws none) — Background
  (Static / Dynamic, an options page), Card Outlines (Edges and Focus /
  Edges Only / Off, an options page — was High / Low), Auto-Hide Top Bar
  (was Hide the top bar; no line). Each options page says what every
  option does in running text, as Show Ratings' ("Choose what's behind
  the pages. Static keeps …"; tried: Background's line about Dynamic
  alone; Card outlines' "A thin edge around every card, …") (tried:
  Look / Billboard / Navigation sections, long descriptions). Home & Details (was Home &
  Content; the add-ons are Nuvio's, synced — only under Nuvio → Sync):
  its row's line "Choose what Home shows and how titles behave."; one list — Home Rows
  (its value the rows that show, no more), Continue Watching Order (Last
  Watched / In Progress First, an options page in running text; was a
  press switching in place, "Recently watched / Streaming style"), Hide
  Watched Titles (off; Home's catalog rows without watched films and
  shows with every aired episode watched — of the 20 shows Next Up looks
  at, `finishedShows`; Continue Watching, Saved for Later, collections
  untouched; `HomeHideWatched`), Auto-Advance Billboard (moved from
  Appearance: behaviour, not looks; was "Billboard moves on by itself"),
  Trailers (With Sound / Silent / Off, an options page — one row setting
  Nuvio's two synced tvOS prefs, `heroTrailersEnabled` /
  `heroTrailerSound`; was two switches), Hide Spoilers (off; Details'
  episodes not watched or started: the still blurred, `BlurredBackdrop`,
  `FixedFocusCardState.blurred`; titles kept — the row shows no synopsis;
  `DetailHideSpoilers`). Home Rows (`HomeRowsPage`; its row's line "Choose which rows show on Home, their order and their names."), as the add-ons': a
  row each (name, its source, "Off" when hidden), lit whole, Select its
  page (`HomeRowPage`: Rename, Source to read); Edit on the title's line
  gives each the eye and the ≡ handle (tried: Rename, Move and a switch
  on every line). Continue Watching and Saved for Later aren't in the
  list (can't be moved or hidden, for now). No separator dots anywhere in
  Settings: a comma, a colon or a row of its own.
  Continue Watching and Library aren't repeated in Settings, and no row
  sends you elsewhere in the app.
- **App icon and Top Shelf images**: generated, never hand-edited —
  `swift Tools/AppIcon/render.swift` writes them into the asset catalog.
  One play drawn like the note on Apple's Musik icon (grey-white, slightly
  see-through, a sharp dark rim) on Musik's gradient 6° pinker (OKLCH, the
  most chroma P3 holds), all in Display P3. Layers: background / the play's
  shadow / the play (the play lifts off its shadow on focus). Tried and
  dropped: wordmarks ("CUE" with a ring C, the E in a play), a 3D key, two
  plays, other colours (sRGB was too tame).
- **Series status chip**: AIRING / RETURNING / ENDED [year]
  (`FixedFocusShowInfo.status`), on trial shaped as a rating chip
  (`TitleBadge`): the word on an off-white plate, dark (as TMDB's mark),
  the year beside it as a score, the outline off-white (tried: the whole
  text off-white in the outline).
- **Loading**: title record on disk, stale-while-revalidate; launch curtain
  with a time cap; background preload queue; Details built with its data
  (no late updates; the episodes' peek stills decoded too — `peekStills`:
  created just before the rise, the name rose alone, the cards popped in).
  The launch: the system launch screen is the app's background colour
  (`AppBackground` colour set), nothing on it (`LaunchScreen`, from
  render.swift; tvOS ignores `UIColorName`; cached per install in the app's
  `Library/SplashBoard`). tvOS 26 flies the icon's front layer — the play
  — onto it and holds it in the middle until the app's first frame (the
  system's, not ours; ~0.35 s in, mid-zoom — too quick; Settings, slower
  to draw, holds ~1 s). The curtain carries on with the same play
  (`LaunchPlay`, 220 pt in a 640 square — measured: the system's settled
  pixels), still, on `ATVBackground` (the Bands picture fading in under it —
  asked for at launch, a copy on disk per build, `BandsPictureStore`;
  the gate waits for it, 1 s at most; tried: drawn at the curtain's first
  frame — it faded in after the gate's avatars),
  for 0.6 s (`LaunchCurtain.playHold`), then it fades as the gate comes in
  (Motion.fade — the system's hand-off to Settings); without a gate it
  stays until the curtain fades into Home. Coming back to the app (a warm
  start) to the gate (after 4 hours away, or left up): the system's play
  goes at once (the app's frame is ready), so the curtain shows ours from
  the first phase out of the background (`cameBack`), held 0.95 s
  (`resumeHold` — the system's share and ours at a cold start), then the
  gate fades in. Coming back to the page: the page as it was (tried: the
  play over it on a curtain — terrible over Home).
  Input and the top bar's focus timers start at the lift. Tried and dropped: the play growing and
  shrinking while the preload ran, then pushed (`LaunchStageView`); no play
  of ours — the system's went too quick; the pink picture full-screen (too
  bright); the play opening into the app (Home through its growing shape).
  (2026-11-08: the play is gone; the gate comes at the first frame, with no
  hold, for every launch and every return after 4 hours, one profile too —
  a choice, so Add Profile is reachable; the focused unlocked profile is
  picked after 5 s with no press, "Continuing as …" at the tertiary level
  for the last 2 s, any press stopping it (tried: no gate with one profile,
  the status line alone on the curtain — five exact lines read as a
  log). The waiting avatar no longer breathes: the status line under it,
  one line per launch, at random: "Assembling the lineup", "Gathering
  the cast", "Aligning the satellites" (tried: "Seeing what's new" then
  "Getting things ready"; talked over: a cinema set, "Opening the doors"
  etc.; three beats; plain lines as "Getting your Home ready").)
  **Who's watching?** (`ProfileGate`, formerly 2+ profiles or the active
  one locked — `gateNeeded`, gone): the curtain itself, after the held play
  (`LaunchCurtain.gate`, expected before the root decides) — not a
  system cover. The preload runs under it
  for the last profile (focus starts there). Picked: the stores switch at
  once (another profile — `LaunchPreloader.picked`, Home reloads for it,
  `HomeViewModel.profileSwitched`, the same steps again from the pick);
  ready, the avatar flies to the top bar's (`TopBarAvatar.frame`) on the
  present spring as the background dissolves off Home (`gateLanded`);
  not ready, it waits in the middle, breathing as the play. Look: 57 pt
  semibold title (75 %), round avatars 180 pt with the cards' rim, focused
  the bright edge, 5 % larger, a soft shadow; names 24 pt medium at a
  caption's levels, stepping down by the avatar's growth while focused
  (`GateSlot.step`) (tried: each profile a card as Settings' avatar tiles,
  `GateCard` — beside a round Add Profile it looked mixed, Add as a card
  read as a fake profile); last, below 5 profiles, Add Profile — a plus on
  a flat round plate the avatars' size (`GateAddTile`; focused white, dark
  plus); every slot one width (`GateSlot`), so with three the middle one
  sits under the title. Select: Add Profile's guided steps (below), ending in the new
  profile picked (its avatar flies to the top bar); the PIN pad flat (white focus, dots white 75 %, a
  wrong PIN shakes, its line 55 %). Also after 4 hours away
  (`awayForGate`, shown at once as the app comes back; a locked profile
  asks its PIN again), after the welcome, and from the top bar's avatar
  (on the curtain too; Back closes it, focus back on the avatar). At
  launch and coming back Back does nothing.
  Pages whose content loads (`PagePreparer`, `PageLoad`): the data starts
  at the press, the page pushed at once under its background (above), shown
  once it's in or after 4 s at the latest — then with placeholders in
  the exact final layout (rows:
  `FixedFocusRows.placeholderRows` + `placeholder:` — two unnamed rows of
  empty cards, no focus, no outline), the content taking over in one
  0.25 s fade (none while still covered — `PageFade.covering`),
  focus then going in. Placeholder look (`FixedFocusPlaceholder`):
  a soft fill over the page (white 9 % → 7 %, no dark base), no card edge, nothing in it — the
  card alone, as the Apple TV app's (tried: an ellipsis glyph in the
  middle); bars where the text goes only on pages shown whole as
  placeholders (a page still loading after the 4 s, and Search's cards); all breathing in step
  (`FixedFocusPulsing`: opacity 1 ↔ 0.55, 1.2 s each way; still under
  Reduce Motion). The same look for any picture still on its way, everywhere
  (every card, the fixed box, episodes, `RemoteImage`): the card's edge and
  anything drawn on the picture (shade, logo, plate) wait with it, its caption
  stays; the picture in, the placeholder fades off it
  (`FixedFocusPlaceholder.follow`, `FixedFocusImages.load(waiting:)`). No
  picture at all: unchanged (the name / initials, a dark tile). "Ready" includes the first screen's pictures
  decoded into memory (`FixedFocusImages.prefetch`, 0.7 s cap after the
  data) — the page swaps in whole, pictures included. Folders (`PageLoad`) and the browse
  pages (their `TMDBBrowseViewModel`, a `PreparedPage`; the grid's
  `placeholder:` — two lines of empty posters).
- **Search**: SwiftUI `.searchable` (the system's field, keyboard,
  dictation, suggestions), 20 pt lower than the other pages under the
  top bar (it crowded it). Nothing scrolls but the row, sideways.
  Where it comes from: TMDB, not the add-ons' catalogs: its combined
  search (`TMDBService.searchMulti` — films, series and people in one
  list), its film and series searches (`TMDBService.search`, a page each,
  cached by query — also the suggestions'), its person and company
  searches. Titles are playable by their IMDb ids (`external_ids`,
  cached): what the stream add-ons take, wherever a title was found;
  titles without an IMDb id or any picture, people without a photo,
  studios without a logo left out. From the 2nd letter (the 1st only
  suggests). Top Results: exactly 6 (they fit across: no scrolling).
  Movies, Series, People, Studios: literal matches only. **Related**
  (the pill's last scope, shown only when it has titles): what the search
  is about, by its lead (Top Results' first card, in the order on — a
  weak match too): a title — its collection's other parts, then Details'
  More Like This (`TMDBService.detail`); a person — their best-known work
  (`bestKnown`); a studio — its best-known titles (`studioBestKnown`);
  about 20 (`relatedCount`). Fetched with the search (the page swaps in
  whole).
  ORDER: Cue's, not TMDB's as it comes (decided 2026-10-30):
  - `SearchViewModel.ranked`: only names whose start or a
    word's starts with what's typed (`matchForm`: lowercased, no
    accents, punctuation a space — "dune part" finds "Dune: Part Two";
    none match, a typo: all), the best known first — fame plus a bonus:
    the name itself +3, its start +1 (`matchBonus`). A title's fame: log
    votes + log popularity of its own TMDB entry (same name, kind, year);
    a person's: 2 × log popularity + ½ × log of their best-known title's
    votes (Christopher Nolan above the "Nolan" documentaries, a minor
    actor not above his film). Top Results: titles and people together,
    by that score. Studios: the exact name first, else TMDB's order.
    Limit: TMDB matches whole words, so two letters find titles with that
    word ("di" → Italian titles, not Die Hard) until the third.
  - One studio into Top Results when it's what you typed — the
    name itself first, a name or word starting with it (3 letters on)
    second; none while a title or person has that very name ("dune": the
    films, not a studio called Dune). Led by a person or studio, Top
    Results' other 5 places are their Related titles; led by a title, only
    the places the matches leave ("frieren": the show, then what's like
    it). A person's best-known: their
    films and shows they played (voice roles too) or directed, by votes +
    popularity (`TMDBService.bestKnown`, from `personCredits`); a studio's
    films and shows by votes (`studioBestKnown`, discover by company) —
    "zendaya" → Zendaya, Spider-Man…, Dune; "pixar" → Pixar, Inside Out,
    Up, Coco… Fetched before the results show (one more request; the
    page swaps in whole — `SearchFound`, one snapshot per search). (Tried:
    a cut-off for what counts as "top" — within 6 of the best, at least 9;
    the user chose exactly 6.)
  (Tried and dropped: the add-ons' search catalogs — junk entries, the
  slowest add-on deciding the wait.)
  Under the keys the system's suggestions: the
  field empty, the recent searches; with text, TMDB's names
  (`SearchViewModel.suggest` — 120 ms after the last key, older lookups
  dropped, at once from an earlier shorter query's answer filtered on the
  device), lowercased: names whose start or a word's starts with what's
  typed (`matchForm`, `matchBonus`), the best known first. No icons (tvOS draws none on
  them, `UISearchSuggestionItem`'s icon neither) and no quoted "what you
  typed" chip (the controller's private `shouldDisplayDefaultSuggestion`
  switch, off — private API, kept on purpose). Focusing one previews it in the field; Select searches
  (the system then clears the row until the next key). Under them the
  line (`SearchScopeBar`, our own — the system's hidden) with a flat pill
  Top Results | Movies | Series | People | Studios | Related — only those
  with results (Top Results always; while the first load runs, it alone),
  as the Apple TV app's (the field empty:
  the line alone): its shape and sizes measured — a capsule 68 pt tall,
  the items 10 pt inside, 29 pt semibold labels 27 pt from its ends (33 inside the focused capsule),
  the line stopping 40 pt from it — in our dark flat fills (theirs is the
  light variant): `FlatControl.rest` behind with `ActionFace.pillEdge`
  along the top, the current scope `FlatControl.selected`, focused white
  with dark content, the highlight gliding; focused, the pill keeps its
  size (no grow); the current scope at rest 7 pt inside it, the white
  capsule focused nearly filling it (4 pt from its edge, measured), with a shadow below (black 45 %, 12 pt, 8 down) (tried: the top bar's
  glass pill);
  moving along it switches, coming in lands on the current one. The line
  sits at the top of the page the system lays out under the keyboard, so
  it and the row move with it: up 102 pt while no suggestions show (an
  empty field without recent searches, a suggestion just chosen), down
  when they do — at once, as in the Apple TV app (tried: a fixed place
  with the suggestions' room kept — the empty room looked odd). The pill
  sits 40 pt under the suggestions, as far as the cards under it (at
  rest): raised 31 pt above that page's top (`pillRaise` — the system
  starts it 71 pt under them). Partly outside it still takes focus; wholly
  outside, focus never reached it. Under the line ONE row of posters
  (`SearchResultsRow`): Saved for Later's cards (`FixedFocusDestinationCell`,
  moving focus, name and a second line under each — a title's year, a
  person's line of work, "Acting"), one shape for every kind, 2:3: a
  title's poster, a person's portrait, a studio's logo on a light plate
  (most logos are dark on clear); six as wide as the line above them
  (`SearchRowController.rowHeight(width:)`) — one size whether the
  suggestions show or not (without them the page sits higher, more room
  below: accepted, as in the Apple TV app).
  Select: a title its Details, a person or studio its page. (Tried and
  dropped: Top Results as 3 landscape backdrops with their logos, studios
  as landscape plates — every scope its own shape. Collections — later,
  perhaps; networks have no TMDB search.) The field empty: the last 12 titles opened from
  Search (`cue.search.recentTitles`). Both recent lists (searches: the last
  8, `cue.search.recent`) are per profile (`ProfileScopedDefaults`).
  Loading: searching with nothing on show yet (the first search, or
  after none found), 6 placeholder cards (`FixedFocusPlaceholder`, no
  focus) in the row's place, the results taking over in one 0.25 s fade;
  with results on show, they stay until the new ones swap in whole (no
  blink while typing). Each new search's results (`SearchFound.batch` —
  over placeholders or other results, even the same titles) swell once
  and settle (`pulseScale`, 0.35 s, all at once — the Apple TV app's sign
  of new results); switching scopes doesn't. Nothing found: one quiet line ("No results for
  …"), no spinner, no icon.
  Focus stays on the keyboard as results arrive. Only completions in the
  suggestions — a Button among them (a Clear) sent tvOS into an endless
  focus/reload loop that froze Search. (Tried and dropped: the keyboard
  scrolling away with a grid of results — a hidden content scroll view,
  the system's line moved, ancestors unclipped; `UISearchContainerViewController`
  with our UIKit results — on the sim the Mac keyboard stopped typing, on
  the TV the keyboard took the system's language; a Top Result card; our
  own suggestion row; the results as Home's rows; the system's scope bar.)
- **Collections**: one panel row per collection on Home. A folder page is
  Home's rows (`FixedFocusRows`): a catalog per row, all its titles, the
  focused row at Home's spot, the next peeking; the folder's cover
  tile (its own shape, 100 pt tall — the header's height, so the rows keep
  their place), name and subtitle above the first row — the same header
  while loading and over the grid. A one-catalog folder opens the poster grid instead (the
  browse pages' grid, with the folder's cover). Every collection shows this
  way, whatever its Nuvio `viewMode` (the value isn't touched). The old
  two-lines-per-catalog blocks, tabs and "See All" pages are gone.
  The header is the rows' `pageHeader`: it moves up with the first row in
  the rows' own animation. Movies / Series show the collections too, only
  folders with sources of that kind (`CollectionSourceDTO.kind`; unknown
  counts), at Home's place; a folder opened there shows only that type
  (`Route.folder(type:)`).
