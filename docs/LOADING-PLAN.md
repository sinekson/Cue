# Loading, caching and preloading — plan

Agreed 2026-10-08. Built: §2 title record, §4 launch steps ①–③ (`LaunchPreloader`), §4 ⑤/⑥ background queue (`TitlePreloader`, end of CueApp.swift). §5 transitions: data at the press (`DetailPreparer`). Goal: everything feels smooth — Details
opens complete, nothing lands during or after a transition.

## 1. What one series costs today (measured from code, caches, the sim's HTTP cache)

| Request | Size (raw JSON) | Cached today |
|---|---|---|
| Add-on meta (full meta + episode list) | ~10–40 KB, long series ~190 KB | 30 min disk, 10 min HTTP; up to 4 add-ons in series |
| TMDB id lookup | < 1 KB | 90 days disk |
| TMDB details (credits, recommendations, similar, videos, ratings) | ~44 KB (~10 KB gz) | HTTP only (~5 h) — and mostly MISSED |
| TMDB season extras | est. 20–80 KB per season | memory only; Details fetches EVERY season |
| MDBList ratings | ~2 KB | 24 h disk |
| TMDB "facts" (billboard) | ~20 KB | 24 h disk — overlaps the details request |
| Episode cast | ~5 KB each | memory only |
| Images: backdrop (original) 0.4–1.4 MB, logo 20–60 KB, stills 50–150 KB, posters 30–70 KB | | image cache (~520 MB budget) |

Problems found:
- TMDB query parameters come from a Dictionary (order changes per launch) →
  the same request has a different URL → the HTTP cache misses (seen: one
  `/tv/<id>` stored twice). Fix: sort the parameters.
- No disk cache for TMDB details; season extras memory-only and all seasons
  fetched serially; facts and details fetched separately; add-ons asked one
  after another; meta kept only 30 min.

## 2. The title record (stale-while-revalidate)

One record per title on disk (memory copy of the last ~50): meta + episodes,
TMDB details (incl. facts), season extras, ratings — each part with its own
timestamp. Never wait for the network if anything is on disk: show it, refresh
in the background if stale, update the screen only if something changed, in
one step. One shared request per question (billboard and Details asking at
once share it). Sorted request parameters. Only the season shown (+ the next).

| Data | Fresh for | Keep for |
|---|---|---|
| Episode list + meta | by air date (below); returning 1 day; ended / movie 7 days | 30 days |
| TMDB details | 3 days (ended 7) | 30 days |
| Season extras | past seasons 30 days; current 12 h | 60 days |
| TMDB id mapping | 90 days | 90 days |
| Ratings (MDBList) | 1 day — fetched in BATCHES (check the batch size and how batches count against the daily limit) | 14 days |
| Episode cast | 30 days | 60 days |
| Images | until space runs out (TMDB image URLs never change) | |
| Blurred backdrops, colour layouts, tints | permanent (derived; written to disk, not re-made per launch) | |

AIRING shows — refresh by the episode list's air dates, not a timer:
1. before the next episode's air date: no requests;
2. from the air date: every ~1 h until it appears, up to ~1 day, then daily;
3. airing with no future date known: every 12 h;
4. opening Details of an airing show: cached at once + a background check if
   the list is older than ~30 min; on launch / return: the same quick check
   for airing shows in Continue Watching and the Library.

Size: data ~100–300 KB per series → cap ~150 MB, least-recently-opened out.

## 3. Memory vs disk

Disk is fast enough for DATA at click time (read ~1 ms, decode ~2–20 ms off
the main thread). Big pictures are not — a 4K backdrop decode is ~30–60 ms
(2–4 frames) and 33 MB: decode BEFORE it's needed.

- Memory (decoded): billboard current ± 1 backdrops, all billboard logos,
  visible posters/stills ± a few, colour layouts/tints near focus, the last
  ~50 title records, the Details about to open (backdrop, first stills).
- Disk: all title records, all downloaded images, blurred copies, colour
  layouts.
- Decoded backdrops kept: A15 4–6, 4K gen 1 2–3, HD 1–2 at a smaller size
  (`PerformanceProfile`).

## 4. Launch steps (cold start)

