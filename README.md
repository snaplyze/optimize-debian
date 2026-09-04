# Linux Optimization Scripts Collection

Коллекция скриптов оптимизации и обновления Debian для различных окружений Linux.

## 📁 Скрипты

### 🖥️ VPS Optimization (`optimize_vps.sh`) - v3.0.0
**Назначение:** Оптимизация VPN-серверов на базе Debian (1-4GB RAM, до 10 Гбит/с)
- **Поддерживаемые ОС:** **Debian 12 (Bookworm)** и **Debian 13 (Trixie)**
- **Особенности:** Debian Backports kernel, Fish + Starship, 10G sysctl, Node.js/fnm, Docker, SSH hardening
- **Использование:** `sudo ./optimize_vps.sh`

**Ключевые возможности:**
- 🚀 **Debian Backports kernel** - официальное LTS ядро из `bookworm-backports` (amd64/arm64)
- 🐟 **Fish + Starship** - интерактивный Fish shell со Starship пресетом `nerd-font-symbols`, гибридный запуск (сохраняет `/bin/bash` как login shell)
- ⚡ **10 Gbps Networking** - BBR, fq pacing, адаптивные буферы до 64MB, очереди 32k, conntrack 262k
- 🌐 **VPN-оптимизация** - IP forwarding, persistent modules (`tcp_bbr`, `tun`, `wireguard`), UDP буферы
- 🐳 Docker CE + Docker Compose
- 🔒 SSH hardening и безопасность (Fail2Ban с `python3-systemd`, UFW с `DEFAULT_FORWARD_POLICY="ACCEPT"`, safe sudoers с `visudo -cf`, Loose `rp_filter = 2`)
- 📈 **70+ sysctl параметров** для VPN (WireGuard, OpenVPN, IPsec)
- 🖥️ CPU Governor (`schedutil` для баланса)
- ⏱️ **Time sync hardening:** обнаружение существующего NTP daemon + fallback на `systemd-timesyncd`
- 📊 Расширенный мониторинг утилит

---

### 🔐 Amnezia Host Baseline (`optimize_amnezia_host.sh`) - v0.3.0
**Назначение:** Подготовка Debian 12/13 хоста под AmneziaVPN self-hosted (с тюнингом под каналы до 10 Гбит/с)
- **Поддерживаемые ОС:** **Debian 12 (Bookworm)** и **Debian 13 (Trixie)**
- **Особенности:** 10G sysctl (BBR, fq, 64MB буферы), Fish shell + Starship (Nerd Font preset), Debian Backports kernel (`--kernel-backports`), SSH hardening, swap 2GB, Fail2Ban (с python3-systemd), UFW (с forward ACCEPT), Docker CE (vanilla)
- **Использование:** `sudo ./optimize_amnezia_host.sh --user snaplyze`

**Ключевые возможности:**
- ⚡ **10 Gbps Networking** - BBR, fq pacing, адаптивные BDP буферы (32–64MB), очереди 32k, conntrack 262k
- 🐟 **Fish + Starship** - интерактивный Fish со Starship (`nerd-font-symbols`), гибридный запуск (сохраняет `/bin/bash` как login shell для совместимости с Amnezia App)
- 🚀 **Debian Backports kernel** - опциональная установка свежего официального ядра через `--kernel-backports`
- 🐳 **Vanilla Docker CE** - установка без кастомного `daemon.json` и без systemd override
- 💾 **Swap 2GB по умолчанию** - снижает риск OOM на VPS с небольшим RAM, отключается через `--skip-swap`
- 👤 **Совместимость с app-checks** - целевой пользователь добавляется в группы `sudo` и `docker`
- 👤 **Создание пользователя** - может создать нового operator user и добавить ему `authorized_keys` от invoking sudo user без дублей
- 🔒 **Security baseline** - SSH hardening с выбором порта (`--ssh-port`), Fail2Ban для SSH (`backend = systemd`), UFW с `DEFAULT_FORWARD_POLICY="ACCEPT"`, safe sudoers (`visudo -cf`), Loose `rp_filter = 2`
- ⏱️ **Time sync preserve-first** - сохраняет уже рабочий `ntpsec`/`systemd-timesyncd`, не заменяет daemon без необходимости
- 📡 **Two-phase firewall** - `bootstrap` для первичной установки через app и `locked` после фиксации `8443/udp`
- 🚫 **Без лишнего** - не ставит AmneziaWG/XRay вручную, не тянет Node.js/fnm, Go и heavy VPS tuning

