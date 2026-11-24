#!/usr/bin/env bash
# Try to reach the backends DIRECTLY, bypassing the edge (Extension C).
# Run it on Mac 2 (should be OPEN) and on Mac 1 (should be BLOCKED).
#
#   ./scripts/backend-ports.sh
#
#   OPEN     TCP connected and the backend answered
#   BLOCKED  no reply at all -> packets dropped by the pf firewall
#   REFUSED  host answered with RST -> reachable, but nothing listening
set -uo pipefail
source "$(dirname "$0")/lib.sh"

me="$(ipconfig getifaddr "$DNS_IFACE" 2>/dev/null || hostname)"
echo "From $me ($(ip_role "$me")):"
for target in "A $BACKEND_A_IP 3001" "B $BACKEND_B_IP 3002"; do
  read -r name ip port <<<"$target"
  # ping first: proves the HOST is reachable even when the PORT is not
  if ping -c1 -t2 "$ip" >/dev/null 2>&1; then p="ping ok"; else p="ping FAIL"; fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 "http://$ip:$port/api/status")"; rc=$?
  case $rc in
    0)  ok   "Backend $name $ip:$port  OPEN (HTTP $code)        [$p]" ;;
    28) bad  "Backend $name $ip:$port  BLOCKED (timeout, dropped) [$p]" ;;
    7)  warn "Backend $name $ip:$port  REFUSED (nothing listening) [$p]" ;;
    *)  bad  "Backend $name $ip:$port  curl exit $rc              [$p]" ;;
  esac
done
