#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  printf '%s\n' '错误：这个脚本需要 bash，请先安装 bash 后重试。' >&2
  exit 1
fi

set -euo pipefail

APP_NAME="shadowsocks-libev"
DEFAULT_METHOD="chacha20-ietf-poly1305"
DEFAULT_SERVER_PORT="8388"
DEFAULT_LOCAL_PORT="1080"
DEFAULT_TIMEOUT="300"
CURL_CONNECT_TIMEOUT="2"
CURL_MAX_TIME="4"
PLATFORM=""
OS_LABEL=""
CONFIG_DIR=""
SERVER_CONFIG=""
LOCAL_CONFIG=""
SNIPPETS_FILE=""
COMMANDS_FILE=""
ACTIVE_CONFIG=""
PUBLIC_HOSTS=()
APP_INSTALL_CHECKED="false"

COLOR_RESET=""
COLOR_BOLD=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RED=""
COLOR_CYAN=""
COLOR_BLUE=""

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  COLOR_RESET=$'\033[0m'
  COLOR_BOLD=$'\033[1m'
  COLOR_GREEN=$'\033[32m'
  COLOR_YELLOW=$'\033[33m'
  COLOR_RED=$'\033[31m'
  COLOR_CYAN=$'\033[36m'
  COLOR_BLUE=$'\033[34m'
fi

log() {
  printf '\n%b%s%b\n' "${COLOR_BOLD}${COLOR_CYAN}" "$*" "$COLOR_RESET" >&2
}

section() {
  printf '\n%b【%s】%b\n' "${COLOR_BOLD}${COLOR_CYAN}" "$1" "$COLOR_RESET" >&2
}

option() {
  printf '%b%2s)%b %s\n' "$COLOR_YELLOW" "$1" "$COLOR_RESET" "$2" >&2
}

prompt_line() {
  printf '%b%s%b' "${COLOR_BOLD}${COLOR_BLUE}" "$1" "$COLOR_RESET" >&2
}

info() {
  printf '%b%s%b\n' "$COLOR_GREEN" "$*" "$COLOR_RESET" >&2
}

warn() {
  printf '%b注意：%s%b\n' "$COLOR_YELLOW" "$*" "$COLOR_RESET" >&2
}

die() {
  printf '%b错误：%s%b\n' "$COLOR_RED" "$*" "$COLOR_RESET" >&2
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_sudo() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$@"
  else
    have_cmd sudo || die "需要 sudo 执行系统级操作，请先安装 sudo 或切换 root。"
    sudo "$@"
  fi
}

detect_platform() {
  local kernel
  kernel="$(uname -s 2>/dev/null || true)"
  case "$kernel" in
    Darwin)
      PLATFORM="macos"
      OS_LABEL="macOS"
      ;;
    Linux)
      PLATFORM="linux"
      OS_LABEL="Linux"
      local distro_id=""
      local distro_like=""
      if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        distro_id="${ID:-}"
        distro_like="${ID_LIKE:-}"
        OS_LABEL="${PRETTY_NAME:-Linux}"
      fi
      case " ${distro_id} ${distro_like} " in
        *debian*|*ubuntu*) ;;
        *)
          have_cmd apt-get || die "当前 Linux 发行版不是 Debian/Ubuntu 系，且没有 apt-get。"
          warn "未识别为 Debian/Ubuntu，但检测到 apt-get，将按 Debian/Ubuntu 方式继续。"
          ;;
      esac
      ;;
    *)
      die "暂不支持当前系统：${kernel:-unknown}。仅支持 Debian/Ubuntu/macOS。"
      ;;
  esac
}

setup_paths() {
  if [ "$PLATFORM" = "linux" ]; then
    CONFIG_DIR="/etc/shadowsocks-libev"
  else
    CONFIG_DIR="${HOME}/.config/shadowsocks-libev"
  fi

  SERVER_CONFIG="${CONFIG_DIR}/server.json"
  LOCAL_CONFIG="${CONFIG_DIR}/local.json"
  ACTIVE_CONFIG="${CONFIG_DIR}/config.json"
  SNIPPETS_FILE="${CONFIG_DIR}/client-snippets.txt"
  COMMANDS_FILE="${CONFIG_DIR}/commands.txt"
}

ensure_config_dir() {
  if [ "$PLATFORM" = "linux" ]; then
    run_sudo mkdir -p "$CONFIG_DIR"
  else
    mkdir -p "$CONFIG_DIR"
  fi
}

install_managed_file() {
  local src="$1"
  local dest="$2"
  local mode="${3:-600}"
  if [ "$PLATFORM" = "linux" ]; then
    run_sudo mkdir -p "$(dirname "$dest")"
    run_sudo install -m "$mode" "$src" "$dest"
  else
    mkdir -p "$(dirname "$dest")"
    install -m "$mode" "$src" "$dest"
  fi
}

