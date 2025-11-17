#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本需要root权限运行${NC}"
        exit 1
    fi
}

# 显示菜单
show_menu() {
    clear
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════╗"
    echo "║       网络引导安装工具菜单           ║"
    echo "╠══════════════════════════════════════╣"
    echo "║ 1. 使用Ventoy网络版                  ║"
    echo "║ 2. 使用iPXE (推荐方案)              ║"
    echo "║ 3. 使用网络引导服务器               ║"
    echo "║ 4. 使用现成的网络引导服务           ║"
    echo "║ 5. 本地下载然后安装                 ║"
    echo "║ 6. 退出                             ║"
    echo "╚══════════════════════════════════════╝"
    echo -e "${NC}"
}

# 方法1: 使用Ventoy网络版
ventoy_netboot() {
    echo -e "${YELLOW}[1] 配置Ventoy网络引导...${NC}"
    
    # 安装必要工具
    apt update && apt install -y grub2-common
    
    # 配置GRUB
    cat >> /etc/grub.d/40_custom <<'EOF'

menuentry "Ventoy Network Boot" {
    insmod chain
    insmod net
    insmod http
    set root='(http)'
    chain http://www.ventoy.net/ventoy_netboot.sh
}
EOF

    update-grub
    echo -e "${GREEN}Ventoy网络引导已配置完成${NC}"
    echo -e "${YELLOW}重启后选择 'Ventoy Network Boot' 即可使用${NC}"
    read -p "按回车键继续..."
}

# 方法2: 使用iPXE
ipxe_boot() {
    echo -e "${YELLOW}[2] 配置iPXE网络引导...${NC}"
    
    # 安装必要工具
    apt update && apt install -y grub2-common
    
    # 创建iPXE配置
    cat >> /etc/grub.d/40_custom <<'EOF'

menuentry "iPXE Boot Menu" {
    insmod chain
    insmod net
    insmod http
    set root='(http)'
    chain --autofree http://boot.netboot.xyz/ipxe/netboot.xyz.lkrn
}
EOF

    update-grub
    echo -e "${GREEN}iPXE引导已配置完成${NC}"
    echo -e "${YELLOW}重启后选择 'iPXE Boot Menu' 即可使用netboot.xyz${NC}"
    read -p "按回车键继续..."
}

