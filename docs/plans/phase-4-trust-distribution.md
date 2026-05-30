# Phase 4 — Trust & distribution (target v1.8.0.0)

## Goal
Remove the #1 adoption blocker (SmartScreen on an unsigned exe) and harden distribution
without breaking the existing trust model (tag-pinned URL, SHA256-pin-and-verify,
no silent auto-upgrade, no admin/UAC, no HKLM). Five deliverables, executed in this order
(each depends on the prior):

1. **Code signing** — sign `Hub.exe` in the release pipeline so Authenticode validates and
   SmartScreen reputation can begin to accrue.
2. **winget package** — author + submit a manifest to `microsoft/winget-pkgs` (favoured once
   the binary is signed).
3. **Self-update banner** — read-only "update available" surface that respects the tag-pin
   (never auto-downloads/executes).
4. **Doctor / diagnostics page** — in-app health check to cut support friction.
5. **Portable mode** — config beside the exe for USB / locked-down machines.

Ordering rationale (per task brief): signing must precede winget (winget review favours signed
binaries) and precede the self-update banner (a banner that points users at a download is only
trustworthy once that download is signed).

## Dependencies / prerequisites
- **Signing identity (item 1) is a hard gate for items 2 and the banner's value prop.** It
  requires an external decision + onboarding that can take days (identity validation). Start it first.
- `gh` CLI authenticated (already required by `build-release.ps1 -Publish`).
- `ps2exe` module (already required by `build-hub.ps1`).
- Windows SDK `signtool.exe` on the build machine (new requirement for signing).
- For Azure Artifact Signing path: a **paid** Azure subscription (free/trial/sponsored are
  rejected — confirmed in the Artifact Signing FAQ), `Az.CodeSigning`/dlib + `Trusted Signing`
  dotnet tool, and a completed Identity Validation.
- Items 4 + 5 (doctor, portable) are backend-coupled → ship in the v1.8.0.0 exe rebuild.
- No new runtime dependencies introduced in Hub.ps1 (constraint preserved).

---

## DECISION GATE — signing identity (resolve before writing any pipeline code)

The eligibility data splits cleanly (Artifact Signing FAQ, retrieved 2026-05):

> Public Trust certificates are available to **organizations** in the USA, Canada, the EU, and
> the UK, **and to individual developers in the USA and Canada only**.

So the geography constraint is **not** "EU is blocked" — it is "EU is blocked *as an individual*,
supported *as an organization*." Three branches:

| Branch | When to pick | Cost / effort | Notes |
|---|---|---|---|
| **A. Azure Artifact Signing as an EU organization** | Owner can validate as a registered org (sole proprietorship / company) | ~$10/mo, 5,000 sigs (Basic). Cloud HSM, no hardware. FIPS 140-2 L3. | Cert CN = validated legal entity name (no custom CN/O). Identity validation can take days and allows 3 attempts. **Preferred if an org identity exists.** |
| **B. Azure Artifact Signing as a US/CA individual** | Owner is a self-employed individual in US/CA | Same ~$10/mo | As of 2026 the old 3-year-history requirement is dropped for individuals. **Not available to an EU individual.** |
| **C. Traditional OV cert in Azure Key Vault** | Owner is an EU individual unwilling to register as an org | OV cert ~$200–400/yr from a CA (Sectigo/DigiCert), stored in Key Vault, signed via `AzureSignTool` | Higher cost, annual renewal, but no org requirement. EV (~$300–700/yr + token/HSM) is overkill — Artifact Signing explicitly does **not** issue EV and EV gives no SmartScreen instant-trust guarantee anymore. |
| **D. Defer** | None of the above acceptable now | $0 | Ship items 3/4/5 in v1.8.0.0; leave signing + winget for a later tag. |

**Action:** the plan below assumes branch **A or C** (both terminate in a `signtool`-compatible
flow). The only code difference is the credential/dlib config block in `build-release.ps1`;
the pipeline ordering is identical. Document the chosen branch in `CHANGELOG.md` for the release.