activate_linux_config() {
  local src="$1"
  if [ "$PLATFORM" != "linux" ]; then
    return 0
  fi
  [ -f "$src" ] || die "配置文件不存在：$src"
  run_sudo install -m 644 "$src" "$ACTIVE_CONFIG"
  info "已同步当前配置到 ${ACTIVE_CONFIG}，供 systemctl 管理的 shadowsocks-libev 服务读取。"
}

show_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    warn "文件不存在：$file"
    return 0
  fi
  log "===== $file ====="
  if [ -r "$file" ]; then
    cat "$file"
  else
    run_sudo cat "$file"
  fi
  printf '\n'
}

install_package() {
  log "检测系统：$OS_LABEL"
  if [ "$PLATFORM" = "linux" ]; then
    info "使用 apt 安装 ${APP_NAME}。"
    run_sudo apt-get update
    run_sudo apt-get install -y shadowsocks-libev curl ca-certificates
  else
    have_cmd brew || die "macOS 需要 Homebrew。请先安装 Homebrew 后重试：https://brew.sh/"
    info "使用 Homebrew 安装 ${APP_NAME}。"
    brew install shadowsocks-libev
  fi
  info "安装完成。"
  APP_INSTALL_CHECKED="true"
}

reinstall_package() {
  log "重新安装 ${APP_NAME}"
  if [ "$PLATFORM" = "linux" ]; then
    info "使用 apt 覆盖安装 ${APP_NAME}。"
    run_sudo apt-get update
    run_sudo apt-get install -y curl ca-certificates
    if dpkg -s shadowsocks-libev >/dev/null 2>&1; then
      run_sudo apt-get install -y --reinstall shadowsocks-libev
    else
      run_sudo apt-get install -y shadowsocks-libev
    fi
  else
    have_cmd brew || die "macOS 需要 Homebrew。请先安装 Homebrew 后重试：https://brew.sh/"
    info "使用 Homebrew 重新安装 ${APP_NAME}。"
    brew reinstall shadowsocks-libev || brew install shadowsocks-libev
  fi
  info "重新安装完成。"
  APP_INSTALL_CHECKED="true"
}

find_binary() {
  local bin="$1"
  local candidate
  if have_cmd "$bin"; then
    command -v "$bin"
    return 0
  fi
  for candidate in \
    "/usr/bin/${bin}" \
    "/usr/local/bin/${bin}" \
    "/opt/homebrew/bin/${bin}"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

is_app_installed() {
  if [ "$PLATFORM" = "linux" ]; then
    dpkg -s shadowsocks-libev >/dev/null 2>&1 && return 0
  else
    have_cmd brew && brew list --formula shadowsocks-libev >/dev/null 2>&1 && return 0
  fi

  find_binary ss-server >/dev/null 2>&1
}

ensure_shadowsocks_libev() {
  if [ "$APP_INSTALL_CHECKED" = "true" ]; then
    require_ss_server
    return 0
  fi

  if is_app_installed; then
    info "检测到 ${APP_NAME} 已安装。"
    if prompt_yes_no "是否覆盖/重新安装 ${APP_NAME}？选择 n 将跳过安装" "y"; then
      reinstall_package
    else
      info "已保留现有安装。"
      APP_INSTALL_CHECKED="true"
    fi
  else
    warn "未检测到 ${APP_NAME}。"
    if prompt_yes_no "是否现在安装 ${APP_NAME}？" "y"; then
      install_package
    else
      die "缺少 ${APP_NAME}，无法继续。"
    fi
  fi

  require_ss_server
}

require_ss_server() {
  find_binary ss-server >/dev/null 2>&1 || die "未找到 ss-server 命令，${APP_NAME} 安装可能不完整，请重新安装。"
}

ensure_binary_for_mode() {
  ensure_shadowsocks_libev
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
  prompt_line "${label}（留空自动生成）: "
  read -r -s value
  printf '\n' >&2
  if [ -z "$value" ]; then
    value="$(generate_password)"
    info "已自动生成密码。"
  fi
  printf '%s\n' "$value"
}

prompt_required_secret() {
  local label="$1"
  local value
  while true; do
    prompt_line "${label}: "
    read -r -s value
    printf '\n' >&2
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
    warn "密码不能为空，必须和远程服务端配置一致。"
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
    warn "端口必须是 1-65535 的数字。"
  done
}

prompt_yes_no() {
  local label="$1"
  local default="${2:-y}"
  local answer
  local hint
  if [ "$default" = "y" ]; then
    hint="Y/n"
  else
    hint="y/N"
  fi
  while true; do
    prompt_line "${label} [${hint}]: "
    read -r answer
    answer="${answer:-$default}"
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) warn "请输入 y 或 n。" ;;
    esac
  done
}

choose_listen_mode() {
  local title="$1"
  local default_mode="${2:-remote}"
  local local_label="$3"
  local remote_label="$4"
  local choice
  local default_choice
  local default_text

  if [ "$default_mode" = "local" ]; then
    default_choice="1"
    default_text="本地监听"
  else
    default_choice="2"
    default_text="远程监听"
  fi

  log "$title"
  option "1" "$local_label"
  option "2" "$remote_label"
  while true; do
    prompt_line "请选择（默认 ${default_choice}：${default_text}）: "
    read -r choice
    choice="${choice:-$default_choice}"
    case "$choice" in
      1) printf 'local\n'; return 0 ;;
      2) printf 'remote\n'; return 0 ;;
      *) warn "请输入 1 或 2。" ;;
    esac
  done
}

