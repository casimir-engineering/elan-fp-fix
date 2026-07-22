#!/usr/bin/env bash
# diagnose.sh — collect diagnostics for the Elan 04f3:0c6e fingerprint sensor.
# Part of elan-fp-fix. Runs as a regular user; uses sudo -n opportunistically.
set -euo pipefail

UDEV_RULE="/etc/udev/rules.d/60-elan-fp-autosuspend.rules"

usage() {
    cat <<'EOF'
Usage: diagnose.sh [--verify-loop N] [--any-elan] [--reenum] [--help]

Collects diagnostics for the Elan 04f3:0c6e fingerprint sensor and writes a
report to ./elan-fp-report-<hostname>-<timestamp>.txt (also shown on screen).

Options:
  --verify-loop N   run fprintd-verify N times and report the success rate
                    (requires an enrolled finger and your touches)
  --any-elan        widen detection to any 04f3 device whose product string
                    contains "Fingerprint"
  --reenum          re-enumerate the sensor (USB unbind/bind) and exit; this
                    recovers a wedged sensor that stops reacting to touches
                    (requires root: sudo ./diagnose.sh --reenum)
  --help            show this help and exit
EOF
}

VERIFY_LOOP=0
ANY_ELAN=0
REENUM=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verify-loop)
            if [[ $# -lt 2 || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "✖ --verify-loop requires a positive integer" >&2
                exit 1
            fi
            VERIFY_LOOP="$2"
            shift 2
            ;;
        --any-elan)
            ANY_ELAN=1
            shift
            ;;
        --reenum)
            REENUM=1
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
done