---

### 🏠 Mini PC Optimization (`optimize_mini_pc.sh`) - v2.0.0
**Назначение:** Оптимизация медиа-серверов (Intel N5095 + 16GB RAM)
- **Поддерживаемые ОС:** **Debian 12 (Bookworm)** и **Debian 13 (Trixie)**
- **Особенности:** Debian Backports kernel, Fish + Starship, Intel QuickSync (GPU), Node.js/fnm, SSD тюнинг
- **Использование:** `sudo ./optimize_mini_pc.sh`

**Ключевые возможности:**
- 🔧 **Kernel & Hardware:** Официальное ядро Debian Backports (`bookworm-backports`), CPU governor `schedutil`
- 🎞️ **Media Server Pro:** QuickSync транскодинг, сетевые буферы 32MB для множественных стримов
- 🐟 **Fish + Starship** - современный shell со Starship пресетом `nerd-font-symbols`, гибридный запуск через `.bashrc`
- 💾 **Умный Swap:** 4GB (вместо 8GB) для 16GB RAM
- 📡 **Сеть для стриминга:** TCP Fast Open, оптимизация для Plex/Jellyfin, Loose `rp_filter = 2`
- 🐳 **Full Stack:** Docker, Go, Node.js/fnm, Fish + Starship
- 📂 **Samba:** Безопасный файловый сервер для локальной сети (`server min protocol = SMB2`, NTLMv1 отключен)
- 🛡️ **Security:** UFW, Fail2Ban (с `python3-systemd`), SSH Hardening, safe sudoers (`visudo -cf`)
- ⏱️ **Time sync hardening:** обнаружение существующего NTP daemon + fallback на `systemd-timesyncd`

---

### 🐧 WSL2 Optimization (`optimize_wsl2.sh`) - v4.1.0
**Назначение:** Оптимизация WSL2 для ML/AI (i7-13700K + RTX 4090 + 32GB RAM)
- **Поддерживаемые ОС:** Debian 12 (Bookworm) и Debian 13 (Trixie)
- **Особенности:** Максимальная производительность для ML/AI, GPU computing, разработка, Node.js/fnm
- **Использование:** `sudo ./optimize_wsl2.sh`

**Ключевые возможности:**
- 🐟 **Fish + Starship** - интерактивный Fish shell со Starship пресетом `nerd-font-symbols`, гибридный запуск через `.bashrc`
- 🤖 **ML/AI Optimization:** Transparent Huge Pages, 64MB сетевые буферы, swappiness=1
- 🎮 **RTX 4090 Ready:** CUDA оптимизации, unlimited memlock, shared memory 64GB
- 🔧 WSL2 конфигурация (wsl.conf, systemd, автозапуск Docker)
- 🪟 Windows интеграция (explorer, cmd, powershell)
- 🐹 Go (последняя версия, SHA256 верификация)
- ⬢ Node.js + fnm (LTS, npm без sudo, auto-switching)
- 🐳 Docker CE + NVIDIA Container Toolkit (официальный метод)
- 🧩 Go и Node.js выбираются отдельными пунктами интерактивного меню
- 🎨 **System info fallback** - `fastfetch` → `neofetch` → skip
- 💾 **Агрессивный I/O:** NVMe nr_requests=2048, read-ahead 1024KB
- 📊 WSL2-специфичные утилиты мониторинга
- ✅ **CUDA:** Официальный метод NVIDIA (cuda-keyring + contrib repo)

**⚠️ ВАЖНО:**
- **Строгая проверка версии:** WSL2-скрипт работает только на Debian 12/13
- **Debian 11 и non-Debian не поддерживаются**
- **CUDA path выбирается автоматически:** `debian12` или `debian13`
- **CUDA Toolkit ставится только через NVIDIA toolkit path:** широкий `cuda` metapackage в WSL не используется

---

### ⬆️ Debian Upgrade to 13 (`upgrade-to-debian13.sh`) - v2.0.3
**Назначение:** Безопасное обновление серверных Debian 11/12 инсталляций до Debian 13
- **Поддерживаемые ОС:** **Debian 11 (bullseye)** и **Debian 12 (bookworm)**
- **Ограничения:** Не предназначен для WSL2 и non-Debian систем
- **Использование:** `sudo ./upgrade-to-debian13.sh` или `sudo ./upgrade-to-debian13.sh --yes`

