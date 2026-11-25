#!/usr/bin/env bash
set -Eeuo pipefail

LOGIN_USER="vcore"
NET_IFACE="eth0"
MIRROR="https://mirror.truenetwork.ru/archlinux"

if [[ $EUID -ne 0 ]]; then
    echo "Запусти скрипт от root."
    exit 1
fi

if ! id "$LOGIN_USER" >/dev/null 2>&1; then
    echo "Пользователь $LOGIN_USER не существует."
    exit 1
fi

echo "===== Настройка групп пользователя ====="

# В Arch Linux используется группа wheel вместо sudo
usermod -aG wheel,audio,video,storage "$LOGIN_USER"

echo "===== Настройка российского зеркала Arch Linux ====="

cp -a /etc/pacman.d/mirrorlist \
    /etc/pacman.d/mirrorlist.backup 2>/dev/null || true

cat > /etc/pacman.d/mirrorlist <<EOF
Server = ${MIRROR}/\$repo/os/\$arch
EOF

pacman -Syy

echo "===== Настройка sudo ====="

mkdir -p /etc/sudoers.d

cat > /etc/sudoers.d/10-wheel <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF

chmod 440 /etc/sudoers.d/10-wheel
visudo -cf /etc/sudoers

echo "===== Обновление системы ====="

pacman -Syu --noconfirm

echo "===== Установка программ ====="

pacman -S --needed --noconfirm \
    jwm \
    xorg-server \
    xorg-xinit \
    xorg-xrandr \
    xorg-xsetroot \
    xorg-setxkbmap \
    git \
    curl \
    firefox \
    firefox-i18n-ru \
    mousepad \
    mc \
    pcmanfm \
    qemu-system-x86 \
    qemu-img \
    jgmenu \
    alacritty \
    sudo \
    pipewire \
    wireplumber \
    pipewire-pulse \
    pasystray \
    pavucontrol \
    xarchiver \
    screen \
    qt6-webengine \
    wget		

echo "===== Настройка сети ====="

# Определяем сетевой интерфейс
NET_IFACE=$(ip -o link show | awk -F': ' '
    $2 != "lo" {
        sub(/@.*/, "", $2)
        print $2
        exit
    }
')

if [ -z "$NET_IFACE" ]; then
    echo "ОШИБКА: сетевой интерфейс не найден!"
    exit 1
fi

echo "Найден интерфейс: $NET_IFACE"

# Создаём конфигурацию
mkdir -p /etc/systemd/network

cat > /etc/systemd/network/20-wired.network <<EOF
[Match]
Name=$NET_IFACE

[Network]
DHCP=yes
IPv6AcceptRA=yes
EOF

# Включаем сетевые службы
systemctl enable systemd-networkd
systemctl enable systemd-resolved

# Настраиваем DNS
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Запускаем службы
systemctl restart systemd-resolved
systemctl restart systemd-networkd

# Ожидаем получения IP
sleep 5

echo "===== Проверка сети ====="
ip -br address
ip route

echo "===== Настройка JWM ====="

USER_HOME="$(getent passwd "$LOGIN_USER" | cut -d: -f6)"

mkdir -p "$USER_HOME"

cat > "$USER_HOME/.xinitrc" <<'EOF'
#!/bin/sh

setxkbmap -layout "us,ru" -option "grp:alt_shift_toggle"

exec jwm
EOF

chmod +x "$USER_HOME/.xinitrc"

# Используем пользовательский jwmrc, если он находится
# в текущем каталоге скрипта.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/jwmrc" ]]; then
    cp "$SCRIPT_DIR/jwmrc" "$USER_HOME/.jwmrc"
elif [[ -f /etc/jwm/system.jwmrc ]]; then
    cp /etc/jwm/system.jwmrc "$USER_HOME/.jwmrc"
elif [[ -f /etc/system.jwmrc ]]; then
    cp /etc/system.jwmrc "$USER_HOME/.jwmrc"
else
    echo "Системный jwmrc не найден. JWM будет использовать настройки по умолчанию."
fi

chown -R "$LOGIN_USER:$LOGIN_USER" "$USER_HOME"

echo "===== Настройка завершена ====="
echo "Пользователь: $LOGIN_USER"
echo "Сеть: $NET_IFACE (DHCP)"
echo "Зеркало: $MIRROR"
echo
echo "Перезагрузи систему:"
echo "reboot"
echo
echo "После входа в систему запускай графическую оболочку командой:"
echo "startx"