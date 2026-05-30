# Phase 3 — Differentiator: Secrets vault + workflow export/import (target v1.7.0.0)

> **Refinement note (rune:plan):** This plan was re-planned through the `rune:plan` skill
> and refined in place as a single phase file (the skill's master+phase split is
> intentionally NOT applied — the task brief says "refine in place"). Symbol anchors are
> authoritative; line numbers are approximate (they drift). Phase 0 shipped as **v1.5.0.0**
> (`$Script:Version = '1.5.0.0'`, Hub.ps1 ≈L27) and added the `-SkipMutex` switch (≈L18,
> ≈L2186), so smoke tests can run alongside a live Hub.exe.

## ⚠️ PS5.1-SAFETY — NON-NEGOTIABLE (applies to every line of `Hub-Secrets.ps1` and `Hub-Export.ps1`)

Hub.exe runs on the **Windows PowerShell 5.1 / .NET Framework** runtime (the child `pwsh`
worker may be 7.x, but the host that dot-sources these modules is 5.1). A single 7.x-only
syntax token anywhere in a dot-sourced module makes the **entire module fail to parse**,
which silently breaks dot-sourcing and **prevents Hub.exe from starting** — this exact
failure happened in Phase 0. The new modules MUST therefore be PS5.1-safe:

- **BANNED:** `??` (null-coalescing), `?:` ternary (`cond ? a : b`), `?.` / `?[]`
  null-conditional, `ConvertFrom-Json -AsHashtable`, `Clean {}` blocks, and any other
  7.x-only syntax.
- **REQUIRED substitutes:** use `if`/`else` instead of ternary; use the project helper
  **`ConvertFrom-JsonHashtable`** (Hub.ps1 ≈L361 pattern) instead of `-AsHashtable`; guard
  nulls with `if ($null -eq $x) { ... }`.
- **List/array responses MUST use `ConvertTo-Json -InputObject $list` + `'[]'` fallback.**
  In a pipeline, an empty array serializes to JSON `null`; the established fix is in
  `Hub-Workflows.ps1` ≈L251–253:
  `$json = ConvertTo-Json -InputObject $list -Depth 10 -Compress; if ($null -eq $json) { $json = '[]' }`.
  This applies to **`GET /api/secrets`** (Step 2) and any list field in the import response.
- **GATING VERIFY (new — Step 7.5):** before *any* exe build, parse-check both new modules
  under **`powershell.exe`** (PS5.1 — NOT `pwsh`, which would not catch the 7.x tokens):
  `powershell.exe -NoProfile -Command "[void][ScriptBlock]::Create((Get-Content -Raw .\Hub-Secrets.ps1))"`
  (and the same for `Hub-Export.ps1`). Non-zero exit / parse error ⇒ STOP, do not build.

## Goal

Add a DPAPI-encrypted secrets vault and `.hubflow` workflow export/import to Hub
without new runtime dependencies, preserving the localhost-only / CSRF / single-exe
security model.

