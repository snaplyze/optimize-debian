# Repository Guidelines

## Сведения о проекте

- Назначение: Bash-скрипты настройки Debian 12/13 под VPS, хост AmneziaVPN, мини-ПК Intel N5095 и WSL2 и обновления Debian 11/12 до 13. Пользователи — администраторы, которые запускают скрипт от root на целевой машине, обычно как `bash <(curl -s https://raw.githubusercontent.com/snaplyze/optimize-debian/main/<script>.sh)`.
- `main` — это релиз: README и `docs/` запускают скрипты прямо из `main`, поэтому слитое туда сразу получают пользователи.
- Каждый `optimize_*.sh` обязан работать одним файлом: `lib/*.sh` подключается, только если читается в `$SCRIPT_DIR/lib`, иначе работают встроенные копии нужных скрипту функций (группами под `if ! declare -F`). Меняешь функцию в `lib/` — меняй ее копии в каждом `optimize_*.sh`: копии сверяет с `lib/` тест `tests/test_embedded_copies.sh`. `upgrade-to-debian13.sh` от `lib/` не зависит.
- Скрипты меняют ядро, пользователей, sudoers, SSH, firewall и sysctl: на рабочей станции не запускай их ни от root, ни через sudo; запуск от root — только на одноразовой Debian-машине. `--help` у `upgrade-to-debian13.sh` и `optimize_amnezia_host.sh` работает без root. `optimize_vps.sh`, `optimize_mini_pc.sh` и `optimize_wsl2.sh` аргументов не разбирают: `--help` игнорируется, и от root скрипт сразу начинает менять систему.
- Быстрый сигнал (около 1 с): `bash -n <файл>` и `bash tests/<затронутый тест>.sh`. `bash -n a.sh b.sh` проверяет только `a.sh`: остальные файлы становятся аргументами.
- Полная проверка перед PR (около 10 с; проверено 2026-10-20 на bash 5.3 и shellcheck 0.11.0), из корня репозитория и не от root, иначе `tests/test_root_privileges_check.sh` пропускается:
  - `bash -c 'for f in *.sh lib/*.sh tests/*.sh; do bash -n "$f" || exit 1; done'`
  - `shellcheck -- *.sh lib/*.sh tests/*.sh`
  - `bash -c 'for t in tests/*.sh; do bash "$t" || exit 1; done'`
  - `git diff --check origin/main`

  CI (`.github/workflows/ci.yml`) выполняет первые три проверки, а пробелы проверяет только в том, что добавляет PR: в старых файлах остались пробелы в конце строк. Временные файлы тестов — только через `mktemp` с удалением: фиксированный путь в общем `/tmp` у раннера под другим пользователем не записывается (`fs.protected_regular`), и тест проходит ложно.
- План: не заведен; задачи — GitHub Issues репозитория `snaplyze/optimize-debian`.
- CI (обнаружено, 2026-10-20): `.github/workflows/ci.yml`, задание `checks` → self-hosted раннер `fedora-mini-s` (Fedora 44, Linux X64, раннер 2.338.0) с метками `[self-hosted, Linux, X64, fedora, project-optimize-debian]`; прогон занимает около 30 с; на раннере нет shellcheck — CI ставит закрепленный релиз сам; организации нет.
- CI (владелец): self-hosted для подходящих заданий — задания, подходящие по меткам, ОС, архитектуре и возможностям, идут на self-hosted, остальные на hosted; подходящее задание на hosted — дефект для исправления. Раннер — по образцу `snaplyze/nucrix`, с меткой `project-<репозиторий>`. Репозиторий публичный: `runs-on` задания `checks` в `ci.yml` направляет на self-hosted только push владельца и PR владельца из этого же репозитория; любой другой источник получает задание на hosted-раннере, и его первый шаг падает до checkout — недоверенный код не проверяется и не исполняется, а `checks` красная, а не пропущенная. Но PR из форка исполняет свой `ci.yml` и может это условие убрать. Граница для форков — настройка репозитория «одобрение запусков для всех внешних участников» (включена владельцем 2026-10-20); запуск из форка не одобряй. Закрепление действий по SHA и список разрешенных действий GitHub здесь не проверяет (решение владельца) — следи за ними в `ci.yml` сам. Действия закрепляй по SHA коммита, инструменты — релизом с SHA-256 в `.github/<tool>.txt`.
- Оркестрация (обнаружено, 2026-10-20): Claude Code — встроенные подагенты (Explore, Plan, general-purpose) и роли плагина `orchestration`: explorer — чтение кода, researcher — первоисточники, worker — реализация, tester — проверки, reviewer — ревью diff; плагин и правило делегирования установлены только у владельца в пользовательских настройках, другим участникам недоступны; в проекте оркестрация не настроена. Codex — не проверено: на машине владельца не установлен.
- Доступ (обнаружено, 2026-10-20): в проекте и управляемых настройках правил доступа нет — режим задают пользовательские настройки участника; секреты: настройками проекта чтение не запрещено. Codex — не проверено.
- Доступ (владелец): широкий неинтерактивный доступ с запретом чтения секретов; задается в пользовательских настройках клиента, а не в настройках проекта.

