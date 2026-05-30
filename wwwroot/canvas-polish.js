// canvas-polish.js — Phase 1 canvas polish: grid-snap toggle, one-level undo,
// auto-fit-on-open helper, and a display-only minimap.
// Exposes canvasPolishMixin() spread into hubApp() alongside canvasEditorMixin().
//
// NOTE: snap()/NODE_W/NODE_H/clamp are closure-private to canvas-editor.js and are
// NOT visible here. cnSnap() therefore inlines the 8px snap math, and cnMinimap
// re-declares NODE_W/NODE_H locally (stable constants, mirrors canvas-editor.js:56).

function canvasPolishMixin() {
  return {
    // ── State ────────────────────────────────────────────────────────────────
    cnSnapEnabled: true,     // grid-snap toggle (A2); persisted to hub.cnSnapEnabled
    cnUndoSnapshot: null,    // single previous snapshot (A3) — ONE level only, not a stack

    // ── Init helper (called from app.js init() after restorePrefs) ─────────────
    restoreCanvasPolish() {
      try {
        const s = localStorage.getItem('hub.cnSnapEnabled');
        if (s !== null) this.cnSnapEnabled = s === '1';
      } catch (e) { /* ignore malformed/unavailable storage */ }
      this.$watch && this.$watch('cnSnapEnabled', (v) => {
        try { localStorage.setItem('hub.cnSnapEnabled', v ? '1' : '0'); } catch (e) {}
      });
    },

    // ── A2: grid-snap helper ───────────────────────────────────────────────────
    // Honors the toggle. snap() is private to canvas-editor.js, so inline the math.
    cnSnap(v) {
      return this.cnSnapEnabled ? Math.round(v / 8) * 8 : Math.round(v);
    },

    // ── A3: one-level undo ──────────────────────────────────────────────────────
    // Call at operation boundaries (add/remove node, add/remove edge, move-start).
    cnSnapshot() {
      try {
        this.cnUndoSnapshot = {
          nodes: JSON.parse(JSON.stringify(this.cnNodes || [])),
          edges: JSON.parse(JSON.stringify(this.cnEdges || [])),
          nextN: this.cnNextN,
        };
      } catch (e) { this.cnUndoSnapshot = null; }
    },

    cnUndo() {
      const s = this.cnUndoSnapshot;
      if (!s) return;
      // Reassign to NEW arrays so Alpine reactivity fires.
      this.cnNodes = (s.nodes || []).map(n => ({ ...n }));
      this.cnEdges = (s.edges || []).map(e => ({ ...e }));
      this.cnNextN = s.nextN;
      this.cnSelNode = null;
      this.cnSelEdge = null;
      this.cnUndoSnapshot = null;   // one level only
    },

    // ── A5: display-only minimap ──────────────────────────────────────────────────
    // Returns null when the canvas is empty (template guards on cnNodes.length).
    get cnMinimap() {
      const NODE_W = 220, NODE_H = 80;
      const nodes = this.cnNodes || [];
      if (!nodes.length) return null;
      const xs = nodes.map(n => n.x), ys = nodes.map(n => n.y);
      const minX = Math.min(...xs), maxX = Math.max(...xs) + NODE_W;
      const minY = Math.min(...ys), maxY = Math.max(...ys) + NODE_H;
      const pad = 60;
      const vbX = minX - pad, vbY = minY - pad;
      const vbW = (maxX - minX) + pad * 2, vbH = (maxY - minY) + pad * 2;

      // Viewport rectangle: the canvas region currently visible in the main view.
      const el = this.$refs && this.$refs.cnWrap;
      const cw = el ? el.clientWidth : 0, ch = el ? el.clientHeight : 0;
      const scale = this.cnScale || 1;
      const view = {
        x: -this.cnPanX / scale,
        y: -this.cnPanY / scale,
        w: cw / scale,
        h: ch / scale,
      };

      return {
        viewBox: vbX + ' ' + vbY + ' ' + vbW + ' ' + vbH,
        nodes: nodes.map(n => ({ id: n.id, x: n.x, y: n.y, w: NODE_W, h: NODE_H })),
        view,
      };
    },
  };
}
