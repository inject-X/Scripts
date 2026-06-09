#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  printf '%s\n' 'Error: this script requires bash. Install bash and retry.' >&2
  exit 1
fi

set -euo pipefail

APP_NAME="shadowsocks-libev"
DEFAULT_METHOD="chacha20-ietf-poly1305"
DEFAULT_SS_PORT="8388"
DEFAULT_SHADOW_TLS_PORT="443"
DEFAULT_TIMEOUT="300"
DEFAULT_SNI="gateway.icloud.com"
DEFAULT_UDP="true"
DEFAULT_FAST_OPEN="true"
CURL_CONNECT_TIMEOUT="2"
CURL_MAX_TIME="4"

CONFIG_DIR="/etc/shadowsocks-libev"
SS_CONFIG="${CONFIG_DIR}/config.json"
SNIPPETS_FILE="${CONFIG_DIR}/client-snippets.txt"
COMMANDS_FILE="${CONFIG_DIR}/commands.txt"
MODE_FILE="${CONFIG_DIR}/setup-mode"
SHADOW_TLS_CONFIG="${CONFIG_DIR}/shadow-tls.json"
SHADOW_TLS_BIN="/usr/local/bin/shadow-tls"
SHADOW_TLS_SERVICE="/etc/systemd/system/shadow-tls.service"
PUBLIC_HOSTS=()
TMP_FILES=()
APT_UPDATED="false"

SYSTEM_DISTRO_LABEL="unknown"
SYSTEM_DISTRO_ID=""
SYSTEM_DISTRO_LIKE=""
SYSTEM_DISTRO_FAMILY="unknown"
SYSTEM_KERNEL="unknown"
SYSTEM_ARCH="unknown"
SYSTEM_CPU_CORES="unknown"
SYSTEM_MEMORY_TOTAL="unknown"
SYSTEM_DISK_ROOT="unknown"
PREFLIGHT_DEPENDENCY_STATUS="not checked"

UI_RESET=""
UI_BOLD=""
UI_PRIMARY=""
UI_ACCENT=""
UI_OK=""
UI_WARN=""
UI_ERROR=""
UI_MUTED=""

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  UI_RESET=$'\033[0m'
  UI_BOLD=$'\033[1m'
  UI_PRIMARY=$'\033[38;5;37m'
  UI_ACCENT=$'\033[38;5;67m'
  UI_OK=$'\033[38;5;42m'
  UI_WARN=$'\033[38;5;214m'
  UI_ERROR=$'\033[38;5;203m'
  UI_MUTED=$'\033[38;5;245m'
fi

log() {
  wizard_title "$*"
}

section() {
  wizard_section "$1"
}

option() {
  wizard_menu_option "$1" "$2"
}

prompt_line() {
  printf '%b?%b %s' "${UI_BOLD}${UI_PRIMARY}" "$UI_RESET" "$1" >&2
}

info() {
  printf '  %b[INFO]%b %s\n' "$UI_PRIMARY" "$UI_RESET" "$*" >&2
}

warn() {
  printf '  %b[WARN]%b %s\n' "$UI_WARN" "$UI_RESET" "$*" >&2
}

die() {
  printf '  %b[ERR]%b %s\n' "$UI_ERROR" "$UI_RESET" "$*" >&2
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

append_unique() {
  local value="$1"
  shift
  local existing
  for existing in "$@"; do
    [ "$existing" = "$value" ] && return 1
  done
  printf '%s\n' "$value"
}

run_sudo() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$@"
  else
    have_cmd sudo || die "sudo is required for system-level operations. Install sudo or switch to root."
    sudo "$@"
  fi
}

run_apt_get_quiet() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get "$@" >/dev/null 2>&1
  else
    have_cmd sudo || die "sudo is required for system-level operations. Install sudo or switch to root."
    sudo env DEBIAN_FRONTEND=noninteractive apt-get "$@" >/dev/null 2>&1
  fi
}

apt_update_quiet_once() {
  [ "$APT_UPDATED" = "true" ] && return 0
  info "Refreshing package indexes..."
  if ! run_apt_get_quiet -qq update; then
    die "apt-get update failed. Check the network or package sources."
  fi
  APT_UPDATED="true"
}

install_packages_quiet() {
  [ "$#" -gt 0 ] || return 0
  apt_update_quiet_once
  info "Installing: $*"
  if ! run_apt_get_quiet -y -qq install "$@"; then
    die "Installation failed: $*. Check the package sources or network."
  fi
}

package_for_command() {
  case "$1" in
    curl) printf 'curl' ;;
    wget) printf 'wget' ;;
    openssl) printf 'openssl' ;;
    python3) printf 'python3' ;;
    awk) printf 'gawk' ;;
    sed) printf 'sed' ;;
    grep) printf 'grep' ;;
    dpkg) printf 'dpkg' ;;
    systemctl|journalctl) printf 'systemd' ;;
    base64|cat|date|dd|dirname|head|install|mktemp|rm|tr) printf 'coreutils' ;;
    *) return 1 ;;
  esac
}

detect_system_profile() {
  local name=""
  local version=""
  local pretty_name=""
  local id=""
  local id_like=""

  SYSTEM_KERNEL="$(uname -sr 2>/dev/null || printf 'unknown')"
  SYSTEM_ARCH="$(uname -m 2>/dev/null || printf 'unknown')"

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    name="${NAME:-}"
    version="${VERSION_ID:-}"
    pretty_name="${PRETTY_NAME:-}"
    id="${ID:-}"
    id_like="${ID_LIKE:-}"
  fi

  SYSTEM_DISTRO_ID="$id"
  SYSTEM_DISTRO_LIKE="$id_like"
  if [ -n "$pretty_name" ]; then
    SYSTEM_DISTRO_LABEL="$pretty_name"
  elif [ -n "$name" ]; then
    SYSTEM_DISTRO_LABEL="${name}${version:+ ${version}}"
  else
    SYSTEM_DISTRO_LABEL="Unknown Linux distribution"
  fi

  case " ${id} ${id_like} " in
    *ubuntu*) SYSTEM_DISTRO_FAMILY="Ubuntu" ;;
    *debian*) SYSTEM_DISTRO_FAMILY="Debian" ;;
    *) SYSTEM_DISTRO_FAMILY="unknown" ;;
  esac

  if have_cmd getconf; then
    SYSTEM_CPU_CORES="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  fi
  if [ -z "$SYSTEM_CPU_CORES" ] || [ "$SYSTEM_CPU_CORES" = "unknown" ]; then
    SYSTEM_CPU_CORES="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
  fi
  [ -n "$SYSTEM_CPU_CORES" ] || SYSTEM_CPU_CORES="unknown"

  if [ -r /proc/meminfo ]; then
    SYSTEM_MEMORY_TOTAL="$(awk '/MemTotal/ { printf "%.1f GB", $2 / 1024 / 1024 }' /proc/meminfo 2>/dev/null || true)"
  fi
  if [ -z "$SYSTEM_MEMORY_TOTAL" ] && have_cmd free; then
    SYSTEM_MEMORY_TOTAL="$(free -h 2>/dev/null | awk '/^Mem:/ { print $2 }' || true)"
  fi
  [ -n "$SYSTEM_MEMORY_TOTAL" ] || SYSTEM_MEMORY_TOTAL="unknown"

  if have_cmd df; then
    SYSTEM_DISK_ROOT="$(df -h / 2>/dev/null | awk 'NR == 2 { print $2 " total, " $4 " available" }' || true)"
  fi
  [ -n "$SYSTEM_DISK_ROOT" ] || SYSTEM_DISK_ROOT="unknown"
}

require_linux_debian_systemd() {
  local kernel
  kernel="$(uname -s 2>/dev/null || true)"
  [ "$kernel" = "Linux" ] || die "This script only supports Linux Debian/Ubuntu VPS servers."

  case " ${SYSTEM_DISTRO_ID} ${SYSTEM_DISTRO_LIKE} " in
    *debian*|*ubuntu*) ;;
    *)
      have_cmd apt-get || die "This Linux distribution is not Debian/Ubuntu based and apt-get was not found."
      warn "The distribution was not recognized as Debian/Ubuntu, but apt-get was found. Continuing with Debian/Ubuntu behavior."
      ;;
  esac

  have_cmd systemctl || die "systemctl was not found. Shadow-TLS service management requires systemd."
}

