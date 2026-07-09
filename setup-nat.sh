#!/usr/bin/env bash
###############################################################################
# setup-nat.sh — Production-grade Interactive NAT Gateway Manager
# Version: 4.0
#
# INTERACTIVE (default):  sudo bash setup-nat.sh
# NON-INTERACTIVE:        sudo bash setup-nat.sh --install [OPTIONS]
#
# OPTIONS:
#   --install            Install NAT (skip menu)
#   --uninstall          Uninstall NAT (skip menu)
#   --status             Show status (skip menu)
#   --dry-run            Simulate; no changes made
#   --iface IFACE        Override outbound interface
#   --cidrs CIDR[,...]   Override subnet CIDRs (comma-separated)
#   --verbose            Debug output
#   -h|--help            Show help
#
# ENV OVERRIDES:
#   NAT_IFACE=eth0
#   NAT_CIDRS="10.0.0.0/16,192.168.1.0/24"
###############################################################################
set -euo pipefail
IFS=$'\n\t'

# ─── Version & Paths ─────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="4.0"
readonly RULE_TAG="setup-nat"
readonly SYSCTL_CONF="/etc/sysctl.d/99-nat-gateway.conf"
readonly LOCK_FILE="/var/run/setup-nat.lock"
readonly BACKUP_DIR="/var/lib/setup-nat/backups"
readonly CLIENT_SCRIPT_PATH="/tmp/client-setup.sh"

# ─── Runtime state ────────────────────────────────────────────────────────────
DRY_RUN=false
UNINSTALL=false
INSTALL=false
STATUS_ONLY=false
VERBOSE=false
NAT_IFACE="${NAT_IFACE:-}"
NAT_CIDRS="${NAT_CIDRS:-}"
IS_EC2=false
IMDS_TOKEN=""
_TMPDIR=""
_LOCK_FD=""
_ROLLBACK_NEEDED=false
_BACKUP_FILE=""
_CONNTRACK_MODULE=""
_CONNTRACK_ARGS=()

# ─── Colors & Terminal ────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  CR=$'\033[0;31m'   CG=$'\033[0;32m'   CY=$'\033[1;33m'
  CM=$'\033[0;35m'   CC=$'\033[0;36m'   CDIM=$'\033[2m'
  CBOLD=$'\033[1m'   CN=$'\033[0m'
else
  CR='' CG='' CY='' CM='' CC='' CDIM='' CBOLD='' CN=''
fi
# Compat aliases for existing log functions
_R="$CR" _G="$CG" _Y="$CY" _C="$CC" _B="$CBOLD" _N="$CN"

_COLS=$(tput cols 2>/dev/null || echo 72)
[[ $_COLS -lt 64 ]] && _COLS=64
[[ $_COLS -gt 80 ]] && _COLS=80

# ─── Logging ──────────────────────────────────────────────────────────────────
_ts()    { date '+%Y-%m-%dT%H:%M:%S'; }
log()    { printf '%s %sINFO %s[%s] %s\n' "$(_ts)" "$CG" "$CN" "$RULE_TAG" "$*"; }
warn()   { printf '%s %sWARN %s[%s] %s\n' "$(_ts)" "$CY" "$CN" "$RULE_TAG" "$*" >&2; }
err()    { printf '%s %sERROR%s[%s] %s\n' "$(_ts)" "$CR" "$CN" "$RULE_TAG" "$*" >&2; }
debug()  { $VERBOSE && printf '%s %sDEBUG%s[%s] %s\n' "$(_ts)" "$CC" "$CN" "$RULE_TAG" "$*" >&2 || true; }
section(){ printf '\n%s %s━━━ %s ━━━%s\n' "$(_ts)" "$CBOLD" "$*" "$CN"; }
die()    { err "$*"; exit 1; }

# ═══════════════════════════════════════════════════════════════════════════════
# UI HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

