# Phase 2: Harden, Recover, Troubleshoot (Runbook)

This runbook builds on the Phase 1 network; nothing gets rebuilt. Each extension
lists **what to set up**, **what to run in the demo**, **what you should
see**, and **what to say**. Save the evidence as you go (see
[`evidence/phase2/README.md`](../evidence/phase2/README.md)).

| Ext. | Topic | Where | Marks |
|------|-------|-------|-------|
| A | Backup DNS resolver | Mac 3 runs a 2nd dnsmasq | 15 (A+B+D) |
| B | DNS TTL + controlled record change | Mac 1 + backup DNS, client | |
| C | Backend isolation with pf | Mac 3, Mac 4 | 10 (C+E) |
| D | HA failover between backends | Mac 2 (nginx) | |
| E | DNS-based edge cutover | Mac 4 runs a standby nginx | |
| F | Faculty-injected fault | everyone | 10 |

---

## 0. One-time preparation (every Mac)

```bash
git pull
cp team.env.example team.env      # fill in the real LAN IPs (same file on every Mac)
./scripts/render.sh               # writes build/ with ready configs
```

In every terminal, `source scripts/demo-env.sh` loads `team.env`, labels the
prompt with team / Mac / IP / time (for self-labelling screenshots) and adds
`snap NAME` (saves a window screenshot to `evidence/phase2/NAME.png`).

`team.env` and `build/` are git-ignored because they hold real IPs. Copy the
same `team.env` to every Mac (AirDrop works) so all four agree on the
inventory.

Phase 2 role map (defaults; change `BACKUP_DNS_IP` / `STANDBY_EDGE_IP` to move roles):

| Mac | Phase 1 role | Added in Phase 2 |
|-----|--------------|------------------|
| Mac 1 | Primary DNS + client | TTL 30 s records, query log |
| Mac 2 | Edge nginx | Phase 2 nginx config (X-Edge, X-Upstream, failover tuning) |
| Mac 3 | Backend A :3001 | **Backup DNS** (Ext A), pf isolation (Ext C) |
| Mac 4 | Backend B :3002 + client | **Standby edge nginx** (Ext E), pf isolation (Ext C) |

### Upgrade Mac 1 DNS to the Phase 2 config

```bash
./dns/dns.sh install primary
```

This moves the Phase 1 `dnsmasq-project2.conf` aside (as `*.phase1.disabled`),
installs `cn-project.conf` and restarts dnsmasq. What changed:

- `address=/app.teamX.test/IP` became `host-record=app.teamX.test,IP,30`. dnsmasq
  answers `address=` records with **TTL 0**, so clients never cached them.
  `host-record` lets us set a TTL of 30 s.
- `local=/teamX.test/` makes unknown `*.teamX.test` names return NXDOMAIN
  locally, so they are never leaked upstream.
- `log-queries` writes every query to `$(brew --prefix)/var/log/dnsmasq-cn.log`
  as evidence.
- `no-resolv` + `server=` lines: non-team names are forwarded to the
  network's DHCP DNS (or `UPSTREAM_DNS`), never via `/etc/resolv.conf`. Once a
  DNS Mac is itself pointed at the team DNS, resolv.conf lists Mac 1 and the
  backup, and the two servers would forward to each other in a loop.

### Upgrade Mac 2 nginx to the Phase 2 config

```bash
cp "$(brew --prefix)/etc/nginx/nginx.conf" "$(brew --prefix)/etc/nginx/nginx.conf.phase1"
cp build/edge-primary/nginx.conf "$(brew --prefix)/etc/nginx/nginx.conf"
sudo nginx -t && sudo nginx -s reload
curl -sI https://app.teamX.test | grep -i -E 'x-(edge|backend|upstream)'
```

Expected: `X-Edge: primary`, `X-Backend: A|B`, `X-Upstream: <ip>:<port>`.

---

## Extension A: Backup DNS resolver

### Setup

On **Mac 3** (the backup DNS):

```bash
brew install dnsmasq
./dns/dns.sh install backup
```

It is rendered from the **same template** as the primary, so the records are
identical by construction. It listens on Mac 3's LAN IP.

On every **client Mac** (Mac 1, Mac 4, and any other client):

```bash
./scripts/client-dns.sh set      # DNS = Mac 1 first, backup second; flushes cache
```

Mac 1 itself is a client too. Point it at `127.0.0.1` as well as the backup, or simply
use Mac 4 as the demo client.

### Demo

