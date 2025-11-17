#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 语言变量
LANG="en"
declare -A TEXT

# 英文文本
TEXT["en_title"]="Network Boot Installation Tool"
TEXT["en_menu_1"]="1. Use Ventoy Network Edition"
TEXT["en_menu_2"]="2. Use iPXE (Recommended)"
TEXT["en_menu_3"]="3. Use Network Boot Server"
TEXT["en_menu_4"]="4. Use Pre-made Network Boot Services"
TEXT["en_menu_5"]="5. Local Download and Install"
TEXT["en_menu_6"]="6. Language Settings"
TEXT["en_menu_7"]="7. Exit"
TEXT["en_system_info"]="System Information"
TEXT["en_hostname"]="Hostname"
TEXT["en_kernel"]="Kernel Version"
TEXT["en_memory"]="Memory"
TEXT["en_disk"]="Disk Space"
TEXT["en_choose_option"]="Please select an option (1-7)"
TEXT["en_invalid_choice"]="Invalid selection, please try again"
TEXT["en_goodbye"]="Goodbye!"
TEXT["en_press_enter"]="Press Enter to continue..."
TEXT["en_root_required"]="Error: This script requires root privileges"
TEXT["en_lang_menu"]="Language Settings"
TEXT["en_lang_1"]="1. English"
TEXT["en_lang_2"]="2. 中文 (Chinese)"
TEXT["en_lang_choose"]="Please select language (1-2)"
TEXT["en_lang_changed"]="Language changed to English"
TEXT["en_iso_menu"]="Please select the system to download:"
TEXT["en_iso_1"]="1. Proxmox VE 8.4"
TEXT["en_iso_2"]="2. Proxmox VE 9.0"
TEXT["en_iso_3"]="3. Debian 12.12.0"
TEXT["en_iso_4"]="4. Custom ISO URL"

# 中文文本
TEXT["zh_title"]="网络引导安装工具"
TEXT["zh_menu_1"]="1. 使用Ventoy网络版"
TEXT["zh_menu_2"]="2. 使用iPXE (推荐方案)"
TEXT["zh_menu_3"]="3. 使用网络引导服务器"
TEXT["zh_menu_4"]="4. 使用现成的网络引导服务"
TEXT["zh_menu_5"]="5. 本地下载然后安装"
TEXT["zh_menu_6"]="6. 语言设置"
TEXT["zh_menu_7"]="7. 退出"
TEXT["zh_system_info"]="系统信息"
TEXT["zh_hostname"]="主机名"
TEXT["zh_kernel"]="内核版本"
TEXT["zh_memory"]="内存"
TEXT["zh_disk"]="磁盘空间"
TEXT["zh_choose_option"]="请选择操作 (1-7)"
TEXT["zh_invalid_choice"]="无效选择，请重新输入"
TEXT["zh_goodbye"]="再见！"
TEXT["zh_press_enter"]="按回车键继续..."
TEXT["zh_root_required"]="错误: 此脚本需要root权限运行"
TEXT["zh_lang_menu"]="语言设置"
TEXT["zh_lang_1"]="1. English (英语)"
TEXT["zh_lang_2"]="2. 中文 (Chinese)"
TEXT["zh_lang_choose"]="请选择语言 (1-2)"
TEXT["zh_lang_changed"]="语言已切换为中文"
TEXT["zh_iso_menu"]="请选择要下载的系统:"
TEXT["zh_iso_1"]="1. Proxmox VE 8.4"
TEXT["zh_iso_2"]="2. Proxmox VE 9.0"
TEXT["zh_iso_3"]="3. Debian 12.12.0"
TEXT["zh_iso_4"]="4. 自定义ISO URL"

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}${TEXT[${LANG}_root_required]}${NC}"
        exit 1
    fi
}

# 显示语言菜单
language_menu() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════╗"
    echo "║          ${TEXT[${LANG}_lang_menu]}           ║"
    echo "╠══════════════════════════════════════╣"
    echo "║ ${TEXT[${LANG}_lang_1]}                  ║"
    echo "║ ${TEXT[${LANG}_lang_2]}        ║"
    echo "╚══════════════════════════════════════╝"
    echo -e "${NC}"
    
    read -p "${TEXT[${LANG}_lang_choose]}: " lang_choice
    
    case $lang_choice in
        1)
            LANG="en"
            echo -e "${GREEN}${TEXT[${LANG}_lang_changed]}${NC}"
            ;;
        2)
            LANG="zh"
            echo -e "${GREEN}${TEXT[${LANG}_lang_changed]}${NC}"
            ;;
        *)
            echo -e "${RED}${TEXT[${LANG}_invalid_choice]}${NC}"
            sleep 2
            ;;
    esac
}