**Ключевые возможности:**
- 🔄 **Маршрут обновления:** автоматический `11 → 12 → 13` или прямой `12 → 13` с явным предупреждением перед вторым major-hop
- 📦 **APT deb822:** переписывание официальных Debian-источников в современном формате
- 🧰 **Подготовка системы:** проверки диска, `dpkg --audit`, hold-пакетов, APT pinning
- 🔒 **Безопасность:** отключение сторонних репозиториев и очистка `backports`/`proposed-updates`
- 🔐 **Remote Access Safety:** сохраняет `/etc/ssh`, `authorized_keys`, состояние firewall и защищает критичные пакеты от `autoremove`
- ✅ **Проверка SSH:** валидирует `sshd`, сервис `ssh` и прослушивание прежних портов после каждого major-step
- ☁️ **Cloud VM Note:** скрипт не переписывает networking под конкретный cloud image и оставляет post-reboot network debugging на уровне VM
- 🚨 **Cloud VPS Warning:** проблемы вида `networking.service failed` после ребута могут быть особенностью cloud image / VM, а не самого upgrade flow
- 💾 **Резервное копирование:** бэкап APT-, SSH- и firewall-состояния в `/root/upgrade-backup-*`
- 📝 **Подробный лог:** полный журнал выполнения в `/var/log/debian-upgrade/`

---

## 🔄 Сравнение скриптов

| Характеристика | VPS Optimization | Amnezia Host Baseline | Mini PC Optimization | WSL2 Optimization |
|---------------|------------------|-----------------------|---------------------|-------------------|
| **Целевое окружение** | VPS серверы | VPS под Amnezia app | Мини-ПК (Home/Media Server) | WSL2 |
| **ОС** | **Debian 12/13** | **Debian 12/13** | **Debian 12/13** | **Debian 12/13** |
| **Ядро** | Debian Backports (LTS) | Стандартное / Backports | Debian Backports (LTS) | WSL2 Linux Kernel |
| **Shell** | **Fish + Starship** | **Fish + Starship** | **Fish + Starship** | **Fish + Starship** |
| **Go** | Последняя версия ✅ | Нет | Последняя версия ✅ | Последняя версия ✅ |
| **Node.js** | LTS + fnm ✅ | Нет | LTS + fnm ✅ | LTS + fnm ✅ |
| **Docker** | Docker CE | Docker CE (опционально, vanilla) | Docker CE | Docker CE |
| **GPU поддержка** | Нет | Нет | Intel QuickSync (транскодинг) | NVIDIA Container Toolkit + CUDA |
| **System info** | - | - | - | **fastfetch → neofetch → skip** |
| **CUDA метод** | - | - | - | **Официальный NVIDIA (cuda-keyring)** |
| **Специфичные функции** | VPN оптимизация | **10G tuning** + Amnezia baseline | Media Server (Plex/Jellyfin) | explorer(), cmd(), powershell() |
| **Swap** | Авто | 2GB по умолчанию | 4GB (для 16GB RAM) | Авто |
| **systemd** | Полная поддержка | Полная поддержка | Полная поддержка | Полная поддержка |
| **Безопасность** | SSH hardening, UFW, Fail2Ban | SSH hardening, UFW, Fail2Ban | UFW, Fail2Ban, SSH Hardening | Базовая безопасность |
| **Samba** | Нет | Нет | Опционально ✅ | Нет |

---

## 🚀 Быстрый старт

### Для VPS:
```bash
# Быстрый запуск (bash + curl)
bash <(curl -s https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_vps.sh)

# Или скачайте и запустите
wget https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_vps.sh
chmod +x optimize_vps.sh
sudo ./optimize_vps.sh
```

