// secrets.js — Phase 3: secrets vault UI + password-field secret binding + workflow
// export/import. Exposes secretsMixin() spread into hubApp().
//
// Values are WRITE-ONLY: the UI never fetches a secret value, only names + metadata. A
// password-typed run field can be bound to a vault secret by NAME — the form then submits
// the string token "@secret:<name>"; the value never travels through the browser.
//
// NOTE: only METHODS / plain data here (no getters) — object-spread flattens getters to
// stale values. Reactive bits use methods called from the template.

function secretsMixin() {
  return {
    // ── State ────────────────────────────────────────────────────────────────
    secrets: [],
    secretForm: { name: '', kind: 'password', value: '', username: '' },
    secretError: '',
    secretBusy: false,

    // Import flow state (export is a plain download — no state needed).
    importStage: 'idle',      // 'idle' | 'confirm' | 'result'
    importFileText: '',
    importFileName: '',
    importError: '',
    importResult: null,       // { id, name, unresolvedScripts[], referencedSecrets[] }

    // ── Vault CRUD (values write-only) ─────────────────────────────────────────
    async refreshSecrets() {
      try {
        const r = await fetch('/api/secrets', { headers: { Accept: 'application/json' } });
        if (!r.ok) { this.secrets = []; return; }
        const data = await r.json();
        this.secrets = Array.isArray(data) ? data : [];
      } catch (e) { this.secrets = []; }
    },

    resetSecretForm() {
      this.secretForm = { name: '', kind: 'password', value: '', username: '' };
      this.secretError = '';
    },

    async saveSecret() {
      this.secretError = '';
      const name = (this.secretForm.name || '').trim();
      if (!name) { this.secretError = 'Name required'; return; }
      if (!this.secretForm.value) { this.secretError = 'Value required'; return; }
      if (this.secretForm.kind === 'credential' && !(this.secretForm.username || '').trim()) {
        this.secretError = 'Username required for a credential'; return;
      }
      this.secretBusy = true;
      try {
        const body = { name, kind: this.secretForm.kind, value: this.secretForm.value };
        if (this.secretForm.kind === 'credential') { body.username = this.secretForm.username.trim(); }
        const r = await this.postJson('/api/secrets', body);
        if (!r.ok) {
          let d = 'HTTP ' + r.status;
          try { d = (await r.json()).error || d; } catch (e) {}
          this.secretError = 'Save failed: ' + d;
          return;
        }
        this.resetSecretForm();
        await this.refreshSecrets();
      } catch (e) {
        this.secretError = 'Save failed: ' + (e && e.message ? e.message : e);
      } finally {
        this.secretBusy = false;
      }
    },

    async deleteSecret(name) {
      if (!name) return;
      try {
        const r = await fetch('/api/secrets/' + encodeURIComponent(name), {
          method: 'DELETE', headers: { 'X-Hub-CSRF': this.csrfToken }
        });
        if (r.ok) { await this.refreshSecrets(); }
      } catch (e) { /* non-fatal */ }
    },

    async rotateSecret(name) {
      const v = window.prompt('New value for "' + name + '" (write-only):');
      if (v === null || v === '') return;
      try {
        const r = await fetch('/api/secrets/' + encodeURIComponent(name), {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json', 'X-Hub-CSRF': this.csrfToken },
          body: JSON.stringify({ value: v })
        });
        if (r.ok) { await this.refreshSecrets(); }
      } catch (e) { /* non-fatal */ }
    },

    // ── Password-field <-> secret binding (run form) ───────────────────────────
    isSecretRef(v) { return typeof v === 'string' && v.indexOf('@secret:') === 0; },
    secretRefName(v) { return this.isSecretRef(v) ? v.slice('@secret:'.length) : ''; },

    bindSecretToField(fieldName, secretName) {
      if (!secretName) return;
      this.formValues[fieldName] = '@secret:' + secretName;
      if (this.queueArgvPreview) this.queueArgvPreview();
    },

    clearSecretField(fieldName) {
      this.formValues[fieldName] = '';
      if (this.queueArgvPreview) this.queueArgvPreview();
    },

    // ── Workflow export (plain download) ───────────────────────────────────────
    exportWorkflow(id) {
      if (!id) return;
      window.location = '/api/workflows/' + encodeURIComponent(id) + '/export';
    },

    // ── Workflow import (trust warning, then POST) ─────────────────────────────
    triggerImportPicker() {
      const el = document.getElementById('hubflow-import-input');
      if (el) { el.value = ''; el.click(); }
    },

    async onImportFilePicked(event) {
      this.importError = '';
      this.importResult = null;
      const file = event && event.target && event.target.files && event.target.files[0];
      if (!file) return;
      try {
        this.importFileText = await file.text();
        this.importFileName = file.name;
        this.importStage = 'confirm';   // show trust modal before sending
      } catch (e) {
        this.importError = 'Could not read file';
        this.importStage = 'idle';
      }
    },

    cancelImport() {
      this.importStage = 'idle';
      this.importFileText = '';
      this.importFileName = '';
      this.importError = '';
    },

    async confirmImport() {
      this.importError = '';
      let envelope = null;
      try { envelope = JSON.parse(this.importFileText); }
      catch (e) { this.importError = 'Not a valid .hubflow (JSON parse failed)'; return; }
      try {
        const r = await fetch('/api/workflows/import', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-Hub-CSRF': this.csrfToken },
          body: JSON.stringify(envelope)
        });
        if (!r.ok) {
          let d = 'HTTP ' + r.status;
          try { const j = await r.json(); d = (j.error || d) + (j.details ? ': ' + j.details.join('; ') : ''); } catch (e) {}
          this.importError = 'Import rejected: ' + d;
          return;
        }
        this.importResult = await r.json();
        this.importStage = 'result';
        if (this.refreshWorkflows) await this.refreshWorkflows();
      } catch (e) {
        this.importError = 'Import failed: ' + (e && e.message ? e.message : e);
      }
    },
  };
}