# 显示主菜单
show_menu() {
    clear
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════╗"
    echo "║          ${TEXT[${LANG}_title]}          ║"
    echo "╠══════════════════════════════════════╣"
    echo "║ ${TEXT[${LANG}_menu_1]}                  ║"
    echo "║ ${TEXT[${LANG}_menu_2]}                  ║"
    echo "║ ${TEXT[${LANG}_menu_3]}                 ║"
    echo "║ ${TEXT[${LANG}_menu_4]}   ║"
    echo "║ ${TEXT[${LANG}_menu_5]}               ║"
    echo "║ ${TEXT[${LANG}_menu_6]}                     ║"
    echo "║ ${TEXT[${LANG}_menu_7]}                             ║"
    echo "╚══════════════════════════════════════╝"
    echo -e "${NC}"
}

# 显示系统信息
show_system_info() {
    echo -e "${CYAN}${TEXT[${LANG}_system_info]}:${NC}"
    
    if [ "$LANG" = "en" ]; then
        echo "${TEXT[${LANG}_hostname]}: $(hostname)"
        echo "${TEXT[${LANG}_kernel]}: $(uname -r)"
        echo "${TEXT[${LANG}_memory]}: $(free -h | awk '/^Mem:/ {print $2}')"
        echo "${TEXT[${LANG}_disk]}:"
    else
        echo "${TEXT[${LANG}_hostname]}: $(hostname)"
        echo "${TEXT[${LANG}_kernel]}: $(uname -r)"
        echo "${TEXT[${LANG}_memory]}: $(free -h | awk '/^Mem:/ {print $2}')"
        echo "${TEXT[${LANG}_disk]}:"
    fi
    
    df -h / | tail -1
    echo ""
}

# 方法1: 使用Ventoy网络版
ventoy_netboot() {
    if [ "$LANG" = "en" ]; then
        echo -e "${YELLOW}[1] Configuring Ventoy Network Boot...${NC}"
    else
        echo -e "${YELLOW}[1] 配置Ventoy网络引导...${NC}"
    fi
    
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
    
    if [ "$LANG" = "en" ]; then
        echo -e "${GREEN}Ventoy network boot configuration completed${NC}"
        echo -e "${YELLOW}Select 'Ventoy Network Boot' after reboot to use${NC}"
    else
        echo -e "${GREEN}Ventoy网络引导配置完成${NC}"
        echo -e "${YELLOW}重启后选择 'Ventoy Network Boot' 即可使用${NC}"
    fi
    
    read -p "${TEXT[${LANG}_press_enter]}"
}

# 方法2: 使用iPXE
ipxe_boot() {
    if [ "$LANG" = "en" ]; then
        echo -e "${YELLOW}[2] Configuring iPXE Network Boot...${NC}"
    else
        echo -e "${YELLOW}[2] 配置iPXE网络引导...${NC}"
    fi
    
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
    
    if [ "$LANG" = "en" ]; then
        echo -e "${GREEN}iPXE boot configuration completed${NC}"
        echo -e "${YELLOW}Select 'iPXE Boot Menu' after reboot to use netboot.xyz${NC}"
    else
        echo -e "${GREEN}iPXE引导配置完成${NC}"
        echo -e "${YELLOW}重启后选择 'iPXE Boot Menu' 即可使用netboot.xyz${NC}"
    fi
    
    read -p "${TEXT[${LANG}_press_enter]}"
}

# 方法3: 使用网络引导服务器
network_boot_server() {
    if [ "$LANG" = "en" ]; then
        echo -e "${YELLOW}[3] Setting up Network Boot Server...${NC}"
    else
        echo -e "${YELLOW}[3] 设置网络引导服务器...${NC}"
    fi
    
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
    
    if [ "$LANG" = "en" ]; then
        echo -e "${GREEN}Network boot server configuration completed${NC}"
        echo -e "${YELLOW}Server started, clients can boot via PXE${NC}"
    else
        echo -e "${GREEN}网络引导服务器配置完成${NC}"
        echo -e "${YELLOW}服务器已启动，客户端可以通过PXE引导${NC}"
    fi
    
    read -p "${TEXT[${LANG}_press_enter]}"
}

# 方法4: 使用现成的网络引导服务
premade_boot_services() {
    if [ "$LANG" = "en" ]; then
        echo -e "${YELLOW}[4] Configuring Pre-made Network Boot Services...${NC}"
    else
        echo -e "${YELLOW}[4] 配置现成的网络引导服务...${NC}"
    fi
    
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
    
    if [ "$LANG" = "en" ]; then
        echo -e "${GREEN}Pre-made network boot services configuration completed${NC}"
        echo -e "${YELLOW}Multiple network installation options available after reboot${NC}"
    else
        echo -e "${GREEN}现成网络引导服务配置完成${NC}"
        echo -e "${YELLOW}重启后可以选择多种网络安装选项${NC}"
    fi
    
    read -p "${TEXT[${LANG}_press_enter]}"
}