### Для AmneziaVPN host baseline:
```bash
# Быстрый запуск (bash + curl)
bash <(curl -s https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_amnezia_host.sh) --user snaplyze --yes

# Или скачайте и запустите минимальный host baseline
wget https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_amnezia_host.sh
chmod +x optimize_amnezia_host.sh

# Рекомендуемый путь: подготовить host и сразу поставить vanilla Docker CE
sudo ./optimize_amnezia_host.sh --user snaplyze --yes

# Если пользователя ещё нет, можно создать его сразу
sudo ./optimize_amnezia_host.sh --user snaplyze --create-user \
  --ssh-public-key 'ssh-ed25519 AAAA... your-key' --yes

# Если swap уже настроен отдельно, можно пропустить его создание
sudo ./optimize_amnezia_host.sh --user snaplyze --skip-swap --yes

# Альтернатива: оставить установку Docker самому приложению Amnezia
sudo ./optimize_amnezia_host.sh --user snaplyze --skip-docker --yes

# После того как AmneziaWG закреплён на 8443/udp, можно ужесточить firewall
sudo ./optimize_amnezia_host.sh --user snaplyze --firewall-phase locked --yes
```

### Для Mini PC:
```bash
# Быстрый запуск (bash + curl)
bash <(curl -s https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_mini_pc.sh)

# Или скачайте и запустите
wget https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_mini_pc.sh
chmod +x optimize_mini_pc.sh
sudo ./optimize_mini_pc.sh
```

### Для WSL2:
```bash
# ⚠️ ВАЖНО: Используйте Debian 12 или Debian 13 под WSL2!

# Подготовка в Windows PowerShell
wsl --update
wsl --set-default-version 2

# Быстрый запуск (bash + curl)
bash <(curl -s https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_wsl2.sh)

# Или скачайте и запустите в WSL2
wget https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_wsl2.sh
chmod +x optimize_wsl2.sh
sudo ./optimize_wsl2.sh
```

### Для обновления Debian 11/12 → 13:
```bash
# Быстрый запуск (bash + curl)
bash <(curl -s https://raw.githubusercontent.com/snaplyze/optimize-debian/main/upgrade-to-debian13.sh)

# Или скачайте и запустите интерактивный апгрейд
wget https://raw.githubusercontent.com/snaplyze/optimize-debian/main/upgrade-to-debian13.sh
chmod +x upgrade-to-debian13.sh
sudo ./upgrade-to-debian13.sh

# Или без интерактивных подтверждений.
# Для Debian 11 скрипт остановится после 11 -> 12, чтобы дать сделать reboot.
sudo ./upgrade-to-debian13.sh --yes

# Только для лабораторных стендов: разрешить 11 -> 12 -> 13 без промежуточного reboot
sudo ./upgrade-to-debian13.sh --yes --allow-two-hop-no-reboot
```

---

## 📋 Подробная документация

- **[VPS Documentation](docs/README_VPS.md)** - Полное руководство по VPS оптимизации
- **[Amnezia Host Documentation](docs/README_AMNEZIA_HOST.md)** - Минимальный baseline под AmneziaVPN self-hosted через приложение
- **[Mini PC Documentation](docs/README_MINI_PC.md)** - Руководство по настройке Intel N5095 (Jasper Lake)
- **[WSL2 Documentation](docs/README_WSL2.md)** - Подробное руководство по WSL2 оптимизации
- **[Debian Upgrade Documentation](docs/README_UPGRADE.md)** - Пошаговое описание обновления Debian 11/12 до 13

## 🔧 Известные исправления

### VSCode Terminal Error (все Remote расширения)
При использовании VSCode Remote (WSL/SSH/Tunnels) может появиться ошибка:
```
__vsc_update_env:6: key: attempt to set associative array to scalar
```

**Автоматически решено в скриптах:** Переход на Fish shell и чистый bashrc полностью устраняет конфликты `__vsc_update_env`.

**Если ошибка осталась:** Закройте все старые терминалы в VSCode и откройте новый (`Ctrl + ~`).

### npm EACCES Error
При установке глобальных пакетов npm может возникнуть ошибка прав доступа.

**Автоматически исправлено в скриптах:** fnm устанавливается в user-local директории, что сохраняет корректные права доступа.
Текущая реализация рассчитана на **чистую ОС** и не пытается мигрировать уже существующие NVM-конфигурации.

**Ручное исправление (если нужно):**
```bash
sudo chown -R $(whoami):$(whoami) ~/.npm
sudo chown -R $(whoami):$(whoami) ~/.local/share/fnm
sudo chown -R $(whoami):$(whoami) ~/.config
```

### WSL2: Debian 12/13 support
Текущая версия `optimize_wsl2.sh` поддерживает **Debian 12 (bookworm)** и **Debian 13 (trixie)**.