require_admin_access() {
  [ "${EUID:-$(id -u)}" -eq 0 ] && return 0
  have_cmd sudo || die "root or sudo is required for system-level operations. Install sudo or switch to root."
}

ensure_required_tools() {
  local required_commands
  local required_packages
  local missing_packages=()
  local cmd
  local package
  local added
  local verified="true"

  PREFLIGHT_DEPENDENCY_STATUS="satisfied"

  required_commands="apt-get systemctl journalctl dpkg curl wget openssl python3 awk sed grep base64 cat date dd dirname head install mktemp rm tr"
  required_packages="ca-certificates"

  for cmd in $required_commands; do
    if ! have_cmd "$cmd"; then
      package="$(package_for_command "$cmd" || true)"
      if [ -n "$package" ]; then
        added="$(append_unique "$package" "${missing_packages[@]:-}" || true)"
        [ -n "$added" ] && missing_packages[${#missing_packages[@]}]="$added"
      fi
    fi
  done

  for package in $required_packages; do
    if ! dpkg -s "$package" >/dev/null 2>&1; then
      added="$(append_unique "$package" "${missing_packages[@]:-}" || true)"
      [ -n "$added" ] && missing_packages[${#missing_packages[@]}]="$added"
    fi
  done

  if [ "${#missing_packages[@]}" -gt 0 ]; then
    info "Missing dependencies detected: ${missing_packages[*]}"
    info "Installing missing dependencies..."
    install_packages_quiet "${missing_packages[@]}"
    PREFLIGHT_DEPENDENCY_STATUS="installed: ${missing_packages[*]}"
  fi

  for cmd in $required_commands; do
    if ! have_cmd "$cmd"; then
      warn "Missing command: ${cmd}"
      verified="false"
    fi
  done
  [ "$verified" = "true" ] || die "Commands are still missing after dependency installation. Check the system environment."
  [ "${#missing_packages[@]}" -gt 0 ] && info "Missing dependencies have been installed."
  return 0
}

preflight_privilege_label() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    printf 'root'
  else
    printf 'sudo available'
  fi
}

preflight_config_dir_label() {
  if [ -d "$CONFIG_DIR" ]; then
    printf 'already exists: %s' "$CONFIG_DIR"
  else
    printf 'created automatically during installation: %s' "$CONFIG_DIR"
  fi
}

show_preflight_summary() {
  wizard_title "Startup Check"
  wizard_line ok "Platform" "Linux + Debian/Ubuntu family + systemd"
  wizard_line ok "Privileges" "$(preflight_privilege_label)"
  wizard_line ok "Package manager" "apt-get available"
  wizard_line ok "Required commands" "$PREFLIGHT_DEPENDENCY_STATUS"
  wizard_line info "Config directory" "$(preflight_config_dir_label)"
  wizard_line info "Result" "Ready to install or manage configuration"
}

run_preflight() {
  local show_summary="${1:-false}"
  [ "$show_summary" = "true" ] && info "Running environment preflight checks..."
  detect_system_profile
  require_linux_debian_systemd
  require_admin_access
  ensure_required_tools
  [ "$show_summary" = "true" ] && show_preflight_summary
  [ "$show_summary" = "true" ] && info "Environment preflight checks passed."
  return 0
}

ensure_config_dir() {
  run_sudo mkdir -p "$CONFIG_DIR"
}

install_managed_file() {
  local src="$1"
  local dest="$2"
  local mode="${3:-600}"
  run_sudo mkdir -p "$(dirname "$dest")"
  run_sudo install -m "$mode" "$src" "$dest"
}

cleanup_tmp_files() {
  local tmp
  for tmp in "${TMP_FILES[@]:-}"; do
    rm -f "$tmp" 2>/dev/null || true
  done
}
trap cleanup_tmp_files EXIT

new_tmp_file() {
  local tmp
  tmp="$(mktemp)"
  TMP_FILES[${#TMP_FILES[@]}]="$tmp"
  printf '%s\n' "$tmp"
}

bool_default_choice() {
  case "$1" in
    true) printf 'y' ;;
    *) printf 'n' ;;
  esac
}

systemd_exec_arg_escape() {
  local s="$1"
  s=${s//%/%%}
  printf '%s' "$s"
}

is_port() {
  local port="$1"
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

prompt_text() {
  local label="$1"
  local default="${2:-}"
  local value
  if [ -n "$default" ]; then
    prompt_line "${label} [${default}]: "
  else
    prompt_line "${label}: "
  fi
  read -r value
  if [ -z "$value" ]; then
    value="$default"
  fi
  printf '%s\n' "$value"
}

prompt_secret() {
  local label="$1"
  local value
  prompt_line "${label} (leave blank to auto-generate): "
  read -r -s value
  printf '\n' >&2
  if [ -z "$value" ]; then
    value="$(generate_password)"
    info "Password generated automatically."
  fi
  printf '%s\n' "$value"
}

prompt_shadow_tls_secret() {
  local value
  while true; do
    value="$(prompt_secret "Enter Shadow-TLS password")"
    case "$value" in
      *[[:space:]]*) warn "Shadow-TLS password cannot contain whitespace." ;;
      *) printf '%s\n' "$value"; return 0 ;;
    esac
  done
}

prompt_sni() {
  local default="$1"
  local value
  while true; do
    value="$(prompt_text "Shadow-TLS SNI" "$default")"
    case "$value" in
      ''|*[[:space:]]*) warn "Shadow-TLS SNI cannot be empty or contain whitespace." ;;
      *) printf '%s\n' "$value"; return 0 ;;
    esac
  done
}

prompt_port() {
  local label="$1"
  local default="$2"
  local value
  while true; do
    value="$(prompt_text "$label" "$default")"
    if is_port "$value"; then
      printf '%s\n' "$value"
      return 0
    fi
    warn "Port must be a number from 1 to 65535."
  done
}

prompt_yes_no() {
  local label="$1"
  local default="${2:-y}"
  local answer
  local hint
  if [ "$default" = "y" ]; then
    hint="Y/n, default Y"
  else
    hint="y/N, default N"
  fi
  while true; do
    prompt_line "${label} [${hint}]: "
    read -r answer
    answer="${answer:-$default}"
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) warn "Enter y or n." ;;
    esac
  done
}

choose_method() {
  local choice
  log "Choose encryption method"
  option "1" "chacha20-ietf-poly1305 (recommended)"
  option "2" "aes-128-gcm"
  option "3" "aes-256-gcm"
  option "4" "Custom"
  while true; do
    prompt_line "Choose an option (default 1: chacha20-ietf-poly1305): "
    read -r choice
    choice="${choice:-1}"
    case "$choice" in
      1) printf '%s\n' "$DEFAULT_METHOD"; return 0 ;;
      2) printf 'aes-128-gcm\n'; return 0 ;;
      3) printf 'aes-256-gcm\n'; return 0 ;;
      4) prompt_text "Enter custom method" "$DEFAULT_METHOD"; return 0 ;;
      *) warn "Enter 1-4." ;;
    esac
  done
}

generate_password() {
  if have_cmd openssl; then
    openssl rand -base64 24 | tr -d '\n'
  elif have_cmd dd && have_cmd base64; then
    dd if=/dev/urandom bs=24 count=1 2>/dev/null | base64 | tr -d '\n'
  else
    printf '%s-%s' "$(date +%s)" "$RANDOM"
  fi
}

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

json_string_array() {
  local first="true"
  local item
  printf '['
  for item in "$@"; do
    if [ "$first" = "true" ]; then
      first="false"
    else
      printf ', '
    fi
    printf '"%s"' "$(json_escape "$item")"
  done
  printf ']'
}

yaml_double_quote() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/ }
  printf '"%s"' "$s"
}

surge_double_quote() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\r'/ }
  s=${s//$'\n'/ }
  printf '"%s"' "$s"
}

url_encode_component() {
  local raw="$1"
  if have_cmd python3; then
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$raw"
  elif have_cmd perl; then
    perl -MURI::Escape -e 'print uri_escape($ARGV[0])' "$raw"
  else
    raw=${raw// /%20}
    raw=${raw//#/%23}
    raw=${raw//\?/%3F}
    raw=${raw//&/%26}
    printf '%s' "$raw"
  fi
}

base64_nopad() {
  printf '%s' "$1" | base64 | tr -d '\n='
}

base64url_nopad() {
  printf '%s' "$1" | base64 | tr -d '\n=' | tr '+/' '-_'
}

format_uri_host() {
  local host="$1"
  case "$host" in
    \[*\]) printf '%s' "$host" ;;
    *:*) printf '[%s]' "$host" ;;
    *) printf '%s' "$host" ;;
  esac
}

valid_ipv4() {
  local ip="$1"
  case "$ip" in
    *.*.*.*) printf '%s' "$ip" | awk -F. 'NF == 4 { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1; exit 0 } { exit 1 }' ;;
    *) return 1 ;;
  esac
}

