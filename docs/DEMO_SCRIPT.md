# Phase 2 Evaluation Demo: Commands per Mac

This is the script for evaluation day, in the order you run it. Every command is
marked with the Mac it runs on. For background and the explanations to give,
see [PHASE2.md](PHASE2.md). Allow about 25 minutes, plus the faculty fault (Ext F).

**In every terminal you open, run this first:**

```bash
cd ~/CN_Project && source scripts/demo-env.sh      # use your own clone path
```

It loads `team.env` (so `$EDGE_IP`, `$TEAM`, … work in the commands below),
labels the prompt with the team, the Mac, its IP and the time, so every
screenshot shows where and when it was taken:

```
[team1 | Mac 4 backend B + standby edge | 10.0.0.14] 14:03:22 ~/CN_Project %
```

and adds `snap NAME`: click a window and it is saved as
`evidence/phase2/NAME.png`. The 📸 marks below are good moments for one.
If it warns that this Mac's IP is not in `team.env`, DHCP gave it a new IP: fix
`team.env` on all Macs and re-run `./scripts/render.sh` before going on.

| Mac | Roles | Terminals to keep open |
|-----|-------|------------------------|
| Mac 1 | Primary DNS + cold client | T1: DNS query log · T2: commands |
| Mac 2 | Primary edge nginx | T1: edge access log · T2: commands |
| Mac 3 | Backend A + backup DNS + pf | T1: `node server.js` · T2: commands |
| Mac 4 | Backend B + standby edge + pf + main client | T1: `node server.js` · T2: `watch.sh` · T3: commands |

---

## Step 0: The day before (all Macs)

Do this before the evaluation, not in front of the examiners.

**All 4 Macs:**

```bash
git pull
# put the SAME filled-in team.env on all four Macs (AirDrop it)
./scripts/render.sh
source scripts/demo-env.sh
for ip in $MAC1_IP $EDGE_IP $BACKEND_A_IP $BACKEND_B_IP; do printf "%-15s " $ip; ping -c2 -t3 $ip | grep 'packet loss'; done
```

Every Mac must reach every other Mac with `0.0% packet loss`. If not:

- **one Mac never answers ping**: turn off Stealth Mode on it
  (`sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode off`).
- **no Mac can reach any other**, but the internet works: the Wi-Fi has client
  isolation (common on campus/guest Wi-Fi). Use a phone hotspot or your own
  router, then update the IPs in `team.env`.
- Don't disconnect from Wi-Fi after this: a new DHCP lease can change an IP.

**Mac 1 (primary DNS):**

```bash
./dns/dns.sh install primary
```

`install` also makes dnsmasq forward non-team names (google.com, …) to the
network's own DNS, never to the other team DNS server, so the two can't loop.
The last line of its output must say `forwarding works`.

**Mac 3 (backup DNS):**

```bash
brew install dnsmasq
./dns/dns.sh install backup
```

**Mac 2 (primary edge):**

```bash
cp "$(brew --prefix)/etc/nginx/nginx.conf" "$(brew --prefix)/etc/nginx/nginx.conf.phase1"
cp build/edge-primary/nginx.conf "$(brew --prefix)/etc/nginx/nginx.conf"
sudo nginx -t && sudo nginx -s reload
```

**Mac 4 (standby edge):** copy `$TEAM.crt` and `$TEAM.key` from Mac 2 with
AirDrop or scp (never through git), then:

```bash
brew install nginx
mkdir -p "$(brew --prefix)/etc/nginx/certs"
cp ~/Downloads/$TEAM.crt ~/Downloads/$TEAM.key "$(brew --prefix)/etc/nginx/certs/"
cp build/edge-standby/nginx.conf "$(brew --prefix)/etc/nginx/nginx.conf"
sudo nginx -t && sudo nginx
```

**Mac 1 and Mac 4 (clients):**

```bash
./scripts/client-dns.sh set
```

Rehearse the whole script once, then run the reset at the end.

---

## Step 1: Pre-flight on evaluation day (2 min)

**Mac 3, T1:**

```bash
cd backend-a && node server.js
```

**Mac 4, T1:**

```bash
cd backend-b && node server.js
```

**Mac 1, T1:**

```bash
./dns/dns.sh log
```

**Mac 2, T1:**

```bash
tail -f "$(brew --prefix)/var/log/nginx/cn-edge-access.log"
```

**Mac 4, T3:** everything must be green before you start.

