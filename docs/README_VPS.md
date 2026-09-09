# VPS Optimization Script for Debian 12/13

Комплексный скрипт оптимизации VPS серверов на базе **Debian 12 (Bookworm)** и **Debian 13 (Trixie)** с Debian Backports kernel, Fish + Starship, Go, Node.js/fnm, Docker, 10G sysctl и усиленной безопасностью.

**🆕 Версия 3.0.0** - **Debian Backports kernel**, **Fish + Starship** (`nerd-font-symbols`), **10G sysctl** (до 64MB буферы), Fail2Ban с `python3-systemd`, persistent modules.
**📦 Версия 2.3.0** - Debian 12/13 support, fnm, deb822-aware APT enrichment, `linux-cpupower`.
**📦 Версия 2.2.0** - Zsh Ultra-Fast (архив)

## 🎯 Ключевые особенности

### 🚀 Debian Backports Kernel
- **Официальный репозиторий** - `bookworm-backports` на Debian 12 обеспечивает установку самого свежего официального стабильного LTS ядра Debian
- **Мультиархитектурность** - полная поддержка x86_64 (`amd64`) и ARM64 (`arm64`)
- **Стабильность и безопасность** - ядро подписано официальными ключами Debian, совместимо со всеми модулями (WireGuard, TUN/TAP, BBR)
- **Debian 13** - использует современное upstream ядро из основного репозитория

### 🐟 Fish Shell + Starship Prompt
- **Fish shell** - современный дружелюбный шелл из коробки: умные автодополнения, подсветка синтаксиса, быстрый поиск по истории
- **Starship Prompt** - единый быстрый промпт с пресетом `nerd-font-symbols`
- **fnm hook** - нативная интеграция Fast Node Manager (`fnm env --use-on-cd --shell fish`)
- **Гибридный запуск** - пользовательский шелл в `/etc/passwd` остаётся стандартным `/bin/bash` для 100% совместимости с SSH-скриптами, scp/rsync, cron и автоматизацией; интерактивные сессии прозрачно запускают Fish через `~/.bashrc`
- **Системные алиасы** - Docker, Git, мониторинг, навигация

### ⚡ 10 Gbps Networking & VPN Tuning
- **BBR & fq** - алгоритм контроля перегрузок BBR с планировщиком `fq`
- **Адаптивные буферы** - до 64MB TCP/UDP буферы (`rmem_max=67108864`) для максимального BDP на 10G каналах
- **Сетевые очереди** - `netdev_max_backlog = 32768`, `somaxconn = 16384`
- **Persistent Modules** - автозагрузка `tcp_bbr`, `tun`, `wireguard` через `/etc/modules-load.d/`
- **VPN Routing** - UFW с `DEFAULT_FORWARD_POLICY="ACCEPT"` и IP forwarding

### 🐹 Go язык программирования
- **Последняя версия** - автоматическое определение и установка
- **SHA256 верификация** - безопасная загрузка
- **Архитектура** - автоопределение (x86_64, ARM и т.д.)
- **PATH конфигурация** - сразу готово к использованию

### ⬢ Node.js с fnm
- **Fast Node Manager (fnm)** - быстрый нативный менеджер версий Node.js
- Автоматическая установка последней LTS версии для root и целевого пользователя
- `corepack enable` для pnpm/yarn, где доступно

## 📋 Системные требования

- **ОС:** **Debian 12 (Bookworm)** или **Debian 13 (Trixie)**
- **Архитектура:** x86_64 (amd64) или ARM64 (arm64)
- **Права:** root/sudo доступ
- **Память:** Минимум 2GB RAM (рекомендуется 4GB+)
- **Хранилище:** Минимум 10GB свободного места
- **Сеть:** Интернет соединение для загрузки пакетов

> Если сервер ещё на Debian 11, сначала выполните [`upgrade-to-debian13.sh`](README_UPGRADE.md). На Debian 12 и Debian 13 `optimize_vps.sh` можно запускать напрямую.

## 🛠️ Установка и использование

### Быстрый запуск
```bash
# Быстрый запуск (bash + curl)
bash <(curl -s https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_vps.sh)

# Или скачайте и запустите
wget https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_vps.sh
chmod +x optimize_vps.sh
sudo ./optimize_vps.sh
```

### Подготовка системы
```bash
# Обновите систему
sudo apt update && sudo apt upgrade -y

# Проверьте архитектуру
uname -m
# Должно быть x86_64

# Проверьте версию ОС
lsb_release -a
```

## 🎯 Компоненты оптимизации

