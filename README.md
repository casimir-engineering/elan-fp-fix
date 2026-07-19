# elan-fp-fix

One-command reliability fix for the **Elan `04f3:0c6e`** fingerprint sensor on Linux.

No custom driver. libfprint's stock `elan` driver supports this sensor, but USB
autosuspend puts the device to sleep between operations and makes enrollment and
verification erratic. This repo fixes the autosuspend issue, installs and
configures `fprintd`, and (optionally) enables fingerprint authentication via
PAM — all with one script.

## Quick start

```sh
git clone https://github.com/blackstar-inc/elan-fp-fix.git
cd elan-fp-fix
sudo ./install.sh
fprintd-enroll
```

The installer is idempotent — safe to re-run at any time.

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
| `--pam` | Enable fingerprint authentication (via `pam-auth-update` / `authselect`) without asking. |
| `--no-pam` | Skip the PAM step entirely. |
| `--uninstall` | Remove the udev rule, re-enable autosuspend, revert PAM. Packages are left installed. |
| `--remove-prints` | With `--uninstall` only: also delete enrolled fingerprints (`/var/lib/fprint`). Asks for confirmation unless `--silent`. |
| `--dry-run` | Print what would be done (`[dry-run] would: ...`) without changing anything. Does not require root. |
| `--any-elan` | Widen detection to any Elan (`04f3`) USB device whose product string contains "Fingerprint", not just `0c6e`. |
| `--help` | Show usage. |

### diagnose.sh

| Flag | Description |
|------|-------------|
| `--verify-loop N` | Run `fprintd-verify` N times and report the success rate (requires an enrolled finger). |
| `--any-elan` | Same detection widening as install.sh. |
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
   under `/etc/pam.d/` by hand**.

## Supported distros

| Distro | Packages | PAM |
|--------|----------|-----|
| Ubuntu / Debian | `fprintd`, `libpam-fprintd` (apt) | `pam-auth-update --enable fprintd` |
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
