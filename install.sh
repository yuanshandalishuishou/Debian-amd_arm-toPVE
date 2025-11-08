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

function remove_all_enterprise_sources() {
    log_step "彻底清理企业订阅源"
    
    log_info "删除所有企业源文件..."
    # 删除所有可能的企业源文件
    rm -f /etc/apt/sources.list.d/pve-enterprise.* 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/ceph-enterprise.* 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/proxmox-enterprise.* 2>/dev/null || true
    
    # 清理 sources.list 文件中的企业源
    if grep -q "enterprise.proxmox.com" /etc/apt/sources.list 2>/dev/null; then
        log_info "清理 /etc/apt/sources.list 中的企业源"
        sed -i '/enterprise.proxmox.com/d' /etc/apt/sources.list
    fi
    
    # 清理可能的备份文件
    rm -f /etc/apt/sources.list.d/pve-enterprise.list.bak 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/pve-enterprise.sources.bak 2>/dev/null || true
    
    # 检查是否还有企业源残留
    local enterprise_sources
    enterprise_sources=$(grep -r "enterprise.proxmox.com" /etc/apt/sources.list* 2>/dev/null || true)
    
    if [[ -n "$enterprise_sources" ]]; then
        log_warn "发现残留的企业源配置:"
        echo "$enterprise_sources"
        log_info "强制清理残留配置..."
        # 使用sed删除所有包含enterprise.proxmox.com的行
        sed -i '/enterprise.proxmox.com/d' /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null || true
    fi
    
    log_info "企业订阅源清理完成"
}

function clean_proxmox_residue() {
    log_step "清理 Proxmox 残留配置"
    
    # 先清理企业源
    remove_all_enterprise_sources
    
    # 检查是否有残留的 apt hook
    if [[ -f /etc/apt/apt.conf.d/80proxmox ]] || \
       dpkg -l | grep -q proxmox || \
       [[ -d /usr/share/proxmox-ve ]]; then
        
        log_warn "检测到 Proxmox 残留配置，正在清理..."
        
        # 移除 apt hook 配置
        rm -f /etc/apt/apt.conf.d/80proxmox 2>/dev/null || true
        rm -f /etc/apt/apt.conf.d/z80proxmox 2>/dev/null || true
        
        # 如果 pve-apt-hook 目录存在但脚本不存在，修复这个问题
        if [[ -d /usr/share/proxmox-ve ]] && [[ ! -f /usr/share/proxmox-ve/pve-apt-hook ]]; then
            log_info "修复损坏的 pve-apt-hook 配置..."
            # 创建一个空的 pve-apt-hook 来避免错误
            cat > /usr/share/proxmox-ve/pve-apt-hook << 'EOF'
#!/bin/sh
exit 0
EOF
            chmod +x /usr/share/proxmox-ve/pve-apt-hook
        fi
        
        # 清理可能的包残留
        if dpkg -l | grep -q proxmox; then
            log_info "移除 Proxmox 相关包..."
            apt-get remove --purge -y proxmox-ve pve-manager pve-kernel-* 2>/dev/null || true
            apt-get autoremove -y 2>/dev/null || true
        fi
        
        # 清理配置目录
        rm -rf /etc/pve 2>/dev/null || true
        rm -rf /var/lib/pve-manager 2>/dev/null || true
    fi
    
    log_info "残留配置清理完成"
}

function check_proxmox_installed() {
    log_step "检查 Proxmox VE 安装状态"
    
    # 检查是否已是完整安装的PVE
    if [[ -f /etc/pve/version ]]; then
        log_error "系统已安装Proxmox VE，无需重复安装"
        return 1
    fi
    
    # 清理残留配置
    clean_proxmox_residue
    
    return 0
}

