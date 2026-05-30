# Phase 2 — Daily-driver power (target v1.6.0.0)

## Goal
Make Hub pleasant to use day-to-day for the script you run a hundred times. Three
features:
1. **Parameter presets / saved runs** — persist named filled-in param sets per item;
   list/apply them; re-run a history row by repopulating the form from the params
   it actually used.
2. **Argv preview ("what will run")** — show the exact argv array Hub will spawn,
   computed server-side, before running. Turns the existing argv-array /
   no-shell-metacharacter model into a visible trust feature.
3. **Log viewer upgrade** — in-log search/filter, ANSI color rendering, line-wrap
   toggle, copy + download, scroll-lock/auto-scroll toggle.

### Overriding constraint — secrets never hit disk (read this first)
`ConvertTo-WidgetSpec` (Hub.ps1 ~L918-923) stamps `password` / `securestring` /
`pscredential` fields with the promise *"Sent over loopback as plain string. Not
stored."* Presets, re-run-from-history, and any logged params all serialize the
submitted `values` map — naively persisting them would write credentials into
`presets\*.json` and `runs.jsonl` and break that promise.

**Rule for this phase:** before persisting a `values` map (preset save OR history
log), drop every field whose schema widget is `password`. On apply / re-run those
fields come back **blank** (and stay `required`), forcing re-entry. `rawArgs` is
opaque (may embed secrets) and is therefore **redacted from history logging** and
**not offered as a saved preset value** — presets are a typed-mode-only feature.
The redaction must be keyed off the live schema (`Get-ParamSchema`), not a guess,
so a field renamed/retyped in the script can't leak on the next run.

