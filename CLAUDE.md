# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A collection of Bash scripts and libraries that provision, optimize, and upgrade Debian Linux environments (Debian 12 Bookworm and Debian 13 Trixie). Includes modular helper libraries in `lib/`, per-environment guides in `docs/`, and an automated Bash test suite in `tests/`.

## Commands

```bash
# Syntax-check all scripts and tests
bash -n *.sh lib/*.sh tests/*.sh

# Static analysis
shellcheck *.sh lib/*.sh tests/*.sh

# Run automated test suite
for t in tests/*.sh; do bash "$t"; done

# Check for trailing whitespace before commit
git diff --check

# Verify argument parsing without running the upgrade
sudo ./upgrade-to-debian13.sh --help
```

Run scripts only on disposable targets (VM snapshot, fresh VPS, WSL2 instance). These scripts modify kernels, users, repositories, sysctl, and system configuration.

## Script Architecture

Five entry points at the repo root — each can run standalone via `curl | bash` or locally using `lib/`:

| Script | Target | Supported Source OS |
|---|---|---|
| `optimize_vps.sh` | VPS (1–4 GB RAM, 10G VPN workloads, Debian Backports kernel, Fish, Starship) | Debian 12 and 13 |
| `optimize_amnezia_host.sh` | AmneziaVPN host (10G sysctl, Fish, Starship, optional Debian Backports kernel, vanilla Docker) | Debian 12 and 13 |
| `optimize_mini_pc.sh` | Intel N5095 home/media server (Debian Backports kernel, Fish, Starship, QuickSync, Samba) | Debian 12 and 13 |
| `optimize_wsl2.sh` | WSL2 (Fish, Starship, ML/AI, CUDA, dev stack) | Debian 12 and 13 |
| `upgrade-to-debian13.sh` | Any server Debian installation | Debian 11 or 12 only |

`upgrade-to-debian13.sh` is the only script that accepts Debian 11/12 as input. The four `optimize_*.sh` scripts enforce Debian 12 or 13 at startup and exit immediately on any other version.

Shared libraries:
- `lib/common.sh`: deb822 rendering, WSL config, username validation, unattended-upgrades templates, secure user home resolution (`common_user_home`), atomic sudoers validation (`common_safe_write_sudoers`).
- `lib/tui.sh`: Charmbracelet `gum` installer, backend detection, and modal helpers.
- Root scripts embed fallback implementations of `lib/` helpers so they can execute as single files via `curl | bash`.

## Coding Conventions

Each script can run standalone. Match the style of the file being edited:

- `optimize_vps.sh` / `optimize_mini_pc.sh` / `optimize_wsl2.sh`: use `#!/bin/bash`, `set -e` or `set -Eeuo pipefail`, uppercase globals (`LOG_FILE`, `SCRIPT_VERSION`), lowercase functions (`wait_for_dpkg_lock`), and output helpers: `log`, `warn`, `error`, `info`, `progress`, `section`.
- `optimize_amnezia_host.sh`: uses `#!/usr/bin/env bash`, `set -euo pipefail`, and unified clean output helpers.
- `upgrade-to-debian13.sh`: uses `#!/usr/bin/env bash`, `set -euo pipefail`, and minimal output helpers `log`, `warn`, `err`.
- 4-space indentation inside functions and conditionals.
- Filenames: lowercase, underscore-separated, environment-specific.

## Key Patterns

- **Logging**: Scripts tee stdout/stderr to a log file at runtime (`/var/log/vps_optimization.log`, `/var/log/debian-upgrade/upgrade-<TS>.log`). Log files are written on target machines and must never be committed.
- **Backup before destructive steps**: `upgrade-to-debian13.sh` snapshots APT, SSH, and firewall state to `/root/upgrade-backup-<TS>/` before every major step.
- **SSH safety**: The upgrade script validates `sshd` and port listening after each major Debian version step. Do not remove or bypass these checks.
- **Username validation**: `optimize_vps.sh` and `optimize_mini_pc.sh` include retry loops for username input — preserve this pattern when modifying user-creation logic.
- **Debian Backports kernel**: VPS, mini-PC, and Amnezia host scripts configure `bookworm-backports` on Debian 12 to install the latest official Debian LTS kernel (`linux-image-${ARCH}`, `linux-headers-${ARCH}`). Debian 13 uses its modern mainline kernel.
- **Fish shell + Starship**: All optimize scripts configure Fish shell with the Starship `nerd-font-symbols` preset. User default shell in `/etc/passwd` remains `/bin/bash` for non-interactive POSIX compatibility; interactive sessions auto-switch to Fish via `~/.bashrc`.
- **Atomic Sudoers Validation**: Any changes to `/etc/sudoers.d/*` must use `common_safe_write_sudoers` (or its embedded fallback) to validate syntax via `visudo -cf` before committing, auto-removing the file on error.
- **Reverse Path Filtering**: All optimize scripts configure Loose `rp_filter = 2` (`net.ipv4.conf.all.rp_filter = 2` and `default.rp_filter = 2`) to ensure proper asymmetric packet routing for WireGuard, AmneziaWG, OpenVPN, and Docker bridge interfaces.
- **CUDA**: `optimize_wsl2.sh` uses the official NVIDIA `cuda-keyring` method targeting the detected Debian version (`debian12` or `debian13` for amd64). Do not install broad `cuda` metapackages in WSL.

## Documentation

When changing behavior, supported OS versions, prerequisites, or safety limits, update all three locations:
1. `README.md` (feature matrix and version table)
2. The relevant `docs/README_<TARGET>.md`
3. `docs/README_UPGRADE.md` if the upgrade flow changes

Keep command examples copy-pasteable and version references consistent across files.

## Commit Style

Use Conventional Commit prefixes with the affected script named in the subject:

```
feat: add swap tuning to optimize_mini_pc.sh
fix: remove redundant fi in upgrade-to-debian13.sh
docs: update CUDA install notes in README_WSL2.md
```