valid_ipv6() {
  local ip="$1"
  ip="${ip#\[}"
  ip="${ip%\]}"
  if have_cmd python3; then
    python3 -c 'import ipaddress, sys
try:
    addr = ipaddress.ip_address(sys.argv[1])
except ValueError:
    sys.exit(1)
sys.exit(0 if addr.version == 6 else 1)' "$ip" 2>/dev/null
  else
    case "$ip" in
      *:*) return 0 ;;
      *) return 1 ;;
    esac
  fi
}

valid_domain_or_host() {
  local host="$1"
  local plain_host
  [ -n "$host" ] || return 1
  case "$host" in
    *[[:space:]]*) return 1 ;;
  esac
  plain_host="${host#\[}"
  plain_host="${plain_host%\]}"
  valid_ipv4 "$plain_host" && return 0
  valid_ipv6 "$plain_host" && return 0
  case "$host" in
    *[!A-Za-z0-9.-]*|.*|*..*|*.) return 1 ;;
  esac
  printf '%s' "$host" | awk 'length($0) <= 253 && $0 ~ /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/ { n=split($0, a, "."); for (i = 1; i <= n; i++) if (a[i] == "" || length(a[i]) > 63 || a[i] ~ /^-/ || a[i] ~ /-$/) exit 1; exit 0 } { exit 1 }'
}

query_public_ip() {
  local family="$1"
  local url
  local ip
  have_cmd curl || return 1
  for url in "https://api64.ipify.org" "https://ifconfig.co/ip"; do
    if [ "$family" = "4" ]; then
      ip="$(curl -4fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" "$url" 2>/dev/null | tr -d '[:space:]' || true)"
      valid_ipv4 "$ip" && printf '%s\n' "$ip" && return 0
    else
      ip="$(curl -6fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" "$url" 2>/dev/null | tr -d '[:space:]' || true)"
      valid_ipv6 "$ip" && printf '%s\n' "$ip" && return 0
    fi
  done
  return 1
}

detect_public_hosts() {
  local ipv4=""
  local ipv6=""
  ipv4="$(query_public_ip 4 || true)"
  ipv6="$(query_public_ip 6 || true)"

  if [ -n "$ipv4" ]; then
    info "Detected public IPv4: ${ipv4}"
  else
    warn "No public IPv4 detected."
  fi

  if [ -n "$ipv6" ]; then
    info "Detected public IPv6: ${ipv6}"
  else
    warn "No public IPv6 detected."
  fi

  if [ -n "$ipv4" ]; then
    printf '%s\n' "$ipv4"
  fi
  if [ -n "$ipv6" ]; then
    printf '%s\n' "$ipv6"
  fi
  [ -n "$ipv4" ] || [ -n "$ipv6" ]
}

append_public_host() {
  local host="$1"
  local existing
  [ -n "$host" ] || return 0
  valid_domain_or_host "$host" || { warn "Skipping invalid public address: ${host}"; return 0; }
  for existing in "${PUBLIC_HOSTS[@]:-}"; do
    [ "$existing" = "$host" ] && return 0
  done
  PUBLIC_HOSTS[${#PUBLIC_HOSTS[@]}]="$host"
}

prompt_public_hosts() {
  local detected
  local host
  local manual
  PUBLIC_HOSTS=()

  log "Query public IPv4 / IPv6 for client configuration generation."
  detected="$(detect_public_hosts || true)"
  while IFS= read -r host; do
    append_public_host "$host"
  done <<EOF
$detected
EOF

  if [ "${#PUBLIC_HOSTS[@]}" -gt 0 ]; then
    info "Leave blank to use the detected public addresses. To override, enter IPs/domains separated by spaces."
  else
    warn "Could not query a public IPv4 or IPv6 automatically."
    info "You can enter server IPs/domains manually. Leave blank to generate only the server-side configuration and skip client configs."
  fi

  manual="$(prompt_text "Public IP or domain" "")"
  if [ -n "$manual" ]; then
    PUBLIC_HOSTS=()
    for host in $manual; do
      append_public_host "$host"
    done
  fi
}

mode_value() {
  local udp="$1"
  if [ "$udp" = "true" ]; then
    printf 'tcp_and_udp'
  else
    printf 'tcp_only'
  fi
}

udp_label() {
  local udp="$1"
  if [ "$udp" = "true" ]; then
    printf 'enabled'
  else
    printf 'disabled'
  fi
}

install_shadowsocks() {
  log "Install / check ${APP_NAME}"
  install_packages_quiet shadowsocks-libev
  command -v ss-server >/dev/null 2>&1 || die "ss-server command was not found. ${APP_NAME} may not be installed completely."
  info "${APP_NAME} is ready."
}

ensure_shadowsocks() {
  if dpkg -s shadowsocks-libev >/dev/null 2>&1 && command -v ss-server >/dev/null 2>&1; then
    info "${APP_NAME} is already installed."
  else
    install_shadowsocks
  fi
}

write_ss_config() {
  local listen_mode="$1"
  local port="$2"
  local password="$3"
  local method="$4"
  local udp="$5"
  local tmp
  local server_value

  if [ "$listen_mode" = "local" ]; then
    server_value="$(json_string_array "::1" "127.0.0.1")"
  else
    server_value="$(json_string_array "::" "0.0.0.0")"
  fi

  tmp="$(new_tmp_file)"
  cat >"$tmp" <<EOF
{
  "server": ${server_value},
  "server_port": ${port},
  "password": "$(json_escape "$password")",
  "method": "$(json_escape "$method")",
  "timeout": ${DEFAULT_TIMEOUT},
  "mode": "$(mode_value "$udp")",
  "fast_open": false
}
EOF
  install_managed_file "$tmp" "$SS_CONFIG" 644
  rm -f "$tmp"
  info "Shadowsocks configuration written: ${SS_CONFIG}"
}

write_mode_file() {
  local mode="$1"
  local tmp
  tmp="$(new_tmp_file)"
  printf '%s\n' "$mode" >"$tmp"
  install_managed_file "$tmp" "$MODE_FILE" 644
  rm -f "$tmp"
}

read_mode() {
  local mode=""
  if [ -f "$MODE_FILE" ]; then
    if [ -r "$MODE_FILE" ]; then
      mode="$(tr -d '[:space:]' <"$MODE_FILE" 2>/dev/null || true)"
    else
      mode="$(run_sudo cat "$MODE_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
    fi
  fi
  if [ -n "$mode" ]; then
    printf '%s\n' "$mode"
  else
    printf 'ss-tls\n'
  fi
}

get_json_value() {
  local key="$1"
  local file="$2"
  if [ ! -f "$file" ]; then
    return 1
  fi
  if have_cmd python3; then
    if [ -r "$file" ]; then
      python3 -c 'import json, sys; data=json.load(open(sys.argv[2])); value=data.get(sys.argv[1], ""); print(("true" if value else "false") if isinstance(value, bool) else (value if not isinstance(value, (list, dict)) else ""))' "$key" "$file" 2>/dev/null || true
    else
      run_sudo python3 -c 'import json, sys; data=json.load(open(sys.argv[2])); value=data.get(sys.argv[1], ""); print(("true" if value else "false") if isinstance(value, bool) else (value if not isinstance(value, (list, dict)) else ""))' "$key" "$file" 2>/dev/null || true
    fi
  else
    return 1
  fi
}

get_ss_port() {
  local port=""
  port="$(get_json_value server_port "$SS_CONFIG" || true)"
  if is_port "$port"; then
    printf '%s\n' "$port"
  else
    printf '%s\n' "$DEFAULT_SS_PORT"
  fi
}

get_ss_password() {
  get_json_value password "$SS_CONFIG" || true
}

get_ss_method() {
  local method=""
  method="$(get_json_value method "$SS_CONFIG" || true)"
  if [ -n "$method" ]; then
    printf '%s\n' "$method"
  else
    printf '%s\n' "$DEFAULT_METHOD"
  fi
}

get_tls_port() {
  local detected=""
  detected="$(get_json_value listen_port "$SHADOW_TLS_CONFIG" || true)"
  if ! is_port "$detected" && [ -f "$SHADOW_TLS_SERVICE" ]; then
    detected="$(grep -oE -- '--listen [^ ]+' "$SHADOW_TLS_SERVICE" 2>/dev/null | head -n1 | awk -F: '{print $NF}' || true)"
  fi
  if is_port "$detected"; then
    printf '%s\n' "$detected"
  else
    printf '%s\n' "$DEFAULT_SHADOW_TLS_PORT"
  fi
}

get_tls_password() {
  local password=""
  password="$(get_json_value password "$SHADOW_TLS_CONFIG" || true)"
  if [ -n "$password" ]; then
    printf '%s\n' "$password"
  elif [ -f "$SHADOW_TLS_SERVICE" ]; then
    grep -oE -- '--password [^[:space:]]+' "$SHADOW_TLS_SERVICE" 2>/dev/null | head -n1 | awk '{print $2}' || true
  fi
}

get_tls_sni() {
  local sni=""
  sni="$(get_json_value tls_sni "$SHADOW_TLS_CONFIG" || true)"
  if [ -z "$sni" ] && [ -f "$SHADOW_TLS_SERVICE" ]; then
    sni="$(grep -oE -- '--tls [^[:space:]]+' "$SHADOW_TLS_SERVICE" 2>/dev/null | head -n1 | awk '{print $2}' || true)"
  fi
  if [ -n "$sni" ]; then
    printf '%s\n' "$sni"
  else
    printf '%s\n' "$DEFAULT_SNI"
  fi
}

detect_shadow_tls_binary_name() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) printf 'shadow-tls-x86_64-unknown-linux-musl\n' ;;
    aarch64|arm64) printf 'shadow-tls-aarch64-unknown-linux-musl\n' ;;
    *) die "Unsupported architecture: ${arch}. Supported: x86_64, aarch64/arm64." ;;
  esac
}