# Strip ANSI escape codes from a string (for length calculation)
_strip_ansi() { printf '%s' "$*" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g'; }

_box_top() {
  printf '%s╔' "$CBOLD"
  printf '═%.0s' $(seq 1 $((_COLS - 2)))
  printf '╗%s\n' "$CN"
}
_box_bot() {
  printf '%s╚' "$CBOLD"
  printf '═%.0s' $(seq 1 $((_COLS - 2)))
  printf '╝%s\n' "$CN"
}
_box_div() {
  printf '%s╠' "$CBOLD"
  printf '═%.0s' $(seq 1 $((_COLS - 2)))
  printf '╣%s\n' "$CN"
}
_box_line() {
  local text="${1:-}"
  local inner=$((_COLS - 4))
  local plain; plain=$(_strip_ansi "$text")
  local pad=$(( inner - ${#plain} ))
  [[ $pad -lt 0 ]] && pad=0
  printf '%s║%s %s%*s %s║%s\n' "$CBOLD" "$CN" "$text" "$pad" '' "$CBOLD" "$CN"
}
_box_empty() { _box_line ''; }

# Print the top banner with system info
print_banner() {
  local host os_name
  host=$(hostname -s 2>/dev/null || echo 'unknown')
  os_name=$(grep -m1 PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'unknown')
  echo
  _box_top
  _box_line "  ${CC}${CBOLD}NAT GATEWAY MANAGER  v${SCRIPT_VERSION}${CN}"
  _box_line "  ${CDIM}Production-grade Linux NAT Setup${CN}"
  _box_div
  _box_line "  ${CBOLD}Host :${CN} ${host}"
  _box_line "  ${CBOLD}OS   :${CN} ${os_name}"
  _box_line "  ${CBOLD}User :${CN} $(whoami)"
  _box_bot
  echo
}

# Print main interactive menu
print_main_menu() {
  _box_top
  _box_line "  ${CBOLD}Select an option:${CN}"
  _box_div
  _box_line "  ${CG}[1]${CN}  Install / Reconfigure NAT Gateway"
  _box_line "  ${CR}[2]${CN}  Uninstall NAT Gateway"
  _box_line "  ${CC}[3]${CN}  Show Current Status"
  _box_line "  ${CY}[4]${CN}  Show Client Setup Commands"
  _box_line "  ${CDIM}[5]  Exit${CN}"
  _box_bot
}

# Prompt for a numbered choice; echo the choice on stdout.
# Uses /dev/tty for all I/O so it works correctly inside $() subshells.
prompt_choice() {
  local lo="${1:-1}" hi="${2:-5}" choice
  while true; do
    printf '\n%sEnter choice [%d-%d]: %s' "$CBOLD" "$lo" "$hi" "$CN" > /dev/tty
    read -r choice < /dev/tty 2>/dev/null || { printf '\n' > /dev/tty; echo '0'; return; }
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= lo && choice <= hi )); then
      echo "$choice"; return
    fi
    printf '%s  Invalid — enter a number between %d and %d.%s\n' "$CR" "$lo" "$hi" "$CN" > /dev/tty
  done
}

# y/N confirmation; returns 0 for yes, 1 for no.
# Uses /dev/tty so it works when called from within $() subshells.
confirm() {
  local msg="${1:-Continue?}" answer
  printf '\n%s%s [y/N]: %s' "$CY" "$msg" "$CN" > /dev/tty
  read -r answer < /dev/tty 2>/dev/null || { printf '\n' > /dev/tty; return 1; }
  [[ "${answer,,}" == 'y' || "${answer,,}" == 'yes' ]]
}

press_enter() {
  printf '\n%s[ Press any key to continue ]%s' "$CDIM" "$CN" > /dev/tty
  read -r -s -n 1 _ < /dev/tty 2>/dev/null || true
  printf '\n' > /dev/tty
}

# ═══════════════════════════════════════════════════════════════════════════════
# CLIPBOARD — OSC 52 (works over SSH in most modern terminals)
# ═══════════════════════════════════════════════════════════════════════════════
copy_to_clipboard() {
  local text="$1" encoded
  encoded=$(printf '%s' "$text" | base64 | tr -d '\n')
  if [[ -c /dev/tty ]]; then
    printf '\033]52;c;%s\007' "$encoded" > /dev/tty
    return 0
  fi
  return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# CLIENT SCRIPT GENERATOR
# ═══════════════════════════════════════════════════════════════════════════════
# shellcheck disable=SC2016  # single quotes intentional: generating shell script text, not expanding
generate_client_script() {
  # Outputs a complete, runnable bash script for private servers
  local gw="$1" iid="${2:-}"
  printf '#!/usr/bin/env bash\n'
  printf '# NAT Gateway client setup — generated by setup-nat.sh v%s\n' "$SCRIPT_VERSION"
  printf '# Run on each private server:  sudo bash /tmp/client-setup.sh\n'
  printf '#\n'
  printf '# What this does:\n'
  printf '#   1. Adds a default route through the NAT Gateway immediately\n'
  printf '#   2. Installs a systemd service so the route survives reboots\n'
  printf '#   3. Verifies internet connectivity\n'
  printf 'set -euo pipefail\n\n'
  printf 'NAT_GW="%s"\n\n' "$gw"
  printf '[[ $EUID -ne 0 ]] && { echo "Run with sudo"; exit 1; }\n\n'
  printf 'echo ""\n'
  printf 'echo "================================================="\n'
  printf 'echo "  NAT Gateway Client Setup"\n'
  printf 'echo "  Gateway: $NAT_GW"\n'
  printf 'echo "================================================="\n'
  printf 'echo ""\n\n'
  printf '# ── Step 1: Apply route now ──────────────────────────────────\n'
  printf 'echo "[1/3] Applying default route via $NAT_GW..."\n'
  printf 'ip route replace default via "$NAT_GW"\n'
  printf 'echo "      OK — route active"\n\n'
  printf '# ── Step 2: Persist via systemd service ─────────────────────\n'
  printf 'echo "[2/3] Installing systemd persistence service..."\n'
  printf 'cat > /etc/systemd/system/nat-route.service << SVCEOF\n'
  printf '[Unit]\n'
  printf 'Description=Default route via NAT Gateway (%s)\n' "$gw"
  printf 'After=network-online.target\n'
  printf 'Wants=network-online.target\n\n'
  printf '[Service]\n'
  printf 'Type=oneshot\n'
  printf 'ExecStart=/sbin/ip route replace default via %s\n' "$gw"
  printf 'RemainAfterExit=yes\n\n'
  printf '[Install]\n'
  printf 'WantedBy=multi-user.target\n'
  printf 'SVCEOF\n\n'
  printf 'systemctl daemon-reload\n'
  printf 'systemctl enable --now nat-route.service\n'
  printf 'echo "      OK — service enabled (persists across reboots)"\n\n'
  printf '# ── Step 3: Verify connectivity ──────────────────────────────\n'
  printf 'echo "[3/3] Verifying internet connectivity..."\n'
  printf 'PUBLIC_IP=$(curl -sf --max-time 5 https://checkip.amazonaws.com 2>/dev/null || echo "unavailable")\n'
  printf 'echo "      Your public IP : $PUBLIC_IP"\n'
  printf 'echo "      (Should match NAT Gateway public IP)"\n'
  printf 'if ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then\n'
  printf '  echo "      Internet      : OK"\n'
  printf 'else\n'
  printf '  echo "      Internet      : FAILED — check route table / NAT instance"\n'
  printf 'fi\n\n'
  printf 'echo ""\n'
  printf 'echo "================================================="\n'
  printf 'echo "  Client setup complete!"\n'
  printf 'echo "  Default route  : $(ip route show default)"\n'
  printf 'echo "  Service status : $(systemctl is-active nat-route.service)"\n'
  printf 'echo "================================================="\n'
  printf 'echo ""\n'
  if [[ -n "$iid" ]]; then
    printf '# AWS NOTE: Also update your private subnet route table:\n'
    printf '#   aws ec2 create-route \\\n'
    printf '#     --route-table-id <RTB-ID> \\\n'
    printf '#     --destination-cidr-block 0.0.0.0/0 \\\n'
    printf '#     --instance-id %s\n' "$iid"
  fi
}

# Display the client setup menu and handle user choice
show_client_menu() {
  local nat_gw="${1:-<NAT-PRIVATE-IP>}" instance_id="${2:-}"

  while true; do
    echo
    _box_top
    _box_line "  ${CBOLD}PRIVATE SERVER SETUP${CN}  —  run on each private server"
    _box_div
    _box_line "  ${CBOLD}NAT Gateway IP:${CN}  ${CG}${nat_gw}${CN}"
    _box_div
    _box_line "  ${CG}[1]${CN}  Copy commands to clipboard  ${CDIM}(OSC52 — works over SSH)${CN}"
    _box_line "  ${CC}[2]${CN}  Save to ${CLIENT_SCRIPT_PATH}"
    _box_line "  ${CY}[3]${CN}  View commands on screen"
    if $IS_EC2; then
      _box_line "  ${CM}[4]${CN}  Show AWS route table instructions"
      _box_line "  ${CDIM}[5]  Back to main menu${CN}"
      _box_bot
      local choice; choice=$(prompt_choice 1 5)
    else
      _box_line "  ${CDIM}[4]  Back to main menu${CN}"
      _box_bot
      local choice; choice=$(prompt_choice 1 4)
    fi

    local script_content
    script_content=$(generate_client_script "$nat_gw" "$instance_id")

    case "$choice" in
      1)
        if copy_to_clipboard "$script_content"; then
          printf '\n%s✓ Copied to clipboard!%s  Paste and run on each private server.\n' "$CG" "$CN"
        else
          printf '\n%s✗ Clipboard unavailable.%s  Use Save or View instead.\n' "$CY" "$CN"
        fi
        press_enter
        ;;
      2)
        printf '%s' "$script_content" > "$CLIENT_SCRIPT_PATH"
        chmod 755 "$CLIENT_SCRIPT_PATH"
        printf '\n%s✓ Saved to %s%s\n' "$CG" "$CLIENT_SCRIPT_PATH" "$CN"
        printf '  Transfer to private servers:\n'
        printf '  %sscp %s <server>:/tmp/client-setup.sh%s\n' "$CDIM" "$CLIENT_SCRIPT_PATH" "$CN"
        printf '  %sssh <server> sudo bash /tmp/client-setup.sh%s\n\n' "$CDIM" "$CN"
        press_enter
        ;;
      3)
        echo
        _box_top
        _box_line "  ${CBOLD}Commands to run on each private server:${CN}"
        _box_bot
        printf '\n%s────── BEGIN SCRIPT ──────────────────────────────────────────────────%s\n' "$CDIM" "$CN"
        printf '%s\n' "$script_content"
        printf '%s────── END SCRIPT ────────────────────────────────────────────────────%s\n\n' "$CDIM" "$CN"
        press_enter
        ;;
      4)
        if $IS_EC2; then
          _show_aws_instructions "$nat_gw" "$instance_id"
          press_enter
        else
          return
        fi
        ;;
      5) return ;;
    esac
  done
}

