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
SHADOW_TLS_VERSION="${SHADOW_TLS_VERSION:-latest}"
SHADOW_TLS_SHA256="${SHADOW_TLS_SHA256:-}"
PUBLIC_HOSTS=()
TMP_FILES=()

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

require_linux_debian_systemd() {
  local kernel
  local distro_id=""
  local distro_like=""
  kernel="$(uname -s 2>/dev/null || true)"
  [ "$kernel" = "Linux" ] || die "当前脚本只支持 Linux Debian/Ubuntu VPS 服务端。"

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    distro_id="${ID:-}"
    distro_like="${ID_LIKE:-}"
  fi

  case " ${distro_id} ${distro_like} " in
    *debian*|*ubuntu*) ;;
    *)
      have_cmd apt-get || die "当前 Linux 发行版不是 Debian/Ubuntu 系，且没有 apt-get。"
      warn "未识别为 Debian/Ubuntu，但检测到 apt-get，将按 Debian/Ubuntu 方式继续。"
      ;;
  esac

  have_cmd systemctl || die "未检测到 systemctl；Shadow-TLS 服务管理需要 systemd。"
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

verify_sha256_if_requested() {
  local file="$1"
  local actual=""
  [ -n "$SHADOW_TLS_SHA256" ] || return 0

  if have_cmd sha256sum; then
    actual="$(sha256sum "$file" | awk '{print $1}')"
  elif have_cmd shasum; then
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  else
    die "已设置 SHADOW_TLS_SHA256，但未找到 sha256sum 或 shasum。"
  fi

  if [ "$actual" != "$SHADOW_TLS_SHA256" ]; then
    die "Shadow-TLS SHA256 校验失败：期望 ${SHADOW_TLS_SHA256}，实际 ${actual}。"
  fi
  info "Shadow-TLS SHA256 校验通过。"
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

prompt_shadow_tls_secret() {
  local value
  while true; do
    value="$(prompt_secret "输入 Shadow-TLS 密码")"
    case "$value" in
      *[[:space:]]*) warn "Shadow-TLS 密码不能包含空白字符。" ;;
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
      ''|*[[:space:]]*) warn "Shadow-TLS SNI 不能为空，也不能包含空白字符。" ;;
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

choose_method() {
  local choice
  log "选择加密协议 / method"
  option "1" "chacha20-ietf-poly1305（推荐）"
  option "2" "aes-128-gcm"
  option "3" "aes-256-gcm"
  option "4" "自定义"
  while true; do
    prompt_line "请选择（默认 1：chacha20-ietf-poly1305）: "
    read -r choice
    choice="${choice:-1}"
    case "$choice" in
      1) printf '%s\n' "$DEFAULT_METHOD"; return 0 ;;
      2) printf 'aes-128-gcm\n'; return 0 ;;
      3) printf 'aes-256-gcm\n'; return 0 ;;
      4) prompt_text "输入自定义 method" "$DEFAULT_METHOD"; return 0 ;;
      *) warn "请输入 1-4。" ;;
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
  local existing
  [ -n "$host" ] || return 0
  valid_domain_or_host "$host" || { warn "跳过无效公网地址：${host}"; return 0; }
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

  log "自动查询公网 IPv4 / IPv6，用于生成客户端导入配置。"
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

udp_label() {
  local udp="$1"
  if [ "$udp" = "true" ]; then
    printf 'enabled'
  else
    printf 'disabled'
  fi
}

install_shadowsocks() {
  log "安装 / 检查 ${APP_NAME}"
  run_sudo apt-get update
  run_sudo apt-get install -y shadowsocks-libev curl ca-certificates openssl wget
  command -v ss-server >/dev/null 2>&1 || die "未找到 ss-server 命令，${APP_NAME} 安装可能不完整。"
  info "${APP_NAME} 已就绪。"
}