choose_mode() {
  choose_listen_mode \
    "选择监听模式" \
    "remote" \
    '本地监听（server = ["::1", "127.0.0.1"]）' \
    '远程监听（server = ["::", "0.0.0.0"]）'
}

choose_existing_mode() {
  choose_listen_mode \
    "选择服务" \
    "remote" \
    "本地监听服务（ss-server）" \
    "远程监听服务（ss-server）"
}

choose_config_level() {
  local choice
  log "选择配置方式"
  option "1" "快速配置（推荐：${DEFAULT_METHOD}，启用 UDP relay）"
  option "2" "高级配置（自选 method / UDP relay / 配置名称）"
  while true; do
    prompt_line "请选择（默认 1：快速配置）: "
    read -r choice
    choice="${choice:-1}"
    case "$choice" in
      1|quick) printf 'quick\n'; return 0 ;;
      2|advanced) printf 'advanced\n'; return 0 ;;
      *) warn "请输入 1 或 2。" ;;
    esac
  done
}

choose_method_simple() {
  local choice
  log "选择加密协议 / method"
  option "1" "chacha20-ietf-poly1305（推荐）"
  option "2" "aes-256-gcm"
  option "3" "aes-128-gcm"
  option "4" "xchacha20-ietf-poly1305"
  option "5" "自定义"
  option "6" "高级列表"
  while true; do
    prompt_line "请选择（默认 1：chacha20-ietf-poly1305）: "
    read -r choice
    choice="${choice:-1}"
    case "$choice" in
      1) printf '%s\n' "$DEFAULT_METHOD"; return 0 ;;
      2) printf 'aes-256-gcm\n'; return 0 ;;
      3) printf 'aes-128-gcm\n'; return 0 ;;
      4) printf 'xchacha20-ietf-poly1305\n'; return 0 ;;
      5) prompt_text "输入自定义 method" "$DEFAULT_METHOD"; return 0 ;;
      6) choose_method_advanced; return 0 ;;
      *) warn "请输入 1-6。" ;;
    esac
  done
}

choose_method_advanced() {
  local choice
  local method
  log "选择加密协议 / method（高级列表）"
  option "1" "aes-128-gcm"
  option "2" "aes-192-gcm"
  option "3" "aes-256-gcm"
  option "4" "chacha20-ietf-poly1305"
  option "5" "xchacha20-ietf-poly1305"
  option "6" "rc4"
  option "7" "rc4-md5"
  option "8" "aes-128-cfb"
  option "9" "aes-192-cfb"
  option "10" "aes-256-cfb"
  option "11" "aes-128-ctr"
  option "12" "aes-192-ctr"
  option "13" "aes-256-ctr"
  option "14" "bf-cfb"
  option "15" "camellia-128-cfb"
  option "16" "camellia-192-cfb"
  option "17" "camellia-256-cfb"
  option "18" "cast5-cfb"
  option "19" "des-cfb"
  option "20" "idea-cfb"
  option "21" "rc2-cfb"
  option "22" "seed-cfb"
  option "23" "salsa20"
  option "24" "chacha20"
  option "25" "chacha20-ietf"
  option "26" "none"
  option "27" "自定义"
  while true; do
    prompt_line "请选择（默认 4：chacha20-ietf-poly1305）: "
    read -r choice
    choice="${choice:-4}"
    case "$choice" in
      1) method="aes-128-gcm" ;;
      2) method="aes-192-gcm" ;;
      3) method="aes-256-gcm" ;;
      4) method="chacha20-ietf-poly1305" ;;
      5) method="xchacha20-ietf-poly1305" ;;
      6) method="rc4" ;;
      7) method="rc4-md5" ;;
      8) method="aes-128-cfb" ;;
      9) method="aes-192-cfb" ;;
      10) method="aes-256-cfb" ;;
      11) method="aes-128-ctr" ;;
      12) method="aes-192-ctr" ;;
      13) method="aes-256-ctr" ;;
      14) method="bf-cfb" ;;
      15) method="camellia-128-cfb" ;;
      16) method="camellia-192-cfb" ;;
      17) method="camellia-256-cfb" ;;
      18) method="cast5-cfb" ;;
      19) method="des-cfb" ;;
      20) method="idea-cfb" ;;
      21) method="rc2-cfb" ;;
      22) method="seed-cfb" ;;
      23) method="salsa20" ;;
      24) method="chacha20" ;;
      25) method="chacha20-ietf" ;;
      26) method="none" ;;
      27) method="$(prompt_text "输入自定义 method" "$DEFAULT_METHOD")" ;;
      *) warn "请输入 1-27。"; continue ;;
    esac
    printf '%s\n' "$method"
    return 0
  done
}

