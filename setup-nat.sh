#!/usr/bin/env bash
###############################################################################
# setup-nat.sh — Production-grade self-configuring NAT Gateway
# Version: 3.0
#
# USAGE:
#   sudo ./setup-nat.sh [OPTIONS]
#
# OPTIONS:
#   --iface IFACE        Override outbound interface auto-detection
#   --cidrs CIDR[,...]   Override subnet auto-detection (comma-separated)
#   --dry-run            Show what would be done; make no changes
#   --uninstall          Remove all NAT rules and disable IP forwarding
#   --status             Show current NAT configuration and exit
#   --verbose            Enable debug-level output
#   -h|--help            Show this help
#
# ENVIRONMENT VARIABLE OVERRIDES (alternatives to flags):
#   NAT_IFACE=eth0
#   NAT_CIDRS="10.0.0.0/16,192.168.1.0/24"
#
# WHAT IT DOES AUTOMATICALLY:
#   - Detects OS family (Debian/Ubuntu, RHEL/Amazon Linux/CentOS/Fedora, Arch)
#   - Validates required tools; installs iptables + persistence if missing
#   - Detects the primary outbound network interface
#   - Detects private subnets; on AWS queries IMDS for VPC CIDR
#   - Detects AWS EC2 and prints the Source/Dest check reminder
#   - Enables IPv4 forwarding (persistent via sysctl.d)
#   - Configures iptables MASQUERADE + FORWARD rules (comment-tagged)
#   - Backs up existing iptables state before any changes
#   - Flushes own stale rules before re-applying (safe re-run)
#   - Persists iptables rules across reboots (distro-appropriate method)
#   - Rolls back all changes on any failure via ERR trap
#   - Prevents concurrent execution via flock
###############################################################################
set -euo pipefail
IFS=$'\n\t'

# ─── Constants ────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="3.0"
readonly RULE_TAG="setup-nat"
readonly SYSCTL_CONF="/etc/sysctl.d/99-nat-gateway.conf"
readonly LOCK_FILE="/var/run/setup-nat.lock"
readonly BACKUP_DIR="/var/lib/setup-nat/backups"

# ─── Runtime state ────────────────────────────────────────────────────────────
DRY_RUN=false
UNINSTALL=false
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
_CONNTRACK_MODULE=""        # resolved once: "conntrack" or "state"
_CONNTRACK_ARGS=()          # array: the actual iptables match args for RELATED,ESTABLISHED

# ─── Colours (auto-disabled if not a tty) ─────────────────────────────────────
if [[ -t 2 ]]; then
  _R='\033[0;31m' _Y='\033[1;33m' _G='\033[0;32m' _C='\033[0;36m' _B='\033[1m' _N='\033[0m'
else
  _R='' _Y='' _G='' _C='' _B='' _N=''
fi

# ─── Logging ──────────────────────────────────────────────────────────────────
_ts()    { date '+%Y-%m-%dT%H:%M:%S'; }
log()    { echo -e "$(_ts) ${_G}INFO ${_N} [${RULE_TAG}] $*"; }
warn()   { echo -e "$(_ts) ${_Y}WARN ${_N} [${RULE_TAG}] $*" >&2; }
err()    { echo -e "$(_ts) ${_R}ERROR${_N} [${RULE_TAG}] $*" >&2; }
debug()  { $VERBOSE && echo -e "$(_ts) ${_C}DEBUG${_N} [${RULE_TAG}] $*" >&2 || true; }
section(){ echo -e "\n$(_ts) ${_B}━━━ $* ━━━${_N}"; }
die()    { err "$*"; exit 1; }

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)   DRY_RUN=true ;;
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
        sed -n '/^# USAGE:/,/^###/p' "$0" | sed 's/^# \{0,1\}//;$d'
        exit 0 ;;
      *)
        die "Unknown argument: '$1'  (run with --help for usage)" ;;
    esac
    shift
  done
}