1. **Secrets vault** — new module `Hub-Secrets.ps1`. Secret VALUES are encrypted at
   rest with DPAPI (`CurrentUser` scope) under `%LOCALAPPDATA%\Hub\secrets\`. Values
   are write-only over the API: no GET ever returns a value; values never appear in
   `runs.jsonl`, SSE streams, `hub-error.log`, or exported `.hubflow` files. At run
   time a referenced secret is decrypted and injected into the
   `securestring` / `pscredential` / `password` params Hub already detects
   (`ConvertTo-WidgetSpec`, the `securestring|pscredential → widget=password` arm at
   Hub.ps1 ≈L924–925).
2. **UI** — manage vault entries (add / rename / delete *names* + metadata) and bind a
   secret to a password-typed param in the run form via a dropdown of secret names
   (value never displayed, never sent from the browser).
3. **Workflow export/import** — `.hubflow` files carrying a workflow incl. its canvas
   JSON. Export is a download; import runs full schema validation (reuse
   `Test-WorkflowSchema`) plus a trust warning. Exported workflows embed only secret
   *name references*, never values.

## Dependencies / prerequisites

- **Phase 2 (done):** stabilized `/api/run` param-injection path; presets establish the
  saved-param JSON convention this vault extends. The vault is a *server-side* analogue
  of a preset: instead of a value travelling browser→server, a *reference* travels and
  the server resolves it.
- Existing autodetect of `securestring`/`pscredential`/`password` → `widget=password`
  (Hub.ps1 `ConvertTo-WidgetSpec`, type-mapping switch arm ≈L924–925). The vault binds
  only to `widget=password`.
- Existing primitives reused as-is: `Build-Argv`, `Start-HubJob`, `Get-ParamSchema`,
  `Get-EffectiveScanRoots`, `Write-JsonResponse`, `Invoke-SecurityMiddleware` (CSRF),
  `$Script:StateRoutes`, `ConvertFrom-JsonHashtable`, `Save-Workflow`,
  `Test-WorkflowSchema`, `New-WorkflowId`.
- DPAPI available built-in via `[System.Security.Cryptography.ProtectedData]` (needs
  `Add-Type -AssemblyName System.Security` on PS5; the type is in-box on PS7).
- New backend routes ⇒ **Hub.exe rebuild required** ⇒ ships as **v1.7.0.0**.

## Files touched (existing + new, absolute repo paths)

New:
- `C:\Users\Harrold\Documents\Claude Projects\Hub\Hub-Secrets.ps1` — vault module
  (DPAPI encrypt/decrypt, CRUD, name validation, run-time resolution, route handler).
- `C:\Users\Harrold\Documents\Claude Projects\Hub\Hub-Export.ps1` — `.hubflow`
  build/parse, trust-warning envelope, import validation glue. (Kept separate from
  Hub-Workflows.ps1 to stay under the 500-line cap.)
- `C:\Users\Harrold\Documents\Claude Projects\Hub\tests\smoke-phase3-secrets.ps1`
- `C:\Users\Harrold\Documents\Claude Projects\Hub\tests\smoke-phase3-export-import.ps1`

Modified:
- `C:\Users\Harrold\Documents\Claude Projects\Hub\Hub.ps1` — dot-source the two new
  modules; add `/api/secrets**`, `/api/workflows/{id}/export`, `/api/workflows/import`
  to `$Script:StateRoutes` and `Invoke-Route`; call secret resolution inside
  `Invoke-RunRoute` *and* the workflow engine before `Start-HubJob`; change spawn to
  pass secrets via **stdin**, not argv (see Step 4).
- `C:\Users\Harrold\Documents\Claude Projects\Hub\Hub-WorkflowEngine.ps1` — resolve
  secret refs for each step before `Build-Argv`/`Start-HubJob` (L117–119, L193–195);
  **track secret-bearing steps and make `Resolve-StepParams` (≈L88-91) drop their
  `{{step-N.stdout(.all)}}` refs to empty (ADV-301)** so an echoed secret can't reach a
  downstream argv.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\wwwroot\app.js` (or the existing
  Alpine root + canvas-editor.js) — Secrets tab UI, password-field secret dropdown,
  export button, import dialog + trust warning.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\wwwroot\index.html` — Secrets tab,
  import dialog markup.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\CHANGELOG.md`,
  `C:\Users\Harrold\Documents\Claude Projects\Hub\README.md` (security model section),
  `C:\Users\Harrold\Documents\Claude Projects\Hub\HANDOFF.md`.

## Implementation steps (numbered; each: what / where / how-to-verify)

### Step 0 — `rune:adversary` red-team review BEFORE any code (MANDATORY, gating)

- **What:** Run `/rune:adversary` against THIS plan (specifically the threat model in
  Risks and the spawn/injection design in Step 4) before writing a single line. This is
  the standing project rule "adversarial review before implementing" applied to a
  security-sensitive feature. Fold every finding back into the plan, then re-confirm.
