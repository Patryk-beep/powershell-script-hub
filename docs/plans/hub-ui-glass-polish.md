# Hub — Glassmorphism UI Polish

**Status:** Approved design (brainstorm complete) — ready for `rune:plan`
**Date:** 2026-05-26
**Approver:** Patryk-beep
**Selected approach:** Option A — CSS-only polish-in-place, glassmorphism aesthetic, Geist + JetBrains Mono, subtle motion. Rosé Pine palette may be replaced if glass treatment demands it.

---

## 1. Problem

Hub's current UI is functional but reads as utilitarian. The simplicity is intentional, but the visual treatment (flat surfaces, hairline borders, no depth, system fonts) makes the dashboard look unpolished — closer to a sysadmin internal tool than a finished product. The chip strip, bigger cards, and new widgets shipped in P-schema-1..3 give the UI more information density, which sharpens the gap between the data and its presentation.

## 2. Goals

- Add visual depth and polish via a glassmorphism design pass: layered translucent surfaces, soft backdrop blur, gradient halos, refined elevation.
- Replace system font stack with vendored Geist Sans (UI) + JetBrains Mono (paths, code, log pane).
- Subtle motion: 150-250 ms ease-out on hover/focus, no page-load animation cascades.
- Preserve fast static-file loadtime — total page weight stays under ~140 KB (current ~95 KB, font budget ~40 KB).
- No build step. No npm. No external CDN. No JS framework swap.
- Existing security (Origin / CSRF / SameSite) and Alpine.js behaviour unchanged.

## 3. Non-goals

- No Alpine → htmx migration.
- No component library (no shadcn / Pico / framework adoption).
- No new pages, no new routes, no JS state model changes.
- No SVG icon overhaul (keep current Lucide-derived sprite, may tint via `currentColor`).
- No animation libraries (Motion, GSAP, anime.js).
- No theme switcher / light-mode (out of scope; can be a future task).
- No new vendor JS — only CSS + font files added under `wwwroot/`.

## 4. Hard constraints

1. **PS2EXE compatibility:** Hub.exe ships `wwwroot/` as static files via HttpListener. Any new file under `wwwroot/` must be served by the existing MIME logic. `WOFF2` MIME type may need registering in `Get-MimeType` if not already.
2. **Static-file model only:** no CSS preprocessor (Sass/Less), no PostCSS, no bundler. Plain hand-written CSS using native custom properties + `color-mix` + `backdrop-filter`.
3. **Font licensing:** Geist is OFL (free, redistributable). JetBrains Mono is Apache 2.0. Both can be vendored. License files must be committed alongside font files.
4. **Subset fonts:** Latin only — full Geist/JetBrains is 200+ KB each. Subset to ~25-30 KB each via WOFF2 subsetting (use `pyftsubset` or pre-subset Google Fonts CDN download, then commit the result).
5. **Backdrop-filter compatibility:** modern Chromium/Edge/Firefox all support `backdrop-filter`. Hub runs in user's default browser. If browser is older, glass effect degrades to flat translucent surface (acceptable fallback).
6. **No flash of unstyled text (FOUT):** declare `font-display: swap` on `@font-face`. Pre-load critical fonts via `<link rel="preload">` in `index.html`.
7. **Caveman mode chat-only:** CSS / code / commits written in normal English.
8. **Backward compatibility:** existing card markup, form markup, chip strip markup all stay. Pure CSS pass.

## 5. Design system tokens

### Palette (replace Rosé Pine Moon — too literary for glass; keep Iris/Love accents as graceful nod)

```css
:root {
  /* Base surfaces (oklch — fall back to hex where needed for PS5/older Chromium) */
  --bg-base:        oklch(0.18 0.012 270);     /* deep ink */
  --bg-surface:     oklch(0.22 0.014 270);     /* card base */
  --bg-elevated:    oklch(0.26 0.016 270);     /* hover lift */

  /* Glass layers (semi-transparent stacked with backdrop-blur) */
  --glass-tint:     color-mix(in oklab, var(--bg-surface) 70%, transparent);
  --glass-border:   color-mix(in oklab, white 8%, transparent);
  --glass-highlight: color-mix(in oklab, white 14%, transparent);

  /* Accent ramp — Iris kept as primary, gold for warnings, love for danger */
  --accent:         oklch(0.72 0.16 290);      /* Iris */
  --accent-soft:    oklch(0.30 0.10 290);
  --warn:           oklch(0.84 0.13 80);       /* warm gold */
  --love:           oklch(0.74 0.18 12);       /* coral */
  --foam:           oklch(0.82 0.10 200);      /* cool teal */

  /* Text */
  --text:           oklch(0.94 0.006 270);
  --muted:          oklch(0.65 0.012 270);
  --subtle:         oklch(0.50 0.014 270);
}
```

