#!/usr/bin/env bash
# elan-fp-fix driver installer: build and install a libfprint with the "elanpress"
# driver, which actually works for the Elan 04f3:0c6e press-type sensor.
#
# The stock libfprint drives 0c6e as a swipe sensor and has never matched a
# finger on it (upstream issues #401/#732). This installs libfprint built from
# github.com/filip-rs/libfprint branch "elanpress" (pinned commit) with this
# repo's driver/elanpress.{c,h} overlaid (fw 8.00 support — see driver/README.md)
# into /usr/local, shadowing the distro library via ldconfig. Nothing dpkg-owned
# is touched; --uninstall removes the local library and loader configuration.
#
# Builds on the host by default, installing build dependencies through the
# distro package manager when missing. --docker keeps the build (and its
# dependencies) inside a container instead.
set -euo pipefail

ELANPRESS_REPO="https://github.com/filip-rs/libfprint.git"
ELANPRESS_COMMIT="34fc394bd912918ddd6e05838c2d5cce1e91109f"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER_OVERLAY_DIR="$SCRIPT_DIR/driver"
PREFIX="/usr/local"
MANIFEST_DIR="$PREFIX/share/elan-fp-fix"
MANIFEST="$MANIFEST_DIR/driver-manifest.txt"
WORKDIR="${ELAN_FP_WORKDIR:-}"
LOADER_CONF="/etc/ld.so.conf.d/00-elan-fp-fix.conf"
LOADER_MARKER="# Managed by elan-fp-fix build-driver.sh"
# shellcheck source=lib/driver-runtime.sh
source "$SCRIPT_DIR/lib/driver-runtime.sh"

usage() {
    cat <<'EOF'
Usage: sudo ./build-driver.sh [OPTIONS]

Build and install a patched libfprint (elanpress driver) for the Elan
04f3:0c6e press-type fingerprint sensor. Builds on the host, installing the
build dependencies through your package manager when they are missing
(apt/dnf/pacman/zypper). No Docker required.

Options:
  --uninstall   Remove the patched library from /usr/local and restore the
                distro libfprint. Enrolled prints are kept (but prints made
                with elanpress are not readable by the stock driver).
  --docker      Build inside a Docker container instead of on the host
                (keeps build dependencies off the system; needs docker).
  --help        Show this help and exit.

Exit codes: 0 success, 1 generic failure, 3 missing build tool.
EOF
}

# Resolve the host's convention even when a container does the compilation.
resolve_libdir() {
    local os_release=${1:-/etc/os-release} ID='' ID_LIKE='' multiarch lib
    if [[ -r "$os_release" ]]; then
        # shellcheck disable=SC1090
        source "$os_release"
    fi
    case " $ID $ID_LIKE " in
        *' debian '*|*' ubuntu '*)
            if command -v dpkg-architecture >/dev/null 2>&1; then
                multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
            else
                multiarch=$(gcc -print-multiarch)
            fi
            if [[ "$multiarch" =~ ^[a-zA-Z0-9_]+-[a-zA-Z0-9_-]+$ ]]; then
                printf 'lib/%s\n' "$multiarch"
                return
            fi
            ;;
        *' fedora '*|*' rhel '*|*' centos '*|*' suse '*|*' opensuse'* )
            lib=$(rpm --eval '%{_lib}')
            case "$lib" in lib|lib64) printf '%s\n' "$lib"; return ;; esac
            echo "✖ cannot resolve native RPM libdir: $lib" >&2
            return 1
            ;;
    esac
    # Arch and other non-multiarch distributions use lib.
    printf 'lib\n'
}

restart_fprintd() {
    ldconfig || return $?
    systemctl restart fprintd.service || return $?
    # The D-Bus name can be acquired before USB enumeration finishes.
    sleep 2
}

validate_manifest_path() {
    # Never allow a malformed manifest to remove files outside our prefix,
    # except for the single loader config this installer owns.
    local path=$1
    [[ "$path" != *'/../'* && "$path" != */.. && "$path" != *'/./'* ]] || return 1
    [[ "$path" == "$PREFIX/"* || "$path" == "$LOADER_CONF" ]]
}

