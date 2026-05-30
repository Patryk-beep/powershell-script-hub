// canvas-editor.js — Visual workflow canvas (drag-and-drop node editor).
// Exposes canvasEditorMixin() spread into hubApp().
// Node positions in canvas space; coordinate conversion: cx = (mx - panX) / scale.

function canvasEditorMixin() {
  // ── Utility helpers (module-private) ────────────────────────────────────────
  function uuid4() {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
      const r = Math.random() * 16 | 0;
      return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
    });
  }

  function clamp(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }
  function snap(v, g) { return Math.round(v / g) * g; }

  // Bezier path between two canvas-space points.
  function bezierD(x1, y1, x2, y2) {
    const cx1 = x1 + 80, cx2 = x2 - 80;
    return `M${x1},${y1} C${cx1},${y1} ${cx2},${y2} ${x2},${y2}`;
  }

  // DFS cycle detection on node graph.
  function detectCycle(nodes, edges) {
    const adj = {};
    nodes.forEach(n => (adj[n.id] = []));
    edges.forEach(e => { if (adj[e.fromNode]) adj[e.fromNode].push(e.toNode); });
    const vis = {}, stk = {};
    function dfs(id) {
      if (stk[id]) return true;
      if (vis[id]) return false;
      vis[id] = stk[id] = true;
      for (const nb of (adj[id] || [])) if (dfs(nb)) return true;
      stk[id] = false;
      return false;
    }
    return nodes.some(n => dfs(n.id));
  }

  // Kahn topological sort; returns sorted node array or null if cycle exists.
  function topoSort(nodes, edges) {
    const inDeg = {}, adj = {};
    nodes.forEach(n => { inDeg[n.id] = 0; adj[n.id] = []; });
    edges.forEach(e => { if (adj[e.fromNode]) { adj[e.fromNode].push(e.toNode); inDeg[e.toNode] = (inDeg[e.toNode] || 0) + 1; } });
    const q = nodes.filter(n => inDeg[n.id] === 0).map(n => n.id);
    const order = [];
    while (q.length) {
      const id = q.shift(); order.push(id);
      for (const nb of adj[id]) { if (--inDeg[nb] === 0) q.push(nb); }
    }
    if (order.length !== nodes.length) return null; // cycle
    return order.map(id => nodes.find(n => n.id === id));
  }

  // Port offsets within a node (canvas space, relative to node top-left).
  const NODE_W = 220, NODE_H = 80;
  const PORT = {
    in:      (n) => ({ x: n.x,           y: n.y + NODE_H / 2 }),
    success: (n) => ({ x: n.x + NODE_W,  y: n.y + NODE_H / 3 }),
    failure: (n) => ({ x: n.x + NODE_W,  y: n.y + (NODE_H * 2) / 3 }),
  };

  // ── Mixin object ──────────────────────────────────────────────────────────────
  return {
    // Canvas state
    cnNodes: [],
    cnEdges: [],
    cnNextN: 1,
    cnPanX: 0, cnPanY: 0, cnScale: 1,
    cnQuery: '',
    cnError: null,
    cnCanvasMode: false,
    cnWorkflowId: null,
    cnWorkflowName: '',

    // Interaction state
    cnDragScript: null,  // {script, gx, gy} — dragging from sidebar
    cnMoving: null,      // {nodeId, startMX, startMY, nodeX0, nodeY0}
    cnDrawEdge: null,    // {fromNode, fromPort, x1, y1, x2, y2}
    cnPanning: false,
    cnPanStart: null,    // {mx, my, panX0, panY0}
    cnPointerId: null,

    // Selection
    cnSelNode: null,     // selected node id
    cnSelEdge: null,     // selected edge id
    cnNodeSchema: null,
    cnNodeSchemaLoading: false,

    // ── Computed ────────────────────────────────────────────────────────────────
    get cnTransformStyle() {
      return `transform:translate(${this.cnPanX}px,${this.cnPanY}px) scale(${this.cnScale});transform-origin:0 0`;
    },
    get cnSvgTransform() {
      return `translate(${this.cnPanX},${this.cnPanY}) scale(${this.cnScale})`;
    },
    get cnFilteredItems() {
      const q = this.cnQuery.trim().toLowerCase();
      const base = this.items || [];
      return q ? base.filter(i => (i.name||'').toLowerCase().includes(q) || (i.description||'').toLowerCase().includes(q)) : base;
    },
    get cnSelectedNodeObj() {
      return this.cnSelNode ? this.cnNodes.find(n => n.id === this.cnSelNode) : null;
    },

    // ── Canvas open/close ────────────────────────────────────────────────────────
    cnOpenNew() {
      this.cnNodes = []; this.cnEdges = []; this.cnNextN = 1;
      this.cnPanX = 0; this.cnPanY = 0; this.cnScale = 1;
      this.cnWorkflowId = null; this.cnWorkflowName = '';
      this.cnSelNode = null; this.cnSelEdge = null; this.cnError = null;
      this.cnCanvasMode = true;
      this.wfEditMode = false;
      this.$nextTick(() => this.cnFitScreen());   // A4: harmless when empty (early-returns)
    },

    cnOpenWorkflow(wf) {
      this.cnWorkflowId = wf.id || null;
      this.cnWorkflowName = wf.name || '';
      this.cnSelNode = null; this.cnSelEdge = null; this.cnError = null;
      if (wf.canvas && Array.isArray(wf.canvas.nodes)) {
        this.cnNodes = wf.canvas.nodes.map(n => ({ ...n }));
        this.cnEdges = wf.canvas.edges ? wf.canvas.edges.map(e => ({ ...e })) : [];
        this.cnNextN = wf.canvas.nextStepN || (this.cnNodes.length + 1);
        this.cnPanX  = wf.canvas.viewport ? wf.canvas.viewport.panX || 0 : 0;
        this.cnPanY  = wf.canvas.viewport ? wf.canvas.viewport.panY || 0 : 0;
        this.cnScale = wf.canvas.viewport ? wf.canvas.viewport.scale || 1 : 1;
      } else {
        // Auto-layout from steps[].
        this.cnNodes = []; this.cnEdges = []; this.cnNextN = 1;
        const catalog = this.items || [];
        const idToNodeId = {};
        (wf.steps || []).forEach((step, i) => {
          const item = catalog.find(it => it.path === step.scriptId || it.id === step.scriptId);
          const nodeId = 'n-' + uuid4();
          idToNodeId[step.id] = nodeId;
          this.cnNodes.push({
            id: nodeId, stepId: step.id,
            scriptId: step.scriptId,
            scriptName: item ? item.name : (step.scriptId || '').split(/[\\/]/).pop().replace(/\.ps1$/i,''),
            itemId: item ? item.id : null,
            x: 260, y: 80 + i * 160,
            params: step.params || {},
          });
          this.cnNextN = i + 2;
        });
        // Convert step onSuccess/onFailure to edges.
        (wf.steps || []).forEach((step, i) => {
          const fromId = idToNodeId[step.id];
          if (!fromId) return;
          ['onSuccess','onFailure'].forEach(field => {
            let target = step[field];
            if (!target || target === 'stop') return;
            if (target === 'next') target = wf.steps[i+1] ? wf.steps[i+1].id : null;
            if (!target) return;
            const toId = idToNodeId[target];
            if (!toId || toId === fromId) return;
            this.cnEdges.push({ id: 'e-' + uuid4(), fromNode: fromId, fromPort: field === 'onSuccess' ? 'success' : 'failure', toNode: toId });
          });
        });
        this.cnPanX = 0; this.cnPanY = 0; this.cnScale = 1;
        // A4: auto-fit ONLY on the auto-layout branch (no saved viewport to clobber).
        // Must run after the canvas DOM renders (cnFitScreen reads getBoundingClientRect).
        this.$nextTick(() => this.cnFitScreen());
      }
      this.cnCanvasMode = true;
    },

    cnClose() {
      this.cnCanvasMode = false;
      this.cnDragScript = null; this.cnMoving = null;
      this.cnDrawEdge = null; this.cnPanning = false;
    },

    // ── Node operations ──────────────────────────────────────────────────────────
    cnAddNode(script, canvasX, canvasY) {
      if (this.cnNodes.length >= 50) { this.cnError = 'Maximum 50 nodes per workflow.'; return; }
      this.cnSnapshot();   // A3: undo boundary
      const stepId = 's' + this.cnNextN++;
      const id = 'n-' + uuid4();
      this.cnNodes.push({
        id, stepId,
        scriptId: script.path,
        scriptName: script.name,
        itemId: script.id,
        x: this.cnSnap(canvasX - NODE_W / 2),   // A2: honors grid-snap toggle
        y: this.cnSnap(canvasY - NODE_H / 2),
        params: {},
      });
      this.cnSelNode = id;
      this.cnLoadNodeSchema(id);
    },

    cnRemoveNode(nodeId) {
      this.cnSnapshot();   // A3: undo boundary
      this.cnNodes = this.cnNodes.filter(n => n.id !== nodeId);
      this.cnEdges = this.cnEdges.filter(e => e.fromNode !== nodeId && e.toNode !== nodeId);
      if (this.cnSelNode === nodeId) { this.cnSelNode = null; this.cnNodeSchema = null; }
    },

    cnSelectNode(nodeId, e) {
      if (e) e.stopPropagation();
      if (this.cnSelNode === nodeId) return;
      this.cnSelNode = nodeId; this.cnSelEdge = null;
      this.cnLoadNodeSchema(nodeId);
    },

    async cnLoadNodeSchema(nodeId) {
      const node = this.cnNodes.find(n => n.id === nodeId);
      if (!node || !node.itemId) { this.cnNodeSchema = null; return; }
      this.cnNodeSchemaLoading = true; this.cnNodeSchema = null;
      try {
        const r = await fetch(`/api/items/${node.itemId}/schema`, { headers: { Accept: 'application/json' } });
        if (r.ok) this.cnNodeSchema = await r.json();
      } catch (e) { /* non-fatal */ }
      finally { this.cnNodeSchemaLoading = false; }
    },

    // ── Edge operations ──────────────────────────────────────────────────────────
    cnAddEdge(fromNode, fromPort, toNode) {
      if (fromNode === toNode) return;
      this.cnSnapshot();   // A3: undo boundary
      // One edge per port.
      this.cnEdges = this.cnEdges.filter(e => !(e.fromNode === fromNode && e.fromPort === fromPort));
      this.cnEdges.push({ id: 'e-' + uuid4(), fromNode, fromPort, toNode });
      if (detectCycle(this.cnNodes, this.cnEdges)) {
        this.cnEdges.pop(); this.cnError = 'This connection would create a cycle.';
        setTimeout(() => { this.cnError = null; }, 3000);
      }
    },

    cnRemoveEdge(edgeId) {
      this.cnSnapshot();   // A3: undo boundary
      this.cnEdges = this.cnEdges.filter(e => e.id !== edgeId);
      if (this.cnSelEdge === edgeId) this.cnSelEdge = null;
    },

    // ── Edge rendering ───────────────────────────────────────────────────────────
    cnBezier(edge) {
      const fn = this.cnNodes.find(n => n.id === edge.fromNode);
      const tn = this.cnNodes.find(n => n.id === edge.toNode);
      if (!fn || !tn) return '';
      const p1 = PORT[edge.fromPort](fn), p2 = PORT.in(tn);
      return bezierD(p1.x, p1.y, p2.x, p2.y);
    },

    cnRubberBand() {
      if (!this.cnDrawEdge) return '';
      return bezierD(this.cnDrawEdge.x1, this.cnDrawEdge.y1, this.cnDrawEdge.x2, this.cnDrawEdge.y2);
    },

    cnEdgeColor(edge) {
      return edge.fromPort === 'success' ? '#4ec588' : '#e8546a';
    },

    // ── Pointer event helpers ────────────────────────────────────────────────────
    cnCanvasXY(e) {
      const el = this.$refs && this.$refs.cnWrap;
      const rect = el ? el.getBoundingClientRect() : { left: 0, top: 0 };
      return {
        x: (e.clientX - rect.left - this.cnPanX) / this.cnScale,
        y: (e.clientY - rect.top  - this.cnPanY) / this.cnScale,
      };
    },

    // Sidebar drag start (pointer on sidebar item).
    cnSidebarPointerDown(e, script) {
      e.preventDefault();
      const el = this.$refs && this.$refs.cnWrap;
      const rect = el ? el.getBoundingClientRect() : { left: 0, top: 0 };
      this.cnDragScript = { script, gx: e.clientX - rect.left, gy: e.clientY - rect.top };
      window.addEventListener('pointermove', this._cnSidebarMove = (ev) => this.cnSidebarMove(ev), { passive: false });
      window.addEventListener('pointerup',   this._cnSidebarUp   = (ev) => this.cnSidebarUp(ev),   { once: true });
    },

    cnSidebarMove(e) {
      if (!this.cnDragScript) return;
      const el = this.$refs && this.$refs.cnWrap;
      const rect = el ? el.getBoundingClientRect() : { left: 0, top: 0 };
      this.cnDragScript = { ...this.cnDragScript, gx: e.clientX - rect.left, gy: e.clientY - rect.top };
    },

    cnSidebarUp(e) {
      if (this._cnSidebarMove) { window.removeEventListener('pointermove', this._cnSidebarMove); this._cnSidebarMove = null; }
      if (!this.cnDragScript) return;
      const el = this.$refs && this.$refs.cnWrap;
      const rect = el ? el.getBoundingClientRect() : { left: 0, top: 0 };
      // Check if dropped over canvas wrap.
      if (e.clientX >= rect.left && e.clientX <= rect.right && e.clientY >= rect.top && e.clientY <= rect.bottom) {
        const cx = (e.clientX - rect.left - this.cnPanX) / this.cnScale;
        const cy = (e.clientY - rect.top  - this.cnPanY) / this.cnScale;
        this.cnAddNode(this.cnDragScript.script, cx, cy);
      }
      this.cnDragScript = null;
    },

    // Canvas pointer down — determines what we're doing.
    cnWrapPointerDown(e) {
      if (e.button !== 0) return;
      const el = this.$refs && this.$refs.cnWrap;
      if (!el) return;

      // Check what was clicked via data attributes.
      const portEl = e.target.closest('[data-port]');
      const nodeEl = e.target.closest('[data-nodeid]');
      const edgeEl = e.target.closest('[data-edgeid]');

      if (portEl && portEl.dataset.port !== 'in') {
        // Start drawing edge from output port.
        const nodeId = portEl.dataset.nodeid;
        const port   = portEl.dataset.port;
        const node   = this.cnNodes.find(n => n.id === nodeId);
        if (!node) return;
        const p = PORT[port](node);
        this.cnDrawEdge = { fromNode: nodeId, fromPort: port, x1: p.x, y1: p.y, x2: p.x, y2: p.y };
        el.setPointerCapture(e.pointerId);
        this.cnPointerId = e.pointerId;
        return;
      }

      if (nodeEl) {
        // Move node.
        const nodeId = nodeEl.dataset.nodeid;
        const node   = this.cnNodes.find(n => n.id === nodeId);
        if (!node) return;
        this.cnSelectNode(nodeId, null);
        this.cnSnapshot();   // A3: undo boundary — once per drag, NOT per pointermove
        this.cnMoving = { nodeId, startMX: e.clientX, startMY: e.clientY, nodeX0: node.x, nodeY0: node.y };
        el.setPointerCapture(e.pointerId);
        this.cnPointerId = e.pointerId;
        return;
      }

      if (edgeEl) {
        this.cnSelEdge = edgeEl.dataset.edgeid;
        this.cnSelNode = null;
        return;
      }

      // Pan.
      this.cnSelNode = null; this.cnSelEdge = null;
      this.cnPanning = true;
      this.cnPanStart = { mx: e.clientX, my: e.clientY, panX0: this.cnPanX, panY0: this.cnPanY };
      el.setPointerCapture(e.pointerId);
      this.cnPointerId = e.pointerId;
    },

    cnWrapPointerMove(e) {
      if (this.cnMoving) {
        const dx = e.clientX - this.cnMoving.startMX;
        const dy = e.clientY - this.cnMoving.startMY;
        const node = this.cnNodes.find(n => n.id === this.cnMoving.nodeId);
        if (node) {
          node.x = clamp(this.cnMoving.nodeX0 + dx / this.cnScale, -4000, 4000);
          node.y = clamp(this.cnMoving.nodeY0 + dy / this.cnScale, -4000, 4000);
        }
        return;
      }

      if (this.cnDrawEdge) {
        const el = this.$refs && this.$refs.cnWrap;
        const rect = el ? el.getBoundingClientRect() : { left: 0, top: 0 };
        this.cnDrawEdge = {
          ...this.cnDrawEdge,
          x2: (e.clientX - rect.left - this.cnPanX) / this.cnScale,
          y2: (e.clientY - rect.top  - this.cnPanY) / this.cnScale,
        };
        return;
      }

      if (this.cnPanning && this.cnPanStart) {
        this.cnPanX = this.cnPanStart.panX0 + (e.clientX - this.cnPanStart.mx);
        this.cnPanY = this.cnPanStart.panY0 + (e.clientY - this.cnPanStart.my);
      }
    },

    cnWrapPointerUp(e) {
      const el = this.$refs && this.$refs.cnWrap;
      if (el && this.cnPointerId !== null) { try { el.releasePointerCapture(this.cnPointerId); } catch (_) {} this.cnPointerId = null; }

      if (this.cnMoving) {
        const node = this.cnNodes.find(n => n.id === this.cnMoving.nodeId);
        if (node) { node.x = this.cnSnap(node.x); node.y = this.cnSnap(node.y); }   // A2
        this.cnMoving = null;
        return;
      }

      if (this.cnDrawEdge) {
        // Hit-test for input port under cursor (with pointer-events:none on rubber-band path).
        const under = document.elementFromPoint(e.clientX, e.clientY);
        const portEl = under && under.closest('[data-port="in"]');
        if (portEl) {
          const toNodeId = portEl.dataset.nodeid;
          if (toNodeId) this.cnAddEdge(this.cnDrawEdge.fromNode, this.cnDrawEdge.fromPort, toNodeId);
        }
        this.cnDrawEdge = null;
        return;
      }

      if (this.cnPanning) { this.cnPanning = false; this.cnPanStart = null; }
    },

    cnWrapWheel(e) {
      e.preventDefault();
      const el = this.$refs && this.$refs.cnWrap;
      const rect = el ? el.getBoundingClientRect() : { left: 0, top: 0 };
      const factor = e.ctrlKey ? 0.002 : 0.001;
      const delta  = -e.deltaY * factor;
      const oldScale = this.cnScale;
      const newScale = clamp(oldScale * Math.exp(delta * 5), 0.25, 2.5);
      // Zoom around cursor.
      const mx = e.clientX - rect.left, my = e.clientY - rect.top;
      const cx = (mx - this.cnPanX) / oldScale;
      const cy = (my - this.cnPanY) / oldScale;
      this.cnScale = newScale;
      this.cnPanX  = mx - cx * newScale;
      this.cnPanY  = my - cy * newScale;
    },

    cnKeyDown(e) {
      if (!this.cnCanvasMode) return;
      if (e.key === 'Delete' || e.key === 'Backspace') {
        const tag = (e.target && e.target.tagName) || '';
        if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
        if (this.cnSelNode)  { this.cnRemoveNode(this.cnSelNode); return; }
        if (this.cnSelEdge)  { this.cnRemoveEdge(this.cnSelEdge); return; }
      }
      // A3: one-level undo. ADV-101 — this branch carries its OWN field guard;
      // the Delete/Backspace guard above is branch-local, not function-scoped.
      if ((e.ctrlKey || e.metaKey) && e.key && e.key.toLowerCase() === 'z') {
        const tag = (e.target && e.target.tagName) || '';
        if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
        e.preventDefault();
        this.cnUndo();
        return;
      }
      if (e.key === 'Escape') { this.cnSelNode = null; this.cnSelEdge = null; this.cnDrawEdge = null; }
    },

    cnFitScreen() {
      if (!this.cnNodes.length) return;
      const el = this.$refs && this.$refs.cnWrap;
      if (!el) return;
      const rect = el.getBoundingClientRect();
      const xs = this.cnNodes.map(n => n.x), ys = this.cnNodes.map(n => n.y);
      const minX = Math.min(...xs), maxX = Math.max(...xs) + NODE_W;
      const minY = Math.min(...ys), maxY = Math.max(...ys) + NODE_H;
      const pad = 40;
      const sw = rect.width - pad * 2, sh = rect.height - pad * 2;
      const scale = clamp(Math.min(sw / (maxX - minX), sh / (maxY - minY)), 0.25, 2);
      this.cnScale = scale;
      this.cnPanX  = pad - minX * scale;
      this.cnPanY  = pad - minY * scale;
    },

    // ── Save to API ──────────────────────────────────────────────────────────────
    async cnSave() {
      this.cnError = null;
      if (!this.cnWorkflowName.trim()) { this.cnError = 'Workflow name is required.'; return; }
      if (this.cnNodes.length === 0)   { this.cnError = 'Add at least one script to the canvas.'; return; }
      if (this.cnNodes.length > 50)    { this.cnError = 'Maximum 50 nodes per workflow.'; return; }
      if (detectCycle(this.cnNodes, this.cnEdges)) { this.cnError = 'Workflow contains a cycle — remove the back-edge before saving.'; return; }

      const sorted = topoSort(this.cnNodes, this.cnEdges);
      if (!sorted) { this.cnError = 'Could not determine step order (cycle detected).'; return; }

      const edgeMap = {};
      this.cnEdges.forEach(e => { edgeMap[`${e.fromNode}:${e.fromPort}`] = e.toNode; });
      const nodeById = {};
      this.cnNodes.forEach(n => (nodeById[n.id] = n));

      const steps = sorted.map(node => {
        const step = { id: node.stepId, scriptId: node.scriptId };
        if (node.params && Object.keys(node.params).length) step.params = { ...node.params };
        const succId = edgeMap[`${node.id}:success`];
        const failId = edgeMap[`${node.id}:failure`];
        if (succId && nodeById[succId]) step.onSuccess = nodeById[succId].stepId;
        if (failId && nodeById[failId]) step.onFailure = nodeById[failId].stepId;
        return step;
      });

      const body = {
        name: this.cnWorkflowName.trim(),
        steps,
        canvas: {
          version: 1,
          nodes: this.cnNodes.map(n => ({ id: n.id, stepId: n.stepId, scriptId: n.scriptId, scriptName: n.scriptName, itemId: n.itemId, x: n.x, y: n.y, params: n.params || {} })),
          edges: this.cnEdges.map(e => ({ ...e })),
          viewport: { panX: Math.round(this.cnPanX), panY: Math.round(this.cnPanY), scale: +this.cnScale.toFixed(3) },
          nextStepN: this.cnNextN,
        },
      };
      if (this.cnWorkflowId) body.id = this.cnWorkflowId;

      this.wfSaving = true;
      try {
        const r = await this.postJson('/api/workflows', body);
        const data = await r.json();
        if (!r.ok) {
          this.cnError = ((data.details && data.details.join) ? data.details.join('; ') : data.error) || `HTTP ${r.status}`;
          return;
        }
        this.cnWorkflowId = data.id;
        await this.refreshWorkflows();
        this.cnClose();
        this.wfSelected = this.workflows.find(w => w.id === data.id) || null;
        this.activeTab = 'workflows';
      } catch (ex) {
        this.cnError = 'Save failed: ' + (ex.message || ex);
      } finally {
        this.wfSaving = false;
      }
    },
  };
}
