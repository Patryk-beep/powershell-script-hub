// hub-notify.js — Phase 1: run-finished OS notifications, document.title progress,
// and pin/favorites + recents (localStorage only — no backend route).
// Exposes hubNotifyMixin() spread into hubApp().
//
// SECURITY (B3): notification bodies carry ONLY the script name + status/exit code.
// Never arguments, parameter values, or stdout/stderr.

function hubNotifyMixin() {
  return {
    // ── State ────────────────────────────────────────────────────────────────
    windowFocused: true,
    notifyEnabled: null,   // tri-state: null = unset, true = on, false = user-declined
    pinnedIds: [],
    recentIds: [],

    // ── Init: focus tracking + notify prefs (called from app.js init) ──────────
    restoreNotifyPrefs() {
      // Initial focus state.
      try { this.windowFocused = document.hasFocus ? document.hasFocus() : true; } catch (e) {}

      try {
        const n = localStorage.getItem('hub.notifyEnabled');
        if (n !== null) this.notifyEnabled = n === '1';
      } catch (e) { /* ignore */ }
      this.$watch && this.$watch('notifyEnabled', (v) => {
        try {
          if (v === null) localStorage.removeItem('hub.notifyEnabled');
          else localStorage.setItem('hub.notifyEnabled', v ? '1' : '0');
        } catch (e) {}
      });

      const sync = () => {
        let focused = true;
        try { focused = (document.visibilityState === 'visible') && (document.hasFocus ? document.hasFocus() : true); } catch (e) {}
        this.windowFocused = focused;
        // On regaining focus, clear any stale ✓/✗ from the title.
        if (focused) this.setTitleProgress('idle');
      };
      window.addEventListener('focus', sync);
      window.addEventListener('blur', () => { this.windowFocused = false; });
      document.addEventListener('visibilitychange', sync);
    },

    // ── B2: permission request — ONLY on a user gesture (the run button) ────────
    requestNotifyPermission() {
      if (!('Notification' in window)) return;
      if (this.notifyEnabled === false) return;
      if (Notification.permission !== 'default') return;
      try {
        Notification.requestPermission().then((perm) => {
          this.notifyEnabled = (perm === 'granted');
        }).catch(() => {});
      } catch (e) { /* older callback-style API or blocked — degrade silently */ }
    },

    // ── B3: fire toast on run finish, only when unfocused ───────────────────────
    notifyRunDone(name, status, exitCode) {
      if (this.windowFocused) return;                 // user is already watching
      if (this.notifyEnabled === false) return;
      if (!('Notification' in window)) return;
      if (Notification.permission !== 'granted') return;

      const label = name || 'Script';
      let body;
      if (status === 'success' || exitCode === 0) {
        body = label + ' exited 0';
      } else if (typeof exitCode === 'number') {
        body = label + ' failed (exit ' + exitCode + ')';
      } else {
        body = label + ' — ' + (status || 'finished');
      }
      try {
        const n = new Notification('Hub — Run finished', { body, tag: 'hub-run' });
        n.onclick = () => { try { window.focus(); n.close(); } catch (e) {} };
      } catch (e) { /* ignore */ }
    },

    // ── B4: document.title progress indicator ───────────────────────────────────
    setTitleProgress(state) {
      switch (state) {
        case 'running': document.title = '● Running… — Hub'; break;
        case 'done':    document.title = '✓ Done — Hub';     break;
        case 'failed':  document.title = '✗ Failed — Hub';   break;
        case 'idle':
        default:        document.title = 'Hub';
      }
    },

    // ── C1: pins + recents persistence (localStorage only) ──────────────────────
    restorePins() {
      try {
        const p = localStorage.getItem('hub.pinnedIds');
        if (p) { const a = JSON.parse(p); if (Array.isArray(a)) this.pinnedIds = a.filter(x => typeof x === 'string'); }
      } catch (e) { /* ignore malformed */ }
      try {
        const r = localStorage.getItem('hub.recentIds');
        if (r) { const a = JSON.parse(r); if (Array.isArray(a)) this.recentIds = a.filter(x => typeof x === 'string'); }
      } catch (e) { /* ignore malformed */ }

      this.$watch && this.$watch('pinnedIds', (v) => { try { localStorage.setItem('hub.pinnedIds', JSON.stringify(v)); } catch (e) {} });
      this.$watch && this.$watch('recentIds', (v) => { try { localStorage.setItem('hub.recentIds', JSON.stringify(v)); } catch (e) {} });
    },

    isPinned(item) {
      return !!item && this.pinnedIds.indexOf(item.id) !== -1;
    },

    togglePin(item) {
      if (!item) return;
      const idx = this.pinnedIds.indexOf(item.id);
      if (idx === -1) {
        this.pinnedIds = this.pinnedIds.concat([item.id]);
      } else {
        const next = this.pinnedIds.slice();
        next.splice(idx, 1);
        this.pinnedIds = next;
      }
    },

    pushRecent(itemId) {
      if (!itemId) return;
      const next = this.recentIds.filter(id => id !== itemId);
      next.unshift(itemId);
      this.recentIds = next.slice(0, 8);   // dedupe-to-front, cap at 8
    },

    // ── C3: resolved recents (ids → live item objects, most-recent-first) ───────
    get recentItems() {
      const items = this.items || [];
      return this.recentIds
        .map(id => items.find(i => i.id === id))
        .filter(Boolean);
    },
  };
}
