// logviewer.js — Phase 2: log search/filter, XSS-safe ANSI color, wrap, copy, download.
// Exposes logViewerMixin() spread into hubApp(). Methods only (no getters — spread
// flattens getters). `autoScroll` already exists in app.js — extended, NOT redeclared.

function logViewerMixin() {
  return {
    // ── State ────────────────────────────────────────────────────────────────
    logFilter: '',
    logWrap: false,

    // ── Filter ──────────────────────────────────────────────────────────────────
    logMatches(line) {
      const f = (this.logFilter || '').trim().toLowerCase();
      if (!f) return true;
      return String(line == null ? '' : line).toLowerCase().indexOf(f) !== -1;
    },

    // ── XSS-safe ANSI → HTML ──────────────────────────────────────────────────────
    // Log lines are UNTRUSTED child-process stdout. ESCAPE first, THEN convert SGR
    // escape sequences to <span> — never inject raw text into x-html.
    _escapeHtml(t) {
      return String(t == null ? '' : t)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    },

    _ansiClasses(codes) {
      const map = {
        '1': 'ansi-bold',
        '30': 'ansi-fg-0', '31': 'ansi-fg-1', '32': 'ansi-fg-2', '33': 'ansi-fg-3',
        '34': 'ansi-fg-4', '35': 'ansi-fg-5', '36': 'ansi-fg-6', '37': 'ansi-fg-7',
        '90': 'ansi-fg-8', '91': 'ansi-fg-9', '92': 'ansi-fg-10', '93': 'ansi-fg-11',
        '94': 'ansi-fg-12', '95': 'ansi-fg-13', '96': 'ansi-fg-14', '97': 'ansi-fg-15'
      };
      const out = [];
      for (const c of codes) { if (map[c]) out.push(map[c]); }
      return out;
    },

    ansiToHtml(line) {
      const s = String(line == null ? '' : line);
      const re = /\[([0-9;]*)m/g;
      let out = '', last = 0, open = false, m;
      while ((m = re.exec(s)) !== null) {
        out += this._escapeHtml(s.slice(last, m.index));
        last = re.lastIndex;
        const codes = m[1].split(';').filter(x => x !== '');
        if (codes.length === 0 || codes.indexOf('0') !== -1) {
          if (open) { out += '</span>'; open = false; }
          continue;
        }
        const cls = this._ansiClasses(codes);
        if (cls.length) {
          if (open) { out += '</span>'; }
          out += '<span class="' + cls.join(' ') + '">';
          open = true;
        }
      }
      out += this._escapeHtml(s.slice(last));
      if (open) { out += '</span>'; }
      return out;
    },

    // ── Wrap toggle ─────────────────────────────────────────────────────────────
    toggleLogWrap() { this.logWrap = !this.logWrap; },

    // ── Copy / download (full log, ANSI stripped) ───────────────────────────────
    _plainLog() {
      return (this.logLines || [])
        .map(e => String(e.line == null ? '' : e.line).replace(/\[[0-9;]*m/g, ''))
        .join('\n');
    },

    async copyLog() {
      try { await navigator.clipboard.writeText(this._plainLog()); } catch (e) { /* clipboard blocked */ }
    },

    downloadLog() {
      try {
        const blob = new Blob([this._plainLog()], { type: 'text/plain' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        const stamp = (this.currentJob || new Date().toISOString().replace(/[:.]/g, '-'));
        a.download = 'hub-log-' + stamp + '.txt';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        setTimeout(() => URL.revokeObjectURL(url), 1000);
      } catch (e) { /* non-fatal */ }
    },
  };
}