**Что важно:**
- CUDA repo path вычисляется автоматически: `debian12` или `debian13`
- Для system info используется fallback `fastfetch -> neofetch -> skip`
- `apt-transport-https` не требуется

### CUDA Installation Fix (v3.0.0)
Исправлена установка CUDA с использованием **официального метода NVIDIA**:
- ✅ cuda-keyring_1.1-1_all.deb (рекомендованный метод)
- ✅ Автоматическое включение contrib репозитория
- ✅ CUDA repo path теперь выбирается динамически: `debian12` или `debian13`
- ✅ Исправлены ошибки GPG ключей (404, missing key)

### fastfetch / neofetch fallback
Скрипт не жёстко зависит от одной утилиты и использует следующий порядок:
- `fastfetch`, если пакет доступен
- иначе `neofetch`
- иначе пропуск без фатальной ошибки

`fastfetch` остаётся предпочтительным вариантом:
- ⚡ Быстрее (написан на C)
- 🔄 Активно поддерживается
- 🎨 Больше возможностей настройки
- 📦 Официально доступен в Debian 13

---

## 🛠️ Системные требования

### Общие требования:
- **ОС:** Linux (Debian/Ubuntu)
- **Права:** root/sudo доступ
- **Память:** Минимум 2GB RAM (рекомендуется 4GB+)
- **Сеть:** Интернет соединение для загрузки пакетов

### VPS специфичные:
- **Архитектура:** x86_64 или arm64
- **Хранилище:** Минимум 10GB свободного места

### WSL2 специфичные:
- **Windows 10/11** с WSL2
- **WSL2 версия:** Последняя
- **Debian:** **Debian 12 (Bookworm)** или **Debian 13 (Trixie)** под WSL2
- **Драйверы:** NVIDIA с WSL поддержкой (опционально для GPU)

### Скрипт обновления Debian:
- **ОС:** Debian 11 (bullseye) или Debian 12 (bookworm)
- **Тип системы:** серверная/минимальная Debian-инсталляция
- **Права:** root/sudo доступ
- **Хранилище:** минимум 5GB свободного места на `/`
- **Важно:** в SSH-сессии рекомендуется `tmux` или `screen`
- **Не поддерживается:** WSL2 и не-Debian окружения

---

## 🔧 Особенности скриптов

### VPS Optimization:
- ✨ **Автоопределение системы** - CPU, RAM, архитектура
- ✨ **Debian Backports kernel** - Свежее официальное LTS ядро Debian
- ✨ **Безопасность** - SSH hardening, Fail2Ban, автообновления
- ✨ **Производительность** - BBR, оптимизация памяти, I/O планировщики
- ✨ **Мониторинг** - Встроенные скрипты наблюдения

### WSL2 Optimization:
- ✨ **Строгая проверка версии** - только Debian 12/13
- ✨ **WSL2 оптимизация** - systemd, wsl.conf, Windows интеграция
- ✨ **Go программирование** - Последняя версия с SHA256 верификацией
- ✨ **Node.js + fnm** - LTS версия, управление версиями, npm без sudo
- ✨ **Интерактивное меню** - Выбор компонентов установки
- ✨ **GPU поддержка** - NVIDIA Container Toolkit + CUDA (официальный метод)
- ✨ **Производительность** - WSL2-специфичные настройки
- ✨ **Удобство** - `fastfetch -> neofetch -> skip`, WSL2-функции, алиасы

---

## 🐳 Docker и Контейнеризация

Все скрипты включают установку и настройку Docker:

### VPS:
- Docker CE с последней версией
- Docker Compose plugin
- Оптимизация daemon.json
- Автоматический запуск сервиса

### WSL2:
- Docker CE с интеграцией WSL2
- **NVIDIA Container Toolkit** (официальный метод)
- **CUDA Toolkit** опционально (cuda-keyring)
- contrib репозиторий автоматически
- Настройка для разработки

---

## 🛠️ Безопасность

### VPS Security:
- SSH hardening (отключение root, только ключи)
- Fail2Ban для защиты от брутфорса
- Автоматические обновления безопасности
- Настройка файрвола (UFW)

### WSL2 Security:
- Базовая безопасность (пользователь с sudo)
- SSH agent конфигурация
- Автоматические обновления

---

## 📊 Мониторинг и Утилиты