install_shadow_tls_binary() {
  local binary
  local url
  local tmp
  binary="$(detect_shadow_tls_binary_name)"
  url="https://github.com/ihciah/shadow-tls/releases/latest/download/${binary}"

  log "Install Shadow-TLS"

  tmp="$(new_tmp_file)"
  info "Downloading ${binary}"
  wget -q "$url" -O "$tmp"
  install_managed_file "$tmp" "$SHADOW_TLS_BIN" 755
  rm -f "$tmp"
  info "Shadow-TLS installed: ${SHADOW_TLS_BIN}"
}

ensure_shadow_tls() {
  if [ -x "$SHADOW_TLS_BIN" ]; then
    info "Shadow-TLS is already installed."
  else
    install_shadow_tls_binary
  fi
}

install_shadowsocks_only() {
  ensure_shadowsocks
  info "shadowsocks-libev installation check completed."
}

install_shadow_tls_only() {
  ensure_shadow_tls
  info "shadow-tls installation check completed."
}

write_shadow_tls_config() {
  local tls_port="$1"
  local backend_port="$2"
  local sni="$3"
  local tls_password="$4"
  local fast_open="$5"
  local tmp
  tmp="$(new_tmp_file)"
  cat >"$tmp" <<EOF
{
  "listen_port": ${tls_port},
  "backend": "127.0.0.1:${backend_port}",
  "tls_sni": "$(json_escape "$sni")",
  "password": "$(json_escape "$tls_password")",
  "fast_open": ${fast_open}
}
EOF
  install_managed_file "$tmp" "$SHADOW_TLS_CONFIG" 600
  rm -f "$tmp"
  info "Shadow-TLS configuration written: ${SHADOW_TLS_CONFIG}"
}

write_shadow_tls_service() {
  local tls_port="$1"
  local backend_port="$2"
  local sni="$3"
  local tls_password="$4"
  local fast_open="$5"
  local fast_open_arg=""
  local sni_arg
  local password_arg
  local tmp

  if [ "$fast_open" = "true" ]; then
    fast_open_arg="--fastopen "
  fi
  sni_arg="$(systemd_exec_arg_escape "$sni")"
  password_arg="$(systemd_exec_arg_escape "$tls_password")"

  tmp="$(new_tmp_file)"
  cat >"$tmp" <<EOF
[Unit]
Description=Shadow-TLS Server Service
Documentation=https://github.com/ihciah/shadow-tls
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SHADOW_TLS_BIN} ${fast_open_arg}--v3 server --listen ::0:${tls_port} --server 127.0.0.1:${backend_port} --tls ${sni_arg} --password ${password_arg}
StandardOutput=journal
StandardError=journal
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  install_managed_file "$tmp" "$SHADOW_TLS_SERVICE" 644
  rm -f "$tmp"
  write_shadow_tls_config "$tls_port" "$backend_port" "$sni" "$tls_password" "$fast_open"
  run_sudo systemctl daemon-reload
  info "Shadow-TLS systemd service written: ${SHADOW_TLS_SERVICE}"
}

start_ss_service() {
  run_sudo systemctl restart shadowsocks-libev
  if systemctl is-enabled --quiet shadowsocks-libev 2>/dev/null; then
    info "shadowsocks-libev started and enabled at boot."
  else
    if run_sudo systemctl enable shadowsocks-libev >/dev/null 2>&1; then
      info "shadowsocks-libev started and enabled at boot."
    else
      warn "shadowsocks-libev started, but enabling it at boot failed. Run systemctl enable shadowsocks-libev manually for details."
    fi
  fi
}

start_shadow_tls_service() {
  [ -f "$SHADOW_TLS_SERVICE" ] || die "Shadow-TLS service file does not exist: ${SHADOW_TLS_SERVICE}"
  run_sudo systemctl restart shadow-tls.service
  if systemctl is-enabled --quiet shadow-tls.service 2>/dev/null; then
    info "shadow-tls started and enabled at boot."
  else
    if run_sudo systemctl enable shadow-tls.service >/dev/null 2>&1; then
      info "shadow-tls started and enabled at boot."
    else
      warn "shadow-tls started, but enabling it at boot failed. Run systemctl enable shadow-tls.service manually for details."
    fi
  fi
}

stop_ss_service() {
  run_sudo systemctl stop shadowsocks-libev >/dev/null 2>&1 || true
  info "shadowsocks-libev stopped."
}

stop_shadow_tls_service() {
  run_sudo systemctl stop shadow-tls.service >/dev/null 2>&1 || true
  info "shadow-tls stopped."
}

status_services() {
  wizard_title "Service Status"
  wizard_line "$(service_state_kind shadowsocks-libev)" "Shadowsocks" "$(service_state_label shadowsocks-libev)"
  if [ -f "$SHADOW_TLS_SERVICE" ] || [ -x "$SHADOW_TLS_BIN" ]; then
    wizard_line "$(service_state_kind shadow-tls.service)" "Shadow-TLS" "$(service_state_label shadow-tls.service)"
  fi

  wizard_section "Suggested Actions"
  if ! systemctl is-active --quiet shadowsocks-libev 2>/dev/null; then
    wizard_action "Shadowsocks backend is not running: open Service Management to start / restart all services."
  fi
  if ! systemctl is-active --quiet shadow-tls.service 2>/dev/null; then
    wizard_action "Shadow-TLS is not running: open Service Management to start / restart all services."
  fi
  wizard_action "View current configuration: open View Configuration."

  wizard_section "systemctl Details"
  run_sudo systemctl status shadowsocks-libev --no-pager -l || true
  if [ -f "$SHADOW_TLS_SERVICE" ] || [ -x "$SHADOW_TLS_BIN" ]; then
    run_sudo systemctl status shadow-tls.service --no-pager -l || true
  fi
}

start_current_services() {
  start_ss_service
  start_shadow_tls_service
}

stop_current_services() {
  stop_shadow_tls_service
  stop_ss_service
}

