# Plan: Visual Canvas Workflow Editor (v3 — post-adversarial)

**Status**: 3 adversarial passes complete — ready to build
**Feature**: Lucidchart-style drag-and-drop canvas replacing the list-based workflow editor

## Decisions Made (non-negotiable)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Editor mode | Canvas REPLACES list editor (no dual-mode) | Eliminates dual-editor consistency bug class |
| Params editing | Side panel (right of canvas) with schema form | Reuses existing schema renderer; non-optional |
| Step ID allocation | Monotonic counter per canvas (`n` → `s{n}`), never reused after delete | Stable references for `{{step-sN.stdout}}` |
| Workflow save | Topo-sort nodes to produce steps[] ordering | Ensures backward references never appear |
| DnD mechanism | Pointer events (not HTML5 DnD API) | Predictable cross-browser coordinates |
| "next" on load | Convert implicit "next" → explicit stepId edge on canvas load | Clean DAG; never emit "next" on save |
| Phase F polish | Deferred (minimap, undo, grid snap, fit-to-screen) | Scope limit |
| Node drag impl | foreignObject for nodes, pure SVG for edges | Reuse CSS; fallback to plain divs if needed |

## Data Model

### Canvas State (stored in workflow.canvas — optional, backward-compatible)

```json
{
  "nodes": [
    { "id": "n-uuid", "stepId": "s1", "scriptId": "/path/to/script.ps1", "scriptName": "cleanup", "x": 150, "y": 100, "params": {"Path": "C:/Temp"} }
  ],
  "edges": [
    { "id": "e-uuid", "fromNode": "n-uuid1", "fromPort": "success", "toNode": "n-uuid2" }
  ],
  "viewport": { "panX": 0, "panY": 0, "scale": 1.0 },
  "nextStepN": 3
}
```

`nextStepN` is a monotonic counter that only increments (never reuses IDs after delete).

### Canvas → Steps Conversion (save path)

1. Topo-sort nodes using edge graph (DFS post-order, reversed). If cycle → reject with error banner, no API call.
2. For each node in topo order, emit step: `{ id: node.stepId, scriptId: node.scriptId, params: node.params }`
3. For each node, compute `onSuccess`/`onFailure` from edges:
   - Outgoing success edge → `onSuccess: targetNode.stepId`
   - No outgoing success edge → `onSuccess: "stop"`
   - Outgoing failure edge → `onFailure: targetNode.stepId`
   - No outgoing failure edge → `onFailure: "stop"`
4. Trim `onSuccess`/`onFailure: "stop"` from last step if it's the natural terminal (clean output)
5. Attach `canvas` object to workflow body before POSTing (passthrough field, ignored by engine)

### Steps → Canvas Conversion (load path)

1. If `workflow.canvas` exists → use it directly (restore positions exactly)
2. Else auto-layout: place nodes vertically at x=260, y=80 + n*160; connect via implicit edges derived from `onSuccess`/`onFailure`; generate new node UUIDs; stepId = existing step.id; `nextStepN` = steps.length + 1
3. Convert `onSuccess: "next"` → explicit edge to next step in array; `onSuccess: "stop"` / absent → no success edge

## Architecture

### Files

| File | Change | Est. Lines |
|------|--------|-----------|
| `wwwroot/canvas-editor.js` | New — full canvas component | ~480 |
| `wwwroot/index.html` | Add canvas view + side panel markup | ~120 |
| `wwwroot/app.js` | Canvas/list toggle, open canvas editor | ~30 |
| `wwwroot/style.css` | Canvas styles | ~90 |

### Coordinate System

All node positions in **canvas space**. Mouse → canvas: `cx = (mx - rect.left - panX) / scale`. Port positions computed from node (x,y): input port at `(x, y+40)`, success port at `(x+220, y+28)`, failure port at `(x+220, y+56)`.

### Interaction State Machine

```
IDLE
  └─ pointerdown on sidebar script → DRAGGING_SCRIPT (ghost node follows cursor)
  └─ pointerdown on node body → MOVING_NODE (node moves, edges follow)
  └─ pointerdown on output port → DRAWING_EDGE (rubber-band bezier from port)
  └─ pointerdown on canvas background → PANNING

DRAGGING_SCRIPT → pointerup on canvas → create node at position, back to IDLE
DRAGGING_SCRIPT → pointerup elsewhere → cancel, back to IDLE

MOVING_NODE → pointermove → update node (x,y), recompute edge endpoints
MOVING_NODE → pointerup → snap to 8px grid, persist position, back to IDLE

DRAWING_EDGE → pointermove → update rubber-band end point
DRAWING_EDGE → pointerup on input port of different node → create edge if valid, back to IDLE
DRAWING_EDGE → pointerup elsewhere → cancel, back to IDLE

PANNING → pointermove → update panX, panY
PANNING → pointerup → back to IDLE
```

## Implementation Phases

### Phase A: SVG Canvas + Pan/Zoom (~120 lines)

