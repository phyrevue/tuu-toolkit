#!/usr/bin/env bash

# TUU Toolkit 一键管理脚本
# 项目地址: https://github.com/phyrevue/tuu-toolkit
# 支持: Debian/Ubuntu, Alpine, CentOS/RHEL/Rocky/Alma
# Version: 2.0.0

set -o pipefail

TOOL_VERSION="2.0.0"
REPO_URL="https://github.com/phyrevue/tuu-toolkit"
RAW_URL="https://raw.githubusercontent.com/phyrevue/tuu-toolkit/main/tuu-toolkit.sh"
LOG_FILE="/var/log/tuu-toolkit.log"

GOST_DIR="/etc/gost"
GOST_CONFIG="$GOST_DIR/config.yaml"
GOST_BIN="/usr/local/bin/gost"
GOST_SERVICE="gost"

SS_DIR="/etc/ss-rust"
SS_CONFIG="$SS_DIR/config.json"
SS_BIN="/usr/local/bin/ssserver"
SS_VERSION_FILE="$SS_DIR/version"
SS_SERVICE="ss-rust"

REALM_DIR="/root/realm"
REALM_CONFIG="$REALM_DIR/config.toml"
REALM_BIN="$REALM_DIR/realm"
REALM_SERVICE="realm"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

OS_ID=""
OS_NAME=""
OS_FAMILY=""
PKG_MANAGER=""
SERVICE_MANAGER=""
LIBC_KIND=""
ARCH_RAW=""

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

clear_screen() {
    if [[ -t 1 && -n "${TERM:-}" ]] && command -v clear >/dev/null 2>&1; then
        command clear
    else
        printf '\n'
    fi
}

write_log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

pause() {
    if [[ -t 0 ]]; then
        read -r -p "按回车键继续..."
    fi
}

confirm() {
    local prompt="${1:-确认继续?}"
    local answer
    read -r -p "$prompt [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        exit 1
    fi
}

need_bash() {
    if [[ -z "${BASH_VERSION:-}" ]]; then
        echo "请使用 bash 运行本脚本。Alpine 可先执行: apk add --no-cache bash"
        exit 1
    fi
}

detect_os() {
    OS_ID=""
    OS_NAME=""
    OS_FAMILY=""
    PKG_MANAGER=""

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_NAME="${PRETTY_NAME:-${NAME:-unknown}}"
        local like="${ID_LIKE:-}"
        case "$OS_ID $like" in
            *alpine*)
                OS_FAMILY="alpine"
                PKG_MANAGER="apk"
                ;;
            *debian*|*ubuntu*)
                OS_FAMILY="debian"
                PKG_MANAGER="apt-get"
                ;;
            *centos*|*rhel*|*fedora*|*rocky*|*almalinux*)
                OS_FAMILY="centos"
                if command -v dnf >/dev/null 2>&1; then
                    PKG_MANAGER="dnf"
                else
                    PKG_MANAGER="yum"
                fi
                ;;
        esac
    fi

    if [[ -z "$OS_FAMILY" ]]; then
        if command -v apk >/dev/null 2>&1; then
            OS_FAMILY="alpine"
            PKG_MANAGER="apk"
            OS_NAME="Alpine Linux"
        elif command -v apt-get >/dev/null 2>&1; then
            OS_FAMILY="debian"
            PKG_MANAGER="apt-get"
            OS_NAME="Debian/Ubuntu"
        elif command -v dnf >/dev/null 2>&1; then
            OS_FAMILY="centos"
            PKG_MANAGER="dnf"
            OS_NAME="CentOS/RHEL compatible"
        elif command -v yum >/dev/null 2>&1; then
            OS_FAMILY="centos"
            PKG_MANAGER="yum"
            OS_NAME="CentOS/RHEL compatible"
        else
            log_error "不支持的操作系统，当前仅支持 Debian/Ubuntu、Alpine、CentOS/RHEL/Rocky/Alma"
            exit 1
        fi
    fi
}

detect_service_manager() {
    if [[ "$OS_FAMILY" == "alpine" ]]; then
        SERVICE_MANAGER="openrc"
    elif [[ "$OS_FAMILY" == "debian" || "$OS_FAMILY" == "centos" ]]; then
        SERVICE_MANAGER="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        SERVICE_MANAGER="openrc"
    elif command -v systemctl >/dev/null 2>&1; then
        SERVICE_MANAGER="systemd"
    else
        SERVICE_MANAGER="none"
    fi
}

detect_libc() {
    LIBC_KIND="gnu"
    if [[ "$OS_FAMILY" == "alpine" ]]; then
        LIBC_KIND="musl"
    elif ldd --version 2>&1 | grep -qi musl; then
        LIBC_KIND="musl"
    fi
}

detect_arch_raw() {
    ARCH_RAW="$(uname -m)"
}

init_context() {
    detect_os
    detect_service_manager
    detect_libc
    detect_arch_raw
}

print_system_info() {
    init_context
    echo "TUU Toolkit: $TOOL_VERSION"
    echo "系统: ${OS_NAME:-unknown}"
    echo "系统族: $OS_FAMILY"
    echo "包管理器: $PKG_MANAGER"
    echo "服务管理: $SERVICE_MANAGER"
    echo "libc: $LIBC_KIND"
    echo "架构: $ARCH_RAW"
}