append_client_snippet() {
  local out="$1"
  local mode="$2"
  local name="$3"
  local host="$4"
  local port="$5"
  local method="$6"
  local password="$7"
  local udp="$8"
  local fast_open="${9:-false}"
  local tls_password="${10:-}"
  local tls_sni="${11:-}"
  local uri_host
  uri_host="$(format_uri_host "$host")"

  cat >>"$out" <<EOF
## ${name}
# Server: ${uri_host}:${port}
# Method: ${method}
# Mode: ${mode}

SS Config:
SS = ss, ${host}, ${port}, encrypt-method=${method}, password=${password}, tfo=${fast_open}, udp-relay=${udp}, shadow-tls-password="${tls_password}", shadow-tls-sni=${tls_sni}, shadow-tls-version=3

Surge [Proxy]:
$(surge_double_quote "$name") = ss, ${host}, ${port}, encrypt-method=$(surge_double_quote "$method"), password=$(surge_double_quote "$password"), udp-relay=${udp}, shadow-tls-password=$(surge_double_quote "$tls_password"), shadow-tls-sni=$(surge_double_quote "$tls_sni"), shadow-tls-version=3, tfo=${fast_open}

Clash / Clash Verge / Mihomo:
# Shadow-TLS field names may differ by client. Adjust according to your client documentation.
proxies:
  - name: $(yaml_double_quote "$name")
    type: ss
    server: $(yaml_double_quote "$host")
    port: ${port}
    cipher: $(yaml_double_quote "$method")
    password: $(yaml_double_quote "$password")
    udp: ${udp}
    plugin: shadow-tls
    plugin-opts:
      host: $(yaml_double_quote "$tls_sni")
      password: $(yaml_double_quote "$tls_password")
      version: 3

sing-box outbound:
{
  "type": "shadowsocks",
  "tag": "$(json_escape "$name")",
  "server": "$(json_escape "$host")",
  "server_port": ${port},
  "method": "$(json_escape "$method")",
  "password": "$(json_escape "$password")",
  "plugin": "shadow-tls",
  "plugin_opts": "v3;host=$(json_escape "$tls_sni");password=$(json_escape "$tls_password")"
}

EOF
}

write_client_snippets() {
  local mode="$1"
  local name="$2"
  local public_port="$3"
  local method="$4"
  local password="$5"
  local udp="$6"
  local fast_open="${7:-false}"
  local tls_password="${8:-}"
  local tls_sni="${9:-}"
  local tmp
  local host
  local label
  tmp="$(new_tmp_file)"
  cat >"$tmp" <<EOF
# Generated by shadowsocks-shadowtls-setup.sh
# Mode: ${mode}
# Profile: ${name}
# Method: ${method}

EOF
  shift 9 || true
  for host in "$@"; do
    if valid_ipv6 "$host"; then
      label="${name} IPv6"
    elif valid_ipv4 "$host"; then
      label="${name} IPv4"
    else
      label="$name"
    fi
    append_client_snippet "$tmp" "$mode" "$label" "$host" "$public_port" "$method" "$password" "$udp" "$fast_open" "$tls_password" "$tls_sni"
  done
  install_managed_file "$tmp" "$SNIPPETS_FILE" 600
  rm -f "$tmp"
  info "Client configuration written: ${SNIPPETS_FILE}"
}

write_commands_file() {
  local tmp
  tmp="$(new_tmp_file)"
  cat >"$tmp" <<EOF
# shadowsocks-libev / Shadow-TLS common commands

Config directory:
  ${CONFIG_DIR}

Usage:
  Run this script directly and choose actions from the menu.

Main menu:
  1. Install
  2. View configuration
  3. Modify configuration
  4. Service management
  5. Log troubleshooting
  6. Uninstall
  0. Exit
EOF
  install_managed_file "$tmp" "$COMMANDS_FILE" 644
  rm -f "$tmp"
}

print_summary_ss_tls() {
  local ss_port="$1"
  local tls_port="$2"
  local method="$3"
  local udp="$4"
  local sni="$5"
  local fast_open="${6:-false}"
  wizard_title "Configuration Complete"
  wizard_line ok "Mode" "SS + Shadow-TLS v3"
  wizard_line info "SS backend" "[\"::1\", \"127.0.0.1\"]:${ss_port}"
  wizard_line info "TLS public" "::0:${tls_port}"
  wizard_line info "SNI" "$sni"
  wizard_line info "Method" "$method"
  wizard_line info "UDP relay" "$(bool_label "$udp")"
  wizard_line info "Shadow-TLS FastOpen" "$(bool_label "$fast_open")"
  wizard_line info "SS config" "$SS_CONFIG"
  wizard_line info "TLS config" "$SHADOW_TLS_CONFIG"
  wizard_line info "TLS service" "$SHADOW_TLS_SERVICE"
  [ -f "$SNIPPETS_FILE" ] && wizard_line info "Client config" "$SNIPPETS_FILE"

  wizard_section "Next Steps"
  wizard_action "Confirm your cloud security group/firewall allows TCP ${tls_port}."
  wizard_action "The SS backend port ${ss_port} only listens locally and usually should not be exposed publicly."
  wizard_action "View status: open Service Management."
  wizard_action "Show client configuration: open View Configuration."
}

configure_ss_tls() {
  local ss_port
  local tls_port
  local method
  local ss_password
  local tls_password
  local sni
  local fast_open
  local udp
  local name

  ensure_shadowsocks
  ensure_shadow_tls
  ensure_config_dir

  ss_port="$(prompt_port "SS backend listen port" "$(get_ss_port)")"
  method="$(choose_method)"
  ss_password="$(prompt_secret "Enter Shadowsocks password")"
  udp="$DEFAULT_UDP"
  info "UDP relay is enabled by default in SS + Shadow-TLS mode."

  tls_port="$(prompt_port "Shadow-TLS public listen port" "$(get_tls_port)")"
  tls_password="$(prompt_shadow_tls_secret)"
  sni="$(prompt_sni "$(get_tls_sni)")"
  if prompt_yes_no "Enable Shadow-TLS fastopen?" "$(bool_default_choice "$DEFAULT_FAST_OPEN")"; then
    fast_open="true"
  else
    fast_open="false"
  fi
  name="$(prompt_text "Profile name" "shadowsocks-shadowtls")"
  prompt_public_hosts

  write_ss_config "local" "$ss_port" "$ss_password" "$method" "$udp"
  write_shadow_tls_service "$tls_port" "$ss_port" "$sni" "$tls_password" "$fast_open"
  write_mode_file "ss-tls"
  if [ "${#PUBLIC_HOSTS[@]}" -gt 0 ]; then
    write_client_snippets "ss-tls" "$name" "$tls_port" "$method" "$ss_password" "$udp" "$fast_open" "$tls_password" "$sni" "${PUBLIC_HOSTS[@]}"
  else
    warn "Client configuration was not generated. You can reconfigure later and enter a public IP/domain."
  fi
  write_commands_file

  if prompt_yes_no "Start now and enable at boot?" "y"; then
    start_ss_service
    start_shadow_tls_service
  fi
  print_summary_ss_tls "$ss_port" "$tls_port" "$method" "$udp" "$sni" "$fast_open"
}

configure_tls_only() {
  local ss_port
  local tls_port
  local tls_password
  local sni
  local fast_open
  local method
  local ss_password
  local udp="true"
  local name

  [ -f "$SS_CONFIG" ] || die "SS configuration was not found: ${SS_CONFIG}. Install and configure SS + Shadow-TLS first."
  ensure_shadow_tls
  ss_port="$(prompt_port "SS backend port" "$(get_ss_port)")"
  tls_port="$(prompt_port "Shadow-TLS public listen port" "$(get_tls_port)")"
  tls_password="$(prompt_shadow_tls_secret)"
  sni="$(prompt_sni "$(get_tls_sni)")"
  if prompt_yes_no "Enable Shadow-TLS fastopen?" "$(bool_default_choice "$DEFAULT_FAST_OPEN")"; then
    fast_open="true"
  else
    fast_open="false"
  fi
  name="$(prompt_text "Profile name" "shadowsocks-shadowtls")"
  prompt_public_hosts

  method="$(get_ss_method)"
  ss_password="$(get_ss_password)"
  [ -n "$ss_password" ] || die "Could not read the SS password. Run the full SS + Shadow-TLS configuration again."

  write_shadow_tls_service "$tls_port" "$ss_port" "$sni" "$tls_password" "$fast_open"
  write_mode_file "ss-tls"
  if [ "${#PUBLIC_HOSTS[@]}" -gt 0 ]; then
    write_client_snippets "ss-tls" "$name" "$tls_port" "$method" "$ss_password" "$udp" "$fast_open" "$tls_password" "$sni" "${PUBLIC_HOSTS[@]}"
  fi
  write_commands_file

  if prompt_yes_no "Restart Shadow-TLS now?" "y"; then
    start_shadow_tls_service
  fi
  print_summary_ss_tls "$ss_port" "$tls_port" "$method" "$udp" "$sni" "$fast_open"
}