_show_aws_instructions() {
  local nat_gw="$1" iid="${2:-<INSTANCE-ID>}"
  echo
  _box_top
  _box_line "  ${CBOLD}${CM}AWS ROUTE TABLE SETUP${CN}  —  run from your workstation"
  _box_div
  _box_line "  ${CBOLD}Step 1${CN}  Disable Source/Destination Check on this instance:"
  _box_empty
  _box_line "    ${CDIM}aws ec2 modify-instance-attribute \\${CN}"
  _box_line "      ${CDIM}--instance-id ${iid} --no-source-dest-check${CN}"
  _box_div
  _box_line "  ${CBOLD}Step 2${CN}  Add a route in the private subnet's route table:"
  _box_empty
  _box_line "    ${CDIM}# Find route table: AWS Console → VPC → Route Tables${CN}"
  _box_empty
  _box_line "    ${CDIM}aws ec2 create-route \\${CN}"
  _box_line "      ${CDIM}--route-table-id <PRIVATE-RTB-ID> \\${CN}"
  _box_line "      ${CDIM}--destination-cidr-block 0.0.0.0/0 \\${CN}"
  _box_line "      ${CDIM}--instance-id ${iid}${CN}"
  _box_div
  _box_line "  ${CG}After Step 2:${CN} private servers route via NAT automatically."
  _box_line "  ${CDIM}No commands needed on private servers for AWS routing.${CN}"
  _box_bot
}

# ═══════════════════════════════════════════════════════════════════════════════
# POST-INSTALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════
run_post_install_tests() {
  local iface="$1"; shift
  local -a cidrs=("$@")
  local passed=0 failed=0 total=6

  section "Post-install verification"
  echo
  _box_top
  _box_line "  ${CBOLD}Running ${total} verification checks...${CN}"
  _box_div

  # Test 1: IP forwarding
  local fwd; fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '0')
  if [[ "$fwd" == '1' ]]; then
    _box_line "  ${CG}✓${CN}  IP forwarding enabled          ${CDIM}(net.ipv4.ip_forward = 1)${CN}"
    passed=$(( passed + 1 ))
  else
    _box_line "  ${CR}✗${CN}  IP forwarding NOT enabled      ${CR}(= ${fwd})${CN}"
    failed=$(( failed + 1 ))
  fi

  # Test 2: MASQUERADE rule
  if iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "/\* ${RULE_TAG} \*/"; then
    _box_line "  ${CG}✓${CN}  MASQUERADE rule active         ${CDIM}(${iface})${CN}"
    passed=$(( passed + 1 ))
  else
    _box_line "  ${CR}✗${CN}  MASQUERADE rule NOT found      ${CR}(iptables nat POSTROUTING)${CN}"
    failed=$(( failed + 1 ))
  fi

  # Test 3: FORWARD rules
  local fwd_count; fwd_count=$(iptables -L FORWARD -n 2>/dev/null | grep -c "/\* ${RULE_TAG} \*/" || echo 0)
  if [[ "$fwd_count" -gt 0 ]]; then
    _box_line "  ${CG}✓${CN}  FORWARD rules in place         ${CDIM}(${fwd_count} tagged rules)${CN}"
    passed=$(( passed + 1 ))
  else
    _box_line "  ${CR}✗${CN}  FORWARD rules NOT found        ${CR}(iptables FORWARD)${CN}"
    failed=$(( failed + 1 ))
  fi

  # Test 4: Persistence file
  local pfile=''
  [[ -f /etc/iptables/rules.v4        ]] && pfile='/etc/iptables/rules.v4'
  [[ -f /etc/sysconfig/iptables       ]] && pfile='/etc/sysconfig/iptables'
  [[ -f /etc/iptables/iptables.rules  ]] && pfile='/etc/iptables/iptables.rules'
  if [[ -n "$pfile" && -f "$SYSCTL_CONF" ]]; then
    _box_line "  ${CG}✓${CN}  Rules persisted to disk        ${CDIM}(${pfile})${CN}"
    passed=$(( passed + 1 ))
  else
    _box_line "  ${CY}⚠${CN}  Persistence file not found     ${CY}(reboot may lose rules)${CN}"
    failed=$(( failed + 1 ))
  fi

  # Test 5: Internet connectivity
  if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
    _box_line "  ${CG}✓${CN}  Internet reachable             ${CDIM}(ping 8.8.8.8)${CN}"
    passed=$(( passed + 1 ))
  else
    _box_line "  ${CY}⚠${CN}  Internet unreachable           ${CY}(ping 8.8.8.8 failed)${CN}"
    failed=$(( failed + 1 ))
  fi

  # Test 6: DNS resolution
  if getent hosts google.com >/dev/null 2>&1 || \
     host google.com >/dev/null 2>&1 || \
     nslookup google.com >/dev/null 2>&1; then
    _box_line "  ${CG}✓${CN}  DNS resolving                  ${CDIM}(google.com)${CN}"
    passed=$(( passed + 1 ))
  else
    _box_line "  ${CY}⚠${CN}  DNS resolution failed          ${CY}(check /etc/resolv.conf)${CN}"
    failed=$(( failed + 1 ))
  fi

  _box_div
  if [[ $failed -eq 0 ]]; then
    _box_line "  ${CG}${CBOLD}All ${total}/${total} tests passed — NAT Gateway is ready!${CN}"
  else
    _box_line "  ${CY}${CBOLD}${passed}/${total} passed${CN}  ${CR}${failed} warning(s)${CN} — check items above"
  fi
  _box_bot
  echo
  return $failed
}

