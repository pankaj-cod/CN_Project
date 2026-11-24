# Phase 2 Final Report: Harden, Recover, Troubleshoot

**Team:** Harshit Kudhial (2401010182) · Om Chimurkar (2401010306) ·
Pankaj Upadhyay (2401010317) · Prakhar Rawat (2401020045)

**Domain:** `app.teamX.test` / `api.teamX.test`  ·  **Review date:** _____

> Sections marked **TODO** must be filled in with what you actually observed
> on your Macs during the Phase 2 run. Keep the raw output in
> `evidence/phase2/` and reference the file names here.

---

## 1. What changed from Phase 1

| Area | Phase 1 | Phase 2 | Why |
|------|---------|---------|-----|
| DNS servers | dnsmasq on Mac 1 only | + identical dnsmasq on Mac 3; clients list both | removes DNS single point of failure (Ext A) |
| DNS records | `address=` (TTL 0) | `host-record=…,30` from one shared template | visible, controllable caching (Ext B); identical data on both servers |
| DNS scope | — | `local=/teamX.test/`, query log | private zone never leaks upstream; evidence |
| nginx | round-robin, `max_fails=1 fail_timeout=5s` | + `proxy_next_upstream_tries 2`, `proxy_read_timeout`, `X-Edge`, `X-Upstream`, upstream access log, `/edge-health` | observable failover (Ext D) and cutover (Ext E) |
| Backends | reachable from any LAN host | TCP 3001/3002 accepted only from the edge (pf anchor) | service isolation (Ext C) |
| Edge | Mac 2 only | standby nginx on Mac 4 (same template) | DNS-based migration (Ext E) |
| Config management | IPs edited by hand in each file | one `team.env` → `scripts/render.sh` → `build/` | one source of truth for IPs; no copy/paste drift between primary and backup |
| Tooling | curl/dig by hand | `watch.sh`, `lb-test.sh`, `backend-ports.sh`, `diagnose.sh` | repeatable demos and evidence |

## 2. Resilience tests and results

**TODO**: fill the *Observed* column and the evidence file for each row.

| # | Test | Expected | Observed | Evidence |
|---|------|----------|----------|----------|
| A1 | `dig` both DNS servers | same answer, TTL 30 | | `A-dig-both.txt` |
| A2 | Stop dnsmasq on Mac 1 while `watch.sh` runs | lookups continue via Mac 3; one slower lookup | | `A-dns-failover.txt` |
| A3 | Stop both backends (contrast) | DNS OK, HTTP 502 | | `A-app-failure.txt` |
| B1 | Change `app` record, watch client | `dig` new at once; client old IP for ≤ 30 s | switched after ___ s | `B-ttl-change.txt` |
| B2 | Change back + flush | client switches immediately | | `B-flush.txt` |
| C1 | Client → backend ports, before pf | OPEN | | `C-before.txt` |
| C2 | Client → backend ports, pf on | BLOCKED (timeout), ping OK | | `C-client-blocked.txt` |
| C3 | Edge → backend ports, pf on | OPEN | | `C-edge-allowed.txt` |
| C4 | Service through edge, pf on | 200, A and B | | `C-service-ok.txt` |
| C5 | Rollback | ports OPEN, pf state = snapshot | | `C-rollback.txt` |
| D1 | Both backends up | A/B alternate | | `D-1-both-up.txt` |
| D2 | Backend A stopped | 100 % B, 0 failures, one retry visible | | `D-2-A-down.txt` |
| D3 | Backend A restarted | A/B again within ~5 s | | `D-3-A-back.txt` |
| D4 | Both stopped | 502 + `/edge-health` OK | | `D-4-both-down.txt` |
| E1 | Standby edge via `--resolve` | `X-Edge: standby`, cert valid | | `E-standby-precheck.txt` |
| E2 | Cutover, cold client | standby immediately | | `E-cutover-cold-client.txt` |
| E3 | Cutover, warm client | primary until TTL, then standby | switched after ___ s | `E-cutover-warm-client.txt` |
| E4 | Old edge access log | requests stop after TTL | | `E-old-edge-log.txt` |

## 3. Troubleshooting findings (Extension F)