configure_shadowsocks_only() {
  local ss_port
  local method
  local ss_password
  local udp
  local tls_port
  local tls_password
  local sni
  local fast_open

  ensure_shadowsocks
  ensure_config_dir
  ss_port="$(prompt_port "shadowsocks-libev backend listen port" "$(get_ss_port)")"
  method="$(choose_method)"
  ss_password="$(prompt_secret "Enter Shadowsocks password")"
  udp="$DEFAULT_UDP"
  write_ss_config "local" "$ss_port" "$ss_password" "$method" "$udp"

  if [ -f "$SHADOW_TLS_SERVICE" ]; then
    tls_port="$(get_tls_port)"
    tls_password="$(get_tls_password)"
    sni="$(get_tls_sni)"
    fast_open="$(get_tls_fastopen)"
    [ -n "$tls_password" ] || die "Could not read the shadow-tls password. Use Reconfigure full configuration instead."
    write_shadow_tls_service "$tls_port" "$ss_port" "$sni" "$tls_password" "$fast_open"
    info "shadow-tls backend port synchronized."
  fi

  write_mode_file "ss-tls"
  write_commands_file
  if prompt_yes_no "Restart services now?" "y"; then
    if [ -f "$SHADOW_TLS_SERVICE" ]; then
      start_current_services
    else
      start_ss_service
    fi
  fi
}

regenerate_client_configs() {
  local tls_port
  local method
  local ss_password
  local udp
  local tls_password
  local sni
  local fast_open
  local name

  [ -f "$SS_CONFIG" ] || die "SS configuration was not found: ${SS_CONFIG}. Install and configure the full setup first."
  [ -f "$SHADOW_TLS_SERVICE" ] || die "shadow-tls service file was not found: ${SHADOW_TLS_SERVICE}. Install and configure the full setup first."

  method="$(get_ss_method)"
  ss_password="$(get_ss_password)"
  udp="$(get_ss_udp)"
  tls_port="$(get_tls_port)"
  tls_password="$(get_tls_password)"
  sni="$(get_tls_sni)"
  fast_open="$(get_tls_fastopen)"
  [ -n "$ss_password" ] || die "Could not read the Shadowsocks password. Reconfigure the full setup."
  [ -n "$tls_password" ] || die "Could not read the shadow-tls password. Reconfigure the full setup."

  name="$(prompt_text "Profile name" "shadowsocks-shadowtls")"
  prompt_public_hosts
  if [ "${#PUBLIC_HOSTS[@]}" -gt 0 ]; then
    write_client_snippets "ss-tls" "$name" "$tls_port" "$method" "$ss_password" "$udp" "$fast_open" "$tls_password" "$sni" "${PUBLIC_HOSTS[@]}"
  else
    warn "Client configuration was not generated. A public IP or domain is required."
  fi
}

wizard_title() {
  local title="$1"
  printf '\n%b%s%b\n' "${UI_BOLD}${UI_PRIMARY}" "$title" "$UI_RESET" >&2
  printf '%b%s%b\n' "$UI_MUTED" "------------------------------" "$UI_RESET" >&2
}

wizard_section() {
  printf '\n%b%s%b\n' "${UI_BOLD}${UI_ACCENT}" "$1" "$UI_RESET" >&2
}

wizard_line() {
  local kind="$1"
  local label="$2"
  local value="$3"
  local marker="-"
  local color="$UI_ACCENT"
  case "$kind" in
    ok) marker="OK"; color="$UI_OK" ;;
    warn) marker="!!"; color="$UI_WARN" ;;
    err|error) marker="!!"; color="$UI_ERROR" ;;
    *) marker="--"; color="$UI_ACCENT" ;;
  esac
  printf '  %b[%s]%b %s: %s\n' "$color" "$marker" "$UI_RESET" "$label" "$value" >&2
}

wizard_hint() {
  printf '  %b%s%b\n' "$UI_MUTED" "$1" "$UI_RESET" >&2
}

wizard_action() {
  printf '  %b->%b %s\n' "$UI_PRIMARY" "$UI_RESET" "$1" >&2
}

wizard_menu_option() {
  local number="$1"
  local title="$2"
  local hint="${3:-}"
  printf '  %b%2s%b  %s\n' "${UI_BOLD}${UI_PRIMARY}" "$number" "$UI_RESET" "$title" >&2
  if [ -n "$hint" ]; then
    printf '      %b%s%b\n' "$UI_MUTED" "$hint" "$UI_RESET" >&2
  fi
}

pretty_title() {
  wizard_title "$1"
}

pretty_section() {
  wizard_section "$1"
}

kv() {
  wizard_line info "$1" "$2"
}

bool_label() {
  local value="$1"
  if [ "$value" = "true" ]; then
    printf 'enabled'
  else
    printf 'disabled'
  fi
}

