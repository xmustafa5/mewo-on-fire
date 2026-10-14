# Console redesign: Apple style, swarm graph, filters, hiding

Date: 2026-10-14
Status: approved in chat, awaiting spec review

## Why

The operations console (`pc/dashboard/index.html`) looks like a sci-fi HUD: monospace capitals, scanlines, corner brackets, glow, a clock, a cat mascot at the core. It is hard to scan and it never gets cleaner: finished sessions stay on screen until the daemon prunes them days later. The user wants a console that reads like a native Mac app, shows sessions as an Obsidian-style graph, can be filtered, and can be tidied by hiding sessions that are done.

## Decisions made with the user

| Topic | Decision |
|---|---|
| Appearance | Follow macOS light/dark (`prefers-color-scheme`). Both themes designed and checked. |
| Style reference | Apple Human Interface Guidelines (skill `ui-design:mobile-ios-design`), applied to a Mac window. |
| Mascot | Removed from the page entirely (core and session card). The app icon keeps it. |
| Graph | An Obsidian-like force-directed swarm replaces the Network view. |
| Filters | Claude's choice: status, project, computer, time range, search. |
| Cleaning up | **Hide in the console only.** Nothing is deleted: not in Claude Code, not in the daemon's session list, not on the phone. `session_forget` is not used. |
| Build approach | Rework the single `index.html` in place. Hand-written physics, no libraries, no build step. |

## Non-goals

- No change to Features or Pipeline behavior or layout; they only get the new look.
- No change to the phone app, the menubar app, or the daemon's session/event storage and retention.
- No auto-hide timer (can come later).
- No new build tooling.

## Constraints

- The page stays one self-contained file with no external assets. The three hosts load it:
  - the Mac app (`pc/console`, WKWebView, `file://`, state pushed through `window.__apply`)
  - the Linux app (`pc/console/linux/mewo-console`, WebKitGTK over `mewo dashboard` on a random port)
  - `mewo dashboard` in a browser (`include_str!`, `/api/*`)
- Keep the host contract: `window.__apply`, `__reply`, `__newSessionResult`, `__preview`, the `'ready'` post, the `/api/*` fallbacks, `window.mewoHost`, working `confirm()`/`alert()`.
- `localStorage` cannot hold console settings: the Linux app gets a new origin every launch. Settings live in the daemon (see "Console settings").
- Every daemon command the page uses must be on both allowlists: `pc/src/dashboard.rs` `forward()` and `pc/console/Sources/DaemonClient.swift` `forward()`.

## 1. Look

**Tokens.** `:root` holds Apple-style tokens for light, with a `@media (prefers-color-scheme: dark)` override. No hex colors in JS: canvas code reads the tokens through `getComputedStyle` and re-reads them on a `matchMedia('(prefers-color-scheme: dark)')` change. This replaces the `const C` hex copy and the hard-coded gradient colors.

| Token | Light | Dark |
|---|---|---|
| `--bg` (window) | `#ffffff` | `#1e1e1e` |
| `--bg-side` (sidebar, translucent) | `rgba(246,246,246,.8)` | `rgba(40,40,40,.75)` |
| `--bg-raised` (cards, popovers) | `#ffffff` | `#2c2c2e` |
| `--fill` (controls) | `rgba(0,0,0,.05)` | `rgba(255,255,255,.08)` |
| `--sep` (hairlines) | `rgba(0,0,0,.1)` | `rgba(255,255,255,.1)` |
| `--text` / `--text-2` / `--text-3` | `#1d1d1f` / `#6e6e73` / `#aeaeb2` | `#f5f5f7` / `#98989d` / `#636366` |
| `--accent` (system blue) | `#007aff` | `#0a84ff` |
| `--working` (orange) | `#ff9500` | `#ff9f0a` |
| `--waiting` (red) | `#ff3b30` | `#ff453a` |
| `--done` (green) | `#34c759` | `#30d158` |
| `--closed` (gray) | `#8e8e93` | `#8e8e93` |
| `--phone` (indigo) | `#5856d6` | `#5e5ce6` |

Radii: `--r-panel: 12px`, `--r-card: 10px`, `--r-control: 7px`, pills fully round. Shadows only on floating things (popovers, sheets, menus).

**Type.** `-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif`. Sentence case everywhere. Monospace only for ids, branches, and paths. Numbers use `font-variant-numeric: tabular-nums`.

**Removed:** scanlines (`body::after`), corner brackets (`.c.tl/.tr/.bl/.br` and their spans), glow shadows, the `#bg` background canvas, the `#boot` splash, the `#mark` reactor, the clock and date, the mascot (`mascotSVG`, `setMascot`, `coreMascot`, `placeCoreMascot`, blink timer, `#core-mascot`, `.mhead`, the mascot CSS).