**Critical correctness note (signing is additive, not a replacement):** signing does NOT replace
the SHA256 pin. The pin stays exactly as-is; the signature is an extra trust signal layered on top.
Do not weaken or remove `$Script:ExpectedZipHash` verification.

---

## Files touched (existing + new, absolute repo paths)

**Existing — edited:**
- `C:\Users\Harrold\Documents\Claude Projects\Hub\build-release.ps1` — insert sign step between build and stage; surface signing config.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\Hub.ps1` — bump `$Script:Version` to `1.8.0.0` (line 24); introduce `$Script:DataDir` + portable detection; dot-source new diagnostics module; register two new GET routes in `Invoke-Route`; fix `Get-HubCacheDir` to use `$Script:DataDir`.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\README.md` — rewrite SmartScreen section; add winget install option; add Portable mode + Diagnostics sections.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\install-hub.ps1` — soften SmartScreen messaging on first launch (signed build); add `-Portable` passthrough doc (installer itself stays %LOCALAPPDATA% based).
- `C:\Users\Harrold\Documents\Claude Projects\Hub\wwwroot\app.js` — fetch `/api/version-check`, render banner; add Diagnostics view fetching `/api/doctor`.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\wwwroot\index.html` — banner element + Diagnostics tab/panel.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\wwwroot\style.css` — banner + diagnostics styling.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\CHANGELOG.md` — v1.8.0.0 entry (release-notes file for `gh release create`).

**New:**
- `C:\Users\Harrold\Documents\Claude Projects\Hub\Hub-Diagnostics.ps1` — `Invoke-DoctorRoute`, `Invoke-VersionCheckRoute`, `Get-LatestReleaseCached` (matches the existing one-module-per-feature pattern; keeps Hub.ps1 under 500-line spirit).
- `C:\Users\Harrold\Documents\Claude Projects\Hub\manifests\Hub.PowerShellHub\<version>\*.yaml` — winget multi-file manifest staged locally before PR (installer / locale / version files). Final home is the fork of `microsoft/winget-pkgs`, not this repo; keep a copy here for reproducibility.
- `C:\Users\Harrold\Documents\Claude Projects\Hub\tests\smoke-phase4-diagnostics.ps1` — smoke for `/api/doctor`, `/api/version-check`, portable fork.

---

## Implementation steps

### Item 1 — Code signing

1.1 **Resolve the decision gate above.** / external / DoD: a credential the build machine can use
non-interactively (managed identity, service principal env vars, or Key Vault access) and a
`signtool`/`AzureSignTool` invocation that succeeds on a throwaway exe.

1.2 **Add the sign step to `build-release.ps1` between build and stage.** / after line 80
(`Write-Done "Hub.exe built …"`), before line 84 (`Staging`). / Sign `$exePath` **in place** so the
already-built exe carries the signature before it is copied into `$StagingDir` and zipped.
Gate the whole block behind a `-Sign` switch (and/or presence of signing env vars) so dry runs and
contributors without credentials still build. Pseudocode shape (no code in this plan):
`if ($Sign) { invoke signtool/AzureSignTool against $exePath with timestamp URL; throw on non-zero }`.
Use the Microsoft timestamp service `http://timestamp.acs.microsoft.com` for the Artifact Signing path.
/ verify: `signtool verify /pa /v "<repo>\Hub.exe"` reports a valid chain after this step runs.

1.3 **Confirm the hash-flow ordering is correct.** / build-release.ps1 lines 84–113. / Because signing
mutates `Hub.exe` → mutates the staged copy → mutates `Hub.zip` bytes, the SHA256 computed at
line 112 is the **signed** zip's hash, and that is exactly what gets patched into
`$Script:ExpectedZipHash` (lines 117–133). No change to the patch logic is needed — only the sign
step's *position* (1.2) guarantees the pin covers signed bytes. / verify: after a `-Sign` dry run,
extract `build\Hub.zip`, run `signtool verify` on the extracted exe, and confirm
`(Get-FileHash build\Hub.zip).Hash` equals the value now embedded in `install-hub.ps1`.

