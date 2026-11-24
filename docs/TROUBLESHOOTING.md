# Extension F: Systematic Troubleshooting

During the evaluation the faculty injects **one** fault. You get marks for
the method even if the fix is incomplete, so say each step out loud.

## The method: follow the packet

A request crosses the layers in a fixed order. Test them in that order and
stop at the **first** one that fails. Everything above it fails only *because*
of it.

```
0. Client config  Which DNS server am I asking?      scutil --dns | head
1. IP             Can I reach the machines at all?   ping
2. DNS            Name -> correct IP?                dig @server name ; dscacheutil -q host -a name
3. TCP            Is the port accepting?             nc -vz IP 443
4. TLS            Handshake + trusted cert?          openssl s_client ; curl -v
5. HTTP           Status + which backend?            curl -si https://app.teamX.test
6. Edge->backend  (on Mac 2) can nginx reach them?   ./scripts/backend-ports.sh
```

Automated walk (prints a verdict naming the first broken layer):

```bash
./scripts/diagnose.sh            # on a client
./scripts/diagnose.sh --edge     # on Mac 2, also checks edge -> backends
```

The script is only the start. Confirm the cause with the manual command for
that layer, then fix it and run it again to show everything is green.

## Reading the symptoms

| What curl says | Layer | Means |
|----------------|-------|-------|
| `Could not resolve host` (exit 6) | DNS | no server answered, or NXDOMAIN |
| connects to an **unexpected IP** (`curl -v` shows `Trying x.x.x.x`) | DNS data | wrong record / stale cache |
| `Connection refused` (exit 7) | TCP | host up, nothing listening on that port (RST) |
| `Operation timed out` (exit 28) on connect | TCP/IP | host down, or a firewall **drops** packets |
| `SSL certificate problem` (exit 60) | TLS | cert not trusted on this Mac / expired |
| `no alternative certificate subject name matches` | TLS | cert doesn't contain this hostname (SAN) |
| `wrong version number` / `SSL_ERROR_SYSCALL` | TLS | speaking TLS to a plain-HTTP port, or vice versa |
| `HTTP 502 Bad Gateway` | edge→backend | backends refuse (not running / wrong port in upstream) |
| `HTTP 504 Gateway Timeout` | edge→backend | backends don't answer (host off / firewall drops the edge) |
| `HTTP 404` | app / nginx routing | wrong `server_name`, `location`, or route |
| `HTTP 200` but always the same `X-Backend` | LB | one upstream down/commented out, or weight changed |
| `ping` fails but curl works | ICMP only | Stealth Mode on the target Mac filters ping; the host is up |

`curl -v https://app.teamX.test` prints every stage (resolve → connect →
TLS → request → response) and is often the fastest single command.

## Likely injected faults, with the fix