ensure_shadowsocks() {
  if dpkg -s shadowsocks-libev >/dev/null 2>&1 && command -v ss-server >/dev/null 2>&1; then
    info "检测到 ${APP_NAME} 已安装。"
    if prompt_yes_no "是否重新安装 ${APP_NAME}？选择 n 将使用现有安装继续" "n"; then
      install_shadowsocks
    fi
  else
    warn "未检测到 ${APP_NAME}。"
    if prompt_yes_no "是否现在安装 ${APP_NAME}？" "y"; then
      install_shadowsocks
    else
      die "缺少 ${APP_NAME}，无法继续。"
    fi
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
  install_managed_file "$tmp" "$SS_CONFIG" 600
  rm -f "$tmp"
  info "Shadowsocks 配置已写入：${SS_CONFIG}"
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
    *) die "不支持的架构：${arch}。支持：x86_64、aarch64/arm64。" ;;
  esac
}

install_shadow_tls_binary() {
  local binary
  local url
  local tmp
  binary="$(detect_shadow_tls_binary_name)"
  if [ "$SHADOW_TLS_VERSION" = "latest" ]; then
    url="https://github.com/ihciah/shadow-tls/releases/latest/download/${binary}"
  else
    url="https://github.com/ihciah/shadow-tls/releases/download/${SHADOW_TLS_VERSION}/${binary}"
  fi

  log "安装 / 更新 Shadow-TLS"
  run_sudo apt-get install -y ca-certificates wget openssl
  if [ "$SHADOW_TLS_VERSION" = "latest" ]; then
    warn "将下载 Shadow-TLS latest 版本；如需固定版本，可设置 SHADOW_TLS_VERSION。"
  else
    info "Shadow-TLS 版本：${SHADOW_TLS_VERSION}"
  fi
  if [ -n "$SHADOW_TLS_SHA256" ]; then
    info "已启用 SHA256 校验。"
  else
    warn "未设置 SHADOW_TLS_SHA256，下载后不会校验二进制摘要。"
  fi

  tmp="$(new_tmp_file)"
  info "下载 ${binary}"
  wget -q "$url" -O "$tmp"
  verify_sha256_if_requested "$tmp"
  install_managed_file "$tmp" "$SHADOW_TLS_BIN" 755
  rm -f "$tmp"
  info "Shadow-TLS 已安装：${SHADOW_TLS_BIN}"
}

ensure_shadow_tls() {
  if [ -x "$SHADOW_TLS_BIN" ]; then
    info "检测到 Shadow-TLS 已安装。"
    if prompt_yes_no "是否重新下载 / 更新 Shadow-TLS？选择 n 将使用现有二进制" "n"; then
      install_shadow_tls_binary
    fi
  else
    install_shadow_tls_binary
  fi
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
  info "Shadow-TLS 配置已写入：${SHADOW_TLS_CONFIG}"
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
  info "Shadow-TLS systemd 服务已写入：${SHADOW_TLS_SERVICE}"
}

start_ss_service() {
  run_sudo systemctl restart shadowsocks-libev
  if systemctl is-enabled --quiet shadowsocks-libev 2>/dev/null; then
    info "shadowsocks-libev 已启动，开机自启已启用。"
  else
    if run_sudo systemctl enable shadowsocks-libev >/dev/null 2>&1; then
      info "shadowsocks-libev 已启动，并已设置开机自启。"
    else
      warn "shadowsocks-libev 已启动，但设置开机自启失败；可手动运行 systemctl enable shadowsocks-libev 查看原因。"
    fi
  fi
}

start_shadow_tls_service() {
  [ -f "$SHADOW_TLS_SERVICE" ] || die "Shadow-TLS 服务文件不存在：${SHADOW_TLS_SERVICE}"
  run_sudo systemctl restart shadow-tls.service
  if systemctl is-enabled --quiet shadow-tls.service 2>/dev/null; then
    info "shadow-tls 已启动，开机自启已启用。"
  else
    if run_sudo systemctl enable shadow-tls.service >/dev/null 2>&1; then
      info "shadow-tls 已启动，并已设置开机自启。"
    else
      warn "shadow-tls 已启动，但设置开机自启失败；可手动运行 systemctl enable shadow-tls.service 查看原因。"
    fi
  fi
}

