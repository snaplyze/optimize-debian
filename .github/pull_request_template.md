<!-- Правила участия: CONTRIBUTING.md. Уязвимости не описывайте в PR, см. SECURITY.md. -->

## Назначение

<!-- Что меняется и зачем. Одно-два предложения. -->

## Issue

Closes #

## Затронутые скрипты

<!-- optimize_vps.sh, optimize_amnezia_host.sh, optimize_mini_pc.sh, optimize_wsl2.sh, upgrade-to-debian13.sh, lib/, tests/, docs/ -->

## Целевое окружение

<!-- VPS, хост AmneziaVPN, мини-ПК, WSL2, обновление Debian 11/12 → 13; версии Debian. -->

## Проверка

Полная проверка из корня репозитория, не от root:

- [ ] `bash -c 'for f in *.sh lib/*.sh tests/*.sh; do bash -n "$f" || exit 1; done'`
- [ ] `shellcheck -- *.sh lib/*.sh tests/*.sh`
- [ ] `bash -c 'for t in tests/*.sh; do bash "$t" || exit 1; done'`
- [ ] `git diff --check origin/main`
- [ ] Ручная проверка измененного пути на одноразовой Debian 12/13 (для `upgrade-to-debian13.sh` — Debian 11/12)

<!-- Где и как проверяли: VM, контейнер с systemd, снимок VPS; фрагменты вывода команд. -->

## Откат и безопасность

<!-- Что скрипт меняет в системе (ядро, пользователи, sudoers, SSH, firewall, sysctl), как откатить, какие резервные копии создаются. -->

## Документация обновлена

- [ ] `README.md` (таблица возможностей и версий)
- [ ] `docs/` (руководство затронутого окружения; `docs/README_UPGRADE.md` при изменении обновления)
- [ ] `CHANGELOG.md`
- [ ] Не требуется: <!-- почему -->