```bash
./scripts/diagnose.sh
curl -s --resolve app.$TEAM.test:443:$STANDBY_EDGE_IP https://app.$TEAM.test/edge-health
snap P2-00_preflight
```

`diagnose.sh` must end with `all layers healthy`, including
`load balancing works (backends seen: A B)`.

The second command must print `"edge":"standby"`, which proves the standby edge
works before any DNS change.

---

## Ext A: Backup DNS (3 min)

**Mac 4, T3:** both DNS servers give the same answer.

```bash
dig @$MAC1_IP app.$TEAM.test +noall +answer
dig @$BACKUP_DNS_IP app.$TEAM.test +noall +answer
./scripts/client-dns.sh show
```

**Mac 4, T2:** start the live view. Leave it running until Ext E.

```bash
./scripts/watch.sh | tee evidence/phase2/A-dns-failover.txt
```

**Mac 1, T2:** kill the primary DNS.

```bash
./dns/dns.sh stop
```

📸 on Mac 4: `snap P2-A_dns_failover` once `dns1` shows `down`. In Mac 4's `watch.sh`, `dns1` shows `down`, `dns2` keeps answering, HTTP stays
`200`. After the cache expires, `LOOKUP` jumps once (failover delay).

**Mac 1, T2:** bring it back.

```bash
./dns/dns.sh start
```

Then contrast this with an application failure: Ctrl+C both `node` servers
(Mac 3 T1 and Mac 4 T1). DNS still resolves, but HTTP returns 502. Restart both
with `node server.js`.

---

## Ext B: TTL and record change (4 min)

**Mac 4, T3:** the second column is the TTL (30).

```bash
dig app.$TEAM.test +noall +answer
```

**Mac 1, T2 and Mac 3, T2:** change the record on both DNS Macs, quickly one
after the other.

```bash
./dns/dns.sh set app $STANDBY_EDGE_IP
```

Watch Mac 4's `watch.sh`. `dns1`/`dns2` show the new IP immediately, while
`CONNECTED` keeps the old IP for up to 30 s, then switches. Point at the
timestamps. 📸 on Mac 4: `snap P2-B_ttl_lag` after it has switched.

**Mac 1, T2 and Mac 3, T2:** change it back.

```bash
./dns/dns.sh set app $EDGE_IP
```

**Mac 4, T3:** flush immediately instead of waiting.

```bash
./scripts/client-dns.sh flush
```

`CONNECTED` switches back on the very next line.

---

## Ext D: Backend failover (4 min)

**Mac 4, T3:** both backends up, so requests alternate A, B, A, B.

```bash
./scripts/lb-test.sh 6 | tee evidence/phase2/D-1-both-up.txt
```

**Mac 3, T1:** press Ctrl+C to stop Backend A.

**Mac 4, T3:** all requests go to B with 0 failed. One line shows `tried: …:3001, …:3002`.

```bash
./scripts/lb-test.sh 8 | tee evidence/phase2/D-2-A-down.txt
```

Point at Mac 2's T1 log, which shows `ustatus="502, 200"`: nginx retried on B.
📸 `snap P2-D_failover` on Mac 4 and `snap P2-D_edge_log` on Mac 2.

**Mac 3, T1:**

```bash
node server.js
```

**Mac 4, T3:** A is back in rotation.

```bash
sleep 6; ./scripts/lb-test.sh 6 | tee evidence/phase2/D-3-A-back.txt
```

Then stop **both** backends (Ctrl+C in Mac 3 T1 and Mac 4 T1).

**Mac 4, T3:**

```bash
curl -si https://app.$TEAM.test | head -1
curl -s https://app.$TEAM.test/edge-health
```

The first command gives 502 and the second still answers. Restart both
backends, then explain the SPOF: Mac 2's nginx is the only remaining single point
of failure, which is what Ext E addresses.

---

## Ext C: Backend isolation with pf (4 min)

**Mac 1, T2:** before the firewall, both backend ports are OPEN (that is the
problem).

```bash
./scripts/backend-ports.sh | tee evidence/phase2/C-before.txt
```

**Mac 3, T2 and Mac 4, T3:** this asks for your password.

```bash
./firewall/firewall.sh apply
```

**Mac 1, T2:** the backends now show BLOCKED, but `ping ok`.

```bash
./scripts/backend-ports.sh | tee evidence/phase2/C-client-blocked.txt
./scripts/lb-test.sh 4
```

The service still works through the edge.

**Mac 2, T2:** the edge is still allowed (OPEN).

```bash
./scripts/backend-ports.sh | tee evidence/phase2/C-edge-allowed.txt
```

