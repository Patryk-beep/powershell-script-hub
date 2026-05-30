# Hub Roadmap — Phased Implementation Plans (v1.5 → v1.9)

Master index for the phased build-out brainstormed 2026-05-30. Each phase has its own
detailed `rune:plan`-style document. Ordering is **dependency-driven**, not impact-driven.

## Ordering rules (why the sequence is what it is)
1. **Backend/route changes are invisible until `Hub.exe` is rebuilt** → backend work batches into release milestones.
2. **Frontend-only changes (`wwwroot\`) take effect from disk** → can ship continuously, no rebuild.
3. **Signing precedes winget**; **presets precede the vault** (shared param-injection path); **engine stability precedes the control-flow overhaul**.

## Critical path (one line)
`-SkipMutex → rebuild exe (v1.5) → [frontend polish] → presets/argv/logs (v1.6) → adversary → secrets vault (v1.7) → signing → winget (v1.8) → control flow (v1.9)`

## The phases

| Phase | Target | Plan | Type | Load-bearing finding from planning |
|---|---|---|---|---|
| **0 — Unblock & ship** | v1.5.0.0 | [phase-0-ship-v1.5.0.0.md](phase-0-ship-v1.5.0.0.md) | release | `-SkipMutex` alone does NOT fix the tests — `Initialize-HubPort` reads the `%TEMP%\hub.port` hint first, so test instances must also pin a dedicated port (8799). Shared `%LOCALAPPDATA%\Hub\` means a test run can mark a *live* workflow run `interrupted`. Two version sources must agree (`$Script:Version` + PS2EXE file version). |
| **1 — Finish-the-job polish** | v1.5.x (frontend) | [phase-1-frontend-polish.md](phase-1-frontend-polish.md) | frontend-only | All three items ship with **no exe rebuild** (served from disk). New logic goes in new mixin files (`canvas-polish.js`, `hub-notify.js`) because `canvas-editor.js` is already 497 lines. Pins/recents must use localStorage — the running 1.4.13 binary 503s any new route. Workflow runs poll (not SSE) — needs a parallel completion hook for toast parity. |
| **2 — Daily-driver power** | v1.6.0.0 | [phase-2-daily-driver-power.md](phase-2-daily-driver-power.md) | release | History logs only `itemId/exitCode/status/duration` — NOT params — so "re-run from history" is a real param-threading chain. Argv-preview reuses a shared `Resolve-RunPlan` helper so it can't drift from real `/api/run`. Every persistence boundary must redact `password` fields; ANSI rendering must HTML-escape first (XSS sink). |
| **3 — Secrets vault + export/import** | v1.7.0.0 | [phase-3-secrets-vault.md](phase-3-secrets-vault.md) | release | Step 0 is a gating `rune:adversary` review. `ProcessStartInfo.Arguments` means an argv-passed secret is visible in `Win32_Process.CommandLine` → must inject via **stdin/`-Command` shim** binding to `[securestring]`/`[pscredential]`. Full leak threat-model: argv, runs.jsonl, SSE, hub-error.log, export, browser. Exports carry secret *name references* only. |
| **4 — Trust & distribution** | v1.8.0.0 | [phase-4-trust-distribution.md](phase-4-trust-distribution.md) | release | Signing→winget→version-banner→doctor→portable, in that dependency order. EU individual can't use Azure Artifact Signing as an individual → branch to org-validation / OV cert / defer. `[version]` arity bug (4-part internal vs 3-part tag compares as "behind"). Hidden `%LOCALAPPDATA%` leak in `Get-HubCacheDir` breaks portable mode. |
| **5 — Deep capability** | v1.9.0.0 | [phase-5-deep-capability.md](phase-5-deep-capability.md) | release | Highest complexity. **foreach is sequential** (single-job-per-run pump) via an iteration-frame stack. `always` reuses success/failure routing; `paused` state the pump filter already skips; `.json.` refs degrade to empty on bad JSON. Fixes: `/kill` no-ops on paused runs; null `currentJobId` on pause to close a double-spawn window. Mandatory `rune:adversary` pass before code. |

## Cross-cutting notes
- **Adversary-before-implement** is a standing project rule (and a saved memory). Phases 3 and 5 bake in a gating `rune:adversary` review as their Step 0. Worth a pass on Phase 2's redaction logic too.
- **Smoke tests** boot `Hub.ps1` directly, so new routes are testable *before* the exe rebuild — the rebuild is a release/DoD step, not a test prerequisite (except Phase 0, which is about the rebuild itself).
- **One open judgment call:** if Hub will be shown to anyone before v1.7, pull **code signing (Phase 4)** forward to right after Phase 0 — SmartScreen ruins first impressions regardless of feature quality.

## Status
- [~] Phase 0 — v1.5.0.0 — **code complete + reviewed on branch `phase-0-ship-v1.5.0.0`** (5 commits; all 4 smoke tests pass; isolation verified; empty-`/api/history` bug fixed). **Blocked on:** `ps2exe` not installed → exe rebuild can't run. **Gated:** publish (`build-release.ps1 -Version 1.5.0.0 -Tag v1.5.0.0 -Publish`) awaiting user OK.
- [ ] Phase 1 — frontend polish
- [ ] Phase 2 — v1.6.0.0
- [ ] Phase 3 — v1.7.0.0
- [ ] Phase 4 — v1.8.0.0
- [ ] Phase 5 — v1.9.0.0