- **Where:** Planning artifact only; no repo changes yet.
- **Mandatory questions the red-team MUST answer (do not implement until each is closed):**
  1. **Argv leak.** If a secret is passed as a CLI argument, it is visible to any
     local process via `Get-CimInstance Win32_Process | select CommandLine` and may be
     captured by process-creation auditing / EDR. → Plan's answer: **inject via stdin**,
     never argv (Step 4). Verify the chosen mechanism really keeps it off the command line.
  2. **`-File` mode cannot read named params from stdin.** `pwsh -File script.ps1`
     binds params positionally/by-name from argv only; stdin is the script's input
     stream, not its param binder. So how does a `securestring` param get the value?
     → Plan's answer: switch password-bearing runs to a **`-Command` shim** that reads a
     length-prefixed secret blob from stdin and splats it into the target script as a
     `[securestring]`/`[pscredential]`, OR have the target read `$input`. The red-team
     must confirm the shim does not itself echo the secret and that non-secret runs are
     unchanged (still `-File`).
  3. **DPAPI scope.** Confirm `CurrentUser` (not `LocalMachine`) so another local user
     cannot decrypt. Confirm no optional entropy is required (CurrentUser alone is the
     documented model) and that roaming-profile / OneDrive KFM of `%LOCALAPPDATA%` will
     NOT silently sync the blobs (it won't — `%LOCALAPPDATA%` is non-roaming).
  4. **Crash/log leak.** Confirm decrypted plaintext is held only in a local variable for
     the minimal window, never interpolated into any `Write-HubError` / `throw` message,
     and is zeroed where feasible. The red-team must grep the design for any `"$secret"`
     interpolation path.
  5. **Echo-back.** The vault cannot stop a *user's own script* from printing the secret
     to stdout (which then hits SSE + history-of-output… though history stores no output).
     Decide and document this as an accepted, documented limitation; ensure Hub itself
     never echoes it.
  6. **Export poisoning.** Confirm an imported `.hubflow` cannot (a) smuggle a secret
     value, (b) reference a scriptId outside scan roots that auto-runs, (c) carry a
     malicious `id` that overwrites an existing workflow, or (d) carry templates in
     `scriptId`. All must be blocked by reusing `Test-WorkflowSchema` + forcing a fresh `id`.
  7. **Name as injection vector.** Secret *names* ARE returned by GET and used as
     filenames. Confirm strict charset (Step 1) prevents path traversal and stored-XSS.
- **How-to-verify:** A short written red-team note is produced; each of the 7 items has a
  decision; Steps 1–8 below are updated to match before implementation starts.

### Step 0.5 — Adversary findings folded (REVISE verdict, 2026-05-30)

The Step 0 red-team returned **REVISE**. Findings now binding on the steps below:

- **[ADV-301 — CRITICAL] Template substitution re-exposes an echoed secret on a DOWNSTREAM
  step's argv.** `Resolve-StepParams` (Hub-WorkflowEngine.ps1 ≈L88-91) substitutes
  `{{step-N.stdout}}`/`.stdout.all` into the next step's param values → `Build-Argv` → argv
  (≈L194-195). If a secret-consuming step's script echoes the secret to stdout, the template
  engine lands it on the next step's command line — defeating stdin injection in the workflow
  path. **MANDATORY:** the run must track which steps resolved ≥1 secret ("secret-bearing");
  `Resolve-StepParams` MUST treat `{{step-N.stdout}}`/`.stdout.all` for a secret-bearing step
  N as **empty** (drop the ref) and surface a warning. `.exitCode` refs remain allowed. Add a
  smoke assertion: a 2-step workflow where step 1 (secret-bound) echoes its secret and step 2
  uses `{{step-s1.stdout}}` → step 2's `Win32_Process.CommandLine` MUST NOT contain the secret.
- **[ADV-302 — HIGH] Shim MUST propagate exit code.** `pwsh -Command "& $target …"` exits 0
  regardless of the target's `exit N`. The shim MUST end with `exit $LASTEXITCODE` or secret
  runs misreport status (breaks history, run-finished toast, and workflow `onFailure` routing).
  Smoke: secret run of an `exit 3` fixture reports exit 3.
- **[ADV-303 — HIGH] stdin payload schema (per-param kind+username).** The stdin JSON is
  `{ "<param>": { "kind":"password|credential", "value":"…", "username":"…|null" } }` (NOT
  bare `{param:value}`). Shim builds `[securestring]` for password/securestring and
  `[pscredential]` (username + securestring) for credential. **Fail closed** (error, never
  argv fallback) on unknown kind or missing username for a credential.
- **[ADV-304 — HIGH] Secret value size cap.** `POST/PUT /api/secrets` rejects a `value`
  longer than **64 KB** with 413/422 (bounds DPAPI blob + stdin payload).
- **[ADV-305 — MED] `-File`→`& $target` parity.** Secret runs invoke via `& <target>` in the
  shim process. `& 'script.ps1'` sets `$PSScriptRoot`/`$PSCommandPath` correctly; still add a
  fixture asserting a secret run and a non-secret run of the same script behave identically.
- **[ADV-306 — MED] `@secret:` is typed-mode only.** In raw mode it is passed literally (no
  resolution, no leak). Document; UI shows a note when raw mode is active.

### Step 1 — `Hub-Secrets.ps1`: storage layer + name validation

- **What:** Define vault dir, name rules, DPAPI encrypt/decrypt, and a per-secret file
  format that stores ciphertext + non-secret metadata.
- **PS5.1 reminder:** this whole module is dot-sourced into the 5.1 host — no `??`/ternary/
  `?.`/`-AsHashtable` anywhere (see the PS5.1-SAFETY block above). Parse JSON with
  `ConvertFrom-JsonHashtable`.
- **Where:** new `Hub-Secrets.ps1`, dot-sourced from Hub.ps1 right after `Hub-History.ps1`
  (L113) so its `$Script:` helpers exist before route dispatch.
- **How:**
  - `Get-SecretsDir` → `Join-Path $Script:ConfigDir 'secrets'`; create on demand
    (mirror `Get-HistoryDir`). Set restrictive ACL best-effort (owner-only) but rely on
    DPAPI as the real boundary.
  - **Name rule:** `^[A-Za-z0-9][A-Za-z0-9 ._-]{0,62}[A-Za-z0-9]$` (no leading/trailing
    space, no `..`, no path separators). Reject otherwise with 422. The on-disk filename
    is `SHA256(name)` hex (12–16 chars) + `.secret.json`, NOT the raw name — defends
    against traversal and case-collision regardless of the charset check.
  - **File format** (`<hash>.secret.json`):
    `{ "v":1, "name":"<original>", "kind":"password|credential", "username":null,
       "ciphertext":"<base64 DPAPI blob>", "createdAt":"<o>", "updatedAt":"<o>" }`.
    For `pscredential` kind, `username` is stored *in cleartext metadata* (it is not the
    secret) and only the password is encrypted.
  - **Encrypt:** `Add-Type -AssemblyName System.Security` (guarded for PS7);
    `[System.Security.Cryptography.ProtectedData]::Protect($utf8Bytes, $null,
    [System.Security.Cryptography.DataProtectionScope]::CurrentUser)` → base64.
  - **Decrypt:** `Unprotect(...)` → UTF8 string; wrap in try/catch that on failure logs a
    **generic** message (`"secret decrypt failed for <name>"`, never the bytes).
- **How-to-verify:** Unit-style assertions in `smoke-phase3-secrets.ps1`: write a secret,
  confirm the on-disk file contains base64 that does NOT contain the plaintext substring;
  confirm bad names are rejected; confirm decrypt round-trips.

### Step 2 — `Hub-Secrets.ps1`: CSRF-gated `/api/secrets` CRUD (write-only values)

- **What:** `Invoke-SecretsRoute` + `Invoke-SecretByNameRoute` modeled on
  `Invoke-WorkflowsRoute` / `Invoke-WorkflowByIdRoute`.
- **Where:** new module; wired into `Invoke-Route` (Step 6).
- **How:**
  - `GET /api/secrets` → list of `{ name, kind, username, createdAt, updatedAt }`
    **only**. Never a `value`/`ciphertext` field. (Read-only ⇒ no CSRF, like `/api/config`.)
    **Empty-array pitfall (PS5.1):** serialize the list with
    `ConvertTo-Json -InputObject $list -Depth 5 -Compress; if ($null -eq $json) { $json = '[]' }`
    (mirror `Hub-Workflows.ps1` ≈L251–253) — a piped empty array becomes JSON `null`, which
    breaks the UI's `.map()`.
  - `POST /api/secrets` (state route) → body `{ name, kind, value, username? }`; validate
    name; **reject `value` longer than 64 KB ⇒ 413 (ADV-304)**; encrypt `value`; write file;
    return metadata (no value). Duplicate name ⇒ 409.
  - `PUT /api/secrets/{name}` (state route) → rename and/or rotate value. Rename =
    metadata change + file re-key (new hash filename, delete old). Rotate = re-encrypt.
  - `DELETE /api/secrets/{name}` (state route) → delete file. 404 if absent.
  - The route NEVER reads back `value` for any GET; the only code path that decrypts is
    `Resolve-SecretValue` (Step 3), called exclusively from the run path.
  - Body size guard + `application/json` (already enforced by middleware for POST).
- **How-to-verify:** smoke test: POST a secret → GET shows name, NO value; attempt to GET
  a single secret returns metadata only; 409 on dup; 422 on bad name; 403 without CSRF
  header.

### Step 3 — Secret reference model + `Resolve-SecretValue`

- **What:** Define how a run references a secret, and resolve it server-side.
- **Where:** `Hub-Secrets.ps1` (resolver) + `Invoke-RunRoute` (Hub.ps1) + workflow engine.
- **How:**
  - **Reference wire format:** in the run/workflow `values`/`params` map, a password field
    may carry a sentinel object/string instead of a literal:
    `"@secret:<name>"` (string sentinel — survives existing PSCustomObject parsing and
    `[string]` coercion in `Build-Argv`). Browser sends only this token; never the value.
  - `Resolve-SecretValue -Name <n>` → returns plaintext (or throws generic on miss).
  - **Server-side binding rule:** resolution is allowed **only** for fields whose schema
    `widget -eq 'password'`. If a `@secret:` token appears on a non-password field →
    reject 400 (prevents a caller smuggling a secret into a normal `-Arg` that would land
    on the command line).
- **How-to-verify:** smoke test posts a run with `values = { Password = "@secret:test" }`
  against a fixture script with a `[securestring]$Password` param; assert the child
  receives the real value (fixture writes a hash of it, not the value, to stdout) and
  that `@secret:` token never appears in argv (see Step 4 verification).

### Step 4 — Secret-safe spawn: stdin injection (CRITICAL — replaces argv for secrets)

- **What:** When a run has ≥1 resolved secret, do NOT place the plaintext on the command
  line. Inject via the child's stdin (already redirected — Hub.ps1 L1426
  `$psi.RedirectStandardInput = $true`, currently closed immediately at L1440).