choose_method() {
  choose_method_simple
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

format_surge_host() {
  printf '%s' "$1"
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
  case "$ip" in
    *:*) return 0 ;;
    *) return 1 ;;
  esac
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
    info "检测到公网 IPv4：${ipv4}"
  else
    warn "未检测到公网 IPv4。"
  fi

  if [ -n "$ipv6" ]; then
    info "检测到公网 IPv6：${ipv6}"
  else
    warn "未检测到公网 IPv6。"
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
  [ -n "$host" ] || return 0
  PUBLIC_HOSTS[${#PUBLIC_HOSTS[@]}]="$host"
}

prompt_public_hosts() {
  local detected
  local host
  local manual
  PUBLIC_HOSTS=()

  log "自动查询公网 IPv4 / IPv6，用于生成 Clash / Surge / URI 配置。"
  detected="$(detect_public_hosts || true)"
  while IFS= read -r host; do
    append_public_host "$host"
  done <<EOF
$detected
EOF

  if [ "${#PUBLIC_HOSTS[@]}" -gt 0 ]; then
    info "留空将使用自动检测到的公网地址；如需覆盖，可输入 IP/域名，多个用空格分隔。"
  else
    warn "未能自动查询到公网 IPv4 或 IPv6。"
    info "可以手动输入服务器 IP/域名；留空则只生成服务端配置，跳过客户端导入配置。"
  fi

  manual="$(prompt_text "公网 IP 或域名" "")"
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

write_server_config() {
  local dest="$1"
  local listen_mode="$2"
  local port="$3"
  local password="$4"
  local method="$5"
  local udp="$6"
  local tmp
  local server_value
  if [ "$listen_mode" = "local" ]; then
    server_value="$(json_string_array "::1" "127.0.0.1")"
  elif [ "$listen_mode" = "remote" ]; then
    server_value="$(json_string_array "::" "0.0.0.0")"
  elif [ "$listen_mode" = "dual" ]; then
    server_value="$(json_string_array "::" "0.0.0.0")"
  elif [ "$listen_mode" = "ipv6" ]; then
    server_value='"::"'
  else
    server_value='"0.0.0.0"'
  fi
  tmp="$(mktemp)"
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
  install_managed_file "$tmp" "$dest" 600
  rm -f "$tmp"
}

append_client_snippet() {
  local out="$1"
  local name="$2"
  local host="$3"
  local port="$4"
  local method="$5"
  local password="$6"
  local udp="$7"
  local uri_host
  local surge_host
  local display_host
  local tag
  local sip002
  local legacy
  uri_host="$(format_uri_host "$host")"
  surge_host="$(format_surge_host "$host")"
  display_host="$uri_host"
  tag="$(url_encode_component "$name")"
  sip002="ss://$(base64url_nopad "${method}:${password}")@${uri_host}:${port}#${tag}"
  cat >>"$out" <<EOF
## ${name}
# Server: ${display_host}:${port}
# Method: ${method}

SIP002 URI:
${sip002}

EOF

  if valid_ipv6 "$host"; then
    cat >>"$out" <<EOF
Legacy ss:// URI:
# IPv6 的 legacy ss:// 兼容性不稳定，请使用上面的 SIP002 URI 或下面的 Clash/sing-box 配置。

EOF
  else
    legacy="ss://$(base64_nopad "${method}:${password}@${uri_host}:${port}")#${tag}"
    cat >>"$out" <<EOF
Legacy ss:// URI:
${legacy}

EOF
  fi

  cat >>"$out" <<EOF
Clash / Clash Verge / Mihomo:
proxies:
  - name: $(yaml_double_quote "$name")
    type: ss
    server: $(yaml_double_quote "$host")
    port: ${port}
    cipher: $(yaml_double_quote "$method")
    password: $(yaml_double_quote "$password")
    udp: ${udp}

Surge [Proxy]:
$(surge_double_quote "$name") = ss, ${surge_host}, ${port}, encrypt-method=$(surge_double_quote "$method"), password=$(surge_double_quote "$password"), udp-relay=${udp}

sing-box outbound:
{
  "type": "shadowsocks",
  "tag": "$(json_escape "$name")",
  "server": "$(json_escape "$host")",
  "server_port": ${port},
  "method": "$(json_escape "$method")",
  "password": "$(json_escape "$password")"
}

EOF
}

write_client_snippets() {
  local name="$1"
  local port="$2"
  local method="$3"
  local password="$4"
  local udp="$5"
  shift 5
  local tmp
  local host
  local label
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# Generated by shadowsocks-setup.sh
# Profile: ${name}
# Method: ${method}

EOF
  for host in "$@"; do
    if valid_ipv6 "$host"; then
      label="${name} IPv6"
    elif valid_ipv4 "$host"; then
      label="${name} IPv4"
    else
      label="$name"
    fi
    append_client_snippet "$tmp" "$label" "$host" "$port" "$method" "$password" "$udp"
  done
  install_managed_file "$tmp" "$SNIPPETS_FILE" 600
  rm -f "$tmp"
}

write_commands_file() {
  local tmp
  tmp="$(mktemp)"
  if [ "$PLATFORM" = "linux" ]; then
    cat >"$tmp" <<EOF
# shadowsocks-libev 常用命令

配置目录:
  ${CONFIG_DIR}

查看配置:
  $0 --show

启动服务:
  $0 --start

停止服务:
  $0 --stop

查看服务状态:
  $0 --status

查看客户端导入配置:
  $0 --export [uri|clash|surge|sing-box|all]

卸载:
  $0 --uninstall
EOF
  else
    cat >"$tmp" <<EOF
# shadowsocks-libev 常用命令

配置目录:
  ${CONFIG_DIR}

查看配置:
  $0 --show

启动远程服务端:
  $0 --start remote

启动本地监听服务:
  $0 --start local

查看客户端导入配置:
  $0 --export [uri|clash|surge|sing-box|all]

卸载:
  $0 --uninstall
EOF
  fi
  install_managed_file "$tmp" "$COMMANDS_FILE" 644
  rm -f "$tmp"
}

linux_service_name() {
  printf 'shadowsocks-libev'
}

macos_label() {
  local mode="$1"
  printf 'com.local.shadowsocks-libev.%s' "$mode"
}

macos_plist_path() {
  local mode="$1"
  printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$(macos_label "$mode")"
}

prepare_linux_service_config() {
  local mode="$1"
  local cfg
  if [ "$mode" = "remote" ]; then
    cfg="$SERVER_CONFIG"
  else
    cfg="$LOCAL_CONFIG"
  fi
  [ -f "$cfg" ] || die "配置文件不存在：$cfg"
  activate_linux_config "$cfg"
  have_cmd systemctl || die "未检测到 systemctl，请手动运行：ss-server -c ${ACTIVE_CONFIG}"
}

create_macos_service() {
  local mode="$1"
  local bin
  local cfg
  local label
  local plist
  local log_dir
  local tmp
  bin="$(find_binary ss-server)"
  if [ "$mode" = "remote" ]; then
    cfg="$SERVER_CONFIG"
  else
    cfg="$LOCAL_CONFIG"
  fi
  [ -f "$cfg" ] || die "配置文件不存在：$cfg"
  label="$(macos_label "$mode")"
  plist="$(macos_plist_path "$mode")"
  log_dir="${HOME}/Library/Logs/shadowsocks-libev"
  mkdir -p "$(dirname "$plist")" "$log_dir"
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${bin}</string>
    <string>-c</string>
    <string>${cfg}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${log_dir}/${mode}.out.log</string>
  <key>StandardErrorPath</key>
  <string>${log_dir}/${mode}.err.log</string>
</dict>
</plist>
EOF
  install_managed_file "$tmp" "$plist" 644
  rm -f "$tmp"
}

create_service() {
  local mode="$1"
  require_ss_server
  if [ "$PLATFORM" = "linux" ]; then
    prepare_linux_service_config "$mode"
  else
    create_macos_service "$mode"
  fi
}

start_existing_service() {
  local mode="$1"
  if [ "$PLATFORM" = "linux" ]; then
    local enable_err
    have_cmd systemctl || die "未检测到 systemctl，请手动运行配置文件中的命令。"
    run_sudo systemctl restart "$(linux_service_name)"
    if systemctl is-enabled --quiet "$(linux_service_name)" 2>/dev/null; then
      info "服务已启动，开机自启已启用：$(linux_service_name)"
    else
      enable_err="$(mktemp)"
      if run_sudo systemctl enable "$(linux_service_name)" >/dev/null 2>"$enable_err"; then
        info "服务已启动，并已设置开机自启：$(linux_service_name)"
      elif [ ! -e /usr/lib/systemd/systemd-sysv-install ] && [ ! -e /lib/systemd/systemd-sysv-install ]; then
        warn "服务已启动，但开机自启未设置：系统缺少 systemd-sysv-install。它属于 systemd-sysv 兼容组件，不属于 ${APP_NAME}；可先运行 sudo apt-get install -y systemd-sysv，再执行 $0 --start。"
      else
        warn "服务已启动，但设置开机自启失败；可手动运行 systemctl enable $(linux_service_name) 查看详细原因。"
      fi
      rm -f "$enable_err"
    fi
  else
    local plist
    local label
    local uid
    plist="$(macos_plist_path "$mode")"
    label="$(macos_label "$mode")"
    uid="$(id -u)"
    launchctl bootout "gui/${uid}" "$plist" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/${uid}" "$plist"
    launchctl enable "gui/${uid}/${label}" >/dev/null 2>&1 || true
    launchctl kickstart -k "gui/${uid}/${label}" >/dev/null 2>&1 || true
    launchctl print "gui/${uid}/${label}" || true
  fi
}

start_service() {
  local mode="$1"
  create_service "$mode"
  start_existing_service "$mode"
}

stop_service() {
  local mode="$1"
  if [ "$PLATFORM" = "linux" ]; then
    have_cmd systemctl || die "未检测到 systemctl。"
    run_sudo systemctl stop "$(linux_service_name)" || true
    info "已停止 $(linux_service_name)。"
  else
    local plist
    local uid
    plist="$(macos_plist_path "$mode")"
    uid="$(id -u)"
    launchctl bootout "gui/${uid}" "$plist" >/dev/null 2>&1 || true
    info "已停止 ${mode}。"
  fi
}

status_service() {
  local mode="$1"
  if [ "$PLATFORM" = "linux" ]; then
    have_cmd systemctl || die "未检测到 systemctl。"
    run_sudo systemctl status --no-pager "$(linux_service_name)" || true
  else
    local label
    local uid
    label="$(macos_label "$mode")"
    uid="$(id -u)"
    launchctl print "gui/${uid}/${label}" || true
  fi
}

configure_remote() {
  local advanced="${1:-quick}"
  local port
  local method
  local password
  local udp
  local name
  ensure_shadowsocks_libev
  ensure_config_dir
  port="$(prompt_port "远程服务端监听端口" "$DEFAULT_SERVER_PORT")"
  password="$(prompt_secret "输入 Shadowsocks 密码")"
  if [ "$advanced" = "advanced" ]; then
    method="$(choose_method)"
    if prompt_yes_no "是否启用 UDP relay？" "y"; then
      udp="true"
    else
      udp="false"
    fi
    name="$(prompt_text "配置名称" "shadowsocks-libev")"
  else
    method="$DEFAULT_METHOD"
    udp="true"
    name="shadowsocks-libev"
    info "使用推荐 method：${method}；UDP relay 默认启用。"
  fi
  prompt_public_hosts

  write_server_config "$SERVER_CONFIG" "remote" "$port" "$password" "$method" "$udp"
  if [ "${#PUBLIC_HOSTS[@]}" -gt 0 ]; then
    write_client_snippets "$name" "$port" "$method" "$password" "$udp" "${PUBLIC_HOSTS[@]}"
  else
    warn "未生成客户端导入配置；之后可重新运行远程配置并输入公网 IP/域名。"
  fi
  write_commands_file
  create_service "remote"

  info "远程服务端配置已写入：${SERVER_CONFIG}"
  if [ "${#PUBLIC_HOSTS[@]}" -gt 0 ]; then
    info "客户端导入配置已写入：${SNIPPETS_FILE}"
    info "需要导出时运行：$0 --export [uri|clash|surge|sing-box|all]"
  fi
  if prompt_yes_no "是否立即启动并设置开机启动？" "y"; then
    start_existing_service "remote"
  fi
  info "监听地址：[\"::\", \"0.0.0.0\"]，UDP relay：${udp}"
}

configure_remote_advanced() {
  configure_remote "advanced"
}

configure_local() {
  local advanced="${1:-quick}"
  local port
  local method
  local password
  local udp
  local tmp
  local name
  ensure_shadowsocks_libev
  ensure_config_dir
  port="$(prompt_port "本地监听端口" "$DEFAULT_LOCAL_PORT")"
  password="$(prompt_secret "输入 Shadowsocks 密码")"
  if [ "$advanced" = "advanced" ]; then
    method="$(choose_method)"
    if prompt_yes_no "是否启用 UDP relay？" "y"; then
      udp="true"
    else
      udp="false"
    fi
    name="$(prompt_text "配置名称" "shadowsocks-libev-local")"
  else
    method="$DEFAULT_METHOD"
    udp="true"
    name="shadowsocks-libev-local"
    info "使用推荐 method：${method}；UDP relay 默认启用。"
  fi

  write_server_config "$LOCAL_CONFIG" "local" "$port" "$password" "$method" "$udp"
  write_client_snippets "$name" "$port" "$method" "$password" "$udp" "127.0.0.1" "::1"
  write_commands_file
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# 本地监听服务信息
server:
  ["::1", "127.0.0.1"]

启动:
  $0 --start local
EOF
  install_managed_file "$tmp" "${CONFIG_DIR}/local-info.txt" 600
  rm -f "$tmp"
  create_service "local"

  info "本地监听配置已写入：${LOCAL_CONFIG}"
  info "客户端导入配置已写入：${SNIPPETS_FILE}"
  info "本地监听说明已写入：${CONFIG_DIR}/local-info.txt"
  info "需要导出时运行：$0 --export [uri|clash|surge|sing-box|all]"
  if prompt_yes_no "是否立即启动并设置开机启动？" "y"; then
    start_existing_service "local"
  fi
  info "监听地址：[\"::1\", \"127.0.0.1\"]，UDP relay：${udp}"
}

configure_local_advanced() {
  configure_local "advanced"
}

show_configs() {
  if [ "$PLATFORM" = "linux" ]; then
    show_file "$ACTIVE_CONFIG"
    return 0
  fi

  if [ -f "$ACTIVE_CONFIG" ]; then
    show_file "$ACTIVE_CONFIG"
    return 0
  fi

  log "macOS 没有单一 systemd 生效配置；显示当前已生成的监听配置。"
  if [ -f "$SERVER_CONFIG" ] || [ -f "$LOCAL_CONFIG" ]; then
    show_file "$SERVER_CONFIG"
    show_file "$LOCAL_CONFIG"
  else
    warn "还没有生成配置文件。请先运行配置向导。"
  fi
}

normalize_export_type() {
  case "${1:-}" in
    uri|URI|uris|URIS) printf 'uri\n' ;;
    clash|Clash|mihomo|Mihomo|clash/mihomo|Clash/Mihomo) printf 'clash\n' ;;
    surge|Surge) printf 'surge\n' ;;
    sing-box|singbox|Sing-box|SingBox) printf 'singbox\n' ;;
    all|ALL|全部) printf 'all\n' ;;
    *) return 1 ;;
  esac
}