map_packages() {
    local mapped=()
    local pkg
    for pkg in "$@"; do
        case "$OS_FAMILY:$pkg" in
            debian:xz) mapped+=("xz-utils") ;;
            debian:procps) mapped+=("procps") ;;
            debian:cron) mapped+=("cron") ;;
            alpine:xz) mapped+=("xz") ;;
            alpine:procps) mapped+=("procps") ;;
            alpine:cron) mapped+=("dcron") ;;
            centos:xz) mapped+=("xz") ;;
            centos:procps) mapped+=("procps-ng") ;;
            centos:cron) mapped+=("cronie") ;;
            *) mapped+=("$pkg") ;;
        esac
    done
    printf '%s\n' "${mapped[@]}"
}

install_packages() {
    require_root
    init_context
    local requested=("$@")
    local packages=()
    local pkg
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && packages+=("$pkg")
    done < <(map_packages "${requested[@]}")

    if [[ ${#packages[@]} -eq 0 ]]; then
        return 0
    fi

    log_info "安装依赖: ${packages[*]}"
    case "$PKG_MANAGER" in
        apt-get)
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
            ;;
        apk)
            apk update
            apk add --no-cache "${packages[@]}"
            ;;
        dnf)
            dnf install -y --allowerasing "${packages[@]}"
            ;;
        yum)
            yum install -y "${packages[@]}"
            ;;
        *)
            log_error "找不到可用包管理器"
            return 1
            ;;
    esac
}

install_core_dependencies() {
    install_packages bash curl wget tar gzip ca-certificates sed grep procps openssl
}

install_archive_dependencies() {
    install_packages bash curl wget tar gzip ca-certificates sed grep procps openssl xz
}

ensure_service_dependencies() {
    init_context
    if [[ "$SERVICE_MANAGER" == "openrc" ]]; then
        if ! command -v rc-service >/dev/null 2>&1 || ! command -v rc-update >/dev/null 2>&1; then
            install_packages openrc
        fi
        mkdir -p /etc/init.d
    fi
}

download_file() {
    local url="$1"
    local output="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 20 --retry 2 -o "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate -O "$output" "$url"
    else
        log_error "缺少 curl 或 wget"
        return 1
    fi
}

get_latest_tag() {
    local repo="$1"
    local fallback="$2"
    local tag=""
    local json=""

    if command -v curl >/dev/null 2>&1; then
        json="$(curl -fsSL --connect-timeout 15 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null || true)"
    elif command -v wget >/dev/null 2>&1; then
        json="$(wget -qO- "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null || true)"
    fi

    tag="$(printf '%s' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    if [[ -z "$tag" ]]; then
        tag="$fallback"
    fi
    echo "$tag"
}

gost_arch() {
    case "$ARCH_RAW" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7) echo "armv7" ;;
        i386|i686) echo "386" ;;
        *) echo "" ;;
    esac
}

linux_rust_target() {
    local libc="${1:-$LIBC_KIND}"
    case "$ARCH_RAW" in
        x86_64|amd64) echo "x86_64-unknown-linux-${libc}" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-${libc}" ;;
        armv7l|armv7)
            if [[ "$libc" == "musl" ]]; then
                echo "armv7-unknown-linux-musleabihf"
            else
                echo "armv7-unknown-linux-gnueabihf"
            fi
            ;;
        armv6l)
            if [[ "$libc" == "musl" ]]; then
                echo "arm-unknown-linux-musleabihf"
            else
                echo "arm-unknown-linux-gnueabihf"
            fi
            ;;
        i386|i686)
            if [[ "$libc" == "musl" ]]; then
                echo "i686-unknown-linux-musl"
            else
                echo ""
            fi
            ;;
        *) echo "" ;;
    esac
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

yaml_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

random_port() {
    local port
    port="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')"
    port=$(( port % 55535 + 10000 ))
    echo "$port"
}

random_password() {
    local bytes="${1:-24}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 "$bytes"
    elif command -v head >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1; then
        head -c "$bytes" /dev/urandom | base64
    else
        date +%s%N | sha256sum | awk '{print $1}'
    fi
}

