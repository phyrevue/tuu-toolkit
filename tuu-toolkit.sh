#!/bin/bash

# TUU Toolkit 一键部署脚本
# 项目地址: https://github.com/phyrevue/tuu-toolkit
# Gost官方: https://github.com/go-gost/gost
# Version: 2.0.0
# 
# 使用方法:
# bash <(curl -fsSL https://raw.githubusercontent.com/phyrevue/tuu-toolkit/main/tuu-toolkit.sh)
# 
# 或带参数:
# PORT=8080 USE_AUTH=true USERNAME=admin PASSWORD=secret bash <(curl -fsSL https://raw.githubusercontent.com/phyrevue/tuu-toolkit/main/tuu-toolkit.sh)

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        log_info "请使用: sudo bash $0"
        exit 1
    fi
}

# 检测系统
detect_system() {
    if [[ -f /etc/redhat-release ]]; then
        OS="centos"
        PACKAGE_MANAGER="yum"
    elif cat /etc/issue | grep -q -E -i "debian|raspbian"; then
        OS="debian"
        PACKAGE_MANAGER="apt-get"
    elif cat /etc/issue | grep -q -E -i "ubuntu"; then
        OS="ubuntu"
        PACKAGE_MANAGER="apt-get"
    elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
        OS="centos"
        PACKAGE_MANAGER="yum"
    elif cat /proc/version | grep -q -E -i "debian|raspbian"; then
        OS="debian"
        PACKAGE_MANAGER="apt-get"
    elif cat /proc/version | grep -q -E -i "ubuntu"; then
        OS="ubuntu"
        PACKAGE_MANAGER="apt-get"
    elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
        OS="centos"
        PACKAGE_MANAGER="yum"
    else
        log_error "不支持的操作系统"
        exit 1
    fi
    
    log_info "检测到系统: $OS"
}