stop_ss_service() {
  run_sudo systemctl stop shadowsocks-libev >/dev/null 2>&1 || true
  info "已停止 shadowsocks-libev。"
}

stop_shadow_tls_service() {
  run_sudo systemctl stop shadow-tls.service >/dev/null 2>&1 || true
  info "已停止 shadow-tls。"
}

status_services() {
  wizard_title "服务状态"
  wizard_line "$(service_state_kind shadowsocks-libev)" "Shadowsocks" "$(service_state_label shadowsocks-libev)"
  if [ -f "$SHADOW_TLS_SERVICE" ] || [ -x "$SHADOW_TLS_BIN" ]; then
    wizard_line "$(service_state_kind shadow-tls.service)" "Shadow-TLS" "$(service_state_label shadow-tls.service)"
  fi

  wizard_section "建议操作"
  if ! systemctl is-active --quiet shadowsocks-libev 2>/dev/null; then
    wizard_action "Shadowsocks 后端未运行：$0 --start"
  fi
  if ! systemctl is-active --quiet shadow-tls.service 2>/dev/null; then
    wizard_action "Shadow-TLS 未运行：$0 --start"
  fi
  wizard_action "查看当前配置：$0 --show"

  wizard_section "systemctl 详情"
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

一行配置:
SS = ss, ${host}, ${port}, encrypt-method=${method}, password=${password}, tfo=${fast_open}, udp-relay=${udp}, shadow-tls-password="${tls_password}", shadow-tls-sni=${tls_sni}, shadow-tls-version=3

Surge [Proxy]:
$(surge_double_quote "$name") = ss, ${host}, ${port}, encrypt-method=$(surge_double_quote "$method"), password=$(surge_double_quote "$password"), udp-relay=${udp}, shadow-tls-password=$(surge_double_quote "$tls_password"), shadow-tls-sni=$(surge_double_quote "$tls_sni"), shadow-tls-version=3, tfo=${fast_open}

Clash / Clash Verge / Mihomo:
# 不同客户端的 Shadow-TLS 字段名可能不同；请按客户端文档调整。
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
  info "客户端导入配置已写入：${SNIPPETS_FILE}"
}

