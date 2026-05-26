# Hub — Cards Bigger, Schema-Driven Card Previews, Autodetect Coverage

**Status:** Approved design (brainstorm complete) — ready for `rune:plan`
**Date:** 2026-05-26
**Approver:** Patryk-beep
**Selected approach:** Option B (schema-driven card) + Medium density chips

---

## 1. Problem

Three user-reported pains in Hub catalog UI and script runner:

1. **Cards feel cramped.** `items-grid` uses `minmax(260px, 1fr)`; card padding is tight (`14px 14px 12px`). Reads dense, not scannable.
2. **Cards hide parameter shape.** A card surfaces `name`, `description`, `kind`, `root`, `mtime`. Nothing about params — user can't tell at-a-glance whether a script needs a single file path or 12 required fields. User clicks blindly.
3. **Autodetect (`Get-ParamSchema` / `ConvertTo-WidgetSpec` in `Hub.ps1:537-675`) is incomplete.** Common PowerShell parameter shapes silently fall back to a plain textbox (or trigger `mode: 'raw'`). User must hand-type args that `ValidateRange` / `ValidateSet` / typed primitives should have driven into proper widgets.

## 2. Goals

- Catalog cards are visibly bigger and breathe more.
- Each card surfaces a **Medium-density** param preview:
  - "N params · M required" chip
  - up to 4 type icons (number / file / switch / dropdown / text / password / datetime / multi)
  - raw vs typed badge
- Schema enrichment moves from on-click to scan time — preview ships with `/api/items`, no second fetch.
- `ConvertTo-WidgetSpec` covers every common parameter shape listed in §5 below.
- Cold catalog load latency remains acceptable on large catalogs (mitigation: parallel AST parse + mtime-keyed cache file).

## 3. Non-goals

- No backend rewrite. `Hub.ps1` stays the single server file.
- No new Alpine dependencies. No build step added.
- No edits to the runner (`Invoke-RunRoute`) beyond what schema expansion forces.
- No history/favourites/usage telemetry on cards (out of scope).
- No HTML drag-reorder of params, no live ValidatePattern preview (deferred).

## 4. Hard constraints (must be honoured in plan)

1. **Backward compatibility:** existing fixtures (`tests/fixtures/*.ps1`) keep producing identical typed schemas. Smoke tests `tests/smoke-phase*.ps1` must still pass.
2. **Defence-in-depth (ADV-C1):** any new code path that resolves a script path must re-confirm it lies under a configured scan root (mirroring `Invoke-SchemaRoute`).
3. **No script execution during AST parse.** `Parser::ParseFile` only — never invoke the script for introspection.
4. **OneDrive cloud-only files:** skip AST parse (already handled at scan time — preserve that behaviour). Cloud items get `paramPreview = null` with a `cloudOnly: true` marker.
5. **JSON contract additive only:** existing fields on `/api/items` items keep their names and types. New fields (`paramPreview`, `schemaMode`) are additions; old clients must still work.
6. **Cache invalidation:** preview cache keyed by `(scriptPath, mtime, size)`. Stat-change → recompute. Cache lives under `%LOCALAPPDATA%\Hub\schema-cache.json` (or equivalent already-used cache dir).
7. **Parallel parse cap:** AST parsing parallelised but bounded (e.g. throttle to `[Environment]::ProcessorCount`) to avoid I/O thrash on cold scan of 1000+ scripts.
8. **No emoji in source files** (project house style).
9. **Caveman mode** does not affect file content — code, comments, commit messages stay normal English.

## 5. Autodetect coverage matrix (what plan must implement)

### Type-to-widget mapping (additions on top of existing)

| PowerShell type | Widget | Notes |
|---|---|---|
| `double`, `decimal`, `float`, `single` | `number` | `step="any"` |
| `datetime` | `datetime-local` | ISO round-trip |
| `guid` | `textbox` | pattern attr `^[0-9a-fA-F-]{36}$` |
| `uri` | `url` | input type=url |
| `securestring`, `pscredential` | `password` | masked; serialised as plain string back to PS (no SecureString round-trip — flagged in help text) |
| `object[]`, `double[]`, `bool[]`, `switch[]` | `textarea-multi` | one per line |
| `hashtable` | `textarea-multi` | `key=value` per line; parsed server-side |
| `scriptblock` | `raw` fallback for that field | not safe to surface as typed widget |

Existing mappings (string / int family / bool / switch / `string[]` / `int[]` / FileInfo / ValidateSet) stay as-is.

### Validator-to-constraint mapping

| Validator | Effect on field spec |
|---|---|
| `ValidateRange(min, max)` | `min`, `max` on number widget |
| `ValidatePattern(regex)` | `pattern` attr + help text "matches /regex/" |
| `ValidateLength(min, max)` | `minlength`, `maxlength` |
| `ValidateCount(min, max)` | `countMin`, `countMax` rendered as hint on textarea-multi |
| `ValidateNotNullOrEmpty` | `required = true` (only if not already set) |
| `ValidateScript({...})` | surfaced as `help` note "custom validation runs server-side" — no client-side enforcement |

