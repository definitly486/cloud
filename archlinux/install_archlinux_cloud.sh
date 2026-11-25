#!/bin/sh
#
# Arch Linux Cloud VM for FreeBSD bhyve
# Usage: doas ./install_archlinux_jwm.sh create|start|stop|restart|status
#
# Uses the official Arch Linux arch-boxes cloud image (cloud-init preinstalled).
# Existing image and disk files are reused; the image is SHA256-verified.
#

set -eu

VM_NAME="archlinux-jwm"
VM_DIR="/media/vm/archlinux-jwm"
VCPUS="2"
MEMORY="2G"
DISK_SIZE="20G"
BRIDGE="bridge0"
TAP="tap11"
LOGIN_USER="vcore"

BASE_URL="https://mirror.truenetwork.ru/archlinux/images/latest"
IMAGE_NAME="Arch-Linux-x86_64-cloudimg.qcow2"
IMAGE_FILE="$VM_DIR/$IMAGE_NAME"
MANIFEST="$VM_DIR/$IMAGE_NAME.SHA256"
DISK_FILE="$VM_DIR/archlinux-jwm.img"
SEED_ISO="$VM_DIR/cloud-init.iso"
USER_DATA="$VM_DIR/user-data"
META_DATA="$VM_DIR/meta-data"
NETWORK_CONFIG="$VM_DIR/network-config"
HOME_FILES_YAML="$VM_DIR/home-files-cloud-init.yml"
HOME_FILES_LIST="$VM_DIR/home-files-list.txt"

UEFI_CODE="/usr/local/share/uefi-firmware/BHYVE_UEFI.fd"
UEFI_VARS_TEMPLATE="/usr/local/share/uefi-firmware/BHYVE_UEFI_VARS.fd"
UEFI_VARS="$VM_DIR/BHYVE_UEFI_VARS.fd"

PIDFILE="$VM_DIR/bhyve.pid"
LOGFILE="$VM_DIR/bhyve.log"

# Packages corresponding to the Debian desktop setup.
# mousepad replaces l3afpad; file-roller replaces arqiver.
PACKAGES="
jwm
xorg-server
xorg-xinit
xorg-xrandr
xorg-xsetroot
git
curl
firefox
firefox-i18n-ru
mousepad
mc
pcmanfm
qemu-system-x86
qemu-img
jgmenu
alacritty
sudo
openssh
pipewire
wireplumber
pipewire-audio
pasystray
pavucontrol
file-roller
screen
qt6-webengine
"

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

need_root()
{
    [ "$(id -u)" -eq 0 ] || die "Run as root: doas $0 $*"
}

need_command()
{
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

check_tools()
{
    for cmd in fetch sha256 awk qemu-img mkisofs openssl ifconfig bhyve bhyvectl daemon; do
        need_command "$cmd"
    done

    [ -r "$UEFI_CODE" ] || die "UEFI firmware not found: $UEFI_CODE"
    [ -r "$UEFI_VARS_TEMPLATE" ] || die "UEFI vars template not found: $UEFI_VARS_TEMPLATE"
}

expected_hash()
{
    awk 'NR == 1 { print $1; exit }' "$MANIFEST"
}

refresh_manifest()
{
    local_tmp="$MANIFEST.download"
    echo "Updating Arch Linux SHA256 manifest..."
    fetch -o "$local_tmp" "$BASE_URL/$IMAGE_NAME.SHA256" ||
        die "Cannot download Arch Linux SHA256 manifest"

    hash="$(awk 'NR == 1 { print $1; exit }' "$local_tmp")"
    case "$hash" in
        ''|*[!0-9a-fA-F]*)
            die "Invalid SHA256 manifest: $local_tmp"
            ;;
    esac
    [ "${#hash}" -eq 64 ] || die "Unexpected SHA256 length in manifest"

    mv -f "$local_tmp" "$MANIFEST"
}

verify_image()
{
    expected="$(expected_hash)"
    [ -n "$expected" ] || die "No SHA256 entry for $IMAGE_NAME"

    actual="$(sha256 -q "$IMAGE_FILE")"
    if [ "$actual" != "$expected" ]; then
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        die "SHA256 verification failed for $IMAGE_FILE. Image was not deleted or replaced."
    fi

    echo "SHA256 verification passed."
}

download_image_if_missing()
{
    if [ -s "$IMAGE_FILE" ]; then
        echo "Reusing existing image: $IMAGE_FILE"
        return
    fi

    echo "Downloading official Arch Linux cloud image..."
    tmp_image="$IMAGE_FILE.download"
    rm -f "$tmp_image"

    fetch -o "$tmp_image" "$BASE_URL/$IMAGE_NAME" ||
        die "Arch Linux cloud image download failed"

    expected="$(expected_hash)"
    actual="$(sha256 -q "$tmp_image")"

    if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
        rm -f "$tmp_image"
        die "Downloaded image failed SHA256 verification; temporary file removed"
    fi

    mv "$tmp_image" "$IMAGE_FILE"
    echo "Arch Linux cloud image downloaded and verified."
}

