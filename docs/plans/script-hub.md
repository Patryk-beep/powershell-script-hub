# Script & Tool Hub Dashboard — Approved Design

> Approved by user on 2026-05-18. Output of `/rune:brainstorm`.
> Next step: hand off to `rune:plan` for phased implementation plan.

---

## 1. Problem

User has growing collection of PowerShell scripts and compiled `.exe` tools spread across multiple folders. Discovery + invocation is the pain point — hunting through OneDrive paths and remembering each script's argument signature. Wants a single front-end that surfaces every script and tool, auto-detects new ones, and runs them with generated input forms.

## 2. Approved approach: **Option B — PS Backend + External Static Files**

A single PowerShell-based local web dashboard. PS2EXE-compiled launcher opens a browser tab to a small HTTP server that lists every script/tool discovered under known roots and runs them on demand with streamed output.

### Architecture

```
%USERPROFILE%\Tools\Hub\
├── Hub.exe                ← user double-clicks (or tray icon)
├── Hub.ps1                ← THE source
├── Hub.ico                ← multi-res icon
├── build-icon.ps1
├── HANDOFF.md             ← (created during implementation)
├── wwwroot\               ← external static frontend
│   ├── index.html
│   ├── app.js             ← Alpine.js or htmx, no build step
│   └── style.css          ← Rosé Pine Moon palette (match WavTo16k)
└── docs\
    └── plans\
        └── script-hub.md  ← (this file)
```

### Runtime flow

1. `Hub.exe` starts → spawns tray icon (NotifyIcon).
2. Starts `System.Net.HttpListener` bound to `http://127.0.0.1:8765/` only.
3. Opens default browser to `http://localhost:8765/`.
4. Browser loads `wwwroot\index.html` + `app.js` + `style.css`.
5. JS calls `GET /api/items` → backend scans roots, returns JSON catalog.
6. User clicks a script → JS calls `GET /api/items/{id}/schema` → form rendered from parsed `param()` block.
7. User submits → `POST /api/run` → backend `Start-Process`es script with async stdout/stderr readers, returns `jobId`.
8. JS opens `EventSource /api/stream/{jobId}` → SSE pushes stdout lines as they arrive.
9. Kill button → `POST /api/jobs/{jobId}/kill` → `Stop-Process`.

## 3. Constraints (must hold through plan + implementation)

| # | Constraint | Why |
|---|---|---|
| 1 | HttpListener bound to `127.0.0.1` only (NOT `+` or `0.0.0.0`) | No LAN/network exposure. Avoid Windows Firewall prompt. |
| 2 | Scan roots: user-configurable at setup time (defaults: `%USERPROFILE%\Tools` and `%USERPROFILE%\Documents\Scripts`) | Setup wizard collects roots on first run; persists to `%LOCALAPPDATA%\Hub\hub-config.json`. |
| 3 | Discovery = folder scan only (no manifest, no header metadata) | User chose simplest model. New `.ps1` or `.exe` dropped in root = auto-listed. |
| 4 | `param()` introspection via `[System.Management.Automation.Language.Parser]::ParseFile` | Same parser proven safe in WavTo16k parse-check. Maps PS types to form widgets. |
| 5 | `.exe` entries shown but have no auto-generated form — raw arg string textbox | We can't introspect compiled binaries. Optional preset argv saved per-tool later. |
| 6 | Stdout/stderr streamed via Server-Sent Events (`text/event-stream`) | No WebSocket library dependency. SSE is one-way which matches log streaming. |
| 7 | Async stream readers + `WaitForExit()` on both success and timeout paths | Same lesson from WavTo16k §4 — `ReadToEnd()` deadlocks on full pipe buffers. |
| 8 | Static frontend lives in `wwwroot\` (NOT embedded in `Hub.ps1`) | UI iteration without rebuilding. Same lesson — embedded UI strings rot fast. |
| 9 | PS2EXE compiled with `-noConsole -STA`, `[Assembly]::GetEntryAssembly().Location` for self-path | Inherited from WavTo16k §4 — `$MyInvocation.MyCommand.Path` is forbidden under PS2EXE. |
| 10 | Path normalization via `[System.IO.Path]::GetFullPath` (NOT `Resolve-Path`) | OneDrive + 8.3 short-alias issue documented in WavTo16k HANDOFF §3. |
| 11 | Rebuild prelude must `Set-ExecutionPolicy -Scope Process -Bypass` | OneDrive-redirected `Documents` PowerShell modules are Restricted. |
| 12 | Visual style = Rosé Pine Moon palette | Consistency with WavTo16k. Iris accent / Foam ok / Gold skip / Love error. |
| 13 | No script execution from outside the configured scan roots | Defence: even if `/api/run` is hit with a forged path, reject anything not under a scan root after `GetFullPath` normalization. |
| 14 | Magic-byte / extension gate on items shown — `.ps1` and `.exe` only | Don't list every random file under Tools\. Whitelist extensions. |

## 4. Deferred (NOT v1 scope)

- Job history / re-run from history (Option C job queue) — defer until proven need.
- Scheduling / cron-like recurrence.
- Sidecar manifest for description, icon, categories.
- Auth — irrelevant for localhost-only.
- HANDOFF.md viewer pane.

## 5. Risks flagged for plan

| Risk | Mitigation must land in plan |
|---|---|
| HttpListener ACL on Windows — bind may require `netsh urlacl` for non-admin first run | Plan must include `netsh http add urlacl url=http://127.0.0.1:8765/ user=...` step OR run as current user with `+` workaround. Document. |
| `param()` block parser edge cases (typed `[hashtable]`, dynamic params, `ValidateScript`) | Plan must define fallback: if no widget mapping, render raw text input + arg-string mode. |
| Long-running script kept alive across browser refresh | Plan must define: job state stored in-memory `$Script:Jobs` hashtable, browser reconnects to existing SSE stream by jobId. |
| User browser opens to wrong URL if port 8765 busy | Plan must pick port at startup (try 8765, fall back), write actual port to a tray-icon tooltip / a small `$env:TEMP\hub.port` file. |
| Process kill on `.exe` children (Stop-Process kills only top — child trees survive) | Plan must use `taskkill /T /F /PID` or `Process.Kill($true)` (Kill entire process tree). |

## 6. Next step

Invoke `rune:plan` with:
- **Approach**: Option B (PS Backend + External wwwroot)
- **Project root**: `%USERPROFILE%\Tools\Hub` (install location)
- **Constraints**: all 14 above (hard)
- **Risks to mitigate**: all 5 above
