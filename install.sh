#!/bin/bash

set -o errexit
set -o pipefail

readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_NC='\033[0m'

SYSTEM_ARCH=""
DEBIAN_CODENAME=""
PVE_VERSION=""
HOSTNAME_FQDN=""
SERVER_IP=""
MIRROR_BASE=""
PVE_REPO_COMPONENT=""
PVE_GPG_KEY_URL=""
DEFAULT_INTERFACE=""
CURRENT_IP=""
CURRENT_MAC=""
CURRENT_GATEWAY=""
NETWORK_PREFIX=""

log_info() { printf "${COLOR_GREEN}[INFO]${COLOR_NC} %s\n" "$1"; }
log_warn() { printf "${COLOR_YELLOW}[WARN]${COLOR_NC} %s\n" "$1"; }
log_error() { printf "${COLOR_RED}[ERROR]${COLOR_NC} %s\n" "$1"; }
log_step() { printf "\n${COLOR_BLUE}>>> [步骤] %s${COLOR_NC}\n" "$1"; }

function cleanup_on_exit() {
    log_warn "脚本被中断或发生错误，正在退出..."
    exit 1
}

function check_prerequisites() {
    log_step "检查系统环境和依赖"

    [[ $EUID -eq 0 ]] || { log_error "此脚本必须以 root 权限运行"; exit 1; }

    local arch
    arch=$(uname -m)
    case "$arch" in
        aarch64|arm64) SYSTEM_ARCH="arm64" ;;
        x86_64|amd64)  SYSTEM_ARCH="amd64" ;;
        *) log_error "不支持的系统架构: $arch"; exit 1 ;;
    esac
    log_info "检测到系统架构: ${SYSTEM_ARCH}"

    # 检查必要命令
    for cmd in curl lsb_release; do
        command -v "$cmd" &>/dev/null || { log_error "缺少必要命令: $cmd"; exit 1; }
    done
}

function check_debian_version() {
    log_step "验证 Debian 版本"
    
    [[ -f /etc/debian_version ]] || { log_error "未检测到 Debian 系统"; exit 1; }
    
    DEBIAN_CODENAME=$(lsb_release -cs)

    case "$DEBIAN_CODENAME" in
        bullseye) PVE_VERSION="7" ;;
        bookworm) PVE_VERSION="8" ;;
        trixie)   PVE_VERSION="9" ;;
        *) log_error "不支持的 Debian 版本: $DEBIAN_CODENAME"; exit 1 ;;
    esac
    log_info "检测到 Debian ${DEBIAN_CODENAME^}，将安装 PVE ${PVE_VERSION}"
}

function configure_architecture_specifics() {
    log_step "配置软件源"

    if [[ "$SYSTEM_ARCH" == "amd64" ]]; then
        MIRROR_BASE="http://download.proxmox.com/debian/pve"
        PVE_REPO_COMPONENT="pve-no-subscription"
        # 使用企业源的 GPG 密钥，但不添加企业源
        PVE_GPG_KEY_URL="https://enterprise.proxmox.com/debian/proxmox-release-${DEBIAN_CODENAME}.gpg"
        log_info "使用 Proxmox VE no-subscription 软件源"
        log_info "GPG 密钥 URL: ${PVE_GPG_KEY_URL}"
    else
        log_info "为 ARM64 选择第三方镜像源"
        local mirrors=(
            "https://mirrors.apqa.cn/proxmox/debian/pve|韩国主源"
            "https://mirrors.lierfang.com/proxmox/debian/pve|中国 Lierfang" 
            "https://hk.mirrors.apqa.cn/proxmox/debian/pve|中国香港"
            "https://de.mirrors.apqa.cn/proxmox/debian/pve|德国"
        )
        
        printf "请选择镜像源：\n"
        for i in "${!mirrors[@]}"; do
            IFS='|' read -r url desc <<< "${mirrors[i]}"
            printf "  %d) %s\n" $((i+1)) "$desc"
        done
        
        local choice
        while :; do
            read -p "请输入选项 (1-${#mirrors[@]}): " choice
            [[ "$choice" =~ ^[1-4]$ ]] && break
            log_warn "无效选项，请重新输入"
        done
        
        IFS='|' read -r MIRROR_BASE _ <<< "${mirrors[$((choice-1))]}"
        PVE_REPO_COMPONENT="port"
        PVE_GPG_KEY_URL="${MIRROR_BASE}/port.gpg"
    fi
}