## Autonomous Local Execution

- Local repository code, config, and documentation edits are pre-authorized when they advance the user's stated goal. Do not ask whether you may edit; inspect, modify, test, and iterate until the goal is achieved.
- Keep safety boundaries for destructive/irreversible actions, credentials/payment/production/external side effects, and material scope changes; otherwise choose the implementation path yourself and report evidence.

## Project Structure & Module Organization
This repository is a Bash toolkit for Debian provisioning and upgrades. The main entry points live at the repo root:

| Script | Target | Supported source OS |
|---|---|---|
| `optimize_vps.sh` | VPS (1–4 GB RAM, 10G VPN workloads, Debian Backports kernel, Fish, Starship, Go, Node.js/fnm, Docker) | Debian 12 and 13 |
| `optimize_amnezia_host.sh` | AmneziaVPN host baseline (10G sysctl, Fish, Starship, optional Debian Backports kernel, vanilla Docker, two-phase UFW) | Debian 12 and 13 |
| `optimize_mini_pc.sh` | Intel N5095 home/media server (Debian Backports kernel, QuickSync, Samba, Fish, Starship, Docker) | Debian 12 and 13 |
| `optimize_wsl2.sh` | WSL2 (systemd, Fish, Starship, NVIDIA/CUDA, ML tuning, dev stack) | Debian 12 and 13 |
| `upgrade-to-debian13.sh` | Guided upgrade of any server Debian installation to 13 with SSH safety checks and backups | Debian 11 or 12 only |

The four `optimize_*.sh` scripts enforce Debian 12 or 13 at startup and exit immediately on any other version.

- `lib/common.sh`: deb822 rendering, WSL config, username validation, unattended-upgrades templates, secure user home resolution (`common_user_home`), atomic sudoers validation (`common_safe_write_sudoers`).
- `lib/tui.sh`: Charmbracelet `gum` installer, backend detection, and modal helpers.
- `tests/`: automated Bash test suite covering hygiene, distro support, TUI, upgrade logic, and profile contracts.
- `README.md`: top-level usage, quickstart, and feature matrix.
- `docs/`: per-environment guides (`README_VPS.md`, `README_AMNEZIA_HOST.md`, `README_MINI_PC.md`, `README_WSL2.md`, `README_UPGRADE.md`).

This project does not build artifacts. Runtime logs are written on target machines under `/var/log/` and must never be committed.

## Coding Style & Naming Conventions
Use Bash consistently. Match the style of the file being edited:

- `optimize_vps.sh` / `optimize_mini_pc.sh` / `optimize_wsl2.sh`: `#!/bin/bash`, `set -e` or `set -Eeuo pipefail`, output helpers `log`, `warn`, `error`, `info`, `progress`, `section`.
- `optimize_amnezia_host.sh`: `#!/usr/bin/env bash`, `set -euo pipefail`, unified clean output helpers.
- `upgrade-to-debian13.sh`: `#!/usr/bin/env bash`, `set -euo pipefail`, minimal output helpers `log`, `warn`, `err`.
- Prefer `#!/usr/bin/env bash` and `set -euo pipefail` in new or heavily refactored scripts unless the file already follows a different established pattern.
- 4-space indentation inside functions and conditionals.
- Lowercase function names such as `wait_for_dpkg_lock`.
- Uppercase variable names for globals and constants such as `LOG_FILE` and `SCRIPT_VERSION`.
- Keep user-facing output explicit and operational; preserve the existing output helpers where present.