systemd_is_running() {
    [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
}

reload_service_manager() {
    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        if systemd_is_running; then
            systemctl daemon-reload || true
        else
            log_warn "systemd 未运行，已生成服务文件但跳过 daemon-reload"
        fi
    fi
}

enable_service() {
    local service="$1"
    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        if systemd_is_running; then
            systemctl enable "$service" || true
        else
            log_warn "systemd 未运行，跳过 enable $service"
        fi
    elif [[ "$SERVICE_MANAGER" == "openrc" ]]; then
        if command -v rc-update >/dev/null 2>&1; then
            rc-update add "$service" default >/dev/null 2>&1 || true
        fi
    fi
}

service_action() {
    local service="$1"
    local action="$2"
    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        if systemd_is_running; then
            systemctl "$action" "$service"
        else
            log_warn "systemd 未运行，无法执行: systemctl $action $service"
            return 1
        fi
    elif [[ "$SERVICE_MANAGER" == "openrc" ]]; then
        if command -v rc-service >/dev/null 2>&1; then
            rc-service "$service" "$action"
        else
            log_warn "OpenRC 不可用，无法执行: rc-service $service $action"
            return 1
        fi
    else
        log_warn "未知服务管理器，无法管理 $service"
        return 1
    fi
}

service_status_text() {
    local service="$1"
    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        if systemd_is_running && systemctl is-active --quiet "$service"; then
            echo "运行中"
        elif systemd_is_running; then
            echo "未运行"
        else
            echo "systemd 未运行"
        fi
    elif [[ "$SERVICE_MANAGER" == "openrc" ]]; then
        if command -v rc-service >/dev/null 2>&1 && rc-service "$service" status >/dev/null 2>&1; then
            echo "运行中"
        else
            echo "未运行"
        fi
    else
        echo "无法检测"
    fi
}

open_firewall_port() {
    local port="$1"
    local proto="${2:-tcp}"

    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        log_success "firewalld 已放行 ${port}/${proto}"
    elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
        log_success "ufw 已放行 ${port}/${proto}"
    elif command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
            iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
        log_success "iptables 已尝试放行 ${port}/${proto}"
    else
        log_warn "未检测到可自动配置的防火墙，请手动放行 ${port}/${proto}"
    fi
}

write_systemd_service() {
    local path="/etc/systemd/system/$1.service"
    local description="$2"
    local exec_start="$3"
    local read_write_paths="${4:-}"

    mkdir -p /etc/systemd/system
    cat > "$path" <<EOF
[Unit]
Description=$description
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$exec_start
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
EOF

    if [[ -n "$read_write_paths" ]]; then
        cat >> "$path" <<EOF
ReadWritePaths=$read_write_paths
EOF
    fi

    cat >> "$path" <<'EOF'

[Install]
WantedBy=multi-user.target
EOF
}

write_openrc_service() {
    local path="/etc/init.d/$1"
    local description="$2"
    local command="$3"
    local command_args="$4"
    local output_log="${5:-/var/log/$1.log}"
    local error_log="${6:-/var/log/$1.err}"

    mkdir -p /etc/init.d
    cat > "$path" <<EOF
#!/sbin/openrc-run

name="$1"
description="$description"
command="$command"
command_args="$command_args"
command_user="root"
command_background="yes"
pidfile="/run/$1.pid"
output_log="$output_log"
error_log="$error_log"

depend() {
    need net
    after firewall
}
EOF
    chmod +x "$path"
}

create_gost_service() {
    init_context
    ensure_service_dependencies
    mkdir -p /var/log/gost
    if [[ "$SERVICE_MANAGER" == "openrc" ]]; then
        write_openrc_service "$GOST_SERVICE" "GOST Proxy Service" "$GOST_BIN" "-C $GOST_CONFIG" "/var/log/gost/gost.log" "/var/log/gost/gost.err"
    else
        write_systemd_service "$GOST_SERVICE" "GOST Proxy Service" "$GOST_BIN -C $GOST_CONFIG" "/var/log/gost"
    fi
    reload_service_manager
    enable_service "$GOST_SERVICE"
}

write_gost_config() {
    local port="$1"
    local bind_addr="$2"
    local use_auth="$3"
    local username="${4:-}"
    local password="${5:-}"
    local log_level="${6:-warn}"

    mkdir -p "$GOST_DIR" /var/log/gost
    if [[ "$use_auth" == "true" ]]; then
        cat > "$GOST_CONFIG" <<EOF
# TUU Toolkit generated GOST SOCKS5 config
services:
- name: socks5-service
  addr: "${bind_addr}:${port}"
  handler:
    type: socks5
    auth:
      username: "$(yaml_escape "$username")"
      password: "$(yaml_escape "$password")"
  listener:
    type: tcp

log:
  level: ${log_level}
  output: /var/log/gost/gost.log
EOF
    else
        cat > "$GOST_CONFIG" <<EOF
# TUU Toolkit generated GOST SOCKS5 config
services:
- name: socks5-service
  addr: "${bind_addr}:${port}"
  handler:
    type: socks5
  listener:
    type: tcp

log:
  level: ${log_level}
  output: /var/log/gost/gost.log
EOF
    fi
    chmod 600 "$GOST_CONFIG"
}

install_gost_binary() {
    install_core_dependencies || return 1
    init_context
    local tag version arch url tmp
    tag="$(get_latest_tag "go-gost/gost" "v3.2.6")"
    version="${tag#v}"
    arch="$(gost_arch)"
    if [[ -z "$arch" ]]; then
        log_error "GOST 不支持当前架构: $ARCH_RAW"
        return 1
    fi
    url="https://github.com/go-gost/gost/releases/download/${tag}/gost_${version}_linux_${arch}.tar.gz"
    tmp="$(mktemp -d /tmp/tuu-gost.XXXXXX)"
    log_info "下载 GOST: $url"
    if ! download_file "$url" "$tmp/gost.tar.gz"; then
        rm -rf "$tmp"
        return 1
    fi
    tar -xzf "$tmp/gost.tar.gz" -C "$tmp"
    if [[ ! -f "$tmp/gost" ]]; then
        log_error "解压后未找到 gost 可执行文件"
        rm -rf "$tmp"
        return 1
    fi
    install -m 755 "$tmp/gost" "$GOST_BIN"
    rm -rf "$tmp"
    log_success "GOST ${tag} 安装完成: $GOST_BIN"
}

install_or_update_gost() {
    require_root
    init_context

    local port bind_addr use_auth username password log_level
    if [[ -n "${PORT:-}" ]]; then
        port="$PORT"
    else
        read -r -p "SOCKS5 端口 [默认 1080]: " port
        port="${port:-1080}"
    fi
    if ! valid_port "$port"; then
        log_error "端口必须在 1-65535 之间"
        return 1
    fi

    bind_addr="${BIND_ADDR:-}"
    if [[ -z "$bind_addr" ]]; then
        read -r -p "绑定地址 [默认 0.0.0.0]: " bind_addr
        bind_addr="${bind_addr:-0.0.0.0}"
    fi

    use_auth="${USE_AUTH:-}"
    if [[ -z "$use_auth" ]]; then
        local auth_answer
        read -r -p "是否启用用户名密码认证? [y/N]: " auth_answer
        if [[ "$auth_answer" =~ ^[Yy]$ ]]; then
            use_auth="true"
        else
            use_auth="false"
        fi
    fi

    if [[ "$use_auth" == "true" ]]; then
        username="${USERNAME:-}"
        password="${PASSWORD:-}"
        [[ -z "$username" ]] && read -r -p "用户名: " username
        [[ -z "$password" ]] && read -r -s -p "密码: " password && echo
        if [[ -z "$username" || -z "$password" ]]; then
            log_error "启用认证时用户名和密码不能为空"
            return 1
        fi
    else
        username=""
        password=""
    fi

    log_level="${LOG_LEVEL:-warn}"
    install_gost_binary || return 1
    write_gost_config "$port" "$bind_addr" "$use_auth" "$username" "$password" "$log_level"
    create_gost_service
    open_firewall_port "$port" tcp
    service_action "$GOST_SERVICE" restart || log_warn "服务未能自动重启，请在完整 init 环境中手动启动"
    log_success "GOST SOCKS5 配置完成"
}

show_gost_info() {
    echo -e "${CYAN}GOST 状态:${NC} $(service_status_text "$GOST_SERVICE")"
    echo -e "${CYAN}二进制:${NC} $GOST_BIN"
    echo -e "${CYAN}配置文件:${NC} $GOST_CONFIG"
    if [[ -x "$GOST_BIN" ]]; then
        "$GOST_BIN" -V 2>/dev/null || true
    fi
    if [[ -f "$GOST_CONFIG" ]]; then
        echo
        sed -n '1,160p' "$GOST_CONFIG"
    fi
}

uninstall_gost() {
    require_root
    if ! confirm "确认卸载 GOST 配置和服务?"; then
        return
    fi
    service_action "$GOST_SERVICE" stop || true
    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        if systemd_is_running; then
            systemctl disable "$GOST_SERVICE" >/dev/null 2>&1 || true
        fi
        rm -f "/etc/systemd/system/${GOST_SERVICE}.service"
    else
        if command -v rc-update >/dev/null 2>&1; then
            rc-update del "$GOST_SERVICE" default >/dev/null 2>&1 || true
        fi
        rm -f "/etc/init.d/${GOST_SERVICE}"
    fi
    rm -rf "$GOST_DIR"
    rm -f "$GOST_BIN"
    reload_service_manager
    log_success "GOST 已卸载"
}

ss_arch() {
    linux_rust_target "$LIBC_KIND"
}

install_ss_binary() {
    install_archive_dependencies || return 1
    init_context
    local tag version arch file url tmp
    tag="$(get_latest_tag "shadowsocks/shadowsocks-rust" "v1.24.0")"
    version="${tag#v}"
    arch="$(ss_arch)"
    if [[ -z "$arch" ]]; then
        log_error "Shadowsocks Rust 不支持当前架构: $ARCH_RAW / $LIBC_KIND"
        return 1
    fi
    file="shadowsocks-v${version}.${arch}.tar.xz"
    url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${version}/${file}"
    tmp="$(mktemp -d /tmp/tuu-ss.XXXXXX)"
    mkdir -p "$SS_DIR"
    log_info "下载 Shadowsocks Rust: $url"
    if ! download_file "$url" "$tmp/$file"; then
        rm -rf "$tmp"
        return 1
    fi
    tar -xf "$tmp/$file" -C "$tmp"
    if [[ ! -f "$tmp/ssserver" ]]; then
        log_error "解压后未找到 ssserver"
        rm -rf "$tmp"
        return 1
    fi
    install -m 755 "$tmp/ssserver" "$SS_BIN"
    echo "v${version}" > "$SS_VERSION_FILE"
    rm -rf "$tmp"
    log_success "Shadowsocks Rust v${version} 安装完成: $SS_BIN"
}

write_ss_config() {
    local port="$1"
    local password="$2"
    local method="$3"
    local fast_open="$4"
    local dns="${5:-}"

    mkdir -p "$SS_DIR"
    local password_json method_json dns_json
    password_json="$(json_escape "$password")"
    method_json="$(json_escape "$method")"
    if [[ -n "$dns" ]]; then
        dns_json=",\n    \"nameserver\": \"$(json_escape "$dns")\""
    else
        dns_json=""
    fi
    {
        printf '{\n'
        printf '    "server": "::",\n'
        printf '    "server_port": %s,\n' "$port"
        printf '    "password": "%s",\n' "$password_json"
        printf '    "method": "%s",\n' "$method_json"
        printf '    "fast_open": %s,\n' "$fast_open"
        printf '    "mode": "tcp_and_udp",\n'
        printf '    "timeout": 300'
        printf '%b\n' "$dns_json"
        printf '}\n'
    } > "$SS_CONFIG"
    chmod 600 "$SS_CONFIG"
}

create_ss_service() {
    init_context
    ensure_service_dependencies
    if [[ "$SERVICE_MANAGER" == "openrc" ]]; then
        write_openrc_service "$SS_SERVICE" "Shadowsocks Rust Service" "$SS_BIN" "-c $SS_CONFIG" "/var/log/ss-rust.log" "/var/log/ss-rust.err"
    else
        write_systemd_service "$SS_SERVICE" "Shadowsocks Rust Service" "$SS_BIN -c $SS_CONFIG" "$SS_DIR"
    fi
    reload_service_manager
    enable_service "$SS_SERVICE"
}

choose_ss_method() {
    local choice method
    echo "请选择 Shadowsocks 加密方式:" >&2
    echo "1) 2022-blake3-aes-256-gcm (默认)" >&2
    echo "2) 2022-blake3-chacha20-poly1305" >&2
    echo "3) aes-256-gcm" >&2
    echo "4) chacha20-ietf-poly1305" >&2
    read -r -p "选项 [1-4]: " choice
    case "${choice:-1}" in
        1) method="2022-blake3-aes-256-gcm" ;;
        2) method="2022-blake3-chacha20-poly1305" ;;
        3) method="aes-256-gcm" ;;
        4) method="chacha20-ietf-poly1305" ;;
        *) method="2022-blake3-aes-256-gcm" ;;
    esac
    echo "$method"
}

