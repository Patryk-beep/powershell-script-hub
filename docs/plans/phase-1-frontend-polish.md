# Phase 1 — Finish-the-job polish (target v1.5.x point release)

> **Frontend-only.** Every change in this phase lives under `wwwroot/`, which `Hub.exe`
> serves directly from disk. **No `Hub.exe` rebuild is required for any step here** — edit
> the file, hard-refresh the browser (Ctrl+Shift+R), done. This is the deciding constraint
> for several design choices below (see *Backend vs frontend split*).

## Goal

Close out the three "finish-the-job" gaps that were explicitly deferred, all without touching
the compiled binary:

1. **Canvas Phase F polish** — minimap overview, one-level undo (Ctrl+Z), auto-fit on open,
   grid-snap toggle (replacing the always-on 8px snap).
2. **Run-finished notifications** — an OS toast via the Notification API (permission requested
   gracefully, on a user gesture), fired when a run finishes while the tab/window is unfocused,
   plus a `document.title` ("title-bar") progress indicator.
3. **Pin/favorites + recents** — pin scripts to the top of the catalog and show a recents row,
   complementing the existing Ctrl+K palette. Persisted **client-side in localStorage**.

## Dependencies / prerequisites

- None on the backend. All endpoints consumed already exist and are served by the **running
  v1.5.0.0 binary** (Phase 0 shipped 2026-05-30): `/api/items`, `/api/items/:id/schema`,
  `/api/stream/:jobId` (SSE), `/api/run`. No new routes.
- **Hard constraint that shapes the design (keystone logic — read carefully):** `Hub.exe`'s
  embedded `Invoke-Route` bakes its **route table into the binary**; any route not in that table
  returns **503**, and adding one requires a *rebuild + release*. This mechanism is unchanged by
  Phase 0. What Phase 0 changed is only the example: the *workflow* routes (`/api/workflows/**`)
  now ship in v1.5.0.0, so the old "v1.4.13.0 503s any new route" framing is stale. But **a
  pins/recents route was never built** — so it would still 503 on today's binary, and wiring one
  would force a rebuild, violating "frontend-only / no rebuild." Therefore localStorage is not
  merely the *lighter* option for pins/recents — it is the **only** frontend-only option.
  Trade-off: pins/recents are **per-browser-profile**, not synced across machines, and cleared
  if the user wipes site data. Accepted — matches the existing `hiddenIds` precedent.
- **If any step below is tempted to add a backend route** (e.g. server-synced pins, a
  notification-prefs endpoint): STOP. That would require a `build-hub.ps1` + `build-release.ps1`
  rebuild and a new release tag — out of scope for this frontend-only phase. Prefer localStorage.
- Existing precedents this phase reuses verbatim:
  - `app.js` `restorePrefs()` — localStorage load + `this.$watch(...)` persistence pattern
    (used today for `hiddenIds`, `kindFilter`, `sortBy`, `autoScroll`, `showHidden`).
  - `item.id` is already assumed **stable across sessions** by the `hiddenIds` feature — pins
    and recents lean on the same assumption.
  - `canvasEditorMixin()` (in `canvas-editor.js`) is spread into `hubApp()` — new mixins follow
    the same "object spread + `<script defer>`" pattern.

## Files touched (existing + new, absolute repo paths)

**New files** (keeps each new unit < 500 lines and matches the established mixin pattern):