# 获取最新版本的 Gost
get_latest_version() {
    log_info "获取 Gost 最新版本..."
    
    # 使用 GitHub API 获取最新版本
    if command -v curl &> /dev/null; then
        LATEST_VERSION=$(curl -s https://api.github.com/repos/go-gost/gost/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    elif command -v wget &> /dev/null; then
        LATEST_VERSION=$(wget -qO- https://api.github.com/repos/go-gost/gost/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    else
        log_warn "无法自动获取最新版本，使用默认版本 v3.2.3"
        LATEST_VERSION="v3.2.3"
    fi
    
    # 验证版本格式
    if [[ ! "$LATEST_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_warn "获取版本失败，使用默认版本 v3.2.3"
        LATEST_VERSION="v3.2.3"
    fi
    
    GOST_VERSION="$LATEST_VERSION"
    GOST_VERSION_NUM="${GOST_VERSION#v}"  # 去掉 v 前缀
    
    log_info "将安装 Gost 版本: $GOST_VERSION"
}

# 检测架构并设置下载链接
set_download_url() {
    log_info "检测系统架构..."
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH_NAME="amd64"
            DOWNLOAD_URL="https://github.com/go-gost/gost/releases/download/${GOST_VERSION}/gost_${GOST_VERSION_NUM}_linux_amd64.tar.gz"
            ;;
        aarch64)
            ARCH_NAME="arm64"
            DOWNLOAD_URL="https://github.com/go-gost/gost/releases/download/${GOST_VERSION}/gost_${GOST_VERSION_NUM}_linux_arm64.tar.gz"
            ;;
        armv7l)
            ARCH_NAME="armv7"
            DOWNLOAD_URL="https://github.com/go-gost/gost/releases/download/${GOST_VERSION}/gost_${GOST_VERSION_NUM}_linux_armv7.tar.gz"
            ;;
        *)
            log_error "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
    
    log_info "架构: $ARCH ($ARCH_NAME)"
}

# 安装依赖
install_dependencies() {
    log_info "安装必要的依赖..."
    
    if [[ "$PACKAGE_MANAGER" == "apt-get" ]]; then
        # 尝试修复损坏的包
        log_info "检查包管理器状态..."
        dpkg --configure -a 2>/dev/null || true
        
        # 清理包缓存
        apt-get clean
        
        # 尝试更新，忽略特定错误
        log_info "更新包列表..."
        apt-get update 2>&1 | while read line; do
            if [[ ! "$line" =~ "bullseye-backports" ]]; then
                echo "$line"
            fi
        done || true
        
        # 安装包，使用 --fix-missing 选项
        log_info "安装必要的包..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing curl wget tar 2>&1 | \
            grep -v "bullseye-backports" || {
            log_warn "标准安装失败，尝试强制安装..."
            # 尝试单独安装每个包
            for pkg in curl wget tar; do
                if ! command -v $pkg &> /dev/null; then
                    DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing $pkg || \
                        log_warn "无法安装 $pkg，但继续执行..."
                fi
            done
        }
    elif [[ "$PACKAGE_MANAGER" == "yum" ]]; then
        yum install -y curl wget tar
    fi
    
    # 检查关键命令
    local missing_cmds=()
    for cmd in wget curl; do
        if ! command -v $cmd &> /dev/null; then
            missing_cmds+=($cmd)
        fi
    done
    
    if [ ${#missing_cmds[@]} -eq 2 ]; then
        log_error "缺少必要的下载工具: wget 和 curl"
        log_info "请手动安装: apt-get install -y wget curl"
        exit 1
    elif [ ${#missing_cmds[@]} -eq 1 ]; then
        log_warn "缺少 ${missing_cmds[0]}，将使用其他下载工具"
    fi
    
    log_success "依赖检查完成"
}

# 下载和安装 Gost
install_gost() {
    log_info "开始安装 Gost $GOST_VERSION ..."
    
    # 检查是否已安装
    if command -v gost &> /dev/null; then
        INSTALLED_VERSION=$(gost -V 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        if [[ "$INSTALLED_VERSION" == "$GOST_VERSION" ]]; then
            log_info "Gost $GOST_VERSION 已经安装"
            return
        else
            log_info "当前版本: $INSTALLED_VERSION，将更新到: $GOST_VERSION"
        fi
    fi
    
    # 创建临时目录
    TEMP_DIR="/tmp/gost-install-$(date +%s)"
    mkdir -p $TEMP_DIR
    cd $TEMP_DIR
    
    # 下载文件
    log_info "下载地址: $DOWNLOAD_URL"
    
    if command -v wget &> /dev/null; then
        wget --no-check-certificate -O gost.tar.gz "$DOWNLOAD_URL"
    elif command -v curl &> /dev/null; then
        curl -L -o gost.tar.gz "$DOWNLOAD_URL"
    else
        log_error "需要安装 wget 或 curl"
        exit 1
    fi
    
    if [[ $? -ne 0 ]]; then
        log_error "下载失败"
        exit 1
    fi
    
    # 解压和安装
    log_info "解压和安装..."
    tar -xzf gost.tar.gz
    
    if [[ ! -f gost ]]; then
        log_error "解压失败,找不到 gost 可执行文件"
        exit 1
    fi
    
    chmod +x gost
    
    # 停止服务（如果正在运行）
    if systemctl is-active --quiet gost; then
        systemctl stop gost
    fi
    
    cp gost /usr/local/bin/
    
    # 验证安装
    if /usr/local/bin/gost -V; then
        log_success "Gost $GOST_VERSION 安装成功"
    else
        log_error "Gost 安装失败"
        exit 1
    fi
    
    # 清理临时文件
    cd /
    rm -rf $TEMP_DIR
}

# 交互式配置
configure_interactive() {
    log_info "开始配置 SOCKS5 代理..."
    
    # 端口配置
    while true; do
        read -p "请输入 SOCKS5 端口 [默认: 1080]: " PORT
        PORT=${PORT:-1080}
        
        # 验证端口
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            log_error "端口必须是1-65535之间的数字"
            continue
        fi
        
        if [ "$PORT" -lt 1024 ]; then
            log_warn "端口 $PORT 是特权端口，需要root权限"
        fi
        
        # 检查端口是否被占用
        if netstat -tlnp 2>/dev/null | grep -q ":$PORT "; then
            log_warn "端口 $PORT 已被占用"
            read -p "是否继续使用此端口? [y/N]: " CONTINUE
            if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                continue
            fi
        fi
        break
    done
    
    # 绑定地址配置
    read -p "请输入绑定地址 [默认: 0.0.0.0 - 监听所有接口]: " BIND_ADDR
    BIND_ADDR=${BIND_ADDR:-0.0.0.0}
    
    # 认证配置
    read -p "是否启用用户认证? [y/N]: " ENABLE_AUTH
    if [[ "$ENABLE_AUTH" =~ ^[Yy]$ ]]; then
        USE_AUTH="true"
        
        # 用户名
        while true; do
            read -p "请输入用户名: " USERNAME
            if [[ -z "$USERNAME" ]]; then
                log_warn "用户名不能为空"
                continue
            fi
            break
        done
        
        # 密码
        while true; do
            read -s -p "请输入密码: " PASSWORD
            echo
            if [[ -z "$PASSWORD" ]]; then
                log_warn "密码不能为空"
                continue
            fi
            
            # 密码强度检查
            if [[ ${#PASSWORD} -lt 8 ]]; then
                log_warn "密码长度建议至少8位"
                read -p "是否继续使用当前密码? [y/N]: " CONTINUE
                if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                    continue
                fi
            fi
            
            # 确认密码
            read -s -p "请再次输入密码: " PASSWORD_CONFIRM
            echo
            if [[ "$PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
                log_warn "两次输入的密码不一致"
                continue
            fi
            break
        done
    else
        USE_AUTH="false"
    fi
    
    # 日志级别配置
    echo -e "\n日志级别选项："
    echo "1) debug - 详细调试信息"
    echo "2) info  - 一般信息"
    echo "3) warn  - 警告信息（默认）"
    echo "4) error - 仅错误信息"
    read -p "请选择日志级别 [1-4, 默认: 3]: " LOG_CHOICE
    
    case ${LOG_CHOICE:-3} in
        1) LOG_LEVEL="debug" ;;
        2) LOG_LEVEL="info" ;;
        3) LOG_LEVEL="warn" ;;
        4) LOG_LEVEL="error" ;;
        *) LOG_LEVEL="warn" ;;
    esac
}

# 生成配置文件
generate_config() {
    log_info "生成配置文件..."
    
    # 创建配置目录和日志目录
    mkdir -p /etc/gost
    mkdir -p /var/log/gost
    
    # 根据是否启用认证生成不同的配置
    if [[ "$USE_AUTH" == "true" ]]; then
        # 带认证的配置
        cat > /etc/gost/config.yaml << EOF
# Gost SOCKS5 代理配置文件 (带认证)
# 版本: ${GOST_VERSION}
# 生成时间: $(date)
# 端口: ${PORT}
# 认证: 启用 (用户名: ${USERNAME})

services:
- name: socks5-service
  addr: "${BIND_ADDR}:${PORT}"
  handler:
    type: socks5
    auth:
      username: ${USERNAME}
      password: ${PASSWORD}
  listener:
    type: tcp

log:
  level: ${LOG_LEVEL}
  output: /var/log/gost/gost.log
  rotation:
    maxSize: 100
    maxAge: 30
    maxBackups: 5
    compress: true
EOF
    else
        # 无认证的配置
        cat > /etc/gost/config.yaml << EOF
# Gost SOCKS5 代理配置文件 (无认证)
# 版本: ${GOST_VERSION}
# 生成时间: $(date)
# 端口: ${PORT}
# 认证: 禁用

services:
- name: socks5-service
  addr: "${BIND_ADDR}:${PORT}"
  handler:
    type: socks5
  listener:
    type: tcp

log:
  level: ${LOG_LEVEL}
  output: /var/log/gost/gost.log
  rotation:
    maxSize: 100
    maxAge: 30
    maxBackups: 5
    compress: true
EOF
    fi
    
    # 设置配置文件权限（保护密码安全）
    chmod 600 /etc/gost/config.yaml
    chown root:root /etc/gost/config.yaml
    
    log_success "配置文件已生成: /etc/gost/config.yaml"
}

# 创建 systemd 服务
create_systemd_service() {
    log_info "创建 systemd 服务..."
    
    cat > /etc/systemd/system/gost.service << EOF
[Unit]
Description=Gost SOCKS5 Proxy Service
Documentation=https://github.com/go-gost/gost
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/gost -C /etc/gost/config.yaml
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=gost

# 安全设置
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/gost

[Install]
WantedBy=multi-user.target
EOF
    
    # 重新加载 systemd
    systemctl daemon-reload
    
    # 启用服务
    systemctl enable gost
    
    log_success "Systemd 服务已创建并启用"
}

# 创建管理脚本
create_management_script() {
    log_info "创建管理脚本..."
    
    cat > /usr/local/bin/tuu-toolkit << 'EOF'
#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 帮助信息
show_help() {
    echo "TUU Toolkit 管理工具"
    echo ""
    echo "用法: tuu-toolkit [命令]"
    echo ""
    echo "命令:"
    echo "  start    - 启动服务"
    echo "  stop     - 停止服务"
    echo "  restart  - 重启服务"
    echo "  status   - 查看状态"
    echo "  logs     - 查看日志"
    echo "  config   - 查看配置"
    echo "  test     - 测试代理"
    echo "  update   - 更新 Gost"
    echo "  help     - 显示帮助"
}

# 测试代理功能
test_proxy() {
    echo -e "${GREEN}测试 SOCKS5 代理连接...${NC}"
    
    # 从配置文件读取端口和认证信息
    PORT=$(grep -A2 "addr:" /etc/gost/config.yaml | grep -oE ':[0-9]+' | cut -d: -f2 | head -1)
    USERNAME=$(grep "username:" /etc/gost/config.yaml 2>/dev/null | awk '{print $2}')
    PASSWORD=$(grep "password:" /etc/gost/config.yaml 2>/dev/null | awk '{print $2}')
    
    # 测试连接
    if [[ -n "$USERNAME" ]] && [[ -n "$PASSWORD" ]]; then
        # 使用认证测试
        timeout 5 curl --socks5-hostname "${USERNAME}:${PASSWORD}@127.0.0.1:${PORT}" \
            -s -o /dev/null -w "%{http_code}" https://www.google.com >/dev/null 2>&1
    else
        # 无认证测试
        timeout 5 curl --socks5-hostname "127.0.0.1:${PORT}" \
            -s -o /dev/null -w "%{http_code}" https://www.google.com >/dev/null 2>&1
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 代理连接成功${NC}"
        echo -e "代理地址: 127.0.0.1:${PORT}"
        if [[ -n "$USERNAME" ]]; then
            echo -e "认证方式: 用户名/密码"
            echo -e "用户名: ${USERNAME}"
        else
            echo -e "认证方式: 无"
        fi
    else
        echo -e "${RED}✗ 代理连接失败${NC}"
        echo -e "${YELLOW}请检查服务是否正在运行${NC}"
    fi
}

# 更新 Gost
update_gost() {
    echo -e "${GREEN}检查 Gost 更新...${NC}"
    
    # 获取当前版本
    CURRENT_VERSION=$(gost -V 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    echo -e "当前版本: ${CURRENT_VERSION}"
    
    # 获取最新版本
    LATEST_VERSION=$(curl -s https://api.github.com/repos/go-gost/gost/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    echo -e "最新版本: ${LATEST_VERSION}"
    
    if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
        echo -e "${GREEN}已是最新版本${NC}"
    else
        echo -e "${YELLOW}发现新版本，是否更新? [y/N]:${NC} "
        read -r CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            # 下载更新脚本并执行
            bash <(curl -fsSL https://raw.githubusercontent.com/phyrevue/tuu-toolkit/main/tuu-toolkit.sh)
        fi
    fi
}

case "$1" in
    start)
        echo -e "${GREEN}启动 Gost SOCKS5 服务...${NC}"
        systemctl start gost
        systemctl status gost --no-pager
        ;;
    stop)
        echo -e "${YELLOW}停止 Gost SOCKS5 服务...${NC}"
        systemctl stop gost
        ;;
    restart)
        echo -e "${YELLOW}重启 Gost SOCKS5 服务...${NC}"
        systemctl restart gost
        systemctl status gost --no-pager
        ;;
    status)
        systemctl status gost --no-pager
        ;;
    logs)
        echo -e "${BLUE}查看最近的日志...${NC}"
        journalctl -u gost -n 50 --no-pager
        ;;
    config)
        echo -e "${BLUE}当前配置:${NC}"
        cat /etc/gost/config.yaml
        ;;
    test)
        test_proxy
        ;;
    update)
        update_gost
        ;;
    help|*)
        show_help
        ;;
