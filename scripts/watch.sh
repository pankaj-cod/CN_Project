#!/usr/bin/env bash
# Live view of one request per second from a client Mac. Use it during
# DNS failover (A), TTL change (B), backend failover (D) and edge
# cutover (E): every line shows what DNS says *now* versus where the
# client actually connected, plus which edge and backend answered.
#
#   ./scripts/watch.sh                 # https://app.<team>.test/api/status
#   ./scripts/watch.sh /               # another path
#   INTERVAL=2 ./scripts/watch.sh      # slower
#   ./scripts/watch.sh | tee evidence/phase2/E-cutover.txt
#
# Columns
#   dns1 / dns2   answer + TTL straight from each DNS server (no cache)
#   lookup        time the OS resolver needed (jumps when it fails over)
#   connected     IP curl actually used = OS resolver incl. its cache
#   edge/backend  X-Edge and X-Backend response headers
set -uo pipefail
source "$(dirname "$0")/lib.sh"

PATH_PART="${1:-/api/status}"
URL="https://$APP_HOST$PATH_PART"
INTERVAL="${INTERVAL:-1}"

curl_err() {
  case "$1" in
    6)  echo "NO-DNS (could not resolve)";;
    7)  echo "TCP-REFUSED (nothing listening)";;
    28) echo "TIMEOUT";;
    35|56) echo "TLS-ERROR";;
    51|58|60|77) echo "CERT-ERROR (untrusted/mismatch)";;
    *)  echo "curl-exit-$1";;
  esac
}

fmt_dns() { [[ -n "$1" ]] && echo "${1% *}/${1#* }s" || echo "down"; }

echo "Watching $URL every ${INTERVAL}s  (Ctrl+C to stop)"
printf '%-8s  %-20s %-20s  %-7s %-26s  %-5s %-8s %s\n' TIME "dns1 $MAC1_IP" "dns2 $BACKUP_DNS_IP" LOOKUP CONNECTED HTTP EDGE BACKEND
while true; do
  d1="$(fmt_dns "$(dns_ask "$MAC1_IP" "$APP_HOST")")"
  d2="$(fmt_dns "$(dns_ask "$BACKUP_DNS_IP" "$APP_HOST")")"
  out="$(curl -s -o /dev/null -D - --max-time 10 -w 'META %{http_code} %{time_namelookup} %{remote_ip}\n' "$URL" 2>/dev/null)"; rc=$?
  code="$(awk '/^META/ {print $2}' <<<"$out")"
  dnst="$(awk '/^META/ {printf "%.2fs", $3}' <<<"$out")"
  ip="$(awk '/^META/ {print $4}' <<<"$out")"
  edge="$(awk -F': ' 'tolower($1)=="x-edge" {gsub("\r",""); print $2}' <<<"$out")"
  be="$(awk -F': ' 'tolower($1)=="x-backend" {gsub("\r",""); print $2}' <<<"$out")"
  if (( rc != 0 )); then
    printf '%-8s  %-20s %-20s  %-7s %-26s  %s\n' "$(date +%H:%M:%S)" "$d1" "$d2" "${dnst:--}" "${ip:--}" "${C_BAD}$(curl_err $rc)${C_0}"
  else
    printf '%-8s  %-20s %-20s  %-7s %-26s  %-5s %-8s %s\n' "$(date +%H:%M:%S)" "$d1" "$d2" "$dnst" \
      "$ip($(ip_role "$ip"))" "$code" "${edge:--}" "${be:--}"
  fi
  sleep "$INTERVAL"
done