**Layout.** One window, three columns, no footer:

```
┌ toolbar: [traffic-light gap] Mewo on Fire / <PC> · <n> phone live   [Graph|Features|Pipeline]   [Search ⌘F] [Clean up ▾] [+ New] ┐
├ sidebar 220px ──────┬ center ─────────────────────────────────────────────┬ inspector 300px ─┤
│ Status   (4 rows)    │ time range [1h|Today|7d|All]  active-filter chips   │ Activity  Clear  │
│ Projects (n rows)    │                                                     │  needs-you cards  │
│ Computers + Add a PC │                swarm canvas                         │  feed (grouped    │
│                      │                                                     │  Today/Earlier)   │
│ This Mac: phones,    │                                   [−][+][fit]       │ or Details when   │
│ relay, events today  │                                                     │ a node is picked  │
│ n hidden · Show      │                                                     │                   │
└──────────────────────┴─────────────────────────────────────────────────────┴──────────────────┘
```

- The toolbar uses a segmented control for the tabs, a search field, a "Clean up" menu button, and one accent button ("New session").
- The sidebar replaces the stat tiles and the info rows. "Requests waiting", "Listening" and "Queued from phone" move to the inspector and the computer's details.
- The old footer data (hosts, port, relay, version) and the 24h activity chart move to the computer's details in the inspector. Clicking the PC name in the toolbar selects that computer.
- Narrow windows (< 1100px): the inspector becomes an overlay sheet opened from a toolbar button. Under 800px the sidebar collapses behind a toolbar button.
- Existing modals (`#newsess`, `#addpc`, `#pickprd`, `#dsys`, `#sdetail`, `#preview`, `#bigmap`) keep their logic and get the new look: centered sheets, `--r-panel`, `--bg-raised`, shadow, dimmed backdrop.
- Features (`#fnet`) and Pipeline (`#pipe`, build map SVG) keep their structure and read colors from the tokens.

## 2. The swarm (Graph tab)

Replaces `layout()`, `drawNet()`, `spawnParticles`, and the click bursts. Canvas 2D at `devicePixelRatio`.

**Nodes**

| Kind | Key | Size | Look |
|---|---|---|---|
| Computer | `pc:<pc_id>` (this PC and each peer) | r 12 | `--text-2` fill; label always visible |
| Project | `p:<project>`, shared across PCs | r 6 + 1.2·√(sessions), max 14 | `--text-3` fill |
| Session | `s:<id>` | r 5 | colored by state (below) |
| Feature | `f:<feature id>` (only when some visible session has `feature`) | r 7 | rounded square, `--accent` outline |

| Session state | Look |
|---|---|
| `working` | `--working` fill, soft ring breathing (2s period) |
| `waiting` | `--waiting` fill, pulse ring |
| `idle` (finished) | `--done` fill |
| `ended` (closed) | `--closed` hollow ring |
| any, `queued > 0` | small `--phone` dot at top-right |
| any, has artifacts | small diamond at bottom-right |

**Peers:** all of a peer's sessions are nodes, subject to the filters (today's cap of 8 non-ended peer sessions goes away; filters and hiding replace it).

**Links:** session → project; project → each computer it has sessions on; session → feature; build session → plan session (`plan_session`), only when both nodes are visible.

**Physics** (hand-written, about 300 lines):
- All-pairs repulsion (O(n²) is fine; sessions are capped at 50 per PC), link springs (rest length 60 for session links, 110 for project↔computer), weak gravity to the center, collision by radius.
- A velocity-Verlet step with alpha cooling (alpha 1 → 0.001, decay 0.0228, velocity damping 0.6), like d3-force.
- **Stable between updates:** nodes keep their position across `apply()` calls. A new node starts next to its first linked neighbor with a little jitter. A data change reheats alpha to 0.3, not 1.
- When alpha is below the threshold and nothing animates, the draw loop sleeps. The breathing and pulse rings keep only a light redraw going.
- **Reduced motion:** `prefers-reduced-motion: reduce` runs 300 ticks synchronously and draws once. Rings don't animate.

**Interaction**
- Drag a node: it is pinned while dragging, released on drop, and the graph reheats to 0.3.
- Drag empty space pans. Scroll or trackpad pinch zooms around the pointer (0.3×–3×).
- `−` / `+` / fit buttons. Double-click on empty space fits.
- Hover: the node and its neighbors stay at full opacity, everything else drops to 15%, and the hovered node's links take `--accent`.
- Labels: computers always; projects from zoom 0.6; sessions from zoom 1.1 or when hovered or neighbor-of-hovered. Each label fades in over a 0.2 zoom band.
- Click a session, project, computer or feature: the inspector shows its details (section 5).
  - A project's details have "Filter to this project".
  - A feature's details reuse `renderFeatureDetail`.