```bash
# 1. both servers answer the same thing
dig @MAC1_IP app.teamX.test +noall +answer
dig @BACKUP_DNS_IP app.teamX.test +noall +answer

# 2. start the live view on the client (Mac 4)
./scripts/watch.sh | tee evidence/phase2/A-dns-failover.txt

# 3. on Mac 1: kill the primary
./dns/dns.sh stop
```

**Expected in `watch.sh`:** the `dns1` column changes to `down`, `dns2` keeps
answering, and requests keep returning `200`. Once the cached entry expires, the
`LOOKUP` column jumps (for example from `0.00s` to a few seconds) on the first
lookup after the primary died. That delay is the resolver timing out on
Mac 1 and retrying the backup. After that it stays fast.

```bash
# 4. bring it back
./dns/dns.sh start
```

**Contrast with an application failure:** stop *both* backends instead. Now `dig`
works perfectly and so does TCP/TLS to the edge, but HTTP returns `502`.

### What to explain

- **DNS service failure:** the *name → IP* step fails. The client never learns
  where to connect, so no TCP SYN is ever sent (`curl: (6) Could not resolve host`).
  The servers themselves may be perfectly healthy.
- **Application failure:** name resolution works and TCP/TLS to the edge work.
  Only the last hop fails (502/504 from nginx). The error comes *from* the
  edge, which proves the network path is fine.
- If dnsmasq is stopped but Mac 1 is up, Mac 1 replies **ICMP port
  unreachable**, so failover is fast. If Mac 1 is powered off nothing replies,
  so the client waits for its timeout before trying the backup.
- Both servers must hold the same data. During a record change (B/E) you
  must update **both**, or clients get different answers depending on which
  server they asked.

---

## Extension B: DNS TTL and controlled record change

### Setup

Records already carry `TTL 30` (`DNS_TTL` in `team.env`). Check it:

```bash
dig app.teamX.test +noall +answer        # 2nd column = 30
```

### Demo

You need two terminals on the client (Mac 4).

```bash
# Terminal 1: live view
./scripts/watch.sh | tee evidence/phase2/B-ttl-change.txt
```

```bash
# On Mac 1 AND on the backup DNS (Mac 3): point app at the standby edge
./dns/dns.sh set app STANDBY_EDGE_IP
```

**Expected:**

| time after change | `dns1`/`dns2` column (direct query, no cache) | `CONNECTED` column (OS resolver, cached) |
|---|---|---|
| 0 s | new IP immediately | **old IP** (cached) |
| up to 30 s | new IP | still old IP |
| after TTL expires | new IP | **new IP** |

This works because `dig @server` asks the server directly, while curl, browsers
and `dscacheutil` go through macOS's `mDNSResponder`, which caches each answer
for its TTL.

Now show a manual flush: change it back, then flush immediately instead of waiting:

```bash
# on both DNS Macs
./dns/dns.sh set app EDGE_IP
# on the client, immediately:
./scripts/client-dns.sh flush        # dscacheutil -flushcache + killall -HUP mDNSResponder
```

The `CONNECTED` column switches on the very next line.

Useful one-liners for screenshots:

```bash
dscacheutil -q host -a name app.teamX.test   # what the OS (cache) says
dig app.teamX.test +noall +answer           # what the server says, with TTL
```

> Use curl or `watch.sh` for the demo, not a browser. Browsers keep their own
> DNS cache and reuse open keep-alive connections, which hides the effect.

### What to explain

- TTL is the server telling resolvers how long they may reuse an answer. A short
  TTL means changes propagate fast but cause more queries. A long TTL means fewer
  queries but changes propagate slowly.
- In production you **lower the TTL in advance** (e.g. 24 h → 60 s a day
  before a migration), cut over, then raise it again. Until the *old* TTL has
  expired everywhere, some clients still use the old IP, so the old server
  must keep serving during that window.
- A flush only fixes *your* machine. You cannot flush other people's resolvers;
  that is why TTL planning matters.

---

## Extension C: Service isolation (backend firewall)

Goal: only the edge (Mac 2) may connect to TCP 3001/3002. Clients must go
through nginx.

### Before (evidence that the hole exists)

```bash
# on Mac 1 (a client)
./scripts/backend-ports.sh | tee evidence/phase2/C-before.txt   # both OPEN
```

### Apply (on Mac 3 **and** Mac 4)

```bash
./firewall/firewall.sh apply
```

This does three things:

1. **Rollback copy:** saves `/etc/pf.conf` and a snapshot of the live pf rules to
   `~/.cn-project/firewall/`.