# ═══════════════════════════════════════════════════════════════════════════════
# LOCK / TEMP / ROLLBACK
# ═══════════════════════════════════════════════════════════════════════════════
setup_tmpdir() {
  _TMPDIR="$(mktemp -d /tmp/.nat-setup-XXXXXX)"
  chmod 700 "$_TMPDIR"
  debug "Temp dir: $_TMPDIR"
}
cleanup_tmpdir() {
  [[ -n "$_TMPDIR" && -d "$_TMPDIR" ]] && rm -rf "$_TMPDIR" || true
}
acquire_lock() {
  $DRY_RUN && { debug "Skipping lock in dry-run"; return; }
  exec {_LOCK_FD}>"$LOCK_FILE" || die "Cannot create lock file: $LOCK_FILE"
  flock -n "$_LOCK_FD" || die "Another instance is already running (lock: $LOCK_FILE)."
  debug "Lock acquired (fd=$_LOCK_FD)"
}
release_lock() {
  [[ -n "$_LOCK_FD" ]] && flock -u "$_LOCK_FD" 2>/dev/null || true
}
do_rollback() {
  err "Rolling back changes..."
  if [[ -n "$_BACKUP_FILE" && -f "$_BACKUP_FILE" ]]; then
    warn "Restoring iptables from backup: $_BACKUP_FILE"
    iptables-restore < "$_BACKUP_FILE" 2>/dev/null || \
      warn "iptables-restore failed — manual intervention may be needed."
  fi
  sysctl -q -w net.ipv4.ip_forward=0 2>/dev/null || true
  err "Rollback complete. Review system state before re-running."
}
on_exit() {
  local rc=$?
  cleanup_tmpdir
  release_lock
  if [[ $rc -ne 0 && "$_ROLLBACK_NEEDED" == 'true' && "$DRY_RUN" == 'false' ]]; then
    do_rollback
  fi
}
on_err() {
  local lineno="${BASH_LINENO[0]:-?}" cmd="${BASH_COMMAND:-?}"
  _ROLLBACK_NEEDED=true
  err "Command failed at line ${lineno}: ${cmd}"
}
trap 'on_exit' EXIT
trap 'on_err'  ERR

# ─── Command runner ───────────────────────────────────────────────────────────
run() {
  if $DRY_RUN; then
    printf '%s %s[dry-run]%s %s\n' "$(_ts)" "$CC" "$CN" "$*"
  else
    debug "exec: $*"; "$@"
  fi
}
run_quiet() {
  if $DRY_RUN; then
    printf '%s %s[dry-run]%s %s\n' "$(_ts)" "$CC" "$CN" "$*"
  elif $VERBOSE; then "$@"
  else "$@" > /dev/null
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# CORE HELPERS
# ═══════════════════════════════════════════════════════════════════════════════
require_root() {
  [[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."
}

check_deps() {
  local missing=() tool
  for tool in iptables ip sysctl flock; do
    command -v "$tool" &>/dev/null || missing+=("$tool")
  done
  [[ ${#missing[@]} -gt 0 ]] && \
    die "Required tools missing: ${missing[*]}. Install them and re-run."
  debug "All required tools present."
}

detect_os() {
  local id='' id_like=''
  if [[ -f /etc/os-release ]]; then
    id=$(grep    -m1 '^ID='       /etc/os-release | sed 's/^ID=//;s/"//g')
    id_like=$(grep -m1 '^ID_LIKE=' /etc/os-release | sed 's/^ID_LIKE=//;s/"//g')
  fi
  case "$id" in
    ubuntu|debian)                             echo 'debian'; return ;;
    amzn|rhel|centos|fedora|rocky|almalinux)   echo 'rhel';   return ;;
    arch|manjaro|endeavouros)                  echo 'arch';   return ;;
  esac
  case "$id_like" in
    *debian*)         echo 'debian'; return ;;
    *rhel*|*fedora*)  echo 'rhel';   return ;;
    *arch*)           echo 'arch';   return ;;
  esac
  echo 'unknown'
}