choose_export_type() {
  local choice
  log "选择导出类型"
  option "1" "URI（SIP002 / Legacy ss://）"
  option "2" "Clash / Clash Verge / Mihomo"
  option "3" "Surge"
  option "4" "sing-box"
  option "5" "全部"
  while true; do
    prompt_line "请选择（默认 5：全部）: "
    read -r choice
    choice="${choice:-5}"
    case "$choice" in
      1) printf 'uri\n'; return 0 ;;
      2) printf 'clash\n'; return 0 ;;
      3) printf 'surge\n'; return 0 ;;
      4) printf 'singbox\n'; return 0 ;;
      5) printf 'all\n'; return 0 ;;
      *) warn "请输入 1-5。" ;;
    esac
  done
}

export_type_label() {
  case "$1" in
    uri) printf 'URI' ;;
    clash) printf 'Clash / Clash Verge / Mihomo' ;;
    surge) printf 'Surge' ;;
    singbox) printf 'sing-box' ;;
    all) printf '全部' ;;
  esac
}

export_section_starts() {
  local export_type="$1"
  local line="$2"
  case "$export_type" in
    uri) [ "$line" = "SIP002 URI:" ] || [ "$line" = "Legacy ss:// URI:" ] ;;
    clash) [ "$line" = "Clash / Clash Verge / Mihomo:" ] ;;
    surge) [ "$line" = "Surge [Proxy]:" ] ;;
    singbox) [ "$line" = "sing-box outbound:" ] ;;
    *) return 1 ;;
  esac
}

