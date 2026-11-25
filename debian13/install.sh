usermod -aG sudo vcore

# Настройка зеркала Debian 13
mkdir -p /etc/apt/sources.list.d

if [ -f /etc/apt/sources.list.d/debian.sources ]; then
    mv /etc/apt/sources.list.d/debian.sources \
       /etc/apt/sources.list.d/debian.sources.disabled
fi

cat << 'EOF' > /etc/apt/sources.list
deb https://mirror.truenetwork.ru/debian trixie main contrib non-free non-free-firmware
deb https://mirror.truenetwork.ru/debian trixie-updates main contrib non-free non-free-firmware
deb https://mirror.truenetwork.ru/debian-security trixie-security main contrib non-free non-free-firmware
EOF


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
    enp0s10:
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

if [[ "$XDG_CURRENT_DESKTOP" == *"GNOME"* ]]; then
    gsettings set org.gnome.desktop.input-sources sources "[(\x27xkb\x27, \x27us\x27), (\x27xkb\x27, \x27ru\x27)]"
    gsettings set org.gnome.desktop.input-sources xkb-options "[\x27grp:alt_shift_toggle\x27]"
elif [[ "$XDG_CURRENT_DESKTOP" == *"KDE"* ]]; then
    kwriteconfig6 --file kxkbrc --group Layout --key LayoutList "us,ru"
    kwriteconfig6 --file kxkbrc --group Layout --key Use true
    kwriteconfig6 --file kxkbrc --group Layout --key Options "grp:alt_shift_toggle"
    dbus-send --session --type=signal --reply-timeout=100 --dest=org.kde.keyboard /Layouts org.kde.keyboard.reloadConfig
elif [ -n "$DISPLAY" ] && command -v setxkbmap >/dev/null 2>&1; then
    setxkbmap -layout "us,ru" -option "grp:alt_shift_toggle"
else
    echo "Графическое окружение не определено или используется чистый Wayland (не GNOME/KDE)."
fi