# ─── Root check ───────────────────────────────────────────────────────────────
require_root() {
  [[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."
}

# ─── Temp directory ───────────────────────────────────────────────────────────
setup_tmpdir() {
  _TMPDIR="$(mktemp -d /tmp/.nat-setup-XXXXXX)"
  chmod 700 "$_TMPDIR"
  debug "Temp dir: $_TMPDIR"
}

cleanup_tmpdir() {
  [[ -n "$_TMPDIR" && -d "$_TMPDIR" ]] && rm -rf "$_TMPDIR" || true
}

# ─── Lock (prevent concurrent runs) ──────────────────────────────────────────
acquire_lock() {
  $DRY_RUN && { debug "Skipping lock in dry-run mode"; return; }
  exec {_LOCK_FD}>"$LOCK_FILE" \
    || die "Cannot create lock file: $LOCK_FILE"
  flock -n "$_LOCK_FD" \
    || die "Another instance of setup-nat.sh is already running (lock: $LOCK_FILE)."
  debug "Lock acquired: $LOCK_FILE (fd=$_LOCK_FD)"
}

release_lock() {
  [[ -n "$_LOCK_FD" ]] && flock -u "$_LOCK_FD" 2>/dev/null || true
}

# ─── Rollback ─────────────────────────────────────────────────────────────────
do_rollback() {
  err "Rolling back changes..."
  # Restore iptables from backup if we made one
  if [[ -n "$_BACKUP_FILE" && -f "$_BACKUP_FILE" ]]; then
    warn "Restoring iptables from backup: $_BACKUP_FILE"
    iptables-restore < "$_BACKUP_FILE" 2>/dev/null || \
      warn "iptables-restore failed — manual intervention may be needed."
  fi
  # Restore ip_forward to 0 (safest default on error)
  sysctl -q -w net.ipv4.ip_forward=0 2>/dev/null || true
  err "Rollback complete. Review the system state before re-running."
}

# ─── Exit / ERR traps ─────────────────────────────────────────────────────────
on_exit() {
  local rc=$?
  cleanup_tmpdir
  release_lock
  if [[ $rc -ne 0 && "$_ROLLBACK_NEEDED" == "true" && ! "$DRY_RUN" == "true" ]]; then
    do_rollback
  fi
}

on_err() {
  local lineno="${BASH_LINENO[0]:-?}"
  local cmd="${BASH_COMMAND:-?}"
  _ROLLBACK_NEEDED=true
  err "Command failed at line ${lineno}: ${cmd}"
}

trap 'on_exit'  EXIT
trap 'on_err'   ERR

# ─── Command runner ───────────────────────────────────────────────────────────
# run CMD ARGS... — executes an array of words directly (no eval, no bash -c).
# In dry-run mode, prints what would run instead.
run() {
  if $DRY_RUN; then
    echo -e "$(_ts) ${_C}[dry-run]${_N} $*"
  else
    debug "exec: $*"
    "$@"
  fi
}

# run_quiet CMD ARGS... — like run but suppresses stdout in non-verbose mode.
run_quiet() {
  if $DRY_RUN; then
    echo -e "$(_ts) ${_C}[dry-run]${_N} $*"
  elif $VERBOSE; then
    "$@"
  else
    "$@" > /dev/null
  fi
}

# ─── Dependency check ─────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  local tool
  for tool in iptables ip sysctl flock; do
    command -v "$tool" &>/dev/null || missing+=("$tool")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Required tools missing: ${missing[*]}. Install them and re-run."
  fi
  debug "All required tools present."
}

# ─── OS detection ─────────────────────────────────────────────────────────────
detect_os() {
  local id="" id_like=""
  if [[ -f /etc/os-release ]]; then
    # Use grep+sed instead of sourcing to avoid executing arbitrary shell code
    id=$(grep    -m1 '^ID='      /etc/os-release | sed 's/^ID=//;s/"//g')
    id_like=$(grep -m1 '^ID_LIKE=' /etc/os-release | sed 's/^ID_LIKE=//;s/"//g')
  fi
  case "$id" in
    ubuntu|debian)                    echo "debian"; return ;;
    amzn|rhel|centos|fedora|rocky|almalinux) echo "rhel"; return ;;
    arch|manjaro|endeavouros)         echo "arch";   return ;;
  esac
  case "$id_like" in
    *debian*)           echo "debian"; return ;;
    *rhel*|*fedora*)    echo "rhel";   return ;;
    *arch*)             echo "arch";   return ;;
  esac
  echo "unknown"
}

# ─── conntrack module resolution ─────────────────────────────────────────────
# Modern kernels: -m conntrack --ctstate. Older: -m state --state.
# Populates the global _CONNTRACK_ARGS array — never returns a string that
# would need re-splitting (avoids IFS=$'\n\t' word-split issues).
resolve_conntrack_module() {
  if iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null; then
    iptables -D OUTPUT -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null || true
    _CONNTRACK_MODULE="conntrack"
    # shellcheck disable=SC2054
    _CONNTRACK_ARGS=(-m conntrack --ctstate RELATED,ESTABLISHED)
  else
    _CONNTRACK_MODULE="state"
    # shellcheck disable=SC2054
    _CONNTRACK_ARGS=(-m state --state RELATED,ESTABLISHED)
  fi
  debug "Conntrack module: $_CONNTRACK_MODULE (args: ${_CONNTRACK_ARGS[*]})"
}