**Mac 3, T2:** show the rules, the `<edges>` table and the counters.

```bash
./firewall/firewall.sh status
snap P2-C_rules_mac3
```

Leave the firewall on for Ext E. It shows why the standby edge must be allowed
explicitly.

---

## Ext E: Edge cutover (5 min)

**Mac 3, T2 and Mac 4, T3:** the standby edge needs backend access too.

```bash
./firewall/firewall.sh allow-standby
```

Keep Mac 4's `watch.sh` running (warm client). Keep Mac 2's access log visible.

**Mac 1, T2 and Mac 3, T2:** cut over on both DNS Macs.

```bash
./dns/dns.sh set app $STANDBY_EDGE_IP
```

**Mac 1, T2:** the cold client switches immediately.

```bash
./scripts/client-dns.sh flush
curl -sI https://app.$TEAM.test | grep -i x-edge
```

It prints `X-Edge: standby` straight away. 📸 `snap P2-E_cold_client` on Mac 1,
and later `snap P2-E_warm_client` on Mac 4 once it has switched.

Mac 4's `watch.sh` shows `EDGE primary` for up to 30 s, then `standby`. Mac 2's
log keeps receiving requests during that window, then goes quiet. That means the
old edge has drained.

**Mac 1, T2 and Mac 3, T2:** roll back.

```bash
./dns/dns.sh set app $EDGE_IP
```

Stop `watch.sh` with Ctrl+C.

> If anything in Ext E fails, run `./firewall/firewall.sh rollback` on Mac 3 and
> Mac 4 first. That rules out pf.

---

## Ext F: Faculty-injected fault

The faculty breaks something. On the client that sees the problem (usually
**Mac 4, T3**):

```bash
./scripts/diagnose.sh | tee evidence/phase2/F-diagnosis.txt
```

If the verdict is APP or LB, also run on **Mac 2, T2** (it also compares
nginx's upstream list with `team.env`):

```bash
./scripts/diagnose.sh --edge
```

Talk through the layers in order: client config, IP, DNS, TCP, TLS, then HTTP.
The first failing layer is the cause. Typical fixes:

| Verdict / symptom | Likely fault | Fix (Mac) |
|---|---|---|
| DNS (client config) | client DNS changed | `./scripts/client-dns.sh set` (client) |
| DNS, both servers no answer | dnsmasq stopped | `./dns/dns.sh start` (Mac 1 / Mac 3) |
| DNS data, wrong IP | record edited | `./dns/dns.sh set app $EDGE_IP` (both DNS Macs) + flush on the client |
| IP, edge unreachable | Wi-Fi off / wrong network / Mac asleep | reconnect, check `ipconfig getifaddr en0` |
| TCP 443 refused | nginx stopped | `sudo nginx` (Mac 2) |
| TCP 443 timed out | pf/firewall on the edge | `sudo pfctl -sr`, `sudo pfctl -d` (Mac 2) |
| TLS not trusted / name mismatch | cert removed from Keychain or wrong cert | re-trust the CA/cert (client) or fix `ssl_certificate` (Mac 2) |
| APP 502 | backend `node` stopped | `node server.js` (Mac 3 / Mac 4) |
| APP 504, backends ping ok | pf blocks the edge | `./firewall/firewall.sh rollback` (Mac 3 / Mac 4) |
| LB: only one backend ever answers (still 200) | one backend stopped, **or** wrong upstream IP/port in nginx.conf, or pf blocks the edge | start it; or on Mac 2 `./scripts/diagnose.sh --edge` shows "upstream is missing …": fix nginx.conf, `sudo nginx -t && sudo nginx -s reload` |
| EDGE-CONF (from `--edge`) | nginx upstream doesn't match team.env | fix the IP/port in nginx.conf, reload (Mac 2) |
| IP, but the warning says ping blocked + TCP 443 works | Stealth Mode, not a fault | say so; continue |
| IP, no Mac reaches any other | Wi-Fi client isolation | other network (hotspot), update team.env |

Full list: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## Reset after the demo

**Mac 3 and Mac 4:**

```bash
./firewall/firewall.sh rollback
```

**Mac 1 and Mac 3** (only if a record is still changed):

```bash
./dns/dns.sh set app $EDGE_IP
```

**Mac 4:** stop the standby edge.

```bash
sudo nginx -s quit
```

**Mac 1 and Mac 4:** optional, back to normal DNS.

```bash
./scripts/client-dns.sh reset
```

Before you unplug, collect the `evidence/phase2/*.txt` files and take screenshots.
