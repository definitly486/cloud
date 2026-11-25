#!/bin/sh

# Скрипт рассчитан на запуск от root по SSH.
# Ошибка отдельной команды не завершает скрипт и не закрывает SSH-сессию.
# Полный журнал: /var/log/vcore-setup.log

# Отсоединяемся от SSH только при обычном запуске.
# Повторный запуск внутри nohup не создаёт ещё один фоновый процесс.
if [ "${INSTALL_SH_BACKGROUND:-0}" != "1" ]; then
    INSTALL_SH_BACKGROUND=1
    export INSTALL_SH_BACKGROUND
    nohup sh "$0" "$@" </dev/null >/dev/null 2>&1 &
    echo "Настройка запущена в фоне. Журнал: /var/log/vcore-setup.log"
    exit 0
fi

LOG_FILE="/var/log/vcore-setup.log"
mkdir -p /var/log
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/vcore-setup.log"

log() {
    printf '%s %s\n' "$(date '+%F %T' 2>/dev/null)" "$*" | tee -a "$LOG_FILE"
}

run_plain() {
    description=$1
    shift

    log "НАЧАЛО: $description"
    # Сохраняем stdout и stderr КАЖДОЙ команды в общий журнал.
    # Статус команды читаем сразу после её завершения (без конвейера),
    # поэтому решение совместимо с POSIX sh.
    "$@" >>"$LOG_FILE" 2>&1
    result=$?

    if [ "$result" -eq 0 ]; then
        log "OK: $description"
    else
        log "ОШИБКА (код $result): $description — продолжаю выполнение"
    fi
    return 0
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Запусти скрипт от root: su -c './install.sh' или sudo ./install.sh"
    exit 1
fi

log "===== Начало настройки Debian ====="

# Добавление пользователя в sudo.
if id vcore >/dev/null 2>&1; then
    run_plain "Добавление vcore в группу sudo" usermod -aG sudo vcore
else
    log "ПРЕДУПРЕЖДЕНИЕ: пользователь vcore не найден; пропускаю usermod"
fi

# Настройка зеркала Debian 13.
run_plain "Создание каталога sources.list.d" mkdir -p /etc/apt/sources.list.d

if [ -f /etc/apt/sources.list.d/debian.sources ]; then
    run_plain "Отключение debian.sources" \
        mv /etc/apt/sources.list.d/debian.sources \
           /etc/apt/sources.list.d/debian.sources.disabled
fi

if cat > /etc/apt/sources.list <<'EOF'
deb https://mirror.truenetwork.ru/debian trixie main contrib non-free non-free-firmware
deb https://mirror.truenetwork.ru/debian trixie-updates main contrib non-free non-free-firmware
deb https://mirror.truenetwork.ru/debian-security trixie-security main contrib non-free non-free-firmware
EOF
then
    log "OK: записан /etc/apt/sources.list"
else
    log "ОШИБКА: не удалось записать /etc/apt/sources.list"
fi

# Ограничиваем время ожидания apt, чтобы процесс не зависал бесконечно.
if command -v timeout >/dev/null 2>&1; then
    run_plain "Обновление индексов apt (лимит 10 минут)" \
        timeout 600 apt-get -o Acquire::Retries=2 update

    run_plain "Установка графических и сетевых пакетов (лимит 30 минут)" \
        timeout 1800 env DEBIAN_FRONTEND=noninteractive apt-get \
        -o Dpkg::Options::=--force-confold install -y \
        jwm xorg git curl firefox-esr-l10n-ru l3afpad mc \
        pcmanfm qemu-utils qemu-system-x86 jgmenu alacritty \
        sudo pipewire wireplumber pipewire-audio pasystray pavucontrol \
        arqiver screen libqt6webenginewidgets6 netplan.io
else
    log "ПРЕДУПРЕЖДЕНИЕ: timeout не найден; apt запускается без ограничения времени"
    run_plain "Обновление индексов apt" apt-get -o Acquire::Retries=2 update
    run_plain "Установка пакетов" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        jwm xorg git curl firefox-esr-l10n-ru l3afpad mc \
        pcmanfm qemu-utils qemu-system-x86 jgmenu alacritty \
        sudo pipewire wireplumber pipewire-audio pasystray pavucontrol \
        arqiver screen libqt6webenginewidgets6 netplan.io
fi

# Настройка сети.
run_plain "Создание каталога netplan" mkdir -p /etc/netplan

# В этой VM сетевой интерфейс называется enp0s1.
# Проверь имя командой: ip -br link
if cat > /etc/netplan/50-cloud-init.yaml <<'EOF'
network:
  version: 2
  ethernets:
    enp0s10:
      dhcp4: true
      dhcp6: true
EOF
then
    log "OK: записан /etc/netplan/50-cloud-init.yaml"
else
    log "ОШИБКА: не удалось записать конфигурацию netplan"
fi

run_plain "Установка прав netplan-конфигурации" chmod 600 /etc/netplan/50-cloud-init.yaml

if command -v timeout >/dev/null 2>&1; then
    run_plain "Проверка конфигурации netplan" timeout 30 netplan generate
else
    run_plain "Проверка конфигурации netplan" netplan generate
fi

# ВАЖНО: netplan apply здесь намеренно НЕ запускается.
# При запуске через SSH он может изменить сетевой интерфейс/маршрут
# и оборвать SSH. Применить сеть безопаснее отдельно после проверки
# интерфейса и наличия доступа к консоли VM.

# Настройка JWM.
if [ -d /home/vcore ]; then
    if cat > /home/vcore/.xinitrc <<'EOF'
#!/bin/sh
exec jwm
EOF
    then
        run_plain "Назначение владельца .xinitrc" chown vcore:vcore /home/vcore/.xinitrc
        run_plain "Установка прав .xinitrc" chmod +x /home/vcore/.xinitrc
    else
        log "ОШИБКА: не удалось создать /home/vcore/.xinitrc"
    fi

    if [ -f /etc/jwm/system.jwmrc ]; then
        run_plain "Копирование системного JWM-конфига" cp /etc/jwm/system.jwmrc /home/vcore/.jwmrc
    else
        log "ПРЕДУПРЕЖДЕНИЕ: /etc/jwm/system.jwmrc не найден"
    fi

    # Пользовательский jwmrc копируем только если файл действительно существует.
    if [ -f ./jwmrc ]; then
        run_plain "Копирование пользовательского jwmrc" cp ./jwmrc /home/vcore/.jwmrc
    else
        log "ПРЕДУПРЕЖДЕНИЕ: файл ./jwmrc не найден; оставляю системный конфиг"
    fi

    run_plain "Назначение владельца .jwmrc" chown vcore:vcore /home/vcore/.jwmrc
else
    log "ПРЕДУПРЕЖДЕНИЕ: /home/vcore не найден; пропускаю настройку JWM"
fi

# Настройка раскладки выполняется только при наличии соответствующей
# графической пользовательской сессии. Из обычного SSH DISPLAY обычно пуст.
case "${XDG_CURRENT_DESKTOP:-}" in
    *GNOME*)
        if command -v gsettings >/dev/null 2>&1; then
            run_plain "Настройка раскладки GNOME" \
                gsettings set org.gnome.desktop.input-sources sources \
                "[('xkb', 'us'), ('xkb', 'ru')]"
            run_plain "Настройка переключения GNOME" \
                gsettings set org.gnome.desktop.input-sources xkb-options \
                "['grp:alt_shift_toggle']"
        else
            log "ПРЕДУПРЕЖДЕНИЕ: gsettings не найден"
        fi
        ;;
    *KDE*)
        if command -v kwriteconfig6 >/dev/null 2>&1; then
            run_plain "Настройка раскладки KDE" \
                kwriteconfig6 --file kxkbrc --group Layout --key LayoutList "us,ru"
            run_plain "Включение раскладки KDE" \
                kwriteconfig6 --file kxkbrc --group Layout --key Use true
            run_plain "Настройка переключения KDE" \
                kwriteconfig6 --file kxkbrc --group Layout --key Options "grp:alt_shift_toggle"
        else
            log "ПРЕДУПРЕЖДЕНИЕ: kwriteconfig6 не найден"
        fi
        ;;
    *)
        if [ -n "${DISPLAY:-}" ] && command -v setxkbmap >/dev/null 2>&1; then
            run_plain "Настройка раскладки X11" \
                setxkbmap -layout "us,ru" -option "grp:alt_shift_toggle"
        else
            log "Пропуск раскладки: скрипт запущен без графической сессии"
        fi
        ;;
esac

log "===== Настройка завершена. Проверь сообщения ОШИБКА/ПРЕДУПРЕЖДЕНИЕ выше. ====="
log "Журнал сохранён: $LOG_FILE"
exit 0
