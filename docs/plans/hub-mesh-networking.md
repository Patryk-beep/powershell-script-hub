# Plan: Hub Mesh — Hub-to-Hub Networking (Option C)

**Status**: Future reference — not scheduled for implementation
**Created**: 2026-05-28
**Scope**: Multiple Hub instances discover each other on the LAN and share catalogs, run scripts remotely, and stream logs across machines.

## Vision

A team of 5 developers each run Hub on their workstation. When Alice opens her Hub, she sees her local scripts plus "Build Server Hub" and "QA Box Hub" in a sidebar. She can browse their catalogs, trigger a deploy script on the build server, and watch the logs stream back — all from her local dashboard.

## Architecture

### Network Discovery

```
Hub A (Alice)  ──┐
Hub B (Bob)    ──┤── UDP broadcast / mDNS on LAN
Hub C (Server) ──┘
                  │
            Discovery packet:
            { "hub": true, "name": "Alice-PC", "port": 8765, "version": "2.x" }
```

- **Discovery**: UDP broadcast on port 8766 every 30s, or mDNS (`_hub._tcp.local`)
- **Fallback**: Manual peer list in config for networks that block broadcast
- **Heartbeat**: Peers expire after 90s without a heartbeat

### Remote API

Every Hub already serves HTTP on port 8765. For mesh, we expose a subset as "remote-safe" endpoints:

| Endpoint | Local | Remote |
|----------|-------|--------|
| `GET /api/items` | Full catalog | Filtered by permissions |
| `GET /api/schema/:id` | Full | Full (read-only) |
| `POST /api/run` | Allowed | Requires remote-exec permission |
| `GET /api/jobs/:id/stream` | Allowed | Allowed (log streaming) |
| `POST /api/jobs/:id/kill` | Allowed | Requires remote-kill permission |
| `GET /api/health` | Allowed | Allowed (used for discovery) |
| `POST /api/setup` | Allowed | **Blocked** (never remote) |

### Security Model

```
Permissions (per-peer or global):
  - catalog-read:   Can browse my script catalog        (default: on)
  - remote-exec:    Can trigger scripts on my machine    (default: off)
  - remote-kill:    Can kill running jobs on my machine   (default: off)
  - log-stream:     Can watch job output                  (default: on)
```

- **Auth**: Shared secret (pre-shared key) or mTLS certificates for trusted peers
- **Default posture**: Catalog browsing allowed, execution denied. User must explicitly enable remote-exec per peer.
- **Audit log**: All remote actions logged with peer identity and timestamp

### Data Flow

```
Alice's Hub                          Build Server Hub
    │                                      │
    ├─ GET /api/items ──────────────────► │ (catalog-read)
    │◄── 200 [filtered items] ────────────┤
    │                                      │
    ├─ POST /api/run ───────────────────► │ (remote-exec check)
    │◄── 200 { jobId } ──────────────────┤
    │                                      │
    ├─ GET /api/jobs/:id/stream ────────► │ (SSE log stream)
    │◄── SSE: stdout lines ──────────────┤
    │◄── SSE: end { exitCode: 0 } ──────┤
```

## Phases

### Phase C1: Peer Discovery
**Goal**: Hub instances find each other on the LAN.

1. Add UDP broadcast sender (every 30s on port 8766)
2. Add UDP listener that maintains a peer registry: `{ name, ip, port, version, lastSeen }`
3. Expire peers after 90s of silence
4. Add `GET /api/peers` endpoint — returns known peers
5. Config option: `mesh.enabled: true/false`, `mesh.name: "My-PC"`, `mesh.manualPeers: [...]`
6. Tray menu shows "Mesh: 3 peers" status

**Risk**: Windows Firewall will block UDP 8766 by default — need first-run prompt or docs
**Mitigation**: Fall back to manual peer config. Consider adding firewall rule via `netsh` with user consent.

### Phase C2: Remote Catalog Browsing
**Goal**: See scripts from remote Hubs in your dashboard.

1. UI sidebar shows discovered peers as collapsible sections
2. Clicking a peer fetches their `GET /api/items` (with auth header)
3. Remote scripts visually distinguished (machine badge, dimmed controls)
4. Remote schema fetch — clicking a remote script loads its parameter form
5. Search/filter works across local + remote catalogs
6. Ctrl+K palette includes remote scripts with `@peer-name` prefix

**Risk**: Latency on large catalogs. Network errors need graceful degradation.
**Mitigation**: Cache remote catalogs for 60s. Show "offline" state for unreachable peers.

### Phase C3: Remote Execution
**Goal**: Run scripts on another machine and stream logs back.

1. "Run on [Peer]" button in the script form (only if peer has remote-exec enabled)
2. POST to remote peer's `/api/run` with auth
3. SSE log stream proxied or direct-connected from remote peer
4. Job status (running/completed/failed) reflected in local UI
5. Kill button sends kill to remote peer
6. All remote runs logged in local history with `remote: true` + peer identity

**Risk**: Network interruption mid-run. Remote peer goes offline while job running.
**Mitigation**: Job continues on remote machine regardless. Reconnect SSE on network restore. Status polling fallback.

### Phase C4: Authentication & Permissions
**Goal**: Secure the mesh with per-peer permissions.

1. First-connection pairing: Hub A contacts Hub B → B shows approval prompt with A's name/IP → user approves → shared secret exchanged
2. Subsequent requests include auth token in header
3. Per-peer permission toggles in settings (catalog-read, remote-exec, remote-kill, log-stream)
4. Revoke peer access from settings (removes shared secret)
5. Audit log for all remote actions

**Risk**: Key management complexity. Users may not understand the security implications.
**Mitigation**: Secure defaults (execution OFF). Clear UI language. Audit log always on.

### Phase C5: Mesh Workflows (Advanced)
**Goal**: Workflows that span multiple machines.

1. Workflow steps can target specific peers:
   ```json
   {
     "id": "step-1",
     "peer": "build-server",
     "scriptId": "deploy.ps1",
     "params": { "Branch": "main" }
   }
   ```
2. Parameter piping works across machines (stdout captured and forwarded)
3. Workflow visualization shows which machine runs each step
4. Failure on one machine can trigger recovery on another

**Depends on**: Pipeline Builder (Plan A+B) must be implemented first
**Risk**: Distributed failure modes multiply. Debugging cross-machine workflows is hard.

## Prerequisites

- Pipeline Builder (A+B hybrid) should ship first — mesh workflows depend on it
- Git-backed catalogs provide an alternative sharing mechanism for teams not ready for mesh
- Windows Firewall documentation / automation for UDP + HTTP ports

## Open Questions

1. **mDNS vs raw UDP**: mDNS is more standard but requires Bonjour/Avahi. Raw UDP is simpler but less discoverable.
2. **NAT traversal**: Should mesh work across subnets/VPNs? If yes, need relay or manual config.
3. **Scale ceiling**: Tested with how many peers? 5? 20? 100? Broadcast storms at scale.
4. **Enterprise readiness**: IT teams may want central policy (allowed peers, forced permissions). Worth adding?

## Rough Effort Estimate

| Phase | Effort | Complexity |
|-------|--------|------------|
| C1: Discovery | 3-5 days | Medium (networking, firewall) |
| C2: Remote Catalog | 2-3 days | Low-medium (HTTP proxying) |
| C3: Remote Execution | 3-5 days | Medium (SSE relay, error handling) |
| C4: Auth & Permissions | 5-7 days | High (security-critical) |
| C5: Mesh Workflows | 5-7 days | High (distributed orchestration) |
| **Total** | **~3-5 weeks** | |
