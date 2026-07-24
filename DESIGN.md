# elan-fp-fix — Design

One-click reliability fix for the Elan `04f3:0c6e` fingerprint sensor on Linux.
Written 2026-07-19, targeting the machine this was diagnosed on (Ubuntu 25.10,
kernel 6.17) but intended to work on any systemd distro with libfprint.

## Problem

libfprint's built-in `elan` (match-on-host) driver claims `04f3:0c6e` and
fprintd lists the device, but enrollment/verification is erratic and setup is
multi-step and distro-specific.

**Prime suspect (confirmed present on this machine):** USB autosuspend. The
sensor sits at `power/control=auto` with a 2 s delay and is suspended at rest;
the elan driver is known to misbehave when the device sleeps between
operations. The system stack is otherwise fully stock (no custom libfprint,
no PPAs).

## Scope

Two stages (stage 2 added 2026-07-19 after live testing):

**Stage 1 — `install.sh`:** udev autosuspend fix + fprintd/PAM setup, one
command. This fixed device flakiness (overheat-disable, mid-enroll
disconnects) but NOT matching.

**Stage 2 — `install-driver.sh`:** live testing showed verify always returns
no-match (0/3). Root cause (confirmed against upstream sources and issues
#401/#732/#814): 0c6e is a press-type imaging sensor misassigned to the
`elan` swipe driver since 2021; it has never matched for anyone; it is not
match-on-chip, so elanmoc is not an option. Fix: build libfprint from
github.com/filip-rs/libfprint branch `elanpress` (pinned commit 34fc394,
security-reviewed 2026-07-19: memory-safe, no malicious code, FAR
unbenchmarked) — a dedicated press driver using ZNCC image correlation.
Installed to /usr/local (ldconfig shadowing), manifest-tracked, fully
revertible; built on the host by default (build deps auto-installed via the
distro package manager), or in Docker with `--docker`.

Out of scope: Windows-style power-button pre-boot capture (vendor firmware,
undocumented, no libfprint support — researched 2026-07-19).

## Components

- **`install.sh`** — the one command:
  1. Detect sensor (`04f3:0c6e` in sysfs; `--any-elan` override for sibling PIDs)
  2. Install `fprintd`/`libfprint` via detected package manager (apt/dnf/pacman/zypper)
  3. Install udev rule, force `power/control=on` immediately (no reboot)
  4. Restart fprintd, verify it sees the device
  5. PAM step (see below)

  Flags: `--silent` (no prompts; implies `--no-pam` unless `--pam` given),
  `--pam` / `--no-pam`, `--uninstall`, `--dry-run`. Idempotent; safe to re-run.
  Interactive runs prompt y/n for PAM.

- **PAM** — only via each distro's safe mechanism: `pam-auth-update`
  (Debian/Ubuntu), `authselect` (Fedora). On Arch (no safe tool) print manual
  instructions. Never hand-edit `/etc/pam.d`.

- **`udev/60-elan-fp-autosuspend.rules`** — disables autosuspend for
  `04f3:0c6e` only.

- **`diagnose.sh`** — collects lsusb/sysfs power state/versions/fprintd debug
  logs into a report file; runs a repeated verify loop to measure reliability
  before/after. Doubles as the test harness proving the fix works.

- **`--uninstall`** — removes udev rule, reverts PAM via the same tools,
  leaves packages and enrolled prints alone (prints removable with a flag).

## Error handling

- No sensor found → name what was searched for, exit cleanly.
- Unknown package manager → print the manual package list.
- PAM tool missing → warn and skip; never hand-edit auth files.

## Testing

- `shellcheck` on all scripts (GitHub Actions CI)
- `--dry-run` mode
- Live verification on this machine: run installer, then the `diagnose.sh`
  verify loop to confirm the erratic behavior is gone (needs real finger
  touches).