export_section_ends_before_line() {
  local export_type="$1"
  local line="$2"
  case "$export_type" in
    uri|singbox) [ -z "$line" ] ;;
    clash) [ "$line" = "Surge [Proxy]:" ] ;;
    surge) [ "$line" = "sing-box outbound:" ] ;;
    *) return 1 ;;
  esac
}

print_all_client_configs_from_stream() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
  done
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
    warn "没有在客户端导入配置中找到 $(export_type_label "$export_type") 内容。"
  fi
}

show_client_config_by_type() {
  local export_type="$1"
  log "===== ${SNIPPETS_FILE} ($(export_type_label "$export_type")) ====="
  if [ -r "$SNIPPETS_FILE" ]; then
    print_client_config_by_type_from_stream "$export_type" <"$SNIPPETS_FILE"
  else
    run_sudo cat "$SNIPPETS_FILE" | print_client_config_by_type_from_stream "$export_type"
  fi
}

show_all_client_configs() {
  log "===== ${SNIPPETS_FILE} ====="
  if [ -r "$SNIPPETS_FILE" ]; then
    print_all_client_configs_from_stream <"$SNIPPETS_FILE"
  else
    run_sudo cat "$SNIPPETS_FILE" | print_all_client_configs_from_stream
  fi
}

export_client_configs() {
  local export_type="${1:-}"
  if [ ! -f "$SNIPPETS_FILE" ]; then
    warn "还没有生成客户端导入配置。请先运行配置向导；远程配置需要填写公网 IP/域名，本地配置会生成 127.0.0.1 / ::1 片段。"
    return 0
  fi

  if [ -z "$export_type" ]; then
    export_type="$(choose_export_type)"
  elif ! export_type="$(normalize_export_type "$export_type")"; then
    die "导出类型必须是 uri、clash、surge、sing-box 或 all。"
  fi

  if [ "$export_type" = "all" ]; then
    show_all_client_configs
  else
    show_client_config_by_type "$export_type"
  fi
}