Progress ring (later: the real animation, maybe sound) shows while ⓪–③ run;
Home appears when ③ is done or at the 2.5 s cap. ④–⑥ never block. Every step
reports count + time to debug numbers (Developer setting).

- ⓪ < 50 ms: profile, settings, add-on list from disk; the ring. (Profile
  picker / PIN: shown instead; ①–③ run after the pick, behind a short ring.)
- ① < 150 ms, disk only: last Home catalogs, Continue Watching / progress /
  library, last billboard picks, title records for the billboard titles,
  Continue Watching and the first ~10 cards of the first two rows.
- ② < 1.2 s, decodes (2–3 in parallel, off main): current billboard backdrop
  + logo + colour layout/tint → billboard titles 2–3 backdrops, all logos →
  first two rows' posters at card size → the billboard title's first 3–4
  episode stills / More Like This posters → blurred copies and colour layouts
  from disk. Not on disk: skipped (→ ④).
- ③ < 200 ms, in parallel: one-time setup — CIContext, card-edge art, shade
  renderings, the dots' glass, first text styles; Movies / Series built hidden.
- ④ background, starts at ①: account sync (as today), fresh catalogs and
  billboard picks (replace quietly, one step), stale title records, one
  MDBList batch, images ② skipped.
- ⑤ during use, a queue: around focus first (billboard ± 2, row ± 3, the next
  row), then rows top to bottom, then hidden tabs; 2–4 at a time; paused while
  scrolling / animating; decoded near focus only, downloaded further out; a
  per-launch request cap.
- ⑥ on demand: rest ~0.5 s on a title → front of the queue; press → whatever
  is missing at once.

Warm start (back from the background): no ring; ④'s airing check + sync only.

## 5. Then: the Home → Details transitions

Entry points: billboard swap; window zoom from Search's small billboard,
Saved for Later posters, the catalog box, Continue Watching's hold menu.
Today Details only exists from 0.45 s of the 0.5 s transition, builds there,
fetches in a chain, holds everything until the end and then publishes it piece
by piece (8–15 full-page redraws, row reloads) — the hitches at the end.

With the title record + preloading: Details' data is ready at the press.
Then: one update instead of many (seasons in one batch, rows updated in
place), and build Details DURING the transition (pushed at the press, hidden
under the overlay). Measure each path on the TV (Release) first.

Open for later: the launch animation itself, sound, the cap and decode
targets (from measurements).

## Built: the background queue (`TitlePreloader`, 2026-10-08)

Home's rows engine reports every focus move. After 0.35 s of still focus the
queue is planned again from there: the title + its neighbours (decoded:
backdrop at stage size, logo, colours), ±2–4 along the row and the next row's
first 4, then every row's first 6 (records: meta, TMDB details, backdrop +
logo to disk). 0.5 s rest on a title → full: + blurred backdrop, season
extras (first 10 seasons), Play's episode's stills to disk. 3 at a time; each
title once per depth per launch; 250 titles from the network per launch (120
on low-power boxes); nothing while the player is up; one MDBList batch per
set of rows. Log: LAN log, "preload". Not done: hidden tabs, pausing during
the billboard's own swap animation (the settle covers presses).

## Built: Details built with its data (`DetailPreparer`, 2026-10-08)