write_commands_file() {
  local tmp
  tmp="$(new_tmp_file)"
  cat >"$tmp" <<EOF
# shadowsocks-libev / Shadow-TLS 常用命令

配置目录:
  ${CONFIG_DIR}

打开菜单:
  $0

安装 / 配置:
  $0 --install-ss-tls
  $0 --configure-tls

服务管理:
  $0 --start
  $0 --stop
  $0 --status

查看配置（默认隐藏 password）:
  $0 --show

查看完整配置（包含 password）:
  $0 --show-raw

导出客户端配置:
  $0 --export [clash|surge|sing-box|line|all]

卸载:
  $0 --uninstall-all
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
  wizard_title "配置完成"
  wizard_line ok "模式" "SS + Shadow-TLS v3"
  wizard_line info "SS 后端" "[\"::1\", \"127.0.0.1\"]:${ss_port}"
  wizard_line info "TLS 公网" "::0:${tls_port}"
  wizard_line info "SNI" "$sni"
  wizard_line info "Method" "$method"
  wizard_line info "UDP relay" "$(bool_label "$udp")"
  wizard_line info "Shadow-TLS FastOpen" "$(bool_label "$fast_open")"
  wizard_line info "SS 配置" "$SS_CONFIG"
  wizard_line info "TLS 配置" "$SHADOW_TLS_CONFIG"
  wizard_line info "TLS 服务" "$SHADOW_TLS_SERVICE"
  [ -f "$SNIPPETS_FILE" ] && wizard_line info "客户端配置" "$SNIPPETS_FILE"

  wizard_section "下一步"
  wizard_action "确认云服务器安全组/防火墙已放行 TCP ${tls_port}。"
  wizard_action "SS 后端端口 ${ss_port} 只监听本机，一般不需要公网放行。"
  wizard_action "查看状态：$0 --status"
  wizard_action "导出客户端配置：$0 --export all"
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

  ss_port="$(prompt_port "SS 后端监听端口" "$(get_ss_port)")"
  method="$(choose_method)"
  ss_password="$(prompt_secret "输入 Shadowsocks 密码")"
  udp="$DEFAULT_UDP"
  info "SS + Shadow-TLS 模式默认启用 UDP relay。"

  tls_port="$(prompt_port "Shadow-TLS 公网监听端口" "$(get_tls_port)")"
  tls_password="$(prompt_shadow_tls_secret)"
  sni="$(prompt_sni "$(get_tls_sni)")"
  if prompt_yes_no "是否启用 Shadow-TLS fastopen？" "$(bool_default_choice "$DEFAULT_FAST_OPEN")"; then
    fast_open="true"
  else
    fast_open="false"
  fi
  name="$(prompt_text "配置名称" "shadowsocks-shadowtls")"
  prompt_public_hosts

  write_ss_config "local" "$ss_port" "$ss_password" "$method" "$udp"
  write_shadow_tls_service "$tls_port" "$ss_port" "$sni" "$tls_password" "$fast_open"
  write_mode_file "ss-tls"
  if [ "${#PUBLIC_HOSTS[@]}" -gt 0 ]; then
    write_client_snippets "ss-tls" "$name" "$tls_port" "$method" "$ss_password" "$udp" "$fast_open" "$tls_password" "$sni" "${PUBLIC_HOSTS[@]}"
  else
    warn "未生成客户端导入配置；之后可重新配置并输入公网 IP/域名。"
  fi
  write_commands_file

  if prompt_yes_no "是否立即启动并设置开机自启？" "y"; then
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

  [ -f "$SS_CONFIG" ] || die "未找到 SS 配置：${SS_CONFIG}。请先安装并配置 SS + Shadow-TLS。"
  ensure_shadow_tls
  ss_port="$(prompt_port "SS 后端端口" "$(get_ss_port)")"
  tls_port="$(prompt_port "Shadow-TLS 公网监听端口" "$(get_tls_port)")"
  tls_password="$(prompt_shadow_tls_secret)"
  sni="$(prompt_sni "$(get_tls_sni)")"
  if prompt_yes_no "是否启用 Shadow-TLS fastopen？" "$(bool_default_choice "$DEFAULT_FAST_OPEN")"; then
    fast_open="true"
  else
    fast_open="false"
  fi
  name="$(prompt_text "配置名称" "shadowsocks-shadowtls")"
  prompt_public_hosts

  method="$(get_ss_method)"
  ss_password="$(get_ss_password)"
  [ -n "$ss_password" ] || die "无法读取 SS 密码，请重新运行 SS + Shadow-TLS 完整配置。"

  write_shadow_tls_service "$tls_port" "$ss_port" "$sni" "$tls_password" "$fast_open"
  write_mode_file "ss-tls"
  if [ "${#PUBLIC_HOSTS[@]}" -gt 0 ]; then
    write_client_snippets "ss-tls" "$name" "$tls_port" "$method" "$ss_password" "$udp" "$fast_open" "$tls_password" "$sni" "${PUBLIC_HOSTS[@]}"
  fi
  write_commands_file

  if prompt_yes_no "是否立即重启 Shadow-TLS？" "y"; then
    start_shadow_tls_service
  fi
  print_summary_ss_tls "$ss_port" "$tls_port" "$method" "$udp" "$sni" "$fast_open"
}

