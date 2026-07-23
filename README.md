# elan-fp-fix

One-command fix for the **Elan `04f3:0c6e`** fingerprint sensor on Linux
(found in the power button of many ASUS laptops: Zenbook S 13 UM5302, ROG
Flow X13, VivoBook Pro, …).

Two stages:

1. **`install.sh` — setup + reliability fix.** Disables USB autosuspend for the
   sensor (udev rule), installs and configures `fprintd`, optionally enables
   PAM fingerprint authentication.
2. **`install-driver.sh` — working driver.** The stock libfprint drives this
   press-type sensor as a *swipe* sensor and has never matched a finger on it
   ([upstream issue #401](https://gitlab.freedesktop.org/libfprint/libfprint/-/issues/401)).
   This script builds libfprint with the community
   [`elanpress` driver](https://github.com/filip-rs/libfprint/tree/elanpress)
   (pinned commit, security-reviewed) plus this repo's patches for firmware
   8.00 sensors (see [`driver/README.md`](driver/README.md)), and installs it
   to `/usr/local` without touching any distro-owned file.

## Quick start

```sh
git clone https://github.com/blackstar-inc/elan-fp-fix.git
cd elan-fp-fix
sudo ./install.sh          # stage 1: autosuspend fix + fprintd + PAM
sudo ./install-driver.sh   # stage 2: working elanpress driver
fprintd-enroll             # press (don't swipe) the sensor repeatedly
```

Both installers are idempotent — safe to re-run at any time. Stage 2 builds
on the host, installing the build dependencies through your package manager
(apt/dnf/pacman/zypper) when they are missing — no Docker needed. Pass
`--docker` to build inside a container instead and keep the build
dependencies off your system.

## Silent install

For unattended setups (no prompts):

```sh
sudo ./install.sh --silent --pam     # with fingerprint auth for login/sudo
sudo ./install.sh --silent           # without PAM changes
```

`--silent` skips the PAM step unless you explicitly pass `--pam`.

## Flags

### install.sh

| Flag | Description |
|------|-------------|
| `--silent` | No prompts. Skips the PAM step unless `--pam` is also given. |
| `--pam` | Enable fingerprint authentication (via `pam-auth-update` / `authselect`) without asking. On Debian/Ubuntu this installs the repo's `elan-fp-fprintd` profile (3 tries, 15 s timeout). |
| `--no-pam` | Skip the PAM step entirely. |
| `--uninstall` | Remove the udev rule, re-enable autosuspend, revert PAM. Packages are left installed. |
| `--remove-prints` | With `--uninstall` only: also delete enrolled fingerprints (`/var/lib/fprint`). Asks for confirmation unless `--silent`. |
| `--dry-run` | Print what would be done (`[dry-run] would: ...`) without changing anything. Does not require root. |
| `--any-elan` | Widen detection to any Elan (`04f3`) USB device whose product string contains "Fingerprint", not just `0c6e`. |
| `--help` | Show usage. |

### install-driver.sh

| Flag | Description |
|------|-------------|
| `--uninstall` | Remove the patched library from `/usr/local` (via install manifest) and restore the distro libfprint. |
| `--docker` | Build inside a Docker container instead of on the host (keeps build dependencies off the system). |
| `--help` | Show usage. |

### diagnose.sh

| Flag | Description |
|------|-------------|
| `--verify-loop N` | Run `fprintd-verify` N times and report the success rate (requires an enrolled finger). |
| `--any-elan` | Same detection widening as install.sh. |
| `--reenum` | Re-enumerate the sensor (USB unbind/bind) to recover it when it stops reacting to touches. Requires root. |
| `--help` | Show usage. |

## How it works

The sensor ships with USB runtime power management set to `power/control=auto`
with a ~2 s delay, so it autosuspends between fingerprint operations. The
libfprint `elan` driver misbehaves when the device sleeps mid-session — the
symptom is flaky enrollment and random verify failures.

The installer:

1. **Detects the sensor** in `/sys/bus/usb/devices` (USB `04f3:0c6e`).
2. **Installs `fprintd`** and the distro's PAM module via apt/dnf/pacman/zypper
   (skipped if already installed).
3. **Installs a udev rule** at `/etc/udev/rules.d/60-elan-fp-autosuspend.rules`
   that sets `power/control=on` (autosuspend off) for this device only, on every
   boot and hotplug.
4. **Applies the fix immediately** by writing `on` to the sensor's
   `power/control` in sysfs — no reboot needed; the udev rule covers future boots.
5. **Restarts fprintd** and verifies it sees the sensor.
6. **Optionally enables PAM** fingerprint auth — only through each distro's safe
   tool (`pam-auth-update` or `authselect`). The installer **never edits files
   under `/etc/pam.d/` by hand**. On Debian/Ubuntu it ships its own
   `pam-auth-update` profile (`/usr/share/pam-configs/elan-fp-fprintd`) that
   replaces the stock `fprintd` one: **3 fingerprint tries** with a 15 s
   overall budget instead of the distro's single try / 10 s, so a misread
   doesn't dump you straight to the password prompt. `--uninstall` removes
   the profile again.

### Why a driver replacement? (stage 2)

`04f3:0c6e` is a **press-type** imaging sensor (150×52 px). Upstream libfprint
lists it under the legacy `elan` *swipe* driver, which stitches near-identical
frames of a resting finger into garbage templates — enrollment mostly reads
"swipe too short" and verification never matches (known upstream since 2021:
issues #401, #732, #759, #814). The `elanpress` driver treats it as what it
is: it stores several processed touch images at enrollment and matches with
normalized cross-correlation, like the Windows driver does.

`install-driver.sh` pins the exact reviewed commit, overlays this repo's
patched driver, builds on the host (or in a Docker container matching your
distro with `--docker`), stages the install, records a manifest, and shadows
the distro library via `/usr/local` + `ldconfig`. Distro packages stay
untouched and keep updating; `--uninstall` restores stock behavior exactly.

**Security note:** the elanpress matcher's false-accept rate has not been
formally benchmarked (the same reason similar approaches are still unmerged
upstream). Treat fingerprint unlock on this sensor as a convenience, not a
strong credential. Prints enrolled with the stock driver are incompatible —
re-enroll after installing.

**Power-button pre-boot capture:** on Windows this sensor can capture your
finger during the power-on press. That flow is armed by vendor firmware and
has never been reverse-engineered; no Linux support exists. The Linux flow is:
boot → login screen → press the sensor once.

## Turning fingerprint login on and off

Fingerprint authentication activates automatically for any user who has a
finger enrolled, and stays off for everyone else:

- **Enable:** enroll a finger — GNOME Settings → Users → Fingerprint Login,
  or `fprintd-enroll`. Login, unlock, and `sudo` then accept a touch, with
  password always available as fallback.
- **Disable:** delete your enrolled fingers — same Settings panel, or
  `fprintd-delete "$USER"`. No prints, no fingerprint prompt.
- **Disable system-wide:** `sudo ./install.sh --uninstall` reverts the PAM
  change (enrolled prints are kept unless you add `--remove-prints`).

**Retries:** on Debian/Ubuntu the stock `fprintd` PAM profile allows a single
fingerprint attempt (`max-tries=1 timeout=10`) before falling back to
password. This repo ships a replacement profile with `max-tries=3 timeout=15`:
up to three touches, and the 15-second overall budget (pam_fprintd's `timeout`
caps the whole verification, not each try) keeps the password fallback prompt
from being delayed too long when you give up.

## Supported distros

| Distro | Packages | PAM |
|--------|----------|-----|
| Ubuntu / Debian | `fprintd`, `libpam-fprintd` (apt) | Repo profile `elan-fp-fprintd` via `pam-auth-update` (3 tries) |
| Fedora | `fprintd`, `fprintd-pam` (dnf) | `authselect enable-feature with-fingerprint` |
| Arch | `fprintd` (pacman) | Manual — see below |
| openSUSE | `fprintd`, `pam_fprintd` (zypper) | Manual |

Other systemd distros with libfprint should work for the autosuspend fix; if the
package manager is unknown, the installer tells you what to install and continues.

### Arch: enabling PAM manually

Arch has no safe automated PAM tool, so the installer skips this step and you
edit the files yourself. Per the [Arch wiki](https://wiki.archlinux.org/title/Fprint),
add the following line **above** the other `auth` lines:

In `/etc/pam.d/system-local-login` (fingerprint at console/display-manager login):

```
auth      sufficient pam_fprintd.so
```

In `/etc/pam.d/sudo` (fingerprint for sudo):

```
auth      sufficient pam_fprintd.so
```

These are manual edits you make and own — this repo's scripts never touch
`/etc/pam.d/`. Keep a root shell open while testing so a mistake doesn't lock
you out, and remove the lines to revert.

## Troubleshooting

Run the diagnostic script (as your regular user):

```sh
./diagnose.sh
```

It collects system info, sensor power state, whether the fix is installed,
fprintd/libfprint versions, and recent fprintd logs into
`./elan-fp-report-<hostname>-<timestamp>.txt`.

To measure reliability after enrolling a finger:

```sh
./diagnose.sh --verify-loop 10
```

If something is broken, open an issue and attach the report file.

## Uninstall

```sh
sudo ./install.sh --uninstall                  # keep enrolled fingerprints
sudo ./install.sh --uninstall --remove-prints  # delete them too
```

Removes the udev rule, restores autosuspend, and reverts the PAM change (via the
same safe tools). Packages are left installed.

## License

[MIT](LICENSE).
