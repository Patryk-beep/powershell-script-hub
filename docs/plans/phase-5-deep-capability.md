# Phase 5 — Deep capability: workflow control flow + structured outputs (target v1.9.0.0)

## Goal

Add four advanced capabilities to the workflow subsystem while preserving 100% backward
compatibility with existing saved workflows (which use only `success` edges, `onSuccess`/
`onFailure`/`next`/`stop` targets, and `{{step-sN.stdout}}` / `.stdout.all` / `.exitCode` refs):

1. **Conditional edge ports** — add `failure` and `always` output ports alongside `success`.
   Engine routes the next step by the upstream step's exit code (success = 0, failure = non-zero,
   always = either). Validators (port + DFS cycle detection) and canvas (render + color-code) updated.
2. **Manual approval / pause node** — a node type that pauses a run until the user acts. New
   CSRF-gated `POST /api/workflow-runs/:id/resume` route; run state machine gains a `paused` state;
   UI prompts approve/abort. Interrupted-run recovery must treat a `paused` run distinctly.
3. **Foreach node** — iterate over an upstream step's output (stdout lines OR a parsed JSON array)
   and run the downstream subgraph once per item. Realistic design given the **single-threaded,
   single-cursor `Step-Jobs` pump**: sequential iteration via an iteration-frame stack (NOT true
   concurrency), with a hard per-foreach item cap and result aggregation into the foreach step's output.
4. **Structured output refs** — extend template substitution so `{{step-sN.json.foo.bar}}` parses a
   step's stdout as JSON and resolves a dotted/indexed path, alongside existing `.stdout` refs.
   Degrades gracefully (resolves to empty string) when stdout is not valid JSON or the path is absent.

Backend changes require an exe rebuild → ships as **v1.9.0.0**. This is the highest-complexity phase;
the run state-machine changes in `Advance-WorkflowRuns` are the riskiest part.

---

## Dependencies / prerequisites

- Phases 0–4 shipped and stable (workflow CRUD, engine, triggers, git catalogs, history, canvas).
- Hub.exe must be rebuilt and re-released as part of this phase (the running binary's `Invoke-Route`
  table is compiled in; new routes will not work until rebuild). See HANDOFF.md known-issue #2.