**TODO**: one row per practice round and the faculty's fault.

| Round | Fault injected (by) | Symptom seen | First failing layer | Commands that proved it | Fix | Time |
|-------|---------------------|--------------|---------------------|-------------------------|-----|------|
| practice 1 | | | | | | |
| practice 2 | | | | | | |
| **faculty** | | | | | | |

What we learned about diagnosing: **TODO** (2-3 sentences, e.g. which
symptom was misleading and how the layer order caught it).

## 4. Single point of failure analysis

After Phase 2 the DNS tier (two servers) and the backend tier (two
instances + passive health check) both survive the loss of one machine. The
remaining single point of failure is **the edge nginx on Mac 2**. It is the
only address `app.teamX.test` resolves to, so losing it is a total outage
even though both backends are healthy. Extension E shows the manual cure,
moving the name to a standby edge. It is slow (detection by a human + up to
one TTL) and it needs both edges to run during the switch. Eliminating the
SPOF properly needs either a **floating virtual IP** shared by two edges
(VRRP/keepalived, ~1-3 s failover, invisible to clients), **health-checked DNS
failover** (Route 53 failover routing), or a managed, multi-zone load
balancer such as AWS ALB. The LAN/router and the single TLS private key
(copied to both edges) remain shared dependencies.

## 5. Learning summary (one paragraph per extension)

**A: Backup DNS.** Name resolution is a separate service from the
application, so it can fail on its own. When we stopped dnsmasq on Mac 1, clients
whose resolver list also contained Mac 3 kept resolving, and only the first
lookup after the failure was slower while the OS timed out on Mac 1. Stopping
the backends instead produced the opposite picture: DNS was perfect but HTTP
returned 502. That distinction ("could not resolve host" vs an error *from*
the edge) is the quickest way to tell which tier is broken. Redundant DNS
servers are only useful if their data is identical, which is why both are
generated from one template.

**B: TTL and record change.** A DNS answer is a lease, not a fact: the
TTL tells every resolver how long it may keep reusing the answer. After
changing the record, `dig @server` showed the new IP at once, while curl,
which goes through macOS's caching resolver, kept connecting to the old
IP until the 30 s TTL ran out. Flushing the cache made the switch instant, but
only on our own Mac. In production you cannot flush other people's resolvers,
so operators lower the TTL well before a migration, keep the old endpoint
serving for at least one old TTL, and raise the TTL again afterwards.

**C: Service isolation.** Moving the backends behind the edge is only
complete when they are *unreachable* any other way. A pf anchor that accepts
TCP 3001/3002 from the edge's IP and silently drops everything else did this
without touching `/etc/pf.conf`. From Mac 1, `ping` to the backend still worked
but the port timed out, which separated host reachability (layer 3) from
service reachability (layer 4). We chose `drop` over `reject` so the service
is not even revealed to exist. Keeping a snapshot and an anchor-only rollback
made the change safe to undo. This is the local equivalent of a cloud
security group that only admits the load balancer.

**D: HA failover.** nginx's passive health check uses real traffic as
the probe: the first request to a dead backend fails to connect, nginx
retries it on the other backend (the client still gets 200), and the dead one
is skipped for `fail_timeout`. The `X-Upstream` header and the access log
made the retry visible (`upstream="A, B" status="502, 200"`). After Backend A
restarted, round-robin resumed within one `fail_timeout`. We also learned the
difference between 502 (backend refused, so its Mac is up) and 504 (no answer,
so the Mac is off or a firewall is dropping), and that the edge itself is now our
single point of failure.

**E: DNS-based edge cutover.** Because clients only know a name, the
edge can be replaced by changing one record. The standby was configured from
the same template and certificate. The cert is bound to the name, not the
IP, so no client saw a TLS warning. During the cutover, cold clients went
straight to the standby while warm clients stayed on the old edge until their
cached answer expired, and the old edge's access log went quiet after about
one TTL. That was our signal it was safe to stop it. DNS cutover moves new
lookups, not existing connections, so it is a migration tool rather than
instant failover.

**F: Troubleshooting.** **TODO** (fill in after the evaluation: the fault,
how the layered method found it, what you'd check first next time).