- Right-click a session: a small menu with Show window / Open in Claude / Hide.
- Esc clears the selection.

## 3. Filters

One `filters` object drives the graph, the sidebar counts, and the activity feed:

```js
filters = { status: [],        // subset of working|waiting|idle|ended; empty = all
            projects: [],      // project names; empty = all
            pcs: [],           // pc_ids; empty = all
            range: 'all',      // '1h' | 'today' | '7d' | 'all', by session last_ts
            q: '' }            // search text, never saved
```

- **Status, Projects, Computers:** sidebar rows toggle membership; several can be on at once. A selected row has the accent wash.
- **Range:** segmented control above the graph.
- **Search:** toolbar field, ⌘F focuses it. It matches case-insensitively on title, project, branch, `last_text`, and cwd. For feed events it matches project and message.
- **Chips:** every active filter appears as a chip above the graph with ×. "Clear filters" shows when any filter is active.
- **Sidebar counts** show non-hidden sessions that pass range and search, ignoring the status/project/computer filters, so a count never drops to 0 because of its own filter.
- **Feed:** events pass when their project and pc pass the filters, they match the search, they are newer than the range start and `feed_cleared_at`, and their `session_id` is not hidden.
- **Graph:** project, computer and feature nodes with no visible session are dropped, except this PC's computer node.
- **Persistence:** status, projects, pcs and range are saved in console settings (debounced 500 ms). Search is not.
- **Empty state:** when filters leave nothing, the center says "No sessions match these filters" with a "Clear filters" button.

## 4. Hiding (console only)

**Rule.** `hidden` maps a session id to that session's `last_ts` at the moment it was hidden. A session is hidden while `session.last_ts <= hidden[id]`. A new reply, a question, or new work raises `last_ts`, so the session reappears on its own and its entry is dropped on the next save.

**Hide one.** "Hide" in the session's details or its right-click menu. It is offered only for `idle` and `ended` sessions; working or waiting sessions would reappear at once.

**Clean up menu** (toolbar):
- Hide finished sessions: all `idle`.
- Hide closed sessions: all `ended`.
- Hide anything idle for over a day: `idle` or `ended` with `last_ts` older than 24 h.
- Clear activity feed: sets `feed_cleared_at = now`.

Bulk actions affect only sessions that are visible under the current filters, and the menu item shows the count ("Hide finished sessions (2)"). No confirm dialog, because everything can be undone: a 5-second "Hid 2 sessions · Undo" toast appears at the bottom of the window.

**Show hidden.** The sidebar footer says "2 hidden · Show". Turning it on draws hidden sessions faded (35%) in the graph, each with "Unhide" in its details, plus an "Unhide all" link. Hidden peer sessions work the same way; session ids are unique.

**Pruning.** On every save, `hidden` drops ids that no longer exist in the current state, which keeps the file small.

## 5. Inspector (right column)

- **Default, Activity:**
  - Needs-you cards (pending requests, the old `#reqs`) on top.
  - Then the filtered feed grouped by "Today" / "Earlier", newest first, up to 60.
  - Each row: status dot, project, time, two-line message. Clicking a row selects its session in the graph.
  - Header button: "Clear" (same as Clean up → Clear activity feed).
- **Session details** (replaces the floating `#detail` card):
  - Title, project, state pill, branch, model, last activity time, last message.
  - Show window / Open in Claude / "On <peer>" (same rules as `showDetail` today), Hide or Unhide, and the artifacts list (opens `#preview` as today).
- **Project details:** session list with state dots, and "Filter to this project".
- **Computer details:** name, online state, phones live/paired, relay, listening, queued from phone, events today, hosts, port, version, the 24h activity chart (`drawChart`, restyled). Peers also get "Remove PC" (existing `peer_remove` flow).
- **Feature details:** `renderFeatureDetail`.
- A back chevron and Esc return to Activity.

## 6. Console settings (daemon)

New module `pc/src/console_prefs.rs`. File: `~/.local/state/mewo-on-fire/console.json` (`paths::console_file()`), mode 0600, written with `paths::write_atomic`.

```json
{ "v": 1,
  "hidden": { "<session id>": 1760450000000 },
  "feed_cleared_at": 0,
  "filters": { "status": [], "projects": [], "pcs": [], "range": "all" } }
```

Control commands (in `control.rs`, next to `session_forget`):