- **Where:** `Start-HubJob` (Hub.ps1 L1394) gains an optional
  `[hashtable]$Secrets = @{}` (param-name → plaintext). `Invoke-RunRoute` and the
  workflow engine build this map from `Resolve-SecretValue` and pass it in; the plaintext
  map is built as late as possible and never logged.
- **How:**
  - **Non-secret runs:** unchanged — `pwsh -File <script> <argv...>`, stdin closed (L1440).
  - **Secret runs:** switch the invocation to a **bootstrap shim** so secrets bind as
    `[securestring]`/`[pscredential]` without touching argv:
    - `FileName = pwsh`; argv = `-NoProfile -NonInteractive -ExecutionPolicy Bypass
      -Command <shim>` where `<shim>` is a fixed, Hub-authored one-liner that:
      1. reads a single JSON line from `[Console]::In` — payload (ADV-303):
         `{ "<param>": { "kind":"password|credential", "value":"…", "username":"…|null" } }`,
      2. for each: `ConvertTo-SecureString -AsPlainText -Force`; if `kind -eq 'credential'`
         build `[pscredential]::new($username, $secure)`. **Fail closed** — unknown kind or a
         credential with no username throws (NEVER fall back to argv),
      3. splats them plus the non-secret argv into `& <targetScript> @nonSecretArgs @secretParams`,
      4. **`exit $LASTEXITCODE` (ADV-302)** so the target's exit code propagates (else secret
         runs always report 0 → wrong history/toast/onFailure routing).
    - The shim text is constant (no user input interpolated into it). The secret JSON is
      written to `$proc.StandardInput`, then stdin closed. Non-secret argv is passed as
      normal argv after `-Command <shim>` (becomes `$args` in the shim scope).
  - Non-secret params for secret runs still travel as argv (they are not sensitive).
  - The plaintext secret JSON string is the only place plaintext lives in Hub; clear the
    variable (`$secretJson = $null`) immediately after `WriteLine`.
