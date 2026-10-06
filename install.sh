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

  sudo ./setup-system.sh --silent --no-pam # autosuspend fix + fprintd
  sudo ./build-driver.sh                   # build + verify elanpress
  sudo ./setup-system.sh --silent --pam-only # enable PAM after activation

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
    # Try both steps so a driver failure does not prevent system cleanup.
    failed=0
    echo "→ uninstalling driver (build-driver.sh --uninstall)"
    "$SCRIPT_DIR/build-driver.sh" --uninstall || failed=$((failed + 1))
    echo "→ uninstalling system setup (setup-system.sh --uninstall)"
    "$SCRIPT_DIR/setup-system.sh" --uninstall || failed=$((failed + 1))
    if [[ "$failed" -gt 0 ]]; then
        echo "✖ $failed uninstall step(s) failed — see messages above" >&2
        exit 1
    fi
    exit 0
fi

echo "→ step 1/3: system setup (setup-system.sh --silent --no-pam)"
"$SCRIPT_DIR/setup-system.sh" --silent --no-pam
echo "→ step 2/3: driver build, install and activation check (build-driver.sh)"
"$SCRIPT_DIR/build-driver.sh"
echo "→ step 3/3: PAM setup (setup-system.sh --silent --pam-only)"
"$SCRIPT_DIR/setup-system.sh" --silent --pam-only