- `C:\Users\Harrold\Documents\Claude Projects\Hub\wwwroot\canvas-polish.js`
  — `canvasPolishMixin()`: minimap, undo snapshot/restore, snap toggle, auto-fit helper.
  Rationale: `canvas-editor.js` is **497 lines**; adding ~60–90 LOC there would break the
  500-line rule. New mixin spread alongside `canvasEditorMixin()`.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\wwwroot\hub-notify.js`
  — `hubNotifyMixin()`: Notification permission, toast firing, `document.title` progress,
  focus/visibility tracking, pins + recents state and helpers.

**Edited files:**

- `C:\Users\Harrold\Documents\Claude Projects\Hub\wwwroot\index.html`
  — add two `<script defer>` tags; add minimap SVG + snap-toggle/undo buttons to the canvas
  toolbar; add pin button to catalog cards + a recents/pinned row above the grid.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\wwwroot\app.js`
  — spread the two new mixins into `hubApp()`; call new init hooks from `init()`; emit undo
  snapshots at canvas operation boundaries; fire notifications + title updates from
  `openStream()`'s `end`/error handlers; record recents in `selectItem()`; resort catalog by
  pinned-first; request permission inside `submit()`.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\wwwroot\canvas-editor.js`
  — minimal hooks: snapshot-before-mutate calls in `cnAddNode`/`cnRemoveNode`/`cnAddEdge`/
    `cnRemoveEdge` and at move-start; make the `snap()` calls honor `cnSnapEnabled`; auto-fit
    on the auto-layout path in `cnOpenWorkflow`; Ctrl+Z handling in `cnKeyDown`.
  - **Line-count decision (explicit):** `canvas-editor.js` is **exactly 497 lines**. The hooks
    above (~5 `cnSnapshot()` call sites + the Ctrl+Z branch + a `$nextTick` wrap) add roughly
    8–15 lines, which pushes it **past 500**. The `<500` rule in the CLAUDE.md project guidance
    is enforced on **new files** (`canvas-polish.js`, `hub-notify.js` must each stay under 500);
    `app.js` already sits at 845, so the limit is understood as "don't grow large files with new
    *logic*." These are call-site hooks, not logic. **Resolution:** accept `canvas-editor.js`
    crossing ~505–510; do NOT relocate canvas internals to satisfy the line count. If a reviewer
    objects, the cheapest net-zero move is making `cnSnap(v)` a one-liner and inlining the Ctrl+Z
    guard — but that is optional, not required by this plan.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\wwwroot\style.css`
  — minimap container/rects, snap-toggle active state, pin button + pinned/recents row,
    toast-disabled fallback styling. All motion gated behind `prefers-reduced-motion`.

## Implementation steps (numbered; each: what / where / how-to-verify)

### Group A — Canvas Phase F polish

**A1. Wire up the new mixins**
- *What:* Spread `canvasPolishMixin()` and `hubNotifyMixin()` into the returned object of
  `hubApp()`, next to the existing `...canvasEditorMixin()`. Add `<script src="canvas-polish.js"
  defer></script>` and `<script src="hub-notify.js" defer></script>` to `index.html` **before**
  `app.js` (so the functions are defined when `hubApp()` runs — same ordering as
  `canvas-editor.js` today, line 11). Call the new init helpers from `init()`:
  `this.restorePins()` and `this.restoreNotifyPrefs()` (after `restorePrefs()`).
- *Where:* `app.js` (top of `hubApp()` return + `init()`); `index.html` `<head>`.
- *Verify:* `console.log(typeof hubApp().cnUndo)` is `"function"`; no "X is not defined" in console.

**A2. Grid-snap toggle**
- *What:* Add `cnSnapEnabled: true` to the polish mixin. Replace the three hard-coded
  `snap(..., 8)` / `snap(node.x, 8)` calls in `canvas-editor.js` (`cnAddNode` lines ~181–182,
  `cnWrapPointerUp` line ~374) with a helper `cnSnap(v)` that returns `this.cnSnapEnabled ?
  snap(v, 8) : Math.round(v)`. Add a toolbar toggle button in the `cn-header`
  (`index.html` ~line 557) bound to `@click="cnSnapEnabled = !cnSnapEnabled"` with
  `:class="{ 'is-active': cnSnapEnabled }"` and `:aria-pressed="cnSnapEnabled"`. Persist the
  preference via `this.$watch('cnSnapEnabled', ...)` to localStorage key `hub.cnSnapEnabled`.
- *Where:* `canvas-editor.js`, `canvas-polish.js`, `index.html`, `style.css`.
- *Verify:* Toggle off → drag a node → it lands at the exact drop pixel (no 8px jump). Toggle on
  → next drag snaps. Reload page → toggle state persists.

