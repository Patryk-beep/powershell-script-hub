# Plan: Pipeline Builder + Shared Team Catalog (A+B Hybrid)

**Status**: Approved — hardened after adversarial review
**Approved**: 2026-05-28
**Hardened**: 2026-05-28 (ADV-001 through ADV-011 + ADV2-001 through ADV2-006 addressed)
**Scope**: Turn Hub from a single-script runner into a workflow engine with Git-backed shared catalogs

## Goal

Users can chain scripts into reusable pipelines (output A → input B), schedule them, and share both scripts and workflows via Git repositories as scan roots.

## Architecture Constraints

- PowerShell backend, Alpine.js frontend — no new runtimes
- Workflows stored as `.hub-workflow.json` files (portable, shareable)
- Git integration is optional — Hub works fully offline, Git adds sharing
- No breaking changes to existing catalog/runner behavior
- All new API mutation routes added to `$Script:StateRoutes` (CSRF-gated) — see Phase 1
- New workflow code lives in `Hub-Workflows.ps1` / `Hub-Triggers.ps1` / `Hub-Git.ps1` / `Hub-History.ps1` (all dot-sourced by Hub.ps1) — Hub.ps1 must not grow further (ADV-007)
- Workflow execution engine is a state machine driven by `Step-Jobs` — never a blocking call on the request thread (ADV-001)

## Template Substitution Spec (ADV-002)

`{{step-N.stdout}}` and `{{step-N.exitCode}}` resolve in params values only:

- Substitution happens on the **values map** before `Build-Argv` is called — the resolved value is treated as a typed param value, never as a flag name, script path, or raw argv fragment
- `{{step-N.stdout}}` resolves to the **last non-empty line** of that step's stdout (ADV-008)
- `{{step-N.stdout.all}}` resolves to full stdout joined with newlines (explicitly opt-in for verbose cases)
- `{{step-N.exitCode}}` resolves to the integer exit code as a string
- **Empty stdout handling (ADV2-002)**: if step-N produced no output and a required param uses `{{step-N.stdout}}`, the step fails immediately before spawning with `error: 'empty-stdout-template'` — it does not pass an empty string through. If the param is optional, an empty resolution omits the param entirely.
- Templates in `scriptId` fields are **prohibited** — validator rejects them at CREATE time
- Resolved values receive the same type validation the schema enforces for that param

## Phases

### Phase 0: Modularization (prerequisite)
**Goal**: Extract workflow code to a new file before adding any of it.

1. Create `Hub-Workflows.ps1` (dot-sourced at Hub.ps1 startup after `$Script:` globals are set)
2. Phases 1–2 functions live in `Hub-Workflows.ps1` (CRUD + state machine)
3. Phase 4 trigger/scheduler functions live in `Hub-Triggers.ps1` — separate file to stay within the 500-line cap (ADV2-006)
4. Git operations (Phase 5) live in `Hub-Git.ps1` (dot-sourced the same way)
5. History logger (Phase 6) lives in `Hub-History.ps1`
6. Each new file must stay under 500 lines
7. **Dot-source insertion point (ADV2-003)**: add the four dot-source lines at Hub.ps1 line ~80 — after all `$Script:` global assignments (lines 21–77) and before the first `function` definition. This guarantees `$Script:ConfigDir` and peers are set before any workflow function runs.

**Files touched**: Hub.ps1 (4 dot-source lines at ~line 80), new files created
**Tests**: Existing smoke tests must pass unchanged after dot-source wiring

---

### Phase 1: Workflow Data Model & Storage
**Goal**: Define and persist workflows without UI yet.

#### Workflow JSON Schema

```json
{
  "id": "wf-<uuid>",
  "name": "Daily Cleanup",
  "version": 1,
  "steps": [
    {
      "id": "step-1",
      "scriptId": "C:/Scripts/cleanup.ps1",
      "params": { "Path": "C:/Temp" },
      "onSuccess": "step-2",
      "onFailure": "stop"
    },
    {
      "id": "step-2",
      "scriptId": "C:/Scripts/report.ps1",
      "params": { "Input": "{{step-1.stdout}}" }
    }
  ],
  "trigger": { "type": "manual" }
}
```

**Schema validation rules (enforced at CREATE/UPDATE):**
- `steps` must be a non-empty array
- Each step `id` must be unique within the workflow
- `scriptId` must not contain `{{` — templates in script paths are forbidden (ADV-002)
- `onSuccess` / `onFailure` targets must reference existing step IDs or the literals `"stop"` / `"next"`
- Step graph must be acyclic — validate by tracing all `onSuccess`/`onFailure` chains for cycles (ADV-009)
- Templates in `params` values are allowed; templates in `params` keys are forbidden

#### Storage