get_ss_udp() {
  local mode=""
  mode="$(get_json_value mode "$SS_CONFIG" || true)"
  if [ "$mode" = "tcp_and_udp" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

get_tls_backend() {
  local backend=""
  backend="$(get_json_value backend "$SHADOW_TLS_CONFIG" || true)"
  if [ -z "$backend" ] && [ -f "$SHADOW_TLS_SERVICE" ]; then
    backend="$(grep -oE -- '--server [^[:space:]]+' "$SHADOW_TLS_SERVICE" 2>/dev/null | head -n1 | awk '{print $2}' || true)"
  fi
  if [ -n "$backend" ]; then
    printf '%s\n' "$backend"
  else
    printf '127.0.0.1:%s\n' "$(get_ss_port)"
  fi
}

get_tls_fastopen() {
  local fast_open=""
  fast_open="$(get_json_value fast_open "$SHADOW_TLS_CONFIG" || true)"
  if [ "$fast_open" = "true" ] || [ "$fast_open" = "false" ]; then
    printf '%s' "$fast_open"
  elif [ -f "$SHADOW_TLS_SERVICE" ] && grep -q -- '--fastopen' "$SHADOW_TLS_SERVICE" 2>/dev/null; then
    printf 'true'
  else
    printf 'false'
  fi
}

service_state() {
  local service="$1"
  local active="inactive"
  local enabled="disabled"
  if systemctl is-active --quiet "$service" 2>/dev/null; then
    active="active"
  fi
  if systemctl is-enabled --quiet "$service" 2>/dev/null; then
    enabled="enabled"
  fi
  printf '%s / %s' "$active" "$enabled"
}

service_state_kind() {
  local service="$1"
  if systemctl is-active --quiet "$service" 2>/dev/null; then
    printf 'ok'
  elif systemctl is-enabled --quiet "$service" 2>/dev/null; then
    printf 'warn'
  else
    printf 'err'
  fi
}

service_state_label() {
  local service="$1"
  local active="inactive"
  local enabled="disabled at boot"
  if systemctl is-active --quiet "$service" 2>/dev/null; then
    active="active"
  fi
  if systemctl is-enabled --quiet "$service" 2>/dev/null; then
    enabled="enabled at boot"
  fi
  printf '%s / %s' "$active" "$enabled"
}

show_raw_file() {
  local file="$1"
  local title="$2"
  if [ ! -f "$file" ]; then
    return 0
  fi
  pretty_section "$title"
  printf '  %b%s%b\n' "$UI_MUTED" "$file" "$UI_RESET" >&2
  if [ -r "$file" ]; then
    cat "$file"
  else
    run_sudo cat "$file"
  fi
  printf '\n'
}

show_configs_summary() {
  local mode_label
  local ss_port
  local ss_method
  local ss_password
  local ss_udp
  local ss_listen
  local tls_port
  local tls_password
  local tls_sni
  local tls_backend
  local tls_fastopen
  local has_action="false"

  mode_label="SS + Shadow-TLS v3"
  ss_listen='["::1", "127.0.0.1"]'

  wizard_title "Current Configuration"
  wizard_line info "Mode" "$mode_label"
  wizard_line info "Config directory" "$CONFIG_DIR"

  wizard_section "Shadowsocks"
  if [ -f "$SS_CONFIG" ]; then
    ss_port="$(get_ss_port)"
    ss_method="$(get_ss_method)"
    ss_password="$(get_ss_password)"
    ss_udp="$(get_ss_udp)"
    wizard_line info "Listen" "${ss_listen}:${ss_port}"
    wizard_line info "Method" "$ss_method"
    wizard_line info "Password" "${ss_password:-not found}"
    wizard_line info "UDP relay" "$(bool_label "$ss_udp")"
    wizard_line "$(service_state_kind shadowsocks-libev)" "Service" "$(service_state_label shadowsocks-libev)"
  else
    wizard_line warn "Status" "Config not found: ${SS_CONFIG}"
  fi

  wizard_section "Shadow-TLS"
  if [ -f "$SHADOW_TLS_SERVICE" ]; then
    tls_port="$(get_tls_port)"
    tls_password="$(get_tls_password)"
    tls_sni="$(get_tls_sni)"
    tls_backend="$(get_tls_backend)"
    tls_fastopen="$(get_tls_fastopen)"
    wizard_line info "Listen" "::0:${tls_port}"
    wizard_line info "Backend" "$tls_backend"
    wizard_line info "SNI" "$tls_sni"
    wizard_line info "Password" "${tls_password:-not found}"
    wizard_line info "FastOpen" "$(bool_label "$tls_fastopen")"
    wizard_line "$(service_state_kind shadow-tls.service)" "Service" "$(service_state_label shadow-tls.service)"
  else
    wizard_line warn "Status" "Service file not found: ${SHADOW_TLS_SERVICE}"
  fi

  wizard_section "File Paths"
  [ -f "$SS_CONFIG" ] && wizard_line info "SS config" "$SS_CONFIG"
  [ -f "$SHADOW_TLS_CONFIG" ] && wizard_line info "TLS config" "$SHADOW_TLS_CONFIG"
  [ -f "$SHADOW_TLS_SERVICE" ] && wizard_line info "TLS service" "$SHADOW_TLS_SERVICE"
  [ -f "$SNIPPETS_FILE" ] && wizard_line info "Client config" "$SNIPPETS_FILE"
  [ -f "$COMMANDS_FILE" ] && wizard_line info "Command reference" "$COMMANDS_FILE"
  wizard_line info "Full raw content" "Open View Configuration, then choose View raw configuration files"

  wizard_section "Recommended Actions"
  if [ ! -f "$SS_CONFIG" ]; then
    wizard_action "No SS configuration yet: open Install."
    has_action="true"
  elif ! systemctl is-active --quiet shadowsocks-libev 2>/dev/null; then
    wizard_action "Shadowsocks is not running: open Service Management to start / restart all services."
    has_action="true"
  fi
  if [ -f "$SHADOW_TLS_SERVICE" ] && ! systemctl is-active --quiet shadow-tls.service 2>/dev/null; then
    wizard_action "Shadow-TLS is not running: open Service Management to start / restart all services."
    has_action="true"
  fi
  if [ -f "$SNIPPETS_FILE" ]; then
    wizard_action "Show client configuration: open View Configuration."
  else
    wizard_action "Client configuration is needed: enter a public IP/domain when reconfiguring."
  fi
  if [ "$has_action" = "false" ]; then
    wizard_hint "Core configuration is ready. If connections fail, check the cloud firewall/security group port first."
  fi
}

show_configs() {
  local raw="${1:-false}"
  if [ "$raw" = "true" ]; then
    pretty_title "Full Configuration (includes passwords)"
    warn "Raw passwords will be displayed below. Do not share them publicly."
    show_raw_file "$SS_CONFIG" "Shadowsocks config.json"
    show_raw_file "$SHADOW_TLS_CONFIG" "Shadow-TLS config.json"
    show_raw_file "$SHADOW_TLS_SERVICE" "Shadow-TLS systemd service"
    return 0
  fi

  show_configs_summary
}

normalize_export_type() {
  case "${1:-}" in
    clash|Clash|mihomo|Mihomo|clash/mihomo|Clash/Mihomo) printf 'clash\n' ;;
    surge|Surge) printf 'surge\n' ;;
    sing-box|singbox|Sing-box|SingBox) printf 'singbox\n' ;;
    ss|SS|line|LINE|"one-line config"|"SS config"|"SS Config") printf 'line\n' ;;
    all|ALL) printf 'all\n' ;;
    *) return 1 ;;
  esac
}

choose_export_type() {
  local choice
  log "Choose configuration type"
  option "1" "Clash / Clash Verge / Mihomo"
  option "2" "Surge"
  option "3" "sing-box"
  option "4" "SS Config"
  option "5" "All"
  while true; do
    prompt_line "Choose an option (default 5: All): "
    read -r choice
    choice="${choice:-5}"
    case "$choice" in
      1) printf 'clash\n'; return 0 ;;
      2) printf 'surge\n'; return 0 ;;
      3) printf 'singbox\n'; return 0 ;;
      4) printf 'line\n'; return 0 ;;
      5) printf 'all\n'; return 0 ;;
      *) warn "Enter 1-5." ;;
    esac
  done
}

export_type_label() {
  case "$1" in
    clash) printf 'Clash / Clash Verge / Mihomo' ;;
    surge) printf 'Surge' ;;
    singbox) printf 'sing-box' ;;
    line) printf 'SS Config' ;;
    all) printf 'All' ;;
  esac
}

export_section_starts() {
  local export_type="$1"
  local line="$2"
  case "$export_type" in
    clash) [ "$line" = "Clash / Clash Verge / Mihomo:" ] ;;
    surge) [ "$line" = "Surge [Proxy]:" ] ;;
    singbox) [ "$line" = "sing-box outbound:" ] ;;
    line) [ "$line" = "SS Config:" ] || [ "$line" = "One-line Config:" ] ;;
    *) return 1 ;;
  esac
}

export_section_ends_before_line() {
  local export_type="$1"
  local line="$2"
  case "$export_type" in
    singbox|line) [ -z "$line" ] ;;
    clash) [ "$line" = "sing-box outbound:" ] || [ "$line" = "Surge [Proxy]:" ] ;;
    surge) [ "$line" = "Clash / Clash Verge / Mihomo:" ] || [ "$line" = "sing-box outbound:" ] ;;
    *) return 1 ;;
  esac
}

print_client_config_by_type_from_stream() {
  local export_type="$1"
  local line
  local profile=""
  local printed_profile="false"
  local in_section="false"
  local found="false"

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "## "*)
        if [ "$in_section" = "true" ]; then
          printf '\n'
          in_section="false"
        fi
        profile="$line"
        printed_profile="false"
        continue
        ;;
    esac

    if [ "$in_section" = "true" ]; then
      if export_section_ends_before_line "$export_type" "$line"; then
        printf '\n'
        in_section="false"
        continue
      fi
      printf '%s\n' "$line"
      continue
    fi

    if export_section_starts "$export_type" "$line"; then
      if [ "$printed_profile" = "false" ] && [ -n "$profile" ]; then
        printf '%s\n' "$profile"
        printed_profile="true"
      fi
      printf '%s\n' "$line"
      in_section="true"
      found="true"
    fi
  done

  if [ "$in_section" = "true" ]; then
    printf '\n'
  fi
  if [ "$found" = "false" ]; then
    warn "No $(export_type_label "$export_type") content was found in the client configuration."
  fi
}

export_client_configs() {
  local export_type="${1:-}"
  if [ ! -f "$SNIPPETS_FILE" ]; then
    warn "Client configuration has not been generated yet. Open Install first and enter a public IP/domain."
    return 0
  fi

  if [ -z "$export_type" ]; then
    export_type="$(choose_export_type)"
  elif ! export_type="$(normalize_export_type "$export_type")"; then
    die "Configuration type must be clash, surge, sing-box, ss, or all."
  fi

  wizard_title "Show Client Configuration: $(export_type_label "$export_type")"
  wizard_hint "Source: ${SNIPPETS_FILE}"
  if [ "$export_type" = "all" ]; then
    if [ -r "$SNIPPETS_FILE" ]; then
      cat "$SNIPPETS_FILE"
    else
      run_sudo cat "$SNIPPETS_FILE"
    fi
  else
    if [ -r "$SNIPPETS_FILE" ]; then
      print_client_config_by_type_from_stream "$export_type" <"$SNIPPETS_FILE"
    else
      run_sudo cat "$SNIPPETS_FILE" | print_client_config_by_type_from_stream "$export_type"
    fi
  fi
}