1.4 **Add a post-sign verification gate in the pipeline.** / build-release.ps1, immediately after 1.2. /
Run `signtool verify /pa /q` on `$exePath`; throw if it fails so an unsigned/broken-signature build
never reaches `gh release create`. / verify: deliberately skip signing → pipeline aborts before publish.

1.5 **Update README SmartScreen section (lines 114–123) + installer messaging.** / README.md + install-hub.ps1. /
Reframe from "unsigned, SmartScreen will block" to "signed; Authenticode verifiable via
`signtool verify /pa Hub.exe`; SmartScreen reputation accrues with download volume and may still
prompt early adopters — click More info → Run anyway, or verify the SHA256 from release notes."
Do **not** claim SmartScreen is eliminated — reputation is download-history based (confirmed in the
FAQ) even for signed binaries. Soften the first-launch warning text in `install-hub.ps1` similarly.
/ verify: README no longer says "Hub.exe is currently unsigned"; messaging promises only the
verifiable Authenticode claim.

### Item 2 — winget package

2.1 **Author a multi-file manifest** (version + installer + default-locale YAML, schema ≥ 1.6.0). /
new `manifests\Hub.PowerShellHub\<version>\`. / `InstallerType: zip` with
`NestedInstallerType: portable` + `NestedInstallerFiles` pointing at `Hub.exe`, because the release
asset is `Hub.zip` (a zip archive, not an MSI/MSIX/standalone exe). `InstallerSha256` =
the **signed** `Hub.zip` hash from item 1 (same value embedded in the installer). `InstallerUrl` =
the tag-pinned release asset URL.
**Terminology guard:** winget's `NestedInstallerType: portable` is unrelated to Hub's own
`-Portable` mode (item 5) — same word, different meaning; keep them distinct in docs.

2.2 **Document the winget feature gap (risk, not blocker).** / manifest README note + repo README. /
winget does NOT run `install-hub.ps1` (script installers are unsupported by winget). So a
`winget install` extracts the zip and registers `Hub.exe` but provides **no setup wizard, no Start
Menu shortcut, no scan-root prompt, no autostart**. Hub's existing in-app `$Script:NeedsSetup` flow
(`/api/config` → setup wizard) covers first-run config, so this degrades gracefully — but the
one-liner installer remains the richer path. State this explicitly so users choose intentionally.

2.3 **Reuse the winget-source-pin knowledge.** / doc only. / `install-hub.ps1` already verifies the
default `winget` source points at the official Microsoft CDN before installing PS7 (lines 130–135).
Carry that trust assumption into the winget instructions (install from the official source only).

2.4 **Validate + submit.** / external. / `winget validate <manifest-dir>`, then
`winget install --manifest <dir>` locally; fork `microsoft/winget-pkgs`, open one PR per package
version. Silent-install requirement is satisfied (Hub.exe self-launches; the zip+portable nested
type needs no interactive installer). / verify: `winget validate` passes; local manifest install
binds `http://127.0.0.1:8765`.

### Item 3 — Self-update banner (read-only, respects tag-pin)

3.1 **Bump `$Script:Version` AND make `build-hub.ps1` patch it.** / Hub.ps1 line 24
`'1.4.13.0'` → `'1.8.0.0'`; `build-hub.ps1`. / `$Script:Version` is the source of truth for
`/api/version`, the banner, and the doctor version check. **Currently `build-hub.ps1` only feeds
`-Version` to PS2EXE file metadata — it does NOT patch the hardcoded line 24**, so the runtime
version is a second, manually-maintained source that silently drifts. Fix it at the root: add a
patch step to `build-hub.ps1` that rewrites the `$Script:Version = '…'` literal from its `-Version`
param (same regex-replace shape `build-release.ps1` uses for the installer hash, lines 117–133).
Single source of truth, and it feeds the comparison in 3.3. / verify: `/api/version` returns
`1.8.0.0` after rebuild; bumping `build-hub.ps1 -Version` alone updates the runtime value.