- Workflows persist to `%LOCALAPPDATA%\Hub\workflows\<id>.json`
- Writes use atomic temp-file-rename pattern: write to `<id>.tmp` → rename to `<id>.json` (ADV write safety)
- `$Script:Workflows` = `[hashtable]::Synchronized(@{})` — loaded at startup, kept in sync with disk

#### CSRF-Gated Routes (ADV-003)

Add to `$Script:StateRoutes` before any route handler is registered:

```powershell
'/api/workflows',               # POST (create/update)
'/api/workflows/.+?',           # DELETE (by id) — also covers PUT
'/api/workflows/.+?/run',       # POST (trigger run)
'/api/workflow-runs/.+?/kill'   # POST (kill run)
```

Read-only routes (`GET /api/workflows`, `GET /api/workflows/:id`, `GET /api/workflows/:id/runs`, `GET /api/workflow-runs/:runId`) do NOT go in StateRoutes — they follow the same pattern as `/api/items` and `/api/config`.

#### API Routes

- `GET /api/workflows` — list all workflows
- `GET /api/workflows/:id` — get workflow detail
- `POST /api/workflows` — create/update workflow (CSRF-gated)
- `DELETE /api/workflows/:id` — delete workflow (CSRF-gated)

**Files touched**: `Hub-Workflows.ps1` (new), Hub.ps1 (dot-source + StateRoutes additions), new test fixtures
**Risk**: Cycle detection algorithm must handle branching (one step can have both `onSuccess` and `onFailure` targets)
**Tests**: CRUD smoke tests, malformed JSON rejection, cycle detection rejection, template-in-scriptId rejection

---

### Phase 2: Workflow Execution Engine
**Goal**: Run a workflow as a sequence of jobs, piping data between steps.

#### Execution Model: State Machine via Step-Jobs (ADV-001)

`Start-HubWorkflow` creates a run record and returns immediately — it does NOT wait for steps to complete. Step advancement is driven by `Step-Jobs` on each pump tick.

**Workflow run record** (stored in `$Script:WorkflowRuns`):

```powershell
@{
  runId         = <uuid>
  workflowId    = <id>
  status        = 'running'   # running | done | failed | killed
  currentStepId = 'step-1'
  stepOutputs   = @{}         # stepId → @{ stdout = <last-line>; stdoutAll = <all>; exitCode = 0 }
  childJobIds   = @()         # all job IDs spawned by this run (for cleanup)
  currentJobId  = $null       # job ID of the active step
  startedAt     = <DateTime>
  endedAt       = $null
  subscribers   = [List]      # SSE subscribers for this run's stream
}
```

**Step-Jobs advancement** (added to `Step-Jobs` pump):

```
For each WorkflowRun with status = 'running':
  currentJob = $Script:Jobs[run.currentJobId]
  if currentJob is terminal (done/failed/killed):
    capture stepOutputs[currentStepId] from currentJob.buffer (last non-empty line + full buffer)
    resolve next step via onSuccess/onFailure routing
    if nextStepId = 'stop' or no more steps:
      mark run done/failed, fire SSE 'end' frame, persist run completion
    else:
      resolve step's params (substitute {{...}} templates from stepOutputs)
      validate resolved paths (all steps' scriptIds validated at RUN start — not per step, ADV-011)
      start next step's job via Start-HubJob with workflowRunId tag
      update run.currentStepId, run.currentJobId
      fire SSE 'step-start' frame to run subscribers
```

#### Child Job Tagging (ADV-006)

`Start-HubJob` gains an optional `-WorkflowRunId` parameter. Tagged jobs:
- Are excluded from the LRU count (`Invoke-JobSweep` skips them for LRU eviction)
- Have TTL reduced to 5 min post-completion (instead of 30 min) — swept by a workflow-aware sweep pass
- Are bulk-swept when their parent workflow run is swept

#### Path Pre-validation (ADV-011)

When `POST /api/workflows/:id/run` is received:
1. Resolve and validate ALL step `scriptId` paths against current scan roots (one `Get-HubItems` call)
2. Cache the `itemId → resolvedPath` map in the run record
3. Step execution uses cached paths — no per-step catalog rescan

#### Template Substitution (ADV-002)

Template resolution applies the spec in the "Template Substitution Spec" section above. Resolution happens just before `Build-Argv` for each step, using `run.stepOutputs` accumulated so far. A template referencing a step that hasn't run yet (`{{step-5.stdout}}` in step-2) is a validation error caught at CREATE time.

#### SSE Stream for Workflow Runs (ADV-010)

`GET /api/workflow-runs/:runId/stream` — SSE with:
- `step-start` event: `{ stepId, stepIndex, totalSteps }`
- `line` event: same format as job log stream (proxied from the active child job)
- `step-end` event: `{ stepId, exitCode, status, routedTo }`
- `end` event: `{ status, exitCode }` (final)
- `: keepalive` comment frame emitted every 15 seconds when no other frame sent (ADV-010)

