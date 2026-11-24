#!/usr/bin/env bash
# Layer-by-layer diagnosis (Extension F). Walks the request path in the
# order the packets do and stops explaining at the first broken layer:
#
#   0. client config   which DNS servers is this Mac really using?
#   1. IP / link       can we reach each team Mac at all?   (ping)
#   2. DNS             does each DNS server answer, with the RIGHT IP?
#   3. TCP             is the edge listening on 80 and 443?
#   4. TLS             handshake ok, cert trusted, name matches, not expired?
#   5. HTTP / app      status code, which backend, 502 = backends down,
#                      and do BOTH backends answer (load balancing)?
#
#   ./scripts/diagnose.sh                 # from a client Mac
#   ./scripts/diagnose.sh --edge          # on Mac 2: also test edge -> backends
#                                         #   and nginx upstream IP:port vs team.env
#   ./scripts/diagnose.sh | tee evidence/phase2/F-diagnosis.txt
set -uo pipefail
source "$(dirname "$0")/lib.sh"

ON_EDGE=0; [[ "${1:-}" == "--edge" ]] && ON_EDGE=1
FIRST_FAIL=""; EDGE_CONF_BAD=0
fail_at() { bad "$2"; [[ -n "$FIRST_FAIL" ]] || FIRST_FAIL="$1"; }

echo "${C_B}Diagnosing https://$APP_HOST  ($(date '+%Y-%m-%d %H:%M:%S') on $(hostname -s))${C_0}"
info "expected: $APP_HOST -> $EDGE_IP (edge), DNS $MAC1_IP + $BACKUP_DNS_IP"

# ---------------------------------------------------------------- 0
hdr "0. Client configuration"
me="$(ipconfig getifaddr "$DNS_IFACE" 2>/dev/null)"
gw="$(route -n get default 2>/dev/null | awk '/gateway/ {print $2}')"
info "this Mac: ${me:-no IP on $DNS_IFACE}   gateway: ${gw:-none}"
# (no mapfile: macOS ships bash 3.2)
ns=( $(scutil --dns 2>/dev/null | awk '/^resolver #1/{f=1} f&&/nameserver\[/{print $3} /^resolver #2/{exit}') )
info "OS resolver #1 nameservers: ${ns[*]:-none}"
if [[ " ${ns[*]:-} " == *" $MAC1_IP "* || " ${ns[*]:-} " == *" $BACKUP_DNS_IP "* ]]; then
  ok "client uses the team DNS"
  [[ " ${ns[*]} " == *" $BACKUP_DNS_IP "* ]] || warn "backup DNS $BACKUP_DNS_IP not configured (./scripts/client-dns.sh set)"
else
  fail_at DNS-CLIENT "client is NOT using team DNS ($MAC1_IP / $BACKUP_DNS_IP) - fix: ./scripts/client-dns.sh set"
fi

# ---------------------------------------------------------------- 1
hdr "1. IP reachability (ping)"
# The client's own path only needs a DNS server and the edge; the
# backends sit behind the edge, so losing one is only a warning here.
# A failed ping is not proof the host is down: macOS Stealth Mode drops
# ICMP echo while TCP still works. For the edge we confirm with TCP 443.
for t in "Mac1-dns $MAC1_IP" "backup-dns $BACKUP_DNS_IP" "edge $EDGE_IP" "backendA $BACKEND_A_IP" "backendB $BACKEND_B_IP"; do
  read -r n ip <<<"$t"
  if ping -c1 -t2 "$ip" >/dev/null 2>&1; then ok "$n $ip reachable"
  elif [[ "$n" == edge ]] && nc -z -G 3 "$ip" 443 >/dev/null 2>&1; then
    warn "$n $ip does not answer ping, but TCP 443 works -> ping is blocked (Stealth Mode on that Mac), host is fine"
  elif [[ "$n" == edge ]]; then
    fail_at IP "$n $ip unreachable by ping AND tcp/443 (Wi-Fi off? asleep? other network? Wi-Fi client isolation?)"
  else warn "$n $ip no ping reply (behind the edge / one of two DNS; or Stealth Mode) - may explain errors below"; fi
done