wizard_icon() {
  local kind="$1"
  case "$kind" in
    ok) printf '%b✓%b' "$COLOR_GREEN" "$COLOR_RESET" ;;
    warn) printf '%b!%b' "$COLOR_YELLOW" "$COLOR_RESET" ;;
    err) printf '%b×%b' "$COLOR_RED" "$COLOR_RESET" ;;
    action) printf '%b→%b' "$COLOR_BLUE" "$COLOR_RESET" ;;
    *) printf '%bi%b' "$COLOR_CYAN" "$COLOR_RESET" ;;
  esac
}

wizard_title() {
  local title="$1"
  printf '\n%b✨ %s%b\n' "${COLOR_BOLD}${COLOR_CYAN}" "$title" "$COLOR_RESET" >&2
  printf '%b────────────────────────────────────────────%b\n' "$COLOR_CYAN" "$COLOR_RESET" >&2
}

wizard_section() {
  printf '\n%b◆ %s%b\n' "${COLOR_BOLD}${COLOR_CYAN}" "$1" "$COLOR_RESET" >&2
}

wizard_line() {
  local kind="$1"
  local label="$2"
  local value="$3"
  printf '  %s %b%s%b：%s\n' "$(wizard_icon "$kind")" "$COLOR_YELLOW" "$label" "$COLOR_RESET" "$value" >&2
}

wizard_hint() {
  printf '  %s %s\n' "$(wizard_icon info)" "$1" >&2
}

wizard_action() {
  printf '  %s %s\n' "$(wizard_icon action)" "$1" >&2
}