3.2 **Create `Hub-Diagnostics.ps1` with `Get-LatestReleaseCached`.** / new file. / GET-only, calls the
GitHub `releases/latest` API, reusing the 403/rate-limit handling shape already proven in
`install-hub.ps1`'s `Get-ReleaseUrl` (lines 199–220). **Cache the result in a script-scope variable
with a min-refresh interval (e.g. 6h) and a hard rate-limit (e.g. one upstream call per N minutes
regardless of caller).** Rationale: `/api/version-check` is an unauthenticated localhost GET; an
open browser tab polling it could otherwise exhaust the 60-req/hr unauthenticated GitHub quota.
On upstream error, return cached/last-known or a soft `{ available: null, reason: 'unreachable' }` —
never throw to the client.

3.3 **Version comparison must normalize ARITY, not just cast.** / Hub-Diagnostics.ps1. / Internal
`$Script:Version` is 4-part (`1.8.0.0`); git tags are 3-part `vX.Y.Z` because `build-release.ps1`
line 56 strips the trailing `.0` (this release tags as `v1.8.0`). A naive string compare is wrong
(`'1.8.0' -gt '1.10.0'` lexically) — but a bare `[version]` cast is **also a trap**:
`[version]'1.8.0.0' -gt [version]'1.8.0'` evaluates **`$true`** because the 3-part tag's Revision
field is `-1` and `0 > -1`. So a fully up-to-date install would report "behind" on every release.
*Fix:* strip the leading `v`, then **pad the tag to 4 parts** (or compare only Major/Minor/Build)
before the `[version]` compare. / verify: smoke test must use the REAL pair —
internal `"1.8.0.0"` vs tag `"v1.8.0"` → "up to date" (NOT behind); `"1.8.0.0"` vs `"v1.10.0"` →
update available. (Same-arity test pairs like `1.8.0` vs `1.8.0` do not exercise the bug.)

3.4 **Register `/api/version-check` as a read-only GET route.** / Hub.ps1 `Invoke-Route`, beside
`/api/health` and `/api/config` (lines 1950–1952). / Returns
`{ current, latest, available:<bool>, oneLiner:"irm …/v<latest>/install-hub.ps1 | iex", releaseUrl }`.
The `oneLiner` is the exact tag-pinned command for the **latest** tag — surfaced for the user to
copy, never executed by Hub. **Do NOT add to `$Script:StateRoutes`** (lines 45–55) — it is not state-
changing and must not require CSRF. / verify: `curl http://127.0.0.1:8765/api/version-check` returns
the shape above; no CSRF needed.

3.5 **Frontend banner.** / wwwroot/app.js + index.html + style.css. / On load, fetch
`/api/version-check`; if `available`, render a dismissible banner: "Update available: vX.Y.Z" + the
copyable one-liner + a link to the release page. **No download button, no auto-execute** — preserves
"no silent auto-upgrade." / verify: with a stubbed newer `latest`, banner appears with correct
one-liner; dismiss persists for the session.

### Item 4 — Doctor / diagnostics page

