# Phase 0 — Unblock & ship what exists (target v1.5.0.0)

> Status: PLAN ONLY. No code written. This is the foundation phase — every later
> roadmap phase depends on a shippable binary and a runnable test suite.

## Goal

1. Make the four mutex-blocked smoke tests runnable **alongside a live `Hub.exe`**
   by adding a `-SkipMutex` flag to `Hub.ps1` and (critically) giving those tests
   a dedicated, deterministic port so they never silently talk to the old binary.
2. Rebuild `Hub.exe` so the distributed binary embeds the Phase 1–6 + canvas route
   table (the shipped binary is v1.4.13.0 and returns 503 for `/api/workflows`).
3. Cut release **v1.5.0.0** via `build-release.ps1 -Version 1.5.0.0 -Publish`,
   with `CHANGELOG.md`, README, and installer version pins all updated.

## Dependencies / prerequisites

- **PS2EXE module installed** (`Install-Module ps2exe -Scope CurrentUser`) — required
  by `build-hub.ps1`.
- **gh CLI authenticated** — required by `build-release.ps1 -Publish` (`gh release create`).
- **Clean working tree** before `-Publish` (build-release.ps1 lines 161–167 refuse a
  dirty tree except for `install-hub.ps1`). So: land the `-SkipMutex` + test changes
  and CHANGELOG/README/version-pin edits as their own commit FIRST, then run the
  release script (which commits only the hash-patched installer).
