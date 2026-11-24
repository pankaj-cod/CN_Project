# Shared helpers - sourced by the other scripts, not run directly.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/team.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found." >&2
  echo "       cp team.env.example team.env  and fill in your LAN IPs." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${TEAM:?TEAM missing in team.env}"
: "${MAC1_IP:?}" "${EDGE_IP:?}" "${BACKEND_A_IP:?}" "${BACKEND_B_IP:?}"
BACKUP_DNS_IP="${BACKUP_DNS_IP:-$BACKEND_A_IP}"
STANDBY_EDGE_IP="${STANDBY_EDGE_IP:-$BACKEND_B_IP}"
DNS_TTL="${DNS_TTL:-30}"
DNS_IFACE="${DNS_IFACE:-en0}"
NET_SERVICE="${NET_SERVICE:-Wi-Fi}"
UPSTREAM_DNS="${UPSTREAM_DNS:-}"

APP_HOST="app.$TEAM.test"
API_HOST="api.$TEAM.test"

BREW_PREFIX="${BREW_PREFIX:-$(brew --prefix 2>/dev/null || echo /opt/homebrew)}"

if [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_BAD=$'\e[31m'; C_WARN=$'\e[33m'; C_DIM=$'\e[2m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  C_OK=""; C_BAD=""; C_WARN=""; C_DIM=""; C_B=""; C_0=""
fi

ok()   { echo "${C_OK}[ OK ]${C_0} $*"; }
bad()  { echo "${C_BAD}[FAIL]${C_0} $*"; }
warn() { echo "${C_WARN}[WARN]${C_0} $*"; }
info() { echo "${C_DIM}       $*${C_0}"; }
hdr()  { echo; echo "${C_B}== $* ==${C_0}"; }

# Name -> IP the way applications see it (system resolver + its cache).
# Works on macOS (dscacheutil); falls back to getent/dig elsewhere.
sys_resolve() {
  local name="$1"
  if command -v dscacheutil >/dev/null 2>&1; then
    dscacheutil -q host -a name "$name" 2>/dev/null | awk '/^ip_address:/ {print $2; exit}' || true
  elif command -v getent >/dev/null 2>&1; then
    getent ahostsv4 "$name" 2>/dev/null | awk '{print $1; exit}' || true
  else
    dig +short "$name" 2>/dev/null | head -1 || true
  fi
}

# Ask one specific DNS server; prints "IP TTL" or nothing.
# (helpers always return 0 so callers using set -e/pipefail don't abort)
dns_ask() {
  local server="$1" name="$2"
  dig @"$server" "$name" A +noall +answer +time=2 +tries=1 2>/dev/null \
    | awk '$4=="A" {print $5, $2; exit}' || true
}

# Which Mac is this IP?
ip_role() {
  case "$1" in
    "$EDGE_IP")         echo "Mac2-edge" ;;
    "$STANDBY_EDGE_IP") echo "standby-edge" ;;
    "$MAC1_IP")         echo "Mac1" ;;
    "$BACKEND_A_IP")    echo "Mac3" ;;
    "$BACKEND_B_IP")    echo "Mac4" ;;
    "")                 echo "-" ;;
    *)                  echo "UNKNOWN" ;;
  esac
}
