# elan-fp-fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Tasks 1–4 are independent and MAY run in parallel (disjoint files). Parallel workers MUST NOT run `git commit` — the orchestrator commits after review.

**Goal:** One-command reliability fix for the Elan `04f3:0c6e` fingerprint sensor on Linux (udev autosuspend fix + fprintd/PAM setup + diagnostics).

**Architecture:** Pure shell. Two self-contained scripts (`install.sh`, `diagnose.sh`) plus a udev rule, README, and shellcheck CI. No driver code — we make the stock libfprint `elan` driver reliable. Scripts are deliberately self-contained (detection helper duplicated, ~12 lines) so each can be downloaded standalone; this is an intentional DRY exception.

**Tech Stack:** Bash (`#!/usr/bin/env bash`, `set -euo pipefail`), udev, systemd, fprintd, pam-auth-update/authselect, GitHub Actions + shellcheck.

## Global Constraints

- Target device: USB `04f3:0c6e` (`--any-elan` widens to any `04f3` device whose product string contains `Fingerprint`).
- Never hand-edit files under `/etc/pam.d/` — only `pam-auth-update` (Debian/Ubuntu) or `authselect` (Fedora); on Arch/unknown, print manual instructions and skip.
- All scripts idempotent — safe to re-run.
- All scripts pass `shellcheck -S style` and `bash -n`.
- User-facing status lines use `✔` (ok), `✖` (fail), `→` (next step / action), `!` (warning).
- Exit codes: 0 success, 1 generic failure, 2 sensor not found, 3 unsupported/missing tool where fatal.
- udev rule installs to `/etc/udev/rules.d/60-elan-fp-autosuspend.rules` (source: `udev/60-elan-fp-autosuspend.rules`).

## Shared interface: sensor detection (duplicated in both scripts)

```bash
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
```

---

### Task 1: udev rule + install.sh

**Files:**
- Create: `udev/60-elan-fp-autosuspend.rules`
- Create: `install.sh` (mode 755)

**Interfaces:**
- Consumes: nothing.
- Produces: `install.sh` CLI: `--silent`, `--pam`, `--no-pam`, `--uninstall`, `--remove-prints` (only with `--uninstall`), `--dry-run`, `--any-elan`, `--help`. udev rule at the path in Global Constraints. README (Task 3) documents exactly these.

- [ ] **Step 1: Write the udev rule** — exact content:

```
# elan-fp-fix: disable USB autosuspend for the Elan 04f3:0c6e fingerprint
# sensor. The libfprint "elan" driver misbehaves when the device autosuspends
# between operations.
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="04f3", ATTR{idProduct}=="0c6e", ATTR{power/control}="on"
```

- [ ] **Step 2: Write install.sh.** Structure and required behavior:

1. `#!/usr/bin/env bash`, `set -euo pipefail`. Resolve `SCRIPT_DIR` via `${BASH_SOURCE[0]}`.
2. Arg parse (`while` + `case`). Unknown flag → usage to stderr, exit 1. `--help` prints usage, exit 0. `--remove-prints` without `--uninstall` → error, exit 1.
3. `--dry-run`: every mutating step prints `[dry-run] would: <command>` instead of executing; detection and checks still run. Implement as `run() { if $DRY_RUN; then echo "[dry-run] would: $*"; else "$@"; fi; }` and route ALL mutations through `run`.
4. Root check: if EUID != 0 and not `--dry-run`/`--help` → `✖ must run as root (try: sudo ./install.sh)`, exit 1.
5. Detect sensor with `find_sensor` (honor `--any-elan` via `ANY_ELAN=1`). Not found → `✖ no Elan fingerprint sensor found (looked for USB 04f3:0c6e in /sys/bus/usb/devices; retry with --any-elan for other Elan PIDs)`, exit 2.
6. Package install: detect manager in order apt-get/dnf/pacman/zypper. Skip if `fprintd-enroll` already in PATH (`✔ fprintd already installed`). Commands: `apt-get install -y fprintd libpam-fprintd`, `dnf install -y fprintd fprintd-pam`, `pacman -S --noconfirm --needed fprintd`, `zypper install -y fprintd pam_fprintd`. Unknown manager → `! unknown package manager — install these yourself: fprintd + PAM module` and continue (not fatal).
7. Install udev rule: copy from `$SCRIPT_DIR/udev/` to `/etc/udev/rules.d/`, then `udevadm control --reload-rules`, `udevadm trigger --subsystem-match=usb --attr-match=idVendor=04f3`.
8. Immediate fix (no reboot): `run bash -c 'echo on > "$SENSOR/power/control"'`; report `✔ autosuspend disabled (immediately and via udev rule for future boots)`.
9. Restart fprintd: `systemctl restart fprintd.service || true` (it's D-Bus activated; failure non-fatal). Verify device visible: `timeout 15 fprintd-list root >/dev/null 2>&1` — fprintd-list exits 0 with "no fingers enrolled" when the device exists; if it fails → `! fprintd does not see the sensor — run ./diagnose.sh` (warning, not fatal).
10. PAM step: skip entirely with `--no-pam` or (`--silent` without `--pam`). `--pam` → do it. Interactive (neither flag, no `--silent`) → prompt `Enable fingerprint authentication for login/sudo? [y/N]` reading from `/dev/tty`. Doing it: Debian/Ubuntu → `pam-auth-update --enable fprintd`; Fedora → `authselect enable-feature with-fingerprint`; else → `! no safe PAM tool found — enable manually, see README` (skip, never edit /etc/pam.d).
11. Finish: `→ enroll a finger now: fprintd-enroll $SUDO_USER` (fall back to `<your-username>` if `SUDO_USER` unset).
12. `--uninstall`: remove `/etc/udev/rules.d/60-elan-fp-autosuspend.rules`, reload udev, `echo auto > $SENSOR/power/control` (if sensor present), revert PAM via `pam-auth-update --remove fprintd` / `authselect disable-feature with-fingerprint` (only if tool exists), leave packages alone. With `--remove-prints`: `rm -rf /var/lib/fprint/*` after a y/N confirm on `/dev/tty` (skip confirm under `--silent`). Print `✔ uninstalled (packages left installed)`.

- [ ] **Step 3: Verify** — `bash -n install.sh`, `shellcheck -S style install.sh` clean; `./install.sh --help` exits 0; `./install.sh --dry-run` as non-root runs detection and prints `[dry-run]` lines, no writes; `./install.sh --remove-prints` errors. DO NOT commit.

### Task 2: diagnose.sh

**Files:**
- Create: `diagnose.sh` (mode 755)

**Interfaces:**
- Consumes: udev rule path from Global Constraints (reports whether installed).
- Produces: CLI: `diagnose.sh [--verify-loop N] [--any-elan] [--help]`. Report written to `./elan-fp-report-$(hostname)-$(date +%Y%m%d-%H%M%S).txt` and path printed at end. README documents exactly this.

- [ ] **Step 1: Write diagnose.sh.** Runs as regular user; uses `sudo -n` opportunistically for journal access (falls back with a note if unavailable). Contains the same `find_sensor` as Task 1. Report sections, each a labeled block written via a `section() { printf '\n===== %s =====\n' "$1"; }` helper, with all output `tee`'d to the report file:
  1. **System** — `uname -a`, `/etc/os-release` PRETTY_NAME.
  2. **Sensor** — `lsusb | grep -i 04f3` (or note if missing), sysfs path from `find_sensor`, and for that path: `power/control`, `power/autosuspend_delay_ms`, `power/runtime_status`.
  3. **Fix state** — whether `/etc/udev/rules.d/60-elan-fp-autosuspend.rules` exists (`✔ udev rule installed` / `✖ udev rule NOT installed`), and whether `power/control` is `on`.
  4. **Software** — versions of fprintd/libfprint via `dpkg -l | grep -i fprint` or `rpm -qa | grep -i fprint` or `pacman -Q | grep -i fprint` (whichever exists).
  5. **fprintd view** — `fprintd-list "$USER"` output verbatim.
  6. **Recent logs** — `journalctl -u fprintd --no-pager -n 50` via `sudo -n`, else user journal, else `! journal not readable without sudo`.
  7. **Verify loop** (only with `--verify-loop N`): requires an enrolled finger (check `fprintd-list "$USER"` doesn't say "no fingers enrolled"; otherwise `✖ enroll first: fprintd-enroll`, skip loop). Loop N times: run `fprintd-verify`, count exit 0 as pass, else fail; print running `[i/N] pass|fail`; end with `✔ verify success rate: P/N` plus `!` warning if < 100%.

- [ ] **Step 2: Verify** — `bash -n`, `shellcheck -S style` clean; running `./diagnose.sh` produces a report file with sections 1–6 populated on this machine. DO NOT commit.

### Task 3: README.md

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: exact CLI surfaces from Tasks 1–2 (flags listed there) and udev rule path.
- Produces: user documentation; no code contract.

- [ ] **Step 1: Write README.md** with sections: what it is (one-click fix for erratic Elan 04f3:0c6e fingerprint sensor on Linux; no custom driver — fixes USB autosuspend that breaks libfprint's elan driver, installs/configures fprintd + optional PAM); Quick start (`git clone`, `sudo ./install.sh`, `fprintd-enroll`); Silent install (`sudo ./install.sh --silent --pam`); all flags in a table (both scripts); How it works (autosuspend explanation, what the udev rule does, why no reboot needed); Supported distros (Ubuntu/Debian, Fedora, Arch — PAM manual on Arch with the exact `/etc/pam.d` lines the Arch wiki recommends, quoted as *manual* instructions); Troubleshooting (run `./diagnose.sh`, attach report to an issue); Uninstall (`sudo ./install.sh --uninstall [--remove-prints]`); License note (MIT).
- [ ] **Step 2: Create `LICENSE`** (MIT, copyright 2026 Raphael / blackstar.inc contributors — use "elan-fp-fix contributors").
- [ ] **Step 3: Verify** — README mentions every flag from Tasks 1–2, no others. DO NOT commit.

### Task 4: CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: script filenames `install.sh`, `diagnose.sh`.
- Produces: CI that fails on shellcheck findings.

- [ ] **Step 1: Write ci.yml** — trigger on push + pull_request; single job on ubuntu-latest: checkout, run `shellcheck -S style install.sh diagnose.sh`, run `bash -n install.sh diagnose.sh`, and `test -x install.sh -a -x diagnose.sh`.
- [ ] **Step 2: Verify** — YAML parses (`python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"`). DO NOT commit.

### Task 5: Integration & live verification (orchestrator, after 1–4)

- [ ] Review all files; `shellcheck -S style install.sh diagnose.sh` and `bash -n` both clean.
- [ ] `./install.sh --dry-run` as non-root: detection succeeds on this machine, `[dry-run]` lines for every mutation.
- [ ] Commit everything as logical commits.
- [ ] Live: `sudo ./install.sh` (interactive PAM prompt → user decides), then `./diagnose.sh` report shows `✔ udev rule installed` and `power/control: on`.
- [ ] Ask user to enroll + run `./diagnose.sh --verify-loop 10` to measure reliability (needs finger touches).
- [ ] Commit any fixes; done.

## Self-review notes

- Spec coverage: detection/override ✔ (T1.5), packages ✔ (T1.6), udev+immediate fix ✔ (T1.7–8), fprintd verify ✔ (T1.9), PAM policy + silent semantics ✔ (T1.10), uninstall ✔ (T1.12), diagnose + verify loop ✔ (T2), README ✔ (T3), shellcheck CI ✔ (T4), live verification ✔ (T5).
- Duplicated `find_sensor` is an intentional, documented DRY exception (standalone-downloadable scripts).
- TDD exception: shell installer against live hardware — verification is `--dry-run`, shellcheck, and the Task 5 live run instead of unit tests; diagnose.sh doubles as the test harness per DESIGN.md.
