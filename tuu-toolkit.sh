#!/usr/bin/env bash

# TUU Toolkit 一键管理脚本
# 项目地址: https://github.com/phyrevue/tuu-toolkit
# 支持: Debian/Ubuntu, Alpine, CentOS/RHEL/Rocky/Alma
# Version: 2.0.7

set -o pipefail

TOOL_VERSION="2.0.7"
REPO_URL="https://github.com/phyrevue/tuu-toolkit"
RAW_URL="https://raw.githubusercontent.com/phyrevue/tuu-toolkit/main/tuu-toolkit.sh"
RELEASE_ASSET_URL_BASE="https://github.com/phyrevue/tuu-toolkit/releases/download"
TOOL_INSTALL_PATH="/usr/local/bin/tuu-toolkit"
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

LOG_MAX_BYTES=2097152
LOG_KEEP_LINES=5000
DIAG_DIR="/var/log/tuu-toolkit-diagnose"

# 写入脚本日志: log_to_file LEVEL 消息...
log_to_file() {
    local level="$1"
    shift
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" \
        | sed 's/\x1b\[[0-9;]*m//g' 2>/dev/null >> "$LOG_FILE" || true
}

# 调用链，例如 realm_start_service <- realm_menu <- main_menu
log_caller_chain() {
    local skip="${1:-2}"
    local chain="" i
    for ((i = skip; i < ${#FUNCNAME[@]}; i++)); do
        [[ "${FUNCNAME[$i]}" == "main" ]] && break
        chain+="${chain:+ <- }${FUNCNAME[$i]}"
    done
    echo "${chain:-main}"
}

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
    log_to_file WARN "$* (位置: $(log_caller_chain 2))"
}
log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    log_to_file ERROR "$* (位置: $(log_caller_chain 2))"
}

# 运行命令，输出照常显示；失败时把命令、退出码和最后 30 行输出记入脚本日志
run_logged() {
    local out rc
    out="$(mktemp /tmp/tuu-cmd.XXXXXX 2>/dev/null)" || { "$@"; return $?; }
    "$@" 2>&1 | tee "$out"
    rc="${PIPESTATUS[0]}"
    if (( rc != 0 )); then
        log_to_file ERROR "命令失败 (退出码 $rc): $* (位置: $(log_caller_chain 2))"
        tr '\r' '\n' < "$out" | grep -v '^[[:space:]]*$' | tail -n 30 | sed 's/^/    | /' \
            | sed 's/\x1b\[[0-9;]*m//g' 2>/dev/null >> "$LOG_FILE" || true
    fi
    rm -f "$out"
    return "$rc"
}

rotate_log_file() {
    local size tmp
    [[ -f "$LOG_FILE" ]] || return 0
    size="$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)"
    if (( size > LOG_MAX_BYTES )); then
        tmp="$(mktemp /tmp/tuu-log.XXXXXX 2>/dev/null)" || return 0
        tail -n "$LOG_KEEP_LINES" "$LOG_FILE" > "$tmp" && cat "$tmp" > "$LOG_FILE"
        rm -f "$tmp"
    fi
}

clear_screen() {
    if [[ -t 1 && -n "${TERM:-}" ]] && command -v clear >/dev/null 2>&1; then
        command clear
    else
        printf '\n'
    fi
}

write_log() {
    log_to_file INFO "$*"
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
            run_logged apt-get update
            DEBIAN_FRONTEND=noninteractive run_logged apt-get install -y "${packages[@]}"
            ;;
        apk)
            run_logged apk update
            run_logged apk add --no-cache "${packages[@]}"
            ;;
        dnf)
            run_logged dnf install -y --allowerasing "${packages[@]}"
            ;;
        yum)
            run_logged yum install -y "${packages[@]}"
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