| Command | Request | Reply |
|---|---|---|
| `console_get` | `{cmd}` | `{ok:true, prefs:{…}}`; defaults when the file is missing or unreadable |
| `console_set` | `{cmd, prefs:{…}}` | `{ok:true}`, or `{ok:false, error}` when `prefs` is not an object or serializes over 256 KB |

- `console_set` replaces the whole document. The page is the only writer, and the last write wins when two consoles are open.
- The daemon stores the object as given: no schema enforcement beyond "object" and the size cap. The page treats unknown or missing fields as defaults.
- Both allowlists gain `console_get` and `console_set`.
- These commands run on this daemon only (no `pc_id` routing to peers).

The page loads settings once after the first state arrives (`daemon({cmd:'console_get'})`) and saves through a debounced `console_set`. If the daemon is an older build without these commands (`ok:false`), the page keeps settings in memory for this run and works otherwise.

## 7. Host changes

**Mac app** (`pc/console/Sources/main.swift`):
- Remove `NSApp.appearance = darkAqua` so the app follows the system.
- `window.backgroundColor` becomes a dynamic `NSColor(name:dynamicProvider:)` matching `--bg` in each mode.
- Style mask adds `.fullSizeContentView`, with `titleVisibility = .hidden`, so the page's toolbar sits beside the traffic lights.
- A user script sets `window.mewoHost = 'mac'`, and the page pads the toolbar 78px on the left for the traffic lights.
- **Window dragging:**
  - A `WKWebView` subclass overrides `mouseDown`. When the click lands inside the toolbar rect and outside every control rect, it calls `window.performDrag(with:)` and double-click zooms the window; otherwise it calls `super`.
  - The page posts `{cmd:'drag_regions', toolbar:[x,y,w,h], controls:[[…],…]}` on load and on resize.
- `install.sh` is unchanged; it already copies `index.html`.

**Linux app:** no code change. It loads over HTTP and gets the plain toolbar without the traffic-light gap. Dark mode follows `prefers-color-scheme` where WebKitGTK maps the GTK dark preference to it (recent versions do); otherwise it shows light.

**`mewo dashboard`:** allowlist only; the page is re-embedded by the rebuild.

## 8. Page structure after the change

The file keeps its shape (CSS, then body, then one IIFE), with the JS split into labelled sections so each part has one job:

| Section | Responsibility |
|---|---|
| `tokens` | read CSS tokens into a `T` object; refresh on scheme change |
| `prefs` | load/save console settings; `isHidden(s)`, `hide(ids)`, `unhide(ids)`, prune |
| `filters` | the `filters` object, `passes(session)`, `passesEvent(ev)`, chips, sidebar counts |
| `graph-model` | build nodes and links from `model` and the filters; keep positions across updates |
| `graph-sim` | physics: `tick()`, `reheat(a)`, pin/unpin |
| `graph-view` | canvas draw, zoom/pan, hover, hit-test, labels |
| `inspector` | Activity feed and the four details views |
| `toolbar` / `sidebar` | tabs, search, Clean up menu, toast, sidebar rows |
| existing | Features, Pipeline, modals, preview, notes, host bridge (restyled, logic kept) |

## 9. Testing

- **Rust unit tests** in `console_prefs.rs`, against a temp dir path:
  - Round trip.
  - Defaults when the file is missing or corrupt.
  - Rejects non-objects.
  - Rejects anything over 256 KB.
- **`cargo build --release`** and `cargo test`.
- **Browser check:** `mewo dashboard` in the built-in browser against the real daemon, in light and dark (`resize_window colorScheme`):
  - No mascot anywhere. The swarm settles, and drag, zoom, hover and fit all work.
  - Each filter changes the graph, counts and feed, and the chips clear.
  - Hiding one session, "Hide finished", and Undo work. "Show hidden" and "Unhide all" work.
  - Hidden state survives a reload (from the daemon file).
  - Narrow widths of 1000px and 760px work.
  - Features, Pipeline, New session and Add a PC still open and work.
  - No console errors.
- **Mac app:** run `pc/console/install.sh` and open the app in light and dark mode:
  - The toolbar sits beside the traffic lights and dragging the window from the toolbar works.
  - Buttons in the toolbar still click.
  - Settings persist across a relaunch.
- **Regression:** `session_forget` stays unused by the page. `sessions.json` and `events.json` are unchanged after hiding: compare their mtimes before and after.

## Risks

- **Window dragging over WKWebView** is the least certain part. Fallback: drop `.fullSizeContentView` and keep a plain transparent 28px title strip above the page toolbar, in the same color.
- **Size of the change:** about 2,100 lines in one file, much of it rewritten. Mitigation: the work goes in ordered phases (tokens and chrome → swarm → filters → hiding and settings → inspector → host changes), and the page must work after each phase.