| # | Fault | What you observe | Confirm with | Fix |
|---|-------|------------------|--------------|-----|
| 1 | Client DNS changed to 8.8.8.8 | `Could not resolve host`; `ping EDGE_IP` works | `scutil --dns \| head`, `dig @8.8.8.8 app.teamX.test` → NXDOMAIN | `./scripts/client-dns.sh set` |
| 2 | dnsmasq stopped on Mac 1 (no backup set) | resolve fails; `dig @MAC1_IP` → `connection refused` | `sudo brew services list` on Mac 1 | `./dns/dns.sh start` |
| 3 | DNS record points to wrong IP | resolves, but TCP refused/timeout or wrong service | `dig app.teamX.test` ≠ `EDGE_IP` | `./dns/dns.sh set app EDGE_IP` on both DNS, flush client |
| 4 | Record changed but client still on old IP | `dig` correct, curl goes elsewhere | `dscacheutil -q host -a name app.teamX.test` vs `dig` | `./scripts/client-dns.sh flush` (or wait TTL) |
| 5 | nginx stopped on Mac 2 | DNS ok, `Connection refused` on 443 | `nc -vz EDGE_IP 443`; `pgrep nginx` on Mac 2 | `sudo nginx` |
| 6 | nginx `listen` port changed (e.g. 4443) | refused on 443 | `sudo lsof -iTCP -sTCP:LISTEN -P \| grep nginx` | fix `listen`, `sudo nginx -t && sudo nginx -s reload` |
| 7 | Cert not trusted / removed from keychain | `SSL certificate problem: self signed` | `security find-certificate -c app.teamX.test` | re-run `security add-trusted-cert` (never `-k`) |
| 8 | Cert for wrong name / expired | `no alternative subject name matches` / `expired` | `openssl s_client -connect EDGE_IP:443 -servername app.teamX.test \| openssl x509 -noout -text` | regenerate cert with correct SAN |
| 9 | One backend stopped | all `X-Backend: B` but 200 OK | `./scripts/lb-test.sh` | start backend |
| 10 | Both backends stopped | 502 (Macs up) / 504 (Macs off) | `curl /edge-health` works, `/` fails | start backends |
| 11 | Wrong upstream IP/port in nginx (e.g. 3003) | **still 200**, but only one `X-Backend` ever answers (nginx retries the bad one on the good one); 502 if both are wrong | `./scripts/diagnose.sh` → verdict LB; on Mac 2 `./scripts/diagnose.sh --edge` → "upstream is missing …"; nginx error log shows `connect() failed` | fix upstream, `sudo nginx -t && sudo nginx -s reload` |
| 12 | Backend bound to 127.0.0.1 | 502; `curl localhost:3001` works on Mac 3 | `lsof -iTCP:3001 -sTCP:LISTEN` shows `127.0.0.1` | bind `0.0.0.0` |
| 13 | pf blocks the edge (edge IP removed from `<edges>`) | 504 after 2 s, `ping` fine | `./firewall/firewall.sh status`; `backend-ports.sh` on Mac 2 → BLOCKED | `./firewall/firewall.sh rollback` or re-add IP |
| 14 | macOS app firewall blocks `node` / `nginx` | timeouts to that port | System Settings → Network → Firewall | allow the app |
| 15 | Machine on a different Wi-Fi / IP changed (DHCP) | `ping` fails | `ipconfig getifaddr en0` vs `team.env` | rejoin / update team.env, re-render, reload |
| 16 | macOS **Stealth Mode** on a Mac | `ping` to it fails, but curl / `nc -z IP 443` work | `/usr/libexec/ApplicationFirewall/socketfilterfw --getstealthmode` on that Mac | not a real fault: say "ICMP is filtered, TCP works". Turn off for the demo: `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode off` |
| 17 | Wi-Fi **client isolation** (campus/guest Wi-Fi) | Macs can't reach *each other* at all (ping and TCP), yet internet works | every Mac can ping the gateway (`route -n get default`) but not the other Macs | the network blocks peer traffic, nothing to fix on the Macs: use a phone hotspot or your own router, then update team.env + re-render |

## Useful commands per layer

```bash
# 0/1
ipconfig getifaddr en0; route -n get default | grep gateway; ping -c3 EDGE_IP
# 2
scutil --dns | head -20
dig app.teamX.test               # through configured resolver (shows SERVER:)
dig @MAC1_IP app.teamX.test      # ask a specific server
dscacheutil -q host -a name app.teamX.test   # what apps see (cached)
# 3
nc -vz EDGE_IP 443
sudo lsof -iTCP -sTCP:LISTEN -P | grep -E 'nginx|node|dnsmasq'
# 4
openssl s_client -connect EDGE_IP:443 -servername app.teamX.test </dev/null | head -20
curl -v https://app.teamX.test 2>&1 | grep -E '^\*|^<'
# 5
curl -si https://app.teamX.test/api/status
curl -s  https://app.teamX.test/edge-health
# edge side (Mac 2)
tail -n 20 "$(brew --prefix)/var/log/nginx/error.log"
tail -n 20 "$(brew --prefix)/var/log/nginx/cn-edge-access.log"
sudo nginx -t
```

## Practice before the evaluation

Take turns: one person injects a fault from the table (without telling the
others), and another diagnoses it out loud using the method above. Record each
round in the "Troubleshooting findings" table in
[`PHASE2_REPORT.md`](PHASE2_REPORT.md).
