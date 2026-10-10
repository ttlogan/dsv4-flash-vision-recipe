#!/bin/bash
echo "--- running kernel ---"; uname -r
echo "--- installed kernels ---"; ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||'
echo "--- dpkg holds on kernel/nvidia ---"; dpkg --get-selections 2>/dev/null | grep -i hold | grep -iE 'kernel|nvidia|linux-image' || echo "(no holds)"
echo "--- grub default ---"; grep -E '^GRUB_DEFAULT|^GRUB_SAVEDEFAULT' /etc/default/grub 2>/dev/null
echo "--- menu entries ---"; grep -E "menuentry '" /boot/grub/grub.cfg 2>/dev/null | sed 's/^[[:space:]]*//' | head
echo "--- auto-update services ---"
for s in dgx-dashboard-updater.service nvidia-dgx-updater.service apt-daily-upgrade.service; do printf "%s: " "$s"; systemctl is-active "$s" 2>/dev/null; done
echo "--- NVIDIA update advisory packages installed? ---"
apt-cache policy linux-image-virtual 2>/dev/null | head -3