### VPS утилиты:
- `vps-monitor.sh` - Системный мониторинг
- `vps-cleanup.sh` - Очистка системы
- `vps-info.sh` - Информация о системе
- `network-test.sh` - Тестирование сети

### WSL2 утилиты:
- `wsl2-monitor.sh` - WSL2 мониторинг
- `wsl2-cleanup.sh` - Очистка WSL2
- `wsl2-backup.sh` - Резервное копирование
- `fastfetch` / `neofetch` - Информация о системе (fallback)
- WSL2-специфичные функции

---

## 🔄 Обновления и Поддержка

### Версионирование:
- **Amnezia Host:** v0.3.0 - **Debian 12/13 support**, 10G sysctl, Fish + Starship (`nerd-font-symbols`), Debian Backports kernel, vanilla Docker CE, safe two-phase firewall
- **VPS:** v3.0.0 - **Debian 12/13 support**, Debian Backports kernel, Fish + Starship (`nerd-font-symbols`), 10G sysctl, Fail2Ban с `python3-systemd`, persistent modules, fnm, Docker CE
- **Mini PC:** v2.0.0 - **Debian 12/13 support**, Debian Backports kernel, Fish + Starship (`nerd-font-symbols`), Fail2Ban с `python3-systemd`, Media Server tuning, Intel QuickSync, fnm
- **WSL2:** v4.1.0 - **Debian 12/13 support**, Fish + Starship (`nerd-font-symbols`), WSL interop functions, optional Go/Node menu toggles, safer CUDA Toolkit path
- **Upgrade:** v2.0.3 - **Debian 11/12 → 13**, deb822, backup, SSH safety checks, no auto networking rewrites

### Разработка и проверка:
```bash
bash -n optimize_vps.sh optimize_mini_pc.sh optimize_wsl2.sh optimize_amnezia_host.sh upgrade-to-debian13.sh lib/*.sh tests/*.sh
shellcheck optimize_vps.sh optimize_mini_pc.sh optimize_wsl2.sh optimize_amnezia_host.sh upgrade-to-debian13.sh lib/*.sh tests/*.sh
for test in tests/test_*.sh; do bash "$test"; done
```

Внутренние helper'ы лежат в `lib/common.sh` и `lib/tui.sh`. TUI сделан в стиле `arch-linux-installer.sh`: основной backend — Charmbracelet `gum`, при необходимости он подтягивается автоматически с проверкой checksum; если `gum` недоступен, используется plain Bash prompt. `dialog`/`whiptail` не выбираются автоматически и доступны только через явный `TUI_BACKEND=dialog|whiptail`. Docker deb822 sources рендерятся через общий helper с `Architectures: $(dpkg --print-architecture)`.

### Обновление:
```bash
# Amnezia Host
wget -O optimize_amnezia_host.sh https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_amnezia_host.sh

# VPS
wget -O optimize_vps.sh https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_vps.sh

# WSL2
wget -O optimize_wsl2.sh https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_wsl2.sh

# Debian 11/12 -> 13 upgrade
wget -O upgrade-to-debian13.sh https://raw.githubusercontent.com/snaplyze/optimize-debian/main/upgrade-to-debian13.sh
```

---

## 🤝 Сообщество

### Поддержка:
- **GitHub Issues** - Сообщения об ошибках
- **GitHub Discussions** - Вопросы и предложения
- **Pull Requests** - Вклад в разработку

### Лицензия:
MIT License - свободное использование и модификация.

---

## 📝 История изменений

### Amnezia Host Baseline v0.3.0 (Текущая) - 2026-09-04
- ⚡ **10 Gbps сетевой стек:** BBR, fq pacing, адаптивные BDP буферы (32–64MB), очереди пакетов (`netdev_max_backlog=32768`, `somaxconn=32768`), conntrack до 262k соединений, ulimits по nofile до 524k
- 🐟 **Fish Shell + Starship:** интерактивный современный shell со Starship и пресетом `nerd-font-symbols`; гибридная интеграция через `~/.bashrc` сохраняет `/bin/bash` в `/etc/passwd`, предотвращая сбои Amnezia App при SSH-автоматизации
- 🚀 **Debian Backports kernel:** опциональное официальное LTS ядро через `--kernel-backports` (amd64/arm64)
- 🔒 **Security & Systemd:** Fail2Ban с установкой `python3-systemd` для journald на Debian 12/13, UFW с `DEFAULT_FORWARD_POLICY="ACCEPT"` для бесшовной маршрутизации VPN
- 🛡️ **Security Audit 2026:** атомарная валидация sudoers (`visudo -cf`), безопасное определение домашних каталогов (`getent passwd`), Loose `rp_filter = 2` для асимметричного VPN-роутинга, современный `KbdInteractiveAuthentication no`
- ⚙️ **CLI флаги:** поддержка `--ssh-port`, `--xray-port`, `--amneziawg-port`, `--skip-fish`, `--kernel-backports` с валидацией портов

