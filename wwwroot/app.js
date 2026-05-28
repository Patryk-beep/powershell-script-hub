// Hub frontend — Alpine.js component.
// Catalog browser with search/filter/sort + form-driven runner with SSE log stream.
// Canvas editor state/methods come from canvasEditorMixin() in canvas-editor.js.

function hubApp() {
  return {
    ...canvasEditorMixin(),
    // ── Catalog state ───────────────────────────────────────────────
    items: [],
    warnings: [],
    error: null,
    loaded: false,
    version: '',
    port: 0,

    // ── Filter / sort state ─────────────────────────────────────────
    query: '',
    kindFilter: 'all',
    sortBy: 'name-asc',
    hiddenIds: [],
    showHidden: false,

    // ── Selection / form state ──────────────────────────────────────
    selected: null,
    schema: null,
    formValues: {},
    schemaLoading: false,

    // ── Run / stream state ──────────────────────────────────────────
    currentJob: null,
    submitting: false,
    ended: false,
    exitCode: null,
    endStatus: '',
    logLines: [],
    eventSource: null,
    autoScroll: true,

    // ── Setup wizard state (P1.5) ───────────────────────────────────
    config: { scanRoots: [], needsSetup: false, defaults: [], maxScanRoots: 16, scanMaxDepth: 1 },
    setupOpen: false,
    setupScanRoots: [],
    setupSaving: false,
    setupError: null,

    // ── Security ────────────────────────────────────────────────────
    csrfToken: '',

    // ── Tab navigation ───────────────────────────────────────────────
    activeTab: 'catalog',   // 'catalog' | 'workflows' | 'history'

    // ── Workflow state ────────────────────────────────────────────────
    workflows: [],
    wfLoading: false,
    wfSelected: null,       // workflow currently viewed
    wfEditMode: false,      // true while editor form is open
    wfForm: null,           // mutable form data during create/edit
    wfSaving: false,
    wfError: null,
    wfRun: null,            // { runId, status, currentStepId, stepOutputs, childJobIds }
    wfRunPolling: null,     // setInterval handle
    wfRunLog: [],
    wfRunEs: null,

    // ── History state ─────────────────────────────────────────────────
    histEntries: [],
    histTotal: 0,
    histOffset: 0,
    histLimit: 50,
    histLoading: false,

    // ── Command-K palette (P-ui-3) ──────────────────────────────────
    paletteOpen: false,
    paletteQuery: '',
    paletteIndex: 0,

    // ── Lifecycle ───────────────────────────────────────────────────
    async init() {
      this.csrfToken = this.readCsrfCookie();
      this.restorePrefs();

      try {
        const h = await (await fetch('/api/health')).json();
        this.version = h.version;
        this.port = h.port;
      } catch (e) { /* non-fatal */ }

      this.bindKeyboard();
      this.bindLogAutoscroll();
      this.bindTabWatch();
      window.addEventListener('keydown', (e) => this.cnKeyDown(e));

      await this.refreshConfig();
      await this.refreshItems();

      // Auto-open setup wizard on first run.
      if (this.config.needsSetup) {
        this.openSetup();
      }
    },

    async refreshConfig() {
      try {
        const r = await fetch('/api/config', { headers: { 'Accept': 'application/json' } });
        if (!r.ok) throw new Error(`/api/config ${r.status}`);
        const data = await r.json();
        this.config = {
          scanRoots: Array.isArray(data.scanRoots) ? data.scanRoots : [],
          needsSetup: !!data.needsSetup,
          defaults: Array.isArray(data.defaults) ? data.defaults : [],
          maxScanRoots: typeof data.maxScanRoots === 'number' ? data.maxScanRoots : 16,
          scanMaxDepth: typeof data.scanMaxDepth === 'number' ? data.scanMaxDepth : 1
        };
      } catch (e) {
        // Don't surface — config endpoint failure shouldn't block the catalog. Settings button still works.
      }
    },

    // ── Setup wizard methods (P1.5) ─────────────────────────────────
    openSetup() {
      this.setupError = null;
      // Seed from current config; if empty, seed with defaults.
      const seed = (this.config.scanRoots && this.config.scanRoots.length)
        ? this.config.scanRoots.slice()
        : (this.config.defaults || []).slice();
      this.setupScanRoots = seed.length ? seed : [''];
      this.setupOpen = true;
    },

    closeSetup() {
      if (this.setupSaving) return;
      this.setupOpen = false;
      this.setupError = null;
      this.setupScanRoots = [];
    },

    setupAddRow() {
      const max = this.config.maxScanRoots || 16;
      if (this.setupScanRoots.length >= max) return;
      this.setupScanRoots.push('');
    },

    setupRemoveRow(idx) {
      if (this.setupScanRoots.length <= 1) return;
      this.setupScanRoots.splice(idx, 1);
    },

    async setupBrowseFolder(idx) {
      this.setupError = null;
      try {
        const r = await this.postJson('/api/browse-folder', {});
        if (!r.ok) {
          if (r.status === 429) {
            this.setupError = 'Folder picker is rate-limited (one open every 2 seconds).';
          } else {
            this.setupError = `Browse failed: HTTP ${r.status}`;
          }
          return;
        }
        const data = await r.json();
        if (!data.cancelled && data.path) {
          this.setupScanRoots[idx] = data.path;
        }
      } catch (e) {
        this.setupError = 'Browse failed: ' + (e && e.message ? e.message : e);
      }
    },

    async setupSave() {
      this.setupError = null;
      const cleaned = this.setupScanRoots
        .map(p => (p || '').trim())
        .filter(p => p.length > 0);
      if (cleaned.length === 0) {
        this.setupError = 'Add at least one folder.';
        return;
      }
      const max = this.config.maxScanRoots || 16;
      if (cleaned.length > max) {
        this.setupError = `Too many folders (max ${max}).`;
        return;
      }
      this.setupSaving = true;
      try {
        const r = await this.postJson('/api/setup', { scanRoots: cleaned });
        if (!r.ok) {
          let detail = `HTTP ${r.status}`;
          try {
            const body = await r.json();
            if (body && body.error) {
              detail = body.error + (body.path ? ` (${body.path})` : '') + (body.max ? ` (max ${body.max})` : '');
            }
          } catch (_) { /* ignore */ }
          this.setupError = 'Save failed: ' + detail;
          return;
        }
        // Success: refresh config + catalog, close modal.
        await this.refreshConfig();
        await this.refreshItems();
        this.setupOpen = false;
        this.setupScanRoots = [];
      } catch (e) {
        this.setupError = 'Save failed: ' + (e && e.message ? e.message : e);
      } finally {
        this.setupSaving = false;
      }
    },

    // ── Persisted prefs (filter + sort + autoScroll) ────────────────
    restorePrefs() {
      try {
        const k = localStorage.getItem('hub.kindFilter');
        const s = localStorage.getItem('hub.sortBy');
        const a = localStorage.getItem('hub.autoScroll');
        const h = localStorage.getItem('hub.hiddenIds');
        const sh = localStorage.getItem('hub.showHidden');
        if (k) this.kindFilter = k;
        if (s) this.sortBy = s;
        if (a !== null) this.autoScroll = a === '1';
        if (h) {
          try {
            const parsed = JSON.parse(h);
            if (Array.isArray(parsed)) this.hiddenIds = parsed.filter(x => typeof x === 'string');
          } catch (e) { /* ignore malformed */ }
        }
        if (sh !== null) this.showHidden = sh === '1';
      } catch (e) { /* ignore */ }

      this.$watch && this.$watch('kindFilter', (v) => { try { localStorage.setItem('hub.kindFilter', v); } catch (e) {} });
      this.$watch && this.$watch('sortBy',     (v) => { try { localStorage.setItem('hub.sortBy', v); } catch (e) {} });
      this.$watch && this.$watch('autoScroll', (v) => { try { localStorage.setItem('hub.autoScroll', v ? '1' : '0'); } catch (e) {} });
      this.$watch && this.$watch('hiddenIds',  (v) => { try { localStorage.setItem('hub.hiddenIds', JSON.stringify(v)); } catch (e) {} });
      this.$watch && this.$watch('showHidden', (v) => { try { localStorage.setItem('hub.showHidden', v ? '1' : '0'); } catch (e) {} });
    },

    isHidden(item) {
      return this.hiddenIds.indexOf(item.id) !== -1;
    },

    toggleHidden(item) {
      const idx = this.hiddenIds.indexOf(item.id);
      if (idx === -1) {
        this.hiddenIds = this.hiddenIds.concat([item.id]);
      } else {
        const next = this.hiddenIds.slice();
        next.splice(idx, 1);
        this.hiddenIds = next;
      }
      // If we just hid every visible item, auto-reveal so user isn't stranded.
      if (!this.showHidden && this.hiddenIds.length === this.items.length && this.items.length > 0) {
        this.showHidden = true;
      }
    },

    bindKeyboard() {
      window.addEventListener('keydown', (ev) => {
        const tag = (ev.target && ev.target.tagName) || '';
        const inField = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';

        // Ctrl/Cmd+K → toggle command palette (always allowed unless typing in a non-palette input)
        if ((ev.ctrlKey || ev.metaKey) && ev.key && ev.key.toLowerCase() === 'k') {
          const inPaletteInput = ev.target && ev.target.classList && ev.target.classList.contains('palette-input');
          if (!inField || inPaletteInput) {
            ev.preventDefault();
            if (this.paletteOpen) { this.closePalette(); } else { this.openPalette(); }
            return;
          }
        }

        // "/" focuses search (when not editing a field, not in form view, not in setup)
        if (ev.key === '/' && !inField && !this.selected && !this.setupOpen && !this.paletteOpen) {
          ev.preventDefault();
          this.$refs.searchInput && this.$refs.searchInput.focus();
          return;
        }

        // Esc → close palette, close setup, deselect item, OR clear search
        if (ev.key === 'Escape') {
          if (this.paletteOpen) {
            this.closePalette();
          } else if (this.setupOpen) {
            this.closeSetup();
          } else if (this.selected) {
            this.deselect();
          } else if (this.query) {
            this.query = '';
          }
          return;
        }
      });
    },

    bindLogAutoscroll() {
      // Whenever logLines length changes and autoScroll is on, scroll to bottom.
      this.$watch && this.$watch('logLines', () => {
        if (!this.autoScroll) return;
        queueMicrotask(() => {
          const pane = this.$refs.logPane;
          if (pane) pane.scrollTop = pane.scrollHeight;
        });
      });
    },

    readCsrfCookie() {
      const m = document.cookie.match(/(?:^|;\s*)hub-csrf=([^;]+)/);
      return m ? decodeURIComponent(m[1]) : '';
    },

    // ── Catalog fetch ───────────────────────────────────────────────
    async refreshItems() {
      this.error = null;
      try {
        const r = await fetch('/api/items', { headers: { 'Accept': 'application/json' } });
        if (!r.ok) throw new Error(`/api/items ${r.status}`);
        const data = await r.json();
        this.items = Array.isArray(data.items) ? data.items : [];
        this.warnings = Array.isArray(data.warnings) ? data.warnings : [];
      } catch (e) {
        this.error = 'Failed to load items: ' + (e && e.message ? e.message : e);
      } finally {
        this.loaded = true;
      }
    },

    // ── Computed: counts (for filter chips) ─────────────────────────
    get counts() {
      const c = { all: 0, ps1: 0, exe: 0, cloud: 0, hidden: 0 };
      for (const it of this.items) {
        const hid = this.isHidden(it);
        if (hid) c.hidden++;
        // chip counts reflect visible set (excluding hidden unless showHidden is on)
        if (hid && !this.showHidden) continue;
        c.all++;
        if (it.kind === 'ps1') c.ps1++;
        else if (it.kind === 'exe') c.exe++;
        if (it.cloudOnly) c.cloud++;
      }
      return c;
    },

    // ── Computed: filtered + sorted items ───────────────────────────
    get filteredItems() {
      const q = (this.query || '').trim().toLowerCase();
      let list = this.items;

      // 1. Hide hidden items unless toggle is on
      if (!this.showHidden) {
        list = list.filter(i => !this.isHidden(i));
      }

      if (this.kindFilter === 'cloud') {
        list = list.filter(i => i.cloudOnly);
      } else if (this.kindFilter !== 'all') {
        list = list.filter(i => i.kind === this.kindFilter);
      }

      if (q) {
        list = list.filter(i =>
          (i.name && i.name.toLowerCase().includes(q)) ||
          (i.root && i.root.toLowerCase().includes(q)) ||
          (i.description && i.description.toLowerCase().includes(q))
        );
      }

      const arr = list.slice();
      switch (this.sortBy) {
        case 'name-desc':  arr.sort((a, b) => b.name.localeCompare(a.name)); break;
        case 'mtime-desc': arr.sort((a, b) => (b.mtime || '').localeCompare(a.mtime || '')); break;
        case 'mtime-asc':  arr.sort((a, b) => (a.mtime || '').localeCompare(b.mtime || '')); break;
        case 'kind':       arr.sort((a, b) => a.kind.localeCompare(b.kind) || a.name.localeCompare(b.name)); break;
        case 'name-asc':
        default:           arr.sort((a, b) => a.name.localeCompare(b.name));
      }
      return arr;
    },

    resetFilters() {
      this.query = '';
      this.kindFilter = 'all';
      this.sortBy = 'name-asc';
    },

    // ── Selection ───────────────────────────────────────────────────
    async selectItem(item) {
      this.selected = item;
      this.schema = null;
      this.formValues = {};
      this.schemaLoading = true;
      this.resetRunState();
      try {
        const r = await fetch(`/api/items/${item.id}/schema`, { headers: { 'Accept': 'application/json' } });
        if (!r.ok) throw new Error(`/api/items/${item.id}/schema ${r.status}`);
        this.schema = await r.json();
        this.seedDefaults();
      } catch (e) {
        this.error = 'Failed to load schema: ' + (e && e.message ? e.message : e);
        this.schema = { mode: 'raw', fields: [], reason: 'fetch-failed' };
      } finally {
        this.schemaLoading = false;
      }
    },

    seedDefaults() {
      if (!this.schema || this.schema.mode !== 'typed') return;
      const v = {};
      for (const f of (this.schema.fields || [])) {
        if (f.default !== undefined && f.default !== null) {
          v[f.name] = f.default;
        } else if (f.widget === 'checkbox' || f.widget === 'checkbox-switch') {
          v[f.name] = false;
        } else if (f.widget === 'number') {
          v[f.name] = 0;
        } else {
          v[f.name] = '';
        }
      }
      this.formValues = v;
    },

    // ── Param chip strip helpers (P-schema-3) ──────────────────────
    paramChipTags(item) {
      if (!item || !item.paramPreview) return [];
      const map = {
        string:      { iconRef: '#i-terminal',  title: 'text' },
        number:      { iconRef: '#i-hash',      title: 'number' },
        bool:        { iconRef: '#i-check',     title: 'boolean' },
        switch:      { iconRef: '#i-toggle',    title: 'switch' },
        file:        { iconRef: '#i-folder',    title: 'file path' },
        password:    { iconRef: '#i-lock',      title: 'password / credential' },
        datetime:    { iconRef: '#i-calendar',  title: 'date / time' },
        url:         { iconRef: '#i-link',      title: 'URL' },
        guid:        { iconRef: '#i-hash',      title: 'GUID' },
        multi:       { iconRef: '#i-list-multi', title: 'multi-value' },
        hashtable:   { iconRef: '#i-list-multi', title: 'hashtable' },
        dropdown:    { iconRef: '#i-select',    title: 'choice' },
        unsupported: { iconRef: '#i-puzzle',    title: 'unsupported — raw fallback' },
        other:       { iconRef: '#i-terminal',  title: 'other' }
      };
      const tags = Array.isArray(item.paramPreview.typeTags) ? item.paramPreview.typeTags : [];
      return tags.slice(0, 4).map(t => Object.assign({ kind: t }, map[t] || map.other));
    },

    isRawCard(item) {
      return !!item && item.kind === 'ps1' && item.schemaMode === 'raw';
    },

    fieldGroupedBySet(fields) {
      const list = Array.isArray(fields) ? fields : [];
      const named = new Set();
      for (const f of list) {
        if (f.parameterSet && f.parameterSet !== '__AllParameterSets') {
          named.add(f.parameterSet);
        }
      }
      if (named.size < 2) {
        return [{ setName: null, fields: list }];
      }
      const groups = [];
      for (const setName of named) {
        const inSet = list.filter(f =>
          f.parameterSet === setName || !f.parameterSet || f.parameterSet === '__AllParameterSets'
        );
        groups.push({ setName, fields: inSet });
      }
      return groups;
    },

    textareaCountHint(field, val) {
      const min = field ? field.countMin : null;
      const max = field ? field.countMax : null;
      if ((min === null || min === undefined) && (max === null || max === undefined)) return '';
      const text = (val == null) ? '' : String(val);
      const lines = text.split(/\r?\n/).filter(s => s.trim().length).length;
      const minLabel = (min === null || min === undefined) ? '0' : String(min);
      const maxLabel = (max === null || max === undefined) ? '∞' : String(max);
      return `${lines} value${lines === 1 ? '' : 's'} (${minLabel}-${maxLabel} allowed)`;
    },

    // ── Tab / workflow / history ─────────────────────────────────────
    bindTabWatch() {
      this.$watch && this.$watch('activeTab', (tab) => {
        if (tab === 'workflows') this.refreshWorkflows();
        if (tab === 'history')   this.refreshHistory();
      });
    },

    async switchTab(tab) {
      this.activeTab = tab;
      if (tab !== 'catalog' && this.selected) this.deselect();
    },

    // Workflows
    async refreshWorkflows() {
      this.wfLoading = true;
      try {
        const r = await fetch('/api/workflows', { headers: { Accept: 'application/json' } });
        if (!r.ok) throw new Error(`/api/workflows ${r.status}`);
        this.workflows = await r.json();
      } catch (e) {
        this.wfError = 'Load failed: ' + (e.message || e);
      } finally { this.wfLoading = false; }
    },

    wfSelectItem(wf) {
      this.wfSelected = wf; this.wfEditMode = false; this.wfError = null;
      this.wfRun = null; this.wfRunLog = [];
      this.closeWfStream();
    },

    wfBack() {
      this.wfSelected = null; this.wfEditMode = false; this.wfForm = null; this.wfError = null;
      this.wfRun = null; this.wfRunLog = [];
      this.closeWfStream();
      if (this.wfRunPolling) { clearInterval(this.wfRunPolling); this.wfRunPolling = null; }
    },

    wfNewForm() {
      this.cnOpenNew();
    },

    wfEditForm() {
      if (!this.wfSelected) return;
      this.cnOpenWorkflow(this.wfSelected);
    },

    wfAddStep() {
      if (!this.wfForm) return;
      const n = this.wfForm.steps.length + 1;
      this.wfForm.steps.push({ id: 's' + n, scriptId: '', onSuccess: 'next', onFailure: 'stop', params: [] });
    },

    wfRemoveStep(idx) { if (this.wfForm) this.wfForm.steps.splice(idx, 1); },

    wfAddParam(stepIdx) {
      this.wfForm.steps[stepIdx].params.push({ key: '', val: '' });
    },

    wfRemoveParam(stepIdx, pIdx) {
      this.wfForm.steps[stepIdx].params.splice(pIdx, 1);
    },

    async wfSave() {
      if (!this.wfForm) return;
      this.wfSaving = true; this.wfError = null;
      const body = {
        name: this.wfForm.name.trim(),
        trigger: this.wfForm.triggerType === 'cron'
          ? { type: 'cron', expression: this.wfForm.cronExpr.trim() }
          : { type: this.wfForm.triggerType },
        steps: this.wfForm.steps.map(s => {
          const params = {};
          (s.params || []).forEach(p => { if (p.key) params[p.key] = p.val; });
          const step = { id: s.id, scriptId: s.scriptId };
          if (s.onSuccess && s.onSuccess !== 'next') step.onSuccess = s.onSuccess;
          if (s.onFailure && s.onFailure !== 'stop') step.onFailure = s.onFailure;
          if (Object.keys(params).length) step.params = params;
          return step;
        })
      };
      if (this.wfForm.id) body.id = this.wfForm.id;
      try {
        const r = await this.postJson('/api/workflows', body);
        const data = await r.json();
        if (!r.ok) { this.wfError = (data.details || [data.error]).join('; '); return; }
        this.wfEditMode = false; this.wfForm = null;
        await this.refreshWorkflows();
        this.wfSelected = this.workflows.find(w => w.id === data.id) || data;
      } catch (e) {
        this.wfError = 'Save failed: ' + (e.message || e);
      } finally { this.wfSaving = false; }
    },

    async wfDelete() {
      if (!this.wfSelected) return;
      if (!confirm('Delete workflow "' + this.wfSelected.name + '"?')) return;
      try {
        const r = await fetch('/api/workflows/' + this.wfSelected.id, {
          method: 'DELETE', headers: { 'X-Hub-CSRF': this.csrfToken }
        });
        if (!r.ok) { this.wfError = 'Delete failed: HTTP ' + r.status; return; }
        this.wfBack(); await this.refreshWorkflows();
      } catch (e) { this.wfError = 'Delete failed: ' + (e.message || e); }
    },

    async wfTrigger() {
      if (!this.wfSelected) return;
      this.wfError = null; this.wfRunLog = []; this.closeWfStream();
      try {
        const r = await this.postJson('/api/workflows/' + this.wfSelected.id + '/run', {});
        if (!r.ok) { const d = await r.json(); this.wfError = 'Run failed: ' + (d.error || r.status); return; }
        const { runId } = await r.json();
        this.wfRun = { runId, status: 'running', currentStepId: null, stepOutputs: {} };
        this.wfStartPoll(runId);
      } catch (e) { this.wfError = 'Run error: ' + (e.message || e); }
    },

    wfStartPoll(runId) {
      if (this.wfRunPolling) clearInterval(this.wfRunPolling);
      const poll = async () => {
        try {
          const r = await fetch('/api/workflow-runs/' + runId, { headers: { Accept: 'application/json' } });
          if (!r.ok) return;
          const run = await r.json();
          this.wfRun = run;
          if (run.status !== 'running') { clearInterval(this.wfRunPolling); this.wfRunPolling = null; }
        } catch (e) { /* ignore poll errors */ }
      };
      this.wfRunPolling = setInterval(poll, 800);
      poll();
    },

    async wfKill() {
      if (!this.wfRun || this.wfRun.status !== 'running') return;
      try {
        await this.postJson('/api/workflow-runs/' + this.wfRun.runId + '/kill', {});
      } catch (e) { /* ignore */ }
    },

    closeWfStream() {
      if (this.wfRunEs) { try { this.wfRunEs.close(); } catch (e) {} this.wfRunEs = null; }
    },

    wfStepStatus(stepId) {
      if (!this.wfRun) return 'pending';
      const out = this.wfRun.stepOutputs && this.wfRun.stepOutputs[stepId];
      if (out) return out.exitCode === 0 ? 'done' : 'failed';
      if (this.wfRun.currentStepId === stepId && this.wfRun.status === 'running') return 'running';
      return 'pending';
    },

    wfStepIds() {
      return (this.wfSelected && this.wfSelected.steps || []).map(s => s.id);
    },

    // History
    async refreshHistory() {
      this.histLoading = true;
      try {
        const url = `/api/history?limit=${this.histLimit}&offset=${this.histOffset}`;
        const r = await fetch(url, { headers: { Accept: 'application/json' } });
        if (!r.ok) throw new Error('/api/history ' + r.status);
        const d = await r.json();
        this.histEntries = d.entries || []; this.histTotal = d.total || 0;
      } catch (e) { /* non-fatal */ }
      finally { this.histLoading = false; }
    },

    async histNextPage() { this.histOffset += this.histLimit; await this.refreshHistory(); },
    async histPrevPage() { this.histOffset = Math.max(0, this.histOffset - this.histLimit); await this.refreshHistory(); },

    histFormatDuration(ms) {
      if (!ms && ms !== 0) return '';
      if (ms < 1000) return ms + 'ms';
      if (ms < 60000) return (ms / 1000).toFixed(1) + 's';
      return Math.round(ms / 60000) + 'm ' + Math.round((ms % 60000) / 1000) + 's';
    },

    // ── Command-K palette (P-ui-3) ──────────────────────────────────
    get paletteResults() {
      const q = (this.paletteQuery || '').trim().toLowerCase();
      const base = this.items || [];
      const wfs  = (this.workflows || []).map(w => ({ ...w, _isWorkflow: true }));
      const all  = [...base, ...wfs];
      const filter = q
        ? all.filter(it =>
            (it.name || '').toLowerCase().includes(q) ||
            (it.description || '').toLowerCase().includes(q) ||
            (!it._isWorkflow && (it.path || '').split(/[\\/]/).pop().toLowerCase().includes(q)))
        : all;
      return filter
        .slice()
        .sort((a, b) => (a.name || '').length - (b.name || '').length)
        .slice(0, 12);
    },

    openPalette()  { this.paletteOpen = true; this.paletteQuery = ''; this.paletteIndex = 0; },
    closePalette() { this.paletteOpen = false; this.paletteQuery = ''; this.paletteIndex = 0; },
    selectPaletteItem() {
      const it = this.paletteResults[this.paletteIndex];
      if (!it) return;
      if (it._isWorkflow) {
        this.activeTab = 'workflows';
        this.$nextTick(() => this.wfSelectItem(it));
      } else {
        this.activeTab = 'catalog';
        this.selectItem(it);
      }
      this.closePalette();
    },
    movePaletteIndex(delta) {
      const len = this.paletteResults.length;
      if (len === 0) return;
      this.paletteIndex = (this.paletteIndex + delta + len) % len;
    },

    deselect() {
      this.closeStream();
      this.selected = null;
      this.schema = null;
      this.formValues = {};
      this.resetRunState();
    },

    // ── Run state ───────────────────────────────────────────────────
    resetRunState() {
      this.closeStream();
      this.currentJob = null;
      this.submitting = false;
      this.ended = false;
      this.exitCode = null;
      this.endStatus = '';
      this.logLines = [];
    },

    clearLog() {
      this.logLines = [];
    },

    closeStream() {
      if (this.eventSource) {
        try { this.eventSource.close(); } catch (e) { /* ignore */ }
        this.eventSource = null;
      }
    },

    async postJson(url, body) {
      return fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Hub-CSRF': this.csrfToken
        },
        body: JSON.stringify(body || {})
      });
    },

    isFormValid() {
      if (!this.schema || this.schema.mode !== 'typed') return true;
      for (const f of (this.schema.fields || [])) {
        if (!f.required) continue;
        const v = this.formValues[f.name];
        if (v === null || v === undefined || v === '') return false;
      }
      return true;
    },

    async submit() {
      if (this.submitting) return;
      if (!this.isFormValid()) return;
      this.error = null;
      this.resetRunState();
      this.submitting = true;
      try {
        const body = { itemId: this.selected.id };
        if (this.schema && this.schema.mode === 'raw') {
          body.rawArgs = this.formValues.__rawArgs || '';
        } else {
          body.values = this.formValues;
        }
        const r = await this.postJson('/api/run', body);
        if (!r.ok) {
          let detail = '';
          try { detail = (await r.json()).error; } catch (e) { detail = `HTTP ${r.status}`; }
          this.error = 'Run failed: ' + detail;
          this.submitting = false;
          return;
        }
        const { jobId } = await r.json();
        this.currentJob = jobId;
        this.openStream(jobId);
      } catch (e) {
        this.error = 'Submit error: ' + (e && e.message ? e.message : e);
        this.submitting = false;
      }
    },

    openStream(jobId) {
      this.closeStream();
      const es = new EventSource('/api/stream/' + jobId);
      this.eventSource = es;
      es.addEventListener('line', (ev) => {
        try {
          const data = JSON.parse(ev.data);
          this.logLines.push(data);
        } catch (e) { /* ignore */ }
      });
      es.addEventListener('end', (ev) => {
        try {
          const data = JSON.parse(ev.data);
          this.exitCode = data.exitCode;
          this.endStatus = data.status;
        } catch (e) { /* ignore */ }
        this.ended = true;
        this.submitting = false;
        this.closeStream();
      });
      es.onerror = () => {
        if (!this.ended) {
          this.error = 'Stream connection lost';
        }
        this.closeStream();
      };
    },

    async kill() {
      if (!this.currentJob || this.ended) return;
      try {
        const r = await this.postJson(`/api/jobs/${this.currentJob}/kill`, {});
        if (!r.ok && r.status !== 204) {
          this.error = `Kill returned HTTP ${r.status}`;
        }
      } catch (e) {
        this.error = 'Kill failed: ' + (e && e.message ? e.message : e);
      }
    },

    // ── Helpers ─────────────────────────────────────────────────────
    shortRoot(root) {
      if (!root) return '';
      const parts = root.replace(/\\+$/, '').split('\\');
      if (parts.length <= 2) return root;
      return '…\\' + parts.slice(-2).join('\\');
    },

    formatMtime(iso) {
      if (!iso) return '';
      const d = new Date(iso);
      if (isNaN(d.getTime())) return iso;

      const now = new Date();
      const diffMs = now - d;
      const diffMin = Math.round(diffMs / 60000);
      const diffHr  = Math.round(diffMs / 3600000);
      const diffDay = Math.round(diffMs / 86400000);

      if (diffMs < 0)        return d.toLocaleString();
      if (diffMin < 1)       return 'just now';
      if (diffMin < 60)      return diffMin + 'm ago';
      if (diffHr < 24)       return diffHr + 'h ago';
      if (diffDay < 7)       return diffDay + 'd ago';
      if (diffDay < 365)     return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
      return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
    }
  };
}