- **No real workflow running** when the smoke suite is exercised against a live Hub.exe
  (see Risks — shared `%LOCALAPPDATA%\Hub\` state).
- PowerShell 5.1 **and** 7 compatibility for every Hub.ps1 / test edit (no PS6+-only
  syntax such as `ConvertFrom-Json -AsHashtable`, ternaries, null-coalescing).

## Files touched (existing + new, absolute repo paths)

Source / build:
- `C:\Users\Harrold\Documents\Claude Projects\Hub\Hub.ps1` — add `-SkipMutex` param + bypass; bump `$Script:Version`; fix stale header comment.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\build-hub.ps1` — default `-Version` pin (1.4.13.0 → 1.5.0.0).
- `C:\Users\Harrold\Documents\Claude Projects\Hub\build-release.ps1` — default `-Version` pin (1.4.13.0 → 1.5.0.0).

Tests (parametrize port + pass `-SkipMutex`):
- `C:\Users\Harrold\Documents\Claude Projects\Hub\tests\smoke-installer-phase1.ps1` — already has `[int]$Port = 8765` (line 13); change default to a free port, thread it into `Start-Hub`, add `-SkipMutex`.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\tests\smoke-phase2-engine.ps1` — add `-Port` param; replace hardcoded `$Script:HubPort = 8765`; pass `-SkipMutex -Port`.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\tests\smoke-phases456.ps1` — same treatment.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\tests\smoke-phase3-ui.ps1` — same treatment.

Release / docs / pins:
- `C:\Users\Harrold\Documents\Claude Projects\Hub\CHANGELOG.md` — `[Unreleased]` → `[1.5.0.0] - 2026-05-30`; new empty `[Unreleased]`; **bottom link-reference block (lines 104–105)**.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\README.md` — install one-liner + tag-pinned URLs (lines 24, 30, 35, 58, 64).
- `C:\Users\Harrold\Documents\Claude Projects\Hub\install-hub.ps1` — default `$Version` (line 47) + help/comment URLs (lines 8, 26) + rate-limit message (line 212). Note: line 47 is `v1.4.13.0` (the **`v`-prefixed tag**), distinct from build scripts' four-part `1.5.0.0`.

No NEW files are created. (Honors "prefer editing existing files".)

## ⚠ Adversary hardening (folded in 2026-05-30 — read before implementing)

These supersede the affected steps below where they conflict:

- **[ADV-001 CRITICAL] Pass the tag explicitly.** `build-release.ps1:56` derives the tag by
  stripping a trailing `.0` → `-Version 1.5.0.0` would tag **`v1.5.0`**, but the existing
  convention (verified: tags are `v1.1.0`, `v1.4.13.0`) and the README/installer pins are
  **four-part `v1.5.0.0`**. Step 16 MUST run with `-Tag v1.5.0.0` so the release tag matches
  the pinned install URLs (otherwise the README one-liner + installer download 404). DoD
  "v1.5.0 release" is corrected to **`v1.5.0.0`**.
- **[ADV-002 HIGH] Isolate `$env:TEMP` per test instance.** `Initialize-HubPort` (2047-2053)
  tries the `hub.port` hint FIRST. With Hub.exe CLOSED (a required DoD scenario) a stale
  `hub.port=8765` is free → the instance binds 8765 while the test polls 8799 → false failure.
  Each test must launch its Hub child with a per-test `$env:TEMP` (or pre-clear/ignore the hint)
  so it binds its `-Port` deterministically. Replaces the fragile "8799 is far from the band" reasoning.
- **[ADV-003 HIGH] Grep wider before the bump.** Add a repo-wide `1\.4\.13` grep AND a scan of
  `tests/` for any `/api/version` or `FileVersion` assertion pinned to the old version; reconcile
  all hits. (CHANGELOG shows a prior hardcoded-version regression.)
- **[ADV-004 MEDIUM] Override `$env:LOCALAPPDATA` for the test child** so interrupted-run recovery
  (`Hub-WorkflowEngine.ps1:36-40`) can never mark a LIVE run `interrupted` and test workflows never
  pollute the user's real list. Verify `-ExtraScanRoots` avoids tripping the first-run wizard on the
  resulting empty config. Makes the plan's "don't run during a live workflow" constraint structural.
- **[ADV-005 MEDIUM]** `Save-PortHint` clobber (2222) is neutralized by the `$env:TEMP` isolation above.

## Implementation steps (numbered; each: what / where / how-to-verify)

### A. `-SkipMutex` flag in Hub.ps1

1. **Add the param.** WHERE: `Hub.ps1` `param(...)` block (lines 5–16, after `[int]$Port = 0`).
   HOW: add `[switch]$SkipMutex` with a comment `# Test-only: bypass the single-instance mutex so a smoke instance can run beside Hub.exe.`
   VERIFY: `[Parser]::ParseFile` clean (build-hub.ps1 step 1 does this automatically).

2. **Bypass the mutex at the call site, not inside the function.** WHERE: `Hub.ps1`
   line 2180, the `if (-not (Test-SingleInstance)) { ... exit 0 }` block.
   HOW: wrap as `if (-not $SkipMutex) { if (-not (Test-SingleInstance)) { ... exit 0 } }`.
   This is the cleanest one-block change: `Test-SingleInstance` is left untouched, so
   in normal runs `$Script:HubMutex` is still acquired and held for the process
   lifetime; with `-SkipMutex`, `$Script:HubMutex` simply stays `$null`.
   VERIFY (manual): run `pwsh -File Hub.ps1 -SkipMutex -Port 8799` while Hub.exe is up; it
   should boot and answer `GET http://127.0.0.1:8799/api/health` 200 instead of exiting 0.

3. **Confirm shutdown null-safety.** WHERE: process-exit / tray-close path.
   HOW: grep showed `$Script:HubMutex` is referenced only at declaration (line 28) and
   acquisition (line 132) — there is **no `.ReleaseMutex()` / `.Dispose()`** call, so a
   `$null` mutex under `-SkipMutex` cannot NRE. Confirm this remains true at plan-execution
   time (single grep `HubMutex`); if a dispose is ever added, guard it with `if ($Script:HubMutex)`.
   VERIFY: grep returns exactly the declaration + acquisition references.

### B. Make the four tests target a dedicated port (the part `-SkipMutex` alone does NOT fix)

Background (verified in source): startup calls `Initialize-HubPort -Preferred $Script:Port`
(line 2206). That function (lines 2030–2074) tries the **`hub.port` hint FIRST** when it
differs from `-Preferred`, then `Preferred`, then `Preferred+1..+10`. Consequences:
- A test that passes `-Port 8799` but leaves the old `%TEMP%\hub.port` = 8765 could bind 8765
  (the hint) — i.e. fail to start (busy, taken by Hub.exe) or, worse, the test then polls 8765
  and unknowingly drives the **old** binary.
- Startup also calls `Save-PortHint` (line 2222), clobbering `%TEMP%\hub.port` — which feeds
  `smoke-final.ps1`'s `Get-HubPort` and the live Hub's "open browser to existing instance".

4. **Pick a fixed test port** (e.g. `8799`) that is outside the `8765..8775` fallback band
   so a collision can't silently land on Hub.exe's range. WHERE: each of the four tests.

5. **Parametrize the port in the three hardcoded tests.** WHERE: `smoke-phase2-engine.ps1`
   (lines 18–19), `smoke-phases456.ps1`, `smoke-phase3-ui.ps1` (lines 16–17).
   HOW: add `[int]$Port = 8799` to each `param(...)`; replace `$Script:HubPort = 8765` with
   `$Script:HubPort = $Port`; leave `$Script:BaseUrl = "http://127.0.0.1:$Script:HubPort"`
   (it already derives from `$Script:HubPort`). `smoke-installer-phase1.ps1` already has
   `[int]$Port = 8765` (line 13) — just change the default to `8799` and make sure its
   base-URL/health-poll derive from `$Port`.
   VERIFY: grep each test for a literal `8765` — should be gone (or only in a comment).

6. **Pass `-SkipMutex` + the chosen port into the launch line.** WHERE: each test's
   `Start-Hub*` argument string (e.g. `smoke-phase2-engine.ps1` line 40; `smoke-phases456.ps1`
   line 59; `smoke-phase3-ui.ps1` line 37; `smoke-installer-phase1.ps1` `Start-Hub`).
   HOW: append `-SkipMutex -Port $Script:HubPort` (or `$Port`) to the existing
   `-ExtraScanRoots ...` arg string. Keep `-ExtraScanRoots` intact.
   VERIFY: the launched `pwsh` command line contains `-SkipMutex -Port 8799`.

7. **Make the test instance start deterministically on its port.** Because `Initialize-HubPort`
   honors the `hub.port` hint first, the safest belt-and-suspenders is for each test to
   poll **the exact port it requested** (it already does, via `$Script:BaseUrl`) AND tolerate
   the documented fallback. Two acceptable options — pick ONE and state it in the test header:
   - (preferred, minimal) Choose 8799, which is far from Hub.exe's 8765 hint and fallback band;
     in practice `Initialize-HubPort` will bind 8799 because the hint (8765) is busy → it skips
     to `Preferred` (8799). The test polls 8799 and gets the **new** instance. No Hub.ps1 change.
   - (only if option 1 proves flaky) Note as a follow-up that `Initialize-HubPort` could honor an
     explicit `-Port` as a hard bind (skip hint+fallback) — but that is a behavior change, out of
     scope for Phase 0; do not implement it here.
   VERIFY: with Hub.exe live on 8765, run each test; the `Hub booted` assertion passes and
   `/api/version` on the test port reports `1.5.0.0` (proving it's the new instance, not the exe
   that may still be old if run before step C).

### C. Version bump (two independent sources MUST agree)

8. **Runtime version string.** WHERE: `Hub.ps1` line 24 `$Script:Version = '1.4.13.0'` → `'1.5.0.0'`.
   This drives `/api/version` and the UI `.hub-version` chip (`wwwroot/index.html` line 74 reads
   `version` from `/api/health`/`/api/version` via `app.js`). Also fix the stale header comment
   `# Version 1.0.0.0` (line 2) → `# Version 1.5.0.0` for hygiene.
   VERIFY: `/api/version` returns `{ "version": "1.5.0.0" }`; UI chip shows `v1.5.0.0`.

9. **Binary file version.** WHERE: passed as `build-hub.ps1 -Version 1.5.0.0` (PS2EXE
   `version=` arg, build-hub.ps1 line 80). Also bump the **default** at build-hub.ps1 line 11
   and build-release.ps1 line 47 (1.4.13.0 → 1.5.0.0) so a bare invocation is correct.
   VERIFY: `(Get-Item Hub.exe).VersionInfo.FileVersion` == `1.5.0.0`.

### D. CHANGELOG

10. **Promote `[Unreleased]`.** WHERE: `CHANGELOG.md` lines 8–9.
    HOW: rename `## [Unreleased]` to `## [1.5.0.0] - 2026-05-30` and add a fresh empty
    `## [Unreleased]` above it. Populate `[1.5.0.0]` with the shipped work (these are the
    commits, summarized from HANDOFF): Pipeline Builder backend (Hub-Workflows.ps1,
    Hub-WorkflowEngine.ps1 — workflow CRUD, schema validation, cycle detection, run state
    machine, template substitution, SSE step events, kill, interrupted-run recovery); Workflow
    UI (Catalog/Workflows/History tabs, run view, Ctrl+K palette); Triggers (cron + file-watch,
    Hub-Triggers.ps1); Git catalogs (clone/pull, https-only, Hub-Git.ps1); Run history
    (JSON-lines + CSV export, Hub-History.ps1); visual canvas workflow editor
    (wwwroot/canvas-editor.js — drag-and-drop nodes, bezier edges, pan/zoom, topo-sort to steps).
    Add a `### Added` for `-SkipMutex` test flag.
11. **Fix the bottom link-reference block.** WHERE: `CHANGELOG.md` lines 104–105.
    HOW: add `[1.5.0.0]: .../releases/tag/v1.5.0.0` and re-point
    `[Unreleased]: .../compare/v1.5.0...HEAD`. This is the easiest line to miss.
    VERIFY: no broken reference links; `[1.5.0.0]` resolves.

### E. Version pins in README + installer

12. **README one-liner + URLs.** WHERE: `README.md` lines 24, 30, 35, 58, 64.
    HOW: replace `v1.4.13.0` → `v1.5.0.0` in the install one-liner, the `-Version` example,
    the offline `-Version` reference, the flags-table default, and the `-Update` one-liner.
    VERIFY: grep README for `1.4.13` → no matches.
13. **Installer default + URLs.** WHERE: `install-hub.ps1` line 47 (`$Version = 'v1.4.13.0'`),
    lines 8 & 26 (help/comment one-liner URLs), line 212 (rate-limit guidance string).
    HOW: `v1.4.13.0` → `v1.5.0.0`. NOTE: installer uses the **`v`-prefixed tag**; build scripts
    use the **four-part** `1.5.0.0`. Don't cross them.
    VERIFY: grep installer for `1.4.13` → no matches.

### F. Build + release

14. **Pre-release commit.** Commit steps A–E on a branch (we're on `main`; branch first per
    project rules) so the working tree is clean except for the installer that build-release.ps1
    will patch. Do not commit `Co-Authored-By` (project rule #2078 — settings.json attribution
    not enabled).
15. **Dry-run build + full smoke against the new exe.** WHERE: repo root.
    HOW: `pwsh -File build-hub.ps1 -Version 1.5.0.0` (kills running Hub.exe, parse-checks,
    compiles, runs `smoke-final.ps1` against the fresh binary). Then run the four
    now-`-SkipMutex` tests **against the freshly built exe** (start it, or just run them on 8799).
    VERIFY: `smoke-final.ps1` PASS; the four tests PASS; `smoke-canvas-editor.ps1` still PASS.
16. **Cut the release.** HOW: `pwsh -File build-release.ps1 -Version 1.5.0.0 -Tag v1.5.0.0 -Publish`
    (the explicit `-Tag` is REQUIRED — see ADV-001; the default derivation would produce the wrong `v1.5.0`).
    This re-runs build-hub.ps1, stages Hub.exe + Hub.ico + README + wwwroot + the five
    `Hub-*.ps1` modules, zips, SHA256-patches `install-hub.ps1`, then (with `-Publish`)
    commits the patched installer, tags `v1.5.0`, pushes, and `gh release create`s with
    CHANGELOG.md as notes. Tag derives from Version by stripping trailing `.0` → `v1.5.0`.
    VERIFY: `gh release view v1.5.0` shows the asset; installer one-liner from the new tag
    installs and `/api/workflows` returns 200 (not 503).

> **Sequencing note:** `build-release.ps1` already calls `build-hub.ps1` internally (line 73),
> which itself kills Hub.exe and runs `smoke-final`. So step 15 is the "validate before
> publishing" pass; step 16 rebuilds once more as part of the gated release. Treat the
> **release artifact from step 16** as the single source of truth — not two separate binaries.

## Backend vs frontend split (which steps need an exe rebuild)

- **Requires exe rebuild to be user-visible:** every Hub.ps1 change — the `-SkipMutex` param
  (A), and the `$Script:Version` bump (C8). The route table that returns 503 for `/api/workflows`
  is baked into the binary; until step 15/16 recompiles, end users keep hitting the old routes.
  This is the entire reason Phase 0 exists.
- **Frontend (no rebuild, served live from `wwwroot/`):** the `.hub-version` chip is static HTML
  reading a value from the API, so it auto-reflects the new `$Script:Version` once the exe is
  rebuilt — no separate frontend edit needed. No `wwwroot/` files change in this phase.
- **No rebuild needed:** test edits (B), CHANGELOG (D), README/installer pins (E) — these are
  dev/docs artifacts. Note the five `Hub-*.ps1` feature modules are **dot-sourced from disk** at
  runtime (build-release.ps1 ships them beside the exe), so their logic is already live in the
  shipped install — only the **embedded route table** in Hub.exe is stale.

## Testing & verification (smoke tests to add/update under tests/)

- **Updated:** `smoke-installer-phase1.ps1`, `smoke-phase2-engine.ps1`, `smoke-phases456.ps1`,
  `smoke-phase3-ui.ps1` — parametrized port + `-SkipMutex` (steps 4–7). Each must PASS while
  Hub.exe is running AND when it is closed.
- **Unchanged but must still PASS:** `smoke-final.ps1` (build-hub.ps1's own post-build smoke —
  it kills Hub.exe and drives the fresh binary, no `-SkipMutex` needed), `smoke-canvas-editor.ps1`.
- **New assertion to fold into one test (no new file):** in `smoke-phase2-engine.ps1` (or
  `smoke-phase3-ui.ps1`), add a check that `GET /api/version` on the test port returns
  `1.5.0.0` — this is the regression guard proving the rebuilt binary, not the stale one,
  answered. Also assert `GET /api/workflows` returns 200 (the 503-regression guard).
- **Cleanup:** ensure each test deletes the workflows/runs it creates (see Risks) — fold a
  `DELETE`/cleanup pass into the `finally` block so a shared `%LOCALAPPDATA%\Hub\` isn't polluted.

## Risks & mitigations

1. **`-SkipMutex` alone is insufficient (port collision).** The test instance would bind/poll
   8765 and silently drive the OLD Hub.exe. → Step B: dedicated port 8799 + derive base URL from it.
2. **`Initialize-HubPort` hint-first behavior.** It tries `%TEMP%\hub.port` before the requested
   port. → Choose 8799 (outside Hub.exe's 8765 + fallback band); the busy hint is skipped to
   `Preferred`. Documented as the chosen option in step 7; a hard-bind change is explicitly out of scope.
3. **`Save-PortHint` clobbers `%TEMP%\hub.port`.** A test instance overwrites the hint Hub.exe
   wrote, so `smoke-final.ps1 Get-HubPort` and the live Hub's "focus existing instance" may target
   the wrong port afterward. → Minor/transient (next real Hub start re-writes it); note it. Optional:
   tests could restore the prior hub.port in their `finally`.
4. **Shared `%LOCALAPPDATA%\Hub\` state (material).** The mutex implicitly prevented two instances
   sharing workflows/runs/history. Running tests beside live Hub.exe means: (a) test workflows
   (`smoke-two-step`, `smoke-slow`) land in the LIVE Hub's list → user-visible pollution; (b) sharper —
   **interrupted-run recovery at test startup scans the shared `workflow-runs\` dir and will mark any
   live in-flight run as `interrupted`** (low probability, high impact — corrupts real run state).
   → Mitigations: run the suite only when no real workflow is executing; have each test delete the
   workflows/runs it creates (finally block). State this constraint in test headers.
5. **PS5/PS7 compat regression.** Any new test/Hub.ps1 syntax must avoid PS6+ constructs.
   → build-hub.ps1 parse-check + run tests under both `powershell.exe` and `pwsh`.
6. **Release script preconditions.** Dirty tree (besides installer) or pre-existing `v1.5.0` tag
   aborts `-Publish` (build-release.ps1 lines 154–167). → Land Phase 0 commit first; confirm
   `git tag --list v1.5.0` is empty before publishing.
7. **PS2EXE / gh missing.** → Verified as prerequisites; build-hub.ps1 and build-release.ps1 both
   fail fast with guidance if absent.

## Rollback plan

- **Pre-publish (steps A–E, 14–15):** all changes are in a feature branch + a local `Hub.exe`
  rebuild. Rollback = `git checkout .` / delete the branch; restore the prior `Hub.exe` from the
  last release artifact (or rebuild at `-Version 1.4.13.0`).
- **Post-publish (step 16):** if the release is bad, `gh release delete v1.5.0 --yes`,
  `git push origin :refs/tags/v1.5.0`, `git tag -d v1.5.0`, revert the installer-hash commit.
  Existing users are unaffected until they manually adopt the new tag (installer is tag-pinned),
  so a bad release does not auto-propagate. Re-pin README/installer back to `v1.4.13.0` if needed.
- The `-SkipMutex` flag and test edits are independently revertable from the release; reverting
  the release does not require reverting them.

## Definition of Done

- [ ] `Hub.ps1` accepts `-SkipMutex`; with it set, a second instance boots beside a live Hub.exe
      on an alternate port; without it, single-instance behavior is unchanged.
- [ ] `$Script:Version` = `1.5.0.0`; `/api/version` and the UI chip both report `v1.5.0.0`.
- [ ] All four previously-failing smoke tests PASS **both** while Hub.exe runs (via `-SkipMutex
      -Port 8799`) and when it is closed; `smoke-final.ps1` and `smoke-canvas-editor.ps1` still PASS.
- [ ] A smoke assertion confirms `GET /api/workflows` returns 200 (not 503) and `/api/version` is
      `1.5.0.0` against the rebuilt binary.
- [ ] `Hub.exe` rebuilt at file-version `1.5.0.0`; `build-release.ps1 -Version 1.5.0.0 -Tag v1.5.0.0 -Publish`
      produces a **`v1.5.0.0`** GitHub release (tag matches README/installer pins — see ADV-001) with
      `Hub.zip` (exe + ico + README + wwwroot + five `Hub-*.ps1` modules) and the SHA256-patched installer committed.
- [ ] `CHANGELOG.md` has a populated `[1.5.0.0] - 2026-05-30` section, a fresh empty `[Unreleased]`,
      and corrected bottom link-reference lines.
- [ ] README + `install-hub.ps1` contain no `1.4.13` references; install one-liner points at `v1.5.0.0`.
- [ ] Installing from the new tag yields a working Hub where the Workflows/History tabs and canvas
      editor function end-to-end (route table no longer stale).
