# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/Patryk-beep/powershell-script-hub/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/Patryk-beep/powershell-script-hub/releases/tag/v1.1.0
