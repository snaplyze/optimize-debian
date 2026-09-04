# Repository Guidelines

## Autonomous Local Execution

- Local repository code, config, and documentation edits are pre-authorized when they advance the user's stated goal. Do not ask whether you may edit; inspect, modify, test, and iterate until the goal is achieved.
- Keep safety boundaries for destructive/irreversible actions, credentials/payment/production/external side effects, and material scope changes; otherwise choose the implementation path yourself and report evidence.

## Project Structure & Module Organization
This repository is a Bash toolkit for Debian provisioning and upgrades. The main entry points live at the repo root:

- `optimize_vps.sh`: complete VPS optimization (Debian 12/13, Debian Backports kernel, Fish, Starship, Go, Node.js/fnm, Docker).
- `optimize_amnezia_host.sh`: dedicated AmneziaVPN host baseline (Debian 12/13, 10G sysctl, Fish, Starship, optional Debian Backports kernel, vanilla Docker, two-phase UFW).
- `optimize_mini_pc.sh`: home/media server optimization (Debian 12/13, Debian Backports kernel, Intel N5095, QuickSync, Samba, Fish, Starship, Docker).
- `optimize_wsl2.sh`: WSL2 environment optimization (Debian 12/13, systemd, Fish, Starship, NVIDIA/CUDA, ML tuning, dev stack).
- `upgrade-to-debian13.sh`: guided Debian 11/12 to 13 upgrade flow with SSH safety checks and backups.
- `lib/`: shared helper scripts (`lib/common.sh` for config rendering/validation, `lib/tui.sh` for Charm Gum integration; standalone fallbacks embedded in root scripts).
- `tests/`: automated Bash test suite covering hygiene, distro support, TUI, upgrade logic, and profile contracts.
- `README.md`: top-level usage, quickstart, and feature matrix.
- `docs/`: per-environment guides (`README_VPS.md`, `README_AMNEZIA_HOST.md`, `README_MINI_PC.md`, `README_WSL2.md`, `README_UPGRADE.md`).

Runtime logs are written on target machines under `/var/log/` and must never be committed.

## Build, Test, and Development Commands
This project does not build artifacts. Contributors validate shell syntax, safety, test assertions, and docs consistency.

- `bash -n *.sh lib/*.sh tests/*.sh`: syntax check all scripts.
- `shellcheck *.sh lib/*.sh tests/*.sh`: static analysis for Bash issues.
- `for t in tests/*.sh; do bash "$t"; done`: execute automated test suite.
- `git diff --check`: catch trailing whitespace and malformed patch output before commit.
- `chmod +x ./optimize_wsl2.sh && sudo ./optimize_wsl2.sh`: run a target script on a disposable Debian 12/13 environment.
- `sudo ./upgrade-to-debian13.sh --help`: verify argument parsing without starting an upgrade.

Prefer testing in a VM, VPS snapshot, or fresh WSL2 instance. These scripts change packages, users, kernels, repositories, and system configuration; do not use a production host as your first test target.

## Coding Style & Naming Conventions
Use Bash consistently. Follow the existing style:

- 4-space indentation inside functions and conditionals.
- Lowercase function names such as `wait_for_dpkg_lock`.
- Uppercase variable names for globals and constants such as `LOG_FILE` and `SCRIPT_VERSION`.
- Prefer `#!/usr/bin/env bash` and `set -euo pipefail` in new or heavily refactored scripts unless the file already follows a different established pattern.
- Keep user-facing output explicit and operational; preserve the existing `log`, `warn`, `error`, `info`, and `progress` helpers where present.

Match existing filenames: lowercase, underscore-separated, environment-specific, for example `optimize_wsl2.sh`.

## Testing Guidelines
There is no automated coverage gate. Minimum validation for every change:

- Run `bash -n` on the edited script.
- Run `shellcheck` on the edited script.
- Exercise the changed code path in the correct target environment: VPS, Mini PC, WSL2, or a Debian upgrade lab.
- For upgrade logic, validate on disposable Debian 11/12 systems and confirm backup/log paths such as `/root/upgrade-backup-*` and `/var/log/debian-upgrade/`.

Document manual test notes when behavior depends on Debian 13, Docker, CUDA, kernel packages, SSH, or hardware-specific paths.

## Documentation Expectations
Documentation is part of the change. When behavior, supported OS versions, prerequisites, or safety limits change:

- update `README.md`
- update the relevant file under `docs/`
- update `docs/README_UPGRADE.md` when upgrade flow or supported Debian versions change

Keep command examples copy-pasteable and keep version references aligned across files.

## Commit & Pull Request Guidelines
Recent history uses short imperative subjects, often with Conventional Commit prefixes, for example `feat: add Debian 11/12 → 13 (trixie) upgrade script v2.0.0` and `fix: remove redundant 'fi' ...`. Prefer:

- `feat: ...` for new capabilities
- `fix: ...` for bug fixes
- `docs: ...` for README and guide updates
- concise imperative wording with the affected script named

PRs should include purpose, affected script(s), target environment, manual validation performed, and rollback or safety notes. Terminal screenshots are optional; command output snippets are usually more useful.