default_ss_password_bytes() {
    case "$1" in
        2022-blake3-aes-128-gcm) echo 16 ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305|2022-blake3-chacha8-poly1305) echo 32 ;;
        *) echo 24 ;;
    esac
}

install_or_update_ss() {
    require_root
    init_context
    local port method password fast_open dns suggested_port

    suggested_port="$(random_port)"
    read -r -p "SS 端口 [默认 ${suggested_port}]: " port
    port="${port:-$suggested_port}"
    if ! valid_port "$port"; then
        log_error "端口必须在 1-65535 之间"
        return 1
    fi

    method="$(choose_ss_method)"
    read -r -p "SS 密码 [默认自动生成]: " password
    if [[ -z "$password" ]]; then
        password="$(random_password "$(default_ss_password_bytes "$method")")"
    fi

    read -r -p "是否开启 TCP Fast Open? [y/N]: " fast_open
    if [[ "$fast_open" =~ ^[Yy]$ ]]; then
        fast_open="true"
    else
        fast_open="false"
    fi
    read -r -p "DNS 服务器 [可空]: " dns

    install_ss_binary || return 1
    write_ss_config "$port" "$password" "$method" "$fast_open" "$dns"
    create_ss_service
    open_firewall_port "$port" tcp
    open_firewall_port "$port" udp
    service_action "$SS_SERVICE" restart || log_warn "服务未能自动重启，请在完整 init 环境中手动启动"

    echo
    log_success "Shadowsocks Rust 配置完成"
    echo "端口: $port"
    echo "密码: $password"
    echo "加密: $method"
}

