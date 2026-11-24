# Demo terminal setup - SOURCE it (zsh or bash), do not run it:
#
#   source scripts/demo-env.sh        # from the repo folder, in every new terminal
#
# What you get:
#   - cd to the repo and the team.env variables ($EDGE_IP, $TEAM, ...) so
#     the commands in docs/DEMO_SCRIPT.md paste as they are
#   - a prompt that labels every screenshot with team, Mac, IP and time:
#       [team1 | Mac 4 backend B | 10.0.0.14] 14:03:22 ~/CN_Project %
#   - snap NAME   screenshot of one window -> evidence/phase2/NAME.png
#                 (click the Terminal window; first use asks for Screen
#                 Recording permission for Terminal - allow, reopen Terminal)
#   - '# comments' in pasted commands work in zsh too

if [ -n "${ZSH_VERSION:-}" ]; then
  eval '_cn_src="${(%):-%x}"'
  setopt interactivecomments
else
  _cn_src="${BASH_SOURCE[0]}"
fi
CN_ROOT="$(cd "$(dirname "$_cn_src")/.." && pwd)"
unset _cn_src

if [ ! -f "$CN_ROOT/team.env" ]; then
  echo "demo-env: $CN_ROOT/team.env missing - cp team.env.example team.env and fill in the IPs" >&2
  return 1 2>/dev/null || exit 1
fi
set -a; . "$CN_ROOT/team.env"; set +a
cd "$CN_ROOT" || return 1
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"

CN_IP="$(ipconfig getifaddr "${DNS_IFACE:-en0}" 2>/dev/null)"
case "$CN_IP" in
  "$MAC1_IP")      CN_MAC="Mac 1 DNS" ;;
  "$EDGE_IP")      CN_MAC="Mac 2 edge" ;;
  "$BACKEND_A_IP") CN_MAC="Mac 3 backend A" ;;
  "$BACKEND_B_IP") CN_MAC="Mac 4 backend B" ;;
  "")              CN_MAC="no IP on ${DNS_IFACE:-en0}" ;;
  *)               CN_MAC="not in team.env" ;;
esac
[ "$CN_IP" = "${BACKUP_DNS_IP:-}" ]   && CN_MAC="$CN_MAC + backup DNS"
[ "$CN_IP" = "${STANDBY_EDGE_IP:-}" ] && CN_MAC="$CN_MAC + standby edge"

if [ -n "${ZSH_VERSION:-}" ]; then
  PROMPT="%F{cyan}[$TEAM | $CN_MAC | ${CN_IP:-?}]%f %F{yellow}%*%f %~ %# "
else
  PS1="\[\e[36m\][$TEAM | $CN_MAC | ${CN_IP:-?}]\[\e[0m\] \[\e[33m\]\t\[\e[0m\] \w \$ "
fi

snap() {
  if [ -z "${1:-}" ]; then echo "usage: snap NAME   (saves evidence/phase2/NAME.png)"; return 2; fi
  mkdir -p "$CN_ROOT/evidence/phase2"
  echo "click the window to capture (Esc to cancel)"
  screencapture -iW "$CN_ROOT/evidence/phase2/$1.png" \
    && [ -f "$CN_ROOT/evidence/phase2/$1.png" ] \
    && echo "saved evidence/phase2/$1.png"
}

echo "demo env loaded: $TEAM, this is $CN_MAC (${CN_IP:-no IP}); snap NAME saves a screenshot"
if [ "$CN_MAC" = "not in team.env" ]; then
  echo "WARNING: this Mac's IP $CN_IP is not in team.env - DHCP gave a new IP? fix team.env and re-run ./scripts/render.sh" >&2
fi
