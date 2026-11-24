#!/usr/bin/env bash
# Manage the project dnsmasq on a DNS Mac (primary = Mac 1, backup = Ext. A).
#
#   ./dns/dns.sh install primary|backup   install rendered config + restart
#   ./dns/dns.sh show                     what this server answers right now
#   ./dns/dns.sh set app|api <ip>         change a record (Ext. B / E) + restart
#   ./dns/dns.sh stop | start | restart   control the service (Ext. A failover)
#   ./dns/dns.sh log                      follow the query log (evidence)
#
# Run ./scripts/render.sh first. "set" must be run on BOTH DNS Macs -
# otherwise clients that fail over to the backup get the old answer.
set -euo pipefail
source "$(dirname "$0")/../scripts/lib.sh"

CONF_DIR="${CONF_DIR:-$BREW_PREFIX/etc/dnsmasq.d}"
CONF="${CONF:-$CONF_DIR/cn-project.conf}"
MAIN_CONF="${MAIN_CONF:-$BREW_PREFIX/etc/dnsmasq.conf}"
LOG="$BREW_PREFIX/var/log/dnsmasq-cn.log"

svc() { sudo brew services "$1" dnsmasq; }

show() {
  hdr "Records served by this DNS server (127.0.0.1)"
  local n r
  for n in "$APP_HOST" "$API_HOST"; do
    r="$(dns_ask 127.0.0.1 "$n")"
    if [[ -n "$r" ]]; then ok "$n -> ${r% *}  (TTL ${r#* }s, $(ip_role "${r% *}"))"
    else bad "$n -> no answer (is dnsmasq running? ./dns/dns.sh start)"; fi
  done
  [[ -f "$CONF" ]] && { info "config: $CONF"; grep '^host-record=\(app\|api\)\.' "$CONF" | sed 's/^/       /'; }
  # forwarding check: a public name must resolve through this server too
  # (+short prints error text like ";; connection refused" too, so only accept an IP)
  if dig @127.0.0.1 example.com A +short +time=2 +tries=1 2>/dev/null | grep -qE '^[0-9]+(\.[0-9]+){3}$'; then
    ok "forwarding works (example.com resolves via this server)"
  else
    warn "example.com does not resolve via this server - check the server= lines in $CONF"
  fi
  return 0
}

cmd="${1:-}"; shift || true
case "$cmd" in
  install)
    role="${1:-}"
    [[ "$role" == primary || "$role" == backup ]] || { echo "usage: $0 install primary|backup" >&2; exit 2; }
    src="$REPO_ROOT/build/dns-$role/dnsmasq-cn.conf"
    [[ -f "$src" ]] || { echo "error: $src missing - run ./scripts/render.sh" >&2; exit 1; }
    mkdir -p "$CONF_DIR"
    # Phase 1 used address= records in dnsmasq-project2.conf. Two files
    # defining the same name would give inconsistent answers, so park it.
    for old in "$CONF_DIR"/dnsmasq-project2.conf "$CONF_DIR"/*project*.conf; do
      [[ -f "$old" && "$old" != "$CONF" ]] || continue
      mv "$old" "$old.phase1.disabled"; warn "disabled old config $old (kept as .phase1.disabled)"
    done
    cp "$src" "$CONF"; ok "installed $CONF ($role)"
    # Upstream for non-team names (the template has no-resolv). Taken from
    # the DHCP lease, which networksetup -setdnsservers does not change, so
    # it is still the network's real DNS even after client-dns.sh set.
    ups="${UPSTREAM_DNS:-$(ipconfig getoption "$DNS_IFACE" domain_name_server 2>/dev/null || true)}"
    case " $ups " in *" $MAC1_IP "*|*" $BACKUP_DNS_IP "*|*" 127.0.0.1 "*) ups="" ;; esac
    { echo; echo "# Upstream DNS, added by dns.sh install $(date '+%Y-%m-%d %H:%M')"
      for s in $ups 1.1.1.1; do echo "server=$s"; done; } >> "$CONF"
    ok "forwarding other names to: ${ups:+$ups, }1.1.1.1 (fallback)"
    if ! grep -q "^conf-dir=$CONF_DIR" "$MAIN_CONF" 2>/dev/null; then
      echo "conf-dir=$CONF_DIR/,*.conf" >> "$MAIN_CONF"; ok "added conf-dir to $MAIN_CONF"
    fi
    svc restart; sleep 1; show ;;

  set)
    which="${1:-}"; ip="${2:-}"
    [[ "$which" == app || "$which" == api ]] && [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] \
      || { echo "usage: $0 set app|api <ipv4>" >&2; exit 2; }
    [[ -f "$CONF" ]] || { echo "error: $CONF missing - run install first" >&2; exit 1; }
    name="$which.$TEAM.test"
    old="$(grep "^host-record=$name," "$CONF" | cut -d, -f2 || true)"
    [[ -n "$old" ]] || { echo "error: no host-record for $name in $CONF" >&2; exit 1; }
    cp "$CONF" "$CONF.bak"
    sed -i.tmp -E "s|^(host-record=$name),[^,]+,|\1,$ip,|" "$CONF" && rm -f "$CONF.tmp"
    ok "$name: ${old:-?} -> $ip   ($(date '+%H:%M:%S'), TTL ${DNS_TTL}s, previous config in $CONF.bak)"
    if [[ "${NO_RESTART:-0}" != 1 ]]; then svc restart; sleep 1; show; fi
    warn "Remember: run the same 'set' on the other DNS Mac too." ;;

  show)    show ;;
  stop)    svc stop ;;
  start)   svc start; sleep 1; show ;;
  restart) svc restart; sleep 1; show ;;
  log)     echo "following $LOG (Ctrl+C to stop)"; tail -f "$LOG" ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