show_ss_info() {
    echo -e "${CYAN}SS 状态:${NC} $(service_status_text "$SS_SERVICE")"
    echo -e "${CYAN}二进制:${NC} $SS_BIN"
    echo -e "${CYAN}配置文件:${NC} $SS_CONFIG"
    [[ -f "$SS_VERSION_FILE" ]] && echo -e "${CYAN}版本:${NC} $(cat "$SS_VERSION_FILE")"
    if [[ -f "$SS_CONFIG" ]]; then
        echo
        sed -n '1,120p' "$SS_CONFIG"
    fi
}

uninstall_ss() {
    require_root
    if ! confirm "确认卸载 Shadowsocks Rust?"; then
        return
    fi
    service_action "$SS_SERVICE" stop || true
    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        if systemd_is_running; then
            systemctl disable "$SS_SERVICE" >/dev/null 2>&1 || true
        fi
        rm -f "/etc/systemd/system/${SS_SERVICE}.service"
    else
        if command -v rc-update >/dev/null 2>&1; then
            rc-update del "$SS_SERVICE" default >/dev/null 2>&1 || true
        fi
        rm -f "/etc/init.d/${SS_SERVICE}"
    fi
    rm -rf "$SS_DIR"
    rm -f "$SS_BIN"
    reload_service_manager
    log_success "Shadowsocks Rust 已卸载"
}

realm_arch() {
    linux_rust_target "$LIBC_KIND"
}

create_default_realm_config() {
    mkdir -p "$REALM_DIR"
    if [[ ! -f "$REALM_CONFIG" ]]; then
        cat > "$REALM_CONFIG" <<'EOF'
[network]
no_tcp = false
use_udp = true
EOF
    fi
}

create_realm_service() {
    init_context
    ensure_service_dependencies
    mkdir -p "$REALM_DIR" /var/log
    if [[ "$SERVICE_MANAGER" == "openrc" ]]; then
        write_openrc_service "$REALM_SERVICE" "Realm Proxy Service" "$REALM_BIN" "-c $REALM_CONFIG" "/var/log/realm.log" "/var/log/realm.err"
    else
        write_systemd_service "$REALM_SERVICE" "Realm Proxy Service" "$REALM_BIN -c $REALM_CONFIG" "$REALM_DIR /var/log"
    fi
    reload_service_manager
    enable_service "$REALM_SERVICE"
}

