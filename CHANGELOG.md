# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.6.0.0] - 2026-05-30

### Added
- **Parameter presets / saved runs** (`Hub-Presets.ps1`) — save a named set of
  filled-in parameter values per script (`POST /api/presets`), list them
  (`GET /api/presets?itemId=`), apply with one click, and delete
  (`DELETE /api/presets/<id>`). CSRF-gated writes; typed-mode only.
- **"What will run" argv preview** (`POST /api/argv-preview`) — shows the exact
  argument array Hub will spawn, computed server-side via the same `Resolve-RunPlan`
  helper as `/api/run` (so it can't drift), rendered as discrete chips with a
  no-shell note. Best-effort `complete:false` on missing required fields.
- **Re-run from history** — history entries now carry the (redacted) parameters and
  script name; a "Re-run" button repopulates the run form. Raw-arg runs are flagged
  (raw args are never stored).
- **Log viewer upgrade** (`wwwroot/logviewer.js`) — in-log search/filter, XSS-safe
  ANSI color rendering (escape-then-colorize), line-wrap toggle, copy + download,
  and a scroll-lock/auto-scroll toggle.

### Security
- **Secret redaction at every persistence boundary** — values whose schema widget is
  `password` (`[securestring]`/`[pscredential]`) **or** whose name matches a secret
  heuristic (`password`/`token`/`api-key`/`secret`/`credential`/…) are stripped before
  a preset or history entry is written to disk. Raw-argument strings are never stored
  (only a boolean). Argv-preview masks secret values in the rendered command line.

## [1.5.0.0] - 2026-05-30

### Added
- **Pipeline Builder** — chain scripts into multi-step workflows. Workflow CRUD
  with schema validation (step IDs, `scriptId`, param templates, forward-ref +
  cycle detection, 50-step cap, atomic persistence) in `Hub-Workflows.ps1`; a
  run state machine driven by the `Step-Jobs` pump with template substitution
  (`{{step-sN.stdout}}` / `.stdout.all` / `.exitCode`), SSE step events
  (step-start/step-end/end), a kill route, and interrupted-run recovery on
  startup in `Hub-WorkflowEngine.ps1`.
- **Visual canvas workflow editor** (`wwwroot/canvas-editor.js`) — drag-and-drop
  node builder with bezier edges, pan/zoom around the cursor, pointer-capture
  drags, DFS cycle detection on edge-create + save, 8px grid snap, and a
  schema-driven side panel. Kahn topo-sort produces the ordered `steps[]`.
- **Workflow UI** — three-tab layout (Catalog / Workflows / History), workflow
  list + detail + run view with a step-progress indicator and kill button.
- **Triggers** (`Hub-Triggers.ps1`) — 5-field cron scheduler (AND dom+dow) and
  file-watch triggers via mtime polling; specs validated at create time
  (bad cron → 422); state persisted under `trigger-states\`.
- **Git catalogs** (`Hub-Git.ps1`) — `POST/GET /api/git-roots` (CSRF-gated,
  https-only), shallow clone (`--depth 1`) + pull with a trust warning; clone
  dirs join the effective scan roots.
- **Run history** (`Hub-History.ps1`) — JSON-lines log at `history\runs.jsonl`
  with atomic rotation at 500 entries; `GET /api/history` with
  limit/offset/status/workflowId filters and `?format=csv` export.
- **`-SkipMutex`** test flag on `Hub.ps1` — lets the smoke suite run beside a
  live `Hub.exe`; the four engine/UI smoke tests now sandbox `TEMP` +
  `LOCALAPPDATA` and bind a dedicated port so they never touch live state.

### Changed
- Rebuilt `Hub.exe` so the embedded route table serves the workflow / trigger /
  git / history endpoints (the v1.4.13.0 binary returned 503 for `/api/workflows`).

### Fixed
- **PS5.1 exe startup** — the Phase 1–6 modules contained PowerShell 7-only syntax
  that never ran under the PS2EXE/PS5.1 runtime (they'd only ever been exercised
  under pwsh 7). `Hub-History.ps1` used `??` (null-coalescing) — a hard parse error
  under PS5.1 that silently broke dot-sourcing and prevented the exe from starting.
  Rewritten with PS5.1-safe equivalents.
- **Schema cache under the exe** — `Get-SchemaCache` read the cache with
  `ConvertFrom-Json -AsHashtable` (PS6+ only); under PS5.1 it always threw, so the
  cache was never used and every `/api/items` did a full cold AST re-scan. Now uses
  the existing PS5-safe `ConvertFrom-JsonHashtable` converter.
- `GET /api/history` on a fresh install (no history yet) returned bare JSON `null`
  instead of `{ entries: [], total: 0, ... }`, which could break the History tab
  for new users. It now always returns the consistent shape.

## [1.4.13.0] - 2026-05-26

### Added
- **Extended `param()` autodetect** — `ConvertTo-WidgetSpec` now covers
  `double`/`decimal`/`float`/`single`, `datetime`, `guid`, `uri`,
  `securestring`/`pscredential`, `hashtable`, `object[]` / `double[]` /
  `bool[]` / `switch[]`, plus validators `ValidateRange`, `ValidatePattern`,
  `ValidateLength`, `ValidateCount`, `ValidateNotNullOrEmpty`,
  `ValidateScript`, `Alias`, `Position`, `ParameterSetName`, `AllowNull`,
  `AllowEmptyString`, `AllowEmptyCollection`. Comment-based `.PARAMETER`
  help honoured as fallback when `[Parameter(HelpMessage=...)]` is absent.
- **`paramPreview` + schema cache** — `/api/items` now carries a slim
  `paramPreview` (count, requiredCount, typeTags, parameterSets) and
  `schemaMode` (`typed` / `partial` / `raw`) per item. Backed by an
  mtime+size-keyed JSON cache at `%LOCALAPPDATA%\Hub\schema-cache.json`.
  Single-pass AST via new `Get-ItemMetadata`.
- **Card chip strip** — typed `.ps1` cards surface count + required +
  up to 4 type icons; raw `.ps1` cards show a gold "raw" badge;
  `.exe` and cloud-only items stay clean.
- **Vendored fonts** — Geist Sans + Geist Mono (Latin subset WOFF2,
  ~42 KB total) under `wwwroot/vendor/fonts/`. WOFF2 MIME registered.
  Preload links + `font-display: swap`.
- **shadcn-hybrid neutral palette** (OKLCH) replaces Catppuccin Mocha.
  Legacy token names aliased so existing CSS rules cascade-inherit.
  Component primitives `.card`, `.btn`, `.btn-primary/ghost/danger`,
  `.input`, `.badge`, `.dialog`, `.dialog-backdrop`.
- **Glassmorphism overlay** — `backdrop-filter` on cards / header /
  log pane / dialogs. Animated multi-blob gradient underlay
  (violet / cyan / magenta / amber) with drift keyframes; gated by
  `prefers-reduced-motion`. Floating header card detaches from viewport
  edges.
- **Command-K palette** — `Ctrl+K` / `Cmd+K` opens fuzzy-search overlay
  over the catalog. Pure client-side filter, no new API.
- New form widgets: `password`, `datetime-local`, `url`, `unsupported`
  (for `scriptblock` params).
- Inline aliases display under field name when `[Alias(...)]` is present.
- `countMin` / `countMax` live hint on `textarea-multi` widgets.

### Fixed
- **PS5 codepage parse-errors** — `.ps1` scripts saved as UTF-8 without
  BOM containing non-ASCII glyphs (e.g. ✓ ✗) no longer fall through to
  raw mode. All parsing routes through `Read-ScriptAst` which uses
  `StreamReader(path, UTF-8, detectBOM=true)` + `Parser::ParseInput`.
- `smoke-phase1.ps1` stale assertions refreshed (pre-P2 test rot).
- `.hub-version` UI chip now reflects current build (was pinned at 1.1.0.0).

### Changed
- `Get-ItemDescription` retained as thin delegator; `Get-ItemMetadata`
  is the canonical AST entry-point.
- `/api/items/{id}/schema` response carries new `schemaMode` field
  alongside the existing `mode`. Additive — old clients unaffected.

## [1.1.0] - 2026-05-19

### Added
- Config-driven scan roots — Hub now reads `%LOCALAPPDATA%\Hub\hub-config.json`
  on startup (versioned schema: `{ version, scanRoots, scanMaxDepth, hiddenIds }`).
- First-run setup wizard — auto-opens in the browser when no config is present.
  Pick scan-root folders interactively via a Windows folder-browser dialog.
- `/api/config`, `/api/setup`, `/api/browse-folder` routes (CSRF-protected like
  every other state route).
- `Test-ValidScanRoot` — 7-rule rejection: relative paths, UNC, `system32`,
  install-dir reflection, config-dir reflection, traversal, and a 16-root cap.
- One-line installer for end users:
  `irm https://raw.githubusercontent.com/Patryk-beep/powershell-script-hub/v1.1.0/install-hub.ps1 | iex`
- `install-hub.ps1` with `-Install` / `-Update` / `-Uninstall` modes,
  SHA256-verified asset download, Start Menu shortcut, optional autostart,
  mutex-guarded update + uninstall.
- `build-release.ps1` — patches the release zip's SHA256 into `install-hub.ps1`
  and (with `-Publish`) cuts the GitHub release.

### Changed
- Spawned child processes now use `ProcessStartInfo.Arguments` (string) instead
  of `ArgumentList` (.NET 5+) so Hub.exe runs cleanly under the .NET Framework
  PowerShell 5 runtime that PS2EXE produces.
- JSON parsing switched off `-AsHashtable` (PS6+) to plain PSCustomObject so
  the PS5 host doesn't trip on `ConvertFrom-Json`.
- Folder-browser dialog is now anchored to an off-screen TopMost owner Form so
  it always appears in front of the browser instead of hiding behind it.

### Security
- Localhost-only listener bound to `127.0.0.1:8765` (no external bind).
- Defense layers: Origin allowlist + Host pin + CSRF cookie + `X-Hub-CSRF`
  header + `SameSite=Strict` on every state route (`/api/run`,
  `/api/jobs/.+/kill`, `/api/setup`, `/api/browse-folder`).
- AST-only parameter introspection (`[Parser]::ParseFile`) — scripts are never
  executed during scan/discovery.
- Single-instance per-user mutex `Global\HubInstance.<sanitized-username>`.
- Installer pins the winget source to `cdn.winget.microsoft.com/cache` before
  running `winget install Microsoft.PowerShell` — refuses to install if the
  default source has been replaced or removed.
- Installer URL is tag-pinned (`/v1.1.0/`) not `/main/` so a compromised `main`
  branch cannot push a malicious installer to existing users.

[Unreleased]: https://github.com/Patryk-beep/powershell-script-hub/compare/v1.6.0.0...HEAD
[1.6.0.0]: https://github.com/Patryk-beep/powershell-script-hub/releases/tag/v1.6.0.0
[1.5.0.0]: https://github.com/Patryk-beep/powershell-script-hub/releases/tag/v1.5.0.0
[1.4.13.0]: https://github.com/Patryk-beep/powershell-script-hub/releases/tag/v1.4.13.0
[1.1.0]: https://github.com/Patryk-beep/powershell-script-hub/releases/tag/v1.1.0
