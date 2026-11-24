# Architecture (updated for Phase 2)

## Topology

```
                         private Wi-Fi / LAN  (one subnet, one router)
 ─────────────┬──────────────────┬──────────────────┬──────────────────┬──────────
              │                  │                  │                  │
   ┌──────────┴─────────┐ ┌──────┴─────────────┐ ┌──┴─────────────────┐ ┌┴───────────────────┐
   │ Mac 1              │ │ Mac 2              │ │ Mac 3              │ │ Mac 4              │
   │ PRIMARY DNS        │ │ PRIMARY EDGE       │ │ Backend A :3001    │ │ Backend B :3002    │
   │ dnsmasq udp/53     │ │ nginx tcp/80,443   │ │ BACKUP DNS udp/53  │ │ STANDBY EDGE nginx │
   │ + test client      │ │ TLS termination    │ │ pf: 3001 <- edge   │ │ pf: 3002 <- edge   │
   │                    │ │ round-robin LB     │ │                    │ │ + test client      │
   └────────────────────┘ └────────────────────┘ └────────────────────┘ └────────────────────┘
   Route 53 (primary)      ALB / CDN edge          EC2 instance A          EC2 instance B
                                                   Route 53 (2nd NS)       standby ALB
                                                   security group          security group
```

Phase 2 additions are in CAPITALS on Mac 3 and Mac 4. No new hardware is needed.

## IP / service inventory

Fill in from `team.env` (do not commit real IPs to a public repo; keep the
filled-in copy in the private report/evidence).

| Mac | Hostname | IPv4 / prefix | Gateway | Interface | MAC address | Services (port/proto) |
|-----|----------|---------------|---------|-----------|-------------|-----------------------|
| 1 | dns1.teamX.test | | | en0 | | dnsmasq 53/udp+tcp |
| 2 | edge.teamX.test | | | en0 | | nginx 80/tcp, 443/tcp |
| 3 | dns2.teamX.test | | | en0 | | node 3001/tcp, dnsmasq 53/udp+tcp |
| 4 | standby-edge.teamX.test | | | en0 | | node 3002/tcp, nginx 80/443/tcp (Ext E) |

DNS records (both DNS servers, TTL 30 s):

| Name | Type | Value (normal) | Value (after Ext E cutover) |
|------|------|----------------|-----------------------------|
| app.teamX.test | A | Mac 2 | Mac 4 |
| api.teamX.test | A | Mac 2 | Mac 2 |
| dns1 / dns2 / edge / standby-edge .teamX.test | A | Mac 1 / Mac 3 / Mac 2 / Mac 4 | unchanged |

## Request flow, layer by layer

```
Client (Mac 4)
 │ 1. DNS      UDP  ephemeral → Mac1:53   "A? app.teamX.test"
 │             (if Mac 1 silent/refuses → retry Mac3:53)          ← Ext A
 │             answer: Mac 2 IP, TTL 30 → cached by mDNSResponder  ← Ext B
 │ 2. TCP      SYN / SYN-ACK / ACK   ephemeral → Mac2:443
 │ 3. TLS      ClientHello(SNI=app.teamX.test) → ServerHello, Certificate,
 │             key exchange, Finished; rest is encrypted
 │ 4. HTTP     GET /api/status  (inside TLS)
 ▼
Mac 2 nginx  – decrypts, picks upstream (round-robin, skips failed)  ← Ext D
 │ 5. TCP      new connection Mac2:ephemeral → Mac3:3001 (or Mac4:3002)
 │             pf on Mac 3/4 lets it through only because src = Mac 2  ← Ext C
 │ 6. HTTP     plain HTTP (TLS ended at the edge) + X-Forwarded-For
 ▼
Backend – responds with X-Backend, Cache-Control, ETag
 ▲ nginx adds X-Edge / X-Upstream, re-encrypts, returns to client
```

| Layer (TCP/IP) | OSI | In this project |
|----------------|-----|-----------------|
| Application | 7 | DNS, HTTP/1.1, REST JSON |
| (Presentation/Session) | 6/5 | TLS 1.2/1.3 between client and edge |
| Transport | 4 | UDP 53 (DNS), TCP 443/80 (edge), TCP 3001/3002 (backends) |
| Internet | 3 | IPv4 on the private LAN, pf filters by source IP + dest port |
| Link | 2/1 | Wi-Fi / Ethernet, ARP for LAN neighbours |

## Failure domains after Phase 2

| Component fails | Impact | Mitigation in place |
|-----------------|--------|---------------------|
| Mac 1 dnsmasq | none after resolver timeout | backup DNS on Mac 3 (Ext A) |
| Backend A or B | none (one retry, then skipped 5 s) | passive health check + retry (Ext D) |
| Both backends | 502/504 from edge | none (application tier down) |
| Mac 2 edge | **total outage** until DNS cutover + TTL | manual DNS cutover to standby (Ext E) |
| LAN / router | total outage | none (out of scope) |
