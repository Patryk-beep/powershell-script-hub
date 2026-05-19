# Hub — Script & Tool Dashboard

A local web dashboard that auto-discovers PowerShell scripts (`.ps1`) and tools (`.exe`) in folders you configure, renders them as a clickable grid, generates input forms from each script's `param()` block, and runs them with live log streaming.

- **Localhost-only** — binds to `127.0.0.1`, never accessible from the network.
- **No dependencies** — single PowerShell-compiled `.exe` plus a static frontend.
- **No install footprint** — config lives in `%LOCALAPPDATA%\Hub\`.

## Install

```powershell
iwr https://raw.githubusercontent.com/Patryk-beep/powershell-script-hub/v1.1.0/install-hub.ps1 -OutFile $env:TEMP\install-hub.ps1
.\install-hub.ps1
```

Or download the latest release zip from [Releases](https://github.com/Patryk-beep/powershell-script-hub/releases) and unpack to `%USERPROFILE%\Tools\Hub\`.

## First run

1. Double-click `Hub.exe`. Browser opens the setup wizard.
2. Add the folders you want Hub to scan (e.g. `%USERPROFILE%\Tools`, `%USERPROFILE%\Documents\Scripts`). Defaults are suggested but optional.
3. Save. Hub reloads with your scripts listed.

## SmartScreen warning

`Hub.exe` is currently unsigned. On first launch Windows Defender SmartScreen may show "Windows protected your PC".

Options:
- Click **More info** → **Run anyway**.
- Or unblock first: `Unblock-File <path>\Hub.exe` then launch.
- Or verify the SHA256 against the published release hash before unblocking.

Codesigning is on the roadmap.

## Architecture

```
%USERPROFILE%\Tools\Hub\
├── Hub.exe              ← compiled tray app (you launch this)
├── Hub.ps1              ← source
├── Hub.ico              ← multi-res icon
├── build-hub.ps1        ← rebuild script (PS2EXE required)
├── build-icon.ps1       ← regenerate Hub.ico
├── wwwroot\             ← static frontend (Alpine.js, vendored)
└── docs\plans\          ← design docs
```

Config: `%LOCALAPPDATA%\Hub\hub-config.json` (created by setup wizard).
Runtime log: `%TEMP%\hub-error.log`.

## Security model

- **Origin allowlist + Host header pin** — blocks DNS-rebinding and cross-origin POST.
- **CSRF cookie + `X-Hub-CSRF` header** — required on every state-changing request.
- **`SameSite=Strict` cookie** — cross-site contexts cannot read CSRF.
- **AST-only param introspection** — scripts are never executed to discover their parameters.
- **Argv-array spawning** — no shell metacharacter interpretation.
- **Path-traversal guard** — static file serving rejects anything outside `wwwroot\`.
- **Scan-root enforcement** — `/api/run` re-validates that the resolved item path is still under a configured scan root.

## Rebuild from source

```powershell
pwsh -NoProfile -File .\build-hub.ps1 -Version 1.1.0.0
```

Requires PowerShell 7 and the `ps2exe` module:

```powershell
Install-Module ps2exe -Scope CurrentUser
```

## License

MIT. See `LICENSE` (TODO).