**A3. One-level undo (Ctrl+Z)**
- *What:* Single previous snapshot (NOT a stack). Add `cnUndoSnapshot: null` and
  `cnSnapshot()` / `cnUndo()` to the polish mixin. `cnSnapshot()` deep-clones
  `{ nodes: cnNodes, edges: cnEdges, nextN: cnNextN }` via
  `JSON.parse(JSON.stringify(...))` and stores it. `cnUndo()` restores that snapshot
  (reassigning `this.cnNodes`/`this.cnEdges`/`this.cnNextN` to **new arrays** so Alpine
  reactivity fires), clears selection, then nulls the snapshot (one level only).
  Call `cnSnapshot()` at **operation boundaries** in `canvas-editor.js`:
  `cnAddNode` (before push), `cnRemoveNode` (top), `cnAddEdge` (before push), `cnRemoveEdge`
  (top), and **move-start** — in `cnWrapPointerDown`'s node-move branch (~line 318), once per
  drag, NOT per `pointermove`. Skip pan/zoom/selection (non-destructive). In `cnKeyDown`
  (`canvas-editor.js` ~line 411) add: if `(e.ctrlKey||e.metaKey) && e.key.toLowerCase()==='z'`
  and not in a field → `e.preventDefault(); this.cnUndo();`. **Reuse the exact INPUT/TEXTAREA/
  SELECT guard already present in `cnKeyDown`.**
- *Where:* `canvas-polish.js`, `canvas-editor.js`.
- *Verify:* Add node → Ctrl+Z removes it. Move node → Ctrl+Z returns it to start position.
  Delete edge → Ctrl+Z restores it. Second consecutive Ctrl+Z does nothing (one level).
  Ctrl+Z while focused in a param input does NOT undo the canvas.

**A4. Auto-fit on open (respecting saved viewport)**
- *What:* `cnFitScreen()` already exists and computes correct bounds but is only called by the
  toolbar button. **Genuine conflict:** `cnOpenWorkflow` restores a saved `viewport` from canvas
  JSON; blindly auto-fitting would *discard the user's saved pan/zoom*. Resolution: auto-fit
  **only on the auto-layout-from-`steps[]` branch** (the `else` block in `cnOpenWorkflow`,
  ~lines 127–161, where no `canvas.viewport` exists), and also in `cnOpenNew()` (harmless — no
  nodes yet, `cnFitScreen` early-returns). Respect the saved viewport when `wf.canvas.viewport`
  is present. Because `cnFitScreen()` reads `getBoundingClientRect()`, it must run **after the
  canvas DOM renders** — wrap as `this.$nextTick(() => this.cnFitScreen())`.
- *Where:* `canvas-editor.js` (`cnOpenWorkflow` auto-layout branch + `cnOpenNew`).
- *Verify:* Open a legacy workflow that has `steps[]` but no `canvas` → nodes are centered and
  fit on screen. Open a canvas-native workflow with a saved viewport → its saved pan/zoom is
  preserved (NOT overridden). The manual "Fit to screen" button still works in both cases.

**A5. Minimap (scaled overview, corner)**
- *What:* Add a render-only `<svg class="cn-minimap">` absolutely positioned in a corner of
  `.cn-canvas-wrap` (`index.html`, inside the wrap ~after line 678, `x-show="cnNodes.length"`).
  Add a computed `cnMinimap` getter in the polish mixin that reuses the bounds math from
  `cnFitScreen` (minX/maxX/minY/maxY across nodes) to produce: (a) a `viewBox` covering the
  content bounds with padding, (b) a small rect per node (`x/y/NODE_W/NODE_H`), and (c) a
  **viewport rectangle** showing the currently-visible canvas region, derived from the wrap's
  client size and the current `cnPanX/cnPanY/cnScale` (visible canvas rect =
  `(-panX/scale, -panY/scale)` with size `(clientW/scale, clientH/scale)`). v1 is **display-only
  — no click-to-pan.** No transitions on the rects (reduced-motion friendly by construction).
- *Where:* `canvas-polish.js` (`get cnMinimap()`), `index.html`, `style.css`.
- *Verify:* With several nodes, the minimap shows all node rects in correct relative positions;
  panning/zooming the main canvas moves/resizes the viewport rectangle live; minimap hidden when
  canvas empty.

