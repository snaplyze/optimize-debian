# Документация optimize-debian

[README](../README.md)

Руководства по скриптам репозитория. Каждое отвечает, что скрипт изменит на машине, как это проверить и как вернуть прежнее состояние. Команды запуска и выбор скрипта — в [README](../README.md); закрепленные выпуски — в разделе [Версии и выпуски](../README.md#версии-и-выпуски).

## Руководства

| Руководство | Для чего | Скрипт | Debian |
|---|---|---|---|
| [VPS](README_VPS.md) | VPS на 1–4 ГБ RAM: ядро из Debian Backports на Debian 12, sysctl под VPN-трафик, Fish и Starship, Go, Node.js (fnm), Docker, SSH hardening, Fail2Ban, UFW | `optimize_vps.sh` | 12, 13 |
| [AmneziaVPN host](README_AMNEZIA_HOST.md) | Базовая настройка хоста под AmneziaVPN: sysctl, Fish и Starship, ядро из Backports по флагу, Docker CE, двухфазный UFW | `optimize_amnezia_host.sh` | 12, 13 |
| [Mini PC](README_MINI_PC.md) | Домашний сервер на Intel N5095: ядро из Backports на Debian 12, QuickSync, Samba, Fish и Starship, Docker | `optimize_mini_pc.sh` | 12, 13 |
| [WSL2](README_WSL2.md) | Debian в WSL2: systemd, Fish и Starship, NVIDIA/CUDA, настройка под ML, стек разработчика | `optimize_wsl2.sh` | 12, 13 |
| [Обновление до Debian 13](README_UPGRADE.md) | Обновление серверной установки Debian 11 или 12 до 13 с бэкапом и проверками SSH | `upgrade-to-debian13.sh` | 11 или 12 → 13 |

Ключевые разделы каждого руководства:

| Руководство | Быстрый старт | Параметры | Файлы на машине | Откат |
|---|---|---|---|---|
| VPS | [Быстрый старт](README_VPS.md#быстрый-старт) | [Параметры запуска](README_VPS.md#параметры-запуска) | [Файлы, которые пишет скрипт](README_VPS.md#файлы-которые-пишет-скрипт) | [Повторный запуск и откат](README_VPS.md#повторный-запуск-и-откат) |
| AmneziaVPN host | [Быстрый старт](README_AMNEZIA_HOST.md#быстрый-старт) | [Параметры запуска](README_AMNEZIA_HOST.md#параметры-запуска) | [Файлы, которые пишет скрипт](README_AMNEZIA_HOST.md#файлы-которые-пишет-скрипт) | [Повторный запуск и откат](README_AMNEZIA_HOST.md#повторный-запуск-и-откат) |
| Mini PC | [Быстрый старт](README_MINI_PC.md#быстрый-старт) | [Параметры запуска](README_MINI_PC.md#параметры-запуска) | [Файлы, которые пишет скрипт](README_MINI_PC.md#файлы-которые-пишет-скрипт) | [Повторный запуск и откат](README_MINI_PC.md#повторный-запуск-и-откат) |
| WSL2 | [Быстрый старт](README_WSL2.md#быстрый-старт) | [Параметры запуска](README_WSL2.md#параметры-запуска) | [Файлы, которые пишет скрипт](README_WSL2.md#файлы-которые-пишет-скрипт) | [Повторный запуск и откат](README_WSL2.md#повторный-запуск-и-откат) |
| Обновление до Debian 13 | [Быстрый старт](README_UPGRADE.md#быстрый-старт) | [Параметры запуска](README_UPGRADE.md#параметры-запуска) | [Логи и бэкапы](README_UPGRADE.md#логи-и-бэкапы) | [Восстановление после сбоя](README_UPGRADE.md#восстановление-после-сбоя) |

> [!WARNING]
> Скрипты меняют ядро, пользователей, sudoers, SSH, firewall и sysctl. Запускайте их от root только на целевой машине; `--help` у всех пяти скриптов работает без root и ничего не меняет.

## Для участников

- [ARCHITECTURE.md](ARCHITECTURE.md) — устройство репозитория: один файл на скрипт и встроенные копии `lib/`, `optimize_main`, `lib/common.sh` и `lib/tui.sh`, тесты, CI, выпуски.
- [CONTRIBUTING.md](../CONTRIBUTING.md) — проверки перед PR, правило копий `lib/`, коммиты и PR, вклад из форков.
- [SECURITY.md](../SECURITY.md) — поддерживаемые версии и как сообщить об уязвимости.
- [CHANGELOG.md](../CHANGELOG.md) — история изменений по выпускам.
- [plan.md](plan.md) — реестр задач и запись хода работ; GitHub Issues — его копия.
- [AGENTS.md](../AGENTS.md) — правила репозитория для участников и агентов.