# ─── Conntrack module ─────────────────────────────────────────────────────────
resolve_conntrack_module() {
  if iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null; then
    iptables -D OUTPUT -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null || true
    _CONNTRACK_MODULE='conntrack'
    # shellcheck disable=SC2054
    _CONNTRACK_ARGS=(-m conntrack --ctstate RELATED,ESTABLISHED)
  else
    _CONNTRACK_MODULE='state'
    # shellcheck disable=SC2054
    _CONNTRACK_ARGS=(-m state --state RELATED,ESTABLISHED)
  fi
  debug "Conntrack module: $_CONNTRACK_MODULE"
}

# ─── IMDS (AWS EC2 metadata) ──────────────────────────────────────────────────
_imds_fetch_token() {
  [[ -n "$IMDS_TOKEN" ]] && return 0
  local token_file="$_TMPDIR/imds_token"
  curl -sf --connect-timeout 2 -m 3 \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' \
    -X PUT 'http://169.254.169.254/latest/api/token' \
    -o "$token_file" 2>/dev/null || return 1
  [[ -s "$token_file" ]] || return 1
  IMDS_TOKEN=$(< "$token_file")
}
imds_get() {
  local path="$1"
  _imds_fetch_token || return 1
  curl -sf --connect-timeout 2 -m 3 \
    -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
    "http://169.254.169.254/latest/meta-data/${path}" 2>/dev/null
}

detect_ec2() {
  if [[ -f /sys/hypervisor/uuid ]] && grep -qi '^ec2' /sys/hypervisor/uuid 2>/dev/null; then
    IS_EC2=true; debug 'EC2 detected via hypervisor UUID'; return
  fi
  if imds_get 'instance-id' &>/dev/null; then
    IS_EC2=true; debug 'EC2 detected via IMDS'; return
  fi
  debug 'Not running on EC2'
}