- Smoke tests need Hub.exe **not** running OR the `-SkipMutex` flag (HANDOFF.md known-issue #1). This
  phase should add `-SkipMutex` to `Hub.ps1` first so the new smoke tests can run alongside the binary.
- No new runtime dependencies. PowerShell 5.1 and 7 must both work. All files stay under 500 lines —
  `Hub-WorkflowEngine.ps1` (currently ~306 lines) will grow; split out the resolution/foreach helpers
  into a new `Hub-WorkflowControl.ps1` if the engine would exceed ~480 lines after edits.

---

## Files touched (existing + new, absolute repo paths)

Existing (backend):
- `C:\Users\Harrold\Documents\Claude Projects\Hub\Hub-WorkflowEngine.ps1` — run state machine,
  `Resolve-StepParams`, `Advance-WorkflowRuns`, `Start-HubWorkflow`, new resume/route handlers.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\Hub-Workflows.ps1` — schema validation, `Test-WorkflowGraph`
  (DFS), new node-type validation (`pause`, `foreach`), new target field (`onAlways`).
- `C:\Users\Harrold\Documents\Claude Projects\Hub\Hub.ps1` — route registration for `/resume`, add
  `/api/workflow-runs/.+?/resume` to `$Script:StateRoutes`, add `-SkipMutex` switch.

Existing (frontend):
- `C:\Users\Harrold\Documents\Claude Projects\Hub\wwwroot\canvas-editor.js` — `PORT` offsets (add
  `failure`/`always`), `cnEdgeColor`, edge create from new ports, node-type metadata for pause/foreach,
  serialize new step fields in `cnSave`, auto-layout edge reconstruction for `always`.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\wwwroot\index.html` (or wherever the run view + Alpine
  template live) — pause approval banner + Resume/Abort buttons; foreach/pause node visual styling.
  Grep for `cnEdgeColor` / `wfSelected` / run-view markup to locate the exact template file.

New (backend, optional split):
- `C:\Users\Harrold\Documents\Claude Projects\Hub\Hub-WorkflowControl.ps1` — ONLY if engine exceeds
  ~480 lines: houses `Resolve-StepParams` (with JSON path), foreach frame helpers, pause helpers.
  Dot-source it from `Hub.ps1` immediately after `Hub-WorkflowEngine.ps1`.

New (tests):
- `C:\Users\Harrold\Documents\Claude Projects\Hub\tests\smoke-phase5-controlflow.ps1`
- `C:\Users\Harrold\Documents\Claude Projects\Hub\tests\fixtures\` — small `.ps1` fixtures that emit
  known stdout / JSON / chosen exit codes (e.g. `emit-json.ps1`, `exit-with.ps1`, `echo-arg.ps1`).

---

## Data model changes (additive, backward-compatible)

Step object (in `workflow.steps[]`) gains OPTIONAL fields. Existing steps omit them entirely:

```
{
  "id": "s3",
  "scriptId": "/path/foo.ps1",
  "type": "script" | "pause" | "foreach",   // absent ⇒ "script" (back-compat)
  "params": { ... },
  "onSuccess": "<stepId>|next|stop",          // existing
  "onFailure": "<stepId>|next|stop",          // existing
  "onAlways":  "<stepId>|next|stop",          // NEW — takes precedence over onSuccess/onFailure when set
  // foreach-only:
  "foreach": { "source": "s2", "as": "lines" | "json", "bodyStart": "s4", "maxItems": 100 }
  // pause-only:
  "pause": { "title": "Approve deploy?", "message": "..." }   // optional copy
}
```

Run record (`workflow-runs/<id>.json`) gains:
```
status: running | paused | done | failed | killed | interrupted   // NEW: paused
pausedStepId: "<stepId>"|null                                      // NEW
foreachFrames: [ { stepId, items[], index, bodyStart, returnTarget, results[] } ]  // NEW stack
```
`Save-WorkflowRun` already drops `subscribers`/`pathMap`; the new keys serialize fine via `-Depth 10`.

Canvas edge gains `fromPort: "always"` (already free-form string; existing edges keep `success`/`failure`).

---

## Implementation steps (numbered; each: what / where / how-to-verify)

### Item 0 — Plumbing: `-SkipMutex` + resume route registration

1. **Add `-SkipMutex` switch.** *Where:* `Hub.ps1` param block + the mutex acquisition block.
   *How:* guard the `Global\HubInstance.<username>` mutex acquisition with `if (-not $SkipMutex)`.
   *Verify:* `pwsh -File Hub.ps1 -Port 8799 -SkipMutex` starts a second instance while Hub.exe runs.

2. **Register resume route + state-route entry.** *Where:* `Hub.ps1` `$Script:StateRoutes` (line ~45)
   and the route dispatch block (line ~1977, before the bare `/api/workflow-runs/([^/]+)$` catch so the
   more specific pattern matches first). Add `'/api/workflow-runs/.+?/resume'` to `$Script:StateRoutes`
   and `if ($path -match '^/api/workflow-runs/([^/]+)/resume$') { Invoke-WorkflowRunResumeRoute ...; return $true }`.
   *Verify:* `POST` without CSRF header → 403; with header to unknown run → 404.

### Item 1 — Conditional edge ports (`failure` / `always`)

3. **Engine routing: add `onAlways`.** *Where:* `Hub-WorkflowEngine.ps1` `Advance-WorkflowRuns`, the
   block at lines ~162–178 that picks `$rf = onSuccess|onFailure`. *How:* before choosing by status,
   check `if ($step.ContainsKey('onAlways')) { $target = [string]$step['onAlways'] } else { <existing
   onSuccess/onFailure logic> }`. Keep `'next'`/`'stop'`/`$null` resolution identical. This is the ONLY
   change needed for `always` routing — `always` is just "route regardless of exit code."
   *Verify:* a step whose script exits non-zero with an `onAlways` target still advances to that target.

4. **Validator: accept `onAlways` targets.** *Where:* `Hub-Workflows.ps1` `Test-WorkflowSchema`,
   the `foreach ($field in @('onSuccess','onFailure'))` loop (~line 217). Add `'onAlways'` to the field
   list so its target is validated against `$validTargets`.
   *Verify:* save a workflow with `onAlways: "s2"` → 200; with `onAlways: "s99"` → 422.

5. **DFS cycle detection: include `onAlways` edges.** *Where:* `Hub-Workflows.ps1` `Test-WorkflowGraph`,
   the `foreach ($field in @('onSuccess','onFailure'))` adjacency loop (~line 110). Add `'onAlways'`.
   *How-to-verify:* a workflow where `s1.onAlways = s2` and `s2.onSuccess = s1` → 422 cycle error.

6. **Canvas: render `failure` + `always` ports.** *Where:* `canvas-editor.js` `PORT` map (~line 57).
   `failure` already exists; add `always: (n) => ({ x: n.x + NODE_W, y: n.y + NODE_H * 0.85 })` and shift
   the three output ports to thirds/quarters so they don't overlap. Update the node markup (in the
   Alpine template) to render an `always` port div with `data-port="always"`.
   *Verify:* three output ports visible on a node; dragging from each starts an edge.

7. **Canvas: color-code edges + serialize `onAlways`.** *Where:* `canvas-editor.js` `cnEdgeColor`
   (~line 244) and `cnSave` (~line 454). *How:* `cnEdgeColor` returns green/`#4ec588` for success,
   red/`#e8546a` for failure, amber/`#e0a64a` for `always`. In `cnSave`, after computing `succId`/`failId`,
   add `const alwaysId = edgeMap[\`${node.id}:always\`]; if (alwaysId && nodeById[alwaysId]) step.onAlways = nodeById[alwaysId].stepId;`.
   Reconstruct `always` edges in `cnOpenWorkflow` auto-layout by adding `'onAlways'` to the `['onSuccess','onFailure']`
   loop (~line 150) mapping `field === 'onAlways' ? 'always' : ...`.
   *Verify:* draw an always edge, save, reload → amber edge reappears; saved JSON has `onAlways`.

### Item 2 — Manual approval / pause node

8. **Schema: validate `type: "pause"`.** *Where:* `Hub-Workflows.ps1` `Test-WorkflowSchema` per-step loop.
   *How:* a `pause` step must NOT have a `scriptId` requirement — relax the `missing scriptId` check so
   it only fires for `type` absent/`"script"`/`"foreach"`. A `pause` step MAY have `onSuccess`/`onAlways`
   (route after resume). `foreach`/`type` field added to `$validTargets`-style allowlist: `type` must be
   one of `script|pause|foreach`.
   *Verify:* save a pause node with no scriptId → 200; an unknown `type: "fork"` → 422.

9. **Engine: enter `paused` state instead of spawning.** *Where:* `Hub-WorkflowEngine.ps1`
   `Start-HubWorkflow` (first step) AND `Advance-WorkflowRuns` (next step). *How:* factor the
   "spawn job for step X" logic into a helper `Step-Into ($run, $stepId)` that:
   (a) looks up the step; (b) if `type -eq 'pause'`: set `$run.status='paused'`, `$run.pausedStepId=$stepId`,
   `$run.currentStepId=$stepId`, **set `$run.currentJobId=$null`**, **do NOT call `Start-HubJob`**, fire
   SSE `step-pause` frame, `Save-WorkflowRun`, and return; (c) if `foreach`: see Item 3; (d) else spawn job.
   *(Why null the job id: it closes a double-spawn window at the resume transition — see step 10. The
   moment `/resume` flips `status` back to `running`, if the pump were to observe a stale `currentJobId`
   pointing at the already-`done` pre-pause job, it would route forward independently and double-spawn.
   Nulling on pause-enter makes that impossible regardless of the HttpListener/pump threading model.)*
   `Advance-WorkflowRuns` skips runs whose `status -ne 'running'`, so a `paused` run is naturally inert
   until resumed. **Critical:** the pump filter at line ~144 (`if ... status -ne 'running') { continue }`)
   already excludes paused runs — confirm no other code path advances them.
   *Verify:* run a workflow whose s1 is a pause node → run status becomes `paused`, no job spawned.

10. **Resume route.** *Where:* new `Invoke-WorkflowRunResumeRoute` in `Hub-WorkflowEngine.ps1`.
    *How:* POST only; 404 if run missing; if `status -ne 'paused'` → 409 `{error:'not-paused'}`.
    Accept optional body `{ action: "approve" | "abort" }` (default approve). On `abort`: set
    `status='killed'`, `endedAt`, `Close-RunSseSubscribers`, 200. On `approve`: set `status='running'`,
    then compute the post-pause target exactly like `Advance-WorkflowRuns` does (use the pause step's
    `onAlways`/`onSuccess`/`next`), and call `Step-Into` for that target (or finalize if no target).
    Then `Save-WorkflowRun`. *Backward-compat:* no existing workflow has pause nodes, so no run can be
    in `paused` until this ships. *Verify:* POST `/resume` to a paused run → status `running` then advances;
    POST again → 409.

11. **Interrupted-run recovery interaction.** *Where:* `Hub-WorkflowEngine.ps1` `Initialize-WorkflowRuns`
    (~line 30). *Decision:* a run that was `paused` at shutdown has no live process and no `endedAt`, so
    the current recovery code (`-not $run['endedAt']` → mark `interrupted`) WOULD wrongly mark it
    `interrupted`. *How:* add `if ($run['status'] -eq 'paused') { keep paused, re-register, DO NOT set endedAt }`
    branch BEFORE the interrupted branch. A paused run is resumable across restarts.
    *Verify:* pause a run, stop Hub, restart, GET the run → still `paused`; resume works.

12. **Make `/kill` work on a paused run.** *Where:* `Hub-WorkflowEngine.ps1`
    `Invoke-WorkflowRunKillRoute` (lines ~290–292). *Problem:* it early-returns for any
    `status -ne 'running'`, so the existing run-view **Kill button silently no-ops on a `paused` run** —
    the obvious UI control is dead. *How:* change the guard to allow `running` AND `paused` to proceed
    to kill. For a paused run there is no live job, so skip the `Stop-JobTree` block (it already guards
    on `$run.currentJobId`/`$job.pid`); just set `status='killed'`, `endedAt`, `Save-WorkflowRun`,
    `Close-RunSseSubscribers`, 200. *Verify:* pause a run, POST `/kill` → status `killed`; Kill button in
    the UI ends a paused run.

13. **UI: pause banner.** *Where:* run-view Alpine template + SSE handler. *How:* on SSE `step-pause`
    event (or when polled run `status==='paused'`), show a banner with the pause `title`/`message` and
    Approve / Abort buttons. Approve → `postJson('/api/workflow-runs/'+runId+'/resume', {action:'approve'})`;
    Abort → `{action:'abort'}`. Render pause nodes on canvas with a distinct icon/border.
    *Verify:* manual click-through pauses, prompts, and resumes a run end-to-end in the browser.

### Item 3 — Foreach node (sequential fan-out, single-cursor pump)

> **Realism note (single-threaded `Step-Jobs` pump).** The engine holds ONE `currentJobId` per run and
> advances ONE step per pump tick. True parallel fan-out (N concurrent child jobs per run) would require
> a multi-job-per-run model — a much larger rewrite and out of scope. Phase 5 implements **sequential
> iteration**: the foreach body subgraph runs once per item, items processed in order, one job at a time.
> Concurrency limit is therefore effectively 1 (documented as a known limitation; revisit in a later phase).

14. **Schema: validate `type: "foreach"`.** *Where:* `Test-WorkflowSchema`. *How:* require a `foreach`
    object with `source` (a prior stepId — enforce the same forward-reference rule as params),
    `as` ∈ `lines|json`, optional `bodyStart` (a stepId), `maxItems` (int, default 100, hard cap 1000).
    A foreach step has no `scriptId`. *Verify:* foreach with `source` pointing to a later step → 422.

15. **Foreach frame model + iteration.** *Where:* `Hub-WorkflowEngine.ps1` `Step-Into` + `Advance-WorkflowRuns`.
    *Current-item exposure — DECIDED (no signature change):* the body step references the current item via
    the existing `.stdout`/`.stdout.all` path. Before spawning the `bodyStart` job for an iteration, write
    a synthetic entry into the run's existing `stepOutputs` map under the **foreach step's own id**:
    `$run.stepOutputs[$foreachStepId] = @{ stdout = $item; stdoutAll = $item; exitCode = 0 }`. The body
    step then uses the normal token `{{step-<foreachStepId>.stdout}}` (e.g. `{{step-s2.stdout}}`) — resolved
    by the unchanged `Resolve-StepParams($Params, $StepOutputs)` signature. This reuses the existing
    resolution path, needs ZERO new token and ZERO signature change, and the forward-reference validator
    already accepts it (the foreach step precedes its body). Overwrite this entry each iteration; on frame
    pop, replace it with the aggregated foreach output (below). *(Rejected alternative: a `{{foreach.item}}`
    token would force a new parameter on `Resolve-StepParams` to pass the frame — avoided.)*
    *How (the core state-machine change):*
    - When `Step-Into` hits a `foreach` step: read the source step's output from `$run.stepOutputs[source]`.
      `as: lines` → split `stdoutAll` on `\r?\n`, drop empties. `as: json` → `ConvertFrom-Json` of
      `stdoutAll`; if not an array or parse fails → treat as zero items (graceful). Apply `maxItems`.
    - Push a frame onto `$run.foreachFrames`: `@{ stepId; items; index=0; bodyStart; returnTarget=<the
      foreach step's onSuccess/onAlways/next>; results=@() }`.
    - If `items.Count -eq 0`: pop frame immediately, route to `returnTarget`.
    - Else: write the synthetic current-item entry (above) for `items[0]`, then `Step-Into` the `bodyStart`
      step (spawns its job).
    - When a body step finishes and its routing yields `'next'`/`stop`/no target AT THE END of the body
      subgraph (detect: the just-finished step is the last body step, i.e. its computed target equals the
      foreach's `returnTarget` or `stop`), do NOT route forward; instead: append the body's terminal output
      to `frame.results`, `frame.index++`. If `index < items.Count`: overwrite the synthetic current-item
      entry with `items[index]` and re-enter `bodyStart` for the next item.
      Else: pop the frame, **overwrite** the foreach step's `stepOutputs[$foreachStepId]` with the
      AGGREGATED result `@{ stdout=<last result>; stdoutAll=<results joined by \n>; exitCode=0 }` (this
      replaces the per-item synthetic entry so downstream steps see the full aggregate), and route to
      `returnTarget`.
    - **Boundary detection** is the sharp edge: the body subgraph must have a well-defined exit. Simplest
      correct rule for v1.9.0.0: the foreach body is **the single `bodyStart` step only** (one step per
      iteration), and its `onSuccess`/`onAlways` is IGNORED during iteration (the frame controls routing).
      Multi-step bodies are explicitly OUT OF SCOPE for this phase (document in Rejection Criteria). This
      keeps the cursor model intact: foreach = "run step B once per item of step A's output, collect outputs."
    *Verify:* foreach over 3 stdout lines runs `bodyStart` 3 times; foreach `stepOutputs.stdoutAll` = 3
    joined results; exit non-zero on item 2 still continues (sequential, isolated) and records the result.

16. **Foreach + nesting / cycle safety.** *Where:* `Test-WorkflowGraph`. *How:* model a foreach step's
    edge to `bodyStart` and `bodyStart`'s implicit return to the foreach as a controlled loop that DFS
    must NOT flag as an illegal cycle — but a foreach whose `bodyStart` is itself (or transitively re-enters
    the same foreach) MUST be rejected. Add a dedicated check: `bodyStart` must differ from the foreach
    stepId and must not be another foreach in v1.9.0.0 (no nested foreach this phase).
    *Verify:* foreach with `bodyStart` == itself → 422; nested foreach → 422.

17. **Canvas: foreach node UI.** *Where:* `canvas-editor.js`. *How:* a foreach node has an extra input
    concept (the `source` step) — model `source` as a dedicated `data-port="foreach-source"` input or a
    side-panel dropdown listing prior steps; `bodyStart` as a dedicated output port `data-port="body"`.
    Serialize `step.foreach = { source, as, bodyStart, maxItems }` in `cnSave`. Render with a loop icon.
    *Verify:* build a foreach visually, save, reload, run → executes per item.

### Item 4 — Structured output refs `{{step-sN.json.foo.bar}}`

18. **Extend `Resolve-StepParams`.** *Where:* `Hub-WorkflowEngine.ps1` lines ~78–96. *How:* BEFORE the
    existing `.stdout.all`/`.stdout`/`.exitCode` replacements, add a regex pass for
    `\{\{step-(?<sid>[^.}]+)\.json\.(?<path>[^}]+)\}\}`. For each match: look up `$StepOutputs[$sid]`,
    parse its `stdoutAll` as JSON **once per step, cached** in a local hashtable to avoid re-parsing;
    walk the dotted path with support for array indices (`foo.0.bar` or `foo[0].bar` — pick `.0.`).
    Resolve to the value as a string (objects/arrays → compact JSON; scalars → `[string]`). On parse
    failure, missing key, or out-of-range index → replace with empty string (graceful degradation,
    matching the existing "empty values are dropped" contract at line ~93). Order matters: do `.json.`
    BEFORE `.stdout` so the longer token wins (same reasoning as the existing `.stdout.all`-before-`.stdout`).
    *Verify:* step emitting `{"foo":{"bar":42}}` → `{{step-s1.json.foo.bar}}` resolves to `42`;
    invalid JSON → empty; missing path → empty.

19. **Validator: forward-reference check covers `.json` refs.** *Where:* `Hub-Workflows.ps1`
    `Test-WorkflowSchema` param-ref scan (~line 199). The existing regex `\{\{step-([^.}]+)` already
    captures the stepId before the first `.`, so `.json.` refs are covered automatically — **verify** the
    regex still matches `{{step-s1.json.foo.bar}}` and that the forward-reference rule applies. Add a unit
    assertion to the smoke test rather than new code if it already works.
    *Verify:* `{{step-s9.json.x}}` referencing a later step → 422.

20. **Doc/hint update.** *Where:* the canvas template token hint (`<details>` toggle, HANDOFF.md line 54
    references it). Add `{{step-sN.json.foo.bar}}` and the foreach current-item convention
    (`{{step-<foreachStepId>.stdout}}`) to the hint copy.
    *Verify:* hint lists the new tokens.

---

## Backend vs frontend split (which steps need an exe rebuild)

| Step(s) | Layer | Needs exe rebuild? |
|--------|-------|--------------------|
| 1, 2 (`-SkipMutex`, resume route) | Backend (Hub.ps1) | YES |
| 3, 4, 5 (onAlways routing/validation/cycle) | Backend | YES |
| 8, 9, 10, 11, 12 (pause schema/engine/resume/recovery/kill-paused) | Backend | YES |
| 14, 15, 16 (foreach schema/engine/cycle) | Backend | YES |
| 18, 19 (JSON refs validation/resolution) | Backend | YES |
| 6, 7 (canvas ports/colors/serialize) | Frontend (canvas-editor.js) | No (static assets served from disk) |
| 13 (pause banner UI) | Frontend | No |
| 17 (foreach node UI) | Frontend | No |
| 20 (token hint) | Frontend | No |

All backend logic is dot-sourced from disk at runtime, BUT the compiled `Invoke-Route` table in Hub.exe
is what dispatches `/api/...`. New routes (`/resume`) and `$Script:StateRoutes` entries live in `Hub.ps1`
and are baked into the exe → **a rebuild is mandatory** for Item 0/2/3. Rebuild + release:
`./build-hub.ps1 -Version 1.9.0.0` then `./build-release.ps1 -Version 1.9.0.0`.

Frontend (`canvas-editor.js`, index template) is served as a static asset from disk, so UI changes take
effect on browser reload without a rebuild — but ship them together in the v1.9.0.0 release for coherence.

---

## Testing & verification (smoke tests under tests/)

New file: `tests/smoke-phase5-controlflow.ps1`. Start Hub via `pwsh -File Hub.ps1 -Port 8799 -SkipMutex`,
fetch CSRF cookie from `GET /`, then exercise (each is an isolated, deterministic assertion):

Fixtures (`tests/fixtures/`): `exit-with.ps1` (`param($Code) exit $Code`), `emit-json.ps1`
(`Write-Output '{"foo":{"bar":42},"list":[10,20]}'`), `emit-lines.ps1` (writes 3 lines), `echo-arg.ps1`
(`param($Value) Write-Output $Value`).

1. **onAlways routing:** create a workflow `s1(exit-with 1) --always--> s2(echo)`; run; poll run to
   completion; assert s2 executed and run status `done`.
2. **onAlways validation:** POST workflow with `onAlways: "nope"` → 422; with valid target → 200.
3. **onAlways cycle:** `s1.onAlways=s2`, `s2.onSuccess=s1` → 422 cycle.
4. **Pause lifecycle:** workflow `s1(pause) -> s2(echo)`; run → status `paused` within 2s, no child job
   running; POST `/resume` {approve} → status transitions through `running` to `done`, s2 ran.
5. **Pause abort:** run pause workflow; POST `/resume` {abort} → status `killed`.
5b. **Kill a paused run:** run pause workflow; POST `/kill` → status `killed` (regression guard for the
    `Invoke-WorkflowRunKillRoute` paused-state fix, step 12).
6. **Pause recovery:** pause a run; (simulate restart by calling `Initialize-WorkflowRuns` in a second
   process or re-reading the run file) → status still `paused`, not `interrupted`.
7. **Resume guards:** `/resume` on a `running` or `done` run → 409; missing CSRF → 403; unknown run → 404.
8. **Foreach lines:** `s1(emit-lines)`, `s2 foreach(source=s1, as=lines, bodyStart=s3)`, `s3(echo-arg
   {{foreach.item}})`; run; assert s3 ran 3 times (inspect child job count for the run) and foreach
   step's `stepOutputs.stdoutAll` contains all 3 items.
9. **Foreach json:** `s1(emit-json)`, foreach over `as=json` of `.list` → 2 iterations. (If `as=json`
   expects a top-level array, use a fixture that emits `[1,2,3]`.)
10. **Foreach maxItems:** source emits 10 lines, `maxItems=3` → exactly 3 iterations.
11. **Foreach empty/invalid:** source emits nothing (or invalid JSON for `as=json`) → 0 iterations,
    foreach routes to its `returnTarget`, run completes `done`.
12. **JSON ref resolve:** `s1(emit-json)`, `s2(echo-arg {{step-s1.json.foo.bar}})` → s2 output `42`.
13. **JSON ref graceful:** `{{step-s1.json.missing.path}}` and a non-JSON source → resolves empty,
    run still completes (no crash).
14. **Backward-compat regression:** load a pre-Phase-5 workflow JSON fixture (only `success` edges,
    `{{step-s1.stdout}}`) → saves (200), runs, completes `done` with identical behavior.

Run command: `pwsh -File tests/smoke-phase5-controlflow.ps1`. Also re-run `smoke-phase2-engine.ps1` and
`smoke-canvas-editor.ps1` to confirm no regressions. Build verify: `./build-hub.ps1 -Version 1.9.0.0`
completes; the resulting exe responds 202 to `/api/workflows/:id/run` and serves `/resume`.

---

## Risks & mitigations  *(flag `rune:adversary` items)*

| Risk | Severity | Mitigation | `rune:adversary`? |
|------|----------|------------|-------------------|
| **Foreach corrupts the single-cursor state machine** (the body re-entry logic mis-detects boundaries, leaks a frame, or double-spawns jobs) | CRITICAL | Constrain v1.9.0.0 foreach body to a SINGLE step; frame controls all routing; exhaustive smoke tests 8–11; add a per-run frame-depth assertion | **YES — mandatory** |
| **Paused run advanced or GC'd** by another pump path / LRU job sweep / interrupted-run recovery | HIGH | Pump filter excludes non-`running`; recovery handles `paused` explicitly; LRU already excludes workflow-tagged jobs but a paused run has NO job — verify the run record itself isn't swept | **YES** |
| **JSON parse of untrusted script stdout** — `ConvertFrom-Json` on huge/malicious stdout (DoS, deep nesting) | MEDIUM | Cap parsed stdout size (e.g. skip parse if `stdoutAll.Length > 1MB` → empty); wrap in try/catch; never `Invoke-Expression` | **YES — security** |
| **Resume route CSRF/abuse** — replay, resuming someone else's run | MEDIUM | CSRF-gated via `$Script:StateRoutes`; localhost-only binding already enforced; 409 on non-paused | YES |
| **Back-compat break**: adding `onAlways` to field/adjacency loops changes validation for old workflows | HIGH | Old workflows never have `onAlways`; `ContainsKey` guards mean absent field = no behavior change; regression test #14 | No (covered by test) |
| **Engine file exceeds 500 lines** after edits | LOW | Split helpers into `Hub-WorkflowControl.ps1`; dot-source after engine | No |
| **PS5 vs PS7 JSON path** — `ConvertFrom-Json` depth/`-AsHashtable` differences | MEDIUM | Reuse existing `ConvertFrom-JsonHashtable` helper (already PS5-safe); test on both runtimes | No |
| **SSE `step-pause` not delivered** if no subscriber yet (run started, UI not connected) | LOW | UI polls run status on connect; SSE `step-pause` is an enhancement, status field is source of truth | No |
| **`always` + `success` both wired on one node** → `onAlways` wins, the `success`/`failure` edges become silently dead (confusing UX) | LOW | In `cnAddEdge`: when adding an `always` edge, remove any `success`/`failure` edges from that node (and vice-versa) so only one routing mode exists per node; OR grey-out the other ports when `always` is connected. Document the "onAlways wins" precedence in the port tooltip | YES |

**Recommended `rune:adversary` pass on this plan BEFORE coding** — per project memory
(`feedback-adversarial-before-implement`), run `/rune:adversary` and fold findings, focusing on the
foreach state-machine boundary logic (Item 3) and paused-run garbage-collection paths (Item 2).

---

## Rollback plan

- All four items are additive and feature-gated by node `type` / optional fields. If a defect ships:
  1. **Frontend-only revert:** restore the prior `canvas-editor.js` and run-view template from git
     (`git checkout <prev> -- wwwroot/canvas-editor.js`). No rebuild needed; takes effect on reload.
  2. **Backend revert:** revert `Hub-WorkflowEngine.ps1` / `Hub-Workflows.ps1` / `Hub.ps1` to the
     v1.8.x commit and rebuild the prior exe (`./build-hub.ps1 -Version 1.8.x`).
- **Data safety:** new run records may contain `status:paused` and `foreachFrames`. On rollback, the old
  engine's `Initialize-WorkflowRuns` will mark any non-`endedAt` run as `interrupted` (harmless — runs
  are historical). No migration of `workflows/*.json` is needed: old engine ignores `type`/`onAlways`/
  `foreach`/`pause` fields (extra keys are tolerated), but a workflow built WITH pause/foreach nodes will
  misbehave on the old engine — document that v1.9.0.0 workflows require v1.9.0.0+.
- Atomic persistence (tmp + move) already guarantees no half-written run/workflow files.

---

## Definition of Done

- [ ] `-SkipMutex` lets a second Hub instance start while Hub.exe runs (smoke harness works).
- [ ] `onAlways` routes regardless of exit code; validated and cycle-checked; canvas renders three
      color-coded output ports and serializes `onAlways`.
- [ ] Pause node halts a run in `paused` state with no child job (`currentJobId` nulled on pause-enter);
      `/api/workflow-runs/:id/resume` (CSRF-gated) approves or aborts; the existing `/kill` route also
      ends a paused run; paused runs survive a restart (not marked `interrupted`); UI shows an
      approve/abort banner.
- [ ] Foreach node iterates a single body step once per source item (lines or JSON array), respects
      `maxItems`, aggregates results into the foreach step's output, handles empty/invalid sources,
      and never corrupts the single-cursor pump (frame stack balanced; no double-spawn).
- [ ] `{{step-sN.json.foo.bar}}` resolves dotted/indexed JSON paths; degrades to empty on invalid JSON
      / missing path; forward-reference validation covers `.json` refs; `.stdout` refs unchanged.
- [ ] **Backward compatibility:** an existing pre-Phase-5 workflow (success edges + `{{step-sN.stdout}}`)
      saves, runs, and completes with identical behavior (regression test #14 green).
- [ ] `tests/smoke-phase5-controlflow.ps1` passes on both PowerShell 5.1 and 7 with Hub.exe closed and
      with `-SkipMutex` alongside Hub.exe; `smoke-phase2-engine.ps1` + `smoke-canvas-editor.ps1` still pass.
- [ ] `Hub.exe` rebuilt and released as **v1.9.0.0**; `/resume` route reachable from the binary.
- [ ] All touched/new `.ps1` files remain under 500 lines (engine split into `Hub-WorkflowControl.ps1`
      if needed).
- [ ] `rune:adversary` run on this plan; findings on Items 2 & 3 folded in before implementation.

---

## Outcome Block

**What was planned:** Four additive workflow capabilities (conditional `always` ports, pause/approval
node + resume route, sequential single-step foreach, JSON-path output refs) with exact engine/pump
changes, backward-compat guarantees, and a smoke suite — shipping as a rebuilt Hub.exe v1.9.0.0.

**Immediate next action:** Run `rune:adversary` on this plan, concentrating on the foreach frame
boundary logic (Item 3, step 14) and the paused-run garbage-collection paths (Item 2, steps 9 & 11).

**How to measure:**

| Goal | Command |
|------|---------|
| Plan exists | `Test-Path "docs/plans/phase-5-deep-capability.md"` |
| Smoke suite green | `pwsh -File tests/smoke-phase5-controlflow.ps1` |
| Back-compat intact | `pwsh -File tests/smoke-phase2-engine.ps1` |
| Binary rebuilt | `./build-hub.ps1 -Version 1.9.0.0; (Get-Item dist/Hub.exe).VersionInfo.FileVersion` |