install_or_update_realm() {
    require_root
    install_core_dependencies || return 1
    init_context
    local tag version arch url tmp
    tag="$(get_latest_tag "zhboner/realm" "v2.9.4")"
    version="${tag#v}"
    arch="$(realm_arch)"
    if [[ -z "$arch" ]]; then
        log_error "Realm 不支持当前架构: $ARCH_RAW / $LIBC_KIND"
        return 1
    fi
    url="https://github.com/zhboner/realm/releases/download/v${version}/realm-${arch}.tar.gz"
    tmp="$(mktemp -d /tmp/tuu-realm.XXXXXX)"
    mkdir -p "$REALM_DIR"
    log_info "下载 Realm: $url"
    if ! download_file "$url" "$tmp/realm.tar.gz"; then
        rm -rf "$tmp"
        return 1
    fi
    tar -xzf "$tmp/realm.tar.gz" -C "$tmp"
    if [[ ! -f "$tmp/realm" ]]; then
        log_error "解压后未找到 realm 主程序"
        rm -rf "$tmp"
        return 1
    fi
    install -m 755 "$tmp/realm" "$REALM_BIN"
    rm -rf "$tmp"
    create_default_realm_config
    create_realm_service
    write_log "Realm installed/updated ${tag}"
    log_success "Realm ${tag} 安装/更新完成"
}

realm_service_restart_if_ready() {
    if [[ -x "$REALM_BIN" ]]; then
        service_action "$REALM_SERVICE" restart || log_warn "Realm 服务未能自动重启，请在完整 init 环境中手动启动"
    fi
}

show_realm_rules() {
    echo -e "                   ${YELLOW}当前 Realm 转发规则${NC}"
    echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
    printf "%-5s| %-30s| %-40s| %-20s\n" "序号" "本地地址:端口" "目标地址:端口" "备注"
    echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"

    if [[ ! -f "$REALM_CONFIG" ]]; then
        log_error "配置文件不存在: $REALM_CONFIG"
        return 1
    fi

    local lines=()
    mapfile -t lines < <(grep -n 'listen =' "$REALM_CONFIG" || true)
    if [[ ${#lines[@]} -eq 0 ]]; then
        echo "没有发现任何转发规则。"
        return 0
    fi

    local index=1
    local line line_number listen_info remote_info remark
    for line in "${lines[@]}"; do
        line_number="$(echo "$line" | cut -d ':' -f 1)"
        listen_info="$(sed -n "${line_number}p" "$REALM_CONFIG" | cut -d '"' -f 2)"
        remote_info="$(sed -n "$((line_number + 1))p" "$REALM_CONFIG" | cut -d '"' -f 2)"
        remark="$(sed -n "$((line_number - 1))p" "$REALM_CONFIG" | sed -n 's/^# 备注:[[:space:]]*//p')"
        printf "%-5s| %-30s| %-40s| %-20s\n" "$index" "$listen_info" "$remote_info" "$remark"
        echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
        index=$((index + 1))
    done
}

add_realm_rule() {
    require_root
    create_default_realm_config
    local local_port remote_host remote_port remark ip_choice listen_addr

    read -r -p "本地监听端口: " local_port
    if ! valid_port "$local_port"; then
        log_error "本地端口必须在 1-65535 之间"
        return 1
    fi
    read -r -p "目标服务器 IP/域名: " remote_host
    read -r -p "目标端口: " remote_port
    if [[ -z "$remote_host" ]] || ! valid_port "$remote_port"; then
        log_error "目标地址不能为空，目标端口必须在 1-65535 之间"
        return 1
    fi
    read -r -p "规则备注: " remark

    echo
    echo "请选择监听模式:"
    echo "1) 双栈监听 [::]:${local_port} (默认)"
    echo "2) 仅 IPv4 监听 0.0.0.0:${local_port}"
    echo "3) 自定义监听地址"
    read -r -p "选项 [1-3]: " ip_choice
    case "${ip_choice:-1}" in
        1) listen_addr="[::]:$local_port" ;;
        2) listen_addr="0.0.0.0:$local_port" ;;
        3)
            read -r -p "完整监听地址，例如 0.0.0.0:80 或 [::]:443: " listen_addr
            if [[ ! "$listen_addr" =~ .+:[0-9]+$ ]]; then
                log_error "监听地址格式错误"
                return 1
            fi
            ;;
        *) listen_addr="[::]:$local_port" ;;
    esac

    cat >> "$REALM_CONFIG" <<EOF

[[endpoints]]
# 备注: $remark
listen = "$listen_addr"
remote = "$remote_host:$remote_port"
EOF
    write_log "Realm rule added: $listen_addr -> $remote_host:$remote_port"
    open_firewall_port "$local_port" tcp
    open_firewall_port "$local_port" udp
    realm_service_restart_if_ready
    log_success "Realm 规则添加成功"
}