- **Why stdin not argv:** argv is world-readable to the local user via
  `Win32_Process.CommandLine` and process-audit logs; stdin is not enumerable post-write.
- **How-to-verify:** With a fixture that runs `Start-Sleep`, capture
  `Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'"` during the run and assert the
  secret plaintext is **absent** from every `CommandLine`. Assert the fixture's
  `[securestring]` param received the correct value (fixture emits SHA256 of the value).

### Step 5 — Workflow export/import (`.hubflow`) in `Hub-Export.ps1`

- **What:** Export a workflow (incl. `canvas`) as a downloadable `.hubflow`; import with
  validation + trust warning; never embed secret values.
- **Where:** new `Hub-Export.ps1`; routes wired in Step 6.
- **How:**
  - **Export** `GET /api/workflows/{id}/export` (read-only): build an envelope
    `{ "hubflow":1, "exportedAt":"<o>", "hubVersion":"1.7.0.0", "workflow":{...} }`.
    The `workflow` is the stored object including `canvas`, with `id`/`version` retained
    for reference but **stripped/regenerated on import**. Because secret refs are only
    `@secret:<name>` tokens in `params`, no value is ever present — but add an explicit
    **scrub pass** that asserts no field starts with anything other than `@secret:` for
    password params and rejects export if a literal somehow leaked (defense in depth).
    Response: `Content-Type: application/json`,
    `Content-Disposition: attachment; filename="<safe-name>.hubflow"`.
  - **Import** `POST /api/workflows/import` (state route): parse envelope; verify
    `hubflow` version; extract `workflow`; **force a fresh `id` via `New-WorkflowId`** and
    reset `version` to 1 (never trust incoming id → no overwrite); run
    `Test-WorkflowSchema` (reuse — catches templates in scriptId, cycles, forward refs,
    step cap); on failure 422 with details. On success `Save-Workflow`.
    - **scriptId trust:** imported steps reference scriptIds (paths). Do NOT auto-resolve
      or run them. Return in the response a list of referenced scriptIds that are NOT
      currently under a scan root so the UI can show the trust warning. Import succeeds
      (workflow saved) but is flagged "unresolved scripts — review before running".
    - **secret refs:** return the list of `@secret:<name>` names referenced so the UI can
      warn which secrets the importer must create locally.
  - File-size cap on import body (e.g. 256 KB) to bound parse cost.
- **How-to-verify:** `smoke-phase3-export-import.ps1`: create workflow with canvas + a
  `@secret:foo` param → export → assert no plaintext, canvas present, envelope shape;
  re-import → assert new `id` ≠ original, `version=1`, schema valid; import a tampered
  file with a literal in a password field / a cyclic graph / templated scriptId → assert
  422; import referencing an out-of-root scriptId → assert 200 + unresolved-scripts flag.

### Step 6 — Wire routes + CSRF list (Hub.ps1)

- **What:** Register new routes and mark state routes.
- **Where:** Hub.ps1 `$Script:StateRoutes` (L45) and `Invoke-Route` (L1945).
- **How:**
  - Add to `$Script:StateRoutes`: `'/api/secrets'`, `'/api/secrets/.+?'`,
    `'/api/workflows/.+?/import'` (import is a POST; export GET is read-only so NOT a
    state route — but it lives under `/api/workflows/.+?` which is *already* a state
    route pattern → confirm GET is allowed through since CSRF only gates non-GET, L262).
    Use a distinct literal `'/api/workflows/import'` so it doesn't collide with the
    `{id}` matcher.
  - In `Invoke-Route`, add (ordering matters — place `import` literal before the generic
    `^/api/workflows/([^/]+)$` matcher, and `export` before it too):
    - `/api/secrets` → `Invoke-SecretsRoute`
    - `^/api/secrets/([^/]+)$` → `Invoke-SecretByNameRoute` (URL-decode name)
    - `/api/workflows/import` → `Invoke-WorkflowImportRoute`
    - `^/api/workflows/([^/]+)/export$` → `Invoke-WorkflowExportRoute`
  - Dot-source `Hub-Secrets.ps1` and `Hub-Export.ps1` after L113. Call their
    `Initialize-*` (dir creation) where the others initialize.