- `canvasEditor()` Alpine component in `canvas-editor.js`
- SVG fills `100% × calc(100vh - 120px)`
- `<g id="viewport" :transform="'translate('+panX+','+panY+') scale('+scale+')'">`
- Wheel zoom: `scale = clamp(scale * (1 - e.deltaY*0.001), 0.3, 2.5)`
- Pan via `pointermove` when `isPanning`
- Canvas `data-canvas` attribute for drop-target detection

### Phase B: Node Rendering + Drag (~150 lines)

- Node: `<foreignObject>` wrapping `<div class="cn-node">` with script name, kind badge, ports
- Port dots: `<div class="cn-port cn-port-in">`, `cn-port-success`, `cn-port-failure`
- Sidebar: existing `items` array filtered by `cnQuery`; each item draggable
- Pointer-drag from sidebar: `ghostNode` state (x,y of cursor); pointerup → create node
- Node reposition: `activeNode` state; pointermove updates `nodes[i].{x,y}`
- Grid snap on pointerup: `Math.round(x/8)*8`

### Phase B.5: Params Side Panel (~80 lines)

- `selectedNode` state — which node is active
- Right panel (280px wide, docked): shows `selectedNode.scriptName`, param form
- Param form reuses existing schema endpoint: `GET /api/items/:id/schema`
- Only shown when a node is selected; hidden on canvas click (deselect)
- Params stored directly in `selectedNode.params` (obj, not array)

### Phase C: Edge System (~100 lines)

- `drawingEdge` state: `{ fromNode, fromPort, x1, y1, x2, y2 }` during drag
- Port hit-test: `document.elementFromPoint(x, y)` → look for `[data-port]` attribute
- Bezier control points: `cx1 = x1+80, cy1=y1; cx2 = x2-80, cy2=y2` (horizontal S-curve)
- Edge rendering: `<path :d="bezier(e)" :stroke="e.fromPort==='success'?'#4ec588':'#e8546a'">`
- Validation on edge create: no self-loop, no duplicate from same port, no cycle (DFS)
- Edge click: `selectedEdge`; Delete key removes it

### Phase D: Cycle Detection (30 lines)

```js
function hasCycle(nodes, edges) {
  const adj = {};
  nodes.forEach(n => adj[n.id] = []);
  edges.forEach(e => adj[e.fromNode].push(e.toNode));
  const visited = {}, stack = {};
  function dfs(id) {
    if (stack[id]) return true;
    if (visited[id]) return false;
    visited[id] = stack[id] = true;
    for (const nb of adj[id]) if (dfs(nb)) return true;
    stack[id] = false;
    return false;
  }
  return nodes.some(n => dfs(n.id));
}
```

Called both on edge creation (real-time) and at save time.

### Phase E: Save / Load (~80 lines)

- `canvasSave()`: validate (≥1 node, no cycle), topo-sort, build steps[], call `wfSave(body)`
- `canvasLoad(wf)`: if `wf.canvas` exists → restore; else auto-layout
- Integration with `app.js`: `wfForm.canvasMode = true`; canvas editor mounted when in canvas mode
- "View JSON" toggle shows raw steps for debugging

### Phase F: Keyboard + UX (~30 lines)

- `keydown` on window: Delete → remove selected node/edge; Escape → deselect/cancel drag
- "Fit to screen" button: compute bounding box of all nodes → set pan/zoom to show all
- Node count badge in canvas header

## Security & Validation

- Script IDs come from `this.items` only — picker dropdown, not free text
- Node positions: `Math.round()` to integers, clamped to `[-5000, 5000]`
- `nextStepN` is an integer, validated before use
- Canvas field passthrough: Hub-Workflows.ps1 accepts any extra top-level JSON field (it stores the full body)
- Maximum 50 nodes enforced client-side before API call (returns error banner, not crash)

## Test Plan

1. **Smoke test** (contract assertions on HTML/JS presence) — mirrors smoke-phase3-ui.ps1 pattern
2. **Round-trip test**: create canvas state → `canvasSave()` → POST to API → GET back → `canvasLoad()` → assert node positions preserved, steps match
3. **Cycle detection test**: add a back edge → assert `hasCycle()` returns true
4. **Topo-sort test**: diamond DAG → assert valid ordering where both branches appear after source

## Success Criteria

- [ ] Drag script from sidebar → node appears on canvas at drop position
- [ ] Connect two nodes with success edge (green arrow)
- [ ] Connect two nodes with failure edge (red arrow)
- [ ] Self-loop rejected visually (no edge created)
- [ ] Cycle detected before save — error shown, no API call
- [ ] Save button → POST /api/workflows succeeds → workflow appears in list
- [ ] Open existing workflow in canvas → positions restored
- [ ] Open list-mode workflow → auto-layout applied
- [ ] Params edited in side panel → persisted in canvas node
- [ ] Delete key removes selected node (and its edges)
- [ ] Pan and zoom smooth
- [ ] All prior smoke tests still pass (P1, P2, P456, P3-UI)
