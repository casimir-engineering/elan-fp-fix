#!/usr/bin/env bash
# Shared read-only diagnostics for the installer and diagnose.sh.

fprintd_pid() {
    local pid
    pid=$(systemctl show fprintd.service --property=MainPID --value 2>/dev/null) || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$pid"
}

read_privileged() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        "$@" 2>/dev/null || sudo -n "$@"
    fi
}

mapped_libfprint() {
    local pid=$1 maps
    maps=$(read_privileged cat "/proc/$pid/maps") || return 1
    # Keep '(deleted)' visible: an old mapping is not proof of activation.
    printf '%s\n' "$maps" | awk '/\/libfprint-2\.so/ {print substr($0, index($0, "/"))}' | sort -u
}

driver_runtime_report() {
    local manifest=${1:-/usr/local/share/elan-fp-fix/driver-manifest.txt}
    local expected=${2:-} pid daemon path
    [[ -z "$expected" ]] || printf 'Expected patched library: %s\n' "$expected"
    echo 'fprintd service environment and overrides:'
    systemctl show fprintd.service --property=Environment --property=DropInPaths 2>&1 || true
    echo 'Loader cache (does not prove what systemd loaded):'
    if command -v ldconfig >/dev/null 2>&1; then
        ldconfig -p 2>&1 | grep libfprint || true
    else
        echo '! ldconfig not available'
    fi

    echo 'Shell linker resolution (not authoritative for systemd/SELinux):'
    daemon=$(systemctl show fprintd.service --property=ExecStart --value 2>/dev/null |
        sed -n 's/.*path=\([^ ;]*\).*/\1/p') || daemon=''
    if [[ -z "$daemon" ]]; then
        for path in /usr/libexec/fprintd /usr/lib/fprintd /usr/lib/fprintd/fprintd; do
            if [[ -x "$path" ]]; then daemon=$path; break; fi
        done
    fi
    if [[ -n "$daemon" ]] && command -v ldd >/dev/null 2>&1; then
        ldd "$daemon" 2>&1 | grep libfprint || true
    else
        echo '! fprintd executable or ldd unavailable'
    fi

    echo 'Actual systemd fprintd mapping (/proc/<MainPID>/maps; authoritative runtime check):'
    if pid=$(fprintd_pid); then
        printf 'MainPID: %s\n' "$pid"
        mapped_libfprint "$pid" || echo '! maps not readable; re-run diagnostics as root'
    else
        echo '! fprintd service is not running (it may have timed out while idle)'
    fi

    if command -v getenforce >/dev/null 2>&1; then
        printf 'SELinux: '
        getenforce || true
        echo 'Installed library labels:'
        if [[ -r "$manifest" ]]; then
            while IFS= read -r path; do
                case "$path" in
                    */libfprint-2.so*) ls -ldZ -- "$path" 2>&1 || true ;;
                esac
            done <"$manifest"
        elif [[ -n "$expected" ]]; then
            ls -ldZ -- "$expected" 2>&1 || true
        else
            echo '! no driver manifest found'
        fi
        if command -v ausearch >/dev/null 2>&1; then
            echo 'Recent fprintd AVCs (may include denials from before this install):'
            read_privileged ausearch -m AVC,USER_AVC -ts recent -c fprintd 2>&1 | tail -n 60 || true
        fi
    fi
    return 0
}
