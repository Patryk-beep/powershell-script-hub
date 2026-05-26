# Hub — shadcn-Hybrid UI Polish

**Status:** Approved design (brainstorm complete) — supersedes `hub-ui-glass-polish.md`
**Date:** 2026-05-26
**Approver:** Patryk-beep
**Selected approach:** Option C-hybrid — Keep Alpine.js. Apply shadcn-style neutral aesthetic via CSS rewrite. Vendor Geist Sans + Geist Mono. Add command-K palette via Alpine. No htmx swap.

---

## 1. Problem (re-stated)

Hub UI is functional but reads as utilitarian. User picked shadcn aesthetic (neutral, hairline borders, sharp shadows, 8 px radius) over glassmorphism. Replacing Alpine with htmx was considered but rejected: backend returns JSON, so htmx becomes underused without a parallel HTML-fragment rewrite of Hub.ps1 — too costly. Hybrid path: keep Alpine.js for reactive JSON rendering, drop htmx, deliver the shadcn visual promise + command-K via pure CSS + small Alpine additions.

## 2. Goals

- Replace Rosé Pine Moon palette with shadcn **neutral** OKLCH ramp (warm-cool balanced grays + restrained blue/violet accent).
- Vendor Geist Sans (400 / 500 / 600) + Geist Mono (400) — Latin subset WOFF2.
- Build a small component-style CSS layer: `.card`, `.btn`, `.input`, `.badge`, `.ring`, `.dialog` (~250 lines). Reusable primitives.
- 8 px border-radius across all surfaces.
- Hairline 1 px borders (`oklch(0.27 0 0)` neutral / accent variants per state).
- Sharp shadow stack: `0 0 0 1px ring + 0 6px 16px shadow` two-layer formula.
- Subtle motion: 150-200 ms ease-out on hover/focus/route changes. `prefers-reduced-motion` honoured.
- Command-K palette: Ctrl/Cmd+K opens overlay, fuzzy-searches catalog by name, Enter selects + opens form pane. Built on existing `hubApp()` Alpine component — no new framework.
- Total page weight under ~140 KB (current 95 KB; font budget 50-55 KB; component CSS ~6 KB).
- No build step. No npm. No external CDN.
- Existing security (Origin / CSRF / SameSite) and Alpine.js behaviour preserved.

## 3. Non-goals

- No htmx, no hyperscript, no framework swap.
- No backend HTML-fragment endpoints.
- No light theme (deferred).
- No new pages, no new routes.
- No SVG icon overhaul.
- No animation libraries.
- No new APIs.

## 4. Hard constraints

1. **PS2EXE compatibility**: `wwwroot/` static-served by HttpListener. WOFF2 MIME registered in `Get-MimeType`.
2. **Single-file CSS philosophy**: keep `style.css` as the only stylesheet. The component layer is a section at the top of that file, not a separate import.
3. **Font licensing**: Geist Sans + Geist Mono — SIL OFL. License files committed.
4. **Subset fonts**: Latin only — Geist 400 ≈ 25 KB, Geist 500 ≈ 25 KB, Geist 600 ≈ 25 KB (droppable if budget tight), Geist Mono 400 ≈ 24 KB. Sourced pre-subset from Google Fonts WOFF2.
5. **No FOUT panic**: `font-display: swap` + `<link rel="preload">` for Geist Sans 400 + Geist Mono 400.
6. **OKLCH support**: Chromium 111+, Firefox 113+. Hex fallback per token.
7. **Backward compatibility**: existing item-card markup, form templates, chip strip stay. CSS rewrite + small Alpine additions only.
8. **Caveman mode** does not affect file content.

## 5. Design tokens (shadcn neutral palette)

