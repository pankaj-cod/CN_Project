#!/usr/bin/env bash
# Send N requests through the edge and show who served each one
# (Extension D: before / during / after stopping Backend A).
#
#   ./scripts/lb-test.sh        # 10 requests
#   ./scripts/lb-test.sh 20
set -uo pipefail
source "$(dirname "$0")/lib.sh"

N="${1:-10}"
URL="https://$API_HOST/api/status"
declare -i a=0 b=0 fail=0

echo "GET $URL  x$N"
for ((i = 1; i <= N; i++)); do
  hdrs="$(curl -s -o /dev/null -D - --max-time 6 -w 'META %{http_code} %{time_total}\n' "$URL")"; rc=$?
  code="$(awk '/^META/ {print $2}' <<<"$hdrs")"; t="$(awk '/^META/ {print $3}' <<<"$hdrs")"
  be="$(awk -F': ' 'tolower($1)=="x-backend" {gsub("\r",""); print $2}' <<<"$hdrs")"
  up="$(awk -F': ' 'tolower($1)=="x-upstream" {gsub("\r",""); print $2}' <<<"$hdrs")"
  edge="$(awk -F': ' 'tolower($1)=="x-edge" {gsub("\r",""); print $2}' <<<"$hdrs")"
  printf '%2d  HTTP %-3s  X-Backend: %-2s X-Edge: %-8s %5.2fs  tried: %s\n' \
    "$i" "${code:-ERR}" "${be:--}" "${edge:--}" "${t:-0}" "${up:-curl exit $rc}"
  case "$be" in A) a+=1;; B) b+=1;; *) fail+=1;; esac
done
echo "----"
echo "Backend A: $a   Backend B: $b   failed: $fail"