# ---------------------------------------------------------------- 2
hdr "2. DNS"
for srv in "$MAC1_IP" "$BACKUP_DNS_IP"; do
  r="$(dns_ask "$srv" "$APP_HOST")"
  if [[ -z "$r" ]]; then
    st="$(dig @"$srv" "$APP_HOST" +time=2 +tries=1 2>&1 | grep -oE 'status: [A-Z]+|connection refused|timed out|no servers could be reached' | head -1)"
    warn "server $srv: no answer (${st:-no reply}) - is dnsmasq running there?"
  elif [[ "${r% *}" == "$EDGE_IP" || "${r% *}" == "$STANDBY_EDGE_IP" ]]; then
    ok "server $srv: $APP_HOST -> ${r% *} ($(ip_role "${r% *}"), TTL ${r#* }s)"
  else
    fail_at DNS-RECORD "server $srv: $APP_HOST -> ${r% *} which is NOT an edge (wrong record)"
  fi
done
sys="$(sys_resolve "$APP_HOST")"
if [[ -z "$sys" ]]; then
  fail_at DNS "system resolver cannot resolve $APP_HOST (both DNS down, or client DNS wrong)"
else
  ok "system resolver (what browsers/curl use): $APP_HOST -> $sys ($(ip_role "$sys"))"
  [[ "$sys" == "$EDGE_IP" || "$sys" == "$STANDBY_EDGE_IP" ]] \
    || fail_at DNS-RECORD "system resolver gives $sys - wrong/stale record (flush: ./scripts/client-dns.sh flush)"
fi
TARGET="${sys:-$EDGE_IP}"

# ---------------------------------------------------------------- 3
hdr "3. TCP to the edge ($TARGET)"
TCP443=0
for port in 443 80; do
  if nc -z -G 3 "$TARGET" "$port" >/dev/null 2>&1; then ok "tcp/$port open"; [[ $port == 443 ]] && TCP443=1
  else
    why="$(nc -z -G 3 "$TARGET" "$port" 2>&1 | grep -oE 'refused|timed out' | head -1)"
    fail_at TCP "tcp/$port ${why:-closed}  (refused = nginx not listening on that port; timed out = firewall/host)"
  fi
done

# ---------------------------------------------------------------- 4
hdr "4. TLS"
if (( ! TCP443 )); then
  info "skipped - no TCP connection to 443, so TLS/HTTP cannot even start"
else
pem="$(echo | openssl s_client -connect "$TARGET:443" -servername "$APP_HOST" 2>/dev/null \
        | openssl x509 2>/dev/null)"
if [[ -z "$pem" ]]; then
  fail_at TLS "no TLS handshake on $TARGET:443 (nginx 'listen 443 ssl' / cert files?)"
else
  openssl x509 -noout -subject -issuer -enddate <<<"$pem" | sed 's/^/       /'
  san="$(openssl x509 -noout -text <<<"$pem" | grep -A1 'Subject Alternative Name' | tail -1 | tr -d ' ')"
  info "SAN: ${san:-none}"
  [[ ",$san," == *",DNS:$APP_HOST,"* ]] && ok "certificate SAN contains $APP_HOST" \
    || fail_at TLS "certificate does not list $APP_HOST in SAN (name mismatch)"
  openssl x509 -noout -checkend 0 <<<"$pem" >/dev/null || fail_at TLS "certificate EXPIRED"
fi
verr="$(curl -sS -o /dev/null --max-time 5 "https://$APP_HOST/edge-health" 2>&1)"; rc=$?
case $rc in
  0) ok "curl trusts the certificate (no -k) and /edge-health answered" ;;
  60|51|58|77) fail_at TLS "certificate not trusted on this Mac: $verr" ;;
  *) [[ -z "$FIRST_FAIL" ]] && warn "curl /edge-health exit $rc: $verr" ;;
esac