prepare_disk()
{
    if [ ! -s "$DISK_FILE" ]; then
        echo "Converting QCOW2 image to raw disk..."
        qemu-img convert -p -f qcow2 -O raw "$IMAGE_FILE" "$DISK_FILE"
    else
        echo "Reusing existing disk: $DISK_FILE"
    fi

    echo "Ensuring virtual disk size is $DISK_SIZE..."
    qemu-img resize "$DISK_FILE" "$DISK_SIZE"
}

prepare_uefi()
{
    if [ ! -s "$UEFI_VARS" ]; then
        echo "Creating VM-specific UEFI variables..."
        cp "$UEFI_VARS_TEMPLATE" "$UEFI_VARS"
    else
        echo "Reusing UEFI variables: $UEFI_VARS"
    fi
}

select_home_files()
{
    : > "$HOME_FILES_YAML"
    printf "\nПапка с файлами на FreeBSD (Enter — пропустить): "
    IFS= read -r source_dir

    [ -n "$source_dir" ] || {
        echo "Копирование дополнительных файлов пропущено."
        return
    }

    [ -d "$source_dir" ] || die "Directory not found: $source_dir"

    find "$source_dir" -type f -print | sort > "$HOME_FILES_LIST"
    [ -s "$HOME_FILES_LIST" ] || {
        echo "В папке нет файлов."
        return
    }

    printf '\nДоступные файлы:\n'
    number=1
    while IFS= read -r file; do
        relative_path=${file#"$source_dir"/}
        printf "  %3s) %s\n" "$number" "$relative_path"
        number=$((number + 1))
    done < "$HOME_FILES_LIST"

    printf "\nВведите номера через пробел (например: 1 3 5), all — все, Enter — пропустить: "
    IFS= read -r selection

    [ -n "$selection" ] || { echo "Выбор файлов пропущен."; return; }

    if [ "$selection" = "all" ] || [ "$selection" = "ALL" ]; then
        selected_numbers=""
        number=1
        while IFS= read -r file; do
            selected_numbers="$selected_numbers $number"
            number=$((number + 1))
        done < "$HOME_FILES_LIST"
    else
        selected_numbers=$(printf "%s\n" "$selection" | tr "," " ")
    fi

    for number in $selected_numbers; do
        case "$number" in
            ''|*[!0-9]*) die "Invalid file number: $number" ;;
        esac
        [ "$number" -gt 0 ] || die "Invalid file number: $number"

        file=$(sed -n "${number}p" "$HOME_FILES_LIST")
        [ -n "$file" ] || die "File number does not exist: $number"
        relative_path=${file#"$source_dir"/}
        destination="/home/$LOGIN_USER/$relative_path"
        yaml_path=$(printf '%s' "$destination" | sed 's/\\/\\\\/g; s/"/\\"/g')

        printf '  - path: "%s"\n' "$yaml_path" >> "$HOME_FILES_YAML"
        printf "    owner: %s:%s\n" "$LOGIN_USER" "$LOGIN_USER" >> "$HOME_FILES_YAML"
        printf "    permissions: '0644'\n" >> "$HOME_FILES_YAML"
        printf "    encoding: b64\n" >> "$HOME_FILES_YAML"
        printf "    content: |\n" >> "$HOME_FILES_YAML"
        base64 < "$file" | sed "s/^/      /" >> "$HOME_FILES_YAML"
        printf "\n" >> "$HOME_FILES_YAML"
        echo "Добавлен: $relative_path -> $destination"
    done
}
make_cloud_init()
{
    # Fixed login credentials for the VM.
    VM_PASSWORD="639639"
    PASSWORD_HASH="$(printf '%s' "$VM_PASSWORD" | openssl passwd -6 -stdin)"
    unset VM_PASSWORD

    printf "SSH public key (leave empty to skip): "
    IFS= read -r SSH_KEY

    select_home_files

    cat > "$USER_DATA" <<EOF
#cloud-config
hostname: $VM_NAME
manage_etc_hosts: true

output:
  all: "| tee -a /var/log/cloud-init-output.log"

users:
  - default
  - name: $LOGIN_USER
    gecos: Arch Linux User
    groups: [wheel, audio, video, storage, optical, input]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: '$PASSWORD_HASH'
EOF

    if [ -n "$SSH_KEY" ]; then
        cat >> "$USER_DATA" <<EOF
    ssh_authorized_keys:
      - $SSH_KEY
EOF
    fi

    cat >> "$USER_DATA" <<'EOF'
chpasswd:
  expire: false
ssh_pwauth: true

write_files:
  - path: /etc/ssh/sshd_config.d/10-vcore-password.conf
    owner: root:root
    permissions: '0600'
    content: |
      PasswordAuthentication yes
      KbdInteractiveAuthentication yes

EOF

    if [ -s "$HOME_FILES_YAML" ]; then
        cat "$HOME_FILES_YAML" >> "$USER_DATA"
    fi

    cat >> "$USER_DATA" <<'EOF'
runcmd:
  # Configure the login account and sudo before package operations.
  # A pacman/network failure must not leave vcore without administrative access.
  - |
    set -eu
    if ! id vcore >/dev/null 2>&1; then
      useradd --create-home --shell /bin/bash vcore
    fi
    usermod -aG wheel,audio,video,storage,optical,input vcore
    printf '%s\n' 'vcore:639639' | chpasswd
    usermod -U vcore
    install -d -m 0750 /etc/sudoers.d
    printf '%s\n' 'vcore ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/10-vcore
    chmod 0440 /etc/sudoers.d/10-vcore
    passwd -l root || true

  - |
    set -euo pipefail
    export LANG=C
    export NEEDRESTART_MODE=a

    echo
    echo "========== НАСТРОЙКА РОССИЙСКОГО ЗЕРКАЛА ARCH LINUX =========="
    mkdir -p /etc/pacman.d
    cat > /etc/pacman.d/mirrorlist <<'MIRRORS'
Server = https://mirror.truenetwork.ru/archlinux/$repo/os/$arch
MIRRORS

    echo "Используется зеркало: https://mirror.truenetwork.ru/archlinux/"
    echo
    echo "========== ОБНОВЛЕНИЕ БАЗЫ ПАКЕТОВ =========="
    pacman -Syy --noconfirm

    echo
    echo "========== ARCH LINUX: ОБНОВЛЕНИЕ СИСТЕМЫ =========="
    pacman -Syu --noconfirm

    echo
    echo "========== ARCH LINUX: УСТАНОВКА ПАКЕТОВ =========="
EOF

    printf '    pacman -S --needed --noconfirm' >> "$USER_DATA"
    for package in $PACKAGES; do
        printf ' \\\n      %s' "$package" >> "$USER_DATA"
    done
    printf '\n' >> "$USER_DATA"

    cat >> "$USER_DATA" <<'EOF'

    echo
    echo "========== ПРОВЕРКА SUDOERS И БЛОКИРОВКА ROOT =========="
    visudo -c
    passwd -l root || true

    echo
    echo "========== НАСТРОЙКА И ВКЛЮЧЕНИЕ SSH =========="
    sshd -t
    systemctl enable --now sshd
    systemctl restart sshd

    echo
    echo "========== УСТАНОВКА ЗАВЕРШЕНА =========="
    echo "Пользователь: vcore"
    echo "Журнал: /var/log/cloud-init-output.log"
EOF

    cat > "$META_DATA" <<EOF
instance-id: ${VM_NAME}-$(date +%Y%m%d%H%M%S)
local-hostname: $VM_NAME
EOF

    write_network_config
    build_seed_iso
}

write_network_config()
{
    # First virtio-net device is expected to appear as enp0s1.
    cat > "$NETWORK_CONFIG" <<EOF
version: 2
ethernets:
  enp0s1:
    dhcp4: true
    dhcp6: true
EOF
}

build_seed_iso()
{
    echo "Creating cloud-init seed ISO..."
    (
        cd "$VM_DIR"
        mkisofs -quiet -output "$SEED_ISO" -volid cidata -joliet -rock \
            user-data meta-data network-config
    )
    echo "Cloud-init seed created: $SEED_ISO"
}

create_vm()
{
    mkdir -p "$VM_DIR"

    refresh_manifest
    download_image_if_missing
    verify_image
    prepare_disk
    prepare_uefi

    if [ ! -s "$SEED_ISO" ]; then
        make_cloud_init
    else
        echo "Existing cloud-init ISO found: $SEED_ISO"
        printf "Recreate user-data too (updates password/packages)? [y/N] "
        IFS= read -r answer
        case "$answer" in
            y|Y|yes|YES)
                make_cloud_init
                ;;
            *)
                [ -s "$USER_DATA" ] || die "Missing $USER_DATA; cannot rebuild cloud-init ISO safely."
                [ -s "$META_DATA" ] || die "Missing $META_DATA; cannot rebuild cloud-init ISO safely."
                write_network_config
                build_seed_iso
                ;;
        esac
    fi

    echo
    echo "Arch Linux VM files are prepared in $VM_DIR"
    echo "Run: doas $0 start"
}