wizard_menu_option() {
  local number="$1"
  local title="$2"
  local hint="${3:-}"
  printf '  %b%s.%b %s\n' "$COLOR_YELLOW" "$number" "$COLOR_RESET" "$title" >&2
  if [ -n "$hint" ]; then
    printf '     %b%s%b\n' "$COLOR_BLUE" "$hint" "$COLOR_RESET" >&2
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

mask_or_empty() {
  local value="$1"
  if [ -n "$value" ]; then
    printf '********'
  else
    printf '未找到'
  fi
}

bool_label() {
  local value="$1"
  if [ "$value" = "true" ]; then
    printf '启用'
  else
    printf '关闭'
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
  local active="未运行"
  local enabled="未开机自启"
  if systemctl is-active --quiet "$service" 2>/dev/null; then
    active="运行中"
  fi
  if systemctl is-enabled --quiet "$service" 2>/dev/null; then
    enabled="已开机自启"
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
  printf '%b%s%b\n' "$COLOR_BLUE" "$file" "$COLOR_RESET" >&2
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

  wizard_title "当前配置摘要"
  wizard_line info "模式" "$mode_label"
  wizard_line info "配置目录" "$CONFIG_DIR"

  wizard_section "Shadowsocks"
  if [ -f "$SS_CONFIG" ]; then
    ss_port="$(get_ss_port)"
    ss_method="$(get_ss_method)"
    ss_password="$(get_ss_password)"
    ss_udp="$(get_ss_udp)"
    wizard_line info "监听" "${ss_listen}:${ss_port}"
    wizard_line info "Method" "$ss_method"
    wizard_line info "Password" "$(mask_or_empty "$ss_password")"
    wizard_line info "UDP relay" "$(bool_label "$ss_udp")"
    wizard_line "$(service_state_kind shadowsocks-libev)" "服务" "$(service_state_label shadowsocks-libev)"
  else
    wizard_line warn "状态" "未找到配置：${SS_CONFIG}"
  fi

  wizard_section "Shadow-TLS"
  if [ -f "$SHADOW_TLS_SERVICE" ]; then
    tls_port="$(get_tls_port)"
    tls_password="$(get_tls_password)"
    tls_sni="$(get_tls_sni)"
    tls_backend="$(get_tls_backend)"
    tls_fastopen="$(get_tls_fastopen)"
    wizard_line info "监听" "::0:${tls_port}"
    wizard_line info "后端" "$tls_backend"
    wizard_line info "SNI" "$tls_sni"
    wizard_line info "Password" "$(mask_or_empty "$tls_password")"
    wizard_line info "FastOpen" "$(bool_label "$tls_fastopen")"
    wizard_line "$(service_state_kind shadow-tls.service)" "服务" "$(service_state_label shadow-tls.service)"
  else
    wizard_line warn "状态" "未找到服务文件：${SHADOW_TLS_SERVICE}"
  fi

  wizard_section "文件路径"
  [ -f "$SS_CONFIG" ] && wizard_line info "SS 配置" "$SS_CONFIG"
  [ -f "$SHADOW_TLS_CONFIG" ] && wizard_line info "TLS 配置" "$SHADOW_TLS_CONFIG"
  [ -f "$SHADOW_TLS_SERVICE" ] && wizard_line info "TLS 服务" "$SHADOW_TLS_SERVICE"
  [ -f "$SNIPPETS_FILE" ] && wizard_line info "客户端配置" "$SNIPPETS_FILE"
  [ -f "$COMMANDS_FILE" ] && wizard_line info "命令参考" "$COMMANDS_FILE"
  wizard_line info "完整原始内容" "$0 --show-raw"

  wizard_section "推荐操作"
  if [ ! -f "$SS_CONFIG" ]; then
    wizard_action "还没有 SS 配置：建议先运行安装 / 配置向导。"
    has_action="true"
  elif ! systemctl is-active --quiet shadowsocks-libev 2>/dev/null; then
    wizard_action "Shadowsocks 未运行：$0 --start"
    has_action="true"
  fi
  if [ -f "$SHADOW_TLS_SERVICE" ] && ! systemctl is-active --quiet shadow-tls.service 2>/dev/null; then
    wizard_action "Shadow-TLS 未运行：$0 --start"
    has_action="true"
  fi
  if [ -f "$SNIPPETS_FILE" ]; then
    wizard_action "导出客户端配置：$0 --export all"
  else
    wizard_action "需要客户端配置：重新配置时输入公网 IP / 域名。"
  fi
  if [ "$has_action" = "false" ]; then
    wizard_hint "核心配置已就绪；如连接异常，优先检查云防火墙/安全组端口。"
  fi
}

show_configs() {
  local raw="${1:-false}"
  if [ "$raw" = "true" ]; then
    pretty_title "完整配置（包含 password）"
    warn "下面会显示原始密码，请勿公开分享。"
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
    line|LINE|一行配置) printf 'line\n' ;;
    all|ALL|全部) printf 'all\n' ;;
    *) return 1 ;;
  esac
}

choose_export_type() {
  local choice
  log "选择导出类型"
  option "1" "Clash / Clash Verge / Mihomo"
  option "2" "Surge"
  option "3" "sing-box"
  option "4" "一行 ss 配置"
  option "5" "全部"
  while true; do
    prompt_line "请选择（默认 5：全部）: "
    read -r choice
    choice="${choice:-5}"
    case "$choice" in
      1) printf 'clash\n'; return 0 ;;
      2) printf 'surge\n'; return 0 ;;
      3) printf 'singbox\n'; return 0 ;;
      4) printf 'line\n'; return 0 ;;
      5) printf 'all\n'; return 0 ;;
      *) warn "请输入 1-5。" ;;
    esac
  done
}

export_type_label() {
  case "$1" in
    clash) printf 'Clash / Clash Verge / Mihomo' ;;
    surge) printf 'Surge' ;;
    singbox) printf 'sing-box' ;;
    line) printf '一行配置' ;;
    all) printf '全部' ;;
  esac
}

export_section_starts() {
  local export_type="$1"
  local line="$2"
  case "$export_type" in
    clash) [ "$line" = "Clash / Clash Verge / Mihomo:" ] ;;
    surge) [ "$line" = "Surge [Proxy]:" ] ;;
    singbox) [ "$line" = "sing-box outbound:" ] ;;
    line) [ "$line" = "一行配置:" ] ;;
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
    warn "没有在客户端导入配置中找到 $(export_type_label "$export_type") 内容。"
  fi
}