# 方法5: 本地下载然后安装
local_download_install() {
    if [ "$LANG" = "en" ]; then
        echo -e "${YELLOW}[5] Local Download and System Installation...${NC}"
    else
        echo -e "${YELLOW}[5] 本地下载并安装系统...${NC}"
    fi
    
    # 更新系统并安装工具
    apt update && apt upgrade -y && apt install -y curl wget net-tools sudo
    
    # 选择要下载的ISO
    echo -e "${BLUE}${TEXT[${LANG}_iso_menu]}${NC}"
    echo "${TEXT[${LANG}_iso_1]}"
    echo "${TEXT[${LANG}_iso_2]}"
    echo "${TEXT[${LANG}_iso_3]}"
    echo "${TEXT[${LANG}_iso_4]}"
    
    if [ "$LANG" = "en" ]; then
        read -p "Please select (1-4): " iso_choice
    else
        read -p "请选择 (1-4): " iso_choice
    fi
    
    case $iso_choice in
        1)
            iso_url="https://enterprise.proxmox.com/iso/proxmox-ve_8.4-1.iso"
            iso_name="proxmox-ve_8.4-1.iso"
            ;;
        2)
            iso_url="https://enterprise.proxmox.com/iso/proxmox-ve_9.0-1.iso"
            iso_name="proxmox-ve_9.0-1.iso"
            ;;
        3)
            iso_url="https://cdimage.debian.org/mirror/cdimage/archive/12.12.0/amd64/iso-cd/debian-12.12.0-amd64-netinst.iso"
            iso_name="debian-12.12.0-amd64-netinst.iso"
            ;;
        4)
            if [ "$LANG" = "en" ]; then
                read -p "Please enter the complete ISO file URL: " custom_url
                read -p "Please enter the filename to save as: " custom_name
            else
                read -p "请输入ISO文件的完整URL: " custom_url
                read -p "请输入保存的文件名: " custom_name
            fi
            iso_url="$custom_url"
            iso_name="$custom_name"
            ;;
        *)
            echo -e "${RED}${TEXT[${LANG}_invalid_choice]}${NC}"
            return 1
            ;;
    esac
    
    # 下载ISO
    if [ "$LANG" = "en" ]; then
        echo -e "${YELLOW}Starting download of $iso_name ...${NC}"
    else
        echo -e "${YELLOW}开始下载 $iso_name ...${NC}"
    fi
    
    cd /
    wget -O "$iso_name" "$iso_url"
    
    if [[ $? -eq 0 ]]; then
        if [ "$LANG" = "en" ]; then
            echo -e "${GREEN}Download completed${NC}"
        else
            echo -e "${GREEN}下载完成${NC}"
        fi
        
        # 配置GRUB引导
        cat >> /etc/grub.d/40_custom <<EOF

menuentry "$iso_name Installer" {
    insmod ext2
    insmod iso9660
    set isofile="/$iso_name"
    search --no-floppy --set=root --file \$isofile
    loopback loop \$isofile
    
    # 根据ISO类型选择正确的内核和initrd路径
    if [ -f (loop)/boot/vmlinuz ]; then
        linux (loop)/boot/vmlinuz boot=iso iso-scan/filename=\$isofile
        initrd (loop)/boot/initrd.img
    else
        # 尝试Proxmox VE的路径
        linux (loop)/proxmox/vmlinuz boot=iso iso-scan/filename=\$isofile
        initrd (loop)/proxmox/initrd.img
    fi
}
EOF
        
        # 设置权限并更新GRUB
        chmod +x /etc/grub.d/40_custom
        update-grub
        
        if [ "$LANG" = "en" ]; then
            echo -e "${GREEN}Local installation configuration completed${NC}"
            echo -e "${YELLOW}Select '$iso_name Installer' after reboot to begin installation${NC}"
            echo -e "${YELLOW}Note: Proxmox VE enterprise ISOs may require a valid subscription${NC}"
        else
            echo -e "${GREEN}本地安装配置完成${NC}"
            echo -e "${YELLOW}重启后选择 '$iso_name Installer' 即可开始安装${NC}"
            echo -e "${YELLOW}注意: Proxmox VE 企业版ISO可能需要有效的订阅${NC}"
        fi
    else
        if [ "$LANG" = "en" ]; then
            echo -e "${RED}Download failed, please check network connection and URL${NC}"
        else
            echo -e "${RED}下载失败，请检查网络连接和URL${NC}"
        fi
    fi
    
    read -p "${TEXT[${LANG}_press_enter]}"
}

# 主程序
main() {
    check_root
    
    # 初始语言选择
    language_menu
    
    while true; do
        show_system_info
        show_menu
        
        read -p "${TEXT[${LANG}_choose_option]}: " choice
        
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
                language_menu
                ;;
            7)
                echo -e "${GREEN}${TEXT[${LANG}_goodbye]}${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}${TEXT[${LANG}_invalid_choice]}${NC}"
                sleep 2
                ;;
        esac
    done
}

# 运行主程序
main "$@"
