#!/usr/bin/env bash
# elan-fp-fix stage 2: build and install a libfprint with the "elanpress"
# driver, which actually works for the Elan 04f3:0c6e press-type sensor.
#
# The stock libfprint drives 0c6e as a swipe sensor and has never matched a
# finger on it (upstream issues #401/#732). This installs libfprint built from
# github.com/filip-rs/libfprint branch "elanpress" (pinned commit) with this
# repo's driver/elanpress.{c,h} overlaid (fw 8.00 support — see driver/README.md)
# into /usr/local, shadowing the distro library via ldconfig. Nothing dpkg-owned
# is touched; --uninstall restores the distro library exactly.
set -euo pipefail

ELANPRESS_REPO="https://github.com/filip-rs/libfprint.git"
ELANPRESS_COMMIT="34fc394bd912918ddd6e05838c2d5cce1e91109f"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER_OVERLAY_DIR="$SCRIPT_DIR/driver"
PREFIX="/usr/local"
MANIFEST_DIR="$PREFIX/share/elan-fp-fix"
MANIFEST="$MANIFEST_DIR/driver-manifest.txt"
WORKDIR="${ELAN_FP_WORKDIR:-/tmp/elan-fp-fix-build}"

usage() {
    cat <<'EOF'
Usage: sudo ./install-driver.sh [OPTIONS]

Build and install a patched libfprint (elanpress driver) for the Elan
04f3:0c6e press-type fingerprint sensor. Builds inside Docker when available
(recommended), otherwise directly on the host.

Options:
  --uninstall   Remove the patched library from /usr/local and restore the
                distro libfprint. Enrolled prints are kept (but prints made
                with elanpress are not readable by the stock driver).
  --host-build  Force building on the host even if Docker is available
                (requires meson/ninja and libfprint dev packages).
  --help        Show this help and exit.

Exit codes: 0 success, 1 generic failure, 3 missing build tool.
EOF
}

UNINSTALL=false
HOST_BUILD=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --uninstall) UNINSTALL=true ;;
        --host-build) HOST_BUILD=true ;;
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
    echo "✖ must run as root (try: sudo ./install-driver.sh)" >&2
    exit 1
fi

restart_fprintd() {
    ldconfig
    systemctl restart fprintd.service 2>/dev/null || true
    # Give fprintd a moment to claim the device with the new library.
    sleep 2
}

do_uninstall() {
    if [[ ! -f "$MANIFEST" ]]; then
        echo "✖ no driver manifest at $MANIFEST — nothing to uninstall" >&2
        exit 1
    fi
    while IFS= read -r f; do
        rm -f "$f"
    done <"$MANIFEST"
    rm -f "$MANIFEST"
    rmdir --ignore-fail-on-non-empty "$MANIFEST_DIR"
    restart_fprintd
    echo "✔ patched libfprint removed; distro library active again"
}

if "$UNINSTALL"; then
    do_uninstall
    exit 0
fi

fetch_source() {
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"
    git -C "$WORKDIR" init -q
    git -C "$WORKDIR" remote add origin "$ELANPRESS_REPO"
    echo "→ fetching libfprint elanpress @ ${ELANPRESS_COMMIT:0:12}"
    git -C "$WORKDIR" fetch -q --depth 1 origin "$ELANPRESS_COMMIT"
    git -C "$WORKDIR" checkout -q "$ELANPRESS_COMMIT"

    # Overlay this repo's patched driver (fw 8.00 support, see driver/README.md)
    if [[ ! -f "$DRIVER_OVERLAY_DIR/elanpress.c" || ! -f "$DRIVER_OVERLAY_DIR/elanpress.h" ]]; then
        echo "✖ missing $DRIVER_OVERLAY_DIR/elanpress.{c,h} — incomplete checkout?" >&2
        exit 1
    fi
    echo "→ overlaying patched elanpress driver from $DRIVER_OVERLAY_DIR"
    cp "$DRIVER_OVERLAY_DIR/elanpress.c" "$DRIVER_OVERLAY_DIR/elanpress.h" \
        "$WORKDIR/libfprint/drivers/"
}

MESON_ARGS=(--prefix="$PREFIX" --libdir=lib/x86_64-linux-gnu
    -Ddoc=false -Dintrospection=false -Dgtk-examples=false
    -Dudev_rules=disabled -Dudev_hwdb=disabled)

build_in_docker() {
    local image
    # shellcheck disable=SC1091
    image="ubuntu:$(. /etc/os-release && echo "${VERSION_ID:-latest}")"
    echo "→ building in Docker ($image)"
    # seccomp=unconfined: under Docker's default seccomp profile, apt 3.x
    # (ubuntu 25.10) balloons to tens of GB and never finishes (LP#2133030);
    # the container only compiles pinned sources, so this is acceptable
    docker run --rm --security-opt seccomp=unconfined -v "$WORKDIR:/src" -w /src "$image" bash -ec "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q >/dev/null
        apt-get install -yq --no-install-recommends git meson ninja-build \
            gcc pkg-config libglib2.0-dev \
            libgusb-dev libnss3-dev libpixman-1-dev \
            libgudev-1.0-dev libcairo2-dev \
            libgirepository1.0-dev libssl-dev >/dev/null
        meson setup builddir ${MESON_ARGS[*]} >/dev/null
        ninja -C builddir >/dev/null
        DESTDIR=/src/stage ninja -C builddir install >/dev/null
    "
}

build_on_host() {
    echo "→ building on host"
    for tool in meson ninja gcc pkg-config; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "✖ missing build tool: $tool (install meson ninja-build gcc pkg-config and libfprint build deps)" >&2
            exit 3
        }
    done
    (cd "$WORKDIR" &&
        meson setup builddir "${MESON_ARGS[@]}" >/dev/null &&
        ninja -C builddir >/dev/null &&
        DESTDIR="$WORKDIR/stage" ninja -C builddir install >/dev/null)
}

fetch_source
if ! "$HOST_BUILD" && command -v docker >/dev/null 2>&1; then
    build_in_docker
else
    build_on_host
fi

if [[ ! -e "$WORKDIR/stage$PREFIX/lib/x86_64-linux-gnu/libfprint-2.so.2" ]]; then
    echo "✖ build produced no libfprint-2.so.2 — see $WORKDIR" >&2
    exit 1
fi

mkdir -p "$MANIFEST_DIR"
(cd "$WORKDIR/stage" && find . \( -type f -o -type l \) | sed 's|^\.||') >"$MANIFEST"
(cd "$WORKDIR/stage" && cp -a ./usr /)
restart_fprintd

if fprintd-list root 2>/dev/null | grep -q "press-type"; then
    echo "✔ fprintd is using the elanpress driver"
else
    echo "! fprintd did not report the press-type sensor — run ./diagnose.sh"
fi
echo "✔ patched libfprint installed to $PREFIX (manifest: $MANIFEST)"
echo "! prints enrolled with the old driver will not match — re-enroll:"
echo "→ fprintd-enroll \${SUDO_USER:-<your-username>}"
