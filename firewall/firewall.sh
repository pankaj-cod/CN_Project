#!/usr/bin/env bash
# Backend isolation with macOS pf (Extension C). Run on Mac 3 and Mac 4.
#
#   ./firewall/firewall.sh apply           save rollback copy, load rules, enable pf
#   ./firewall/firewall.sh status          show loaded rules, <edges> table, counters
#   ./firewall/firewall.sh allow-standby   also allow the standby edge (Ext. E)
#   ./firewall/firewall.sh rollback        remove our rules, restore original state
#
# Our rules live in the anchor "com.apple/cn-project". The stock
# /etc/pf.conf already evaluates every com.apple/* anchor, so the system
# file is never modified - rollback = flush the anchor + release pf.
set -euo pipefail
source "$(dirname "$0")/../scripts/lib.sh"

ANCHOR="com.apple/cn-project"
RULES="$REPO_ROOT/build/backend/pf-backend.rules"
STATE="$HOME/.cn-project/firewall"
mkdir -p "$STATE"

snapshot() {  # full pf state, for the rollback copy and the before/after diff
  { echo "# pf snapshot $(date)"
    echo "## main ruleset"; sudo pfctl -s rules 2>/dev/null || true
    echo "## anchor $ANCHOR"; sudo pfctl -a "$ANCHOR" -s rules 2>/dev/null || true; } > "$1"
}

case "${1:-}" in
  apply)
    [[ -f "$RULES" ]] || { echo "error: $RULES missing - run ./scripts/render.sh" >&2; exit 1; }
    ts="$(date +%Y%m%d-%H%M%S)"
    # Rollback copy: the system pf.conf and the live ruleset before we touch anything.
    sudo cp /etc/pf.conf "$STATE/pf.conf.original.$ts"
    snapshot "$STATE/before.$ts.txt"; ln -sf "before.$ts.txt" "$STATE/before.latest.txt"
    ok "rollback copy saved in $STATE (pf.conf.original.$ts, before.$ts.txt)"

    # The main ruleset must contain the com.apple/* anchor hook. On a Mac
    # where pf was never used it may be empty - load the stock pf.conf.
    if ! sudo pfctl -s rules 2>/dev/null | grep -q 'anchor "com.apple/\*"'; then
      sudo pfctl -q -f /etc/pf.conf; info "loaded stock /etc/pf.conf (provides the com.apple/* hook)"
    fi
    sudo pfctl -q -a "$ANCHOR" -f "$RULES"
    ok "rules loaded into anchor $ANCHOR"

    # -E enables pf and returns a reference token; releasing that token on
    # rollback leaves pf exactly as enabled/disabled as it was before.
    tok="$(sudo pfctl -E 2>&1 | awk '/Token/ {print $NF}')"
    [[ -n "$tok" ]] && echo "$tok" > "$STATE/token"
    ok "pf enabled (token ${tok:-?})"
    "$0" status ;;

  status)
    hdr "pf"; sudo pfctl -s info 2>/dev/null | head -1
    hdr "Rules in $ANCHOR"; sudo pfctl -a "$ANCHOR" -v -s rules 2>/dev/null || true
    hdr "<edges> table (allowed to reach 3001/3002)"; sudo pfctl -a "$ANCHOR" -t edges -T show 2>/dev/null || echo "  (not loaded)" ;;

  allow-standby)
    sudo pfctl -a "$ANCHOR" -t edges -T add "$STANDBY_EDGE_IP"
    ok "standby edge $STANDBY_EDGE_IP may now reach the backends"
    sudo pfctl -a "$ANCHOR" -t edges -T show ;;

  rollback)
    sudo pfctl -a "$ANCHOR" -F all 2>/dev/null || true
    ok "flushed anchor $ANCHOR"
    if [[ -f "$STATE/token" ]]; then
      sudo pfctl -X "$(cat "$STATE/token")" 2>/dev/null || true; rm -f "$STATE/token"
      ok "released our pf enable token (pf returns to its previous on/off state)"
    fi
    if cmp -s /etc/pf.conf "$(ls -t "$STATE"/pf.conf.original.* 2>/dev/null | head -1)"; then
      ok "/etc/pf.conf unchanged from the saved original"
    fi
    snapshot "$STATE/after-rollback.txt"
    if diff <(sed 1d "$STATE/before.latest.txt") <(sed 1d "$STATE/after-rollback.txt") >/dev/null; then
      ok "pf state matches the pre-demo snapshot"
    else
      warn "pf state differs from pre-demo snapshot:"; diff <(sed 1d "$STATE/before.latest.txt") <(sed 1d "$STATE/after-rollback.txt") || true
    fi ;;

  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
