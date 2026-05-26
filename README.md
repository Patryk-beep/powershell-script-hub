# Hub — Script & Tool Dashboard

[![Release](https://img.shields.io/github/v/release/Patryk-beep/powershell-script-hub?display_name=tag&sort=semver)](https://github.com/Patryk-beep/powershell-script-hub/releases)
[![License](https://img.shields.io/github/license/Patryk-beep/powershell-script-hub)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-blue)](https://github.com/Patryk-beep/powershell-script-hub)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%2F%207-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)

A local web dashboard that auto-discovers PowerShell scripts (`.ps1`) and tools (`.exe`) in folders you configure, renders them as a clickable grid, generates input forms from each script's `param()` block, and runs them with live log streaming.

- **Localhost-only** — binds to `127.0.0.1`, never accessible from the network.
- **No dependencies** — single PowerShell-compiled `.exe` plus a static frontend.
- **No install footprint** — config lives in `%LOCALAPPDATA%\Hub\`.

## Requirements

- Windows 10 or 11
- PowerShell 5.1 (built into Windows — used by the installer)
- PowerShell 7 — used to spawn user scripts. If not present, the installer will
  offer to install it via `winget install Microsoft.PowerShell`.

## Install

```powershell
irm https://raw.githubusercontent.com/Patryk-beep/powershell-script-hub/v1.4.13.0/install-hub.ps1 | iex
```

That one-liner is **tag-pinned** to a specific release. It will not silently
upgrade if `main` changes. Per-user install — no admin required.

If GitHub rate-limits the request (rare), pass `-Version v1.4.13.0` to skip the
`latest` lookup:

```powershell
$args = @{ Version = 'v1.4.13.0' }
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Patryk-beep/powershell-script-hub/v1.4.13.0/install-hub.ps1))) @args
```

### What the installer does

1. Checks for PowerShell 7. Offers to install via winget (source-pinned to the
   official Microsoft CDN — refuses to proceed if the source has been replaced).
2. Downloads `Hub.zip` from the GitHub release and verifies its SHA256 against
   a hex string embedded in the installer itself.
3. Extracts to `%LOCALAPPDATA%\Programs\Hub\`.
4. Prompts for scan-root folders (defaults: `%USERPROFILE%\Tools` and
   `%USERPROFILE%\Documents\Scripts`) and writes `%LOCALAPPDATA%\Hub\hub-config.json`.
5. Creates a Start Menu shortcut named **PowerShell Hub**.
6. Launches Hub. Browser opens to `http://127.0.0.1:8765`.

### Flags

| Flag | Effect |
|---|---|
| `-InstallDir <path>` | Override install location (default `%LOCALAPPDATA%\Programs\Hub`). |
| `-ScanRoots @('C:\a','C:\b')` | Skip the interactive prompt (useful for scripted installs). |
| `-Autostart` | Add an `HKCU\...\Run` entry so Hub launches at sign-in. |
| `-NoLaunch` | Install but don't open the browser. |
| `-Version v1.4.13.0` | Pin a specific release tag (default). |
| `-VerifyHash <sha256>` | Override the embedded hash check (e.g. when piping a custom build). |

## Update

```powershell
irm https://raw.githubusercontent.com/Patryk-beep/powershell-script-hub/v1.4.13.0/install-hub.ps1 | iex -Update
```

Or, if you already have the installer on disk:

```powershell
.\install-hub.ps1 -Update
```

`-Update` re-downloads the release zip and overwrites the install dir. Your
`hub-config.json` lives at `%LOCALAPPDATA%\Hub\` (outside the install dir) and
is never touched.

## Uninstall

```powershell
.\install-hub.ps1 -Uninstall
```

Removes the install dir, Start Menu shortcut, and autostart key. You will be
asked separately whether to also delete the config at `%LOCALAPPDATA%\Hub\`.
Your scan-root folders themselves are never deleted.

## Offline install / air-gapped

Grab two files from the [release page](https://github.com/Patryk-beep/powershell-script-hub/releases):

1. `Hub.zip` — the release asset.
2. `install-hub.ps1` — the version of the installer published at the same tag.
   The installer baked into a release matches its own zip's hash exactly; the
   raw URL above also points to the same content (this is the "fresh installer
   from URL" path). Either is safe.

Copy both to the target machine and run:

```powershell
.\install-hub.ps1 -VerifyHash <sha256-of-Hub.zip-from-release-notes>
```

The installer will skip the network fetch path if you supply `Hub.zip` next to
itself (planned for v1.2; for now, run with `-Version v1.4.13.0` and let it
download from GitHub).

## First run

1. The installer launches Hub automatically. If it didn't, double-click the
   Start Menu shortcut.
2. The setup wizard opens in the browser if your scan-roots weren't provided.
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
%LOCALAPPDATA%\Programs\Hub\        ← install dir (overwritten on -Update)
├── Hub.exe                         ← compiled tray app (the shortcut launches this)
├── Hub.ico                         ← multi-res icon
├── README.md                       ← bundled docs
└── wwwroot\                        ← static frontend (Alpine.js, vendored)

%LOCALAPPDATA%\Hub\                 ← state dir (preserved across -Update)
└── hub-config.json                 ← scan roots, hidden items, schema version

%TEMP%\hub-error.log                ← runtime log

Repository (for contributors):
├── Hub.ps1                         ← THE source (~1700 LOC)
├── build-hub.ps1                   ← rebuild Hub.exe (PS2EXE required)
├── build-icon.ps1                  ← regenerate Hub.ico
├── install-hub.ps1                 ← end-user installer
├── build-release.ps1               ← release pipeline (dev-only)
└── docs\plans\                     ← design docs
```

## Security model

### Runtime
- **Origin allowlist + Host header pin** — blocks DNS-rebinding and cross-origin POST.
- **CSRF cookie + `X-Hub-CSRF` header** — required on every state-changing request.
- **`SameSite=Strict` cookie** — cross-site contexts cannot read CSRF.
- **AST-only param introspection** — scripts are never executed to discover their parameters.
- **Argv-array spawning** — no shell metacharacter interpretation.
- **Path-traversal guard** — static file serving rejects anything outside `wwwroot\`.
- **Scan-root enforcement** — `/api/run` re-validates that the resolved item path is still under a configured scan root.

### Supply chain
The one-liner runs in your user context. The trust model:

- The installer URL is **tag-pinned** (`/v1.4.13.0/`), not `/main/`. A compromised
  `main` branch cannot push a malicious installer to existing users — they
  would have to type out a new tag manually.
- `Hub.zip` is verified by **SHA256** before extraction. The expected hash is
  embedded in the installer at release-build time (see `build-release.ps1`).
- Pin-and-verify only protects what you trust. If you fork the repo, or if you
  install from an unreviewed tag, you are trusting whoever pushed that tag.
- `Hub.exe` is **unsigned** today. SmartScreen will block the first launch.
  Codesigning is on the roadmap.

### What the installer will NOT do
- Require admin or elevate via UAC.
- Modify system PATH.
- Write to `HKLM\` (machine-wide registry).
- Delete your scan-root folders during `-Uninstall`.
- Run any script discovered during the scan.

## Rebuild from source

```powershell
pwsh -NoProfile -File .\build-hub.ps1 -Version 1.1.0.0
```

Requires PowerShell 7 and the `ps2exe` module:

```powershell
Install-Module ps2exe -Scope CurrentUser
```

## License

MIT. See [LICENSE](LICENSE).