### Type scale
```css
--font-ui:   'Geist', system-ui, sans-serif;
--font-mono: 'JetBrains Mono', ui-monospace, monospace;

--text-xs:   11px;
--text-sm:   12.5px;
--text-base: 14px;
--text-md:   15.5px;
--text-lg:   17px;
--text-xl:   20px;
--text-2xl:  24px;
```

### Spacing scale (4 px base)
```css
--r-1: 4px;  --r-2: 8px;   --r-3: 12px;  --r-4: 16px;
--r-5: 20px; --r-6: 24px;  --r-7: 32px;  --r-8: 40px;
```

### Elevation stack (multi-layer shadows — glass requires light edge + soft cast)
```css
--shadow-1: 0 1px 0 var(--glass-highlight) inset,
            0 1px 2px rgb(0 0 0 / 0.20);
--shadow-2: 0 1px 0 var(--glass-highlight) inset,
            0 8px 24px rgb(0 0 0 / 0.28),
            0 2px 6px rgb(0 0 0 / 0.18);
--shadow-3: 0 1px 0 var(--glass-highlight) inset,
            0 20px 60px rgb(0 0 0 / 0.40),
            0 4px 12px rgb(0 0 0 / 0.24);
```

### Glass primitive (the core class)
```css
.glass {
  background: var(--glass-tint);
  backdrop-filter: blur(16px) saturate(140%);
  -webkit-backdrop-filter: blur(16px) saturate(140%);
  border: 1px solid var(--glass-border);
  box-shadow: var(--shadow-1);
}

.glass-elevated  { box-shadow: var(--shadow-2); }
.glass-prominent { box-shadow: var(--shadow-3); backdrop-filter: blur(24px) saturate(160%); }
```

### Motion tokens
```css
--dur-fast:  120ms;
--dur-base:  180ms;
--dur-slow:  280ms;
--ease:      cubic-bezier(0.22, 0.61, 0.36, 1);   /* gentle ease-out */
--ease-in:   cubic-bezier(0.42, 0, 0.58, 1);
```

## 6. Visual treatment (per surface)

### Background
- Body background: `var(--bg-base)` with a subtle radial gradient halo behind the header — `radial-gradient(at 50% 0%, oklch(0.30 0.08 290 / 0.35), transparent 60%)`. Provides depth so glass cards have something to refract.

### Header
- `glass-elevated` panel pinned to top. 64px tall. Logo SVG + version chip + settings button. Bottom border = 1 px `var(--glass-highlight)`.

### Toolbar
- `glass` strip below header. Search input becomes a soft pill with inner shadow. Chip-group gets pressed-state via gradient + ring instead of solid colour.

### Item cards
- `.item-card` → `glass` + extra elevation token. On hover: `transform: translateY(-2px)` + shadow upgrade to `glass-prominent`. 200 ms ease-out transition.
- Inside: kind icon gets gradient background (`linear-gradient(135deg, var(--accent), var(--accent-soft))`) with 1 px highlight ring.
- Param chip strip stays where it is, chip pills get glass + ring treatment.
- Card border-radius bumped to 14px (from current 8-10px) for glass softness.

### Form pane
- `glass-elevated` panel. Form fields get inset glass background (`background: oklch(0.20 0.014 270 / 0.6)` + soft inset shadow). Focus state: 2px outline-offset ring in `var(--accent)`. Mandatory marker `*` becomes a tiny coral pill.
- Field labels split into two rows: name (Geist UI medium) + aliases/type/required (smaller, muted). Mono font on `form-pane-path` (the script path under title).

### Log pane
- Black-tinted glass: `background: oklch(0.10 0.004 270 / 0.75)` + thin frame. Mono font (JetBrains Mono 12.5px). Top edge gets a 24px gradient fade so streaming logs feel like they enter the pane from above. Pulse dot for live state.

### Modals (setup wizard)
- Backdrop: `backdrop-filter: blur(8px) brightness(0.6)`. Modal itself: `glass-prominent`.

## 7. Typography

- Vendor Geist Sans (Regular 400, Medium 500, Semibold 600 — three weights only). Latin subset, WOFF2 only.
- Vendor JetBrains Mono Regular 400. Latin subset, WOFF2.
- Preload critical font files via `<link rel="preload" as="font" type="font/woff2" crossorigin>` in `index.html`.
- `font-display: swap` so system fallback shows first paint, custom font replaces seamlessly.

