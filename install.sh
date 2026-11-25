usermod -aG sudo vcore
apt update 
apt install jwm xorg git curl  firefox-esr-l10n-ru  l3afpad mc pcmanfm qemu-utils qemu-system-x86 jgmenu alacritty

cat << 'EOF' > /home/vcore/.xinitrc
#!/bin/sh

exec jwm
EOF

chown vcore:vcore /home/vcore/.xinitrc
chmod +x /home/vcore/.xinitrc