function check_system_resources() {
    log_step "检查系统资源"
    
    # 检查磁盘空间
    local available_space
    available_space=$(df / | awk 'NR==2 {print $4}')
    if [[ "$available_space" -lt 10485760 ]]; then  # 小于10GB
        log_error "磁盘空间不足，至少需要10GB可用空间"
        return 1
    fi
    log_info "磁盘空间: 充足 ($((available_space/1024))MB 可用)"
    
    # 检查内存
    local total_mem
    total_mem=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    if [[ "$total_mem" -lt 2097152 ]]; then  # 小于2GB
        log_warn "内存小于2GB，可能影响Proxmox VE性能"
    else
        log_info "内存: 充足 ($((total_mem/1024))MB)"
    fi
    
    return 0
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
        PVE_GPG_KEY_URL="https://enterprise.proxmox.com/debian/proxmox-release-${DEBIAN_CODENAME}.gpg"
        log_info "使用 Proxmox 官方软件源"
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

function install_essential_tools() {
    log_step "安装必要工具"
    
    # 先彻底清理企业源
    remove_all_enterprise_sources
    
    # 先更新系统
    log_info "更新系统包列表..."
    if ! apt-get update; then
        log_warn "首次更新失败，但继续执行..."
    fi
    
    # 修复损坏的包状态（如果有）
    log_info "修复包状态..."
    dpkg --configure -a 2>/dev/null || true
    apt-get install -f -y 2>/dev/null || true
    
    # 安装必要包 - 使用更安全的方式
    log_info "安装基本网络工具..."
    
    # 逐个安装包，避免批量安装触发问题
    local essential_packages=("net-tools" "curl" "wget" "gnupg")
    for pkg in "${essential_packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            log_info "安装 $pkg..."
            if ! apt-get install -y --allow-downgrades --allow-remove-essential --allow-change-held-packages "$pkg"; then
                log_warn "$pkg 安装出现问题，但尝试继续"
            fi
        else
            log_info "$pkg 已安装"
        fi
    done
    
    # 单独处理 ifupdown，因为它可能触发 pve-apt-hook
    if ! dpkg -l | grep -q "^ii  ifupdown "; then
        log_info "安装 ifupdown..."
        # 使用更保守的方式安装
        if ! apt-get download ifupdown; then
            log_warn "无法下载 ifupdown，跳过安装"
        else
            dpkg -i ifupdown*.deb 2>/dev/null || true
            apt-get install -f -y 2>/dev/null || true
            rm -f ifupdown*.deb
        fi
    fi
    
    log_info "必要工具安装完成"
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
    local current_hostname
    current_hostname=$(hostname)
    local current_domain
    current_domain=$(hostname -d 2>/dev/null || echo "local")
    
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
    
    # 创建正确的网桥配置 - 使用 Proxmox VE 的标准格式
    cat > /etc/network/interfaces <<EOF
# Loopback interface
auto lo
iface lo inet loopback

# Physical interface - set to manual for bridge
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
    # Local network address
    up ip addr add 192.168.250.254/24 dev vmbr0
EOF

    log_info "网桥配置完成"
    log_info "  - 网桥名称: vmbr0"
    log_info "  - 公网 IP: ${CURRENT_IP}/${NETWORK_PREFIX}"
    log_info "  - 本地 IP: 192.168.250.254/24"
    log_info "  - 绑定接口: ${DEFAULT_INTERFACE}"
}

function activate_network_bridge() {
    log_step "激活网桥配置"
    
    log_warn "注意：网络配置更改可能导致当前SSH连接中断"
    log_warn "建议通过控制台或带外管理执行此操作"
    
    read -p "继续操作? (y/N): " confirm_network
    [[ "${confirm_network,,}" != "y" ]] && { 
        log_info "跳过网络激活，请稍后手动重启网络服务或重启系统"
        return 0
    }
    
    # 安装必要的网络工具
    log_info "安装网络工具..."
    
    # 先清理企业源，避免更新失败
    remove_all_enterprise_sources
    
    # 更新包列表
    if ! apt-get update; then
        log_warn "包列表更新失败，但继续执行网络配置..."
    fi
    
    # 逐个安装网络工具，避免触发问题
    local network_packages=("bridge-utils" "net-tools")
    for pkg in "${network_packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            log_info "安装 $pkg..."
            if apt-get download "$pkg" 2>/dev/null; then
                dpkg -i "${pkg}"*.deb 2>/dev/null || true
                rm -f "${pkg}"*.deb
            else
                log_warn "无法下载 $pkg，跳过"
            fi
        fi
    done
    
    # 修复包依赖
    apt-get install -f -y 2>/dev/null || true
    
    # 停止可能的网络管理器
    log_info "停止网络管理器..."
    systemctl stop NetworkManager 2>/dev/null || true
    systemctl disable NetworkManager 2>/dev/null || true
    
    # 确保使用传统的 networking 服务
    systemctl enable networking
    
    # 重新加载网络配置
    log_info "重新加载网络配置..."
    
    # 先关闭接口
    ip link set "$DEFAULT_INTERFACE" down 2>/dev/null || true
    ip link delete vmbr0 2>/dev/null || true
    
    # 重启网络服务
    log_info "重启网络服务..."
    if systemctl restart networking; then
        log_info "网络服务重启成功"
    else
        log_warn "网络服务重启失败，尝试手动配置"
        # 手动配置网桥
        brctl addbr vmbr0 2>/dev/null || true
        brctl addif vmbr0 "$DEFAULT_INTERFACE" 2>/dev/null || true
        ip link set vmbr0 up 2>/dev/null || true
        ip link set "$DEFAULT_INTERFACE" up 2>/dev/null || true
    fi
    
    # 等待网络稳定
    sleep 3
    
    # 检查网桥状态
    if ip link show vmbr0 &>/dev/null; then
        log_info "✅ vmbr0 网桥创建成功"
        
        # 配置IP地址
        ip addr add "$CURRENT_IP/$NETWORK_PREFIX" dev vmbr0 2>/dev/null || true
        ip addr add 192.168.250.254/24 dev vmbr0 2>/dev/null || true
        ip route add default via "$CURRENT_GATEWAY" dev vmbr0 2>/dev/null || true
        
        echo -e "\n当前网桥状态:"
        ip addr show vmbr0 | grep inet || echo "   未配置IP"
        echo -e "\n网桥链接状态:"
        bridge link show 2>/dev/null || brctl show 2>/dev/null || echo "无法显示网桥链接信息"
        
        return 0
    else
        log_error "❌ vmbr0 网桥创建失败"
        log_info "网桥配置已保存，重启后生效"
        return 1
    fi
}

function check_pve_services() {
    log_step "检查 Proxmox VE 服务状态"
    
    local services=("pveproxy" "pvedaemon" "pvestatd" "pve-cluster")
    local all_running=true
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            log_info "✅ $service 正在运行"
        else
            log_warn "⚠️  $service 未运行，尝试启动..."
            if systemctl start "$service" 2>/dev/null; then
                log_info "✅ $service 启动成功"
            else
                log_error "❌ $service 启动失败"
                all_running=false
            fi
        fi
    done
    
    # 等待服务完全启动
    if $all_running; then
        log_info "等待 Proxmox VE 服务完全初始化..."
        sleep 5
        
        # 检查 /etc/pve 目录是否存在
        local max_attempts=10
        local attempt=1
        
        while [[ $attempt -le $max_attempts ]]; do
            if [[ -d /etc/pve ]] && [[ -d /etc/pve/nodes ]]; then
                log_info "✅ Proxmox VE 配置目录已就绪"
                return 0
            fi
            log_info "等待 Proxmox VE 配置目录... ($attempt/$max_attempts)"
            sleep 3
            ((attempt++))
        done
        
        log_error "❌ Proxmox VE 配置目录未在预期时间内创建"
        return 1
    else
        log_error "❌ 必要的 Proxmox VE 服务未运行"
        return 1
    fi
}

function run_installation() {
    log_step "安装 Proxmox VE"
    
    # 首先彻底清理企业源
    remove_all_enterprise_sources
    
    # 修复任何apt配置问题
    log_info "修复APT配置..."
    rm -f /etc/apt/apt.conf.d/80proxmox 2>/dev/null || true
    
    log_info "下载 GPG 密钥..."
    local gpg_key_name="proxmox-release-${DEBIAN_CODENAME}.gpg"
    if ! curl -fsSL "${PVE_GPG_KEY_URL}" -o "/etc/apt/trusted.gpg.d/${gpg_key_name}"; then
        log_error "GPG 密钥下载失败"
        # 尝试替代方案
        if ! wget -O "/etc/apt/trusted.gpg.d/${gpg_key_name}" "${PVE_GPG_KEY_URL}"; then
            log_error "无法下载 GPG 密钥，安装中止"
            exit 1
        fi
    fi

    # 创建我们的软件源，使用非企业源
    echo "deb ${MIRROR_BASE} ${DEBIAN_CODENAME} ${PVE_REPO_COMPONENT}" > /etc/apt/sources.list.d/pve-no-subscription.list
    
    # 再次确认清理企业源
    remove_all_enterprise_sources
    
    log_info "更新软件包列表..."
    if ! apt-get update; then
        log_error "软件包更新失败，请检查网络连接和软件源配置"
        log_info "当前配置的软件源:"
        cat /etc/apt/sources.list.d/*.list 2>/dev/null || echo "无软件源配置"
        exit 1
    fi
    
    log_info "安装 Proxmox VE 核心包..."
    export DEBIAN_FRONTEND=noninteractive
    
    # 使用更安全的安装方式
    log_info "阶段1: 安装基础组件..."
    apt-get install -y proxmox-default-kernel 2>/dev/null || true
    
    log_info "阶段2: 安装主要组件..."
    if ! apt-get install -y proxmox-ve postfix open-iscsi; then
        log_error "Proxmox VE 安装失败"
        log_info "尝试替代安装方法..."
        
        # 尝试逐个安装关键组件
        local pve_packages=("pve-manager" "pve-kernel-6.8" "qemu-server" "pve-firmware" "postfix" "open-iscsi")
        for pkg in "${pve_packages[@]}"; do
            log_info "安装 $pkg..."
            apt-get install -y "$pkg" 2>/dev/null || true
        done
        
        # 最后尝试安装元包
        apt-get install -y proxmox-ve 2>/dev/null || {
            log_error "Proxmox VE 安装完全失败"
            exit 1
        }
    fi
    
    log_info "Proxmox VE 安装成功"
    
    # 检查服务状态
    if ! check_pve_services; then
        log_warn "Proxmox VE 服务未完全启动，但安装已完成"
    fi
}

function install_routeros() {
    log_step "安装 RouterOS 虚拟机"
    
    local download_url="https://drive.usercontent.google.com/download?id=1DL2uaMfWz2mDHSE_0vRLz1Fw02isTfRe&export=download&authuser=0"
    local image_dir="/var/lib/vz/images/101"
    
    # 创建存储目录
    mkdir -p "$image_dir"
    cd "$image_dir" || { log_error "无法进入目录 $image_dir"; return 1; }
    
    log_info "下载 RouterOS 镜像..."
    if ! wget -O MikroTik-RouterOS.qcow2.xz "$download_url"; then
        log_error "RouterOS 镜像下载失败"
        return 1
    fi
    
    log_info "解压镜像文件..."
    if ! xz -d MikroTik-RouterOS.qcow2.xz; then
        log_error "镜像解压失败"
        return 1
    fi
    
    # 检查 Proxmox VE 配置目录是否存在
    if [[ ! -d /etc/pve/qemu-server ]]; then
        log_warn "Proxmox VE 配置目录不存在，等待服务启动..."
        
        # 尝试启动服务
        systemctl start pve-cluster 2>/dev/null || true
        systemctl start pvedaemon 2>/dev/null || true
        
        # 等待目录创建
        local max_wait=30
        local waited=0
        while [[ $waited -lt $max_wait ]] && [[ ! -d /etc/pve/qemu-server ]]; do
            sleep 3
            ((waited+=3))
            log_info "等待 Proxmox VE 配置目录... ${waited}s/${max_wait}s"
        done
        
        if [[ ! -d /etc/pve/qemu-server ]]; then
            log_error "Proxmox VE 配置目录仍未创建，无法创建虚拟机配置"
            log_info "RouterOS 镜像已下载，但需要重启后手动创建虚拟机"
            return 1
        fi
    fi
    
    # 创建虚拟机配置
    log_info "创建 RouterOS 虚拟机配置..."
    cat > /etc/pve/qemu-server/101.conf << 'EOF'
boot: order=ide0
cores: 1
cpu: host
ide0: local:101/MikroTik-RouterOS.qcow2,model=VMware%20Virtual%20IDE%20Hard%20Drive,serial=00000000000000000001
memory: 1024
name: MikroTik-RouterOS
net0: virtio=BC:24:11:00:00:00,bridge=vmbr0,queues=4
net1: virtio=BC:24:11:00:00:01,bridge=vmbr1,queues=4
net2: virtio=BC:24:11:00:00:02,bridge=vmbr2,queues=4
numa: 1
sockets: 1
EOF

    log_info "RouterOS 虚拟机配置完成"
}

function show_completion_info() {
    printf "\n============================================================\n"
    log_info "    Proxmox VE $PVE_VERSION 安装成功!    "
    printf "============================================================\n\n"
    
    log_info "访问地址:"
    log_info "  - 公网: https://${SERVER_IP}:8006/"
    log_info "  - 本地: https://192.168.250.254:8006/"
    log_info "用户名: root"
    log_info "密码: 您的系统 root 密码\n"
    
    # 显示当前网络配置
    log_info "当前网络配置:"
    cat /etc/network/interfaces
    
    # 检查网桥状态
    log_info "\n网络状态检查:"
    if ip link show vmbr0 &>/dev/null; then
        log_info "✅ vmbr0 网桥状态: 已激活"
        echo -e "\n网桥IP配置:"
        ip addr show vmbr0 | grep inet || echo "  暂无IP配置"
        echo -e "\n路由表:"
        ip route show | grep -E "(default|vmbr0)"
    else
        log_error "❌ vmbr0 网桥未激活"
        log_info "当前网络接口:"
        ip addr show | grep -E "^(inet|^[0-9]+:)" | head -10
    fi
    
    # 检查 Proxmox VE 状态
    log_info "\nProxmox VE 状态:"
    if systemctl is-active --quiet pveproxy; then
        log_info "✅ Proxmox VE Web 界面: 运行中"
    else
        log_warn "⚠️  Proxmox VE Web 界面: 未运行"
    fi
    
    if [[ -d /etc/pve/qemu-server ]]; then
        log_info "✅ 虚拟机配置目录: 就绪"
    else
        log_warn "⚠️  虚拟机配置目录: 未就绪"
    fi
    
    log_warn "重要：建议重启系统以确保所有网络配置生效"
    read -p "立即重启? (y/N): " reboot_confirm
    if [[ "${reboot_confirm,,}" == "y" ]]; then
        log_info "10秒后重启..."
        sleep 10
        reboot
    else
        log_warn "请手动重启系统以应用所有更改: reboot"
        log_info "或者手动重启网络: systemctl restart networking"
    fi
}

function main() {
    trap cleanup_on_exit INT TERM
    
    echo "欢迎使用 Proxmox VE 一键安装脚本"
    echo "=================================="

    check_prerequisites
    check_proxmox_installed || exit 1
    check_system_resources || exit 1
    check_debian_version
    configure_architecture_specifics

    # 先安装必要工具
    install_essential_tools

    # 然后获取网络信息
    get_network_info || exit 1
    
    # 然后配置主机名
    configure_hostname || exit 1
    
    printf "\n====================== 安装确认 ======================\n"
    printf "  - 系统架构:        %s\n" "$SYSTEM_ARCH" 
    printf "  - Debian 版本:     %s (PVE %s)\n" "$DEBIAN_CODENAME" "$PVE_VERSION"
    printf "  - 主机名:          %s\n" "$HOSTNAME_FQDN"
    printf "  - 服务器 IP:       %s\n" "$SERVER_IP"
    printf "  - 本地 IP:         192.168.250.254/24\n"
    printf "  - 软件源:          %s\n" "$MIRROR_BASE"
    printf "============================================================\n"

    read -p "开始安装? (y/N): " final_confirm
    [[ "${final_confirm,,}" != "y" ]] && { log_error "安装取消"; exit 1; }

    run_installation
    setup_network_bridge
    activate_network_bridge
    install_routeros
    show_completion_info
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