uninstall_all() {
  wizard_title "Full Uninstall Confirmation"
  wizard_hint "Services will be stopped/disabled, and the following paths will be removed:"
  wizard_action "$CONFIG_DIR"
  wizard_action "$SS_CONFIG"
  wizard_action "$SNIPPETS_FILE"
  wizard_action "$COMMANDS_FILE"
  wizard_action "$MODE_FILE"
  wizard_action "$SHADOW_TLS_CONFIG"
  wizard_action "$SHADOW_TLS_SERVICE"
  wizard_action "$SHADOW_TLS_BIN"
  if ! prompt_yes_no "Fully uninstall SS + Shadow-TLS and remove all configuration?" "n"; then
    return 0
  fi
  run_sudo systemctl stop shadow-tls.service >/dev/null 2>&1 || true
  run_sudo systemctl disable shadow-tls.service >/dev/null 2>&1 || true
  run_sudo systemctl stop shadowsocks-libev >/dev/null 2>&1 || true
  run_sudo systemctl disable shadowsocks-libev >/dev/null 2>&1 || true
  [ -f "$SHADOW_TLS_SERVICE" ] && run_sudo rm -f "$SHADOW_TLS_SERVICE"
  [ -f "$SHADOW_TLS_BIN" ] && run_sudo rm -f "$SHADOW_TLS_BIN"
  if have_cmd apt-get; then
    run_sudo apt-get purge -y shadowsocks-libev || true
  fi
  run_sudo rm -rf "$CONFIG_DIR"
  run_sudo systemctl daemon-reload >/dev/null 2>&1 || true
  info "SS + Shadow-TLS has been fully uninstalled."
}

menu_header() {
  local mode_label
  mode_label="SS + Shadow-TLS v3"

  wizard_title "Shadowsocks-libev + Shadow-TLS Management"
  wizard_line info "System" "${SYSTEM_DISTRO_LABEL} (${SYSTEM_DISTRO_FAMILY})"
  wizard_line info "Kernel" "$SYSTEM_KERNEL"
  wizard_line info "Architecture" "$SYSTEM_ARCH"
  wizard_line info "CPU" "${SYSTEM_CPU_CORES} cores"
  wizard_line info "Memory" "$SYSTEM_MEMORY_TOTAL"
  wizard_line info "Current mode" "$mode_label"
  wizard_line "$(service_state_kind shadowsocks-libev)" "shadowsocks-libev" "$(service_state_label shadowsocks-libev)"
  wizard_line "$(service_state_kind shadow-tls.service)" "shadow-tls" "$(service_state_label shadow-tls.service)"
}

menu_install() {
  local choice
  while true; do
    wizard_title "Install"
    wizard_menu_option "1" "One-click full setup (shadowsocks-libev + shadow-tls)"
    wizard_menu_option "2" "Install shadowsocks-libev only"
    wizard_menu_option "3" "Install shadow-tls only"
    wizard_menu_option "4" "Recheck and install missing dependencies"
    wizard_menu_option "0" "Return to main menu"
    prompt_line "Choose an option (default 1): "
    read -r choice
    choice="${choice:-1}"
    case "$choice" in
      1) configure_ss_tls; return 0 ;;
      2) install_shadowsocks_only; return 0 ;;
      3) install_shadow_tls_only; return 0 ;;
      4) run_preflight true; return 0 ;;
      0) return 0 ;;
      *) warn "Enter 0-4." ;;
    esac
  done
}

menu_configs() {
  local choice
  while true; do
    wizard_title "View Configuration"
    wizard_menu_option "1" "View current configuration"
    wizard_menu_option "2" "Show Surge configuration"
    wizard_menu_option "3" "Show Clash / Mihomo configuration"
    wizard_menu_option "4" "Show sing-box configuration"
    wizard_menu_option "5" "Show SS configuration"
    wizard_menu_option "6" "Show all client configurations"
    wizard_menu_option "7" "View raw configuration files"
    wizard_menu_option "0" "Return to main menu"
    prompt_line "Choose an option (default 1): "
    read -r choice
    choice="${choice:-1}"
    case "$choice" in
      1) show_configs false ;;
      2) export_client_configs surge ;;
      3) export_client_configs clash ;;
      4) export_client_configs sing-box ;;
      5) export_client_configs line ;;
      6) export_client_configs all ;;
      7) show_configs true ;;
      0) return 0 ;;
      *) warn "Enter 0-7." ;;
    esac
  done
}

menu_modify() {
  local choice
  while true; do
    wizard_title "Modify Configuration"
    wizard_menu_option "1" "Modify shadowsocks-libev configuration"
    wizard_menu_option "2" "Modify shadow-tls configuration"
    wizard_menu_option "3" "Change public address/domain and regenerate client configs"
    wizard_menu_option "4" "Reconfigure full setup"
    wizard_menu_option "0" "Return to main menu"
    prompt_line "Choose an option (default 4): "
    read -r choice
    choice="${choice:-4}"
    case "$choice" in
      1) configure_shadowsocks_only ;;
      2) configure_tls_only ;;
      3) regenerate_client_configs ;;
      4) configure_ss_tls ;;
      0) return 0 ;;
      *) warn "Enter 0-4." ;;
    esac
  done
}

menu_services() {
  local choice
  while true; do
    wizard_title "Service Management"
    wizard_menu_option "1" "View running status"
    wizard_menu_option "2" "Start / restart all services"
    wizard_menu_option "3" "Stop all services"
    wizard_menu_option "4" "Restart shadowsocks-libev only"
    wizard_menu_option "5" "Restart shadow-tls only"
    wizard_menu_option "0" "Return to main menu"
    prompt_line "Choose an option (default 1): "
    read -r choice
    choice="${choice:-1}"
    case "$choice" in
      1) status_services ;;
      2) start_current_services ;;
      3) stop_current_services ;;
      4) start_ss_service ;;
      5) start_shadow_tls_service ;;
      0) return 0 ;;
      *) warn "Enter 0-5." ;;
    esac
  done
}

show_journal_logs() {
  local service="$1"
  local title="$2"
  local follow="${3:-false}"
  wizard_title "$title"
  if [ "$follow" = "true" ]; then
    run_sudo journalctl -u "$service" -n 80 -f --no-pager
  else
    run_sudo journalctl -u "$service" -n 120 --no-pager
  fi
}

show_all_journal_logs() {
  wizard_title "Follow All Logs"
  run_sudo journalctl -u shadowsocks-libev -u shadow-tls.service -n 80 -f --no-pager
}

menu_logs() {
  local choice
  while true; do
    wizard_title "Log Troubleshooting"
    wizard_menu_option "1" "View shadowsocks-libev logs"
    wizard_menu_option "2" "View shadow-tls logs"
    wizard_menu_option "3" "Follow all logs"
    wizard_menu_option "0" "Return to main menu"
    prompt_line "Choose an option (default 1): "
    read -r choice
    choice="${choice:-1}"
    case "$choice" in
      1) show_journal_logs shadowsocks-libev "shadowsocks-libev Logs" false ;;
      2) show_journal_logs shadow-tls.service "shadow-tls Logs" false ;;
      3) show_all_journal_logs ;;
      0) return 0 ;;
      *) warn "Enter 0-3." ;;
    esac
  done
}

menu() {
  local choice
  while true; do
    menu_header
    wizard_section "Main Menu"
    wizard_menu_option "1" "Install"
    wizard_menu_option "2" "View configuration"
    wizard_menu_option "3" "Modify configuration"
    wizard_menu_option "4" "Service management"
    wizard_menu_option "5" "Log troubleshooting"
    wizard_menu_option "6" "Uninstall"
    wizard_menu_option "0" "Exit"
    prompt_line "Choose an option (default 1): "
    read -r choice
    choice="${choice:-1}"
    case "$choice" in
      1) menu_install ;;
      2) menu_configs ;;
      3) menu_modify ;;
      4) menu_services ;;
      5) menu_logs ;;
      6) uninstall_all ;;
      0) exit 0 ;;
      *) warn "Enter 0-6." ;;
    esac
  done
}

main() {
  if [ "$#" -gt 0 ]; then
    die "Command-line arguments are not supported. Run the script directly and choose actions from the menu."
  fi
  run_preflight false
  menu
}

main "$@"