# ---------------------------------------------------------------- 5
hdr "5. HTTP / application"
out="$(curl -s -D - -o /dev/null --max-time 8 -w 'META %{http_code}\n' "https://$APP_HOST/api/status" 2>/dev/null)"
code="$(awk '/^META/ {print $2}' <<<"$out")"
be="$(awk -F': ' 'tolower($1)=="x-backend" {gsub("\r",""); print $2}' <<<"$out")"
edge="$(awk -F': ' 'tolower($1)=="x-edge" {gsub("\r",""); print $2}' <<<"$out")"
case "$code" in
  200) ok "HTTP 200 from backend ${be:-?} via edge ${edge:-?}"
       # One 200 is not enough: if nginx can only reach one backend, every
       # request still succeeds (it retries on the other). Look at a few.
       seen=""; n=0
       for i in 1 2 3 4 5 6; do
         b="$(curl -s -D - -o /dev/null --max-time 8 "https://$APP_HOST/api/status" 2>/dev/null \
              | awk -F': ' 'tolower($1)=="x-backend" {gsub("\r",""); print $2}')"
         [[ -n "$b" ]] && { n=$((n+1)); seen="$seen $b"; }
       done
       uniq="$(tr ' ' '\n' <<<"$seen" | grep . | sort -u | tr '\n' ' ')"; uniq="${uniq% }"
       info "6 more requests answered by:$seen"
       if [[ "$(wc -w <<<"$uniq" | tr -d ' ')" -ge 2 ]]; then
         ok "load balancing works (backends seen: $uniq)"
       elif (( n > 0 )); then
         fail_at LB "only backend $uniq ever answers - the other upstream is broken (backend stopped, wrong IP:port in nginx upstream, or pf blocks the edge). Check on Mac 2: ./scripts/diagnose.sh --edge"
       fi ;;
  502|504) fail_at APP "HTTP $code from edge ${edge:-?}: edge works, but no backend answered (backends down / wrong upstream IP:port / firewall blocks edge)" ;;
  404) fail_at APP "HTTP 404: request reached a server but wrong location/server_name or backend route" ;;
  000|"") fail_at APP "no HTTP response" ;;
  *) fail_at APP "HTTP $code" ;;
esac
fi  # TCP443

if (( ON_EDGE )); then
  hdr "5b. Edge -> backends (direct, from this edge)"
  "$REPO_ROOT/scripts/backend-ports.sh" | tail -n +2

  hdr "5c. nginx upstream config vs team.env"
  NGINX_CONF="${NGINX_CONF:-$BREW_PREFIX/etc/nginx/nginx.conf}"
  if [[ ! -r "$NGINX_CONF" ]]; then
    warn "cannot read $NGINX_CONF (set NGINX_CONF=/path/to/nginx.conf)"
  else
    # server lines inside the upstream { } block, e.g. 10.0.0.13:3001
    ups="$(awk '/^[[:space:]]*upstream[[:space:]]/ {f=1; next}
                f && /^[[:space:]]*server[[:space:]]/ {sub(/;.*/,""); print $2}
                f && /}/ {f=0}' "$NGINX_CONF")"
    info "upstream servers in $NGINX_CONF: $(echo $ups)"
    for want in "$BACKEND_A_IP:3001" "$BACKEND_B_IP:3002"; do
      if grep -qx "$want" <<<"$ups"; then ok "upstream has $want"
      else EDGE_CONF_BAD=1; fail_at EDGE-CONF "upstream is missing $want (typo in IP or port?) - fix nginx.conf, then: sudo nginx -t && sudo nginx -s reload"; fi
    done
    while read -r u; do
      [[ -z "$u" || "$u" == "$BACKEND_A_IP:3001" || "$u" == "$BACKEND_B_IP:3002" ]] && continue
      EDGE_CONF_BAD=1; fail_at EDGE-CONF "upstream has unexpected entry $u (not in team.env)"
    done <<<"$ups"
    info "(this is the file on disk; if it was edited without a reload, nginx may still run the old version)"
  fi
fi

# ---------------------------------------------------------------- verdict
hdr "Verdict"
case "$FIRST_FAIL" in
  "")         ok "all layers healthy" ;;
  DNS-CLIENT) echo "First broken layer: DNS (client configuration) - the client asks the wrong server." ;;
  IP)         echo "First broken layer: IP/link - fix connectivity before looking higher." ;;
  DNS)        echo "First broken layer: DNS - name cannot be resolved at all." ;;
  DNS-RECORD) echo "First broken layer: DNS data - resolution works but returns the wrong IP." ;;
  TCP)        echo "First broken layer: TCP - host up, but the service port is not accepting connections." ;;
  TLS)        echo "First broken layer: TLS - TCP ok, handshake/certificate problem." ;;
  APP)        echo "First broken layer: application/upstream - DNS, TCP and TLS all fine." ;;
  LB)         echo "Service works, but only through ONE backend - the other upstream is broken (degraded, no redundancy left)." ;;
  EDGE-CONF)  echo "nginx upstream config does not match team.env - wrong backend IP or port on the edge." ;;
esac
if (( EDGE_CONF_BAD )) && [[ "$FIRST_FAIL" != EDGE-CONF ]]; then
  echo "Cause found on this edge (5c): nginx upstream does not match team.env - fix it and reload nginx."
fi
[[ -z "$FIRST_FAIL" ]]