2. Loads [`build/backend/pf-backend.rules`](../firewall/pf-backend.rules.template)
   into the pf anchor `com.apple/cn-project`. The stock `/etc/pf.conf`
   already evaluates `com.apple/*` anchors, so the system file is **not edited**.
3. Enables pf with a reference token (`pfctl -E`).

The rules:

```
table <edges> persist { EDGE_IP }
pass  in quick on lo0 all no state
pass  in quick proto tcp from <edges> to any port { 3001 3002 } flags S/SA keep state
block drop in log quick proto tcp from any to any port { 3001 3002 }
```

### Demo

```bash
# Mac 1 (client): direct access is now blocked
./scripts/backend-ports.sh | tee evidence/phase2/C-client-blocked.txt
#   Backend A ... BLOCKED (timeout, dropped)   [ping ok]

# Mac 2 (edge): still allowed
./scripts/backend-ports.sh | tee evidence/phase2/C-edge-allowed.txt
#   Backend A ... OPEN (HTTP 200)

# Any client: the real service still works through the edge
./scripts/lb-test.sh 4
```

`ping ok` + `BLOCKED` together prove that the **host** is reachable and only
the **port** is filtered. Inspect the rules and hit counters with:

```bash
./firewall/firewall.sh status
```

### Rollback (mandatory after the demo)

```bash
./firewall/firewall.sh rollback        # on Mac 3 and Mac 4
./scripts/backend-ports.sh             # from Mac 1: OPEN again
```

`rollback` flushes the anchor, releases the pf token (pf goes back to its
earlier on/off state), and diffs the pf rules against the saved snapshot.

### What to explain

- **drop vs reject:** `block drop` sends nothing back, so the client waits until
  it times out. `block return` would send a TCP RST, which shows up as an immediate
  "connection refused", the same thing you see when nothing is listening. Drop
  hides the service; that difference is also a diagnosis clue (timeout =
  filtered, refused = closed).
- This is the local version of a cloud **security group**: backends sit in a
  private subnet and accept traffic only from the load balancer's group.
- The rule matches on the **source IP**, which is why the standby edge (Ext E)
  has to be added to `<edges>`.

---

## Extension D: High-availability failover

### How nginx detects a dead backend

Open-source nginx has no active health probes, so we use **passive** checks
([`nginx-phase2.conf.template`](../nginx/nginx-phase2.conf.template)):

```nginx
upstream backend_servers {
    server BACKEND_A_IP:3001 max_fails=1 fail_timeout=5s;
    server BACKEND_B_IP:3002 max_fails=1 fail_timeout=5s;
}
...
proxy_next_upstream         error timeout http_502 http_503 http_504;
proxy_next_upstream_tries   2;
proxy_connect_timeout       2s;
```

1. A real request goes to A, and the connect fails (RST, or no answer within 2 s).
2. nginx **retries the same request on B**, so the client still gets a 200.
3. A is marked unavailable for `fail_timeout` (5 s) and all traffic goes to B.
4. After 5 s nginx tries A again with one live request. If A answers, round-robin resumes.

### Demo

```bash
# client
./scripts/lb-test.sh 6 | tee evidence/phase2/D-1-both-up.txt        # A,B,A,B...

# Mac 3: stop Backend A (Ctrl+C in its terminal)

./scripts/lb-test.sh 8 | tee evidence/phase2/D-2-A-down.txt         # all B, 0 failed
#   one line shows  tried: MAC3:3001, MAC4:3002   <- the retry, visible

# Mac 3: start it again
node server.js
sleep 6
./scripts/lb-test.sh 6 | tee evidence/phase2/D-3-A-back.txt         # A and B again
```

Edge-side proof (Mac 2): every request's upstream attempts are logged.

```bash
tail -f "$(brew --prefix)/var/log/nginx/cn-edge-access.log"
# ... status=200 upstream="10.x.x.13:3001, 10.x.x.14:3002" ustatus="502, 200"
```

Then stop **both** backends:

```bash
curl -si https://app.teamX.test | head -1           # 502 Bad Gateway (504 if the Macs are off)
curl -s  https://app.teamX.test/edge-health         # {"edge":"primary","status":"ok"}
```

That shows exactly where the edge ends and the backends begin: DNS, TCP and TLS are fine, and nginx
answers by itself, but it has no upstream to send the request to.

- **502**: the backend refused the connection (Mac up, `node` not running).
- **504**: no answer at all within the timeout (Mac off / packets dropped).