uninstall_all() {
  local mode
  if ! prompt_yes_no "确认卸载 ${APP_NAME} 并删除所有配置、服务和日志文件？" "n"; then
    return 0
  fi

  if [ "$PLATFORM" = "linux" ]; then
    have_cmd systemctl && run_sudo systemctl stop "$(linux_service_name)" >/dev/null 2>&1 || true
    have_cmd systemctl && run_sudo systemctl disable "$(linux_service_name)" >/dev/null 2>&1 || true
    if have_cmd apt-get; then
      run_sudo apt-get purge -y shadowsocks-libev
    else
      warn "未检测到 apt-get，已跳过软件包卸载。"
    fi
    run_sudo rm -rf "$CONFIG_DIR"
    have_cmd systemctl && run_sudo systemctl daemon-reload >/dev/null 2>&1 || true
  else
    for mode in remote local; do
      stop_service "$mode" || true
      rm -f "$(macos_plist_path "$mode")"
    done
    if have_cmd brew; then
      brew uninstall shadowsocks-libev || true
    else
      warn "未检测到 Homebrew，已跳过软件包卸载。"
    fi
    rm -rf "$CONFIG_DIR" "${HOME}/Library/Logs/shadowsocks-libev"
  fi
  info "已卸载 ${APP_NAME}，并删除相关配置、服务和日志文件。"
}

