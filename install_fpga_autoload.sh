#!/bin/sh
#
# Install the MaRCoS FPGA loader as an early SysV boot service.
#
# Host usage:
#   sh ./install_fpga_autoload.sh BOARD_IP
#
# Windows PowerShell must launch this script through the same Git Bash
# executable used by MaSeqMimo. See readme.org for an example.
#
# Direct board usage:
#   /bin/sh install_fpga_autoload.sh --board-install
#
# The bitstream and overlay must already have been installed by
# copy_bitstream.sh as:
#   /lib/firmware/marcos_fpga.bit.bin
#   /lib/firmware/marcos_fpga.dtbo

PROGRAM_NAME=$(basename "$0")

BITSTREAM=/lib/firmware/marcos_fpga.bit.bin
DTBO=/lib/firmware/marcos_fpga.dtbo
FPGA_MANAGER=/sys/class/fpga_manager/fpga0
FPGA_STATE=$FPGA_MANAGER/state
OVERLAY_ROOT=/sys/kernel/config/device-tree/overlays
OVERLAY=$OVERLAY_ROOT/full
INIT_SCRIPT=/etc/init.d/marcos-fpga
EARLY_LINK=/etc/rcS.d/S99marcos-fpga

say()
{
    echo "$PROGRAM_NAME: $*"
}

fail()
{
    echo "$PROGRAM_NAME: ERROR: $*" >&2
    exit 1
}

usage()
{
    cat <<EOF
Usage:
  $PROGRAM_NAME BOARD_IP
  $PROGRAM_NAME --board-install
  $PROGRAM_NAME {start|stop|restart|status}

Run the BOARD_IP form from the marcos_extras directory on the host.
It uploads this script and installs the early SysV boot service remotely.
Windows PowerShell users must launch this script through Git Bash.

Use --board-install only when this script has already been copied to the board.
EOF
}

wait_for_path()
{
    path=$1
    timeout=$2
    elapsed=0

    while [ ! -e "$path" ]; do
        if [ "$elapsed" -ge "$timeout" ]; then
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    return 0
}

current_fpga_state()
{
    if [ -r "$FPGA_STATE" ]; then
        cat "$FPGA_STATE"
    else
        echo unavailable
    fi
}

marcos_overlay_is_loaded()
{
    [ "$(current_fpga_state)" = operating ] || return 1
    [ -d "$OVERLAY" ] || return 1
    [ -r "$OVERLAY/path" ] || return 1

    loaded_path=$(cat "$OVERLAY/path" 2>/dev/null || true)
    case "$loaded_path" in
        *marcos_fpga.dtbo*) return 0 ;;
        *) return 1 ;;
    esac
}

record_load_time()
{
    if [ -r /proc/uptime ]; then
        cut -d ' ' -f 1 /proc/uptime > /tmp/marcos-fpga-loaded-at 2>/dev/null || true
    fi
}

load_fpga()
{
    force=${1:-no}

    [ -r "$BITSTREAM" ] || fail "Missing bitstream: $BITSTREAM"
    [ -r "$DTBO" ] || fail "Missing device-tree overlay: $DTBO"

    say "Waiting for the FPGA Manager"
    wait_for_path "$FPGA_MANAGER/flags" 20 || \
        fail "FPGA Manager did not appear within 20 seconds"

    if ! grep -qs " /sys/kernel/config " /proc/mounts; then
        say "Mounting configfs"
        mount -t configfs configfs /sys/kernel/config || \
            fail "Unable to mount configfs"
    fi

    wait_for_path "$OVERLAY_ROOT" 10 || \
        fail "Device-tree overlay interface did not appear within 10 seconds"

    if [ "$force" != yes ] && marcos_overlay_is_loaded; then
        say "MaRCoS FPGA is already loaded"
        record_load_time
        return 0
    fi

    if [ -d "$OVERLAY" ]; then
        rmdir "$OVERLAY" || fail "Unable to remove the existing full overlay"
    fi

    echo 0 > "$FPGA_MANAGER/flags" || fail "Unable to set FPGA Manager flags"
    mkdir "$OVERLAY" || fail "Unable to create the full overlay"
    printf '%s' marcos_fpga.dtbo > "$OVERLAY/path" || \
        fail "Unable to apply marcos_fpga.dtbo"

    elapsed=0
    while [ "$elapsed" -lt 10 ]; do
        if [ "$(current_fpga_state)" = operating ]; then
            say "MaRCoS FPGA loaded successfully"
            record_load_time
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    fail "FPGA load failed; state is $(current_fpga_state)"
}

service_status()
{
    state=$(current_fpga_state)
    echo "FPGA state: $state"

    if marcos_overlay_is_loaded; then
        echo "MaRCoS overlay: loaded"
        return 0
    fi

    echo "MaRCoS overlay: not loaded"
    return 1
}

