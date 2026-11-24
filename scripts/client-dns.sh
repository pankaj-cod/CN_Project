#!/usr/bin/env bash
# Point a client Mac at the team DNS servers (Extension A).
#
#   ./scripts/client-dns.sh set      primary (Mac 1) first, backup second
#   ./scripts/client-dns.sh primary  only Mac 1 (Phase 1 behaviour)
#   ./scripts/client-dns.sh show     what the OS is actually using
#   ./scripts/client-dns.sh flush    empty the macOS DNS cache (Ext. B)
#   ./scripts/client-dns.sh reset    back to DHCP-provided DNS
set -euo pipefail
source "$(dirname "$0")/lib.sh"

flush() {
  sudo dscacheutil -flushcache
  sudo killall -HUP mDNSResponder
  ok "macOS DNS cache flushed ($(date '+%H:%M:%S'))"
}

show() {
  hdr "networksetup DNS for '$NET_SERVICE'"
  networksetup -getdnsservers "$NET_SERVICE" | sed 's/^/  /'
  hdr "Resolver #1 as seen by the OS (scutil --dns)"
  scutil --dns | awk '/^resolver #1/{f=1} f&&/nameserver|search|timeout/{print "  "$0} /^resolver #2/{exit}'
  hdr "$APP_HOST via system resolver"
  echo "  $(sys_resolve "$APP_HOST")"
}

case "${1:-}" in
  set)     sudo networksetup -setdnsservers "$NET_SERVICE" "$MAC1_IP" "$BACKUP_DNS_IP"
           ok "DNS servers: $MAC1_IP (primary, Mac 1), $BACKUP_DNS_IP (backup)"; flush; show ;;
  primary) sudo networksetup -setdnsservers "$NET_SERVICE" "$MAC1_IP"
           ok "DNS servers: $MAC1_IP only"; flush; show ;;
  show)    show ;;
  flush)   flush ;;
  reset)   sudo networksetup -setdnsservers "$NET_SERVICE" empty; ok "DNS back to DHCP default"; flush ;;
  *) sed -n '2,9p' "$0"; exit 2 ;;
esac