## 8. Motion catalog (subtle)

| Surface | Trigger | Effect | Duration |
|---|---|---|---|
| Card | hover | `translateY(-2px)` + shadow up | 200 ms ease |
| Card | focus-visible | accent outline-offset 4px | 150 ms |
| Card | press | `scale(0.98)` | 100 ms |
| Chip / button | hover | tint +6% | 150 ms |
| Form input | focus | outline grows from 1 → 2 px | 150 ms |
| Log pulse dot | run state | opacity 0.4 ↔ 1.0 | 1100 ms loop |
| Modal | open | opacity 0→1 + scale 0.96→1 | 200 ms ease |

No staggered card-in animation (would feel gimmicky on every catalog reload). Keep current `animation: card-in` but reduce delay cap to 120ms total.

## 9. Asset list (new files under `wwwroot/`)

```
wwwroot/
  vendor/
    fonts/
      geist-400.woff2          ~25 KB
      geist-500.woff2          ~25 KB
      geist-600.woff2          ~25 KB
      jetbrains-mono-400.woff2 ~28 KB
      LICENSE-GEIST.txt
      LICENSE-JETBRAINS.txt
```

Total font budget: ~103 KB. May trim to Geist 400+500 only (drop 600) if budget tight — saves 25 KB.

Per-file MIME: `font/woff2`. Add to `Get-MimeType` in `Hub.ps1` if not present.

## 10. Browser support

- Chromium 76+, Firefox 103+, Safari 9+ for `backdrop-filter`.
- Hub launches in the user's default browser. Realistic floor: Chromium-based Edge / Chrome (Windows default).
- Fallback: when `backdrop-filter` unsupported, glass surfaces fall back to flat translucent background (still visually OK, just no blur). Test in incognito with `chrome://flags` disable.

## 11. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Font file CORS issues over loopback | `font-display: swap` keeps text visible; loopback CORS is permissive by default |
| `backdrop-filter` perf cost on weaker GPUs | Limit to 6-8 simultaneous glass surfaces. No glass on text-only chips. |
| Multi-layer shadows hurt mobile-y rendering | Hub is desktop-only; non-issue |
| `color-mix` and `oklch` unsupported on older Chromium | Hard floor is Chromium 111+ for OKLCH. Fallback hex pairs declared alongside `oklch()` |
| Font subsetting tooling | Use Google Fonts CDN as origin (subsetted by default) — download woff2, no `pyftsubset` step required |
| Geist subsetting from Vercel CDN — licence drift | Vendor LICENSE files explicitly; pin to specific version |
| Subtle motion feels broken in reduced-motion mode | Wrap transitions in `@media (prefers-reduced-motion: no-preference)` block |

## 12. Verification

- Visual checklist (`docs/verification/glass-ui-checklist.md`) — manual sign-off.
- Lighthouse via local Chromium: first-paint < 200 ms, layout shift = 0, total page weight under 140 KB.
- All 7 existing smoke tests (`smoke-phase1..3`, `smoke-phase-schema-1..3`, `smoke-schema-coverage`) remain 100% green — CSS-only changes touch no JS or backend logic.
- New smoke `smoke-ui-glass.ps1`: asserts WOFF2 files served with `font/woff2` MIME, asserts `<link rel="preload">` for critical fonts present in `index.html`, asserts `.glass` class declared in `style.css`.

## 13. Out-of-scope follow-ups

- Light theme (high effort, low priority for v1.2)
- Command-K palette
- Per-card actions menu (run history, favourite, copy path)
- Live in-card param chip filtering ("show me scripts with no required params")

## 14. Handoff payload to `rune:plan`

- **Approach:** Polish-in-place CSS-only refactor with glassmorphism aesthetic.
- **Aesthetic:** Expressive / glassmorphism (P1 = C). Palette may replace Rosé Pine Moon per § 5 colour scheme.
- **Typography:** Geist Sans (400/500/600) + JetBrains Mono (400), vendored under `wwwroot/vendor/fonts/`.
- **Motion:** Subtle (per § 8 catalog).
- **Hard constraints:** § 4 1-8.
- **Risks to mitigate:** § 11.
- **Verification gates:** § 12 — all 7 prior smokes stay green; new `smoke-ui-glass.ps1` validates font + preload + glass token.
- **Out-of-scope:** § 13.
