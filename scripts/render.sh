#!/usr/bin/env bash
# Render every Phase 2 config from team.env into build/.
#
#   ./scripts/render.sh
#
# Output (git-ignored, contains real IPs):
#   build/dns-primary/dnsmasq-cn.conf   -> Mac 1
#   build/dns-backup/dnsmasq-cn.conf    -> backup DNS Mac (default Mac 3)
#   build/edge-primary/nginx.conf       -> Mac 2
#   build/edge-standby/nginx.conf       -> standby edge Mac (default Mac 4)
#   build/backend/pf-backend.rules      -> Mac 3 and Mac 4
set -euo pipefail
source "$(dirname "$0")/lib.sh"

OUT="$REPO_ROOT/build"
mkdir -p "$OUT"/{dns-primary,dns-backup,edge-primary,edge-standby,backend}

if [[ "$BACKUP_DNS_IP" == "$MAC1_IP" ]]; then
  echo "error: BACKUP_DNS_IP must be a different Mac than MAC1_IP" >&2; exit 1
fi
if [[ "$STANDBY_EDGE_IP" == "$EDGE_IP" ]]; then
  echo "error: STANDBY_EDGE_IP must be a different Mac than EDGE_IP" >&2; exit 1
fi

# render <template> <output> KEY=VALUE...
render() {
  local tpl="$1" out="$2"; shift 2
  local args=(
    -e "s|@TEAM@|$TEAM|g"
    -e "s|@MAC1_IP@|$MAC1_IP|g"
    -e "s|@EDGE_IP@|$EDGE_IP|g"
    -e "s|@BACKEND_A_IP@|$BACKEND_A_IP|g"
    -e "s|@BACKEND_B_IP@|$BACKEND_B_IP|g"
    -e "s|@BACKUP_DNS_IP@|$BACKUP_DNS_IP|g"
    -e "s|@STANDBY_EDGE_IP@|$STANDBY_EDGE_IP|g"
    -e "s|@DNS_TTL@|$DNS_TTL|g"
    -e "s|@DNS_IFACE@|$DNS_IFACE|g"
    -e "s|@BREW_PREFIX@|$BREW_PREFIX|g"
  )
  local kv
  for kv in "$@"; do args+=(-e "s|@${kv%%=*}@|${kv#*=}|g"); done
  sed "${args[@]}" "$tpl" > "$out"
  if grep -n '@[A-Z_]*@' "$out"; then
    echo "error: unreplaced placeholder in $out" >&2; exit 1
  fi
  echo "  wrote ${out#"$REPO_ROOT"/}"
}

echo "Rendering configs for $APP_HOST"
render "$REPO_ROOT/dns/dnsmasq.conf.template" "$OUT/dns-primary/dnsmasq-cn.conf" \
  ROLE=PRIMARY ROLE_LC=primary LISTEN_IP="$MAC1_IP"
render "$REPO_ROOT/dns/dnsmasq.conf.template" "$OUT/dns-backup/dnsmasq-cn.conf" \
  ROLE=BACKUP ROLE_LC=backup LISTEN_IP="$BACKUP_DNS_IP"
render "$REPO_ROOT/nginx/nginx-phase2.conf.template" "$OUT/edge-primary/nginx.conf" \
  EDGE_NAME=primary
render "$REPO_ROOT/nginx/nginx-phase2.conf.template" "$OUT/edge-standby/nginx.conf" \
  EDGE_NAME=standby
render "$REPO_ROOT/firewall/pf-backend.rules.template" "$OUT/backend/pf-backend.rules"

cat <<EOF

Inventory
  Mac 1  primary DNS ........ $MAC1_IP
  Mac 2  primary edge ....... $EDGE_IP
  Mac 3  backend A :3001 .... $BACKEND_A_IP
  Mac 4  backend B :3002 .... $BACKEND_B_IP
  backup DNS ................ $BACKUP_DNS_IP ($(ip_role "$BACKUP_DNS_IP"))
  standby edge .............. $STANDBY_EDGE_IP
  record TTL ................ ${DNS_TTL}s
EOF
