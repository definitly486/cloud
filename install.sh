usermod -aG sudo vcore

apt update

apt install -y jwm xorg git curl firefox-esr-l10n-ru l3afpad mc \
pcmanfm qemu-utils qemu-system-x86 jgmenu alacritty \
sudo pipewire wireplumber pipewire-audio pasystray pavucontrol \
arqiver screen libqt6webenginewidgets6 netplan.io

# Настройка сети
mkdir -p /etc/netplan

cat << 'EOF' > /etc/netplan/50-cloud-init.yaml
network:
  version: 2
  ethernets:
    enp0s1:
      dhcp4: true
      dhcp6: true
EOF

chmod 600 /etc/netplan/50-cloud-init.yaml

netplan generate
netplan apply

# Настройка JWM
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