function detect_network_info() {
    # 尝试自动检测网络信息
    local interfaces=($(find /sys/class/net -type l -not -name lo -exec basename {} \;))
    
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        return 1
    fi
    
    # 选择第一个非lo接口作为默认
    DEFAULT_INTERFACE="${interfaces[0]}"
    
    # 尝试检测IP地址
    CURRENT_IP=$(ip -4 addr show dev "$DEFAULT_INTERFACE" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)
    
    # 尝试检测MAC地址
    CURRENT_MAC=$(cat "/sys/class/net/$DEFAULT_INTERFACE/address" 2>/dev/null)
    
    # 尝试检测网关
    CURRENT_GATEWAY=$(ip route | grep default | awk '{print $3}' | head -n1)
    
    # 尝试检测网络前缀
    NETWORK_PREFIX=$(ip -4 addr show dev "$DEFAULT_INTERFACE" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f2 | head -n1)
    
    # 如果网络前缀为空，设置默认值
    [[ -z "$NETWORK_PREFIX" ]] && NETWORK_PREFIX="24"
    
    return 0
}

function get_network_info() {
    log_step "配置网络信息"
    
    # 先尝试自动检测
    if detect_network_info; then
        log_info "已自动检测到网络配置:"
        log_info "  - 网络接口: $DEFAULT_INTERFACE"
        log_info "  - IP 地址: $CURRENT_IP"
        log_info "  - MAC 地址: $CURRENT_MAC"
        log_info "  - 网关: $CURRENT_GATEWAY"
        log_info "  - 网络前缀: $NETWORK_PREFIX"
    else
        log_warn "无法自动检测网络配置，请手动输入"
        DEFAULT_INTERFACE="eth0"
    fi
    
    # 让用户确认或修改网络配置
    printf "\n请确认网络配置 (直接回车使用默认值):\n"
    
    read -p "网络接口 [${DEFAULT_INTERFACE}]: " input_interface
    DEFAULT_INTERFACE="${input_interface:-$DEFAULT_INTERFACE}"
    
    read -p "IP 地址 [${CURRENT_IP}]: " input_ip
    CURRENT_IP="${input_ip:-$CURRENT_IP}"
    
    # 验证IP格式
    while [[ ! $CURRENT_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; do
        log_warn "IP 地址格式无效"
        read -p "请输入有效的 IP 地址: " CURRENT_IP
    done
    
    read -p "MAC 地址 [${CURRENT_MAC}]: " input_mac
    CURRENT_MAC="${input_mac:-$CURRENT_MAC}"
    
    # 验证MAC格式
    while [[ -n "$CURRENT_MAC" && ! $CURRENT_MAC =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; do
        log_warn "MAC 地址格式无效"
        read -p "请输入有效的 MAC 地址 (或留空自动生成): " CURRENT_MAC
    done
    
    read -p "网关地址 [${CURRENT_GATEWAY}]: " input_gateway
    CURRENT_GATEWAY="${input_gateway:-$CURRENT_GATEWAY}"
    
    # 验证网关格式
    while [[ ! $CURRENT_GATEWAY =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; do
        log_warn "网关地址格式无效"
        read -p "请输入有效的网关地址: " CURRENT_GATEWAY
    done
    
    read -p "网络前缀 [${NETWORK_PREFIX}]: " input_prefix
    NETWORK_PREFIX="${input_prefix:-$NETWORK_PREFIX}"
    
    # 验证网络前缀
    while [[ ! $NETWORK_PREFIX =~ ^[0-9]{1,2}$ || $NETWORK_PREFIX -gt 32 ]]; do
        log_warn "网络前缀无效"
        read -p "请输入有效的网络前缀 (1-32): " NETWORK_PREFIX
    done
    
    log_info "最终网络配置:"
    log_info "  - 网络接口: $DEFAULT_INTERFACE"
    log_info "  - IP 地址: $CURRENT_IP"
    log_info "  - MAC 地址: $CURRENT_MAC"
    log_info "  - 网关: $CURRENT_GATEWAY"
    log_info "  - 网络前缀: /$NETWORK_PREFIX"
    
    return 0
}

function configure_hostname() {
    log_step "配置主机名"

    # 获取当前主机名作为默认值
    local current_hostname=$(hostname)
    local current_domain=$(hostname -d 2>/dev/null || echo "local")
    
    # 如果当前主机名包含域名，则分离
    if [[ "$current_hostname" == *.* ]]; then
        current_domain="${current_hostname#*.}"
        current_hostname="${current_hostname%%.*}"
    fi

    printf "请配置主机名 (直接回车使用默认值):\n"
    
    read -p "主机名 [${current_hostname}]: " hostname
    hostname="${hostname:-$current_hostname}"
    
    read -p "域名 [${current_domain}]: " domain  
    domain="${domain:-$current_domain}"
    
    HOSTNAME_FQDN="${hostname}.${domain}"
    SERVER_IP="$CURRENT_IP"

    log_info "配置预览: ${HOSTNAME_FQDN} (${SERVER_IP})"
    
    read -p "确认修改主机名和 hosts 文件? (y/N): " confirm_hosts
    [[ "${confirm_hosts,,}" != "y" ]] && { log_warn "操作取消"; return 1; }

    hostnamectl set-hostname "$HOSTNAME_FQDN"
    
    cat > /etc/hosts <<EOF
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
${SERVER_IP}    ${HOSTNAME_FQDN} ${hostname}
EOF
    log_info "主机配置完成"
}

function setup_network_bridge() {
    log_step "配置网络网桥 vmbr0"
    
    read -p "是否要配置 vmbr0 网桥? (Y/n): " confirm_bridge
    [[ "${confirm_bridge,,}" == "n" ]] && { log_info "跳过网桥配置"; return 0; }

    # 如果之前没有获取网络信息，则重新获取
    if [[ -z "$DEFAULT_INTERFACE" ]]; then
        if ! get_network_info; then
            log_error "无法获取网络信息，无法配置网桥"
            return 1
        fi
    fi
    
    log_info "当前网络配置:"
    log_info "  - 接口: $DEFAULT_INTERFACE"
    log_info "  - IP: $CURRENT_IP/$NETWORK_PREFIX"
    log_info "  - MAC: $CURRENT_MAC"
    log_info "  - 网关: $CURRENT_GATEWAY"

    read -p "使用以上配置创建网桥? (Y/n): " confirm_config
    [[ "${confirm_config,,}" == "n" ]] && {
        log_info "请手动输入网桥配置"
        while :; do
            read -p "请输入网桥 IP 地址 (CIDR格式, 如 192.168.1.10/24): " bridge_cidr
            [[ $bridge_cidr =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]] && break
            log_warn "CIDR 格式无效"
        done
        CURRENT_IP=$(echo "$bridge_cidr" | cut -d/ -f1)
        NETWORK_PREFIX=$(echo "$bridge_cidr" | cut -d/ -f2)
        
        while :; do
            read -p "请输入网关地址: " CURRENT_GATEWAY
            [[ $CURRENT_GATEWAY =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
            log_warn "网关地址格式无效"
        done
    }

    # 备份原网络配置
    cp /etc/network/interfaces "/etc/network/interfaces.backup.$(date +%Y%m%d_%H%M%S)"
    
    # 创建网桥配置 - 修正网桥配置格式
    cat > /etc/network/interfaces <<EOF
# Loopback interface
auto lo
iface lo inet loopback

# Physical interface
auto $DEFAULT_INTERFACE
iface $DEFAULT_INTERFACE inet manual

# Bridge interface
auto vmbr0
iface vmbr0 inet static
    address $CURRENT_IP/$NETWORK_PREFIX
    gateway $CURRENT_GATEWAY
    bridge-ports $DEFAULT_INTERFACE
    bridge-stp off
    bridge-fd 0
    bridge-maxwait 0
EOF

    log_info "网桥配置完成"
    log_info "  - 网桥名称: vmbr0"
    log_info "  - IP: ${CURRENT_IP}/${NETWORK_PREFIX}"
    log_info "  - 网关: ${CURRENT_GATEWAY}"
    log_info "  - 绑定接口: ${DEFAULT_INTERFACE}"
}

function activate_network_bridge() {
    log_step "激活网桥配置"
    
    # 安装网络工具
    if ! command -v brctl &>/dev/null && ! command -v bridge &>/dev/null; then
        log_info "安装 bridge-utils..."
        apt-get update
        apt-get install -y bridge-utils net-tools
    fi
    
    # 重启网络服务以应用配置
    log_info "重启网络服务应用网桥配置..."
    
    # 先停止网络服务
    systemctl stop networking 2>/dev/null || true
    sleep 2
    
    # 重新启动网络服务
    systemctl start networking
    
    # 等待网络稳定
    sleep 5
    
    # 检查网桥状态
    if ip link show vmbr0 &>/dev/null; then
        log_info "✅ vmbr0 网桥创建成功"
        
        # 检查IP地址
        local bridge_ip=$(ip addr show vmbr0 2>/dev/null | grep "inet " | awk '{print $2}') || true
        
        if [[ -n "$bridge_ip" ]]; then
            log_info "✅ 网桥 IP 配置成功: $bridge_ip"
        else
            log_warn "⚠️  网桥 IP 未配置，尝试手动配置"
            ip addr add $CURRENT_IP/$NETWORK_PREFIX dev vmbr0 2>/dev/null || true
        fi
        
        echo -e "\n当前网桥状态:"
        ip addr show vmbr0 2>/dev/null || echo "无法显示网桥信息"
        
        return 0
    else
        log_error "❌ vmbr0 网桥创建失败"
        log_info "尝试手动创建网桥..."
        
        # 手动创建网桥
        brctl addbr vmbr0 2>/dev/null || true
        brctl addif vmbr0 $DEFAULT_INTERFACE 2>/dev/null || true
        ip link set vmbr0 up 2>/dev/null || true
        ip addr add $CURRENT_IP/$NETWORK_PREFIX dev vmbr0 2>/dev/null || true
        
        if ip link show vmbr0 &>/dev/null; then
            log_info "✅ 手动创建网桥成功"
            return 0
        else
            log_error "❌ 网桥创建完全失败，请检查系统日志"
            log_info "您可能需要手动编辑 /etc/network/interfaces 文件"
            return 1
        fi
    fi
}

function run_installation() {
    log_step "安装 Proxmox VE"
    
    log_info "下载 GPG 密钥..."
    local gpg_key_name="proxmox-release-${DEBIAN_CODENAME}.gpg"
    
    # 尝试下载 GPG 密钥，如果失败则尝试备用方案
    if ! curl -fsSL "${PVE_GPG_KEY_URL}" -o "/etc/apt/trusted.gpg.d/${gpg_key_name}"; then
        log_warn "GPG 密钥下载失败，尝试备用方案..."
        
        # 对于 Debian Trixie (PVE 9)，尝试使用 Bookworm 的密钥
        if [[ "$DEBIAN_CODENAME" == "trixie" ]]; then
            log_info "尝试使用 PVE 8 (Bookworm) 的 GPG 密钥"
            PVE_GPG_KEY_URL="https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg"
            if ! curl -fsSL "${PVE_GPG_KEY_URL}" -o "/etc/apt/trusted.gpg.d/${gpg_key_name}"; then
                log_error "备用 GPG 密钥也下载失败"
                exit 1
            fi
        else
            log_error "GPG 密钥下载失败"
            exit 1
        fi
    fi

    # 只添加 no-subscription 源，不添加企业源
    echo "deb ${MIRROR_BASE} ${DEBIAN_CODENAME} ${PVE_REPO_COMPONENT}" > /etc/apt/sources.list.d/pve.list
    
    log_info "更新软件包列表..."
    apt-get update || { log_error "软件包更新失败"; exit 1; }
    
    log_info "安装 Proxmox VE 核心包..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y proxmox-ve postfix open-iscsi || {
        log_error "Proxmox VE 安装失败"; exit 1;
    }

    log_info "Proxmox VE 安装成功"
}

function show_completion_info() {
    printf "\n============================================================\n"
    log_info "    Proxmox VE $PVE_VERSION 安装成功!    "
    printf "============================================================\n\n"
    
    log_info "访问地址:"
    log_info "  - https://${SERVER_IP}:8006/"
    log_info "用户名: root"
    log_info "密码: 您的系统 root 密码\n"
    
    # 最终检查网桥状态
    if ip link show vmbr0 &>/dev/null; then
        log_info "✅ 网桥状态: 已激活"
        echo -e "\n当前网桥配置:"
        ip addr show vmbr0 2>/dev/null | grep "inet " || echo "网桥无IP配置"
    else
        log_warn "⚠️  网桥未激活，需要重启以应用网络配置"
    fi
    
    log_warn "需要重启以加载新内核和网络配置"
    read -p "立即重启? (y/N): " reboot_confirm
    if [[ "${reboot_confirm,,}" == "y" ]]; then
        log_info "5秒后重启..."
        sleep 5
        reboot
    else
        log_warn "请手动重启系统以应用所有更改: reboot"
    fi
}

function main() {
    trap cleanup_on_exit INT TERM
    
    echo "欢迎使用 Proxmox VE 一键安装脚本"
    echo "=================================="

    check_prerequisites
    check_debian_version
    configure_architecture_specifics

    # 先获取网络信息
    get_network_info || exit 1
    
    # 然后配置主机名
    configure_hostname || exit 1
    
    printf "\n====================== 安装确认 ======================\n"
    printf "  - 系统架构:        %s\n" "$SYSTEM_ARCH" 
    printf "  - Debian 版本:     %s (PVE %s)\n" "$DEBIAN_CODENAME" "$PVE_VERSION"
    printf "  - 主机名:          %s\n" "$HOSTNAME_FQDN"
    printf "  - 服务器 IP:       %s\n" "$SERVER_IP"
    printf "  - 软件源:          %s\n" "$MIRROR_BASE"
    printf "  - 仓库组件:        %s\n" "$PVE_REPO_COMPONENT"
    printf "  - GPG 密钥:        %s\n" "$PVE_GPG_KEY_URL"
    printf "============================================================\n"

    read -p "开始安装? (y/N): " final_confirm
    [[ "${final_confirm,,}" != "y" ]] && { log_error "安装取消"; exit 1; }

    run_installation
    setup_network_bridge
    activate_network_bridge
    show_completion_info
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