```css
:root {
  /* shadcn neutral dark — warm-cool balanced */
  --bg-base:        oklch(0.145 0 0);        /* near-black neutral */
  --bg-surface:     oklch(0.205 0 0);        /* card / panel base */
  --bg-elevated:    oklch(0.269 0 0);        /* hover lift */
  --bg-muted:       oklch(0.205 0 0);        /* input / chip background */

  /* Hairline borders */
  --border:         oklch(0.269 0 0);        /* default 1px */
  --border-strong:  oklch(0.371 0 0);        /* focus / hover */
  --ring:           oklch(0.985 0 0 / 0.10); /* default outline */

  /* Foreground */
  --fg:             oklch(0.985 0 0);
  --fg-muted:       oklch(0.708 0 0);
  --fg-subtle:      oklch(0.556 0 0);

  /* Accent — shadcn default blue-violet, restrained */
  --accent:         oklch(0.623 0.214 259.815);
  --accent-fg:      oklch(0.985 0 0);
  --accent-soft:    oklch(0.379 0.146 265.522);

  /* Semantic */
  --danger:         oklch(0.704 0.191 22.216);
  --warn:           oklch(0.828 0.189 84.429);
  --success:        oklch(0.696 0.170 162.480);

  /* Type */
  --font-ui:        'Geist', system-ui, sans-serif;
  --font-mono:      'Geist Mono', ui-monospace, monospace;

  /* Spacing scale (4 px base) */
  --r-1: 4px; --r-2: 8px; --r-3: 12px; --r-4: 16px;
  --r-5: 20px; --r-6: 24px; --r-7: 32px; --r-8: 40px;

  /* Border-radius */
  --radius-sm: 6px;
  --radius:    8px;
  --radius-lg: 10px;

  /* Shadows — shadcn two-layer */
  --shadow-sm: 0 0 0 1px var(--border), 0 1px 2px 0 rgb(0 0 0 / 0.05);
  --shadow:    0 0 0 1px var(--border), 0 4px 12px -2px rgb(0 0 0 / 0.30);
  --shadow-lg: 0 0 0 1px var(--border-strong), 0 12px 32px -4px rgb(0 0 0 / 0.50);

  /* Motion */
  --dur: 180ms;
  --ease: cubic-bezier(0.22, 0.61, 0.36, 1);
}
```

## 6. Component primitives (top of `style.css`, after tokens)

```css
/* .card — neutral surface with hairline ring + sharp shadow */
.card {
  background: var(--bg-surface);
  border-radius: var(--radius);
  box-shadow: var(--shadow);
  transition: transform var(--dur) var(--ease), box-shadow var(--dur) var(--ease);
}
.card:hover { transform: translateY(-1px); box-shadow: var(--shadow-lg); }

/* .btn — primary, ghost, danger variants */
.btn {
  display: inline-flex; align-items: center; gap: var(--r-2);
  height: 36px; padding: 0 var(--r-3);
  border-radius: var(--radius); border: 1px solid var(--border);
  background: var(--bg-surface); color: var(--fg);
  font: 500 13px var(--font-ui);
  transition: background var(--dur) var(--ease), border-color var(--dur) var(--ease);
}
.btn:hover    { background: var(--bg-elevated); border-color: var(--border-strong); }
.btn-primary  { background: var(--accent); color: var(--accent-fg); border-color: transparent; }
.btn-primary:hover { background: oklch(from var(--accent) calc(l + 0.05) c h); }
.btn-ghost    { background: transparent; border-color: transparent; }
.btn-danger   { background: var(--danger); color: var(--fg); border-color: transparent; }

/* .input — text/number/select */
.input {
  height: 36px; padding: 0 var(--r-3);
  border-radius: var(--radius); border: 1px solid var(--border);
  background: var(--bg-muted); color: var(--fg);
  font: 13px var(--font-ui);
  transition: border-color var(--dur) var(--ease), box-shadow var(--dur) var(--ease);
}
.input:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 3px oklch(from var(--accent) l c h / 0.20); }

/* .badge — small inline pill */
.badge {
  display: inline-flex; align-items: center; gap: 4px;
  height: 22px; padding: 0 var(--r-2);
  border-radius: 999px; border: 1px solid var(--border);
  background: var(--bg-muted); color: var(--fg-muted);
  font: 500 11px var(--font-ui);
}

/* .dialog — modal pane */
.dialog-backdrop {
  position: fixed; inset: 0;
  background: rgb(0 0 0 / 0.60);
  backdrop-filter: blur(4px);
  z-index: 50;
}
.dialog {
  background: var(--bg-surface);
  border-radius: var(--radius-lg);
  box-shadow: var(--shadow-lg);
  border: 1px solid var(--border);
}
```

## 7. Per-surface treatment