Match existing filenames: lowercase, underscore-separated, environment-specific, for example `optimize_wsl2.sh`.

## Key Patterns

- **Logging**: Scripts tee stdout/stderr to a log file at runtime (`/var/log/vps_optimization.log`, `/var/log/debian-upgrade/upgrade-<TS>.log`).
- **Backup before destructive steps**: `upgrade-to-debian13.sh` snapshots APT, SSH, and firewall state to `/root/upgrade-backup-<TS>/` before every major step.
- **SSH safety**: The upgrade script validates `sshd` and port listening after each major Debian version step. Do not remove or bypass these checks.
- **Username validation**: `optimize_vps.sh` and `optimize_mini_pc.sh` include retry loops for username input — preserve this pattern when modifying user-creation logic.
- **Debian Backports kernel**: VPS, mini-PC, and Amnezia host scripts configure `bookworm-backports` on Debian 12 to install the latest official Debian LTS kernel (`linux-image-${ARCH}`, `linux-headers-${ARCH}`). Debian 13 uses its modern mainline kernel.
- **Fish shell + Starship**: All optimize scripts configure Fish shell with the Starship `nerd-font-symbols` preset. User default shell in `/etc/passwd` remains `/bin/bash` for non-interactive POSIX compatibility; interactive sessions auto-switch to Fish via `~/.bashrc`.
- **Atomic Sudoers Validation**: Any changes to `/etc/sudoers.d/*` must use `common_safe_write_sudoers` (or its embedded fallback) to validate syntax via `visudo -cf` on a temporary file before moving it into place; on error the temporary file is removed and the previous file stays unchanged.
- **Reverse Path Filtering**: All optimize scripts configure Loose `rp_filter = 2` (`net.ipv4.conf.all.rp_filter = 2` and `default.rp_filter = 2`) to ensure proper asymmetric packet routing for WireGuard, AmneziaWG, OpenVPN, and Docker bridge interfaces.
- **CUDA**: `optimize_wsl2.sh` uses the official NVIDIA `cuda-keyring` method targeting the detected Debian version (`debian12` or `debian13` for amd64). Do not install broad `cuda` metapackages in WSL.

## Testing Guidelines
There is no automated coverage gate. Minimum validation for every change:

- Run `bash -n` on the edited script.
- Run `shellcheck` on the edited script.
- Exercise the changed code path in the correct target environment: VPS, Mini PC, WSL2, or a Debian upgrade lab. Prefer a VM, VPS snapshot, or fresh WSL2 instance, for example `chmod +x ./optimize_wsl2.sh && sudo ./optimize_wsl2.sh` on a disposable Debian 12/13 environment.
- For upgrade logic, validate on disposable Debian 11/12 systems and confirm backup/log paths such as `/root/upgrade-backup-*` and `/var/log/debian-upgrade/`.

Document manual test notes when behavior depends on Debian 13, Docker, CUDA, kernel packages, SSH, or hardware-specific paths.

## Documentation Expectations
Documentation is part of the change. When behavior, supported OS versions, prerequisites, or safety limits change:

- update `README.md` (feature matrix and version table)
- update the relevant file under `docs/`
- update `docs/README_UPGRADE.md` when upgrade flow or supported Debian versions change

Keep command examples copy-pasteable and keep version references aligned across files.

## Commit & Pull Request Guidelines
Use Conventional Commit prefixes (`feat:` new capabilities, `fix:` bug fixes, `docs:` README and guide updates) with concise imperative wording and the affected script named in the subject:

```
feat: add swap tuning to optimize_mini_pc.sh
fix: remove redundant fi in upgrade-to-debian13.sh
docs: update CUDA install notes in README_WSL2.md
```

PRs should include purpose, affected script(s), target environment, manual validation performed, and rollback or safety notes. Terminal screenshots are optional; command output snippets are usually more useful.
