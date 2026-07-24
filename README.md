# elan-fp-fix

Working Linux driver + one-command setup for the **Elan `04f3:0c6e`**
press-type fingerprint sensor — the power-button sensor on many ASUS laptops
(Zenbook S 13 UM5302, ROG Flow X13, VivoBook Pro, …).

## Install

```sh
git clone https://github.com/casimir-engineering/elan-fp-fix.git
cd elan-fp-fix
sudo ./install.sh
fprintd-enroll    # press (don't swipe) the sensor repeatedly
```

This is the full setup: USB autosuspend fix + `fprintd` + fingerprint
authentication for login/sudo (3 tries before password fallback) + the patched
`elanpress` driver built and installed to `/usr/local`. `install.sh` is a thin
wrapper that runs `setup-system.sh --silent --pam` followed by
`build-driver.sh`; run those two directly for selective install/uninstall
(e.g. skipping PAM or building in Docker). Everything is idempotent — safe to
re-run.

## Options

### `install.sh` — full setup in one command

| Flag | Description |
|------|-------------|
| *(none)* | Run `setup-system.sh --silent --pam`, then `build-driver.sh`. |
| `--uninstall` | Run `build-driver.sh --uninstall`, then `setup-system.sh --uninstall`. Packages and enrolled prints are kept. |
| `--help` | Show usage. |

### `setup-system.sh` — system setup: autosuspend fix, fprintd, PAM

| Flag | Description |
|------|-------------|
| `--silent` | No prompts. Skips the PAM step unless `--pam` is also given. |
| `--pam` | Enable fingerprint authentication without asking (`pam-auth-update` / `authselect`; on Debian/Ubuntu installs this repo's `elan-fp-fprintd` profile: 3 tries, 15 s budget). |
| `--no-pam` | Never touch PAM configuration. |
| `--uninstall` | Remove the udev rule, restore autosuspend, revert PAM. Packages stay installed. |
| `--remove-prints` | With `--uninstall` only: also delete enrolled fingerprints (`/var/lib/fprint`). |
| `--dry-run` | Print what would be done without changing anything. No root needed. |
| `--any-elan` | Match any Elan (`04f3`) USB device whose product string contains "Fingerprint", not just `0c6e`. |
| `--help` | Show usage. |

### `build-driver.sh` — driver: patched elanpress libfprint

| Flag | Description |
|------|-------------|
| *(none)* | Build on the host (build dependencies auto-installed via apt/dnf/pacman/zypper) and install to `/usr/local`. |
| `--docker` | Build inside a Docker container instead, keeping build dependencies off the system. |
| `--uninstall` | Remove the patched library (via install manifest) and restore the distro libfprint. |
| `--help` | Show usage. |

### `diagnose.sh` — diagnostics and recovery

| Flag | Description |
|------|-------------|
| *(none)* | Write a report (system info, sensor power state, versions, fprintd logs) to `./elan-fp-report-<hostname>-<timestamp>.txt`. |
| `--verify-loop N` | Run `fprintd-verify` N times and report the success rate (needs an enrolled finger). |
| `--reenum` | Re-enumerate the sensor (USB unbind/bind) to recover it when it stops reacting to touches. Needs root. |
| `--any-elan` | Same detection widening as setup-system.sh. |
| `--help` | Show usage. |

## What it does

1. **`setup-system.sh`** disables USB autosuspend for the sensor (udev rule +
   immediate sysfs write — the stock driver misbehaves when the device sleeps
   mid-session), installs `fprintd`, and optionally enables PAM fingerprint
   auth — only through `pam-auth-update` or `authselect`, never by hand-editing
   `/etc/pam.d/`. On Debian/Ubuntu it ships a profile with `max-tries=3
   timeout=15` instead of the stock single try, so one misread doesn't dump you
   to the password prompt.
2. **`build-driver.sh`** fixes matching. Upstream libfprint drives `0c6e` as
   a legacy *swipe* sensor and has never matched a finger on it
   ([upstream #401](https://gitlab.freedesktop.org/libfprint/libfprint/-/issues/401),
   known since 2021). This builds libfprint at a pinned, security-reviewed
   commit of the community
   [`elanpress` driver](https://github.com/filip-rs/libfprint/tree/elanpress),
   overlays this repo's patches for firmware 8.00 sensors (finger detection,
   cancellation, sub-second verify — see [`driver/README.md`](driver/README.md)
   for the protocol details), and installs to `/usr/local`, shadowing the
   distro library via `ldconfig`. Distro packages stay untouched and keep
   updating; `--uninstall` restores stock behavior exactly.

Fingerprint auth activates per-user: it's on for anyone with an enrolled
finger (GNOME Settings → Users, or `fprintd-enroll`) and off otherwise
(delete your prints with `fprintd-delete "$USER"`). Prints enrolled with the
stock driver are incompatible — re-enroll after installing.

## Supported distros

| Distro | Packages | PAM |
|--------|----------|-----|
| Ubuntu / Debian | `fprintd`, `libpam-fprintd` (apt) | Repo profile `elan-fp-fprintd` via `pam-auth-update` (3 tries) |
| Fedora | `fprintd`, `fprintd-pam` (dnf) | `authselect enable-feature with-fingerprint` |
| Arch | `fprintd` (pacman) | Manual — add `auth sufficient pam_fprintd.so` per the [Arch wiki](https://wiki.archlinux.org/title/Fprint); the scripts never edit `/etc/pam.d/` |
| openSUSE | `fprintd`, `pam_fprintd` (zypper) | Manual |

Other systemd distros with libfprint should work for the autosuspend fix; with
an unknown package manager the installer names the packages and continues.

## Security notes

- The elanpress matcher (normalized cross-correlation) has no formally
  benchmarked false-accept rate — the same reason similar approaches remain
  unmerged upstream. Treat fingerprint unlock on this sensor as a convenience,
  not a strong credential. Password fallback always remains available.
- On Windows this sensor captures your finger during the power-on press.
  That pre-boot flow is armed by vendor firmware, has never been
  reverse-engineered, and is impossible on Linux today. The Linux flow is:
  boot → login screen → press the sensor once.

## Troubleshooting

```sh
./diagnose.sh                   # report file to attach to an issue
./diagnose.sh --verify-loop 10  # measure reliability
sudo ./diagnose.sh --reenum     # recover a sensor that stopped reacting
```

## Uninstall

```sh
sudo ./install.sh --uninstall                       # everything: driver + udev + PAM revert, keep prints
sudo ./build-driver.sh --uninstall                  # just the driver: restore the distro libfprint
sudo ./setup-system.sh --uninstall                  # just system setup: udev + PAM revert, keep prints
sudo ./setup-system.sh --uninstall --remove-prints  # also delete enrolled prints
```

## License

[MIT](LICENSE).