delete_realm_rule() {
    require_root
    if [[ ! -f "$REALM_CONFIG" ]]; then
        log_error "配置文件不存在: $REALM_CONFIG"
        return 1
    fi

    show_realm_rules
    local lines=()
    mapfile -t lines < <(grep -n '^\[\[endpoints\]\]' "$REALM_CONFIG" || true)
    if [[ ${#lines[@]} -eq 0 ]]; then
        return 0
    fi

    local choice start_line next_line end_line
    read -r -p "请输入要删除的规则序号，直接回车返回: " choice
    [[ -z "$choice" ]] && return 0
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#lines[@]} )); then
        log_error "无效序号"
        return 1
    fi

    start_line="$(echo "${lines[$((choice - 1))]}" | cut -d ':' -f 1)"
    next_line="$(grep -n '^\[\[endpoints\]\]' "$REALM_CONFIG" | awk -F: -v s="$start_line" '$1 > s {print $1; exit}')"
    if [[ -z "$next_line" ]]; then
        end_line="$(wc -l < "$REALM_CONFIG")"
    else
        end_line=$((next_line - 1))
    fi

    sed -i "${start_line},${end_line}d" "$REALM_CONFIG"
    sed -i '/^[[:space:]]*$/d' "$REALM_CONFIG"
    write_log "Realm rule deleted: $choice"
    realm_service_restart_if_ready
    log_success "Realm 规则已删除"
}

manage_realm_cron() {
    require_root
    init_context
    echo "1) 添加每日重启任务"
    echo "2) 删除所有 Realm 定时任务"
    echo "3) 查看当前 Realm 定时任务"
    read -r -p "请选择: " choice

    local hour
    case "$choice" in
        1)
            read -r -p "输入每日重启时间，0-23: " hour
            if ! [[ "$hour" =~ ^[0-9]+$ ]] || (( hour < 0 || hour > 23 )); then
                log_error "时间无效"
                return 1
            fi
            install_packages cron
            if [[ "$SERVICE_MANAGER" == "openrc" ]]; then
                mkdir -p /etc/crontabs
                touch /etc/crontabs/root
                sed -i '/realm/d' /etc/crontabs/root
                echo "0 $hour * * * rc-service realm restart" >> /etc/crontabs/root
                if command -v rc-update >/dev/null 2>&1; then
                    rc-update add crond default >/dev/null 2>&1 || true
                fi
                if command -v rc-service >/dev/null 2>&1; then
                    rc-service crond restart >/dev/null 2>&1 || true
                fi
            else
                cat > /etc/cron.d/realm-restart <<EOF
0 $hour * * * root systemctl restart realm
EOF
            fi
            log_success "已添加每日 ${hour}:00 重启 Realm"
            ;;
        2)
            [[ -f /etc/crontabs/root ]] && sed -i '/realm/d' /etc/crontabs/root
            rm -f /etc/cron.d/realm-restart
            log_success "已删除 Realm 定时任务"
            ;;
        3)
            grep -h "realm" /etc/crontabs/root /etc/cron.d/realm-restart 2>/dev/null || echo "无 Realm 定时任务"
            ;;
        *)
            log_error "无效选择"
            ;;
    esac
}

show_realm_logs() {
    echo -e "\n${BLUE}===== Realm 标准日志 /var/log/realm.log =====${NC}"
    [[ -f /var/log/realm.log ]] && tail -n 50 /var/log/realm.log || echo "暂无日志"
    echo -e "\n${BLUE}===== Realm 错误日志 /var/log/realm.err =====${NC}"
    [[ -f /var/log/realm.err ]] && tail -n 50 /var/log/realm.err || echo "暂无错误日志"
    echo -e "\n${BLUE}===== 脚本日志 $LOG_FILE =====${NC}"
    [[ -f "$LOG_FILE" ]] && tail -n 30 "$LOG_FILE" || echo "暂无脚本日志"
}

manual_test_realm() {
    if [[ ! -x "$REALM_BIN" ]]; then
        log_error "Realm 主程序不存在，请先安装"
        return 1
    fi
    if [[ ! -f "$REALM_CONFIG" ]]; then
        log_error "Realm 配置文件不存在"
        return 1
    fi
    echo -e "${YELLOW}即将前台运行 Realm，按 Ctrl+C 退出。${NC}"
    "$REALM_BIN" -c "$REALM_CONFIG"
}

uninstall_realm() {
    require_root
    if ! confirm "确认完全卸载 Realm?"; then
        return
    fi
    service_action "$REALM_SERVICE" stop || true
    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        if systemd_is_running; then
            systemctl disable "$REALM_SERVICE" >/dev/null 2>&1 || true
        fi
        rm -f "/etc/systemd/system/${REALM_SERVICE}.service"
    else
        if command -v rc-update >/dev/null 2>&1; then
            rc-update del "$REALM_SERVICE" default >/dev/null 2>&1 || true
        fi
        rm -f "/etc/init.d/${REALM_SERVICE}"
    fi
    rm -rf "$REALM_DIR"
    rm -f /var/log/realm.log /var/log/realm.err /etc/cron.d/realm-restart
    [[ -f /etc/crontabs/root ]] && sed -i '/realm/d' /etc/crontabs/root
    reload_service_manager
    write_log "Realm uninstalled"
    log_success "Realm 已完全卸载"
}

show_realm_info() {
    echo -e "${CYAN}Realm 状态:${NC} $(service_status_text "$REALM_SERVICE")"
    echo -e "${CYAN}二进制:${NC} $REALM_BIN"
    echo -e "${CYAN}配置文件:${NC} $REALM_CONFIG"
    if [[ -x "$REALM_BIN" ]]; then
        "$REALM_BIN" -v 2>/dev/null || true
    fi
    if [[ -f "$REALM_CONFIG" ]]; then
        echo
        show_realm_rules
    fi
}