reset_password_seed()
{
    if vm_running; then
        die "Stop the VM first: doas $0 stop"
    fi

    mkdir -p "$VM_DIR"
    cat > "$USER_DATA" <<'EOF'
#cloud-config
hostname: archlinux-jwm
ssh_pwauth: true
write_files:
  - path: /etc/ssh/sshd_config.d/10-vcore-password.conf
    owner: root:root
    permissions: '0600'
    content: |
      PasswordAuthentication yes
      KbdInteractiveAuthentication yes
runcmd:
  - |
    set -eu
    if ! id vcore >/dev/null 2>&1; then
      useradd --create-home --shell /bin/bash vcore
    fi
    usermod -aG wheel,audio,video,storage,optical,input vcore
    printf '%s\n' 'vcore:639639' | chpasswd
    usermod -U vcore
    install -d -m 0750 /etc/sudoers.d
    printf '%s\n' 'vcore ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/10-vcore
    chmod 0440 /etc/sudoers.d/10-vcore
    passwd -l root || true
    systemctl enable --now sshd
    sshd -t
    systemctl restart sshd
EOF

    cat > "$META_DATA" <<EOF
instance-id: ${VM_NAME}-password-recovery-$(date +%Y%m%d%H%M%S)
local-hostname: $VM_NAME
EOF
    write_network_config
    build_seed_iso
    echo "Recovery cloud-init ISO created. Start the VM with: doas $0 start"
}