## Dependencies / prerequisites
- **Phase 0 complete**: a working v1.5 `Hub.exe` and smoke tests runnable while
  Hub.exe is open — i.e. `Hub.ps1` honors a `-SkipMutex` switch (HANDOFF.md known
  issue #1) so `tests/smoke-phase2-*.ps1` can boot `Hub.ps1` on an alternate port
  (`-Port`) without colliding with the singleton mutex / running binary.
- No new runtime dependencies. PowerShell 5.1 / 7 compatible. Files < 500 lines.
- Persistence mirrors the workflows pattern (`Save-Workflow`: write `.tmp` → delete
  target → `Move`; `ConvertFrom-JsonHashtable` on load; `Initialize-*` at startup).

## Files touched (existing + new, absolute repo paths)
**New**
- `C:\Users\Harrold\Documents\Claude Projects\Hub\Hub-Presets.ps1` — preset CRUD +
  routes (mirror Hub-Workflows.ps1 / Hub-History.ps1 module shape). Backend.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\wwwroot\presets.js` —
  `presetsMixin()` spread into `hubApp()` (mirrors `canvas-editor.js` pattern).
  Frontend.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\wwwroot\logviewer.js` —
  `logViewerMixin()`: filter/search state, ANSI→span parser (HTML-escaping),
  copy/download, wrap toggle. Frontend.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\tests\smoke-phase2-presets.ps1`
- `C:\Users\Harrold\Documents\Claude Projects\Hub\tests\smoke-phase2-argv-preview.ps1`
- `C:\Users\Harrold\Documents\Claude Projects\Hub\tests\smoke-phase2-history-rerun.ps1`

**Existing — backend**
- `Hub.ps1`:
  - dot-source block (~L109-113) → add `. Hub-Presets.ps1`.
  - `$Script:StateRoutes` (~L45-55) → register POST/DELETE preset + (none for
    argv-preview; see note) routes.
  - `Invoke-Route` (~L1945-2003) → add `/api/presets`, `/api/presets/.+?`,
    `/api/argv-preview` branches.
  - main entry (~L2199-2203) → add `Initialize-Presets`.
  - `New-JobRecord` (~L1326-1351) → add `values` + `rawArgs` fields (redacted copy).
  - `Invoke-RunRoute` (~L1654-1730) → extract shared resolve/validate/build helper;
    stash redacted params on the job record.
  - `Start-HubJob` (~L1394-1454) → accept + carry the redacted params onto the job.
- `Hub-History.ps1`:
  - `Write-HubHistory` (~L31-49) → emit a redacted `params` object (+`rawArgsUsed`
    boolean, never the value) and `name`/`itemName` for display.
  - bump history entry shape; `Get-HistoryCsv` columns unchanged (params omitted
    from CSV to avoid a ragged schema).
- `Version` bump `$Script:Version = '1.6.0.0'` (Hub.ps1 ~L24).

**Existing — frontend**
- `wwwroot\index.html` — load `presets.js` + `logviewer.js` (after `app.js`,
  before Alpine init, same as `canvas-editor.js`); preset save/list/apply UI in
  the run panel; "What will run" argv-preview block; log-toolbar (search box,
  wrap/scroll toggles, copy/download); "Re-run" button on history rows.
- `wwwroot\style.css` — styles for the preset chips/menu, argv-preview `<pre>`,
  ANSI color classes (`.ansi-*`), log toolbar. Keep additive (append a clearly
  fenced `/* Phase 2 */` block).
- `wwwroot\app.js` — spread the two new mixins into the returned object
  (`...presetsMixin(), ...logViewerMixin()`); add `reRunFromHistory(entry)` that
  selects the item, loads schema, populates `formValues` from `entry.params`, and
  switches to the run view. **Do not** grow app.js's core logic — push detail into
  the mixins (app.js is already 845 lines, over the 500 guideline).

**Build/release**
- `CHANGELOG.md` — `[1.6.0.0]` section.
- `README.md` — install one-liner tag bump to `v1.6.0.0`.
- `build-hub.ps1` / `build-release.ps1` — invoked at release (no edits expected;
  `Hub-Presets.ps1` and `*.js` ship because the build globs the repo + wwwroot —
  **verify** the build manifest picks up the new module file).

## Implementation steps (numbered: what / where / how-to-verify)

### A. Preset persistence module (backend → REBUILD for Hub.exe)
1. **Create `Hub-Presets.ps1`.** What: `$Script:Presets = [hashtable]::Synchronized(@{})`;
   `Get-PresetsDir` → `%LOCALAPPDATA%\Hub\presets`; `New-PresetId` → `ps-<guid>`;
   `Save-Preset` (temp→delete→move, exactly like `Save-Workflow`); `Remove-PresetFile`;
   `Initialize-Presets` (enumerate `*.json`, skip `.tmp`, `ConvertFrom-JsonHashtable`).
   Where: new file, < 500 lines. Verify: `Test-Path` of the dir after a save;
   round-trip a written file through `Initialize-Presets`.
2. **Preset record shape.** `{ id, itemId, name, values (redacted), createdAt }`.
   Reuse `ConvertFrom-JsonHashtable` (defined in Hub-Workflows.ps1, already loaded
   first). Verify: saved JSON has no `password`-widget keys (unit assertion in test).
3. **Redaction helper.** What: `Remove-SecretValues -Schema $schema -Values $ht` →
   returns a clone with every field whose `widget -eq 'password'` removed. Where:
   Hub-Presets.ps1 (also called by history). Verify: feed a schema with a password
   field + a value; assert the key is absent from output.
4. **Routes — `Invoke-PresetsRoute` (collection).** GET `/api/presets?itemId=<id>` →
   list filtered by itemId (array JSON, use the `ConvertTo-Json -InputObject` +
   `'[]'` fallback idiom from `Invoke-WorkflowsRoute`). POST `/api/presets` →
   validate `{itemId, name, values}`; resolve item + re-validate scan root (reuse
   the shared helper from step 8) so a preset can't reference an item outside a
   scan root; fetch live schema; redact; assign id; `Save-Preset`; 200 with record.
   Where: Hub-Presets.ps1. Verify: POST then GET returns it; password value stripped.
5. **Routes — `Invoke-PresetByIdRoute`.** DELETE `/api/presets/<id>` → 200/404.
   (No PUT — edit = delete + re-save, matching workflows.) Verify: delete then GET
   list is empty.
6. **Wire into Hub.ps1.** (a) dot-source `Hub-Presets.ps1`; (b) `Initialize-Presets`
   in main; (c) **CSRF registration (two-part, honor existing pattern):** add
   `'/api/presets'` and `'/api/presets/.+?'` to `$Script:StateRoutes`; add the route
   branches to `Invoke-Route` (`/api/presets` exact, `^/api/presets/([^/]+)$` regex).
   **CSRF nuance:** `Invoke-SecurityMiddleware` only enforces CSRF on non-GET, so the
   GET list is automatically exempt while POST/DELETE are gated — no extra code.
   Verify: POST without `X-Hub-CSRF` → 403 `csrf`; GET list without header → 200.

### B. Re-run from history (backend → REBUILD) — param threading, not a one-liner
7. **Thread params onto the job record.** What: add `values` and `rawArgs` fields to
   `New-JobRecord` (Hub.ps1 ~L1326). Populate them in `Invoke-RunRoute` *after*
   `Build-Argv` succeeds, storing the **redacted** `values` (call `Remove-SecretValues`)
   and a `rawArgsUsed` boolean (never the raw string). Pass through `Start-HubJob`
   (new optional `-Values`/`-RawArgsUsed` params) onto the record. Where: Hub.ps1.
   Verify: run a fixture with params; inspect the in-memory job (smoke can't, so
   assert via the history entry in step 9).
8. **Extract shared resolve/build helper.** What: factor the common
   "resolve item by id → re-validate under scan root → `Get-ParamSchema` →
   `Build-Argv`" block out of `Invoke-RunRoute` into `Resolve-RunPlan -ItemId -Values
   -RawArgs` returning `@{ item; resolved; schema; argv }` or a structured error.
   Both `/api/run` and `/api/argv-preview` (step 11) call it so they can never drift.
   Where: Hub.ps1. Verify: `/api/run` still works end-to-end (existing smoke-phase2);
   preview argv equals what run spawns for the same body.
9. **History emits redacted params.** What: in `Write-HubHistory` add
   `params` (the redacted `values` from the job), `rawArgsUsed` (bool), and `itemName`
   (resolve via catalog or carry on the job) to the entry. Where: Hub-History.ps1
   (~L34-42). Keep `Get-HistoryCsv` columns as-is (params not in CSV). Verify: run a
   fixture, GET `/api/history`, assert entry has `params` with the non-secret value
   and **no** password key; rotation still works at 500.
10. **Frontend re-run.** What: `reRunFromHistory(entry)` in app.js — find item by
    `entry.itemId` (guard: item may no longer exist / be out of scan root → show a
    toast, abort), `selectItem`, await schema load, set `formValues = {...entry.params}`
    (password fields stay blank), switch to catalog/run view, do **not** auto-submit.
    Add a "Re-run" button to history rows in index.html. Where: app.js + index.html.
    Verify (manual + UI smoke): clicking re-run lands on the run form pre-filled.

### C. Argv preview (backend compute → REBUILD; read-only, NOT a state route)
11. **`/api/argv-preview` endpoint.** What: POST (body `{itemId, values, rawArgs}`),
    calls `Resolve-RunPlan` (step 8) but **does not spawn**. Returns
    `{ exe, argv: [..], commandLineString, schemaMode, complete: bool }` where `exe`
    is `pwsh` (+ the fixed `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File
    <path>` prefix) for `.ps1` or the exe path for `.exe`, and `argv` is the honest
    array (one discrete element per arg — the point is "no shell"). `commandLineString`
    via `Join-CmdLineArgs` for the human-readable line. Where: Hub.ps1 (route) +
    helper. **Not added to `$Script:StateRoutes`** (read-only computation, no CSRF) —
    but it IS a POST, so middleware still enforces Origin + Host + `Content-Type:
    application/json`. Verify: POST a body, assert `argv` matches the array `/api/run`
    would build; assert `password` values are reflected in the preview only in-memory
    (response is fine to show; nothing persisted).
12. **Graceful incomplete preview.** What: `Build-Argv` throws `ArgumentException` on
    a missing required field. In preview, catch it and return `{ complete:false,
    missing:[names], argv:[partial-or-empty] }` with **200**, not 400 — a half-filled
    form should still show a best-effort preview, not an error. Where: argv-preview
    route. Verify: omit a required field → 200, `complete:false`.
13. **Frontend "What will run" block.** What: `presetsMixin` (or a small inline)
    debounced call to `/api/argv-preview` as `formValues` changes; render `exe` +
    `argv[]` as discrete chips/lines + the joined command line; a short note: "Hub
    runs this as a fixed argument array — your input is never passed through a shell."
    Where: presets.js + index.html + style.css. Verify (manual): typing a value with
    a space shows it as one argv element, quoted only in the joined line.

### D. Log viewer upgrade (frontend-only → NO rebuild)
14. **`logViewerMixin()` in `wwwroot\logviewer.js`.** State: `logFilter` (string),
    `logWrap` (bool), `autoScroll` (already exists in app.js — **extend, do not
    re-declare**), `filteredLogLines` getter (case-insensitive substring over the
    line text). Where: new file, spread into `hubApp()`. Verify: with N lines, a
    filter string reduces rendered rows; clearing restores them.
15. **ANSI color rendering — XSS-safe.** What: tiny `ansiToHtml(line)` that FIRST
    HTML-escapes (`& < > "`), THEN converts SGR escape sequences (`[..m`) to
    `<span class="ansi-fg-N">`. Log lines are untrusted child-process stdout — escape
    before injecting or it's an XSS sink. Render with `x-html` only on the escaped
    output. Support the 8/16 basic colors + reset + bold; strip unknown sequences.
    Where: logviewer.js + `.ansi-*` classes in style.css. Verify: a fixture that
    emits `<script>` + an ANSI color sequence renders the literal text colored, with
    no script execution (UI smoke asserts the escaped substring in DOM source).
16. **Line-wrap toggle.** What: toggle a `.log-wrap` class on `$refs.logPane`
    (`white-space: pre` ↔ `pre-wrap`). Verify (manual): long line wraps/scrolls.
17. **Copy + download.** What: Copy → `navigator.clipboard.writeText(plainText)`
    (plain text = the un-ANSI, un-HTML joined `logLines`, respecting the active
    filter? — copy the **full** log; download the full log). Download → Blob
    `text/plain`, filename `hub-log-<jobId|timestamp>.txt`. Where: logviewer.js +
    toolbar buttons in index.html. Verify (manual): downloaded file matches the log.
18. **Scroll-lock / auto-scroll toggle.** What: surface the existing `autoScroll`
    flag (app.js bindLogAutoscroll ~L293-302) as a visible toggle button; when off,
    new lines don't yank scroll position. Verify (manual): toggle off, push lines,
    scroll stays put.

## Backend vs frontend split (which steps need an exe rebuild)
| Sub-item | Steps | Layer | Needs Hub.exe rebuild? |
|---|---|---|---|
| Presets persistence + routes | 1–6 | Backend | **Yes** (new routes invisible until rebuild) |
| Re-run param threading + history params | 7–9 | Backend | **Yes** |
| Re-run UI button | 10 | Frontend | No (consumes existing+new GET data) |
| Argv preview endpoint | 11–12 | Backend | **Yes** |
| Argv preview UI | 13 | Frontend | No |
| Log viewer (search/ANSI/wrap/copy/download/scroll) | 14–18 | Frontend | No |

**Why rebuild matters:** the shipped `Hub.exe` embeds `Invoke-Route` + `$Script:StateRoutes`
in its compiled image, so new backend routes return 503 until `build-hub.ps1` recompiles.
**Tests are exempt:** smoke tests launch `Hub.ps1` directly (`pwsh -File Hub.ps1`), which
dot-sources the modules at runtime — new routes work in tests without a rebuild. The
rebuild is a *release* (DoD) step, not a *test* prerequisite.

## Testing & verification (smoke tests to add under tests/)
Mirror `tests/smoke-phases456.ps1` harness (Start-Hub via `pwsh -File Hub.ps1
-ExtraScanRoots fixtures -Port <alt> -SkipMutex`; `New-HubSession` for CSRF;
`Invoke-Api` helper). Back up + restore `hub-config.json` and clean
`presets\` / `history\` between runs.

- **`smoke-phase2-presets.ps1`**: POST preset → 200; GET `?itemId=` returns it;
  saving a preset whose values include a `password` field → stored JSON has no
  password key (read `presets\*.json` off disk and assert); POST without CSRF → 403;
  DELETE → 200, GET list empty; item outside scan root rejected.
- **`smoke-phase2-argv-preview.ps1`**: POST a complete body → 200, `argv` array equals
  the array `/api/run` builds (run the fixture, compare against a known-good argv for
  `arg-echo.ps1`); a value containing a space → one argv element, quoted in
  `commandLineString`; omit a required field → 200 `complete:false`; ValidateSet
  violation → surfaced (matches Build-Argv behavior).
- **`smoke-phase2-history-rerun.ps1`**: run `sample-param.ps1` with a known value →
  GET `/api/history` → newest entry has `params` with that value and `itemName`;
  run a fixture with a password param (add `tests/fixtures/secret-param.ps1`) →
  history entry has **no** secret value, `rawArgsUsed:false`; rotation still trims at
  500.
- **Regression:** existing `smoke-phase2-engine.ps1` (run path) must still pass —
  the `Resolve-RunPlan` extraction must not change `/api/run` behavior.
- **Frontend UI smoke** (static-assertion style, like `smoke-canvas-editor.ps1`):
  assert `presets.js` + `logviewer.js` are referenced in index.html, `presetsMixin`
  / `logViewerMixin` exist, and `ansiToHtml` HTML-escapes before colorizing (grep the
  source for an escape step preceding span injection).

## Risks & mitigations
- **Secret leakage into presets/history** (highest). → Redact by live schema
  (`Remove-SecretValues`) at every persistence boundary; smoke test reads the file
  off disk to prove absence. `rawArgs` never logged/saved.
- **Argv preview drifting from real run** (defeats the trust purpose). → Single
  `Resolve-RunPlan` helper shared by run + preview; no client-side argv logic; smoke
  compares preview to the actual run argv.
- **ANSI rendering XSS** (untrusted stdout → HTML). → Escape-then-colorize; `x-html`
  only on escaped output; smoke asserts the escape ordering.
- **Re-run referencing a vanished / moved item.** → `reRunFromHistory` guards on
  item lookup + scan-root membership; shows a non-fatal message instead of a broken
  form.
- **File-size creep** (app.js already 845 lines, >500 guideline). → New logic goes in
  `presets.js` / `logviewer.js` mixins; app.js gains only the small `reRunFromHistory`
  + two `...mixin()` spreads. Keep new modules < 500 lines each.
- **Build manifest misses `Hub-Presets.ps1`.** → DoD step explicitly verifies the
  module is bundled into Hub.exe (boot rebuilt exe, hit `/api/presets`, expect 200).
- **History entry shape change breaks old readers.** → Additive only (`params`,
  `rawArgsUsed`, `itemName` are new keys); `Read-HubHistory` / `Get-HistoryCsv`
  tolerate missing keys on pre-1.6 lines (no required-field assumptions).
- **PS5 vs PS7** (Hub.exe is PS5; tests may run PS7). → Avoid `??`-only constructs in
  module code paths the exe executes (note: `Invoke-HistoryRoute` already uses `??`,
  but it runs from the dot-sourced module under whatever host launched Hub — keep new
  code PS5-safe: no `??`, no `-AsHashtable`, use `ConvertFrom-JsonHashtable`).

## Rollback plan
- Each sub-item is independent; revert per-feature.
- **Backend:** delete `Hub-Presets.ps1`, remove its dot-source + `Initialize-Presets`
  + the three `Invoke-Route` branches + the two `$Script:StateRoutes` entries; revert
  `New-JobRecord` / `Invoke-RunRoute` / `Start-HubJob` / `Write-HubHistory` to the
  pre-phase shape (the param fields are additive, so reverting is purely subtractive).
  Existing history lines with `params` are harmless to a reverted reader (extra keys
  ignored).
- **Frontend:** remove the two `<script>` tags + the two `...mixin()` spreads +
  `reRunFromHistory`; the run/log/history UI returns to v1.5 behavior. No data
  migration — preset files simply stop being read.
- **Release:** if a regression ships, re-cut the previous tag (`v1.5.x`); presets dir
  is orphaned but never deleted.
- Data dirs (`presets\`, `history\`) are never destroyed on rollback.

## Definition of Done
- [ ] `Hub-Presets.ps1` created (<500 lines), dot-sourced, `Initialize-Presets` wired.
- [ ] `/api/presets` (GET list `?itemId=`, POST) + `/api/presets/<id>` (DELETE)
      working; POST/DELETE CSRF-gated (registered in `$Script:StateRoutes` **and**
      `Invoke-Route`); GET list exempt.
- [ ] Saving a preset / logging history with a `password` field writes **no** secret
      to disk (proven by a smoke test reading the file).
- [ ] History entries carry redacted `params` + `itemName`; "Re-run" repopulates the
      form (password fields blank); guards a missing item.
- [ ] `/api/argv-preview` returns the honest argv array, matches what `/api/run`
      spawns (shared `Resolve-RunPlan`), 200-with-`complete:false` on missing required.
- [ ] "What will run" UI shows exe + argv array + joined command line + the no-shell note.
- [ ] Log viewer: search/filter, ANSI color (XSS-safe), wrap toggle, copy, download,
      scroll-lock toggle — all functional; `autoScroll` extended not duplicated.
- [ ] New logic lives in `presets.js` / `logviewer.js` mixins; app.js core not bloated.
- [ ] `smoke-phase2-presets.ps1`, `smoke-phase2-argv-preview.ps1`,
      `smoke-phase2-history-rerun.ps1` pass under `-SkipMutex`; `smoke-phase2-engine.ps1`
      regression passes.
- [ ] `$Script:Version` = `1.6.0.0`; CHANGELOG `[1.6.0.0]` + README tag bumped.
- [ ] `Hub.exe` rebuilt (`build-hub.ps1 -Version 1.6.0.0`), confirmed to bundle
      `Hub-Presets.ps1` (rebuilt exe answers `/api/presets` with 200, not 503);
      release cut via `build-release.ps1 -Version 1.6.0.0`.