# ─── IMDS (AWS EC2 metadata service) helpers ──────────────────────────────────
# Fetches and caches the IMDSv2 token. Returns non-zero if IMDS unavailable.
_imds_fetch_token() {
  [[ -n "$IMDS_TOKEN" ]] && return 0
  local token_file="$_TMPDIR/imds_token"
  curl -sf --connect-timeout 2 -m 3 \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
    -X PUT "http://169.254.169.254/latest/api/token" \
    -o "$token_file" 2>/dev/null || return 1
  [[ -s "$token_file" ]] || return 1
  IMDS_TOKEN=$(< "$token_file")
  debug "IMDS token acquired (${#IMDS_TOKEN} chars)"
}

# imds_get PATH — query IMDS. Returns non-zero if unreachable or on error.
imds_get() {
  local path="$1"
  _imds_fetch_token || return 1
  curl -sf --connect-timeout 2 -m 3 \
    -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
    "http://169.254.169.254/latest/meta-data/${path}" 2>/dev/null
}

# ─── EC2 detection ────────────────────────────────────────────────────────────
detect_ec2() {
  # Xen-based instances expose hypervisor UUID
  if [[ -f /sys/hypervisor/uuid ]] && grep -qi '^ec2' /sys/hypervisor/uuid 2>/dev/null; then
    IS_EC2=true; debug "EC2 detected via hypervisor UUID"; return
  fi
  # Nitro-based instances: try IMDSv2
  if imds_get "instance-id" &>/dev/null; then
    IS_EC2=true; debug "EC2 detected via IMDS instance-id"; return
  fi
  debug "Not running on EC2 (or IMDS unreachable)"
}

