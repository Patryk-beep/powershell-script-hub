## Highlights

- **Extended `param()` autodetect** — covers `double`, `decimal`, `float`, `datetime`, `guid`, `uri`, `securestring`, `hashtable`, `scriptblock`, primitive arrays, plus all `Validate*` attributes, `[Alias]`, `Position`, `ParameterSetName`. Comment-based `.PARAMETER` help honoured as fallback.
- **`paramPreview` on `/api/items`** — every card surfaces count + required + type icons. Backed by a mtime+size-keyed JSON cache.
- **shadcn-hybrid neutral palette** + vendored Geist Sans + Geist Mono fonts (Latin subset WOFF2, ~42 KB total).
- **Glassmorphism overlay** — animated multi-blob gradient underlay (violet / cyan / magenta / amber); floating header card; glass-tinted cards / log pane / dialogs. `prefers-reduced-motion` honoured throughout.
- **Command-K palette** — `Ctrl+K` (or `Cmd+K`) opens fuzzy-search overlay over the catalog. Pure client-side filter; no new API.
- **PS5 codepage parse-error fix** — `.ps1` scripts saved as UTF-8 without BOM containing non-ASCII glyphs (e.g. check / cross marks) no longer fall through to raw mode.

## Install / Update

```powershell
irm https://raw.githubusercontent.com/Patryk-beep/powershell-script-hub/v1.4.13.0/install-hub.ps1 | iex
```

Existing installs:
```powershell
irm https://raw.githubusercontent.com/Patryk-beep/powershell-script-hub/v1.4.13.0/install-hub.ps1 | iex -Update
```

## Verification

- 11/11 smoke tests green (3 foundational + 3 schema + 1 schema-coverage + 3 UI + 1 UI-aggregate).
- Hub.exe v1.4.13.0 (~126 KB, PS2EXE Desktop PS5 runtime).
- AST-only introspection — no script execution during catalog scan or schema fetch (verified via sentinel fixtures).

See [CHANGELOG.md](https://github.com/Patryk-beep/powershell-script-hub/blob/v1.4.13.0/CHANGELOG.md) for the full diff.