#### CSRF-Gated Routes (Phase 2 additions — already in StateRoutes from Phase 1)

- `POST /api/workflows/:id/run` (CSRF-gated)
- `POST /api/workflow-runs/:runId/kill` (CSRF-gated)

#### Kill Behavior

`POST /api/workflow-runs/:runId/kill`:
- Marks run as `killed`
- If `currentJobId` is set and the job is running: calls `Stop-JobTree` on that job's PID
- If between steps (no active job): marks run killed immediately, no job to kill
- All remaining steps are skipped

#### Per-Run Error Isolation (ADV2-001)

The try/catch wraps **each individual run's advancement** inside the `foreach WorkflowRun` loop — not the loop itself. If Run A's advancement throws, it is marked `failed` with `error: 'engine-error'` and its SSE subscribers receive an `end` frame. The loop continues to Run B on the same tick. A single bad run cannot stall or lose other runs.

#### Run Record Persistence (ADV2-004)

Workflow run records are persisted at key transitions to `%LOCALAPPDATA%\Hub\workflow-runs\<runId>.json`:
- Written (atomic temp-rename) when: run starts, each step starts, each step ends, run ends
- On Hub startup: any `endedAt: null` run record is loaded and marked `status: 'interrupted'` — surfaced in the run history UI and Phase 6 history log
- This prevents Hub crashes silently dropping in-progress runs with no trace

**Files touched**: `Hub-Workflows.ps1` (engine), Hub.ps1 (Step-Jobs extension), app.js (SSE consumption)
**Risk**: Run record persistence adds a disk write per step transition — keep writes async-safe within the single-threaded pump (they are, since all run state is on the main thread)
**Tests**: Multi-step workflow with pass/fail routing, parameter piping, kill mid-step, kill between steps, zero-step workflow rejection (caught at Phase 1 validation), interrupted-run recovery on restart

---

### Phase 3: Workflow UI
**Goal**: Users can create, edit, and monitor workflows in the dashboard.

1. Add "Workflows" tab/section to the sidebar (alongside catalog)
2. Workflow list view: name, step count, last run status, trigger type
3. Workflow editor:
   - Step list (add/remove/reorder)
   - Per-step: pick script from catalog, configure params via existing form renderer
   - Parameter piping: dropdown to reference prior step outputs (shows `{{step-N.stdout}}` / `{{step-N.stdout.all}}`)
   - Template-in-scriptId is blocked in the UI picker (not a free-text field)
   - Trigger config: manual only in this phase
4. Workflow run view:
   - Step progress indicator (pending → running → passed/failed)
   - Click a step to see its log stream (reuse existing log pane)
   - Kill button for the whole workflow
5. Ctrl+K palette includes workflow names

**Files touched**: index.html, app.js, style.css
**Risk**: Editor UX complexity — keep it list-based, not a visual DAG (simpler to build, works on all screens)
**Tests**: UI smoke tests for workflow CRUD + run monitoring

---

### Phase 4: Triggers & Scheduling
**Goal**: Workflows can run on schedule or in response to events.

#### Cron Triggers

1. Add `cron` trigger type to workflow schema: `{ "type": "cron", "expression": "0 8 * * 1-5" }`
2. Cron scheduler runs in `Step-Jobs` pump (every 60s — gated by timestamp, not every tick)
3. Last-run timestamp **persisted** to `%LOCALAPPDATA%\Hub\workflows\<id>.state.json` (ADV-005):
   ```json
   { "lastRunAt": "2026-05-28T08:00:00.000Z", "nextRunAt": "2026-05-29T08:00:00.000Z" }
   ```
4. On Hub startup, state files are loaded alongside workflow files — no double-fire after restart
5. Trigger status shown in workflow list (next scheduled run time)

#### File-Watch Triggers

1. `FileSystemWatcher` on configured paths
2. Debounce: 5s after last event before firing
3. **Limitation documented**: `FileSystemWatcher` does not work on UNC/network paths — Hub warns at config time if the watch path is a network path (ADV-007 related: surfaces known limitation)
4. Tray notification on scheduled workflow completion (pass/fail)

**Files touched**: `Hub-Triggers.ps1` (new), Hub.ps1 (dot-source addition), app.js (trigger config UI)
**Tests**: Cron parsing, file-watch debounce, scheduler tick behavior, restart-no-double-fire

---

### Phase 5: Git-Backed Shared Catalogs
**Goal**: Teams share scripts and workflows via Git repos.

#### URL Security (ADV-004)

Git scan root URLs must pass validation before being accepted:
- Scheme must be `https://` — `file://`, `git://`, `ssh://`, and bare paths are rejected with a clear error
- URL must parse as a valid URI with a non-empty host
- UI shows an explicit trust warning: "Scripts in this repository will appear in your Hub catalog. Only add repositories you trust."