configure_wizard() {
  local mode
  local level
  mode="$(choose_mode)"
  level="$(choose_config_level)"
  if [ "$mode" = "remote" ]; then
    configure_remote "$level"
  else
    configure_local "$level"
  fi
}

install_and_configure() {
  install_package
  configure_wizard
}

menu() {
  local choice
  while true; do
    log "shadowsocks-libev 安装与配置菜单"
    printf '%b系统：%b%s\n' "$COLOR_CYAN" "$COLOR_RESET" "$OS_LABEL" >&2
    printf '%b配置目录：%b%s\n' "$COLOR_CYAN" "$COLOR_RESET" "$CONFIG_DIR" >&2
    section "配置"
    option "1" "安装/更新并配置（推荐，默认）"
    option "2" "仅运行配置向导"
    section "服务"
    option "3" "启动服务"
    option "4" "停止服务"
    option "5" "查看服务状态"
    section "查看与导出"
    option "6" "查看生效配置"
    option "7" "导出客户端配置"
    section "维护"
    option "8" "卸载 shadowsocks-libev（删除所有配置）"
    option "0" "退出"
    prompt_line "请选择（默认 1：安装/更新并配置）: "
    read -r choice
    choice="${choice:-1}"
    case "$choice" in
      1) install_and_configure ;;
      2) configure_wizard ;;
      3)
        if [ "$PLATFORM" = "linux" ]; then
          start_existing_service "remote"
        else
          start_service "$(choose_existing_mode)"
        fi
        ;;
      4)
        if [ "$PLATFORM" = "linux" ]; then
          stop_service "remote"
        else
          stop_service "$(choose_existing_mode)"
        fi
        ;;
      5)
        if [ "$PLATFORM" = "linux" ]; then
          status_service "remote"
        else
          status_service "$(choose_existing_mode)"
        fi
        ;;
      6) show_configs ;;
      7) export_client_configs ;;
      8) uninstall_all ;;
      0) exit 0 ;;
      *) warn "请输入 0-8。" ;;
    esac
  done
}

usage() {
  cat <<EOF
用法:
  $0                         # 打开菜单，默认安装/更新并配置
  $0 --install               # 安装/更新 shadowsocks-libev 后进入配置向导
  $0 --configure             # 选择本地/远程和快速/高级配置
  $0 --configure-server      # 快速配置远程服务端
  $0 --configure-local       # 快速配置本地监听
  $0 --configure-server-advanced
  $0 --configure-local-advanced
  $0 --show                  # 查看生效配置
  $0 --export [uri|clash|surge|sing-box|all]
  $0 --start [remote|local]  # Linux 可省略；macOS 需指定 remote 或 local
  $0 --stop [remote|local]
  $0 --status [remote|local]
  $0 --uninstall             # 卸载并删除所有配置、服务和日志文件

说明:
  remote = 远程监听 ss-server，server = ["::", "0.0.0.0"]，默认端口 ${DEFAULT_SERVER_PORT}
  local  = 本地监听 ss-server，server = ["::1", "127.0.0.1"]，默认端口 ${DEFAULT_LOCAL_PORT}
  快速配置默认使用 ${DEFAULT_METHOD}，启用 UDP relay，密码留空会自动生成。
EOF
}

validate_mode_arg() {
  local mode="${1:-}"
  case "$mode" in
    remote|local) printf '%s\n' "$mode" ;;
    *) die "模式必须是 remote 或 local。" ;;
  esac
}

main() {
  detect_platform
  setup_paths
  case "${1:-}" in
    "")
      menu
      ;;
    --install)
      install_and_configure
      ;;
    --configure)
      configure_wizard
      ;;
    --configure-server)
      configure_remote
      ;;
    --configure-local)
      configure_local
      ;;
    --configure-server-advanced)
      configure_remote_advanced
      ;;
    --configure-local-advanced)
      configure_local_advanced
      ;;
    --show)
      show_configs
      ;;
    --export)
      export_client_configs "${2:-}"
      ;;
    --start)
      if [ "$PLATFORM" = "linux" ]; then
        start_existing_service "remote"
      else
        start_service "$(validate_mode_arg "${2:-}")"
      fi
      ;;
    --stop)
      if [ "$PLATFORM" = "linux" ]; then
        stop_service "remote"
      else
        stop_service "$(validate_mode_arg "${2:-}")"
      fi
      ;;
    --status)
      if [ "$PLATFORM" = "linux" ]; then
        status_service "remote"
      else
        status_service "$(validate_mode_arg "${2:-}")"
      fi
      ;;
    --uninstall)
      uninstall_all
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
