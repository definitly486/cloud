usermod -aG sudo vcore
apt update 
apt install jwm xorg git curl  firefox-esr-l10n-ru  l3afpad mc \
pcmanfm qemu-utils qemu-system-x86 jgmenu alacritty \
sudo  pipewire wireplumber pipewire-audio pasystray pavucontrol 

cat << 'EOF' > /home/vcore/.xinitrc
#!/bin/sh

exec jwm
EOF

chown vcore:vcore /home/vcore/.xinitrc
chmod +x /home/vcore/.xinitrc

cp /etc/jwm/system.jwmrc /home/vcore/.jwmrc
chown vcore:vcore /home/vcore/.jwmrc

cp jwmrc /home/vcore/.jwmrc
chown vcore:vcore /home/vcore/.jwmrc