# ─── CIDR utilities ───────────────────────────────────────────────────────────
normalize_cidr() {
  local input="${1:-}"
  [[ -z "$input" ]] && die "normalize_cidr: empty input"
  [[ ! "$input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] && \
    die "Invalid CIDR: '$input' (expected d.d.d.d/0-32)"
  local addr prefix; IFS='/' read -r addr prefix <<< "$input"
  local IFS=. oct; local -a octs; read -ra octs <<< "$addr"
  for oct in "${octs[@]}"; do
    (( oct >= 0 && oct <= 255 )) || die "Invalid octet '$oct' in CIDR: $input"
  done
  local a="${octs[0]}" b="${octs[1]}" c="${octs[2]}" d="${octs[3]}"
  local ip=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  local mask
  if (( prefix == 0 )); then mask=0
  else mask=$(( ( 0xFFFFFFFF << (32 - prefix) ) & 0xFFFFFFFF ))
  fi
  local net=$(( ip & mask ))
  printf '%d.%d.%d.%d/%d\n' \
    $(( (net >> 24) & 255 )) $(( (net >> 16) & 255 )) \
    $(( (net >>  8) & 255 )) $(( net & 255 )) "$prefix"
}

validate_iface() {
  local iface="$1"
  [[ "$iface" =~ ^[a-zA-Z0-9._@:-]+$ ]] || \
    die "Interface name contains invalid characters: '$iface'"
  ip link show "$iface" &>/dev/null || \
    die "Interface '$iface' does not exist. Check --iface or NAT_IFACE."
}

# ─── iptables helpers ─────────────────────────────────────────────────────────
backup_iptables() {
  $DRY_RUN && return
  mkdir -p "$BACKUP_DIR"
  _BACKUP_FILE="$BACKUP_DIR/rules-$(date '+%Y%m%dT%H%M%S').v4"
  if iptables-save > "$_BACKUP_FILE" 2>/dev/null; then
    log "Rules backed up: $_BACKUP_FILE"
  else
    warn "Could not create iptables backup (continuing)."
    _BACKUP_FILE=''
  fi
}

iptables_flush_tagged() {
  local table="$1" chain="$2" tag="$3"
  local -a nums=(); local line num
  while IFS= read -r line; do
    num=$(awk '{print $1}' <<< "$line")
    [[ "$num" =~ ^[0-9]+$ ]] && nums+=("$num")
  done < <(iptables -t "$table" -L "$chain" --line-numbers -n 2>/dev/null \
    | grep -- "/\* ${tag} \*/" || true)
  local i
  for (( i=${#nums[@]}-1; i>=0; i-- )); do
    iptables -t "$table" -D "$chain" "${nums[$i]}" 2>/dev/null || true
  done
}

iptables_flush_legacy() {
  local table="$1" chain="$2" pattern="$3"
  local -a nums=(); local line num
  while IFS= read -r line; do
    grep -q '\/\*' <<< "$line" && continue
    num=$(awk '{print $1}' <<< "$line")
    [[ "$num" =~ ^[0-9]+$ ]] && nums+=("$num")
  done < <(iptables -t "$table" -L "$chain" --line-numbers -n -v 2>/dev/null \
    | grep -E -- "$pattern" || true)
  local i
  for (( i=${#nums[@]}-1; i>=0; i-- )); do
    iptables -t "$table" -D "$chain" "${nums[$i]}" 2>/dev/null || true
  done
}

flush_script_rules() {
  local iface="${1:-}"
  iptables_flush_tagged nat    POSTROUTING "$RULE_TAG"
  iptables_flush_tagged filter FORWARD     "$RULE_TAG"
  iptables_flush_tagged filter INPUT       "$RULE_TAG"
  if [[ -n "$iface" ]]; then
    local esc_iface; esc_iface=$(printf '%s' "$iface" | sed 's/[.[\*^$]/\\&/g')
    iptables_flush_legacy nat POSTROUTING "MASQUERADE.*${esc_iface}|${esc_iface}.*MASQUERADE"
    iptables_flush_legacy filter FORWARD  "ACCEPT.*${esc_iface}|${esc_iface}.*ACCEPT"
    iptables_flush_legacy filter FORWARD  'RELATED,ESTABLISHED'
  fi
}

# ─── Interface / subnet / VPC detection ──────────────────────────────────────
detect_iface() {
  local iface=''
  iface=$(ip -o -4 route show to default 2>/dev/null \
    | awk 'NR==1{ for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit} }')
  [[ -z "$iface" ]] && iface=$(ip route show default 2>/dev/null \
    | awk 'NR==1{ for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit} }')
  printf '%s' "$iface"
}

detect_cidrs() {
  local outif="$1"; local -a found=(); local raw norm
  local skip_pat
  skip_pat='^(lo|docker[0-9]*|virbr[0-9]*|br-[a-f0-9]+|veth[a-z0-9]*'
  skip_pat+='|vnet[0-9]*|tun[0-9]*|tap[0-9]*|dummy[0-9]*'
  skip_pat+='|flannel[.][^/]*|cni[0-9]*|weave|cilium|calico)'
  while IFS= read -r raw; do
    [[ -z "$raw" ]] && continue
    norm=$(normalize_cidr "$raw") || { warn "Skipping invalid CIDR '$raw'"; continue; }
    found+=("$norm")
  done < <(ip -o -4 addr show 2>/dev/null \
    | awk -v outif="$outif" -v skip="$skip_pat" '$2 != outif && $2 !~ skip { print $4 }')
  if [[ ${#found[@]} -gt 0 ]]; then
    local IFS=','; printf '%s' "${found[*]}"
  fi
}

detect_vpc_cidrs() {
  local mac vpc_cidrs
  mac=$(imds_get 'mac') || return 1
  [[ -z "$mac" ]] && return 1
  [[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || {
    warn "IMDS returned unexpected MAC format; skipping VPC CIDR detection."
    return 1
  }
  vpc_cidrs=$(imds_get "network/interfaces/macs/${mac}/vpc-ipv4-cidr-blocks") || return 1
  [[ -z "$vpc_cidrs" ]] && return 1
  printf '%s' "$vpc_cidrs" | tr '\n' ',' | sed 's/,$//'
}

# ─── Package installation ─────────────────────────────────────────────────────
install_packages() {
  local os_family="$1"
  section "Package installation"
  case "$os_family" in
    debian)
      if ! command -v iptables &>/dev/null; then
        log "Installing iptables..."
        run_quiet apt-get update -y
        run_quiet env DEBIAN_FRONTEND=noninteractive apt-get install -y iptables
      fi
      if ! dpkg-query -W -f='${Status}' iptables-persistent 2>/dev/null \
           | grep -q '^install ok installed$'; then
        log "Installing iptables-persistent..."
        run_quiet env DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
      fi
      ;;
    rhel)
      local pm='yum'; command -v dnf &>/dev/null && pm='dnf'
      if ! command -v iptables &>/dev/null; then
        log "Installing iptables..."; run_quiet "$pm" install -y iptables
      fi
      if ! rpm -q iptables-services &>/dev/null 2>&1; then
        log "Installing iptables-services..."; run_quiet "$pm" install -y iptables-services
      fi
      ;;
    arch)
      if ! command -v iptables &>/dev/null; then
        log "Installing iptables..."; run_quiet pacman -S --noconfirm --needed iptables
      fi
      ;;
    *)
      warn "Unknown OS family — skipping package install."
      command -v iptables &>/dev/null || die "iptables not found. Install manually and re-run."
      ;;
  esac
}

# ─── IP forwarding ────────────────────────────────────────────────────────────
enable_ip_forwarding() {
  section "IP forwarding"
  log "Writing $SYSCTL_CONF..."
  if ! $DRY_RUN; then
    mkdir -p "$(dirname "$SYSCTL_CONF")"
    cat > "$SYSCTL_CONF" <<'EOF'
# Managed by setup-nat.sh — do not edit manually
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.rp_filter = 2
EOF
    sysctl -q -p "$SYSCTL_CONF" || die "sysctl failed to apply $SYSCTL_CONF"
  else
    run echo "(write $SYSCTL_CONF and sysctl -p)"
  fi
}

# ─── NAT rules ────────────────────────────────────────────────────────────────
apply_nat_rules() {
  local iface="$1"; shift; local -a cidrs=("$@")
  local -a tag=(-m comment --comment "$RULE_TAG")
  local cidr
  for cidr in "${cidrs[@]}"; do
    run iptables -t nat -A POSTROUTING -o "$iface" -s "$cidr" -j MASQUERADE "${tag[@]}"
    log "  MASQUERADE  $cidr  →  $iface"
  done
  run iptables -I FORWARD 1 "${_CONNTRACK_ARGS[@]}" -j ACCEPT "${tag[@]}"
  log "  FORWARD     ESTABLISHED/RELATED  →  ACCEPT  [xt_${_CONNTRACK_MODULE}]"
  for cidr in "${cidrs[@]}"; do
    run iptables -A FORWARD -s "$cidr" -o "$iface" -j ACCEPT "${tag[@]}"
    log "  FORWARD     $cidr  →  $iface  →  ACCEPT"
  done
}

verify_rules() {
  local iface="$1"; shift; local -a cidrs=("$@")
  $DRY_RUN && return
  local failed=false cidr
  for cidr in "${cidrs[@]}"; do
    if ! iptables -t nat -C POSTROUTING -o "$iface" -s "$cidr" -j MASQUERADE \
         -m comment --comment "$RULE_TAG" 2>/dev/null; then
      err "  Verification FAILED: MASQUERADE rule missing for $cidr → $iface"
      failed=true
    fi
  done
  if ! iptables -L FORWARD -n 2>/dev/null | grep -q "/\* ${RULE_TAG} \*/"; then
    err "  Verification FAILED: FORWARD rules not found."
    failed=true
  fi
  $failed && die "Rule verification failed. Run --status or check iptables manually."
  log "Rule verification passed."
}

# ─── Persistence ──────────────────────────────────────────────────────────────
persist_rules() {
  local os_family="$1"
  section "Persistence"
  case "$os_family" in
    debian)
      run mkdir -p /etc/iptables
      if ! $DRY_RUN; then
        iptables-save > /etc/iptables/rules.v4 || die "iptables-save failed"
      else run echo "iptables-save > /etc/iptables/rules.v4"; fi
      run systemctl enable netfilter-persistent 2>/dev/null || \
        warn "systemctl enable netfilter-persistent failed"
      ;;
    rhel)
      run systemctl enable iptables 2>/dev/null || true
      if ! $DRY_RUN; then
        service iptables save 2>/dev/null \
          || iptables-save > /etc/sysconfig/iptables \
          || die "Failed to persist iptables rules on RHEL"
      else run echo "service iptables save || iptables-save > /etc/sysconfig/iptables"; fi
      ;;
    arch)
      run mkdir -p /etc/iptables
      if ! $DRY_RUN; then
        iptables-save > /etc/iptables/iptables.rules || die "iptables-save failed"
      else run echo "iptables-save > /etc/iptables/iptables.rules"; fi
      run systemctl enable iptables 2>/dev/null || true
      ;;
    *)
      local fallback='/etc/nat-gateway-iptables.rules'
      warn "Unknown OS — saving rules to $fallback"
      if ! $DRY_RUN; then
        iptables-save > "$fallback" || warn "iptables-save failed; rules won't survive reboot."
      else run echo "iptables-save > $fallback"; fi
      ;;
  esac
  log "Rules persisted."
}

# ─── Status display ───────────────────────────────────────────────────────────
show_status() {
  section "NAT Gateway Status"
  echo
  echo "  IP forwarding (kernel):"
  sysctl net.ipv4.ip_forward 2>/dev/null | sed 's/^/    /' || echo "    (unable to read)"
  echo
  echo "  Sysctl config (${SYSCTL_CONF}):"
  if [[ -f "$SYSCTL_CONF" ]]; then sed 's/^/    /' "$SYSCTL_CONF"
  else echo "    (file not found)"; fi
  echo
  echo "  NAT rules (POSTROUTING, tagged '${RULE_TAG}'):"
  if iptables -t nat -L POSTROUTING -v -n --line-numbers 2>/dev/null \
     | grep -q "/\* ${RULE_TAG} \*/"; then
    iptables -t nat -L POSTROUTING -v -n --line-numbers 2>/dev/null \
      | grep -E "(Chain|/\* ${RULE_TAG} \*/)" | sed 's/^/    /'
  else echo "    (none)"; fi
  echo
  echo "  FORWARD rules (tagged '${RULE_TAG}'):"
  if iptables -L FORWARD -v -n --line-numbers 2>/dev/null \
     | grep -q "/\* ${RULE_TAG} \*/"; then
    iptables -L FORWARD -v -n --line-numbers 2>/dev/null \
      | grep -E "(Chain|/\* ${RULE_TAG} \*/)" | sed 's/^/    /'
  else echo "    (none)"; fi
  echo
  echo "  Latest backup:"
  if [[ -d "$BACKUP_DIR" ]]; then
    # shellcheck disable=SC2012  # ls -t is the idiomatic way to sort by mtime; backup filenames are safe
    ls -1t "$BACKUP_DIR"/*.v4 2>/dev/null | head -1 | sed 's/^/    /' || echo "    (none)"
  else echo "    (no backup directory)"; fi
  echo
}

# ─── Uninstall ────────────────────────────────────────────────────────────────
do_uninstall() {
  local os_family="$1"
  section "Uninstall"
  log "Removing all NAT rules and disabling IP forwarding..."
  local iface; iface=$(detect_iface) || true
  [[ -z "$iface" ]] && warn "Could not detect outbound interface; removing tagged rules only."
  if ! $DRY_RUN; then
    backup_iptables
    flush_script_rules "${iface:-}"
    log "Flushed all '${RULE_TAG}' rules."
    rm -f "$SYSCTL_CONF"
    sysctl -q -w net.ipv4.ip_forward=0 || warn "Could not disable ip_forward."
    persist_rules "$os_family"
  else
    run echo "flush_script_rules ${iface:-<unknown>}"
    run echo "rm -f $SYSCTL_CONF"
    run echo "sysctl -w net.ipv4.ip_forward=0"
  fi
  log "Uninstall complete. IP forwarding disabled, NAT rules removed."
}

# ═══════════════════════════════════════════════════════════════════════════════
# INSTALL FLOW (core logic, called from both interactive and non-interactive)
# ═══════════════════════════════════════════════════════════════════════════════
do_install() {
  local os_family="$1"

  check_deps
  section "Environment detection"
  detect_ec2

  local instance_id=''
  if $IS_EC2; then
    instance_id=$(imds_get 'instance-id' 2>/dev/null || true)
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warn "  AWS: Source/Destination Check must be DISABLED."
    warn "  Run from your workstation:"
    if [[ -n "$instance_id" ]]; then
      warn "    aws ec2 modify-instance-attribute \\"
      warn "      --instance-id ${instance_id} --no-source-dest-check"
    else
      warn "    aws ec2 modify-instance-attribute \\"
      warn "      --instance-id <INSTANCE-ID> --no-source-dest-check"
    fi
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  fi

  section "Interface detection"
  if [[ -z "$NAT_IFACE" ]]; then
    NAT_IFACE=$(detect_iface)
    [[ -z "$NAT_IFACE" ]] && die "Cannot auto-detect outbound interface. Use --iface."
    log "Auto-detected interface: $NAT_IFACE"
  else
    log "Using specified interface: $NAT_IFACE"
  fi
  validate_iface "$NAT_IFACE"

  section "Subnet detection"
  if [[ -z "$NAT_CIDRS" ]]; then
    NAT_CIDRS=$(detect_cidrs "$NAT_IFACE") || true
    if [[ -z "$NAT_CIDRS" ]]; then
      log "No secondary interfaces found."
      if $IS_EC2; then
        log "Querying AWS IMDS for VPC CIDR(s)..."
        NAT_CIDRS=$(detect_vpc_cidrs 2>/dev/null) || true
        [[ -n "$NAT_CIDRS" ]] && log "VPC CIDR(s): $NAT_CIDRS"
      fi
    fi
    if [[ -z "$NAT_CIDRS" ]]; then
      warn "No private subnets detected — falling back to 0.0.0.0/0."
      warn "Use --cidrs 10.0.0.0/8 for a tighter rule."
      NAT_CIDRS='0.0.0.0/0'
    fi
  else
    log "Using specified CIDRs: $NAT_CIDRS"
  fi

  local -a CIDR_ARRAY=(); local raw norm
  IFS=',' read -ra _raw_cidrs <<< "$NAT_CIDRS"
  for raw in "${_raw_cidrs[@]}"; do
    raw=$(tr -d ' ' <<< "$raw"); [[ -z "$raw" ]] && continue
    norm=$(normalize_cidr "$raw")
    CIDR_ARRAY+=("$norm"); log "  CIDR: $norm"
  done
  [[ ${#CIDR_ARRAY[@]} -eq 0 ]] && die "No valid CIDRs to configure."

  install_packages "$os_family"

  if $DRY_RUN; then
    _CONNTRACK_MODULE='conntrack'
    # shellcheck disable=SC2054
    _CONNTRACK_ARGS=(-m conntrack --ctstate RELATED,ESTABLISHED)
  else
    resolve_conntrack_module
  fi

  backup_iptables
  _ROLLBACK_NEEDED=true

  enable_ip_forwarding

  section "iptables rules"
  log "Flushing stale '${RULE_TAG}' rules..."
  if ! $DRY_RUN; then flush_script_rules "$NAT_IFACE"
  else run echo "flush_script_rules $NAT_IFACE"; fi

  log "Applying NAT rules..."
  apply_nat_rules "$NAT_IFACE" "${CIDR_ARRAY[@]}"

  section "Verification"
  verify_rules "$NAT_IFACE" "${CIDR_ARRAY[@]}"

  persist_rules "$os_family"
  _ROLLBACK_NEEDED=false

  # ── Summary ─────────────────────────────────────────────────────────────────
  echo
  log "════════════════════════════════════════════════════"
  log "  NAT Gateway v${SCRIPT_VERSION} — configuration complete"
  log "════════════════════════════════════════════════════"
  log "  Interface  : ${NAT_IFACE}"
  log "  CIDRs      : ${CIDR_ARRAY[*]}"
  log "  Forwarding : enabled  (${SYSCTL_CONF})"
  log "  Module     : xt_${_CONNTRACK_MODULE}"
  [[ -n "$_BACKUP_FILE" ]] && log "  Backup     : ${_BACKUP_FILE}"
  $IS_EC2 && log "  AWS EC2    : !! disable Source/Dest check (see above) !!"
  log "════════════════════════════════════════════════════"

  if ! $DRY_RUN; then
    # Post-install tests
    run_post_install_tests "$NAT_IFACE" "${CIDR_ARRAY[@]}" || true

    # Detect NAT gateway's private IP for client setup
    local nat_gw
    nat_gw=$(ip -o -4 addr show dev "$NAT_IFACE" 2>/dev/null \
      | awk 'NR==1{print $4}' | cut -d/ -f1 || echo '<NAT-PRIVATE-IP>')

    # Show client setup menu
    show_client_menu "$nat_gw" "$instance_id"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# INTERACTIVE MENU LOOP
# ═══════════════════════════════════════════════════════════════════════════════
run_interactive_menu() {
  local os_family="$1"

  while true; do
    print_banner
    print_main_menu

    local choice; choice=$(prompt_choice 1 5)

    case "$choice" in
      1)
        echo
        section "Install / Reconfigure NAT Gateway"
        if confirm "Proceed with installation?"; then
          do_install "$os_family"
        else
          printf '\n%sInstallation cancelled.%s\n' "$CY" "$CN"
        fi
        press_enter
        ;;
      2)
        echo
        section "Uninstall NAT Gateway"
        if confirm "Remove all NAT rules and disable IP forwarding?"; then
          do_uninstall "$os_family"
          printf '\n%s✓ Uninstall complete.%s\n' "$CG" "$CN"
        else
          printf '\n%sUninstall cancelled.%s\n' "$CY" "$CN"
        fi
        press_enter
        ;;
      3)
        show_status
        press_enter
        ;;
      4)
        local nat_gw
        nat_gw=$(ip -o -4 addr show dev "$(detect_iface)" 2>/dev/null \
          | awk 'NR==1{print $4}' | cut -d/ -f1 || echo '<NAT-PRIVATE-IP>')
        local iid=''
        $IS_EC2 && iid=$(imds_get 'instance-id' 2>/dev/null || true)
        show_client_menu "$nat_gw" "$iid"
        ;;
      5)
        printf '\n%sGoodbye.%s\n\n' "$CDIM" "$CN"
        exit 0
        ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════════════════════════
# ARGUMENT PARSING
# ═══════════════════════════════════════════════════════════════════════════════
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install)   INSTALL=true ;;
      --dry-run)   DRY_RUN=true; INSTALL=true ;;
      --uninstall) UNINSTALL=true ;;
      --status)    STATUS_ONLY=true ;;
      --verbose)   VERBOSE=true ;;
      --iface)
        [[ $# -ge 2 ]] || die "--iface requires an argument"
        NAT_IFACE="$2"; shift ;;
      --cidrs)
        [[ $# -ge 2 ]] || die "--cidrs requires an argument"
        NAT_CIDRS="$2"; shift ;;
      -h|--help)
        sed -n '/^# INTERACTIVE (default)/,/^###/p' "$0" | sed 's/^# \{0,1\}//;$d'
        exit 0 ;;
      *)
        die "Unknown argument: '$1'  (run with --help for usage)" ;;
    esac
    shift
  done
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
main() {
  parse_args "$@"
  require_root
  setup_tmpdir
  acquire_lock

  local os_family; os_family=$(detect_os)

  # ── Non-interactive modes (explicit flags) ───────────────────────────────────
  if $STATUS_ONLY; then
    show_status
    exit 0
  fi

  if $UNINSTALL; then
    do_uninstall "$os_family"
    exit 0
  fi

  if $INSTALL || $DRY_RUN; then
    section "NAT Gateway v${SCRIPT_VERSION}"
    log "OS family : $os_family"
    $DRY_RUN && warn "DRY-RUN mode — no changes will be made."
    $VERBOSE  && debug "Verbose logging enabled."
    do_install "$os_family"
    exit 0
  fi

  # ── Interactive mode (default when no action flag given) ─────────────────────
  if [[ -t 0 ]]; then
    run_interactive_menu "$os_family"
  else
    # stdin is not a tty (piped/automated) — run install directly
    section "NAT Gateway v${SCRIPT_VERSION} (non-interactive)"
    log "OS family : $os_family"
    do_install "$os_family"
  fi
}

main "$@"