### VPS v3.0.0 (Текущая) - 2026-09-04
- 🚀 **Debian Backports kernel:** замена XanMod на официальный репозиторий `bookworm-backports` (LTS ядро, полная поддержка amd64 и arm64)
- 🐟 **Fish + Starship:** интерактивный современный shell со Starship (`nerd-font-symbols`), гибридный запуск через `~/.bashrc` (сохраняет `/bin/bash` в `/etc/passwd`)
- ⚡ **10 Gbps сетевой стек:** адаптивные BDP буферы (rmem/wmem до 64MB), очереди `netdev_max_backlog=32768`, `somaxconn=16384`, conntrack до 262k
- 🛡️ **Безопасность:** Fail2Ban с `python3-systemd`, UFW с `DEFAULT_FORWARD_POLICY="ACCEPT"`
- 🔌 **Persistent Modules:** гарантированная загрузка `tcp_bbr`, `tun`, `wireguard` через `/etc/modules-load.d/`
- 🔒 **Security Audit 2026:** атомарная валидация sudoers (`visudo -cf`), безопасный `getent passwd`, устранение `noexec` с `/tmp` tmpfs, Loose `rp_filter = 2`, современный `KbdInteractiveAuthentication no`, очистка скачанных архивов Go

### Mini PC v2.0.0 (Текущая) - 2026-09-04
- 🚀 **Debian Backports kernel:** замена XanMod на официальный `bookworm-backports` (amd64)
- 🐟 **Fish + Starship:** переход на Fish shell с пресетом `nerd-font-symbols` и гибридным запуском через `~/.bashrc`
- 🛡️ **Fail2Ban:** интеграция `python3-systemd` бэкенда
- 🔒 **Security Audit 2026:** атомарная валидация sudoers (`visudo -cf`), устранение `noexec` с `/tmp`, Loose `rp_filter = 2`, отключение устаревшего NTLMv1 в Samba (`server min protocol = SMB2`), безопасный `getent passwd`

### WSL2 v4.1.0 (Текущая) - 2026-09-04
- 🐟 **Fish + Starship:** переход на Fish shell с пресетом `nerd-font-symbols` и гибридным запуском через `~/.bashrc`
- 🪟 **WSL2 helpers в Fish:** нативные функции `explorer`, `cmd`, `powershell`, `wslperf`, `mkcd`
- ⬢ **fnm интеграция:** хук `fnm env --use-on-cd --shell fish`
- 🎮 **CUDA в Fish Shell:** автоматический экспорт `CUDA_HOME` и `LD_LIBRARY_PATH` в `config.fish`
- 🔒 **Security Audit 2026:** атомарная валидация sudoers (`visudo -cf`), безопасное определение домашних каталогов (`getent passwd`) вместо `eval echo`, Loose `rp_filter = 2` для Docker и сетевых мостов

### WSL2 v4.0.0 (Архив) - 2026-05-11
- ✅ **Опциональные dev toolchains:** Go и Node.js/fnm теперь выбираются отдельными пунктами меню
- ✅ **WSL CUDA safety:** GPU preflight предупреждает, но не роняет весь скрипт; широкий `cuda` metapackage не ставится
- ✅ **Shared helpers:** WSL config, Docker deb822 и unattended-upgrades рендерятся через общий `lib/common.sh`
- ✅ **Gum TUI:** `gum`-style prompts как в `arch-linux-installer.sh`; без автоматического blue-screen `dialog`/`whiptail`

### WSL2 v3.0.0 (Архив) - 2026-02-03
- ✅ **Debian 12/13 support:** bookworm и trixie
- ✅ **CUDA официальный метод:** `cuda-keyring_1.1-1_all.deb` с dynamic distro path
- ✅ **contrib репозиторий:** автоматическое включение
- ✅ **System info fallback:** `fastfetch -> neofetch -> skip`
- ❌ **Удалено:** `apt-transport-https` (устарел, встроен в apt)