esac
EOF
    
    chmod +x /usr/local/bin/tuu-toolkit
    
    log_success "管理脚本已创建: tuu-toolkit"
}

# 配置防火墙
configure_firewall() {
    log_info "配置防火墙..."
    
    # 检查并配置 firewalld
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port=${PORT}/tcp
        firewall-cmd --reload
        log_success "firewalld 规则已添加"
    # 检查并配置 ufw
    elif command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        ufw allow ${PORT}/tcp
        log_success "ufw 规则已添加"
    # 检查并配置 iptables
    elif command -v iptables &> /dev/null; then
        iptables -A INPUT -p tcp --dport ${PORT} -j ACCEPT
        # 保存规则
        if command -v netfilter-persistent &> /dev/null; then
            netfilter-persistent save
        elif command -v iptables-save &> /dev/null; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
        log_success "iptables 规则已添加"
    else
        log_warn "未检测到防火墙，请手动配置端口 ${PORT} 的访问规则"
    fi
}

# 显示安装信息
show_info() {
    echo ""
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}    Gost SOCKS5 安装成功!${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    echo -e "${BLUE}服务状态:${NC}"
    systemctl status gost --no-pager | head -n 3
    echo ""
    echo -e "${BLUE}代理信息:${NC}"
    echo -e "协议: SOCKS5"
    echo -e "地址: ${BIND_ADDR}:${PORT}"
    
    if [[ "$USE_AUTH" == "true" ]]; then
        echo -e "认证: 启用"
        echo -e "用户名: ${USERNAME}"
        echo -e "密码: ${PASSWORD}"
    else
        echo -e "认证: 禁用"
    fi
    
    echo ""
    echo -e "${BLUE}管理命令:${NC}"
    echo -e "启动服务: tuu-toolkit start"
    echo -e "停止服务: tuu-toolkit stop"
    echo -e "重启服务: tuu-toolkit restart"
    echo -e "查看状态: tuu-toolkit status"
    echo -e "查看日志: tuu-toolkit logs"
    echo -e "测试代理: tuu-toolkit test"
    echo -e "更新版本: tuu-toolkit update"
    echo ""
    echo -e "${BLUE}配置文件:${NC} /etc/gost/config.yaml"
    echo -e "${BLUE}日志文件:${NC} /var/log/gost/gost.log"
    echo ""
    
    # 获取服务器 IP
    SERVER_IP=$(curl -s4 ip.sb 2>/dev/null || curl -s4 ipinfo.io/ip 2>/dev/null || echo "YOUR_SERVER_IP")
    
    echo -e "${BLUE}客户端配置示例:${NC}"
    if [[ "$USE_AUTH" == "true" ]]; then
        echo -e "curl --socks5-hostname ${USERNAME}:${PASSWORD}@${SERVER_IP}:${PORT} https://www.google.com"
    else
        echo -e "curl --socks5-hostname ${SERVER_IP}:${PORT} https://www.google.com"
    fi
    echo ""
    echo -e "${GREEN}======================================${NC}"
}

