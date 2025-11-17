# 更新系统并安装工具
apt update && apt upgrade -y && apt install -y curl wget net-tools sudo

# 下载ISO到根目录
cd /
wget https://enterprise.proxmox.com/iso/proxmox-ve_8.4-1.iso

# 写入正确的GRUB配置
cat > /etc/grub.d/40_custom <<'EOF'
menuentry "Proxmox VE Installer" {
    insmod ext2
    insmod iso9660
    set isofile="/proxmox-ve_8.4-1.iso"
    search --no-floppy --set=root --file $isofile
    loopback loop $isofile
    linux (loop)/boot/vmlinuz boot=iso iso-scan/filename=$isofile
    initrd (loop)/boot/initrd.img
}
EOF

# 设置权限并更新GRUB
chmod +x /etc/grub.d/40_custom
update-grub

# 重启提示
echo "重启后请在GRUB菜单中选择 'Proxmox VE Installer'"