export_client_configs() {
  local export_type="${1:-}"
  if [ ! -f "$SNIPPETS_FILE" ]; then
    warn "还没有生成客户端导入配置。请先运行安装/配置向导并输入公网 IP/域名。"
    return 0
  fi

  if [ -z "$export_type" ]; then
    export_type="$(choose_export_type)"
  elif ! export_type="$(normalize_export_type "$export_type")"; then
    die "导出类型必须是 clash、surge、sing-box、line 或 all。"
  fi

  wizard_title "导出客户端配置：$(export_type_label "$export_type")"
  wizard_hint "来源：${SNIPPETS_FILE}"
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
  wizard_title "完全卸载确认"
  wizard_hint "将停止/禁用服务，并删除以下路径："
  wizard_action "$CONFIG_DIR"
  wizard_action "$SS_CONFIG"
  wizard_action "$SNIPPETS_FILE"
  wizard_action "$COMMANDS_FILE"
  wizard_action "$MODE_FILE"
  wizard_action "$SHADOW_TLS_CONFIG"
  wizard_action "$SHADOW_TLS_SERVICE"
  wizard_action "$SHADOW_TLS_BIN"
  if ! prompt_yes_no "确认完全卸载 SS + Shadow-TLS，并删除所有配置？" "n"; then
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
  info "已完全卸载 SS + Shadow-TLS。"
}

menu_start_stop_choice() {
  local choice
  wizard_title "选择服务范围"
  wizard_menu_option "1" "按当前模式操作" "推荐"
  wizard_menu_option "2" "仅 shadowsocks-libev"
  wizard_menu_option "3" "仅 shadow-tls"
  while true; do
    prompt_line "请选择（默认 1）："
    read -r choice
    choice="${choice:-1}"
    case "$choice" in
      1) printf 'current\n'; return 0 ;;
      2) printf 'ss\n'; return 0 ;;
      3) printf 'tls\n'; return 0 ;;
      *) warn "请输入 1-3。" ;;
    esac
  done
}

menu_header() {
  local mode_label
  mode_label="SS + Shadow-TLS v3"

  wizard_title "Shadowsocks 安装向导"
  wizard_line info "当前模式" "$mode_label"
  wizard_line "$(service_state_kind shadowsocks-libev)" "Shadowsocks 后端" "$(service_state_label shadowsocks-libev)"
  wizard_line "$(service_state_kind shadow-tls.service)" "Shadow-TLS" "$(service_state_label shadow-tls.service)"
  wizard_hint "新 VPS 首次配置建议选择 1：SS + Shadow-TLS。"
}

menu_services() {
  local choice
  local scope
  while true; do
    wizard_title "服务管理"
    wizard_menu_option "1" "启动 / 重启当前模式服务"
    wizard_menu_option "2" "停止当前模式服务"
    wizard_menu_option "3" "查看服务状态"
    wizard_menu_option "4" "高级：选择服务范围启动"
    wizard_menu_option "5" "高级：选择服务范围停止"
    wizard_menu_option "0" "返回主菜单"
    prompt_line "请选择（默认 1）："
    read -r choice
    choice="${choice:-1}"
    case "$choice" in
      1) start_current_services ;;
      2) stop_current_services ;;
      3) status_services ;;
      4)
        scope="$(menu_start_stop_choice)"
        case "$scope" in
          current) start_current_services ;;
          ss) start_ss_service ;;
          tls) start_shadow_tls_service ;;
        esac
        ;;
      5)
        scope="$(menu_start_stop_choice)"
        case "$scope" in
          current) stop_current_services ;;
          ss) stop_ss_service ;;
          tls) stop_shadow_tls_service ;;
        esac
        ;;
      0) return 0 ;;
      *) warn "请输入 0-5。" ;;
    esac
  done
}