### Group B — Run-finished notifications + title-bar progress

**B1. Focus / visibility tracking**
- *What:* In `hubNotifyMixin()` add `windowFocused: true`. In its init helper bind
  `window.addEventListener('focus'/'blur', ...)` and
  `document.addEventListener('visibilitychange', ...)` to keep `windowFocused` in sync
  (`document.visibilityState === 'visible' && document.hasFocus()`). On regaining focus, reset
  the title (see B4).
- *Where:* `hub-notify.js`, called from `init()`.
- *Verify:* `console.log` in the handlers; switching tabs/windows flips the flag.

**B2. Permission request on a user gesture**
- *What:* Add `notifyEnabled` (localStorage `hub.notifyEnabled`, default unset) and a
  `requestNotifyPermission()` helper. **Never request on page load** (browsers penalize
  load-time prompts). Request inside `submit()` (`app.js` ~line 747) — the run-button click is a
  legitimate user gesture: if `notifyEnabled !== false` and
  `Notification.permission === 'default'`, call `Notification.requestPermission()` once and store
  the result. Feature-detect `'Notification' in window` first; degrade silently if absent or
  denied. Optionally expose a settings toggle later (out of scope; the gesture path is enough).
- *Where:* `hub-notify.js`, `app.js` (`submit()`).
- *Verify:* First run triggers the browser permission prompt exactly once; granting it persists;
  denying it never re-prompts and never errors.

**B3. Fire the toast on run finish (unfocused only)**
- *What:* Add `notifyRunDone(name, status, exitCode)` to the mixin. In `openStream()`'s `end`
  listener (`app.js` ~line 787) and its `onerror` branch, after setting `ended`/`endStatus`,
  call `this.notifyRunDone(this.selected?.name, this.endStatus, this.exitCode)`. The helper
  no-ops if `this.windowFocused` is true (user is already watching), if permission isn't granted,
  or if `notifyEnabled === false`. **Security:** the toast body contains **only the script name +
  status/exit code** — never arguments, never output lines. Title e.g. `"Hub — Run finished"`,
  body e.g. `"<name> exited 0"` / `"<name> failed (exit 1)"`.
- *Where:* `hub-notify.js`, `app.js` (`openStream`).
- *Verify:* Start a run, switch to another window before it ends → OS toast appears with name +
  status, no args/output. Stay focused → no toast (only the in-page UI updates).

**B4. Title-bar progress indicator**
- *What:* "Title-bar" = `document.title`. Add `setTitleProgress(state)`:
  `running` → `"● Running… — Hub"`, `done` → `"✓ Done — Hub"`, `failed` → `"✗ Failed — Hub"`,
  `idle` → `"Hub"`. Call `running` at the start of `submit()` (after a successful `/api/run`),
  and `done`/`failed` from `openStream`'s `end` handler based on `endStatus`/`exitCode`. **Reset
  to `idle` ("Hub") when the window regains focus** (B1 handler) so a stale ✓/✗ doesn't linger.
- *Where:* `hub-notify.js`, `app.js` (`submit`, `openStream`, focus handler).
- *Verify:* While a run is in progress and the tab is backgrounded, the tab/title shows
  "● Running…"; on completion it shows "✓ Done" / "✗ Failed"; clicking back into the window
  restores plain "Hub".

**B5. Workflow-run scope (explicit decision)**
- *What:* **Workflow runs use polling (`wfStartPoll`), not SSE** — there is no SSE `end` event on
  that path, so the task's "SSE `end`" strictly covers **catalog runs only**. Decision for v1:
  **mirror the same notification + title behavior on workflow poll-completion** for parity — in
  `wfStartPoll`'s `poll()` (`app.js` ~line 597), when `run.status` transitions from `running`
  to a terminal state, call `notifyRunDone(this.wfSelected?.name, run.status)` and
  `setTitleProgress(...)`. Keep this as a clearly-labeled secondary hook so it can be dropped if
  scope must shrink. (If deferred, document that workflows won't toast — they don't "come free"
  with the catalog SSE path.)
- *Where:* `app.js` (`wfStartPoll`).
- *Verify:* Run a workflow, background the window → toast on completion identical in shape to a
  catalog-run toast.

