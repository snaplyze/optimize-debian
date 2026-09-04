# Debian 11/12 → 13 Upgrade Guide

Скрипт `upgrade-to-debian13.sh` предназначен для безопасного обновления **Debian 11 (bullseye)** и **Debian 12 (bookworm)** до **Debian 13 (trixie)** на серверных и минимальных инсталляциях.

**Текущая версия:** `v2.0.3`
**Поддерживаемые сценарии:** `11 → 12 → 13`, `12 → 13`
**Не поддерживается:** WSL2, non-Debian системы, i386

## 🎯 Что делает скрипт

- Определяет текущую версию Debian и выбирает корректный маршрут обновления.
- Делает бэкап APT-конфигурации, списка пакетов и части системного состояния.
- Проверяет свободное место на `/` и отдельных mountpoint'ах `/boot`, `/var/cache/apt/archives`, `/usr`, а также `dpkg --audit`, hold-пакеты, APT pinning и архитектуру.
- Отключает сторонние репозитории, удаляет `backports` и `proposed-updates`.
- Переписывает APT-источники в формате **deb822** для целевого релиза.
- Сохраняет `/etc/ssh`, `authorized_keys`, конфиги firewall и отмечает критичные пакеты как manual, чтобы они не ушли через `autoremove`.
- Выполняет двухэтапное обновление по модели Release Notes: `upgrade` → `full-upgrade`, сохраняя локальные conffiles вместо замены на дефолтные.
- После каждого major-step проверяет `sshd -t`, сервис `ssh` и прослушивание ожидаемых портов.
- Не пытается автоматически переписывать networking-конфиг под конкретный cloud image; сетевые проблемы после ребута диагностируются отдельно на уровне VM.
- Делает финальную очистку, проверяет kernel meta-package и выводит пост-апгрейд рекомендации.

## 📋 Требования

- Debian 11 или Debian 12
- root/sudo доступ
- минимум **5 GB** свободного места на `/`
- стабильный интернет
- при работе по SSH рекомендуется `tmux` или `screen`

Если скрипт обнаружит WSL, неподдерживаемую ОС или критичные проблемы с `dpkg`, он завершится с ошибкой до начала апгрейда.

## 🚀 Запуск

```bash
# Быстрый запуск (bash + curl)
bash <(curl -s https://raw.githubusercontent.com/snaplyze/optimize-debian/main/upgrade-to-debian13.sh)

# Или скачивание
wget https://raw.githubusercontent.com/snaplyze/optimize-debian/main/upgrade-to-debian13.sh
chmod +x upgrade-to-debian13.sh

# Интерактивный режим
sudo ./upgrade-to-debian13.sh

# Автоматический режим без подтверждений.
# На Debian 11 скрипт остановится после 11 -> 12 и попросит reboot.
sudo ./upgrade-to-debian13.sh --yes

# Только для лабораторных стендов: разрешить 11 -> 12 -> 13 без промежуточного reboot
sudo ./upgrade-to-debian13.sh --yes --allow-two-hop-no-reboot
```

## 🔄 Маршрут обновления

### Debian 11 (bullseye)
Скрипт выполняет **двухшаговый** путь:

1. `bullseye → bookworm`
2. `bookworm → trixie`

### Debian 12 (bookworm)
Скрипт выполняет **прямой** переход:

1. `bookworm → trixie`

На каждом шаге сначала обновляется текущий релиз до последней point release, затем записываются новые APT-источники и запускается мажорный апгрейд. Для маршрута `11 → 12 → 13` автоматический режим `--yes` больше не продолжает второй major-hop без ребута; продолжение без промежуточного ребута требует отдельного флага `--allow-two-hop-no-reboot`.

## 💾 Логи и бэкапы

- **Лог выполнения:** `/var/log/debian-upgrade/upgrade-*.log`
- **Бэкап состояния:** `/root/upgrade-backup-*`
- **Отключённые сторонние репозитории:** `/etc/apt/sources.list.d.disabled-*`

Скрипт сохраняет `sources.list`, `sources.list.d`, `preferences`, `dpkg --get-selections`, `apt-cache policy`, `uname -a`, список активных сервисов, `/etc/ssh`, снимки `authorized_keys` и конфиги firewall.

## ⚠️ Важные замечания

- Скрипт рассчитан на **серверные Debian-инсталляции**, а не на WSL2.
- При SSH-апгрейде лучше запускать его внутри `tmux` или `screen`.
- Для маршрута `11 → 12 → 13` безопаснее сделать ребут между major-hop и перезапустить скрипт уже на Debian 12.
- `--allow-two-hop-no-reboot` оставлен для контролируемых лабораторных стендов и не является рекомендуемым production-путём.
- Если после ребута на cloud VM появляется `networking.service failed`, но сам апгрейд завершился успешно, это может быть особенностью образа/VM и требует отдельной диагностики уже на Debian 13.
- Если до апгрейда использовался нестандартный SSH-порт, скрипт проверит, что после обновления он всё ещё слушается.
- Если найдены DSA (`ssh-dss`) ключи в `authorized_keys`, скрипт выдаст предупреждение до обновления.
- После завершения требуется **перезагрузка**.
- После ребута проверьте `uname -r`, `cat /etc/os-release` и `systemctl --failed`.
- Если вам нужны внешние репозитории, верните только действительно необходимые записи после успешного обновления.

## ☁️ Cloud VM / Yandex Cloud notes

- Скрипт больше не пытается автоматически исправлять cloud networking; если после ребута есть сетевые проблемы, сравнивайте состояние VM с чистым образом и диагностируйте `networking.service`, `ifup@eth0.service` и `cloud-init` уже отдельно.
- Если после ребута пропал SSH, сначала проверьте:
  - `cloud-init status --long`
  - `ip -br addr`
  - `ip route`
  - доступность metadata на `169.254.169.254`
- Если metadata недоступна, SSH-ключи могут не примениться. В этом случае сначала восстановите штатную сетевую конфигурацию образа или используйте rescue/serial доступ, а не пытайтесь чинить это через upgrade script.
- Для Yandex Cloud используйте serial console / serial-port output как основной recovery-канал. При полном выпадении сети восстанавливайте boot disk через rescue VM.
- Осторожно с `yc compute instance update --metadata ...`: операция перезаписывает весь metadata payload и может затереть существующие `user-data` / `ssh-keys`, если не передать их заново.

## 🔗 См. также

- **[Главный README](../README.md)** - обзор всех скриптов репозитория
- **[VPS Guide](README_VPS.md)** - оптимизация VPS после перехода на Debian 13
- **[Amnezia Host Guide](README_AMNEZIA_HOST.md)** - подготовка хоста под AmneziaVPN (10G сетевой стек)
- **[Mini PC Guide](README_MINI_PC.md)** - настройка Mini PC после обновления
- **[WSL2 Guide](README_WSL2.md)** - настройка среды WSL2
