// presets.js — Phase 2: parameter presets + "What will run" argv preview.
// Exposes presetsMixin() spread into hubApp().
//
// NOTE: only METHODS and plain data live here (no getters) — object-spread
// (...presetsMixin()) flattens getters to stale values, so reactive computed values
// must be inline getters in app.js or plain methods called from the template.

function presetsMixin() {
  return {
    // ── State ────────────────────────────────────────────────────────────────
    presets: [],
    presetName: '',
    presetError: '',
    argvPreview: null,       // { exe, argv[], prefix[], commandLineString, schemaMode, complete, missing[] }
    _argvTimer: null,

    // ── Presets CRUD (per selected item) ───────────────────────────────────────
    async refreshPresets() {
      if (!this.selected) { this.presets = []; return; }
      try {
        const r = await fetch('/api/presets?itemId=' + encodeURIComponent(this.selected.id), { headers: { Accept: 'application/json' } });
        if (!r.ok) { this.presets = []; return; }
        const data = await r.json();
        this.presets = Array.isArray(data) ? data : [];
      } catch (e) { this.presets = []; }
    },

    async savePreset() {
      this.presetError = '';
      const name = (this.presetName || '').trim();
      if (!name) { this.presetError = 'Name required'; return; }
      if (!this.selected) return;
      // Typed mode only — raw args are never saved as a preset value.
      if (this.schema && this.schema.mode === 'raw') { this.presetError = 'Presets are for typed-parameter scripts only'; return; }
      try {
        const r = await this.postJson('/api/presets', { itemId: this.selected.id, name, values: this.formValues });
        if (!r.ok) {
          let d = 'HTTP ' + r.status;
          try { d = (await r.json()).error || d; } catch (e) {}
          this.presetError = 'Save failed: ' + d;
          return;
        }
        this.presetName = '';
        await this.refreshPresets();
      } catch (e) { this.presetError = 'Save failed: ' + (e && e.message ? e.message : e); }
    },

    applyPreset(p) {
      if (!p) return;
      // Secret fields were redacted at save time → absent here → stay blank (re-entry required).
      this.formValues = Object.assign({}, this.formValues, p.values || {});
      this.queueArgvPreview();
    },

    async deletePreset(id) {
      if (!id) return;
      try {
        const r = await fetch('/api/presets/' + encodeURIComponent(id), {
          method: 'DELETE',
          headers: { 'X-Hub-CSRF': this.csrfToken }
        });
        if (r.ok) { await this.refreshPresets(); }
      } catch (e) { /* non-fatal */ }
    },

    // ── "What will run" argv preview (debounced) ────────────────────────────────
    queueArgvPreview() {
      if (this._argvTimer) { clearTimeout(this._argvTimer); }
      this._argvTimer = setTimeout(() => { this.fetchArgvPreview(); }, 250);
    },

    clearArgvPreview() { this.argvPreview = null; },

    async fetchArgvPreview() {
      if (!this.selected) { this.argvPreview = null; return; }
      // Send the same shape /api/run would — server reuses Resolve-RunPlan so the
      // preview can't drift; secret values are masked server-side (ADV-202).
      const body = { itemId: this.selected.id };
      if (this.schema && this.schema.mode === 'raw') {
        body.rawArgs = this.formValues.__rawArgs || '';
      } else {
        const v = Object.assign({}, this.formValues);
        delete v.__rawArgs;
        body.values = v;
      }
      try {
        const r = await this.postJson('/api/argv-preview', body);
        if (!r.ok) { this.argvPreview = null; return; }
        this.argvPreview = await r.json();
      } catch (e) { this.argvPreview = null; }
    },
  };
}