- **How-to-verify:** Routes return non-503; `Test-IsStateRoute` returns `$true` for the
  new POST/PUT/DELETE paths (assert in smoke test); a POST without CSRF → 403.

### Step 7 — Frontend: Secrets tab, password dropdown, export/import UI

- **What:** Minimal Alpine UI; values never displayed.
- **Where:** `wwwroot/index.html` + the Alpine root in `wwwroot/app.js`
  (and `canvas-editor.js` only for the export button if it lives in the editor toolbar).
- **How:**
  - **Secrets tab** (4th tab alongside Catalog/Workflows/History): list names + kind +
    updatedAt; "Add" dialog (name, kind, value, optional username); "Rename"; "Delete".
    The value `<input type="password">` is write-only — after save the field is cleared
    and the value is never re-fetched.
  - **Run-form binding:** for any field with `widget==='password'`, render a small
    "Use secret" toggle → dropdown of secret names (from `GET /api/secrets`). When chosen,
    the field's submitted value becomes the string `"@secret:<name>"`; the literal input
    is disabled. The value box never shows a stored secret.
  - **Export:** button on a workflow → `window.location = '/api/workflows/'+id+'/export'`
    (browser downloads the `.hubflow`).
  - **Import:** file picker → read text → `POST /api/workflows/import` with
    `X-Hub-CSRF`. Show a **trust warning modal** before saving conceptually ("Importing a
    workflow you did not create can reference scripts/secrets on your machine. Only import
    files you trust.") and after import surface any `unresolvedScripts` /
    `referencedSecrets` returned by Step 5.
- **How-to-verify:** Manual: add a secret, confirm value never reappears after reload;
  bind a secret in a password param and run a fixture; export downloads a file; import
  shows the trust modal and the unresolved-scripts warning. Static check in
  `smoke-canvas-editor.ps1`-style test that the new markup/handlers exist.

### Step 7.5 — PS5.1 parse-check gate (MANDATORY before any build)

- **What:** Prove the two new modules parse under the **5.1 host runtime** before compiling.
  A 7.x-only token (`??`, ternary, `?.`, `-AsHashtable`) parses fine under `pwsh` 7 but
  fails under `powershell.exe` 5.1, which is what Hub.exe embeds — and a parse failure in a
  dot-sourced module stops Hub.exe from starting (the Phase 0 failure).
- **Where:** repo root; no code changes — a verification command.
- **How:** run under **`powershell.exe`** (NOT `pwsh`):
  - `powershell.exe -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('.\Hub-Secrets.ps1',[ref]$null,[ref]$null)"`
  - same for `.\Hub-Export.ps1`.
  - Also dot-source both in a clean 5.1 session to catch load-time errors:
    `powershell.exe -NoProfile -Command ". .\Hub-Secrets.ps1; . .\Hub-Export.ps1; 'OK'"`.
- **How-to-verify:** all three commands exit 0 and the last prints `OK`. Any parse/load
  error ⇒ STOP; fix the offending syntax before Step 8. Do NOT build until this passes.

### Step 8 — Docs, changelog, version bump, rebuild

- **What:** Document the feature + threat model; bump to 1.7.0.0.
- **Where:** `CHANGELOG.md` (Unreleased → 1.7.0.0), `README.md` security model,
  `HANDOFF.md`, `$Script:Version` in Hub.ps1 (≈L27).
- **How:** README security section gains a "Secrets vault" subsection (DPAPI CurrentUser,
  write-only API, stdin injection, no export of values, echo-back limitation). Confirm
  **Step 7.5 passed**, then `build-hub.ps1 -Version 1.7.0.0` and
  `build-release.ps1 -Version 1.7.0.0`.
  - **Note:** `build-release.ps1` now **commits the rebuilt `Hub.exe`** as part of the
    release cut (the exe is a tracked artifact). Expect a commit touching the binary; do not
    separately `git add` the exe, and verify the release commit includes it.
- **How-to-verify:** Step 7.5 green; `/api/version` returns `1.7.0.0`; UI version chip
  updates; `git log -1 --stat` shows `Hub.exe` in the release commit.

## Backend vs frontend split (which steps need an exe rebuild)

| Step | Layer | Needs exe rebuild? |
|------|-------|--------------------|
| 0 (adversary) | planning | no |
| 1 Hub-Secrets storage | backend (dot-sourced) | runs from disk on existing exe, BUT routes (Step 6) are in the binary's `Invoke-Route` |
| 2 `/api/secrets` CRUD | backend route | **yes** |
| 3 Resolve-SecretValue | backend | yes (called from run path baked in exe) |
| 4 stdin spawn change | backend (`Start-HubJob`, `Invoke-RunRoute`) | **yes** |
| 5 export/import | backend route | **yes** |
| 6 route wiring | backend (`Invoke-Route`, `$Script:StateRoutes`) | **yes** |
| 7 UI | frontend (`wwwroot/`) | **no** (static files served from disk) |
| 7.5 PS5.1 parse gate | verification | no (gates the build — must pass first) |
| 8 docs/version | mixed | yes (version embedded in exe) |

Net: all backend route/spawn work (Steps 2–6, 8) requires the **v1.7.0.0 rebuild**
because `Invoke-Route`, `$Script:StateRoutes`, `Start-HubJob`, `Invoke-RunRoute`, and
`$Script:Version` are compiled into Hub.exe. Module *bodies* are dot-sourced from disk,
but the new routes will return 503 until the binary's route table is rebuilt (same issue
documented in HANDOFF.md §2 for workflows). Frontend (Step 7) ships without rebuild.