ensure_download_tool() {
    if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
        return 0
    fi
    log_warn "缺少 curl/wget，正在安装下载工具"
    install_packages curl wget ca-certificates
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
        run_logged curl -fL --connect-timeout 20 --retry 2 -o "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        run_logged wget -O "$output" "$url"
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

version_gt() {
    local left="${1#v}"
    local right="${2#v}"
    local left_parts right_parts max i left_num right_num

    IFS='.' read -r -a left_parts <<< "$left"
    IFS='.' read -r -a right_parts <<< "$right"
    max="${#left_parts[@]}"
    (( ${#right_parts[@]} > max )) && max="${#right_parts[@]}"

    for ((i = 0; i < max; i++)); do
        left_num="${left_parts[$i]:-0}"
        right_num="${right_parts[$i]:-0}"
        left_num="${left_num//[^0-9]/}"
        right_num="${right_num//[^0-9]/}"
        left_num="${left_num:-0}"
        right_num="${right_num:-0}"

        if (( 10#$left_num > 10#$right_num )); then
            return 0
        elif (( 10#$left_num < 10#$right_num )); then
            return 1
        fi
    done

    return 1
}

current_script_path() {
    local script_path="${BASH_SOURCE[0]:-$0}"
    local resolved=""

    if command -v readlink >/dev/null 2>&1; then
        resolved="$(readlink -f "$script_path" 2>/dev/null || true)"
    fi
    [[ -z "$resolved" ]] && resolved="$script_path"

    case "$resolved" in
        /dev/fd/*|/proc/*/fd/*|pipe:*|"")
            echo ""
            ;;
        *)
            if [[ -f "$resolved" && -w "$resolved" ]]; then
                echo "$resolved"
            else
                echo ""
            fi
            ;;
    esac
}

# 从脚本内容中解析 TOOL_VERSION
toolkit_version_from_file() {
    sed -n 's/^TOOL_VERSION="\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -n1
}

# 下载远程最新脚本到 $1，成功时输出其版本号。
# 优先使用 main 分支（与 README 安装命令一致），失败时回退到最新 Release 附件。
fetch_latest_toolkit() {
    local output="$1"
    local version="" tag=""

    if download_file "$RAW_URL" "$output" >/dev/null 2>&1; then
        version="$(toolkit_version_from_file "$output")"
    fi
    if [[ -z "$version" ]]; then
        tag="$(get_latest_tag "phyrevue/tuu-toolkit" "")"
        if [[ -n "$tag" ]] && download_file "${RELEASE_ASSET_URL_BASE}/${tag}/tuu-toolkit.sh" "$output" >/dev/null 2>&1; then
            version="$(toolkit_version_from_file "$output")"
        fi
    fi
    [[ -n "$version" ]] || return 1
    echo "$version"
}

check_and_update_toolkit() {
    require_root
    init_context
    ensure_download_tool || return 1

    local latest_version tmp_file target current_path
    tmp_file="$(mktemp /tmp/tuu-toolkit-update.XXXXXX)"

    echo "当前版本: v${TOOL_VERSION}"
    log_info "正在检查远程版本..."
    if ! latest_version="$(fetch_latest_toolkit "$tmp_file")"; then
        rm -f "$tmp_file"
        log_error "无法获取远程版本信息，请检查网络或 GitHub 访问是否正常"
        return 1
    fi
    echo "最新版本: v${latest_version}"

    if [[ "$latest_version" == "$TOOL_VERSION" ]]; then
        rm -f "$tmp_file"
        log_success "当前已是最新版本"
        return 0
    fi
    if version_gt "$TOOL_VERSION" "$latest_version"; then
        rm -f "$tmp_file"
        log_info "本地版本高于远程版本，无需更新"
        return 0
    fi

    echo
    log_info "发现新版本 v${latest_version}"
    if ! confirm "是否立即更新 TUU Toolkit?"; then
        rm -f "$tmp_file"
        log_info "已取消更新"
        return 0
    fi

    if ! bash -n "$tmp_file"; then
        rm -f "$tmp_file"
        log_error "下载的脚本语法检查失败，已中止更新"
        return 1
    fi

    current_path="$(current_script_path)"
    if [[ -n "$current_path" ]]; then
        target="$current_path"
    else
        target="$TOOL_INSTALL_PATH"
    fi

    install -m 755 "$tmp_file" "$target"
    rm -f "$tmp_file"

    log_success "TUU Toolkit 已更新到 v${latest_version}"
    echo "安装位置: $target"
    if [[ "$target" == "$TOOL_INSTALL_PATH" ]]; then
        echo "以后可直接运行: tuu-toolkit"
    else
        echo "请重新运行脚本以使用新版本"
    fi
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

json_get_string() {
    local file="$1"
    local key="$2"
    sed -nE "s/^[[:space:]]*\"${key}\"[[:space:]]*:[[:space:]]*\"(.*)\"[,]?[[:space:]]*$/\1/p" "$file" | head -n1
}

json_get_scalar() {
    local file="$1"
    local key="$2"
    sed -nE "s/^[[:space:]]*\"${key}\"[[:space:]]*:[[:space:]]*([^,[:space:]]+)[,]?[[:space:]]*$/\1/p" "$file" | head -n1
}

yaml_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

valid_port() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
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

base64_urlsafe_no_pad() {
    printf '%s' "$1" | base64 | tr -d '\n=' | tr '+/' '-_'
}

url_encode() {
    local LC_ALL=C
    local input="$1"
    local output="" char i
    for ((i = 0; i < ${#input}; i++)); do
        char="${input:i:1}"
        case "$char" in
            [A-Za-z0-9.~_-]) output+="$char" ;;
            *) printf -v char '%%%02X' "'$char"; output+="$char" ;;
        esac
    done
    printf '%s' "$output"
}

get_public_ipv4() {
    local ip url
    if [[ -n "${SERVER_IP:-}" ]]; then
        echo "$SERVER_IP"
        return 0
    fi

    for url in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me/ip"; do
        if command -v curl >/dev/null 2>&1; then
            ip="$(curl -fsS4 --connect-timeout 4 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
        elif command -v wget >/dev/null 2>&1; then
            ip="$(wget -qO- -T 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
        else
            ip=""
        fi

        if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done

    echo "YOUR_SERVER_IP"
}

build_ss_uri() {
    local method="$1"
    local password="$2"
    local server="$3"
    local port="$4"
    local tag="${5:-TUU-SS-${port}}"
    local userinfo

    # SIP002: 2022 加密的 userinfo 使用百分号编码，其余加密使用 Base64URL
    if is_ss2022_method "$method"; then
        userinfo="$(url_encode "$method"):$(url_encode "$password")"
    else
        userinfo="$(base64_urlsafe_no_pad "${method}:${password}")"
    fi
    if [[ "$server" == *:* && "$server" != \[*\] ]]; then
        server="[$server]"
    fi

    echo "ss://${userinfo}@${server}:${port}#${tag}"
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
            run_logged systemctl "$action" "$service"
        else
            log_warn "systemd 未运行，无法执行: systemctl $action $service"
            return 1
        fi
    elif [[ "$SERVICE_MANAGER" == "openrc" ]]; then
        if command -v rc-service >/dev/null 2>&1; then
            # command_background 模式下进程退出后 OpenRC 仍记录为 started(crashed)，
            # 此时 start 会提示 "already been started" 而不真正启动，stop 也会失败。
            # 进程不在运行时先 zap 清除状态，再按实际情况执行。
            if [[ "$action" =~ ^(start|restart|stop)$ ]] && ! rc-service "$service" status >/dev/null 2>&1; then
                rc-service "$service" zap >/dev/null 2>&1 || true
                case "$action" in
                    stop) return 0 ;;
                    restart) action="start" ;;
                esac
            fi
            run_logged rc-service "$service" "$action"
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

service_is_running() {
    local service="$1"
    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        systemd_is_running && systemctl is-active --quiet "$service"
    elif [[ "$SERVICE_MANAGER" == "openrc" ]]; then
        command -v rc-service >/dev/null 2>&1 && rc-service "$service" status >/dev/null 2>&1
    else
        return 1
    fi
}

# 重启后稍等再检查，避免配置错误导致进程立即退出却仍提示成功
# 返回: 0 运行中, 1 启动后退出, 2 当前环境无法管理服务
restart_and_verify_service() {
    action_and_verify_service "$1" restart "${2:-}"
}

start_and_verify_service() {
    action_and_verify_service "$1" start "${2:-}"
}

action_and_verify_service() {
    local service="$1"
    local action="$2"
    local error_log="${3:-}"
    local log_lines_before=0
    if [[ -n "$error_log" && -f "$error_log" ]]; then
        log_lines_before="$(wc -l < "$error_log")"
    fi
    if ! service_action "$service" "$action"; then
        log_warn "服务未能成功执行 ${action}，请检查上方输出或在完整 init 环境中手动启动"
        return 2
    fi
    sleep 2
    if service_is_running "$service"; then
        return 0
    fi

    log_error "$service 启动后未能保持运行，最近日志:"
    local recent=""
    if [[ "$SERVICE_MANAGER" == "systemd" ]] && command -v journalctl >/dev/null 2>&1; then
        recent="$(journalctl -u "$service" -n 20 --no-pager 2>/dev/null || true)"
    elif [[ -n "$error_log" && -f "$error_log" ]]; then
        # 错误日志是追加写入的，只显示本次重启后新增的内容
        recent="$(tail -n "+$((log_lines_before + 1))" "$error_log" | tail -n 20)"
    fi
    if [[ -n "$recent" ]]; then
        printf '%s\n' "$recent" >&2
        printf '%s\n' "$recent" | sed 's/^/    | /' 2>/dev/null >> "$LOG_FILE" || true
    else
        echo "(没有新的错误输出，可运行「日志与排错 -> 生成排错报告」获取详细信息)" >&2
    fi
    return 1
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

start_pre() {
    # 容器内可能无权提高硬限制，失败时保持系统默认
    ulimit -n 1048576 2>/dev/null || true
}

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
    metadata:
      udp: true
      udpBufferSize: 4096
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
    metadata:
      udp: true
      udpBufferSize: 4096
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
    open_firewall_port "$port" udp
    restart_and_verify_service "$GOST_SERVICE" /var/log/gost/gost.err
    if [[ $? -eq 1 ]]; then
        log_error "GOST 服务未能正常运行，请根据上面的日志排查"
        return 1
    fi
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
    # Upstream GNU builds may require a newer glibc than the host provides.
    # The musl release is static and works on both glibc and musl systems.
    linux_rust_target "musl"
}

install_ss_binary() {
    install_archive_dependencies || return 1
    init_context
    local tag version arch native_arch selected_arch file url tmp candidate
    local candidates=()
    tag="$(get_latest_tag "shadowsocks/shadowsocks-rust" "v1.24.0")"
    version="${tag#v}"
    arch="$(ss_arch)"
    if [[ -z "$arch" ]]; then
        log_error "Shadowsocks Rust 不支持当前架构: $ARCH_RAW / $LIBC_KIND"
        return 1
    fi

    candidates+=("$arch")
    native_arch="$(linux_rust_target "$LIBC_KIND")"
    if [[ -n "$native_arch" && "$native_arch" != "$arch" ]]; then
        candidates+=("$native_arch")
    fi

    tmp="$(mktemp -d /tmp/tuu-ss.XXXXXX)"
    mkdir -p "$SS_DIR"

    for candidate in "${candidates[@]}"; do
        file="shadowsocks-v${version}.${candidate}.tar.xz"
        url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${version}/${file}"
        log_info "下载 Shadowsocks Rust: $url"
        if download_file "$url" "$tmp/$file"; then
            selected_arch="$candidate"
            break
        fi
        log_warn "未找到 ${candidate} 发布包，尝试其他兼容构建"
    done

    if [[ -z "$selected_arch" ]]; then
        rm -rf "$tmp"
        log_error "Shadowsocks Rust 下载失败"
        return 1
    fi

    if ! tar -xf "$tmp/$file" -C "$tmp"; then
        log_error "Shadowsocks Rust 安装包解压失败"
        rm -rf "$tmp"
        return 1
    fi
    if [[ ! -f "$tmp/ssserver" ]]; then
        log_error "解压后未找到 ssserver"
        rm -rf "$tmp"
        return 1
    fi

    chmod +x "$tmp/ssserver"
    if ! "$tmp/ssserver" --version >/dev/null 2>"$tmp/ssserver-check.err"; then
        log_error "下载的 ssserver 无法在当前系统运行"
        if grep -q 'GLIBC_[0-9]' "$tmp/ssserver-check.err" 2>/dev/null; then
            log_error "系统 glibc 版本过旧，请使用静态 musl 构建或升级操作系统"
        fi
        sed -n '1,10p' "$tmp/ssserver-check.err" >&2
        rm -rf "$tmp"
        return 1
    fi

    if ! install -m 755 "$tmp/ssserver" "$SS_BIN"; then
        log_error "无法安装 ssserver 到 $SS_BIN"
        rm -rf "$tmp"
        return 1
    fi
    if ! echo "v${version}" > "$SS_VERSION_FILE"; then
        log_warn "无法写入版本文件: $SS_VERSION_FILE"
    fi
    rm -rf "$tmp"
    log_success "Shadowsocks Rust v${version} 安装完成 (${selected_arch}): $SS_BIN"
}

# 内核禁用 IPv6 (ipv6.disable=1) 时 /proc/net/if_inet6 不存在，无法绑定 "::"
ipv6_supported() {
    [[ -e /proc/net/if_inet6 ]]
}

# 内核禁用 IPv6 时无法绑定 "::"，退回仅 IPv4 监听
ss_listen_addr() {
    if ipv6_supported; then
        echo "::"
    else
        echo "0.0.0.0"
    fi
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
        printf '    "server": "%s",\n' "$(ss_listen_addr)"
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
    echo "1) aes-256-gcm (默认，兼容性最好)" >&2
    echo "2) chacha20-ietf-poly1305" >&2
    echo "3) 2022-blake3-aes-256-gcm (要求服务器与客户端时间误差小于 30 秒)" >&2
    echo "4) 2022-blake3-chacha20-poly1305 (要求服务器与客户端时间误差小于 30 秒)" >&2
    read -r -p "选项 [1-4]: " choice
    case "${choice:-1}" in
        1) method="aes-256-gcm" ;;
        2) method="chacha20-ietf-poly1305" ;;
        3) method="2022-blake3-aes-256-gcm" ;;
        4) method="2022-blake3-chacha20-poly1305" ;;
        *) method="aes-256-gcm" ;;
    esac
    echo "$method"
}

is_ss2022_method() {
    [[ "$1" == 2022-blake3-* ]]
}

default_ss_password_bytes() {
    case "$1" in
        2022-blake3-aes-128-gcm) echo 16 ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305|2022-blake3-chacha8-poly1305) echo 32 ;;
        *) echo 24 ;;
    esac
}

# 2022 加密的密码必须是指定长度密钥的 Base64，否则 ssserver 会拒绝启动
valid_ss2022_password() {
    local method="$1"
    local password="$2"
    local expected decoded_len
    [[ "$password" =~ ^[A-Za-z0-9+/]+=*$ ]] || return 1
    expected="$(default_ss_password_bytes "$method")"
    decoded_len="$(printf '%s' "$password" | base64 -d 2>/dev/null | wc -c)"
    [[ "${decoded_len//[[:space:]]/}" == "$expected" ]]
}

print_ss_connect_hints() {
    local method="$1"
    echo
    echo "如果客户端无法连接，请检查:"
    echo "  - 云服务商控制台的安全组是否已放行该端口的 TCP 和 UDP"
    if is_ss2022_method "$method"; then
        echo "  - 服务器与客户端时间误差是否小于 30 秒 (服务器当前 UTC 时间: $(date -u '+%H:%M:%S'))"
    fi
}

# 仅更新程序与服务文件，保留现有端口、密码和加密方式，分享链接不变
update_ss_keep_config() {
    install_ss_binary || return 1
    create_ss_service
    restart_and_verify_service "$SS_SERVICE" /var/log/ss-rust.err
    if [[ $? -eq 1 ]]; then
        log_error "Shadowsocks 服务未能正常运行，请根据上面的日志排查"
        return 1
    fi
    echo
    log_success "Shadowsocks Rust 已更新，原配置保持不变"
    show_ss_info
}

install_or_update_ss() {
    require_root
    init_context
    local port method password fast_open dns suggested_port server_ip ss_uri keep_answer

    if [[ -f "$SS_CONFIG" ]]; then
        read -r -p "检测到已有配置，是否保留配置仅更新程序? [Y/n]: " keep_answer
        if [[ ! "$keep_answer" =~ ^[Nn]$ ]]; then
            update_ss_keep_config
            return
        fi
    fi

    suggested_port="$(random_port)"
    read -r -p "SS 端口 [默认 ${suggested_port}]: " port
    port="${port:-$suggested_port}"
    if ! valid_port "$port"; then
        log_error "端口必须在 1-65535 之间"
        return 1
    fi

    method="$(choose_ss_method)"
    if is_ss2022_method "$method"; then
        log_warn "2022 加密会校验时间，服务器或客户端时间不准时将无法连接"
    fi
    read -r -p "SS 密码 [默认自动生成]: " password
    if [[ -z "$password" ]]; then
        password="$(random_password "$(default_ss_password_bytes "$method")")"
    elif is_ss2022_method "$method" && ! valid_ss2022_password "$method" "$password"; then
        log_error "${method} 的密码必须是 $(default_ss_password_bytes "$method") 字节密钥的 Base64 编码，建议留空自动生成"
        return 1
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
    restart_and_verify_service "$SS_SERVICE" /var/log/ss-rust.err
    if [[ $? -eq 1 ]]; then
        log_error "Shadowsocks 服务未能正常运行，请根据上面的日志排查"
        return 1
    fi

    echo
    log_success "Shadowsocks Rust 配置完成"
    server_ip="$(get_public_ipv4)"
    ss_uri="$(build_ss_uri "$method" "$password" "$server_ip" "$port")"
    echo "端口: $port"
    echo "密码: $password"
    echo "加密: $method"
    echo "服务器: $server_ip"
    echo "完整 SS 链接: $ss_uri"
    print_ss_connect_hints "$method"
}

show_ss_info() {
    local version server port password method fast_open mode timeout dns server_ip ss_uri tfo_text

    echo -e "${CYAN}SS 状态:${NC} $(service_status_text "$SS_SERVICE")"
    echo -e "${CYAN}二进制:${NC} $SS_BIN"
    echo -e "${CYAN}配置文件:${NC} $SS_CONFIG"
    if [[ -f "$SS_VERSION_FILE" ]]; then
        version="$(cat "$SS_VERSION_FILE")"
    else
        version="未知"
    fi
    echo -e "${CYAN}版本:${NC} $version"

    if [[ ! -f "$SS_CONFIG" ]]; then
        log_warn "SS 配置文件不存在"
        return 0
    fi

    server="$(json_get_string "$SS_CONFIG" server)"
    port="$(json_get_scalar "$SS_CONFIG" server_port)"
    password="$(json_get_string "$SS_CONFIG" password)"
    method="$(json_get_string "$SS_CONFIG" method)"
    fast_open="$(json_get_scalar "$SS_CONFIG" fast_open)"
    mode="$(json_get_string "$SS_CONFIG" mode)"
    timeout="$(json_get_scalar "$SS_CONFIG" timeout)"
    dns="$(json_get_string "$SS_CONFIG" nameserver)"

    if [[ "$fast_open" == "true" ]]; then
        tfo_text="启用"
    else
        tfo_text="禁用"
    fi

    echo
    echo -e "${YELLOW}Shadowsocks 配置信息${NC}"
    echo "监听地址: ${server:-::}"
    echo "端口: ${port:-未知}"
    echo "密码: ${password:-未知}"
    echo "加密: ${method:-未知}"
    echo "TCP Fast Open: $tfo_text"
    echo "模式: ${mode:-tcp_and_udp}"
    echo "超时: ${timeout:-300} 秒"
    echo "DNS: ${dns:-未设置}"

    if [[ -n "$method" && -n "$password" && -n "$port" ]]; then
        server_ip="$(get_public_ipv4)"
        ss_uri="$(build_ss_uri "$method" "$password" "$server_ip" "$port")"
        echo "服务器: $server_ip"
        echo "完整 SS 链接: $ss_uri"
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

realm_has_endpoints() {
    [[ -f "$REALM_CONFIG" ]] && grep -q '^\[\[endpoints\]\]' "$REALM_CONFIG"
}

# Realm 在没有任何 endpoints 时会立即退出，因此启动前先检查规则
realm_start_service() {
    local action="${1:-start}"
    if [[ ! -x "$REALM_BIN" ]]; then
        log_error "Realm 主程序不存在，请先安装"
        return 1
    fi
    if ! realm_has_endpoints; then
        log_warn "当前没有任何 Realm 转发规则，Realm 启动后会立即退出，请先添加转发规则"
        service_action "$REALM_SERVICE" stop >/dev/null 2>&1 || true
        return 1
    fi
    realm_fix_ipv6_listen
    if action_and_verify_service "$REALM_SERVICE" "$action" /var/log/realm.err; then
        log_success "Realm 服务运行中"
    else
        echo "可选择「10) 前台测试运行 Realm」直接查看报错，或在主菜单「7) 日志与排错」生成排错报告"
    fi
}

# 系统未启用 IPv6 时，"[::]" 监听会导致 Realm 绑定失败并立即退出，自动改为 0.0.0.0
realm_fix_ipv6_listen() {
    ipv6_supported && return 0
    grep -qE '^[[:space:]]*listen[[:space:]]*=[[:space:]]*"\[::\]:' "$REALM_CONFIG" || return 0
    cp -f "$REALM_CONFIG" "${REALM_CONFIG}.bak"
    sed -i -E 's/^([[:space:]]*listen[[:space:]]*=[[:space:]]*")\[::\]:/\10.0.0.0:/' "$REALM_CONFIG"
    log_warn "系统未启用 IPv6，已将 [::] 监听改为 0.0.0.0 (原配置备份: ${REALM_CONFIG}.bak)"
}

realm_service_restart_if_ready() {
    if [[ -x "$REALM_BIN" ]]; then
        realm_start_service restart || true
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

    local default_choice=1
    echo
    if ! ipv6_supported; then
        default_choice=2
        log_warn "系统未启用 IPv6，无法使用双栈监听，默认使用仅 IPv4 监听"
    fi
    echo "请选择监听模式:"
    echo "1) 双栈监听 [::]:${local_port}$( ((default_choice == 1)) && echo ' (默认)')"
    echo "2) 仅 IPv4 监听 0.0.0.0:${local_port}$( ((default_choice == 2)) && echo ' (默认)')"
    echo "3) 自定义监听地址"
    read -r -p "选项 [1-3]: " ip_choice
    ip_choice="${ip_choice:-$default_choice}"
    if [[ "$ip_choice" == "1" ]] && ! ipv6_supported; then
        log_warn "系统未启用 IPv6，已改为仅 IPv4 监听 0.0.0.0:${local_port}"
        ip_choice=2
    fi
    case "$ip_choice" in
        1) listen_addr="[::]:$local_port" ;;
        2) listen_addr="0.0.0.0:$local_port" ;;
        3)
            read -r -p "完整监听地址，例如 0.0.0.0:80 或 [::]:443: " listen_addr
            if [[ ! "$listen_addr" =~ .+:[0-9]+$ ]]; then
                log_error "监听地址格式错误"
                return 1
            fi
            ;;
        *)
            if ipv6_supported; then
                listen_addr="[::]:$local_port"
            else
                listen_addr="0.0.0.0:$local_port"
            fi
            ;;
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
                echo "0 $hour * * * (rc-service realm status >/dev/null 2>&1 || rc-service realm zap); rc-service realm restart" >> /etc/crontabs/root
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
    echo "提示: 如需完整的排错信息，请在主菜单选择「7) 日志与排错 -> 生成排错报告」"
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

# ======================== 日志与排错 ========================

log_session_start() {
    rotate_log_file
    log_to_file INFO "===== 会话开始: TUU Toolkit v${TOOL_VERSION} | ${OS_NAME:-unknown} | ${SERVICE_MANAGER} | ${LIBC_KIND} | ${ARCH_RAW} | 参数: ${*:-无} ====="
}

# 隐藏配置/输出中的密码和分享链接
mask_secrets() {
    sed -E \
        -e 's/("password"[[:space:]]*:[[:space:]]*")([^"\\]|\\.)*"/\1******"/g' \
        -e 's/^([[:space:]]*password:[[:space:]]*).*/\1"******"/' \
        -e 's#ss://[^[:space:]]+#ss://******#g'
}

DIAG_ISSUES=()

diag_issue() {
    DIAG_ISSUES+=("$*")
}

diag_section() {
    printf '\n==================== %s ====================\n' "$*"
}

# 打印并执行命令，最长 15 秒，输出合并 stderr
diag_run() {
    local rc
    printf '$ %s\n' "$*"
    if command -v timeout >/dev/null 2>&1; then
        timeout 15 "$@" 2>&1
    else
        "$@" 2>&1
    fi
    rc=$?
    (( rc != 0 )) && printf '(退出码: %s)\n' "$rc"
    return 0
}

diag_tail() {
    local file="$1"
    local count="${2:-50}"
    if [[ -f "$file" ]]; then
        printf -- '--- %s (最后 %s 行, 修改时间: %s) ---\n' "$file" "$count" \
            "$(date -r "$file" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 未知)"
        tail -n "$count" "$file" | mask_secrets
    else
        printf -- '--- %s: 不存在 ---\n' "$file"
    fi
}

diag_listening_sockets() {
    if command -v ss >/dev/null 2>&1; then
        ss -lntup 2>/dev/null
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lntup 2>/dev/null
    fi
}

diag_port_listeners() {
    diag_listening_sockets | grep -E "[:.]$1[[:space:]]" || true
}

diag_process_lines() {
    local bin="$1"
    ps -ef 2>/dev/null | grep -F "$bin" | grep -v grep || ps 2>/dev/null | grep -F "$bin" | grep -v grep || true
}

diag_check_service() {
    local label="$1" service="$2" bin="$3" config="$4" out_log="$5" err_log="$6" version_flag="$7"
    shift 7
    local ports=("$@")
    local unit_file status_out status_rc running=0 out port listeners

    if [[ "$SERVICE_MANAGER" == "openrc" ]]; then
        unit_file="/etc/init.d/$service"
    else
        unit_file="/etc/systemd/system/$service.service"
    fi

    diag_section "$label"
    if [[ ! -e "$bin" && ! -f "$config" && ! -f "$unit_file" ]]; then
        echo "未安装 (主程序、配置和服务文件都不存在)"
        return 0
    fi

    echo "主程序: $bin"
    if [[ ! -e "$bin" ]]; then
        diag_issue "$label: 主程序不存在 $bin，请重新安装"
    elif [[ ! -x "$bin" ]]; then
        diag_issue "$label: 主程序没有执行权限 $bin"
    else
        ls -l "$bin" 2>&1
        out="$(timeout 5 "$bin" "$version_flag" 2>&1)"
        status_rc=$?
        echo "版本检测 ($bin $version_flag, 退出码 $status_rc):"
        printf '%s\n' "$out" | head -n 10
        if (( status_rc != 0 )) && [[ "$status_rc" != "124" ]]; then
            if grep -q 'GLIBC_[0-9]' <<< "$out"; then
                diag_issue "$label: 主程序与系统 glibc 版本不兼容 ($(grep -o 'GLIBC_[0-9.]*' <<< "$out" | head -n1))，请用 musl 版本重新安装"
            elif grep -qiE 'not found|no such file' <<< "$out"; then
                diag_issue "$label: 主程序无法运行，可能是架构或 libc 不匹配: $(head -n1 <<< "$out")"
            else
                diag_issue "$label: 主程序版本检测失败 (退出码 $status_rc): $(head -n1 <<< "$out")"
            fi
        fi
        if command -v ldd >/dev/null 2>&1; then
            out="$(ldd "$bin" 2>&1 || true)"
            if grep -q 'not found' <<< "$out"; then
                diag_issue "$label: 缺少动态库: $(grep 'not found' <<< "$out" | awk '{print $1}' | tr '\n' ' ')"
                printf '%s\n' "$out"
            fi
        fi
    fi

    echo
    echo "配置文件: $config"
    if [[ -f "$config" ]]; then
        ls -l "$config" 2>&1
        sed -n '1,200p' "$config" | mask_secrets
    else
        diag_issue "$label: 配置文件不存在 $config"
    fi

    echo
    echo "服务文件: $unit_file"
    if [[ -f "$unit_file" ]]; then
        cat "$unit_file"
    else
        diag_issue "$label: 服务文件不存在 $unit_file，请重新安装以生成服务"
    fi

    echo
    echo "服务状态:"
    if [[ "$SERVICE_MANAGER" == "openrc" ]] && command -v rc-service >/dev/null 2>&1; then
        status_out="$(rc-service "$service" status 2>&1)"
        status_rc=$?
        printf '%s\n(退出码: %s)\n' "$status_out" "$status_rc"
        (( status_rc == 0 )) && running=1
        if grep -qi 'crashed' <<< "$status_out"; then
            diag_issue "$label: OpenRC 记录为 crashed，进程启动后已退出，请查看下方错误日志"
        fi
        if command -v rc-update >/dev/null 2>&1 && ! rc-update show default 2>/dev/null | grep -qw "$service"; then
            diag_issue "$label: 未加入开机自启 (rc-update add $service default)"
        fi
    elif [[ "$SERVICE_MANAGER" == "systemd" ]] && systemd_is_running; then
        diag_run systemctl status "$service" --no-pager -l -n 0
        systemctl is-active --quiet "$service" && running=1
        if [[ "$(systemctl is-enabled "$service" 2>/dev/null)" != "enabled" ]]; then
            diag_issue "$label: 未设置开机自启 (systemctl enable $service)"
        fi
        if [[ "$(systemctl is-active "$service" 2>/dev/null)" == "failed" ]]; then
            diag_issue "$label: systemd 显示服务启动失败 (failed)，请查看下方 journal 日志"
        fi
    else
        echo "无法检测 (服务管理器不可用)"
    fi
    if (( running == 0 )); then
        diag_issue "$label: 服务当前未运行"
    fi

    echo
    echo "相关进程:"
    out="$(diag_process_lines "$bin")"
    echo "${out:-无}"

    if [[ ${#ports[@]} -gt 0 ]]; then
        echo
        echo "端口监听:"
        for port in "${ports[@]}"; do
            [[ -z "$port" ]] && continue
            listeners="$(diag_port_listeners "$port")"
            if [[ -n "$listeners" ]]; then
                echo "端口 $port:"
                printf '%s\n' "$listeners"
                if (( running == 0 )); then
                    diag_issue "$label: 服务未运行但端口 $port 已被其他进程占用，可能导致启动失败"
                fi
            else
                echo "端口 $port: 未监听"
                (( running == 1 )) && diag_issue "$label: 服务在运行，但端口 $port 未处于监听状态"
            fi
        done
    fi

    echo
    echo "日志:"
    diag_tail "$err_log" 60
    diag_tail "$out_log" 30
    if [[ "$SERVICE_MANAGER" == "systemd" ]] && command -v journalctl >/dev/null 2>&1; then
        echo "--- journalctl -u $service (最后 60 行) ---"
        journalctl -u "$service" -n 60 --no-pager 2>&1 | mask_secrets
    fi
}

diag_check_realm_endpoints() {
    local listens=() remotes=() i host port target
    [[ -f "$REALM_CONFIG" ]] || return 0
    mapfile -t listens < <(sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$REALM_CONFIG")
    mapfile -t remotes < <(sed -n 's/^[[:space:]]*remote[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$REALM_CONFIG")

    diag_section "Realm 转发规则检测"
    echo "规则数量: ${#listens[@]}"
    if [[ ${#listens[@]} -eq 0 ]]; then
        diag_issue "Realm: 配置中没有任何转发规则，Realm 启动后会立即退出"
        return 0
    fi
    echo "系统 IPv6: $(ipv6_supported && echo 已启用 || echo 未启用)"
    for ((i = 0; i < ${#listens[@]} && i < 30; i++)); do
        target="${remotes[$i]:-}"
        echo "规则 $((i + 1)): ${listens[$i]} -> ${target:-<缺少 remote>}"
        if [[ "${listens[$i]}" == \[* ]] && ! ipv6_supported; then
            diag_issue "Realm: 规则 $((i + 1)) 监听 IPv6 地址 ${listens[$i]}，但系统未启用 IPv6，Realm 会绑定失败退出 (新版脚本启动时会自动改为 0.0.0.0)"
        fi
        if [[ -z "$target" ]]; then
            diag_issue "Realm: 规则 $((i + 1)) 缺少 remote"
            continue
        fi
        port="${target##*:}"
        host="${target%:*}"
        host="${host#[}"
        host="${host%]}"
        if timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
            echo "  目标 TCP 连通: 正常"
        else
            echo "  目标 TCP 连通: 失败"
            diag_issue "Realm: 规则 $((i + 1)) 的目标 ${target} 从本机 TCP 连接失败 (目标未开放、被防火墙拦截或域名无法解析)"
        fi
    done
}

diag_system() {
    local free_kb
    diag_section "系统信息"
    echo "TUU Toolkit: v${TOOL_VERSION}"
    echo "脚本路径: $(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")"
    echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "系统: ${OS_NAME:-unknown} | 系统族: $OS_FAMILY | 包管理器: $PKG_MANAGER"
    echo "服务管理: $SERVICE_MANAGER | libc: $LIBC_KIND | 架构: $ARCH_RAW"
    echo "Bash: ${BASH_VERSION:-unknown}"
    echo "PID 1: $(cat /proc/1/comm 2>/dev/null || echo unknown)"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        echo "虚拟化: $(systemd-detect-virt 2>/dev/null || echo none)"
    elif [[ -f /.dockerenv ]] || grep -qaE 'docker|lxc|container' /proc/1/cgroup /proc/1/environ 2>/dev/null; then
        echo "虚拟化: 可能运行在容器中"
    fi
    diag_run uname -a
    diag_run uptime
    if [[ "$LIBC_KIND" == "gnu" ]]; then
        echo "glibc: $(ldd --version 2>&1 | head -n1)"
    fi

    diag_section "资源"
    diag_run free -m
    diag_run df -h /
    echo "ulimit -n: $(ulimit -n)"
    free_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ -n "$free_kb" ]] && (( free_kb < 51200 )); then
        diag_issue "系统: 根分区剩余空间不足 50MB，可能导致安装或日志写入失败"
    fi

    diag_section "服务管理器"
    if [[ "$SERVICE_MANAGER" == "openrc" ]]; then
        if ! command -v rc-service >/dev/null 2>&1; then
            diag_issue "系统: 未安装 OpenRC (rc-service 不存在)"
        fi
        if [[ ! -f /run/openrc/softlevel ]]; then
            diag_issue "系统: OpenRC 未初始化 (缺少 /run/openrc/softlevel)，服务无法启动；可执行 openrc default 或 mkdir -p /run/openrc && touch /run/openrc/softlevel"
        fi
        command -v rc-status >/dev/null 2>&1 && diag_run rc-status -a
    elif [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        if ! systemd_is_running; then
            diag_issue "系统: 当前系统没有运行 systemd (常见于容器)，服务无法通过 systemctl 管理"
        else
            diag_run systemctl --failed --no-pager
        fi
    else
        diag_issue "系统: 未识别到可用的服务管理器"
    fi

    diag_section "网络"
    diag_run cat /etc/resolv.conf
    if command -v ip >/dev/null 2>&1; then
        diag_run ip addr
        diag_run ip route
    fi
    local host url code
    for host in github.com api.github.com raw.githubusercontent.com; do
        if getent hosts "$host" >/dev/null 2>&1 || nslookup "$host" >/dev/null 2>&1; then
            echo "DNS 解析 $host: 正常"
        else
            echo "DNS 解析 $host: 失败"
            diag_issue "网络: 无法解析 $host，安装和更新会失败，请检查 DNS"
        fi
    done
    for url in https://api.github.com https://raw.githubusercontent.com; do
        if command -v curl >/dev/null 2>&1; then
            code="$(curl -sS -o /dev/null -w '%{http_code} 用时 %{time_total}s' --max-time 10 "$url" 2>&1)"
            echo "访问 $url: $code"
            if [[ "$code" == 000* || "$code" == curl:* ]]; then
                diag_issue "网络: 无法访问 $url ($code)"
            fi
        elif command -v wget >/dev/null 2>&1; then
            if timeout 10 wget -q --spider "$url" 2>/dev/null; then
                echo "访问 $url: 正常"
            else
                echo "访问 $url: 失败"
                diag_issue "网络: 无法访问 $url"
            fi
        fi
    done

    diag_section "监听端口"
    local sockets
    sockets="$(diag_listening_sockets)"
    echo "${sockets:-无法获取 (缺少 ss/netstat)}"

    diag_section "防火墙"
    command -v iptables >/dev/null 2>&1 && diag_run iptables -S INPUT
    command -v ip6tables >/dev/null 2>&1 && diag_run ip6tables -S INPUT
    command -v nft >/dev/null 2>&1 && diag_run nft list ruleset
    command -v ufw >/dev/null 2>&1 && diag_run ufw status
    command -v firewall-cmd >/dev/null 2>&1 && diag_run firewall-cmd --list-all

    diag_section "定时任务"
    grep -hE 'realm|gost|ss-rust' /etc/crontabs/root /etc/cron.d/* /var/spool/cron/crontabs/root 2>/dev/null || echo "无相关定时任务"
}

generate_diagnostic_report() {
    require_root
    init_context
    local ts report body gost_port ss_port realm_ports=() issue

    mkdir -p "$DIAG_DIR"
    chmod 700 "$DIAG_DIR" 2>/dev/null || true
    ts="$(date '+%Y%m%d-%H%M%S')"
    report="$DIAG_DIR/diagnose-${ts}.txt"
    body="$(mktemp /tmp/tuu-diag.XXXXXX)"
    DIAG_ISSUES=()

    log_info "正在收集排错信息，网络检测可能需要几十秒..."

    if [[ -f "$GOST_CONFIG" ]]; then
        gost_port="$(sed -n 's/.*addr:[[:space:]]*"[^"]*:\([0-9][0-9]*\)".*/\1/p' "$GOST_CONFIG" | head -n1)"
    fi
    if [[ -f "$SS_CONFIG" ]]; then
        ss_port="$(json_get_scalar "$SS_CONFIG" server_port)"
    fi
    if [[ -f "$REALM_CONFIG" ]]; then
        mapfile -t realm_ports < <(sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*".*:\([0-9][0-9]*\)".*/\1/p' "$REALM_CONFIG")
    fi

    {
        diag_system
        diag_check_service "GOST SOCKS5" "$GOST_SERVICE" "$GOST_BIN" "$GOST_CONFIG" \
            /var/log/gost/gost.log /var/log/gost/gost.err -V ${gost_port:+"$gost_port"}
        diag_check_service "Shadowsocks Rust" "$SS_SERVICE" "$SS_BIN" "$SS_CONFIG" \
            /var/log/ss-rust.log /var/log/ss-rust.err --version ${ss_port:+"$ss_port"}
        diag_check_service "Realm" "$REALM_SERVICE" "$REALM_BIN" "$REALM_CONFIG" \
            /var/log/realm.log /var/log/realm.err -v "${realm_ports[@]}"
        diag_check_realm_endpoints
        diag_section "脚本日志 $LOG_FILE (最后 150 行)"
        diag_tail "$LOG_FILE" 150
    } > "$body" 2>&1

    {
        echo "TUU Toolkit 排错报告"
        echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "说明: 密码和 ss:// 链接已脱敏，但报告中包含 IP 地址和端口，分享前请自行确认"
        diag_section "问题摘要 (${#DIAG_ISSUES[@]} 项)"
        if [[ ${#DIAG_ISSUES[@]} -eq 0 ]]; then
            echo "未发现明显问题"
        else
            for issue in "${DIAG_ISSUES[@]}"; do
                echo "- $issue"
            done
        fi
        cat "$body"
    } > "$report"
    rm -f "$body"
    chmod 600 "$report"

    # 只保留最近 10 份报告
    ls -1t "$DIAG_DIR"/diagnose-*.txt 2>/dev/null | tail -n +11 | xargs -r rm -f 2>/dev/null || true

    write_log "生成排错报告: $report (发现 ${#DIAG_ISSUES[@]} 项问题)"
    echo
    echo -e "${YELLOW}问题摘要:${NC}"
    if [[ ${#DIAG_ISSUES[@]} -eq 0 ]]; then
        log_success "未发现明显问题"
    else
        for issue in "${DIAG_ISSUES[@]}"; do
            echo -e "  ${RED}-${NC} $issue"
        done
    fi
    echo
    log_success "排错报告已保存: $report"
    echo "反馈问题时请附上此文件 (密码已脱敏，含 IP 地址)。"
}

# 给日志中的 ERROR/WARN 上色
colorize_log() {
    sed -e "s/\[ERROR\]/$(printf '\033[0;31m')[ERROR]$(printf '\033[0m')/" \
        -e "s/\[WARN\]/$(printf '\033[1;33m')[WARN]$(printf '\033[0m')/"
}

view_text() {
    if [[ -t 1 ]] && command -v less >/dev/null 2>&1; then
        less -R "$@"
    else
        cat "$@"
    fi
}

show_toolkit_log() {
    echo -e "${BLUE}===== 脚本日志 $LOG_FILE (最后 ${1:-100} 行) =====${NC}"
    if [[ -f "$LOG_FILE" ]]; then
        tail -n "${1:-100}" "$LOG_FILE" | colorize_log
    else
        echo "暂无脚本日志"
    fi
}

show_toolkit_errors() {
    echo -e "${BLUE}===== 最近的错误和警告 (含失败命令输出) =====${NC}"
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "暂无脚本日志"
        return 0
    fi
    local result
    result="$(awk '
        /\[(ERROR|WARN)\]/ { keep = 1; print; next }
        /^    \|/ { if (keep) print; next }
        { keep = 0 }
    ' "$LOG_FILE" | tail -n 120)"
    if [[ -z "$result" ]]; then
        log_success "日志中没有错误或警告"
    else
        printf '%s\n' "$result" | colorize_log
    fi
}

show_all_service_logs() {
    local f
    for f in /var/log/gost/gost.err /var/log/gost/gost.log /var/log/ss-rust.err /var/log/ss-rust.log /var/log/realm.err /var/log/realm.log; do
        [[ -f "$f" ]] || continue
        echo -e "\n${BLUE}===== $f (最后 30 行) =====${NC}"
        tail -n 30 "$f" | mask_secrets
    done
    if [[ "$SERVICE_MANAGER" == "systemd" ]] && command -v journalctl >/dev/null 2>&1; then
        local s
        for s in "$GOST_SERVICE" "$SS_SERVICE" "$REALM_SERVICE"; do
            [[ -f "/etc/systemd/system/$s.service" ]] || continue
            echo -e "\n${BLUE}===== journalctl -u $s (最后 30 行) =====${NC}"
            journalctl -u "$s" -n 30 --no-pager 2>&1 | mask_secrets
        done
    fi
}

show_latest_report() {
    local latest
    latest="$(ls -1t "$DIAG_DIR"/diagnose-*.txt 2>/dev/null | head -n1)"
    if [[ -z "$latest" ]]; then
        log_warn "还没有排错报告，请先生成"
        return 0
    fi
    echo "报告: $latest"
    view_text "$latest"
}

log_menu() {
    while true; do
        clear_screen
        echo -e "${BOLD}TUU Toolkit v${TOOL_VERSION} - 日志与排错${NC}"
        echo "脚本日志: $LOG_FILE"
        echo "报告目录: $DIAG_DIR"
        echo "1) 生成排错报告 (推荐，出问题时先运行这个)"
        echo "2) 查看最近一次排错报告"
        echo "3) 查看错误和警告"
        echo "4) 查看脚本日志 (最近 100 行)"
        echo "5) 查看所有服务日志"
        echo "6) 清空脚本日志"
        echo "0) 返回"
        read -r -p "请选择: " choice
        case "$choice" in
            1) generate_diagnostic_report; pause ;;
            2) show_latest_report; pause ;;
            3) show_toolkit_errors; pause ;;
            4) show_toolkit_log 100; pause ;;
            5) show_all_service_logs; pause ;;
            6)
                if confirm "确认清空 $LOG_FILE?"; then
                    : > "$LOG_FILE"
                    log_success "脚本日志已清空"
                fi
                pause
                ;;
            0) return ;;
            *) log_error "无效选项"; pause ;;
        esac
    done
}

gost_menu() {
    while true; do
        clear_screen
        echo -e "${BOLD}TUU Toolkit v${TOOL_VERSION} - GOST SOCKS5${NC}"
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
            2) start_and_verify_service "$GOST_SERVICE" /var/log/gost/gost.err; pause ;;
            3) service_action "$GOST_SERVICE" stop; pause ;;
            4) restart_and_verify_service "$GOST_SERVICE" /var/log/gost/gost.err; pause ;;
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
        echo -e "${BOLD}TUU Toolkit v${TOOL_VERSION} - Shadowsocks Rust${NC}"
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
            2) start_and_verify_service "$SS_SERVICE" /var/log/ss-rust.err; pause ;;
            3) service_action "$SS_SERVICE" stop; pause ;;
            4) restart_and_verify_service "$SS_SERVICE" /var/log/ss-rust.err; pause ;;
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
        echo -e "${BOLD}TUU Toolkit v${TOOL_VERSION} - Realm${NC}"
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
            5) realm_start_service start; pause ;;
            6) service_action "$REALM_SERVICE" stop; pause ;;
            7) realm_start_service restart; pause ;;
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
    log_session_start "菜单"

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
        echo "5) 检测/更新脚本"
        echo "6) 安装基础依赖"
        echo "7) 日志与排错"
        echo "0) 退出"
        echo -e "${YELLOW}========================================${NC}"
        read -r -p "请选择: " choice
        case "$choice" in
            1) gost_menu ;;
            2) ss_menu ;;
            3) realm_menu ;;
            4) print_system_info; pause ;;
            5) check_and_update_toolkit; pause ;;
            6) install_core_dependencies; pause ;;
            7) log_menu ;;
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
    --update)
        need_bash
        init_context
        log_session_start "$@"
        check_and_update_toolkit
        ;;
    --diagnose)
        need_bash
        init_context
        log_session_start "$@"
        generate_diagnostic_report
        ;;
    --log)
        need_bash
        init_context
        show_toolkit_errors
        echo
        show_toolkit_log 50
        ;;
    --help|-h)
        cat <<EOF
TUU Toolkit ${TOOL_VERSION}

用法:
  curl -fsSL ${RAW_URL} -o tuu-toolkit.sh && chmod +x tuu-toolkit.sh && ./tuu-toolkit.sh
  bash tuu-toolkit.sh
  bash tuu-toolkit.sh --check
  bash tuu-toolkit.sh --update
  bash tuu-toolkit.sh --diagnose   生成排错报告 (保存到 ${DIAG_DIR})
  bash tuu-toolkit.sh --log        查看脚本错误日志

功能:
  - GOST SOCKS5 安装与服务管理
  - Shadowsocks Rust 安装与服务管理
  - Realm 安装、转发规则与服务管理
  - 检测并更新 TUU Toolkit 脚本
  - 错误日志记录与一键排错报告

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
