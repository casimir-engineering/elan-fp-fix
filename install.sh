#!/usr/bin/env bash
# elan-fp-fix installer: make the Elan 04f3:0c6e fingerprint sensor reliable.
# Installs a udev rule that disables USB autosuspend (the libfprint "elan"
# driver misbehaves when the device autosuspends), installs fprintd, and
# optionally enables PAM fingerprint authentication.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
RULE_NAME="60-elan-fp-autosuspend.rules"
RULE_DEST="/etc/udev/rules.d/$RULE_NAME"
# pam-auth-update profile shipped by this repo: identical to the distro
# "fprintd" profile but with max-tries=3 timeout=15 (Debian/Ubuntu ship
# max-tries=1 timeout=10, i.e. a single attempt before password fallback).
PAM_PROFILE="elan-fp-fprintd"
PAM_PROFILE_DEST="/usr/share/pam-configs/$PAM_PROFILE"

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [OPTIONS]

Fix the Elan 04f3:0c6e fingerprint sensor on Linux (USB autosuspend +
fprintd + optional PAM setup).

Options:
  --silent         Non-interactive. Skips the PAM prompt (PAM is NOT
                   enabled unless --pam is also given).
  --pam            Enable PAM fingerprint authentication without asking.
  --no-pam         Never touch PAM configuration.
  --uninstall      Remove the udev rule, restore autosuspend, and revert
                   the PAM change. Packages are left installed.
  --remove-prints  With --uninstall only: also delete all enrolled
                   fingerprints (/var/lib/fprint/*).
  --dry-run        Print what would be done instead of doing it.
                   Does not require root.
  --any-elan       Match any Elan (04f3) USB device whose product string
                   contains "Fingerprint", not just PID 0c6e.
  --help           Show this help and exit.

Exit codes: 0 success, 1 generic failure, 2 sensor not found,
3 unsupported/missing tool where fatal.
EOF
}

SILENT=false
PAM=false
NO_PAM=false
UNINSTALL=false
REMOVE_PRINTS=false
DRY_RUN=false
ANY_ELAN=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --silent) SILENT=true ;;
        --pam) PAM=true ;;
        --no-pam) NO_PAM=true ;;
        --uninstall) UNINSTALL=true ;;
        --remove-prints) REMOVE_PRINTS=true ;;
        --dry-run) DRY_RUN=true ;;
        --any-elan) ANY_ELAN=1 ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            printf '✖ unknown option: %s\n\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

if "$REMOVE_PRINTS" && ! "$UNINSTALL"; then
    echo "✖ --remove-prints requires --uninstall" >&2
    exit 1
fi

# Every mutating command goes through run(); --dry-run prints instead.
run() { if "$DRY_RUN"; then echo "[dry-run] would: $*"; else "$@"; fi; }

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

# Asks a y/N question on /dev/tty. Returns 0 only on an explicit yes.
# Falls back to "no" when no terminal is available.
prompt_yn() {
    local ans=n
    if { exec 3</dev/tty; } 2>/dev/null; then
        read -r -u 3 -p "$1" ans || ans=n
        exec 3<&-
    fi
    [[ "$ans" == [Yy]* ]]
}

enable_pam() {
    if command -v pam-auth-update >/dev/null 2>&1; then
        # Install our profile (Conflicts: fprintd, so pam-auth-update swaps
        # the stock single-try profile out for ours). No /etc/pam.d hand-edits.
        run cp "$SCRIPT_DIR/pam-configs/$PAM_PROFILE" "$PAM_PROFILE_DEST"
        run pam-auth-update --enable "$PAM_PROFILE"
        echo "✔ PAM fingerprint authentication enabled (pam-auth-update, 3 tries)"
    elif command -v authselect >/dev/null 2>&1; then
        run authselect enable-feature with-fingerprint
        echo "✔ PAM fingerprint authentication enabled (authselect)"
    else
        echo "! no safe PAM tool found — enable manually, see README"
    fi
}

do_uninstall() {
    local sensor
    if [[ -e "$RULE_DEST" ]]; then
        run rm -f "$RULE_DEST"
        run udevadm control --reload-rules
        echo "✔ udev rule removed"
    else
        echo "✔ udev rule already absent"
    fi

    sensor=$(find_sensor)
    if [[ -n "$sensor" ]]; then
        run bash -c "echo auto > '$sensor/power/control'"
        echo "✔ USB autosuspend restored to auto"
    fi

    if command -v pam-auth-update >/dev/null 2>&1; then
        run pam-auth-update --remove "$PAM_PROFILE" fprintd
        run rm -f "$PAM_PROFILE_DEST"
        echo "✔ PAM fingerprint authentication disabled (pam-auth-update)"
    elif command -v authselect >/dev/null 2>&1; then
        run authselect disable-feature with-fingerprint
        echo "✔ PAM fingerprint authentication disabled (authselect)"
    fi

    if "$REMOVE_PRINTS"; then
        local confirmed=true
        if ! "$SILENT"; then
            prompt_yn "Delete ALL enrolled fingerprints in /var/lib/fprint? [y/N] " || confirmed=false
        fi
        if "$confirmed"; then
            run bash -c 'rm -rf /var/lib/fprint/*'
            echo "✔ enrolled fingerprints removed"
        else
            echo "! fingerprint removal skipped"
        fi
    fi

    echo "✔ uninstalled (packages left installed)"
}

install_packages() {
    if command -v fprintd-enroll >/dev/null 2>&1; then
        echo "✔ fprintd already installed"
        return 0
    fi
    if command -v apt-get >/dev/null 2>&1; then
        run apt-get install -y fprintd libpam-fprintd
    elif command -v dnf >/dev/null 2>&1; then
        run dnf install -y fprintd fprintd-pam
    elif command -v pacman >/dev/null 2>&1; then
        run pacman -S --noconfirm --needed fprintd
    elif command -v zypper >/dev/null 2>&1; then
        run zypper install -y fprintd pam_fprintd
    else
        echo "! unknown package manager — install these yourself: fprintd + PAM module"
    fi
}

main() {
    if [[ "$EUID" -ne 0 ]] && ! "$DRY_RUN"; then
        echo "✖ must run as root (try: sudo ./install.sh)" >&2
        exit 1
    fi

    if "$UNINSTALL"; then
        do_uninstall
        return 0
    fi

    local sensor
    sensor=$(find_sensor)
    if [[ -z "$sensor" ]]; then
        echo "✖ no Elan fingerprint sensor found (looked for USB 04f3:0c6e in /sys/bus/usb/devices; retry with --any-elan for other Elan PIDs)" >&2
        exit 2
    fi
    echo "✔ sensor found: $sensor"

    install_packages

    run cp "$SCRIPT_DIR/udev/$RULE_NAME" "$RULE_DEST"
    run udevadm control --reload-rules
    run udevadm trigger --action=add --subsystem-match=usb --attr-match=idVendor=04f3
    echo "✔ udev rule installed: $RULE_DEST"

    run bash -c "echo on > '$sensor/power/control'"
    echo "✔ autosuspend disabled (immediately and via udev rule for future boots)"

    run systemctl restart fprintd.service || true
    if timeout 15 fprintd-list root >/dev/null 2>&1; then
        echo "✔ fprintd sees the sensor"
    else
        echo "! fprintd does not see the sensor — run ./diagnose.sh"
    fi

    if "$NO_PAM" || { "$SILENT" && ! "$PAM"; }; then
        echo "! PAM configuration skipped"
    elif "$PAM"; then
        enable_pam
    elif prompt_yn "Enable fingerprint authentication for login/sudo? [y/N] "; then
        enable_pam
    else
        echo "! PAM configuration skipped"
    fi

    echo "→ enroll a finger now: fprintd-enroll ${SUDO_USER:-<your-username>}"
}

main
