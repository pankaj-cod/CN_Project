# Phase 2 evidence

Save every demo here with `| tee evidence/phase2/<file>`, plus a screenshot
of the terminal. After `source scripts/demo-env.sh`, `snap NAME` saves a window
screenshot straight to `evidence/phase2/NAME.png`, and the prompt shows team,
Mac, IP and time, so each screenshot is self-labelling. The file names match the test table in
[`docs/PHASE2_REPORT.md`](../../docs/PHASE2_REPORT.md), so an evaluator can
find any item within 30 seconds.

> These files contain your real LAN IPs. If the repo is public, either
> keep this folder out of the public push or mask the IPs.

| Ext | File | Command (run on) |
|-----|------|------------------|
| A | `A-dig-both.txt` | `dig @MAC1_IP app.teamX.test; dig @BACKUP_DNS_IP app.teamX.test` (client) |
| A | `A-client-dns.txt` | `./scripts/client-dns.sh show` (client) |
| A | `A-dns-failover.txt` + png | `./scripts/watch.sh` while `./dns/dns.sh stop` on Mac 1 |
| A | `A-app-failure.txt` | `curl -si https://app.teamX.test` with both backends stopped |
| B | `B-ttl-change.txt` + png | `./scripts/watch.sh` while `./dns/dns.sh set app …` on both DNS |
| B | `B-flush.txt` | `./scripts/client-dns.sh flush` + next `watch.sh` lines |
| C | `C-before.txt` | `./scripts/backend-ports.sh` (Mac 1) before pf |
| C | `C-rules.txt` | `./firewall/firewall.sh status` (Mac 3 / Mac 4) |
| C | `C-client-blocked.txt` | `./scripts/backend-ports.sh` (Mac 1) |
| C | `C-edge-allowed.txt` | `./scripts/backend-ports.sh` (Mac 2) |
| C | `C-service-ok.txt` | `./scripts/lb-test.sh 4` (client) |
| C | `C-rollback.txt` | `./firewall/firewall.sh rollback` + `backend-ports.sh` |
| D | `D-1-both-up.txt` | `./scripts/lb-test.sh 6` |
| D | `D-2-A-down.txt` | `./scripts/lb-test.sh 8` after stopping Backend A |
| D | `D-3-A-back.txt` | `./scripts/lb-test.sh 6` after restarting A |
| D | `D-4-both-down.txt` | `curl -si …/` and `curl -s …/edge-health` |
| D | `D-edge-log.txt` | `tail -n 30 $(brew --prefix)/var/log/nginx/cn-edge-access.log` (Mac 2) |
| E | `E-standby-precheck.txt` | `curl -sv --resolve app.teamX.test:443:STANDBY_EDGE_IP https://app.teamX.test/edge-health` |
| E | `E-cutover-warm-client.txt` + png | `./scripts/watch.sh` (Mac 4) during cutover |
| E | `E-cutover-cold-client.txt` | `flush` + `curl -sI …` (Mac 1) |
| E | `E-old-edge-log.txt` | Mac 2 access log during the TTL window |
| F | `F-diagnosis.txt` | `./scripts/diagnose.sh` during the challenge |
| all | `*.pcapng` | optional Wireshark captures (e.g. DNS retry to backup: filter `dns`) |

Nice-to-have Wireshark captures for Phase 2:

- **DNS failover:** filter `dns || icmp`. The query goes to Mac 1, comes back as
  ICMP *port unreachable*, and the same query is retried to Mac 3.
- **pf drop:** filter `tcp.port == 3001`. Repeated SYN retransmissions with
  no SYN-ACK show the packets being dropped (compare with a RST when the backend
  is merely stopped).
- **Failover inside nginx:** capture on Mac 2, filter
  `tcp.port == 3001 || tcp.port == 3002`. You see the SYN → RST to A, then a
  new connection to B for the same client request.