# Prints the sysfs device path of the sensor (e.g. /sys/bus/usb/devices/1-3), or nothing.
# ANY_ELAN=1 widens the match. Never exits non-zero (callers test output emptiness).
find_sensor() {
    local d vid pid prod
    for d in /sys/bus/usb/devices/*; do
        [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
        vid=$(<"$d/idVendor"); pid=$(<"$d/idProduct")
        [[ "$vid" == "04f3" ]] || continue
        if [[ "$pid" == "0c6e" ]]; then printf '%s\n' "$d"; return 0; fi
        if [[ "${ANY_ELAN:-0}" == "1" && -f "$d/product" ]]; then
            prod=$(<"$d/product")
            [[ "$prod" == *[Ff]ingerprint* ]] && { printf '%s\n' "$d"; return 0; }
        fi
    done
    return 0
}

section() { printf '\n===== %s =====\n' "$1"; }

# Recover a wedged sensor: after interrupted captures the device keeps ACKing
# commands but its frames stop reacting to the finger. A libusb/usbfs reset is
# not enough — only a full unbind/bind (re-enumeration) brings it back.
reenumerate() {
    local sensor port
    sensor=$(find_sensor)
    if [[ -z "$sensor" ]]; then
        echo "✖ no Elan fingerprint sensor found — nothing to re-enumerate" >&2
        return 2
    fi
    if [[ $EUID -ne 0 ]]; then
        echo "✖ re-enumeration needs root — run: sudo ./diagnose.sh --reenum" >&2
        return 1
    fi
    port=$(basename "$sensor")
    echo "→ re-enumerating $port (USB unbind/bind)..."
    echo "$port" > /sys/bus/usb/drivers/usb/unbind
    sleep 2
    echo "$port" > /sys/bus/usb/drivers/usb/bind
    sleep 1
    if [[ -n "$(find_sensor)" ]]; then
        echo "✔ sensor re-enumerated ($port)"
    else
        echo "✖ sensor did not come back after unbind/bind — check lsusb / dmesg" >&2
        return 2
    fi
}

show_sysfs_attr() {
    # show_sysfs_attr <sensor-path> <relative-attr>
    local path="$1/$2"
    if [[ -r "$path" ]]; then
        printf '%s: %s\n' "$2" "$(<"$path")"
    else
        printf '! %s: not readable\n' "$2"
    fi
}

main() {
    local exit_code=0
    local sensor
    sensor=$(find_sensor)

    section "1. System"
    uname -a
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        (. /etc/os-release && printf 'OS: %s\n' "${PRETTY_NAME:-unknown}")
    else
        echo "! /etc/os-release not readable"
    fi

    section "2. Sensor"
    if command -v lsusb >/dev/null 2>&1; then
        lsusb | grep -i '04f3' || echo "! no 04f3 device in lsusb output"
    else
        echo "! lsusb not available (install usbutils)"
    fi
    if [[ -n "$sensor" ]]; then
        printf 'sysfs path: %s\n' "$sensor"
        show_sysfs_attr "$sensor" "power/control"
        show_sysfs_attr "$sensor" "power/autosuspend_delay_ms"
        show_sysfs_attr "$sensor" "power/runtime_status"
    else
        echo "✖ no Elan fingerprint sensor found (looked for USB 04f3:0c6e in /sys/bus/usb/devices; retry with --any-elan for other Elan PIDs)"
        exit_code=2
    fi

    section "3. Fix state"
    if [[ -f "$UDEV_RULE" ]]; then
        echo "✔ udev rule installed ($UDEV_RULE)"
    else
        echo "✖ udev rule NOT installed ($UDEV_RULE)"
    fi
    if [[ -n "$sensor" && -r "$sensor/power/control" ]]; then
        if [[ "$(<"$sensor/power/control")" == "on" ]]; then
            echo "✔ power/control is on (autosuspend disabled)"
        else
            echo "✖ power/control is not on (autosuspend active) — run: sudo ./install.sh"
        fi
    else
        echo "! power/control state unknown (sensor not found or not readable)"
    fi

    section "4. Software"
    if command -v dpkg >/dev/null 2>&1; then
        dpkg -l 2>/dev/null | grep -i fprint || echo "! no fprint packages found via dpkg"
    elif command -v rpm >/dev/null 2>&1; then
        rpm -qa 2>/dev/null | grep -i fprint || echo "! no fprint packages found via rpm"
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Q 2>/dev/null | grep -i fprint || echo "! no fprint packages found via pacman"
    else
        echo "! no known package manager found — cannot list fprintd/libfprint versions"
    fi

    section "5. fprintd view"
    if command -v fprintd-list >/dev/null 2>&1; then
        fprintd-list "$USER" 2>&1 || echo "! fprintd-list failed — is fprintd running? (run: sudo ./install.sh)"
    else
        echo "✖ fprintd-list not found — install fprintd (run: sudo ./install.sh)"
    fi

    section "6. Recent logs"
    if command -v journalctl >/dev/null 2>&1; then
        if sudo -n journalctl -u fprintd --no-pager -n 50 2>/dev/null; then
            :
        elif journalctl -u fprintd --no-pager -n 50 2>/dev/null; then
            :
        else
            echo "! journal not readable without sudo (re-run as: sudo ./diagnose.sh, or add yourself to the systemd-journal group)"
        fi
    else
        echo "! journalctl not available"
    fi

    if [[ "$VERIFY_LOOP" -gt 0 ]]; then
        section "7. Verify loop"
        local enrolled=1
        if ! command -v fprintd-verify >/dev/null 2>&1; then
            echo "✖ fprintd-verify not found — install fprintd (run: sudo ./install.sh)"
            enrolled=0
        elif fprintd-list "$USER" 2>&1 | grep -qi "no fingers enrolled"; then
            echo "✖ enroll first: fprintd-enroll"
            enrolled=0
        fi
        if [[ "$enrolled" -eq 1 ]]; then
            local i pass=0
            echo "→ touch the sensor when prompted ($VERIFY_LOOP rounds)"
            for ((i = 1; i <= VERIFY_LOOP; i++)); do
                if fprintd-verify >/dev/null 2>&1; then
                    pass=$((pass + 1))
                    printf '[%d/%d] pass\n' "$i" "$VERIFY_LOOP"
                else
                    printf '[%d/%d] fail\n' "$i" "$VERIFY_LOOP"
                fi
            done
            printf '✔ verify success rate: %d/%d\n' "$pass" "$VERIFY_LOOP"
            if [[ "$pass" -eq 0 ]]; then
                echo "! every attempt failed — the sensor may be wedged (ignoring touches);"
                echo "  try re-enumerating it: sudo ./diagnose.sh --reenum"
            elif [[ "$pass" -lt "$VERIFY_LOOP" ]]; then
                echo "! verification is not 100% reliable — check sections 3 and 6 above"
            fi
        fi
    fi

    printf '\n→ report saved to: %s\n' "$REPORT"
    return "$exit_code"
}

if [[ "$REENUM" -eq 1 ]]; then
    reenumerate
    exit $?
fi

REPORT="./elan-fp-report-$(hostname)-$(date +%Y%m%d-%H%M%S).txt"

status=0
main 2>&1 | tee "$REPORT" || status=$?
exit "$status"