### Group C — Pin/favorites + recents

**C1. Pin state + persistence**
- *What:* In `hubNotifyMixin()` (or a small `pinsMixin` — keep it in `hub-notify.js` to avoid a
  third file) add `pinnedIds: []` and `recentIds: []`. `restorePins()` mirrors `restorePrefs()`
  exactly: read localStorage `hub.pinnedIds` / `hub.recentIds` (JSON arrays, filter to strings),
  then register `this.$watch('pinnedIds', ...)` and `this.$watch('recentIds', ...)` to persist.
  Helpers: `isPinned(item)`, `togglePin(item)` (concat/splice like `toggleHidden`),
  `pushRecent(itemId)` (dedupe to front, cap at 8).
- *Where:* `hub-notify.js`, `app.js` (`init` calls `restorePins`).
- *Verify:* `togglePin` then reload → pin persists. id-stability is the same assumption
  `hiddenIds` already relies on.

**C2. Pinned-first sort + pin button on cards**
- *What:* In `filteredItems` getter (`app.js` ~line 342), after the existing sort, apply a stable
  **pinned-first** partition: pinned items (in their existing sort order) precede unpinned. Add a
  pin button to each `.item-card` (`index.html` ~line 231, mirroring `card-hide-btn`):
  `@click.stop="togglePin(item)"`, `:class="{ 'is-pinned': isPinned(item) }"`, with a star/pin
  glyph (add an `#i-pin` symbol to the sprite, or reuse `#i-bolt`). Record recents:
  call `this.pushRecent(item.id)` inside `selectItem()` (`app.js` ~line 384).
- *Where:* `app.js` (`filteredItems`, `selectItem`), `index.html`, `style.css`.
- *Verify:* Pin a script → it jumps to the top and shows the pinned glyph; sort/filter changes
  keep pinned items first; opening a script adds it to recents.

**C3. Recents row**
- *What:* Above the `.items-grid` (`index.html` ~line 217), add a compact "Recent" row
  `x-show="recentIds.length && !selected && activeTab==='catalog' && !query"` rendering the last
  N recent items (resolve ids → items via `this.items.find`). Clicking a chip calls
  `selectItem`. Hidden when searching/filtering to avoid noise.
- *Where:* `index.html`, `app.js` (a `get recentItems()` getter), `style.css`.
- *Verify:* After opening 2–3 scripts, the recents row shows them most-recent-first; clicking a
  chip opens that script; row hides while a search query is active.

## Backend vs frontend split (which steps need an exe rebuild)

| Step | Backend? | Needs exe rebuild? |
|------|----------|--------------------|
| A1–A5 (canvas polish) | No | **No** |
| B1–B5 (notifications, title) | No | **No** |
| C1–C3 (pins/recents) | No — localStorage only | **No** |

**Every step is pure frontend.** `wwwroot/` is served from disk by the running `Hub.exe`, so
all changes take effect on browser refresh. **No `build-hub.ps1` / `build-release.ps1` run is
required for this phase.** (The v1.5.0.0 rebuild that baked in the *workflow routes* already
shipped in Phase 0 — that is done, not pending.) The localStorage choice for pins is what *keeps*
this phase frontend-only — a backend pins route was never built, so it would 503 on the current
v1.5.0.0 binary and force another rebuild (see Dependencies).

## Testing & verification

- **Manual smoke** (no exe rebuild; hard-refresh between edits):
  - Canvas: toggle snap on/off; Ctrl+Z across add/move/delete; open legacy vs canvas-native
    workflow (auto-fit vs preserved viewport); minimap reflects pan/zoom.
  - Notifications: grant on first run via the run-button gesture; background the window → toast;
    foreground → no toast; title shows ●/✓/✗ then resets to "Hub" on focus.
  - Pins/recents: pin → top + persists across reload; recents populate and hide on search.