### Metadata additions

| Source | Field on widget spec | Behaviour |
|---|---|---|
| Comment-based help `<# .PARAMETER name #>` | `help` (fallback when `[Parameter(HelpMessage=...)]` absent) |
| `Position = N` | `position` (sort order in form) |
| `[Alias('x','y')]` | `aliases: ['x','y']` (rendered under field name) |
| ParameterSet membership | `parameterSet: 'name'` (UI groups by set; default set = `'__AllParameterSets'`) |
| `AllowNull` / `AllowEmptyString` | `allowEmpty: true` |

### Param preview (slim — used on cards)

```json
{
  "count": 5,
  "requiredCount": 2,
  "typeTags": ["string", "number", "file", "switch"],
  "schemaMode": "typed",
  "parameterSets": 1
}
```

`typeTags` deduplicated, max 4 entries (order: required-types first, then by frequency).

## 6. UI changes (frontend)

### Card

- `items-grid` minmax bumped: `260px` → `320px`.
- `.item-card` padding: `14px 14px 12px` → `18px 18px 16px`.
- New `<div class="item-card-params">` slotted between description and `.item-foot`, rendering:
  - param count chip `5 params`
  - required chip `2 required` (omitted if 0)
  - up to 4 inline type icons (lucide-style, reuse existing sprite where possible — add new symbols for `number`, `password`, `datetime`, `multi`)
  - raw-mode badge when `schemaMode === 'raw'` (replaces icons)
- Card stays clickable; chips are visual only (no click handlers).

### Form pane

Renders new widget types added in §5 with input types `password`, `datetime-local`, `url`; respects `min`/`max`/`pattern`/`minlength`/`maxlength`. ParameterSet groups rendered as `<fieldset>` headings when more than one set exists. Aliases shown as muted text under field name.

## 7. Backend changes (`Hub.ps1`)

- `ConvertTo-WidgetSpec` extended per §5 (single function — additions only, no removal of existing branches).
- New function `Get-ParamPreview` — returns the slim JSON in §5 from a parsed AST (reuses `Get-ParamSchema`'s `paramBlock`).
- `Get-HubItems` enriches each item with `paramPreview` and `schemaMode`. AST parsing of `.ps1` items parallelised via runspace pool, bounded by `[Environment]::ProcessorCount`. `.exe` and cloud-only items skip parse and return `paramPreview = null`, `schemaMode = 'raw'`.
- New cache file `%LOCALAPPDATA%\Hub\schema-cache.json` (or existing cache dir if one exists — confirm during plan phase) keyed by `(path, mtime, size)`. Hit avoids re-parse; miss parses and stores.
- New helper to parse comment-based help (`.PARAMETER`) — pulls help text from `HelpContent.Parameters` of the AST.

## 8. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Cold-load latency spike on big catalogs | Bounded runspace pool + on-disk cache (skip parse when mtime+size unchanged). Show catalog as soon as raw items are listed; stream preview augmentation. |
| Cache file corruption | JSON parse failure → silent rebuild from scratch. Cache is purely advisory. |
| Comment-based help parse cost | `HelpContent()` lazy — only called when AST has a comment-based help block. |
| Securestring widget gives false sense of security | Help text states value is sent over loopback as plain string; not stored. |
| Hashtable textarea parsing edge cases | Server-side parse converts `key=value` lines into `[hashtable]`; malformed lines surface as a 400 with line number. |
| Parallel AST parse races | Each runspace gets its own `Parser` invocation. No shared mutable state during parse. Aggregation happens single-threaded. |

## 9. Verification (smoke and unit)

- All `tests/smoke-phase*.ps1` continue to pass unchanged.
- New fixture script `tests/fixtures/all-widgets.ps1` exercises every type/validator added in §5.
- New smoke `tests/smoke-schema-coverage.ps1` asserts:
  - `GET /api/items/<id>/schema` for `all-widgets.ps1` returns every expected widget shape.
  - `GET /api/items` carries `paramPreview` on every `.ps1` item; cloud-only items carry `paramPreview = null`.
  - Cache file written on first request; second request to same item hits cache (mtime check).

## 10. Out-of-scope follow-ups (capture but don't implement now)

- Card filter "scripts with no required params".
- ValidatePattern live preview / regex playground.
- DynamicParam support (would require running the script, currently forbidden).
- ParameterSet picker UI when sets are mutually exclusive.

## 11. Handoff payload to `rune:plan`

- **Approach:** Option B — schema-driven card with scan-time enrichment.
- **Density:** Medium — count chip + required chip + up to 4 type icons + raw badge.
- **Constraints to honour:** §4 1–9 above.
- **Risks to mitigate in phase plan:** §8.
- **Out-of-scope:** §10.
- **Verification gates:** §9 — existing smoke tests must stay green; new smoke test added.