#### Storage & Discovery

1. Git repos use a **separate top-level config key `gitRoots`** — not mixed into `scanRoots` (ADV2-005). This keeps the existing `Invoke-SetupRoute` string-only validation path untouched and prevents type-confusion bugs:
   ```json
   {
     "scanRoots": ["C:/MyScripts"],
     "gitRoots": [
       { "url": "https://github.com/team/scripts.git", "branch": "main" }
     ]
   }
   ```
2. A new `Invoke-GitRootsSetupRoute` (`POST /api/git-roots`, CSRF-gated, added to `$Script:StateRoutes`) handles `gitRoots` separately from the existing `/api/setup` route
3. On refresh (or configurable interval), `git clone` / `git pull` into `%LOCALAPPDATA%\Hub\repos\<url-hash>\`
4. The repos dir is **not** added as a local scan root — only the Git root type accesses it (prevents local scan root overlap)
4. Git scan roots are **read-only** in Hub (no editing remote scripts)
5. `git pull` failure shows a persistent warning badge on the affected catalog section ("Stale — last synced 3 days ago") — not a silent failure (ADV error propagation)
6. Setup wizard gains "Add Git Repository" option with URL + branch + optional credential helper
7. Workflow `.hub-workflow.json` files in Git repos are discovered and shown as "Shared Workflows"
8. Visual distinction in catalog: local scripts vs. shared (Git) scripts (badge/icon)

**Files touched**: `Hub-Git.ps1` (new), Hub.ps1 (dot-source + `'/api/git-roots'` added to StateRoutes), app.js (setup wizard), index.html
**Risk**: Git must be installed and on PATH. Auth for private repos (credential manager integration). Clone size limits.
**Mitigation**: Detect `git.exe` at startup, warn if missing. Shallow clone (`--depth 1`). Document credential setup.
**Tests**: Git URL scheme validation (https accepted, file/ssh rejected), clone/pull behavior, read-only enforcement, stale-sync warning

---

### Phase 6: Run History & Export
**Goal**: Persistent run history for auditability and team visibility.

1. Log every run (single script + workflow) to `%LOCALAPPDATA%\Hub\history\`
   - JSON-lines format: timestamp, script/workflow ID, params, exit code, duration
   - Retain last 500 runs (configurable), rotate old entries
   - Rotation is done atomically: read, slice, write to temp, rename (no partial writes)
2. Add `GET /api/history` endpoint with pagination + filters (script, status, date range)
3. History tab in UI: searchable table with status, duration, re-run button
4. Export to CSV for team reporting
5. Workflow runs show full step-by-step history with expandable logs

**Files touched**: `Hub-History.ps1` (new), Hub.ps1 (dot-source), app.js + index.html (history UI)
**Risk**: Log file growth — enforce rotation. Don't store full stdout in history (just exit code + summary).
**Tests**: History write/read/rotate, CSV export format, concurrent-write safety (single-threaded pump guarantees ordering)

---

## Implementation Order

```
Phase 0 (modularize) → Phase 1 (data model) → Phase 2 (engine) → Phase 3 (UI)
    → Phase 4 (triggers) → Phase 5 (Git) → Phase 6 (history)
```

Phases 0–3 form the MVP: users can build and run workflows.
Phases 4–6 are enhancements that can ship incrementally.

## New Files

| File | Purpose | Max Lines |
|------|---------|-----------|
| `Hub-Workflows.ps1` | Workflow CRUD, execution engine, state machine (Phases 1–2) | 500 |
| `Hub-Triggers.ps1` | Cron scheduler, file-watch triggers, last-run persistence (Phase 4) | 500 |
| `Hub-Git.ps1` | Git scan root clone/pull operations, `gitRoots` config (Phase 5) | 500 |
| `Hub-History.ps1` | Run history logger and rotation (Phase 6) | 500 |

## Success Criteria

- [ ] User can create a 3-step workflow in the UI
- [ ] Workflow runs with parameter piping between steps
- [ ] Failed step routes correctly (stop or skip to alternate)
- [ ] Kill during a step and kill between steps both work correctly
- [ ] Cyclic step graphs are rejected at create time
- [ ] Cron-scheduled workflow fires on time and does NOT double-fire after Hub restart
- [ ] Git repo appears as read-only scan root — `file://` and `ssh://` URLs are rejected
- [ ] `git pull` failure shows a stale-sync warning (not silent)
- [ ] Run history persists across Hub restarts
- [ ] All existing smoke tests still pass (no regressions)
- [ ] Workflow JSON files can be copied between machines and just work
- [ ] Hub UI and API remain responsive during long-running multi-step workflows