# 主函数
main() {
    clear
    echo -e "${BLUE}TUU Toolkit 一键部署脚本${NC}"
    echo -e "${BLUE}项目地址: https://github.com/phyrevue/tuu-toolkit${NC}"
    echo ""
    
    # 检查是否为 root
    check_root
    
    # 检测系统
    detect_system
    
    # 获取最新版本
    get_latest_version
    
    # 设置下载链接
    set_download_url
    
    # 检查是否通过环境变量传入了配置
    if [[ -n "$PORT" ]] && [[ -n "$USE_AUTH" ]]; then
        # 静默安装模式
        log_info "使用预设配置进行安装..."
        log_info "端口: $PORT"
        log_info "认证: $USE_AUTH"
        
        # 验证端口
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            log_error "端口必须是1-65535之间的数字"
            exit 1
        fi
        
        # 设置默认值
        BIND_ADDR=${BIND_ADDR:-0.0.0.0}
        LOG_LEVEL=${LOG_LEVEL:-warn}
        
        # 如果启用认证，检查用户名和密码
        if [[ "$USE_AUTH" == "true" ]]; then
            if [[ -z "$USERNAME" ]] || [[ -z "$PASSWORD" ]]; then
                log_error "启用认证时必须提供用户名和密码"
                exit 1
            fi
        fi
    else
        # 交互式配置
        configure_interactive
    fi
    
    # 安装流程
    install_dependencies
    install_gost
    generate_config
    create_systemd_service
    create_management_script
    configure_firewall
    
    # 启动服务
    log_info "启动 Gost 服务..."
    systemctl start gost
    
    # 等待服务启动
    sleep 2
    
    # 检查服务状态
    if systemctl is-active --quiet gost; then
        log_success "Gost 服务启动成功"
    else
        log_error "Gost 服务启动失败"
        log_info "请查看日志: journalctl -u gost -n 50"
        exit 1
    fi
    
    # 显示安装信息
    show_info
}

# 运行主函数
main "$@"