### VPS v2.3.0 (Архив) - 2026-02-04
- ✅ **Debian 12/13 support**
- ✅ **Валидация username** с retry при ошибке (числовой, пустой, неверные символы)
- 🔧 **Удалены дубликаты** функций (check_dialog)
- ⚡ **Zsh Ultra-Fast** - fnm auto-switching, VPN-оптимизация

### Mini PC v1.2.0 (Архив) - 2026-02-04
- ✅ **Debian 12/13 support**
- ✅ **Валидация username** с retry при ошибке
- 🎞️ **Media Server Pro** - 32MB буферы, оптимизация для Plex/Jellyfin
- 💾 **Умный Swap** - 4GB для 16GB RAM

### Debian Upgrade v2.0.3 (Текущая) - 2026-04-03
- ✨ **Новый скрипт обновления:** Debian 11/12 → Debian 13 (trixie)
- ✅ **Двухшаговый маршрут:** `bullseye → bookworm → trixie` с явным предупреждением перед продолжением без ребута
- ✅ **deb822-источники:** запись официальных APT sources в современном формате
- ✅ **Проверки безопасности:** диск, `dpkg --audit`, hold-пакеты, pinning, сторонние репозитории
- ✅ **Бэкап и логирование:** сохранение состояния в `/root/upgrade-backup-*` и `/var/log/debian-upgrade/`
- ✅ **SSH/firewall safety:** сохранение `/etc/ssh`, `authorized_keys`, firewall-конфигов и защита пакетов от `autoremove`
- ✅ **cloud image guidance:** notes про serial console / backup restore и про то, что `networking.service` проблемы могут быть VM-specific

### WSL2 v2.2.0 (Архив) - 2025-12-12
- ⚡ **Zsh Ultra-Fast** - терминал загружается на 70-90% быстрее
- 🤖 **ML/AI Optimization** - Transparent Huge Pages, 64MB буферы
- 💾 **Агрессивный I/O** - NVMe: 2048 requests, 1024KB read-ahead

### WSL2 v2.1.2 (Архив) - 2025-11-20
- 🔧 WSL монтирование изменено: `/c/` → `/mnt/c/` (стандарт WSL)

### WSL2 v2.1.0 (Архив) - 2025-11-19
- ✨ **fnm** - единый Node manager для текущих скриптов
- 🔧 **VSCode Terminal fix** - для Remote SSH/Tunnels
- ✨ **npm без sudo** - fnm в user-local окружении

### WSL2 v2.0.0 (Архив)
- ✨ **Go установка** - последняя версия с SHA256 верификацией
- ✨ **Node.js + fnm** - LTS версия
- ✨ Создан WSL2 скрипт с Zsh + Starship
- ✨ NVIDIA Container Toolkit + CUDA поддержка

---

## ⚠️ Важные замечания

### WSL2 v4.0.0 - Debian 12/13
**Текущий подход:**
1. поддерживаются Debian 12 и Debian 13;
2. CUDA repo path выбирается по `VERSION_ID`;
3. `fastfetch` используется только когда пакет доступен;
4. fallback на `neofetch` не ломает запуск на Debian 12;
5. Go и Node.js/fnm можно включать независимо;
6. широкий WSL-пакет `cuda` не используется как fallback.

### CUDA Installation
Теперь используется **официальный метод NVIDIA**:
```bash
# Включение contrib (обязательно для Debian)
add-apt-repository contrib

# Установка keyring пакета (рекомендовано NVIDIA)
wget https://developer.download.nvidia.com/compute/cuda/repos/debian${VERSION_ID}/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb

# Установка CUDA
apt update
apt install cuda-toolkit
```

### fastfetch vs neofetch
Скрипт сначала пытается использовать **fastfetch**, затем **neofetch**, а если ни один пакет недоступен — просто пропускает этот шаг.

`fastfetch` остаётся предпочтительным вариантом:
- Написан на C (намного быстрее)
- Активно поддерживается
- Больше возможностей настройки
- Официально в репозиториях Debian 13

---

**Выберите подходящий скрипт для вашего окружения и начните оптимизацию уже сегодня!** 🚀