menu_reconfigure() {
  local choice
  while true; do
    wizard_title "重新配置"
    wizard_menu_option "1" "重新配置 SS + Shadow-TLS"
    wizard_menu_option "2" "仅重新配置 Shadow-TLS"
    wizard_menu_option "0" "返回主菜单"
    prompt_line "请选择（默认 1）："
    read -r choice
    choice="${choice:-1}"
    case "$choice" in
      1) configure_ss_tls ;;
      2) configure_tls_only ;;
      0) return 0 ;;
      *) warn "请输入 0-2。" ;;
    esac
  done
}

menu_maintenance() {
  local choice
  while true; do
    wizard_title "维护 / 卸载"
    wizard_menu_option "1" "查看完整原始配置" "包含 password，请勿公开分享"
    wizard_menu_option "2" "完全卸载 SS + Shadow-TLS"
    wizard_menu_option "0" "返回主菜单"
    prompt_line "请选择（默认 0：返回）："
    read -r choice
    choice="${choice:-0}"
    case "$choice" in
      1) show_configs true ;;
      2) uninstall_all ;;
      0) return 0 ;;
      *) warn "请输入 0-2。" ;;
    esac
  done
}

menu() {
  local choice
  while true; do
    menu_header
    wizard_section "常用操作"
    wizard_menu_option "1" "安装 / 配置：SS + Shadow-TLS" "公网只暴露 TLS 端口，默认 SNI ${DEFAULT_SNI}"
    wizard_menu_option "2" "查看当前配置摘要"
    wizard_menu_option "3" "导出客户端配置"
    wizard_menu_option "4" "服务管理"
    wizard_menu_option "5" "重新配置"
    wizard_menu_option "6" "维护 / 卸载"
    wizard_menu_option "0" "退出"
    prompt_line "请选择（默认 1：安装 SS + Shadow-TLS）: "
    read -r choice
    choice="${choice:-1}"
    case "$choice" in
      1) configure_ss_tls ;;
      2) show_configs false ;;
      3) export_client_configs ;;
      4) menu_services ;;
      5) menu_reconfigure ;;
      6) menu_maintenance ;;
      0) exit 0 ;;
      *) warn "请输入 0-6。" ;;
    esac
  done
}

usage() {
  cat <<EOF
用法:
  $0                         # 打开彩色安装向导，默认安装 SS + Shadow-TLS
  $0 --install-ss-tls        # 智能安装并配置 SS + Shadow-TLS
  $0 --configure-tls         # 仅重新配置 Shadow-TLS
  $0 --start                 # 启动/重启 SS 后端和 Shadow-TLS
  $0 --stop                  # 停止 Shadow-TLS 和 SS 后端
  $0 --status                # 查看服务状态摘要和 systemctl 详情
  $0 --show                  # 查看配置摘要、服务状态和文件路径，隐藏 password
  $0 --show-raw              # 查看原始配置文件，包含 password
  $0 --export [clash|surge|sing-box|line|all]
  $0 --uninstall-all
  $0 -h|--help

说明:
  - 只支持 Linux Debian/Ubuntu + systemd。
  - 只安装 SS + Shadow-TLS 模式：ss-server 只监听 ["::1", "127.0.0.1"]，Shadow-TLS 默认公网监听 ${DEFAULT_SHADOW_TLS_PORT}。
  - 默认 method：${DEFAULT_METHOD}。
  - 默认 Shadow-TLS SNI：${DEFAULT_SNI}。
EOF
}

main() {
  require_linux_debian_systemd
  case "${1:-}" in
    "") menu ;;
    --install-ss-tls) configure_ss_tls ;;
    --configure-tls) configure_tls_only ;;
    --start) start_current_services ;;
    --stop) stop_current_services ;;
    --status) status_services ;;
    --show) show_configs false ;;
    --show-raw) show_configs true ;;
    --export) export_client_configs "${2:-}" ;;
    --uninstall-all) uninstall_all ;;
    -h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