validate_manifest() {
    local path
    while IFS= read -r path; do
        if ! validate_manifest_path "$path"; then
            echo "✖ unsafe driver manifest path: $path" >&2
            return 1
        fi
    done <"$1"
}

do_uninstall() {
    if [[ ! -f "$MANIFEST" ]]; then
        echo "✔ no driver manifest — patched driver already absent"
        return 0
    fi
    validate_manifest "$MANIFEST"
    local path
    while IFS= read -r path; do
        rm -f -- "$path"
    done <"$MANIFEST"
    rm -f -- "$MANIFEST"
    rmdir --ignore-fail-on-non-empty "$MANIFEST_DIR"
    if ! restart_fprintd; then
        echo "✖ patched files removed, but fprintd could not restart — run ./diagnose.sh" >&2
        return 1
    fi
    echo "✔ patched libfprint removed; fprintd restarted with distro loader paths"
}

fetch_source() {
    if [[ -z "$WORKDIR" ]]; then
        WORKDIR=$(mktemp -d /tmp/elan-fp-fix-build.XXXXXX)
    else
        mkdir -p "$WORKDIR"
        if [[ -n "$(find "$WORKDIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
            echo "✖ ELAN_FP_WORKDIR must be an empty directory: $WORKDIR" >&2
            return 1
        fi
    fi
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

build_in_docker() {
    local image
    image="ubuntu:24.04"
    local ID='' VERSION_ID='' meson_args
    # Use an Ubuntu host's matching release; Fedora's version is not an Ubuntu tag.
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "$ID" == ubuntu ]]; then image="ubuntu:$VERSION_ID"; fi
    printf -v meson_args '%q ' "${MESON_ARGS[@]}"
    echo "→ building in Docker ($image)"
    # seccomp=unconfined: under Docker's default seccomp profile, apt 3.x
    # (ubuntu 25.10) balloons to tens of GB and never finishes (LP#2133030);
    # the container only compiles pinned sources, so this is acceptable
    docker run --rm --security-opt seccomp=unconfined -v "$WORKDIR:/src" -w /src "$image" bash -ec "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q >/dev/null
        apt-get install -yq --no-install-recommends git meson ninja-build \
            gcc g++ pkg-config libglib2.0-dev \
            libgusb-dev libnss3-dev libpixman-1-dev \
            libgudev-1.0-dev libcairo2-dev \
            libgirepository1.0-dev libssl-dev >/dev/null
        meson setup builddir $meson_args
        ninja -C builddir
        DESTDIR=/src/stage ninja -C builddir install
    "
}

# Returns 0 when a build tool or a library libfprint needs is missing.
host_deps_missing() {
    local tool pc
    for tool in git meson ninja gcc pkg-config; do
        command -v "$tool" >/dev/null 2>&1 || return 0
    done
    # Match Meson's default C++ compiler candidates rather than assuming gcc
    # supplies C++ (Fedora/openSUSE package it separately).
    local cxx
    local -a candidates=(c++ g++ clang++)
    if [[ -n "${CXX:-}" ]]; then
        read -r -a candidates <<<"$CXX"
        command -v "${candidates[0]}" >/dev/null 2>&1 || return 0
        "${candidates[@]}" --version >/dev/null 2>&1 || return 0
    else
        local found=false
        for cxx in "${candidates[@]}"; do
            if command -v "$cxx" >/dev/null 2>&1 && "$cxx" --version >/dev/null 2>&1; then
                found=true
                break
            fi
        done
        "$found" || return 0
    fi
    for pc in glib-2.0 gusb nss pixman-1 gudev-1.0 cairo openssl; do
        pkg-config --exists "$pc" || return 0
    done
    return 1
}

install_build_deps() {
    if ! host_deps_missing; then
        echo "→ build dependencies already present"
        return 0
    fi
    echo "→ installing build dependencies"
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
            git meson ninja-build gcc g++ pkg-config \
            libglib2.0-dev libgusb-dev libnss3-dev libpixman-1-dev \
            libgudev-1.0-dev libcairo2-dev libgirepository1.0-dev libssl-dev
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y \
            git meson ninja-build gcc gcc-c++ pkgconf-pkg-config \
            glib2-devel libgusb-devel nss-devel pixman-devel \
            libgudev-devel cairo-devel gobject-introspection-devel openssl-devel
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --needed --noconfirm \
            git meson ninja gcc pkgconf \
            glib2 libgusb nss pixman libgudev cairo gobject-introspection openssl
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y \
            git meson ninja gcc gcc-c++ pkg-config \
            glib2-devel libgusb-devel mozilla-nss-devel pixman-devel \
            libgudev-devel cairo-devel gobject-introspection-devel libopenssl-devel
    else
        echo "✖ unknown package manager — install these and re-run:" >&2
        echo "  git meson ninja gcc + a C++ compiler + pkg-config + dev packages for:" >&2
        echo "  glib-2.0 gusb nss pixman-1 gudev-1.0 cairo openssl" >&2
        exit 3
    fi
    if host_deps_missing; then
        echo "✖ build dependencies still missing after the install — see above" >&2
        exit 3
    fi
}

run_build_step() {
    local step=$1 status
    shift
    echo "→ $step (log: $WORKDIR/build.log)"
    if "$@" >>"$WORKDIR/build.log" 2>&1; then
        return 0
    else
        status=$?
        echo "✖ $step failed (exit $status); log: $WORKDIR/build.log" >&2
        tail -n 80 "$WORKDIR/build.log" >&2
        return "$status"
    fi
}

build_on_host() {
    echo "→ building on host"
    (
        cd "$WORKDIR"
        run_build_step "Meson setup" meson setup builddir "${MESON_ARGS[@]}" || exit $?
        run_build_step "Ninja build" ninja -C builddir || exit $?
        run_build_step "Ninja install" env DESTDIR="$WORKDIR/stage" ninja -C builddir install
    )
}

install_staged_files() {
    local staged_manifest="$WORKDIR/new-manifest.txt" path dir
    local -a label_paths=()
    local -A new_dirs=()
    # Only files below the resolved prefix can be installed/removed.
    (cd "$WORKDIR/stage" && find ".${PREFIX}" \( -type f -o -type l \) -print |
        sed 's|^\.||') >"$staged_manifest"
    validate_manifest "$staged_manifest"
    [[ ! -f "$MANIFEST" ]] || validate_manifest "$MANIFEST"
    if [[ -e "$LOADER_CONF" || -L "$LOADER_CONF" ]]; then
        if [[ -L "$LOADER_CONF" ]] || ! grep -qxF "$LOADER_MARKER" "$LOADER_CONF"; then
            echo "✖ refusing to replace unowned loader configuration: $LOADER_CONF" >&2
            return 1
        fi
    fi
    # Create directories without copying the staging tree's metadata onto
    # shared /usr/local directories. Label only new directories and our files.
    while IFS= read -r path; do
        dir=$(dirname "$path")
        while [[ ! -d "$dir" ]]; do
            new_dirs["$dir"]=1
            dir=$(dirname "$dir")
        done
        mkdir -p "$(dirname "$path")"
        # cp -a implicitly preserves context AND xattrs from /tmp (user_tmp_t).
        # Preserve symlinks/modes/times only; -Z uses destination policy labels.
        # Replace the inode so a running daemon's old mapping is not rewritten.
        cp -d --preserve=mode,timestamps -Z --remove-destination -- "$WORKDIR/stage$path" "$path"
        label_paths+=("$path")
    done <"$staged_manifest"
    mkdir -p "$MANIFEST_DIR" "$(dirname "$LOADER_CONF")"
    printf '%s\n%s\n' "$LOADER_MARKER" "$LIBDIR" >"$LOADER_CONF"
    printf '%s\n' "$LOADER_CONF" >>"$staged_manifest"
    label_paths+=("$LIBDIR" "$LOADER_CONF" "$MANIFEST_DIR" "$MANIFEST")
    if [[ -f "$MANIFEST" ]]; then
        # Drop old manifest-owned libraries when migrating from a legacy libdir.
        while IFS= read -r path; do
            if ! grep -qxF "$path" "$staged_manifest"; then rm -f -- "$path"; fi
        done <"$MANIFEST"
    fi
    cp "$staged_manifest" "$MANIFEST"
    # Defensive restoration also fixes previously installed files with bad labels.
    # No broad recursive relabel: unrelated libraries retain their contexts.
    if command -v restorecon >/dev/null 2>&1; then
        label_paths+=("${!new_dirs[@]}")
        restorecon -F -- "${label_paths[@]}"
    fi
}

verify_activation() {
    local view pid mapped expected actual found=false
    if ! view=$(LC_ALL=C timeout 15 fprintd-list root 2>&1); then
        printf '✖ fprintd query failed: %s\n' "$view" >&2
        return 1
    fi
    if [[ "$view" != *'ElanTech press-type fingerprint sensor'* ]]; then
        printf '✖ fprintd did not report the elanpress sensor: %s\n' "$view" >&2
        return 1
    fi
    # Querying the device starts an idle service via D-Bus. Use systemd's PID,
    # not a foreground/debug daemon or shell ldd, for the runtime check.
    if [[ -d /proc ]]; then
        if ! pid=$(fprintd_pid) || ! mapped=$(mapped_libfprint "$pid"); then
            echo "✖ cannot read the systemd fprintd library mapping" >&2
            return 1
        fi
        expected=$(readlink -f "$LIBDIR/libfprint-2.so.2")
        while IFS= read -r actual; do
            if [[ "$actual" == "$expected" ]]; then found=true; fi
        done <<<"$mapped"
        if ! "$found"; then
            printf '✖ fprintd mapped %s; expected %s\n' "${mapped:-no libfprint}" "$expected" >&2
            return 1
        fi
    fi
    echo "✔ fprintd is using the elanpress driver"
}

main() {
    local uninstall=false docker_build=false
    while [[ $# -gt 0 ]]; do
        case $1 in
            --uninstall) uninstall=true ;;
            --docker) docker_build=true ;;
            --host-build) ;; # backwards compatibility
            --help|-h) usage; return 0 ;;
            *) printf '✖ unknown option: %s\n\n' "$1" >&2; usage >&2; return 1 ;;
        esac
        shift
    done
    if [[ "$EUID" -ne 0 ]]; then
        echo "✖ must run as root (try: sudo ./build-driver.sh)" >&2
        return 1
    fi
    if "$uninstall"; then do_uninstall; return; fi
    if "$docker_build" && ! command -v docker >/dev/null 2>&1; then
        echo "✖ --docker requested but docker is not installed" >&2
        return 3
    fi
    if ! "$docker_build"; then install_build_deps; fi
    local libdir
    libdir=$(resolve_libdir)
    LIBDIR="$PREFIX/$libdir"
    MESON_ARGS=(--prefix="$PREFIX" --libdir="$libdir"
        -Ddoc=false -Dintrospection=false -Dgtk-examples=false
        -Dudev_rules=disabled -Dudev_hwdb=disabled)
    fetch_source
    if "$docker_build"; then
        run_build_step "Docker build" build_in_docker
    else
        build_on_host
    fi
    if [[ ! -e "$WORKDIR/stage$LIBDIR/libfprint-2.so.2" ]]; then
        echo "✖ build produced no $LIBDIR/libfprint-2.so.2 — see $WORKDIR" >&2
        return 1
    fi
    install_staged_files
    if ! restart_fprintd || ! verify_activation; then
        echo "✖ files installed, but driver activation failed; PAM must wait" >&2
        driver_runtime_report "$MANIFEST" "$LIBDIR/libfprint-2.so.2" >&2
        echo "→ run sudo ./diagnose.sh; fix activation and re-run the installer" >&2
        return 1
    fi
    echo "✔ patched libfprint installed to $LIBDIR (manifest: $MANIFEST)"
    echo "! prints enrolled with the old driver will not match — re-enroll:"
    echo "→ fprintd-enroll \${SUDO_USER:-<your-username>}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