## Testing & verification (smoke tests under tests/)

**Smoke-test harness contract (both new suites MUST follow this):**
- **Sandbox the environment** so tests never touch the real vault/config. Before starting
  Hub.ps1, redirect both `TEMP` and `LOCALAPPDATA` to a fresh per-test temp dir
  (e.g. `$env:LOCALAPPDATA = $sandbox; $env:TEMP = $sandbox`) so `%LOCALAPPDATA%\Hub\secrets\`,
  `hub.port`, and `hub-error.log` all land in the sandbox and are deleted at teardown. A test
  must never read or write the developer's real DPAPI secrets dir.
- **Start Hub for the test** with `powershell.exe .\Hub.ps1 -SkipMutex -Port <free-port>`
  (`-SkipMutex` lets it run alongside a live Hub.exe; `-Port` avoids the 8765 collision).
- **Assert HTTP status codes** on every request (200/202/400/403/404/409/422 as specified
  per step), not just body content — status is the primary contract.
- Tear down: stop the spawned Hub process and remove the sandbox dir.

- `tests\smoke-phase3-secrets.ps1`
  - Encrypt-at-rest: on-disk `.secret.json` base64 does NOT contain the plaintext.
  - Write-only: `GET /api/secrets` and `GET /api/secrets/{name}` never return `value`.
  - Name validation: traversal / empty / overlong names → 422.
  - CSRF: POST/PUT/DELETE without `X-Hub-CSRF` → 403.
  - **No-argv-leak:** spawn a fixture with a `[securestring]` param bound to `@secret:x`;
    poll `Get-CimInstance Win32_Process` and assert plaintext absent from all CommandLine.
  - **No-history-leak:** after a secret run, grep `runs.jsonl` and `hub-error.log` for the
    plaintext → must be absent.
  - **No-SSE-leak (Hub side):** assert Hub never emits the value (fixture that does NOT
    echo it; confirm SSE buffer clean).
- `tests\smoke-phase3-export-import.ps1`
  - Export shape + canvas present + no plaintext.
  - Import → fresh id, version reset, schema validated.
  - Tampered imports (literal in password field, cycle, templated scriptId, oversized
    body) → 422.
  - Out-of-root scriptId → 200 with `unresolvedScripts`.
- Re-run the existing smoke suites after the rebuild, each started with
  `powershell.exe .\Hub.ps1 -SkipMutex -Port <free-port>` (the `-SkipMutex` switch shipped
  in v1.5.0.0) so they pass even with a live Hub.exe holding the
  `Global\HubInstance.<username>` mutex.

## Risks & mitigations — full threat model (where plaintext could leak)

| Leak vector | Risk | Mitigation |
|-------------|------|------------|
| **Command line (argv)** | Local user reads `Win32_Process.CommandLine`; EDR/process-audit captures it | **Stdin injection** for secret runs (Step 4); secrets NEVER on argv. Smoke-tested. |
| **`runs.jsonl` history** | Value persisted to disk | History logs only itemId/exitCode/status/duration (Hub-History.ps1 L34–42) — no values/argv. Keep it that way; assert in smoke test. |
| **SSE log stream** | Value streamed to browser | Hub only streams child stdout/stderr. Hub never writes the value to a stream. Echo-back by the *user's own script* is an accepted, documented limitation (Step 0 item 5). |
| **`hub-error.log`** | Value in an exception/log message | `Write-HubError` only logged with generic messages; resolver/decrypt catch blocks must NOT interpolate `$value`. Code review + grep for `"$secret"` interpolation. |
| **Exported `.hubflow`** | Value embedded in export | Only `@secret:<name>` tokens live in params; export scrub pass rejects any literal in a password field (Step 5). |
| **GET API responses** | Value returned by list/detail | API is write-only for values; only metadata returned (Step 2). The single decrypt path is the run-time resolver. |
| **Browser memory / DOM** | Value cached client-side | UI never fetches values; password inputs are write-only and cleared after save; run form sends only the `@secret:` token. |
| **At rest** | Blob readable by another local user / on backup | DPAPI `CurrentUser` scope — only the same Windows user can decrypt; `%LOCALAPPDATA%` is non-roaming (no OneDrive/profile sync). |
| **Import overwrite/RCE** | Malicious `.hubflow` overwrites a workflow or auto-runs a script | Force fresh `id`; reuse `Test-WorkflowSchema`; never auto-run; trust warning + unresolved-scripts flag (Step 5). |
| **Secret name as path/XSS** | Name used as filename / rendered in UI | Strict charset; on-disk name = SHA256 hash, not raw; UI escapes names. |
| **`-File` can't bind stdin params** | Implementation lands secret on argv as a fallback | Use the `-Command` shim that binds securestring/pscredential from stdin (Step 4 item 2); fail closed if the shim path is unavailable rather than falling back to argv. |

Other risks:
- **PS5 vs PS7 DPAPI:** `System.Security` assembly load differs. Mitigation: guarded
  `Add-Type`; test on both runtimes (Hub.exe = PS5/.NET Framework; child = pwsh7).
- **Shim correctness across param kinds:** securestring vs pscredential binding. Mitigate
  with fixture scripts for each kind in the smoke suite.
- **Route ordering regressions:** new matchers must precede the generic `{id}` matcher.
  Mitigate by ordering in `Invoke-Route` and asserting each route resolves in tests.

## Rollback plan

- All new code is additive (two new modules + isolated route/spawn branches). To roll
  back: revert the Hub.ps1 dot-source lines, the `$Script:StateRoutes` additions, the
  `Invoke-Route` branches, and the `Start-HubJob`/`Invoke-RunRoute` secret branch; remove
  the two new modules and the UI additions; rebuild the prior version.
- Data safety: `%LOCALAPPDATA%\Hub\secrets\` is independent of config/workflows; leaving
  the dir in place after rollback is harmless (no reader without the routes). The
  non-secret run path is byte-for-byte unchanged when no secret is referenced, so reverting
  cannot corrupt existing runs/workflows.
- Export/import is read/write of files only; rollback removes the routes — existing
  workflows untouched.
- Ship rollback as v1.7.0.1 rebuild if a production issue surfaces.

## Definition of Done

- [ ] Step 0 `rune:adversary` review completed; all 7 mandatory questions resolved and
      folded into the plan/implementation.
- [ ] **PS5.1-safe:** `Hub-Secrets.ps1` and `Hub-Export.ps1` contain no `??`/ternary/`?.`/
      `-AsHashtable`; all list responses use `ConvertTo-Json -InputObject` + `'[]'` fallback.
- [ ] **Step 7.5 parse-gate passed** under `powershell.exe` (5.1) for both new modules
      (ParseFile + clean dot-source) BEFORE any exe build.
- [ ] New smoke suites sandbox `TEMP`+`LOCALAPPDATA`, start Hub with `-SkipMutex -Port`, and
      assert HTTP status codes; they never touch the real secrets dir.
- [ ] `Hub-Secrets.ps1` stores DPAPI-`CurrentUser`-encrypted values; on-disk blob never
      contains plaintext (smoke-verified).
- [ ] `/api/secrets` CRUD is CSRF-gated and write-only for values; no GET returns a value.
- [ ] Secret values never appear in `runs.jsonl`, SSE, `hub-error.log`, or `.hubflow`
      (each asserted by a smoke test).
- [ ] Secret runs inject via stdin; plaintext is provably absent from every child
      `Win32_Process.CommandLine`.
- [ ] **ADV-301:** a secret-bearing step's `{{step-N.stdout}}` refs are dropped — smoke proves
      an echoed secret never reaches a downstream step's `Win32_Process.CommandLine`.
- [ ] **ADV-302:** secret run of an `exit 3` fixture reports exit 3 (shim `exit $LASTEXITCODE`).
- [ ] **ADV-303/304:** stdin payload carries per-param kind+username, fails closed on bad kind;
      secret value > 64 KB rejected.
- [ ] `securestring`/`pscredential`/`password` params bind the resolved secret correctly
      (fixture verifies received value via hash).
- [ ] Workflow export produces a `.hubflow` with canvas, no values; import forces a fresh
      id, runs `Test-WorkflowSchema`, shows a trust warning, and flags unresolved scripts.
- [ ] UI: Secrets tab (write-only), password-field secret dropdown, export download,
      import dialog with trust warning.
- [ ] All four existing smoke suites + the two new suites pass (Hub started with `-Port`
      / `-SkipMutex`).
- [ ] `CHANGELOG.md`, `README.md` security model, `HANDOFF.md` updated; `$Script:Version`
      = `1.7.0.0`; Hub.exe rebuilt and `/api/version` reports `1.7.0.0`; the
      `build-release.ps1` commit includes the rebuilt `Hub.exe` (`git log -1 --stat`).