# 方法3: 使用网络引导服务器
network_boot_server() {
    echo -e "${YELLOW}[3] 设置网络引导服务器...${NC}"
    
    # 安装必要软件
    apt update && apt install -y dnsmasq nginx wget
    
    # 创建目录结构
    mkdir -p /var/www/html/iso
    mkdir -p /var/lib/tftpboot
    
    # 配置nginx
    cat > /etc/nginx/sites-available/netboot <<'EOF'
server {
    listen 80;
    root /var/www/html;
    index index.html;
    
    location / {
        autoindex on;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/netboot /etc/nginx/sites-enabled/
    systemctl enable nginx
    systemctl restart nginx
    
    # 配置dnsmasq
    cat >> /etc/dnsmasq.conf <<'EOF'

# PXE Boot Configuration
dhcp-range=192.168.1.100,192.168.1.200,255.255.255.0,24h
dhcp-boot=undionly.kpxe
enable-tftp
tftp-root=/var/lib/tftpboot
EOF

    # 下载PXE文件
    cd /var/lib/tftpboot
    wget -O undionly.kpxe http://boot.netboot.xyz/ipxe/undionly.kpxe
    
    systemctl enable dnsmasq
    systemctl restart dnsmasq
    
    echo -e "${GREEN}网络引导服务器配置完成${NC}"
    echo -e "${YELLOW}服务器已启动，客户端可以通过PXE引导${NC}"
    read -p "按回车键继续..."
}

# 方法4: 使用现成的网络引导服务
premade_boot_services() {
    echo -e "${YELLOW}[4] 配置现成的网络引导服务...${NC}"
    
    apt update && apt install -y grub2-common
    
    # 添加多个网络引导选项
    cat >> /etc/grub.d/40_custom <<'EOF'

menuentry "netboot.xyz - Multi OS" {
    insmod chain
    insmod net
    insmod http
    chain http://boot.netboot.xyz/ipxe/netboot.xyz.lkrn
}

menuentry "Debian Network Install" {
    insmod chain
    insmod net
    insmod http
    chain http://deb.debian.org/debian/dists/stable/main/installer-amd64/current/images/netboot/netboot.tar.gz
}

menuentry "Ubuntu Network Install" {
    insmod chain
    insmod net
    insmod http
    chain http://archive.ubuntu.com/ubuntu/dists/focal/main/installer-amd64/current/legacy-images/netboot/ubuntu-installer/amd64/linux
}
EOF

    update-grub
    echo -e "${GREEN}现成网络引导服务配置完成${NC}"
    echo -e "${YELLOW}重启后可以选择多种网络安装选项${NC}"
    read -p "按回车键继续..."
}

# 方法5: 本地下载然后安装
local_download_install() {
    echo -e "${YELLOW}[5] 本地下载并安装系统...${NC}"
    
    # 更新系统并安装工具
    apt update && apt upgrade -y && apt install -y curl wget net-tools sudo
    
    # 选择要下载的ISO
    echo -e "${BLUE}请选择要下载的系统:${NC}"
    echo "1. Proxmox VE 8.4"
    echo "2. Debian 12"
    echo "3. Ubuntu 22.04 LTS"
    echo "4. 自定义ISO URL"
    read -p "请选择 (1-4): " iso_choice
    
    case $iso_choice in
        1)
            iso_url="https://download.proxmox.com/iso/proxmox-ve_8.4-1.iso"
            iso_name="proxmox-ve_8.4-1.iso"
            ;;
        2)
            iso_url="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.2.0-amd64-netinst.iso"
            iso_name="debian-12.2.0-amd64-netinst.iso"
            ;;
        3)
            iso_url="https://releases.ubuntu.com/22.04/ubuntu-22.04.3-live-server-amd64.iso"
            iso_name="ubuntu-22.04.3-live-server-amd64.iso"
            ;;
        4)
            read -p "请输入ISO文件的完整URL: " custom_url
            read -p "请输入保存的文件名: " custom_name
            iso_url="$custom_url"
            iso_name="$custom_name"
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return 1
            ;;
    esac
    
    # 下载ISO
    echo -e "${YELLOW}开始下载 $iso_name ...${NC}"
    cd /
    wget -O "$iso_name" "$iso_url"
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}下载完成${NC}"
        
        # 配置GRUB引导
        cat >> /etc/grub.d/40_custom <<EOF

menuentry "$iso_name Installer" {
    insmod ext2
    insmod iso9660
    set isofile="/$iso_name"
    search --no-floppy --set=root --file \$isofile
    loopback loop \$isofile
    linux (loop)/boot/vmlinuz boot=iso iso-scan/filename=\$isofile
    initrd (loop)/boot/initrd.img
}
EOF
        
        # 设置权限并更新GRUB
        chmod +x /etc/grub.d/40_custom
        update-grub
        
        echo -e "${GREEN}本地安装配置完成${NC}"
        echo -e "${YELLOW}重启后选择 '$iso_name Installer' 即可开始安装${NC}"
    else
        echo -e "${RED}下载失败，请检查网络连接和URL${NC}"
    fi
    
    read -p "按回车键继续..."
}

# 显示系统信息
show_system_info() {
    echo -e "${BLUE}系统信息:${NC}"
    echo "主机名: $(hostname)"
    echo "内核版本: $(uname -r)"
    echo "内存: $(free -h | awk '/^Mem:/ {print $2}')"
    echo "磁盘空间:"
    df -h / | tail -1
    echo ""
}

# 主程序
main() {
    check_root
    
    while true; do
        show_system_info
        show_menu
        
        read -p "请选择操作 (1-6): " choice
        
        case $choice in
            1)
                ventoy_netboot
                ;;
            2)
                ipxe_boot
                ;;
            3)
                network_boot_server
                ;;
            4)
                premade_boot_services
                ;;
            5)
                local_download_install
                ;;
            6)
                echo -e "${GREEN}再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                sleep 2
                ;;
        esac
    done
}

# 运行主程序
main "$@"