- **Existing static smoke test:** re-run
  `tests\smoke-canvas-editor.ps1` to confirm the new `<script>` tags and toolbar markup didn't
  break the canvas static checks. **Phase-0 update:** `Hub.ps1` now accepts `-SkipMutex`
  (line 18; gate at line 2186) and every smoke test passes it plus `-Port`, so the suite now
  runs **alongside a live `Hub.exe`** — the old "fails while Hub.exe holds the mutex" limitation
  (HANDOFF "Known issues" #1) is fixed. No need to close Hub.exe before testing this phase.
  Note: `smoke-canvas-editor.ps1` serves `wwwroot/` from disk, so it validates the *edited*
  frontend immediately with no rebuild.
- **Reduced-motion:** with OS "reduce motion" on, verify minimap/toast/pinned-row introduce no
  animation; existing `@media (prefers-reduced-motion)` blocks in `style.css` already gate the
  blob/drift animations — new selectors must follow the same gating.
- **Console clean:** no uncaught errors; Notification feature-detection degrades silently in
  contexts where the API is unavailable.
- **localStorage robustness:** corrupt `hub.pinnedIds`/`hub.recentIds`/`hub.cnSnapEnabled` values
  are caught (try/catch like `restorePrefs`) and ignored, never throwing during `init()`.

## Risks & mitigations

| Risk | Mitigation |
|------|------------|
| Auto-fit clobbers a user's saved pan/zoom | Auto-fit ONLY on the auto-layout (`steps[]`) branch; respect saved `viewport` when present (A4). |
| `cnFitScreen` runs before render → zero-size rect | Wrap in `this.$nextTick(...)` (A4). |
| Ctrl+Z hijacks text inputs / native undo | Reuse the existing INPUT/TEXTAREA/SELECT guard in `cnKeyDown`; only `preventDefault` when canvas is focused and not in a field (A3). |
| Load-time permission prompt penalized by browser | Request only inside `submit()` on the run-button gesture; never on load (B2). |
| Toast leaks sensitive data | Body limited to script name + status/exit code; never args or output (B3). |
| `canvas-editor.js` (497 LOC) or `app.js` (845 LOC) bloat past limits | New logic goes in two new mixin files < 500 LOC each; edits to existing files are minimal hooks (Files touched). |
| Stale ✓/✗ left in the title | Reset to "Hub" on window focus (B4). |
| Pins/recents not synced across machines | Documented trade-off of the localStorage-only constraint; acceptable, mirrors `hiddenIds`. |
| Workflow runs assumed to toast "for free" | They use polling, not SSE — handled explicitly in B5, with an optional-drop note. |
| `item.id` instability would mis-pin | Same assumption `hiddenIds` already relies on; noted, not re-litigated. |

## Rejection criteria (explicit DO-NOTs — anti-patterns to prevent common mistakes)

These consolidate the "DO NOT" guidance scattered through the steps above into one checklist
so an executing coder cannot miss them:

- **DO NOT** build an undo *stack* or multi-level history. Undo is **one level only** (single
  previous snapshot, nulled after restore) — see A3. A growing stack is out of scope and a
  memory/complexity trap.
- **DO NOT** auto-fit (`cnFitScreen`) on the saved-viewport branch of `cnOpenWorkflow`. Auto-fit
  ONLY on the auto-layout-from-`steps[]` branch and in `cnOpenNew()`. Auto-fitting a canvas-native
  workflow would **discard the user's saved pan/zoom** — see A4.
- **DO NOT** make the minimap interactive in v1 (no click-to-pan, no drag). It is **display-only**;
  interactivity is a future phase — see A5.
- **DO NOT** call `Notification.requestPermission()` on page load or in `init()`. Request **only**
  on the run-button user gesture inside `submit()`; browsers penalize load-time prompts — see B2.
- **DO NOT** put run arguments, parameter values, or any stdout/stderr output in a notification
  toast. Body is limited to **script name + status/exit code** only — see B3 (security).
- **DO NOT** add a backend route for pins, recents, or notification prefs. All three are
  **localStorage only**; a new route would 503 and force an exe rebuild — see Dependencies.
- **DO NOT** add a third new JS file. Keep pins/recents inside `hub-notify.js`; only two new
  files are created this phase.
- **DO NOT** introduce un-gated motion. Every new animated selector (minimap, toast, pinned row)
  must sit behind the existing `@media (prefers-reduced-motion)` blocks in `style.css`.
- **DO NOT** assume workflow runs toast "for free." They poll (`wfStartPoll`), not SSE — they
  need an explicit completion hook — see B5.
- **DO NOT** let `restorePins()` / `restoreNotifyPrefs()` throw on corrupt localStorage. Wrap
  reads in try/catch exactly like `restorePrefs()` — a bad stored value must never break `init()`.

## Rollback plan

- All changes are additive and isolated. To roll back **any single feature**, revert the
  corresponding hunk(s); the two new files (`canvas-polish.js`, `hub-notify.js`) can be deleted
  and their two `<script>` tags + mixin spreads removed to drop Groups A/B/C entirely.
- **No data migration / no backend state** — nothing persisted server-side. Worst-case user
  recovery: clear the `hub.*` localStorage keys (`hub.pinnedIds`, `hub.recentIds`,
  `hub.cnSnapEnabled`, `hub.notifyEnabled`) via DevTools.
- Because there's no exe rebuild, rollback is just restoring `wwwroot/` files + browser refresh —
  no reinstall, no release re-cut.
- `git revert` of the phase commit fully restores prior behavior; the running binary is unaffected.

## Definition of Done

- [ ] Canvas: grid-snap toggle works and persists; one-level Ctrl+Z undoes add/move/delete (and
      only one level, guarded against text inputs); auto-fit centers auto-layout workflows while
      preserving saved viewports; minimap shows nodes + a live viewport rectangle.
- [ ] Notifications: permission requested only on the run-button gesture; OS toast fires on run
      finish **only when unfocused**, containing name + status only; `document.title` shows
      ● running → ✓/✗ on finish → resets to "Hub" on focus. Catalog runs covered; workflow runs
      covered (B5) or explicitly documented as deferred.
- [ ] Pins/recents: pin button on cards; pinned items sort first and persist; recents row shows
      recently-opened scripts and hides during search; all state in localStorage.
- [ ] All new motion gated behind `prefers-reduced-motion`; no console errors; corrupt
      localStorage values handled gracefully.
- [ ] New code lives in `canvas-polish.js` + `hub-notify.js` (each < 500 lines); edits to
      `canvas-editor.js` / `app.js` are minimal hooks.
- [ ] `tests\smoke-canvas-editor.ps1` still PASSes (now runs alongside a live `Hub.exe` via
      `-SkipMutex`); verified entirely **without rebuilding `Hub.exe`** (browser hard-refresh only).

## Outcome Block

**What was planned:** Three frontend-only feature groups for the v1.5.x point release — (A)
canvas polish (snap toggle, one-level Ctrl+Z undo, auto-fit-on-open, display-only minimap), (B)
run-finished OS notifications + `document.title` progress for both catalog (SSE) and workflow
(poll) runs, and (C) pinned/recents catalog with localStorage persistence. All logic lands in two
new mixin files (`canvas-polish.js`, `hub-notify.js`); existing files get minimal call-site hooks.
No `Hub.exe` rebuild — `wwwroot/` is served from disk.

**Immediate next action:** Create `wwwroot/canvas-polish.js` with `canvasPolishMixin()` exposing
`cnSnapEnabled`, `cnSnap(v)`, `cnUndoSnapshot`/`cnSnapshot()`/`cnUndo()`, and `get cnMinimap()`
(start of Group A, task A1→A2).

**How to measure:**

| What | Command | Pass condition |
|------|---------|----------------|
| New files exist & under 500 lines | `(Get-Content wwwroot\canvas-polish.js).Count; (Get-Content wwwroot\hub-notify.js).Count` | both < 500 |
| Canvas static smoke still green (alongside live Hub.exe) | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\smoke-canvas-editor.ps1` | exits 0 / "PASS" |
| No new backend route snuck in | `Select-String -Path wwwroot\*.js -Pattern "/api/pins|/api/recents|/api/notify"` | no matches |
| Mixins wired (console, manual) | DevTools: `typeof hubApp().cnUndo` and `typeof hubApp().notifyRunDone` | both `"function"`, no "not defined" errors |