gost_menu() {
    while true; do
        clear_screen
        echo -e "${BOLD}TUU Toolkit - GOST SOCKS5${NC}"
        echo "状态: $(service_status_text "$GOST_SERVICE")"
        echo "1) 安装/更新 GOST SOCKS5"
        echo "2) 启动服务"
        echo "3) 停止服务"
        echo "4) 重启服务"
        echo "5) 查看状态/配置"
        echo "6) 卸载 GOST"
        echo "0) 返回"
        read -r -p "请选择: " choice
        case "$choice" in
            1) install_or_update_gost; pause ;;
            2) service_action "$GOST_SERVICE" start; pause ;;
            3) service_action "$GOST_SERVICE" stop; pause ;;
            4) service_action "$GOST_SERVICE" restart; pause ;;
            5) show_gost_info; pause ;;
            6) uninstall_gost; pause ;;
            0) return ;;
            *) log_error "无效选项"; pause ;;
        esac
    done
}

ss_menu() {
    while true; do
        clear_screen
        echo -e "${BOLD}TUU Toolkit - Shadowsocks Rust${NC}"
        echo "状态: $(service_status_text "$SS_SERVICE")"
        echo "1) 安装/更新 Shadowsocks Rust"
        echo "2) 启动服务"
        echo "3) 停止服务"
        echo "4) 重启服务"
        echo "5) 查看状态/配置"
        echo "6) 卸载 Shadowsocks Rust"
        echo "0) 返回"
        read -r -p "请选择: " choice
        case "$choice" in
            1) install_or_update_ss; pause ;;
            2) service_action "$SS_SERVICE" start; pause ;;
            3) service_action "$SS_SERVICE" stop; pause ;;
            4) service_action "$SS_SERVICE" restart; pause ;;
            5) show_ss_info; pause ;;
            6) uninstall_ss; pause ;;
            0) return ;;
            *) log_error "无效选项"; pause ;;
        esac
    done
}

realm_menu() {
    while true; do
        clear_screen
        echo -e "${BOLD}TUU Toolkit - Realm${NC}"
        echo "状态: $(service_status_text "$REALM_SERVICE")"
        echo "配置目录: $REALM_DIR"
        echo "1) 安装/更新 Realm"
        echo "2) 添加转发规则"
        echo "3) 查看转发规则"
        echo "4) 删除转发规则"
        echo "5) 启动服务"
        echo "6) 停止服务"
        echo "7) 重启服务"
        echo "8) 定时任务管理"
        echo "9) 查看日志"
        echo "10) 前台测试运行 Realm"
        echo "11) 查看安装信息"
        echo "12) 完全卸载 Realm"
        echo "0) 返回"
        read -r -p "请选择: " choice
        case "$choice" in
            1) install_or_update_realm; pause ;;
            2) add_realm_rule; pause ;;
            3) show_realm_rules; pause ;;
            4) delete_realm_rule; pause ;;
            5) service_action "$REALM_SERVICE" start; pause ;;
            6) service_action "$REALM_SERVICE" stop; pause ;;
            7) service_action "$REALM_SERVICE" restart; pause ;;
            8) manage_realm_cron; pause ;;
            9) show_realm_logs; pause ;;
            10) manual_test_realm; pause ;;
            11) show_realm_info; pause ;;
            12) uninstall_realm; pause ;;
            0) return ;;
            *) log_error "无效选项"; pause ;;
        esac
    done
}

main_menu() {
    need_bash
    require_root
    init_context

    while true; do
        clear_screen
        echo -e "${YELLOW}========================================${NC}"
        echo -e "${BOLD}             TUU Toolkit ${TOOL_VERSION}${NC}"
        echo -e "${YELLOW}========================================${NC}"
        echo "项目: $REPO_URL"
        echo "系统: ${OS_NAME:-unknown}"
        echo "系统族: $OS_FAMILY | 包管理器: $PKG_MANAGER | 服务: $SERVICE_MANAGER | libc: $LIBC_KIND"
        echo "架构: $ARCH_RAW"
        echo
        echo "1) GOST SOCKS5 管理"
        echo "2) Shadowsocks Rust 管理"
        echo "3) Realm 转发管理"
        echo "4) 系统检测"
        echo "5) 安装基础依赖"
        echo "0) 退出"
        echo -e "${YELLOW}========================================${NC}"
        read -r -p "请选择: " choice
        case "$choice" in
            1) gost_menu ;;
            2) ss_menu ;;
            3) realm_menu ;;
            4) print_system_info; pause ;;
            5) install_core_dependencies; pause ;;
            0) exit 0 ;;
            *) log_error "无效选项"; pause ;;
        esac
        init_context
    done
}

case "${1:-}" in
    --check)
        need_bash
        print_system_info
        ;;
    --version|-v)
        echo "$TOOL_VERSION"
        ;;
    --help|-h)
        cat <<EOF
TUU Toolkit ${TOOL_VERSION}

用法:
  bash <(curl -fsSL ${RAW_URL})
  bash tuu-toolkit.sh
  bash tuu-toolkit.sh --check

功能:
  - GOST SOCKS5 安装与服务管理
  - Shadowsocks Rust 安装与服务管理
  - Realm 安装、转发规则与服务管理

支持:
  Debian/Ubuntu + systemd
  Alpine + OpenRC
  CentOS/RHEL/Rocky/Alma + systemd
EOF
        ;;
    *)
        main_menu "$@"
        ;;
esac