### Single point of failure

With backups for DNS (Ext A) and backends (Ext D), the remaining SPOF is
**the edge nginx on Mac 2**. It is the only IP that `app.teamX.test` resolves to.
If Mac 2 dies, every request fails even though both backends are healthy.

How to eliminate it:

| Approach | How | Failover time |
|----------|-----|---------------|
| DNS-based (what Ext E does by hand) | 2 edges, change the record when one dies; Route 53 health-checked failover records automate it | TTL + detection |
| Floating virtual IP | 2 edges run VRRP/keepalived (CARP on BSD); the standby takes over the same IP | ~1-3 s, clients don't notice |
| Multiple A records | DNS returns both edge IPs; clients retry the other | depends on client |
| Managed LB (AWS ALB / GCP LB) | the provider runs the edge redundantly across zones | handled by provider |

Remaining shared dependencies: the single Wi-Fi/LAN and router, and the TLS
private key, which must be copied to every edge.

---

## Extension E: Controlled edge migration (DNS cutover)

Move `app.teamX.test` from the Mac 2 edge to a standby nginx on Mac 4 without
breaking clients.

### Setup the standby edge (Mac 4)

```bash
brew install nginx
mkdir -p "$(brew --prefix)/etc/nginx/certs"
# copy teamX.crt AND teamX.key from Mac 2 (AirDrop/scp, never via git)
cp build/edge-standby/nginx.conf "$(brew --prefix)/etc/nginx/nginx.conf"
sudo nginx -t && sudo nginx
```

The config is rendered from the same template as Mac 2. The upstreams, TLS
and timeouts are identical; only `X-Edge: standby` differs. The same certificate
works because it is issued for the **name**, not the IP.

If the firewall from Ext C is active, let the standby edge reach the
backends (on Mac 3 and Mac 4):

```bash
./firewall/firewall.sh allow-standby
```

Test the standby **before** cutting over, without touching DNS:

```bash
curl -s --resolve app.teamX.test:443:STANDBY_EDGE_IP https://app.teamX.test/edge-health
# {"edge":"standby","status":"ok"}
```

(`--resolve` pins the name to an IP for this one request. TLS still
validates against the name, so no `-k` is needed.)

### Cutover demo

Use two clients: Mac 4 "warm" (it has just resolved the name) and Mac 1 "cold"
(flush first).

```bash
# Mac 4 (warm client)
./scripts/watch.sh | tee evidence/phase2/E-cutover-warm-client.txt

# Mac 2: watch the old edge's log
tail -f "$(brew --prefix)/var/log/nginx/cn-edge-access.log"

# Mac 1 and Mac 3 (both DNS servers)
./dns/dns.sh set app STANDBY_EDGE_IP

# Mac 1 (cold client)
./scripts/client-dns.sh flush
curl -sI https://app.teamX.test | grep -i x-edge        # X-Edge: standby  (immediately)
```

**Expected:**

- Cold lookups get the new record and land on `X-Edge: standby` right away.
- The warm client keeps showing `X-Edge: primary` until its cached answer
  expires (≤ 30 s), then switches to `standby`.
- Mac 2's access log keeps receiving requests during that window, then goes quiet.
  That is the cue that the old edge has drained and can be shut down
  (`sudo nginx -s quit` drains open connections gracefully).

### Rollback

```bash
./dns/dns.sh set app EDGE_IP     # on both DNS Macs
```

### What to explain

- The client never knew the edge's IP; it only knew the name. That is why the
  edge can be moved with a DNS change alone.
- During the TTL window **both edges must serve**. Shutting the old edge down
  first would break cached clients for up to one TTL.
- DNS cutover is coarse: it moves *new lookups*, not existing TCP connections.
  Long-lived keep-alive connections stay on the old edge until they close.

---

## Extension F: Faculty-injected troubleshooting challenge

See [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md). In short: run

```bash
./scripts/diagnose.sh | tee evidence/phase2/F-diagnosis.txt
```

and talk through the layers **in order**: client config → IP → DNS → TCP
→ TLS → HTTP. The first layer that fails is where you look; every layer
above it is just collateral damage.

---

## Reset everything after the demo

```bash
./firewall/firewall.sh rollback                     # Mac 3, Mac 4
./dns/dns.sh set app EDGE_IP                        # Mac 1 + backup DNS (if changed)
./scripts/client-dns.sh reset                       # clients, back to DHCP DNS
sudo nginx -s quit                                  # Mac 4 standby edge
```
