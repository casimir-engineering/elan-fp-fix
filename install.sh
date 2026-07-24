#!/usr/bin/env bash
# elan-fp-fix one-command installer: runs the recommended full setup.
# Convenience wrapper around setup-system.sh (autosuspend fix, fprintd, PAM)
# and build-driver.sh (patched elanpress libfprint). For selective installs
# or uninstalls, run those two scripts directly.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [--uninstall] [--help]

Convenience wrapper for the full elan-fp-fix setup. Equivalent to:

  sudo ./setup-system.sh --silent --pam   # autosuspend fix + fprintd + PAM
  sudo ./build-driver.sh                  # patched elanpress libfprint

For selective installs or uninstalls (e.g. skipping PAM, Docker builds,
removing enrolled prints), run setup-system.sh and build-driver.sh directly;
each has its own --help.

Options:
  --uninstall   Remove everything: the patched libfprint (build-driver.sh
                --uninstall), then the udev rule and PAM change
                (setup-system.sh --uninstall). Packages and enrolled
                prints are kept.
  --help        Show this help and exit.
EOF
}

UNINSTALL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --uninstall) UNINSTALL=true ;;
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

if [[ "$EUID" -ne 0 ]]; then
    echo "✖ must run as root (try: sudo ./install.sh)" >&2
    exit 1
fi

if "$UNINSTALL"; then
    # Driver first (it shadows the distro library), then system setup.
    # build-driver.sh --uninstall exits 1 when the driver was never
    # installed; keep going so the system-setup half is still reverted.
    failed=0
    echo "→ uninstalling driver (build-driver.sh --uninstall)"
    "$SCRIPT_DIR/build-driver.sh" --uninstall || failed=$((failed + 1))
    echo "→ uninstalling system setup (setup-system.sh --uninstall)"
    "$SCRIPT_DIR/setup-system.sh" --uninstall || failed=$((failed + 1))
    if [[ "$failed" -eq 2 ]]; then
        echo "✖ both uninstall steps failed — see messages above" >&2
        exit 1
    elif [[ "$failed" -eq 1 ]]; then
        echo "! one uninstall step reported nothing to do or failed — see above"
    fi
    exit 0
fi

echo "→ step 1/2: system setup (setup-system.sh --silent --pam)"
"$SCRIPT_DIR/setup-system.sh" --silent --pam
echo "→ step 2/2: driver build and install (build-driver.sh)"
"$SCRIPT_DIR/build-driver.sh"