- **Body** — flat `--bg-base`, no halo (shadcn is flat-neutral, not refraction-based).
- **Header** — `--bg-surface` + bottom 1 px `--border`. Sticky.
- **Toolbar** — flush row, search input becomes a `.input`, chip-group buttons become `.btn-ghost` with `[aria-pressed=true]` getting `--bg-elevated` + ring.
- **Item card** — `.card` directly. Hover lift -1 px. Chip strip stays. Kind icon gets a `--bg-elevated` square with rounded corners.
- **Form pane** — split into `.card` sections: "Parameters" + "Output". Each form field uses `.input`. Mandatory marker `*` becomes a `.badge` `[required]`.
- **Log pane** — `.card` with `--bg-base` interior, Geist Mono 12.5 px. Pulse dot uses `--success` for running state.
- **Setup modal** — `.dialog-backdrop` + `.dialog`. Footer buttons `.btn` + `.btn-primary`.

## 8. Command-K palette (new feature)

- Keybinding: `Ctrl+K` (Windows) / `Cmd+K` (Mac). Add to `bindKeyboard()` in `app.js`.
- New Alpine state: `paletteOpen`, `paletteQuery`, `paletteIndex`.
- On open: render `.dialog-backdrop` + `.dialog` containing a `.input[autofocus]` + scrollable result list. Each result is a `.card` row showing item name + kind + path snippet.
- Search filter: case-insensitive substring match on `name` + `description` + filename. Cap to 10 results.
- Navigation: Arrow up/down moves `paletteIndex`. Enter calls `selectItem(item)` + closes palette.
- Esc closes palette.
- Reuses existing items state — no new fetch.

## 9. Asset list (new files)

```
wwwroot/
  vendor/
    fonts/
      geist-400.woff2          ~25 KB
      geist-500.woff2          ~25 KB
      geist-600.woff2          ~25 KB  (droppable if budget tight)
      geist-mono-400.woff2     ~24 KB
      LICENSE-GEIST.txt
```

Total font budget ≈ 99 KB (74 KB if Geist 600 dropped).

## 10. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Aesthetic-only changes feel incremental | shadcn is deliberate restraint; verify visually before approval |
| OKLCH unsupported on older Chromium | Hub runs on user's default browser; Edge/Chrome are current. Hex fallbacks where critical |
| Component class collisions with existing `style.css` rules | New tokens defined first; existing class selectors rewritten to consume them. Old class names stay (no markup churn) |
| Command-K conflicts with browser shortcuts | Cmd+K is "search address bar" on some browsers — preventDefault on keydown only when target is not in an input |
| Font subset misses glyph | Hub UI uses ASCII + basic punctuation only. Latin subset covers it. Path strings may contain non-ASCII; falls back to system mono |
| Multi-layer shadow perf on large catalogs | shadcn shadow is cheap (2 layers, no blur radius >32). No issue |
| Geist 600 drops if budget tight | Phase 1 can ship with 400 + 500 + Mono only; 600 added in P2 if needed |

## 11. Verification

- Existing smokes 7/7 green (CSS-only changes to layout; Alpine state unaffected).
- New `smoke-ui-shadcn.ps1`: asserts WOFF2 MIME, `<link rel="preload">`, neutral palette tokens (`--bg-base`, `--bg-surface`, `--border`), component classes (`.card`, `.btn`, `.input`, `.badge`, `.dialog`), command-K event binding.
- Manual visual checklist `docs/verification/shadcn-ui-checklist.md`.

## 12. Out-of-scope follow-ups

- Light theme toggle
- Run-history view in command-K (currently catalog-only)
- Multi-select / batch operations
- Custom theme builder

## 13. Handoff payload to `rune:plan`

- **Approach**: Option C-hybrid — Alpine kept, shadcn aesthetic via CSS rewrite, vendored Geist Sans + Geist Mono, command-K palette.
- **Palette**: shadcn neutral (warm-cool balanced gray + blue-violet accent).
- **Mono**: Geist Mono 400.
- **Border-radius**: 8 px default.
- **Command-K**: in-scope.
- **Motion**: subtle (180 ms ease-out).
- **Hard constraints**: § 4 1-8.
- **Risks**: § 10.
- **Verification**: § 11.
- **Out-of-scope**: § 12.