setup_network()
{
    if ! ifconfig "$BRIDGE" >/dev/null 2>&1; then
        die "Bridge interface $BRIDGE does not exist"
    fi

    if ! ifconfig "$TAP" >/dev/null 2>&1; then
        echo "Creating TAP interface $TAP..."
        ifconfig "$TAP" create
    fi

    if ! ifconfig "$BRIDGE" | grep -q "[[:space:]]$TAP"; then
        echo "Adding $TAP to $BRIDGE..."
        ifconfig "$BRIDGE" addm "$TAP"
    fi

    ifconfig "$TAP" up
}

vm_running()
{
    bhyvectl --vm="$VM_NAME" --get-stats >/dev/null 2>&1
}

start_vm()
{
    [ -s "$DISK_FILE" ] || die "Disk not found. Run '$0 create' first."
    [ -s "$SEED_ISO" ] || die "Cloud-init ISO not found. Run '$0 create' first."
    [ -s "$UEFI_VARS" ] || die "UEFI vars not found. Run '$0 create' first."

    if vm_running; then
        echo "VM $VM_NAME is already running."
        return
    fi

    setup_network
    rm -f "$PIDFILE"

    echo "Starting bhyve VM: $VM_NAME"
    daemon -p "$PIDFILE" -o "$LOGFILE" bhyve \
        -c "$VCPUS" \
        -m "$MEMORY" \
        -A -H -P \
        -s 0,hostbridge \
        -s 1,virtio-net,"$TAP" \
        -s 2,virtio-blk,"$DISK_FILE" \
        -s 3,ahci-cd,"$SEED_ISO" \
        -l bootrom,"$UEFI_CODE","$UEFI_VARS" \
        -l com1,stdio \
        "$VM_NAME"

    sleep 1
    if vm_running; then
        echo "VM $VM_NAME started."
        echo "bhyve log: $LOGFILE"
    else
        echo "VM did not start. Check: $LOGFILE" >&2
        [ ! -f "$LOGFILE" ] || tail -40 "$LOGFILE" >&2
        return 1
    fi
}

stop_vm()
{
    if vm_running; then
        echo "Stopping VM $VM_NAME..."
        bhyvectl --vm="$VM_NAME" --destroy
    else
        echo "VM $VM_NAME is not running."
    fi
    rm -f "$PIDFILE"
}

status_vm()
{
    if vm_running; then
        echo "VM $VM_NAME: RUNNING"
    else
        echo "VM $VM_NAME: STOPPED"
    fi

    [ ! -s "$IMAGE_FILE" ] || echo "Image: $IMAGE_FILE"
    [ ! -s "$DISK_FILE" ] || echo "Disk:  $DISK_FILE"
    [ ! -s "$SEED_ISO" ] || echo "Seed:  $SEED_ISO"
}

usage()
{
    echo "Usage: doas $0 {create|reset-password|start|stop|restart|status}"
}

main()
{
    need_root "$@"
    check_tools

    command="${1:-}"
    case "$command" in
        create)         create_vm ;;
        reset-password) reset_password_seed ;;
        start)          start_vm ;;
        stop)    stop_vm ;;
        restart) stop_vm; start_vm ;;
        status)  status_vm ;;
        *)       usage; exit 2 ;;
    esac
}

main "$@"