remove_late_start_links()
{
    for runlevel_dir in \
        /etc/rc0.d /etc/rc1.d /etc/rc2.d /etc/rc3.d \
        /etc/rc4.d /etc/rc5.d /etc/rc6.d
    do
        [ -d "$runlevel_dir" ] || continue

        for link in "$runlevel_dir"/S??marcos-fpga; do
            [ -L "$link" ] || continue
            target=$(readlink "$link" 2>/dev/null || true)

            case "$target" in
                ../init.d/marcos-fpga|/etc/init.d/marcos-fpga)
                    say "Removing duplicate late start link: $link"
                    rm -f "$link" || fail "Unable to remove $link"
                    ;;
            esac
        done
    done
}

install_on_board()
{
    [ "$(id -u)" -eq 0 ] || fail "Board installation must run as root"
    [ -d /etc/init.d ] || fail "SysV init directory not found: /etc/init.d"
    [ -d /etc/rcS.d ] || fail "Early boot directory not found: /etc/rcS.d"
    [ -r "$BITSTREAM" ] || fail "Run copy_bitstream.sh first; missing $BITSTREAM"
    [ -r "$DTBO" ] || fail "Run copy_bitstream.sh first; missing $DTBO"

    source_script=$0
    case "$source_script" in
        /*) ;;
        *) source_script=$(pwd)/$source_script ;;
    esac

    [ -r "$source_script" ] || fail "Unable to read installer: $source_script"

    if [ -e "$EARLY_LINK" ] || [ -L "$EARLY_LINK" ]; then
        if [ ! -L "$EARLY_LINK" ] || \
           [ "$(readlink "$EARLY_LINK" 2>/dev/null || true)" != ../init.d/marcos-fpga ]; then
            fail "Refusing to replace unexpected path: $EARLY_LINK"
        fi
    fi

    if [ "$source_script" != "$INIT_SCRIPT" ] && [ "$source_script" != "$EARLY_LINK" ]; then
        if [ -f "$INIT_SCRIPT" ]; then
            backup=$INIT_SCRIPT.previous
            say "Backing up the existing init script to $backup"
            cp -p "$INIT_SCRIPT" "$backup" || fail "Unable to create $backup"
        fi

        say "Installing $INIT_SCRIPT"
        cp "$source_script" "$INIT_SCRIPT" || fail "Unable to install $INIT_SCRIPT"
    fi

    chmod 755 "$INIT_SCRIPT" || fail "Unable to make $INIT_SCRIPT executable"

    if [ ! -L "$EARLY_LINK" ]; then
        say "Creating early boot link: $EARLY_LINK"
        ln -s ../init.d/marcos-fpga "$EARLY_LINK" || \
            fail "Unable to create $EARLY_LINK"
    fi

    remove_late_start_links
    sync

    say "Early FPGA autoload installation completed"
    say "The FPGA will load from rcS on the next boot"
    say "The running FPGA was not reloaded during installation"
    say "Current FPGA state: $(current_fpga_state)"
    say "Reboot the board and run: $INIT_SCRIPT status"
}

valid_board_host()
{
    case "$1" in
        ""|BOARD_IP|board_ip|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

deploy_from_host()
{
    board_host=$1
    remote=root@$board_host
    remote_script=/tmp/install_fpga_autoload.sh

    valid_board_host "$board_host" || fail "Invalid board address: $board_host"
    command -v ssh >/dev/null 2>&1 || fail "ssh is not available"
    command -v scp >/dev/null 2>&1 || fail "scp is not available"

    script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd) || \
        fail "Unable to locate this script"
    local_script=$script_dir/$(basename "$0")

    say "Checking SSH access to $remote"
    ssh -o ConnectTimeout=10 "$remote" true || fail "Unable to connect to $remote"

    say "Uploading the installer"
    if ! scp -o ConnectTimeout=10 "$local_script" "$remote:$remote_script"; then
        say "Retrying with the legacy SCP protocol"
        scp -O -o ConnectTimeout=10 "$local_script" "$remote:$remote_script" || \
            fail "Unable to upload the installer"
    fi

    say "Installing the early boot service"
    ssh -o ConnectTimeout=10 "$remote" "/bin/sh $remote_script --board-install" || \
        fail "Remote installation failed"

    ssh -o ConnectTimeout=10 "$remote" "rm -f $remote_script" >/dev/null 2>&1 || true
    say "Remote installation completed"
}

case "${1:-}" in
    start)
        load_fpga no
        ;;
    stop)
        # Deliberately keep the FPGA configured to avoid output disturbances.
        exit 0
        ;;
    restart|reload)
        load_fpga yes
        ;;
    status)
        service_status
        ;;
    --board-install)
        install_on_board
        ;;
    -h|--help|"")
        usage
        ;;
    *)
        [ "$#" -eq 1 ] || {
            usage >&2
            exit 2
        }
        deploy_from_host "$1"
        ;;
esac