# ─── CIDR utilities ───────────────────────────────────────────────────────────
# Validate and normalize host-address CIDR to network CIDR.
# e.g.  172.17.0.1/16  →  172.17.0.0/16
normalize_cidr() {
  local input="${1:-}"
  [[ -z "$input" ]] && die "normalize_cidr: empty input"

  # Strict format check: d.d.d.d/p
  if [[ ! "$input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
    die "Invalid CIDR: '$input' (expected d.d.d.d/0-32)"
  fi

  local addr prefix
  IFS='/' read -r addr prefix <<< "$input"

  # Validate each octet
  local IFS=. oct; local -a octs
  read -ra octs <<< "$addr"
  for oct in "${octs[@]}"; do
    (( oct >= 0 && oct <= 255 )) || die "Invalid octet '$oct' in CIDR: $input"
  done
  local a="${octs[0]}" b="${octs[1]}" c="${octs[2]}" d="${octs[3]}"

  local ip=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  local mask
  if (( prefix == 0 )); then
    mask=0
  else
    # Parenthesise carefully to avoid bash signed-shift surprises on 32-bit
    mask=$(( ( 0xFFFFFFFF << (32 - prefix) ) & 0xFFFFFFFF ))
  fi
  local net=$(( ip & mask ))

  printf '%d.%d.%d.%d/%d\n' \
    $(( (net >> 24) & 255 )) $(( (net >> 16) & 255 )) \
    $(( (net >>  8) & 255 )) $(( net & 255 )) "$prefix"
}

# validate_iface NAME — die if the interface doesn't exist in the kernel.
validate_iface() {
  local iface="$1"
  # Sanitise: interface names must not contain shell metacharacters
  [[ "$iface" =~ ^[a-zA-Z0-9._@:-]+$ ]] \
    || die "Interface name contains invalid characters: '$iface'"
  ip link show "$iface" &>/dev/null \
    || die "Interface '$iface' does not exist. Check --iface or NAT_IFACE."
}

# ─── iptables helpers ─────────────────────────────────────────────────────────

# Backup current iptables state before any changes.
backup_iptables() {
  $DRY_RUN && return
  mkdir -p "$BACKUP_DIR"
  _BACKUP_FILE="$BACKUP_DIR/rules-$(date '+%Y%m%dT%H%M%S').v4"
  if iptables-save > "$_BACKUP_FILE" 2>/dev/null; then
    log "Existing rules backed up to: $_BACKUP_FILE"
  else
    warn "Could not create iptables backup (continuing anyway)."
    _BACKUP_FILE=""
  fi
}

# iptables_flush_tagged TABLE CHAIN TAG
# Delete all rules in TABLE/CHAIN bearing comment TAG.
# Deletes in reverse line-number order to avoid index shifting.
iptables_flush_tagged() {
  local table="$1" chain="$2" tag="$3"
  local -a nums=()
  local line num

  while IFS= read -r line; do
    num=$(awk '{print $1}' <<< "$line")
    [[ "$num" =~ ^[0-9]+$ ]] && nums+=("$num")
  done < <(iptables -t "$table" -L "$chain" --line-numbers -n 2>/dev/null \
    | grep -- "/\* ${tag} \*/" || true)

  local i
  for (( i=${#nums[@]}-1; i>=0; i-- )); do
    debug "  delete $table/$chain rule #${nums[$i]}"
    iptables -t "$table" -D "$chain" "${nums[$i]}" 2>/dev/null || true
  done
  debug "  flushed ${#nums[@]} tagged rules from $table/$chain"
}

# iptables_flush_legacy TABLE CHAIN LINE_PATTERN
# Remove untagged (no comment) rules whose iptables -L line matches PATTERN.
# Used for one-time migration from pre-tagging script versions.
iptables_flush_legacy() {
  local table="$1" chain="$2" pattern="$3"
  local -a nums=()
  local line num

  while IFS= read -r line; do
    # Skip lines that already carry a comment (another tool's rule)
    grep -q '\/\*' <<< "$line" && continue
    num=$(awk '{print $1}' <<< "$line")
    [[ "$num" =~ ^[0-9]+$ ]] && nums+=("$num")
  done < <(iptables -t "$table" -L "$chain" --line-numbers -n -v 2>/dev/null \
    | grep -E -- "$pattern" || true)

  local i
  for (( i=${#nums[@]}-1; i>=0; i-- )); do
    debug "  legacy-delete $table/$chain rule #${nums[$i]}"
    iptables -t "$table" -D "$chain" "${nums[$i]}" 2>/dev/null || true
  done
}

# flush_script_rules IFACE
# Remove all rules owned by this script (tagged + legacy untagged on IFACE).
flush_script_rules() {
  local iface="${1:-}"

  # Tagged rules — always safe, only ever created by this script
  iptables_flush_tagged nat    POSTROUTING "$RULE_TAG"
  iptables_flush_tagged filter FORWARD     "$RULE_TAG"
  iptables_flush_tagged filter INPUT       "$RULE_TAG"

  # Legacy untagged rules from pre-3.0 runs (migration path)
  if [[ -n "$iface" ]]; then
    # Escape the iface for use in an awk/grep pattern
    local esc_iface
    esc_iface=$(printf '%s' "$iface" | sed 's/[.[\*^$]/\\&/g')

    # POSTROUTING: MASQUERADE on this specific outbound interface
    iptables_flush_legacy nat POSTROUTING \
      "MASQUERADE.*${esc_iface}|${esc_iface}.*MASQUERADE"

    # FORWARD: ACCEPT rules targeting this outbound interface
    iptables_flush_legacy filter FORWARD \
      "ACCEPT.*${esc_iface}|${esc_iface}.*ACCEPT"

    # FORWARD: bare RELATED,ESTABLISHED ACCEPT (our old rule; Docker uses DOCKER-FORWARD chain)
    iptables_flush_legacy filter FORWARD "RELATED,ESTABLISHED"
  fi
}

# ─── Interface auto-detection ─────────────────────────────────────────────────
detect_iface() {
  local iface=""
  # Primary: default route dev field
  iface=$(ip -o -4 route show to default 2>/dev/null \
    | awk 'NR==1{ for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit} }')
  # Fallback: first interface with a default route (any metric)
  if [[ -z "$iface" ]]; then
    iface=$(ip route show default 2>/dev/null \
      | awk 'NR==1{ for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit} }')
  fi
  printf '%s' "$iface"
}

# ─── Subnet auto-detection ────────────────────────────────────────────────────
detect_cidrs() {
  local outif="$1"
  local -a found=()
  local raw norm

  # Virtual/overlay interface prefixes to skip — they are not physical LANs
  local skip_pat
  skip_pat='^(lo|docker[0-9]*|virbr[0-9]*|br-[a-f0-9]+|veth[a-z0-9]*'
  skip_pat+='|vnet[0-9]*|tun[0-9]*|tap[0-9]*|dummy[0-9]*'
  skip_pat+='|flannel[.][^/]*|cni[0-9]*|weave|cilium|calico)'

  while IFS= read -r raw; do
    [[ -z "$raw" ]] && continue
    norm=$(normalize_cidr "$raw") || { warn "Skipping invalid CIDR '$raw'"; continue; }
    found+=("$norm")
    debug "  detected secondary CIDR: $norm"
  done < <(ip -o -4 addr show 2>/dev/null \
    | awk -v outif="$outif" -v skip="$skip_pat" \
        '$2 != outif && $2 !~ skip { print $4 }')

  if [[ ${#found[@]} -gt 0 ]]; then
    local IFS=','
    printf '%s' "${found[*]}"
  fi
}

# ─── AWS VPC CIDR detection ───────────────────────────────────────────────────
detect_vpc_cidrs() {
  local mac vpc_cidrs
  mac=$(imds_get "mac") || return 1
  [[ -z "$mac" ]] && return 1
  # Validate MAC format to guard against IMDS injection
  [[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || {
    warn "IMDS returned unexpected MAC format; skipping VPC CIDR detection."
    return 1
  }
  vpc_cidrs=$(imds_get "network/interfaces/macs/${mac}/vpc-ipv4-cidr-blocks") || return 1
  [[ -z "$vpc_cidrs" ]] && return 1
  # IMDS returns one CIDR per line — join with comma, strip trailing comma
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
      # Correct installed-and-configured check
      if ! dpkg-query -W -f='${Status}' iptables-persistent 2>/dev/null \
           | grep -q '^install ok installed$'; then
        log "Installing iptables-persistent..."
        run_quiet env DEBIAN_FRONTEND=noninteractive \
          apt-get install -y iptables-persistent
      fi
      ;;
    rhel)
      local pm="yum"
      command -v dnf &>/dev/null && pm="dnf"
      if ! command -v iptables &>/dev/null; then
        log "Installing iptables..."
        run_quiet "$pm" install -y iptables
      fi
      if ! rpm -q iptables-services &>/dev/null 2>&1; then
        log "Installing iptables-services..."
        run_quiet "$pm" install -y iptables-services
      fi
      ;;
    arch)
      if ! command -v iptables &>/dev/null; then
        log "Installing iptables..."
        run_quiet pacman -S --noconfirm --needed iptables
      fi
      ;;
    *)
      warn "Unknown OS family — skipping package install."
      command -v iptables &>/dev/null \
        || die "iptables not found. Install it manually and re-run."
      ;;
  esac
  debug "Package check complete."
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
    # Apply only this file to avoid unintended side effects from other sysctl.d entries
    sysctl -q -p "$SYSCTL_CONF" \
      || die "sysctl failed to apply $SYSCTL_CONF"
    debug "sysctl applied."
  else
    run echo "(write $SYSCTL_CONF and sysctl -p)"
  fi
}

# ─── NAT rules ────────────────────────────────────────────────────────────────
apply_nat_rules() {
  local iface="$1"; shift
  local -a cidrs=("$@")
  local -a tag=(-m comment --comment "$RULE_TAG")
  local cidr

  for cidr in "${cidrs[@]}"; do
    run iptables -t nat -A POSTROUTING \
      -o "$iface" -s "$cidr" -j MASQUERADE "${tag[@]}"
    log "  MASQUERADE  $cidr  →  $iface"
  done

  # Allow return traffic (ESTABLISHED/RELATED). Inserted at position 1 in FORWARD
  # so it evaluates before the DROP policy and any per-CIDR rules.
  # _CONNTRACK_ARGS is a pre-built array — no string splitting needed.
  run iptables -I FORWARD 1 \
    "${_CONNTRACK_ARGS[@]}" -j ACCEPT "${tag[@]}"
  log "  FORWARD     ESTABLISHED/RELATED  →  ACCEPT  [xt_${_CONNTRACK_MODULE}]"

  for cidr in "${cidrs[@]}"; do
    run iptables -A FORWARD \
      -s "$cidr" -o "$iface" -j ACCEPT "${tag[@]}"
    log "  FORWARD     $cidr  →  $iface  →  ACCEPT"
  done
}

# ─── Verify applied rules ─────────────────────────────────────────────────────
verify_rules() {
  local iface="$1"; shift
  local -a cidrs=("$@")
  $DRY_RUN && return

  local failed=false cidr

  for cidr in "${cidrs[@]}"; do
    if ! iptables -t nat -C POSTROUTING \
         -o "$iface" -s "$cidr" -j MASQUERADE \
         -m comment --comment "$RULE_TAG" 2>/dev/null; then
      err "  Verification FAILED: MASQUERADE rule missing for $cidr → $iface"
      failed=true
    else
      debug "  Verified MASQUERADE: $cidr → $iface"
    fi
  done

  # Check FORWARD rules exist (at least one tagged entry)
  if ! iptables -L FORWARD -n 2>/dev/null | grep -q "/\* ${RULE_TAG} \*/"; then
    err "  Verification FAILED: No FORWARD rules with tag '${RULE_TAG}' found."
    failed=true
  else
    debug "  Verified FORWARD rules present."
  fi

  $failed && die "Rule verification failed. Run --status or check iptables manually."
  log "Rule verification passed."
}

# ─── Persist across reboots ───────────────────────────────────────────────────
persist_rules() {
  local os_family="$1"
  section "Persistence"

  case "$os_family" in
    debian)
      run mkdir -p /etc/iptables
      if ! $DRY_RUN; then
        iptables-save > /etc/iptables/rules.v4 \
          || die "iptables-save failed"
      else
        run echo "iptables-save > /etc/iptables/rules.v4"
      fi
      run systemctl enable netfilter-persistent 2>/dev/null || \
        warn "systemctl enable netfilter-persistent failed (may not matter if service already active)"
      ;;
    rhel)
      run systemctl enable iptables 2>/dev/null || true
      if ! $DRY_RUN; then
        service iptables save 2>/dev/null \
          || iptables-save > /etc/sysconfig/iptables \
          || die "Failed to persist iptables rules on RHEL"
      else
        run echo "service iptables save || iptables-save > /etc/sysconfig/iptables"
      fi
      ;;
    arch)
      run mkdir -p /etc/iptables
      if ! $DRY_RUN; then
        iptables-save > /etc/iptables/iptables.rules \
          || die "iptables-save failed"
      else
        run echo "iptables-save > /etc/iptables/iptables.rules"
      fi
      run systemctl enable iptables 2>/dev/null || true
      ;;
    *)
      local fallback="/etc/nat-gateway-iptables.rules"
      warn "Unknown OS — saving rules to $fallback"
      warn "Add 'iptables-restore < $fallback' to a boot-time hook."
      if ! $DRY_RUN; then
        iptables-save > "$fallback" || warn "iptables-save failed; rules will not survive reboot."
      else
        run echo "iptables-save > $fallback"
      fi
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
  if [[ -f "$SYSCTL_CONF" ]]; then
    sed 's/^/    /' "$SYSCTL_CONF"
  else
    echo "    (file not found — not configured by this script)"
  fi

  echo
  echo "  NAT rules (POSTROUTING, tagged '${RULE_TAG}'):"
  if iptables -t nat -L POSTROUTING -v -n --line-numbers 2>/dev/null \
     | grep -q "/\* ${RULE_TAG} \*/"; then
    iptables -t nat -L POSTROUTING -v -n --line-numbers 2>/dev/null \
      | grep -E "(Chain|/\* ${RULE_TAG} \*/)" | sed 's/^/    /'
  else
    echo "    (none)"
  fi

  echo
  echo "  FORWARD rules (tagged '${RULE_TAG}'):"
  if iptables -L FORWARD -v -n --line-numbers 2>/dev/null \
     | grep -q "/\* ${RULE_TAG} \*/"; then
    iptables -L FORWARD -v -n --line-numbers 2>/dev/null \
      | grep -E "(Chain|/\* ${RULE_TAG} \*/)" | sed 's/^/    /'
  else
    echo "    (none)"
  fi

  echo
  echo "  Latest backup:"
  if [[ -d "$BACKUP_DIR" ]]; then
    ls -1t "$BACKUP_DIR"/*.v4 2>/dev/null | head -1 | sed 's/^/    /' || echo "    (none)"
  else
    echo "    (no backup directory)"
  fi
  echo
}

# ─── Uninstall ────────────────────────────────────────────────────────────────
do_uninstall() {
  local os_family="$1"
  section "Uninstall"
  log "Removing all NAT rules and disabling IP forwarding..."

  local iface
  iface=$(detect_iface) || true
  [[ -z "$iface" ]] && warn "Could not detect outbound interface; only tagged rules will be removed."

  if ! $DRY_RUN; then
    backup_iptables
    flush_script_rules "${iface:-}"
    log "Flushed all '${RULE_TAG}' rules."
    rm -f "$SYSCTL_CONF"
    sysctl -q -w net.ipv4.ip_forward=0 \
      || warn "Could not disable ip_forward (may need reboot)."
    persist_rules "$os_family"
  else
    run echo "flush_script_rules ${iface:-<unknown>}"
    run echo "rm -f $SYSCTL_CONF"
    run echo "sysctl -w net.ipv4.ip_forward=0"
    run echo "persist_rules $os_family"
  fi

  log "Uninstall complete. IP forwarding disabled, NAT rules removed."
}

# ─── Client setup instructions ────────────────────────────────────────────────
show_client_setup() {
  local nat_gw
  nat_gw=$(ip -o -4 addr show dev "$NAT_IFACE" 2>/dev/null \
    | awk 'NR==1{print $4}' | cut -d/ -f1)
  [[ -z "$nat_gw" ]] && nat_gw="<NAT-PRIVATE-IP>"

  echo
  echo -e "${_B}╔═════════════════════════════════════════════════════════╗"
  echo -e "║   PRIVATE SERVER SETUP — copy/paste on each client     ║"
  echo -e "╚═════════════════════════════════════════════════════════╝${_N}"
  echo
  printf '%s\n' \
    "NAT_GW=${nat_gw}" \
    "" \
    "# ── 1. Apply immediately ──────────────────────────────────" \
    "sudo ip route replace default via \$NAT_GW" \
    "" \
    "# ── 2. Make permanent (systemd) ───────────────────────────" \
    "sudo tee /etc/systemd/system/nat-route.service << 'SVCEOF'" \
    "[Unit]" \
    "Description=Default route via NAT Gateway" \
    "After=network.target" \
    "" \
    "[Service]" \
    "Type=oneshot" \
    "ExecStart=/sbin/ip route replace default via ${nat_gw}" \
    "RemainAfterExit=yes" \
    "" \
    "[Install]" \
    "WantedBy=multi-user.target" \
    "SVCEOF" \
    "" \
    "sudo systemctl daemon-reload" \
    "sudo systemctl enable --now nat-route.service" \
    "" \
    "# ── 3. Verify ─────────────────────────────────────────────" \
    "curl -s https://checkip.amazonaws.com   # must show NAT public IP" \
    "ping -c 3 8.8.8.8"

  if $IS_EC2; then
    local iid=""
    iid=$(imds_get "instance-id" 2>/dev/null || true)
    echo
    echo -e "${_Y}  ╔══ AWS ONLY — run from your workstation, not here ══╗${_N}"
    echo -e "${_Y}  ║  Add a route in the private subnet's route table:  ║${_N}"
    echo -e "${_Y}  ╚════════════════════════════════════════════════════╝${_N}"
    echo
    echo "  Step 1 — find your private subnet route table ID in the AWS Console"
    echo "           (VPC → Route Tables → select the private subnet's table)"
    echo
    echo "  Step 2 — run this from your workstation (AWS CLI):"
    echo
    printf '%s\n' \
      "  aws ec2 create-route \\" \
      "    --route-table-id <PRIVATE-SUBNET-RTB-ID> \\" \
      "    --destination-cidr-block 0.0.0.0/0 \\" \
      "    --instance-id ${iid:-<INSTANCE-ID>}"
    echo
    echo "  After this, private servers route through this NAT automatically."
    echo "  No commands needed on the private servers themselves."
  fi
  echo
  echo -e "${_B}═════════════════════════════════════════════════════════${_N}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
main() {
  parse_args "$@"
  require_root
  setup_tmpdir
  acquire_lock

  local os_family
  os_family=$(detect_os)

  section "NAT Gateway v${SCRIPT_VERSION}"
  log "OS family : $os_family"
  $DRY_RUN  && warn "DRY-RUN mode active — no changes will be made."
  $VERBOSE  && debug "Verbose logging enabled."

  # ── Status only ─────────────────────────────────────────────────────────────
  if $STATUS_ONLY; then
    show_status
    exit 0
  fi

  # ── Uninstall ────────────────────────────────────────────────────────────────
  if $UNINSTALL; then
    do_uninstall "$os_family"
    exit 0
  fi

  # ── Dependencies ─────────────────────────────────────────────────────────────
  check_deps

  # ── EC2 detection ────────────────────────────────────────────────────────────
  section "Environment detection"
  detect_ec2
  if $IS_EC2; then
    log "AWS EC2 instance detected."
    local instance_id=""
    instance_id=$(imds_get "instance-id" 2>/dev/null || true)
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warn "  AWS Source/Destination Check must be DISABLED on this"
    warn "  instance's ENI — this cannot be done from inside the OS."
    warn "  Run once from your workstation (AWS CLI required):"
    if [[ -n "$instance_id" ]]; then
      warn "    aws ec2 modify-instance-attribute \\"
      warn "      --instance-id ${instance_id} --no-source-dest-check"
    else
      warn "    aws ec2 modify-instance-attribute \\"
      warn "      --instance-id <INSTANCE-ID> --no-source-dest-check"
    fi
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  fi

  # ── Interface detection ───────────────────────────────────────────────────────
  section "Interface detection"
  if [[ -z "$NAT_IFACE" ]]; then
    NAT_IFACE=$(detect_iface)
    [[ -z "$NAT_IFACE" ]] && \
      die "Cannot auto-detect outbound interface (no default route). Use --iface."
    log "Auto-detected outbound interface: $NAT_IFACE"
  else
    log "Using specified outbound interface: $NAT_IFACE"
  fi
  validate_iface "$NAT_IFACE"

  # ── CIDR detection ────────────────────────────────────────────────────────────
  section "Subnet detection"
  if [[ -z "$NAT_CIDRS" ]]; then
    NAT_CIDRS=$(detect_cidrs "$NAT_IFACE") || true

    if [[ -z "$NAT_CIDRS" ]]; then
      log "No secondary physical interfaces found."
      if $IS_EC2; then
        log "Querying AWS IMDS for VPC CIDR(s)..."
        NAT_CIDRS=$(detect_vpc_cidrs 2>/dev/null) || true
        [[ -n "$NAT_CIDRS" ]] && log "VPC CIDR(s) from IMDS: $NAT_CIDRS"
      fi
    fi

    if [[ -z "$NAT_CIDRS" ]]; then
      warn "No private subnets detected — falling back to 0.0.0.0/0."
      warn "Tip: use --cidrs 10.0.0.0/8 for a tighter, more secure rule."
      NAT_CIDRS="0.0.0.0/0"
    fi
  else
    log "Using specified CIDRs: $NAT_CIDRS"
  fi

  # Validate and normalise every CIDR in the final list
  local -a CIDR_ARRAY=()
  local raw norm
  IFS=',' read -ra _raw_cidrs <<< "$NAT_CIDRS"
  for raw in "${_raw_cidrs[@]}"; do
    raw=$(tr -d ' ' <<< "$raw")
    [[ -z "$raw" ]] && continue
    norm=$(normalize_cidr "$raw")   # dies on invalid format
    CIDR_ARRAY+=("$norm")
    log "  CIDR: $norm"
  done
  [[ ${#CIDR_ARRAY[@]} -eq 0 ]] && die "No valid CIDRs to configure."

  # ── Packages ──────────────────────────────────────────────────────────────────
  install_packages "$os_family"

  # ── Resolve conntrack module ──────────────────────────────────────────────────
  if $DRY_RUN; then
    _CONNTRACK_MODULE="conntrack"
    # shellcheck disable=SC2054
    _CONNTRACK_ARGS=(-m conntrack --ctstate RELATED,ESTABLISHED)
  else
    resolve_conntrack_module
  fi

  # ── Backup current iptables state ─────────────────────────────────────────────
  backup_iptables
  # From this point forward, on any error the ERR trap sets _ROLLBACK_NEEDED=true
  # and on_exit() calls do_rollback().
  _ROLLBACK_NEEDED=true

  # ── IP forwarding ──────────────────────────────────────────────────────────────
  enable_ip_forwarding

  # ── iptables rules ────────────────────────────────────────────────────────────
  section "iptables rules"
  log "Flushing stale '${RULE_TAG}' rules from previous runs..."
  if ! $DRY_RUN; then
    flush_script_rules "$NAT_IFACE"
  else
    run echo "flush_script_rules $NAT_IFACE"
  fi

  log "Applying NAT rules..."
  apply_nat_rules "$NAT_IFACE" "${CIDR_ARRAY[@]}"

  # ── Verify ────────────────────────────────────────────────────────────────────
  section "Verification"
  verify_rules "$NAT_IFACE" "${CIDR_ARRAY[@]}"

  # ── Persistence ───────────────────────────────────────────────────────────────
  persist_rules "$os_family"

  # All changes applied successfully — no rollback needed on exit
  _ROLLBACK_NEEDED=false

  # ── Summary ───────────────────────────────────────────────────────────────────
  echo
  log "════════════════════════════════════════════════════"
  log "  NAT Gateway configuration complete"
  log "════════════════════════════════════════════════════"
  log "  Version    : ${SCRIPT_VERSION}"
  log "  OS family  : ${os_family}"
  log "  Interface  : ${NAT_IFACE}"
  log "  CIDRs      : ${CIDR_ARRAY[*]}"
  log "  Forwarding : enabled  (${SYSCTL_CONF})"
  log "  Rules tag  : '${RULE_TAG}'  (idempotent re-runs)"
  log "  Module     : xt_${_CONNTRACK_MODULE}"
  [[ -n "$_BACKUP_FILE" ]] && \
  log "  Backup     : ${_BACKUP_FILE}"
  $IS_EC2 && \
  log "  AWS EC2    : !! disable Source/Dest check (see above) !!"
  log "════════════════════════════════════════════════════"
  log "  Verify  :  sudo $0 --status"
  log "  Re-run  :  sudo $0        (idempotent)"
  log "  Undo    :  sudo $0 --uninstall"
  log "════════════════════════════════════════════════════"

  show_client_setup
}

main "$@"