### Системная конфигурация
- ✅ Обновление системы до последней версии
- ✅ Удаление ненужных пакетов
- ✅ Настройка репозиториев
- ✅ Создание пользователя с sudo
- ✅ Генерация обеих локалей `ru_RU.UTF-8` и `en_US.UTF-8` для SSH; меню выбирает язык по умолчанию. `update-locale` использует штатный файл Debian 12/13, постоянный `LC_ALL` не задаётся. [Исправление на уже настроенном сервере](README_AMNEZIA_HOST.md#ошибка-setlocale-при-входе-по-ssh).
- ✅ Настройка часового пояса
- ✅ Проверка существующего NTP daemon и fallback на `systemd-timesyncd`
- ✅ Диагностика после auto-enrichment APT sources

### Ядро и производительность
- ✅ Debian Backports kernel (`bookworm-backports`) для Debian 12 / Mainline для Debian 13
- ✅ 10G sysctl оптимизация (BBR, fq, буферы до 64MB, очереди 32k)
- ✅ Persistent modules (`/etc/modules-load.d/99-vps-modules.conf` с `tcp_bbr`, `tun`, `wireguard`)
- ✅ I/O планировщики (SSD/NVMe)
- ✅ Управление памятью (swappiness)
- ✅ Увеличение лимитов файлов

### Безопасность
- ✅ SSH hardening (только ключи, отключение root)
- ✅ Fail2Ban настройка (с `backend = systemd` через `python3-systemd`)
- ✅ UFW firewall с `DEFAULT_FORWARD_POLICY="ACCEPT"` для VPN
- ✅ Автоматические обновления безопасности
- ✅ Настройка логирования

### Разработка
- ✅ Fish + Starship конфигурация (пресет `nerd-font-symbols`)
- ✅ Гибридный запуск (сохраняет `/bin/bash` в `/etc/passwd`, auto-switch в `~/.bashrc`)
- ✅ Go (последняя версия с SHA256 верификацией)
- ✅ Node.js + fnm (LTS с управлением версиями через `fnm env --shell fish`)
- ✅ Базовые утилиты (git, curl, htop, fzf, bat, cmake, gcc)
- ✅ SSH agent конфигурация
- ✅ Настройка окружения

### Контейнеризация
- ✅ Docker CE установка
- ✅ Docker Compose plugin
- ✅ Docker deb822 source с `Architectures: $(dpkg --print-architecture)`
- ✅ Оптимизация daemon.json
- ✅ Настройка сетей и пулов адресов

### Интерфейс запуска
- ✅ Визуальные элементы используют Charmbracelet `gum` в стиле `arch-linux-installer.sh`
- ✅ Если `gum` недоступен, используется plain Bash fallback; `dialog`/`whiptail` не выбираются автоматически
- ✅ Общие renderer/helper-функции вынесены в `lib/common.sh` и `lib/tui.sh`

## 🎨 Fish + Starship особенности

### Преимущества Fish
- **Автодополнения из коробки** - умный автокомплит по истории и man-страницам без сторонних плагинов
- **Подсветка синтаксиса** - нативная подсветка команд и путей в реальном времени
- **Высокая скорость** - мгновенный запуск без компиляции rc-файлов
- **Starship пресет** - единый официальный пресет `nerd-font-symbols`
- **Совместимость** - шелл пользователя в `/etc/passwd` остаётся `/bin/bash`; авто-переключение в Fish происходит только в интерактивных сессиях

### Starship prompt
- 🌱 Git статус и ветка
- 🐋 Docker контекст
- 🐍 Python, ⬢ Node.js, 🐹 Go, 🦀 Rust версии
- ⏰ Время выполнения команд
- 💾 Использование памяти и диска

### Алиасы
```bash
# Docker
d='docker'
dc='docker compose'
dps='docker ps'
dcl='docker compose logs -f'

# Git
g='git'
gs='git status'
gcm='git commit -m'
gl='git log --oneline --graph'

# Система
ll='ls -alFh'
update='sudo apt update && sudo apt upgrade -y'
meminfo='free -h'
diskinfo='df -h'
```

## 🐹 Go программирование

### Установка
- Автоматическое определение последней версии с go.dev
- SHA256 верификация для безопасности
- Установка в `/usr/local/go`
- Автоматическая конфигурация PATH

### Использование
```bash
# Go сразу доступен
go version
go mod init example.com/hello
go run main.go

# Переменные окружения
echo $GOPATH     # $HOME/go
echo $GOROOT     # /usr/local/go
```

### Конфигурация
- `/etc/profile.d/golang.sh` - глобальная конфигурация для всех shells
- `~/.config/fish/config.fish` и `~/.bashrc` - локальная конфигурация для Fish и Bash (автоматически добавляется)

## ⬢ Node.js с fnm

### fnm установка
- **Fast Node Manager (fnm)** - быстрый нативный менеджер версий Node.js
- Установка без модификации shell rc файлов со стороны инсталлятора
- Автоматическая установка последней LTS версии
- `corepack enable` для pnpm/yarn, где доступно
- Установка для root и целевого пользователя
- Текущая реализация рассчитана на **чистую ОС** и не выполняет миграцию старых NVM-конфигураций

### Node.js версии
- Автоматическая установка последней LTS версии
- Простое переключение между версиями: `fnm use 18`, `fnm use 20`
- npm install работает БЕЗ sudo

### Использование
```bash
# Проверка версии
fnm --version
node --version
npm --version

# Управление версиями
fnm list
fnm install 18
fnm use 18
fnm default 18

# npm без sudo
npm install -g some-package
npm install
```

### fnm конфигурация
```fish
# ~/.config/fish/config.fish автоматически содержит:
if test -d "$HOME/.local/share/fnm"
    set -gx FNM_PATH "$HOME/.local/share/fnm"
    fish_add_path -g "$FNM_PATH"
end
if command -v fnm >/dev/null 2>&1
    fnm env --use-on-cd --shell fish | source
end
```

## 🚀 Debian Backports Kernel

### Особенности
- **Стабильность** - официальные пакеты ядра Debian LTS (`linux-image-${ARCH}`, `linux-headers-${ARCH}`)
- **Архитектуры** - полная поддержка x86_64 (`amd64`) и ARM64 (`arm64`)
- **Безопасность** - своевременные обновления безопасности напрямую от команды безопасности Debian
- **Совместимость** - полная поддержка WireGuard in-tree, BBR, TUN/TAP и Docker

### Проверка
```bash
# Проверка установленного ядра
uname -r
dpkg -l | grep linux-image
```

## 🐳 Docker оптимизация

### daemon.json конфигурация
```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "features": {
    "buildkit": true
  }
}
```

**Примечание:** Конфигурация оптимизирована для Debian 13 с поддержкой systemd socket activation. Не используются `default-address-pools` и `default-ulimits` для избежания конфликтов с systemd.

### Сеть и производительность
- **overlay2 storage driver** - максимальная производительность и совместимость
- **json-file логирование** - ограничение размера логов предотвращает переполнение диска
- **BuildKit** - ускорение сборки образов
- **systemd socket activation** - правильная интеграция с systemd для автозапуска
- **iptables-legacy** - обеспечение совместимости с Debian 13/13+ (использует nftables по умолчанию, требуется переключение перед UFW)

## 🔒 Безопасность

### SSH Hardening
```bash
# /etc/ssh/sshd_config
Port 22
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
```

### Fail2Ban
- **SSH защита** - блокировка брутфорса
- **настроенные jail'ы** - оптимальные параметры
- **логирование** - детальная статистика

### UFW Firewall
```bash
# Стандартные правила
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp        # SSH
ufw allow 80/tcp        # HTTP
ufw allow 443/tcp       # HTTPS
ufw enable --force
```

**Важно для Debian 13+:** Скрипт автоматически переключает iptables на legacy режим перед установкой UFW, чтобы избежать конфликтов с nftables. Это критично для правильной работы файрвола.

> [!WARNING]
> **Docker и UFW (обход правил фильтрации):** Демон Docker по умолчанию настраивает цепочки iptables (PREROUTING) напрямую, минуя правила фильтрации UFW. Порты контейнеров, опубликованные наружу через `-p <port>:<port>`, будут открыты всему миру независимо от `ufw default deny incoming`. Для ограничения доступа привязывайте порты к localhost (`-p 127.0.0.1:<port>:<port>`) или используйте проект `ufw-docker`.

## ⚡ Оптимизация производительности

### VPN-специфичные настройки (70+ параметров)
```bash
# Reverse Path Filtering (Loose mode 2 для асимметричной маршрутизации VPN/WireGuard/Docker)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# TCP Fast Open (reduces VPN connection latency by 15-40%)
net.ipv4.tcp_fastopen = 3

# UDP Buffer Sizes (critical for VPN protocols like WireGuard, OpenVPN)
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# IP Forwarding (required for VPN)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Connection Tracking (for multiple simultaneous VPN connections)
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_tcp_timeout_established = 1800

# NAT Performance
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1

# BBR congestion control
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
```

### Сетевые настройки (оптимизировано под каналы до 10 Гбит/с)
```bash
# TCP/UDP Buffer Sizes (адаптивно до 64MB для 10G BDP)
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.core.rmem_max = 67108864   # 64MB (или 32MB на VPS с <3GB RAM)
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# Сетевые очереди для высокого throughput
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 16384
```

### Файловая система
```bash
# Увеличенные лимиты файлов
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288

# Оптимизация памяти
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
```

### I/O планировщики (расширенная оптимизация)
```bash
# NVMe drives - extended optimization
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/nr_requests}="1024"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/read_ahead_kb}="512"

# SSD drives - extended optimization
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/nr_requests}="512"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/read_ahead_kb}="256"

# HDD drives
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
```

### CPU Governor
```bash
# Schedutil governor - balance between performance and power efficiency
# Автоматически применяется ко всем CPU ядрам
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo "schedutil" > "$cpu"
done
```

### System Limits
```bash
# /etc/security/limits.conf
* soft nofile 524288
* hard nofile 524288
* soft nproc 131072
* hard nproc 131072
```

## 🛠️ Утилиты скрипта

### vps-monitor.sh
Мониторинг системы:
```bash
vps-monitor.sh
```
- Системная информация
- Использование CPU/памяти/диска
- Сетевая статистика
- Top процессы

### vps-cleanup.sh
Очистка системы:
```bash
vps-cleanup.sh
```
- Очистка кэша пакетов
- Удаление старых логов
- Очистка Docker
- Удаление временных файлов

### vps-info.sh
Информация о системе:
```bash
vps-info.sh
```
- Детальная информация о железе
- Версия ОС и ядра
- Сетевые настройки
- Установленные пакеты

### network-test.sh
Тестирование сети:
```bash
network-test.sh
```
- Скорость соединения
- Пинг до популярных сервисов
- DNS тестирование
- Тестирование BBR

## 🔧 Конфигурационные файлы

### /etc/sysctl.d/99-custom.conf
```bash
# BBR
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# Память
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# Файлы
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288

# Сеть
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
```

### /etc/ssh/sshd_config
```bash
Port 22
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
```

## 🔄 Обновление и поддержка

### Автоматические обновления
- Безопасные обновления включены
- Еженедельная очистка системы
- Автоматическое удаление старых ядер
- Мониторинг безопасности

### Ручное обновление
```bash
# Обновить скрипт
wget -O optimize_vps.sh https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_vps.sh

# Проверить систему
vps-monitor.sh

# Очистить систему
vps-cleanup.sh
```

## 🐛 Устранение проблем

### Работа с VSCode Terminal (Remote SSH / Tunnels)

- **Интеграция с Fish:** Скрипт сохраняет `/bin/bash` системным shell в `/etc/passwd`. При открытии интерактивного терминала в VSCode через `~/.bashrc` автоматически стартует Fish со всеми алиасами и Starship.
- **Совместимость с VSCode Server:** Внутренние неинтерактивные команды VSCode выполняются через чистый Bash без сбоев окружения (в отличие от старых конфигураций с `KSH_ARRAYS`).
- **Если терминал не переключился на Fish:** убедитесь, что в `~/.bashrc` присутствует блок запуска `exec fish`, и перезапустите терминальную сессию в VSCode (`Ctrl + ~`).

### Проблемы с npm EACCES

**Ошибка:**
```
npm error code EACCES
npm error Your cache folder contains root-owned files
```

**Решение (автоматически применено в скрипте):**
fnm устанавливается в user-local директории, сохраняя корректные права.

**Ручное исправление (если нужно):**
```bash
sudo chown -R $(whoami):$(whoami) ~/.npm
sudo chown -R $(whoami):$(whoami) ~/.local/share/fnm
sudo chown -R $(whoami):$(whoami) ~/.config
npm cache clean --force
```

### Проблемы с ядром
```bash
# Проверить версию ядра
uname -r

# Список установленных ядер
dpkg --list | grep linux-image

# Удалить старые ядра
sudo apt autoremove --purge
```

### Проблемы с SSH
```bash
# Проверить статус
sudo systemctl status ssh

# Проверить конфигурацию
sudo sshd -t

# Перезапустить сервис
sudo systemctl restart ssh
```

### Проблемы с Docker
```bash
# Проверить статус
sudo systemctl status docker

# Проверить группу
groups $USER

# Добавить в группу
sudo usermod -aG docker $USER
newgrp docker
```

## 📊 Мониторинг

### Системные метрики
- **CPU** - использование, load average
- **Память** - RAM, swap, кэши
- **Диск** - использование, I/O статистика
- **Сеть** - трафик, соединения, BBR

### Логирование
- **Системные логи** - journalctl
- **SSH логи** - auth.log
- **Docker логи** - container logs
- **Производительность** - sar, iostat

## 📈 Сравнение с стандартной установкой

| Характеристика | Стандартная установка | После оптимизации |
|---------------|---------------------|-------------------|
| Ядро | Стандартное | Debian Backports (LTS) |
| Shell | Bash | Fish + Starship |
| Сеть | Базовая (1G) | 10G tuning (BBR, fq, 64MB buffers) |
| Безопасность | Базовая | Усиленная (Fail2Ban + UFW forward ACCEPT) |
| Производительность | Стандартная | Оптимизированная (70+ sysctl) |
| Контейнеризация | Нет | Docker CE |
| Мониторинг | Базовый | Расширенный |

## 📝 Лог изменений

### v3.0.0 (Текущая) - 2026-09-04
- 🚀 **Debian Backports kernel** - замена XanMod на официальный `bookworm-backports` (amd64 и arm64)
- 🐟 **Fish + Starship** - переход на Fish shell со Starship пресетом `nerd-font-symbols`
- ⚡ **10 Gbps Networking** - адаптивные сетевые буферы до 64MB, очереди 32k, conntrack 262k
- 🛡️ **Fail2Ban** - переход на прямой `backend = systemd` через `python3-systemd` (без зависимости от `/var/log/auth.log`)
- 🔒 **UFW & SSH** - добавление `DEFAULT_FORWARD_POLICY="ACCEPT"` для VPN-пакетов, предупреждение об обходе фильтрации Docker, переход на `KbdInteractiveAuthentication no`
- 📦 **Persistent modules** - автозагрузка `tcp_bbr`, `tun`, `wireguard` через `/etc/modules-load.d/`
- 🔒 **Security & Stability Hardening** - безопасная атомарная запись sudoers с `visudo -cf`, безопасное определение домашних каталогов (`getent passwd`), исправление монтирования `/tmp` (без `noexec`), и свободный Loose `rp_filter = 2` для VPN/Docker.

### v2.3.0 (Архив) - 2026-02-04
- ✅ **Debian 12/13 support**
- ✅ **Валидация username** с retry при ошибке (числовой, пустой, неверные символы, слишком длинный)
- 🔧 **Удалены дубликаты функций** (check_dialog)
- ✅ **deb822-aware APT enrichment**
- ✅ **CPU tooling:** `linux-cpupower`

### v2.2.0 (Архив) - 2025-12-12
- ⚡ **Zsh Ultra-Fast** - терминал загружается на 70-90% быстрее
- ✨ **Legacy Node manager автообновление** - автоматическое определение последней версии через GitHub API
- ✨ **Fallback версия** - v0.40.1 если API недоступен
- 🔧 **VSCode Terminal fix** - исправление ошибки `__vsc_update_env` для Remote SSH/Tunnels
- 🔧 **KSH_ARRAYS** - условное включение только вне VSCode терминала
- ✨ **npm без sudo** - установка legacy Node manager от имени пользователя для корректных прав
- ✨ **Для всех пользователей** - root, NEW_USER и DOCKER_USER получают одинаковые настройки
- 📚 Обновленная документация с описанием всех исправлений

### v2.0.0 (Архив)
- ✨ **Go** установка (последняя версия, SHA256 верификация)
- ✨ **Node.js + legacy Node manager** с LTS версией (фиксированная v0.39.7)
- ✨ Автоматическая инициализация Go и legacy Node manager в .zshrc
- ✨ Упрощенная docker daemon.json конфигурация
- ✨ iptables-legacy конфигурация для Debian 13
- ✨ Systemd socket activation для Docker

### v1.0.0 (Архив)
- 🐧 Базовый VPS скрипт оптимизации
- 🐧 XanMod kernel поддержка
- 🐧 Zsh + Starship конфигурация
- 🐧 Docker CE + Docker Compose
- 🐧 SSH hardening и безопасность
- 🐧 Системная оптимизация
- 🐧 Утилиты мониторинга

## 🤝 Сообщество

- **GitHub Issues** - сообщения об ошибках
- **GitHub Discussions** - вопросы и предложения
- **Pull Requests** - вклад в разработку

## 📄 Лицензия

MIT License - свободное использование и модификация.

## 🔗 См. также

- **[Debian Upgrade Guide](README_UPGRADE.md)** - обновление Debian 11/12 до 13 перед VPS-оптимизацией
- **[Главный README](../README.md)** - обзор всех скриптов репозитория

---

**Создано с ❤️ для VPS сообщества**