Measured first (sim, Debug, billboard → Details): push at ~470 ms, the build
~85 ms at 0.45–0.55 s (the swap's motion is nearly over there), then
NOTHING until ~1.5 s — the page held its data (`settleUntil`) and published
16 changes at once + 3 more redraws, ~85 ms of row updates and new cells
after the page had settled.

Now: on the press (billboard and card window) `DetailPreparer` reads what the
page needs — episode list, every season's extras, TMDB details, ratings, the
collection — from memory / disk (ready in ~15–30 ms when the background queue
has been there). `DetailView.init` seeds the view model with it, so the page
is BUILT complete; the load still runs (background refresh) but only
publishes real changes. Measured: no view-model change after the build. The
`DetailOpenProbe` logs each press (LAN log, "details").

Not done: pushing Details at the press, hidden (build during the transition)
— the build would then land at the START of the swap, where everything moves;
at 0.45 s it lands where almost nothing does. Check on the TV (Release)
whether the handover drops a frame before changing it.

## Built: into Details through black, from everywhere (`DetailTransition`, 2026-10-08)

User: no placeholders; Details only animates in once everything is loaded;
one consistent, simple transition from every entry point (the billboard
swap had the same problems: "Season X" late, a different logo late).

Press → black curtain over everything (0.3 s ease-in-out) → `DetailPreparer`
gets the record, TMDB details, ratings, season count / status, tagline, the
first row's name, and decodes the logo, picture, blurred picture and colours
→ Details pushed under the black (no slide) and drawn → black fades out
(0.5 s ease-out). At least 0.12 s of black; a ring after 1.5 s; after 8 s it
shows what it has. Back: to black (0.22 s), pop, fade in (0.4 s). Input: Home
holds still (`handingOver`); a Select / Back / Down pressed in the black goes
to Details. Measured (sim): ready 8–9 ms after the press, revealed ~590–620 ms.
Replaces the billboard's in-place swap and the card window morph
(`TitleMorphOverlay` — now unused). Timings: `DetailTransition` statics.

**Revised the same day (user: "smooth, but really ugly"): picture first, then
the text.** The press: the page steps back (dims 85 %, scale 0.97, 0.35 s).
Details' picture (decoded — usually at once) fades in full screen at Details'
exact place with its shade, settling 1.04 → 1 (0.6 s). Under the still
picture the rest loads and Details is built; then its text and buttons rise
in (24 pt, 0.4 s) while the overlay hands over to Details' own picture.
Back: text drops (0.16 s), the picture fades and grows a touch, the page
below steps forward (0.5 s). Billboard auto-paging pauses while Details is
up (`DetailsOpen`). Measured (sim): picture at ~15 ms, text in at ~0.95 s.

**Core Animation version (2026-10-08, later).** All moves are CA layer
animations on a UIKit overlay on the window (`DetailTransitionOverlay`);
strict phases (move 1 → still: push + build until 4 on-time frames → move 2),
each phase continuing only on CA's completion; per-phase main-thread hitches
logged (`FrameWatch`, LAN log "details": "frames move 1: … late …"). Home only
dims (scaling it fought the picture's zoom: "in, out, in"); the picture starts
at Home's framing (the billboard's current slow-zoom scale) and zooms once to
Details' (`ModeSwap.depthScale`). Details keeps the picture Home showed
(`DetailViewModel.shownPicture`; the meta add-on's record often has another).
Render Lab → Details transition: "zoom" (default — a card opens into the
picture: window frame + corners to the screen, the picture from where the
card draws it, the card's snapshot fading in the first third; Back closes
into the card) or "fade". The billboard always uses the fade + zoom-in.

**Info block (2026-10-09):** tried a cascade (parts one after another) and a
left-to-right wipe — too much. Now a plain fade in place, no movement (Back:
a plain fade out). Dev: `-transitionSlowMo` (every move 4× longer),
`-detailsHold` (the cover held 3 s before the reveal).

**The zoom is the loading time (2026-10-09).** Fade: Details is built while
the picture zooms in (0.7 s, ease in-out (0.35, 0, 0.25, 1)); everything but
the picture — a snapshot of Details' rows layer: info block, buttons, its
rows' name — fades in over the last 0.35 s of the zoom and lands with it,
then the overlay goes (the page underneath is the same). A little late: a
shorter fade (≥ 0.15 s), still ending with the zoom; later still: the picture
lands alone, the rest when ready. Tried and dropped: a fixed pause after the
zoom (too slow), a linear zoom (too abrupt), the info block with the picture
from the start, the whole page as one snapshot.

**From the billboard, in place (2026-10-09).** `DetailTransition.openInPlace`
— the fade's two moves, using what's there. Move 1: the cover (the
billboard's own picture, framing and shade — identical) fades in over Home
(0.2 s) with a live copy of the billboard's text above it (no reason line):
only what Home alone has goes (the reason line, its rows' name, the dots, the
top bar); then the zoom, the text still. Details is built under it from the
press. Move 2, at `revealAt` of the zoom: the overlay hands over to Details —
the buttons and Season X come in. ~0.93 s on the sim. Needed for it: ONE shade
for Home's billboard, Details and the cover (`StageArt.shade(for:)`) and
Details keeping the logo Home showed (`shownLogo` — the record's ghosted).
(First try: Home zoomed itself, then a held snapshot while Details was built
— a visible hold; dropped.)