4.1 **Add `Invoke-DoctorRoute` to `Hub-Diagnostics.ps1`.** / new file. / GET-only JSON aggregating
checks, each `{ ok:<bool>, detail:<string> }`:
- **PS7 present** — reuse `install-hub.ps1`'s `Test-Pwsh7` logic (port the function; do not exec user scripts).
- **Port bound** — `$Script:ListenerHealthy` / `$Script:Port` (already tracked, see `Invoke-HealthRoute` line 1213).
- **Config valid** — call `Read-HubConfig`; report `$Script:NeedsSetup`, version mismatch.
- **Exe version vs latest** — reuse the cached `Get-LatestReleaseCached` (3.2) — do NOT make a second upstream call.
- **Scan roots resolvable** — iterate `Get-EffectiveScanRoots` (line 537), `Test-Path` each, report missing/unreadable.
- **Data dir + portable mode** — report resolved `$Script:DataDir` and whether portable is active (item 5).
/ verify: `curl …/api/doctor` returns each check; flip a scan root to a bad path → that check reports `ok:false`.

4.2 **Register `/api/doctor` as a read-only GET** beside `/api/version-check` (NOT a state route). /
Hub.ps1 `Invoke-Route`. / verify: route returns 200; absent from `$Script:StateRoutes`.

4.3 **Frontend Diagnostics view** — a tab/panel in the existing tabbed UI (Catalog/Workflows/History →
add Diagnostics) rendering each check with ok/fail icons + detail + a "copy report" button. /
wwwroot. / verify: panel renders all checks; failing checks visually flagged.

### Item 5 — Portable mode

5.1 **Introduce a single `$Script:DataDir` and a portable fork — set BEFORE line 86.** / Hub.ps1 around
lines 61–86. / Detection precedence: explicit `-Portable` param (new, see 5.2) OR a marker file
`hub-portable.txt` next to the exe (`$Script:ScriptRoot`) → `$Script:DataDir = Join-Path $Script:ScriptRoot 'HubData'`;
else `$Script:DataDir = Join-Path $env:LOCALAPPDATA 'Hub'` (current behaviour). Then derive
`$Script:ConfigDir = $Script:DataDir`, `$Script:ConfigPath = Join-Path $Script:DataDir 'hub-config.json'`.
Must be set before line 86 because `Test-ValidScanRoot` rule 6 (line 464) reads `$Script:ConfigDir`,
and before the dot-sources (line 109) because the feature modules derive their dirs from `$Script:ConfigDir`.
**Why fork here, not literally inside `Read-HubConfig` (as the brief phrased it):** `Read-HubConfig`
only consumes `$Script:ConfigPath`; `Write-HubConfig` and all four feature modules read
`$Script:ConfigDir`. Forking at the single init point makes every consumer portable at once —
forking inside `Read-HubConfig` would fix reads but leave writes + modules on `%LOCALAPPDATA%`.
/ verify: launch with marker file present → config written next to exe.

5.2 **Add `-Portable` switch to the param block.** / Hub.ps1 lines 5–16. / `[switch]$Portable`.
Document that the installer (`install-hub.ps1`) itself stays `%LOCALAPPDATA%`-based; portable mode
is for users who copy the extracted folder to a USB stick and run `Hub.exe -Portable` (or drop the
marker file). / verify: `Hub.exe -Portable` uses the beside-exe data dir.

5.3 **Fix the hidden `%LOCALAPPDATA%` leak in `Get-HubCacheDir`.** / Hub.ps1 lines 333–345. /
**Confirmed by grep** (`LOCALAPPDATA` across `Hub*.ps1`): the four feature modules
(`Hub-Workflows.ps1`:10/20, `Hub-Triggers.ps1`:14, `Hub-History.ps1`:14, `Hub-Git.ps1`:14) all derive
their dirs from `$Script:ConfigDir`, so they follow portable mode for free once 5.1 lands. BUT
`Get-HubCacheDir` (line 336) **independently** recomputes `Join-Path $env:LOCALAPPDATA 'Hub'` and
ignores `$Script:ConfigDir` — so without a fix, `schema-cache.json` keeps writing to `%LOCALAPPDATA%`
even in portable mode. Change `Get-HubCacheDir` to return `$Script:DataDir` (keeping its
temp-fallback when `$env:LOCALAPPDATA` is empty). This is the ONLY extra fork beyond 5.1.
/ verify: in portable mode, `schema-cache.json` appears under `HubData\` next to the exe, and
`%LOCALAPPDATA%\Hub\` is not created.

5.4 **Portable + scan-root validation interaction.** / Hub.ps1 `Test-ValidScanRoot` (rules 5/6,
lines 462–464). / Confirm that with `$Script:DataDir` beside the exe, rule 6 (config-dir reflection)
still rejects scan roots inside the portable data dir, and rule 5 still rejects the install dir.
No code change expected — just a test asserting a scan root pointed at `HubData\` is rejected. /
verify: smoke test asserts rejection.

---

## Backend vs frontend split (which steps need an exe rebuild)

| Item | Touches exe code (rebuild → v1.8.0.0)? | Notes |
|---|---|---|
| 1 Signing | **No exe code.** Pipeline-only (`build-release.ps1`) + README. | But the *signed* exe IS the v1.8.0.0 build artifact. |
| 2 winget | **No exe code.** Manifest + docs only. | Depends on item 1's signed release existing. |
| 3 Version-check route (3.1–3.4) | **Yes** — `$Script:Version` bump, new module, new route. | |
| 3 Banner UI (3.5) | **No** — static `wwwroot`. | Non-functional until the rebuilt exe ships `/api/version-check`. |
| 4 Doctor route (4.1–4.2) | **Yes** — new module + route. | |
| 4 Diagnostics UI (4.3) | **No** — static `wwwroot`. | Functionally coupled to the rebuilt exe. |
| 5 Portable (5.1–5.4) | **Yes** — `Read-HubConfig`/path init + `Get-HubCacheDir`. | |

**Build sequencing:** all backend changes land in Hub.ps1 + `Hub-Diagnostics.ps1`, then
`build-hub.ps1 -Version 1.8.0.0`, then `build-release.ps1 -Version 1.8.0.0 -Sign` (signs, stages,
zips, hashes, patches installer, optionally `-Publish`). **New module registration is two-point:**
add `Hub-Diagnostics.ps1` to BOTH (a) the dot-source block in Hub.ps1 (~line 113) AND (b)
`build-release.ps1`'s module copy loop (line 93) + `$expectedFiles` list (line 98) — miss (b) and the
release zip ships without the module and `/api/doctor` 500s.

---

## Testing & verification
- **Signing:** `signtool verify /pa /v Hub.exe` after a `-Sign` build; assert exit 0 and a valid chain.
  Extract `build\Hub.zip`, re-verify the extracted exe, confirm zip hash == embedded `$Script:ExpectedZipHash`.
- **Pin integrity:** run `install-hub.ps1 -LocalZip build\Hub.zip` (existing test path) — SHA256 check passes against the signed zip.
- **Version-check:** smoke test stubs GitHub `latest` to a higher tag → `available:true` + correct one-liner;
  same tag → `available:false`; upstream 403 → soft `unreachable`, no throw; confirm cache prevents repeat upstream calls within the interval.
- **Version compare:** assert `[version]` normalization (`1.8.0` vs `1.10.0`).
- **Doctor:** all six checks return; corrupt a scan root → that check fails; PS7-absent path reports fail.
- **Portable:** launch with marker file / `-Portable` → `HubData\hub-config.json` AND `HubData\schema-cache.json`
  beside exe; `%LOCALAPPDATA%\Hub\` NOT created; workflows/triggers/history/repos all land under `HubData\`.
- **Routes are CSRF-free GETs:** assert `/api/doctor` + `/api/version-check` succeed without the `X-Hub-CSRF` header
  and are absent from `$Script:StateRoutes`.
- **Mutex caveat (HANDOFF #1):** run smokes with Hub.exe closed, or add `-SkipMutex` first (already a flagged TODO).
- `tests\smoke-phase4-diagnostics.ps1` covers the new routes + portable fork.

## Risks & mitigations
- **Signing eligibility / cost (highest risk).** EU individual is ineligible for Artifact Signing.
  *Mitigation:* decision gate — branch A (EU org) or branch C (OV cert in Key Vault). Both reach a
  `signtool`-compatible flow; only the credential block differs. Worst case branch D defers signing
  and still ships items 3/4/5.
- **Identity validation latency (days, 3 attempts).** *Mitigation:* start onboarding before writing
  any pipeline code; keep the `-Sign` step gated so the rest of v1.8.0.0 ships regardless.
- **SmartScreen still prompts early adopters even when signed** (reputation is download-history based).
  *Mitigation:* messaging promises only verifiable Authenticode, not SmartScreen elimination; optionally
  submit the signed file via Microsoft Security Intelligence for review.
- **GitHub rate-limit exhaustion via unauthenticated `/api/version-check` polling.** *Mitigation:*
  server-side cache + hard min-interval; soft-fail to cached/last-known.
- **winget feature gap** (no wizard/shortcut/autostart). *Mitigation:* document it; rely on in-app `NeedsSetup`.
- **Portable data leak** via `Get-HubCacheDir`. *Mitigation:* explicit fix (5.3), verified by smoke.
- **Module not staged into release zip.** *Mitigation:* two-point registration check (build-release `$expectedFiles`).
- **Version drift** between `$Script:Version`, git tag, and winget manifest. *Mitigation:* document the
  lockstep; doctor surfaces a mismatch.

## Rollback plan
- **Signing:** `-Sign` is a switch — drop it to ship an unsigned build identical to today's pipeline.
  A bad signature is caught by the post-sign `signtool verify` gate (1.4) before publish.
- **winget:** manifest lives in a separate repo PR; close the PR / `winget` listing has zero effect on the
  one-liner installer. Fully decoupled.
- **Routes/banner/doctor:** new additive GET routes + static UI; revert the Hub.ps1 route registrations
  and `wwwroot` diffs, rebuild. No existing route or data shape changes.
- **Portable:** default branch is unchanged (`%LOCALAPPDATA%`); portable is opt-in via flag/marker.
  Reverting 5.1/5.3 restores byte-identical default behaviour. No config migration involved.
- **Release-level:** since every change is additive and the zip is SHA256-pinned per tag, users on
  v1.7.x are unaffected until they type a new tag (tag-pin trust model preserved).

## Definition of Done
- [ ] Signing decision recorded (branch A/B/C/D) in CHANGELOG.
- [ ] `build-release.ps1 -Sign` produces a `Hub.exe` where `signtool verify /pa /v` succeeds with a valid chain.
- [ ] `build\Hub.zip` SHA256 == embedded `$Script:ExpectedZipHash` (pin covers signed bytes).
- [ ] README SmartScreen section rewritten (no "currently unsigned"); promises only verifiable Authenticode.
- [ ] winget manifest passes `winget validate` and a local manifest install binds `127.0.0.1:8765`; PR opened to `microsoft/winget-pkgs`.
- [ ] `/api/version-check` returns current/latest/available/one-liner; cached + rate-limited; CSRF-free; correct `[version]` comparison.
- [ ] Update banner renders the copyable one-liner; no download/auto-execute control exists.
- [ ] `/api/doctor` returns all six checks; failing scan root / absent PS7 reported correctly; reuses cached version-check.
- [ ] Portable mode: `-Portable` / marker writes ALL state (config, schema-cache, workflows, triggers, history, repos) beside the exe; `%LOCALAPPDATA%\Hub\` untouched.
- [ ] `Hub-Diagnostics.ps1` registered in BOTH Hub.ps1 dot-source AND build-release staging (`$expectedFiles`).
- [ ] `$Script:Version` = `1.8.0.0`, matches the tag; new files under 500 lines; PS 5.1/7 compatible; no new runtime deps.
- [ ] `tests\smoke-phase4-diagnostics.ps1` green (Hub.exe closed or `-SkipMutex`).
