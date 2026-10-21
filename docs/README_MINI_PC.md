# Mini PC Optimization Guide (Intel N5095/Jasper Lake)

**🆕 Версия 2.0.0** - **Debian Backports kernel**, **Fish + Starship** (`nerd-font-symbols`), Fail2Ban с `python3-systemd`, гибридный запуск шелла.
**📦 Версия 1.2.0** - Debian 12/13 support, fnm, deb822-aware APT enrichment, `linux-cpupower`.
**📦 Версия 1.1.0** - Умный swap (4GB для 16GB RAM), Media Server Pro (архив)

Специализированный скрипт оптимизации для мини-ПК на базе процессоров Intel Celeron N5095 (Jasper Lake) под управлением **Debian 12 (Bookworm)** или **Debian 13 (Trixie)**. Идеально подходит для создания **Home Server** или **Media Server** (Plex, Jellyfin).

## 🎯 Ключевые возможности

### 🐟 Fish + Starship
- **Fish shell** - быстрый, удобный и современный шелл с подсветкой синтаксиса и автодополнениями из коробки
- **Starship prompt** - единый быстрый промпт с пресетом `nerd-font-symbols`
- **fnm hook** - нативная интеграция Fast Node Manager (`fnm env --use-on-cd --shell fish`)
- **Гибридный запуск** - сохраняет `/bin/bash` в `/etc/passwd` для совместимости со скриптами и cron, а интерактивные сессии запускают Fish через `~/.bashrc`

### 🎞️ Media Server Pro
- **QuickSync транскодинг** - Intel UHD Graphics для аппаратного кодирования
- **32MB сетевые буферы** - оптимизация для множественных стримов (Plex/Jellyfin)
- **TCP Fast Open** - снижение latency при подключении клиентов
- **Расширенный I/O** - NVMe nr_requests=1024, read_ahead=512KB

### 💾 Умный Swap
- **4GB swap для 16GB RAM** - оптимальный баланс (вместо стандартных 8GB)
- **Swappiness=10** - минимальное использование swap

### 🔧 Kernel & Hardware Tuning
- **Debian Backports kernel** - официальное стабильное ядро Debian из `bookworm-backports` (LTS ядро)
- **CPU Governor: schedutil** - баланс производительности и температуры

## 🎯 Особенности оборудования

Скрипт учитывает специфику архитектуры **Tremont (Jasper Lake)**:

### 🧠 CPU: Intel Celeron N5095
- **Архитектура:** Tremont (10nm)
- **Инструкции:** SSE4.2, AES-NI, **нет AVX/AVX2**
- **Оптимизация:**
  - Установка официального ядра **Debian Backports** (`bookworm-backports` на Debian 12 / Mainline на Debian 13)
  - Губернатор питания: `schedutil` (баланс производительности и нагрева)

### 🎞️ GPU: Intel UHD Graphics
- **Поддержка:** QuickSync Video (аппаратное транскодирование)
- **Драйверы:** `intel-media-va-driver-non-free` (лучшая производительность для Linux)
- **Инструменты:** `intel-gpu-tools` (мониторинг через `intel_gpu_top`)
- **Группы:** Автоматическое добавление пользователя в `render` и `video`

### 💾 Storage: NVMe + SATA SSD
- **Планировщик I/O:**
  - NVMe: `none` (прямой доступ к NVMe очередям)
  - SATA SSD: `mq-deadline` (оптимизация очередей)
- **TRIM:** Включение `fstrim.timer` для продления жизни SSD
- **Монтирование:** Опции `noatime` для снижения износа

---

## 🚀 Установка и запуск

### 1. Подготовка
Установите чистый **Debian 12 (Bookworm)** или **Debian 13 (Trixie)**. Рекомендуется "netinst" образ без графического окружения (Headless) для максимальной производительности.

Если система ещё работает на Debian 11, сначала обновите её через [`upgrade-to-debian13.sh`](README_UPGRADE.md). На Debian 12 и Debian 13 можно сразу запускать `optimize_mini_pc.sh`.

### 2. Загрузка и запуск
```bash
# Быстрый запуск (bash + curl)
bash <(curl -fsSL https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_mini_pc.sh)

# Или скачать скрипт
wget https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_mini_pc.sh

# Сделать исполняемым
chmod +x optimize_mini_pc.sh

# Запустить (требуется root/sudo)
sudo ./optimize_mini_pc.sh
```

---

## 🛠️ Интерактивное меню

При запуске вам будет предложено выбрать компоненты установки. TUI сделан в стиле `arch-linux-installer.sh`: основной backend — Charmbracelet `gum`; `dialog`/`whiptail` не выбираются автоматически, чтобы не показывать fullscreen blue-screen UI.

1.  **System Update:** Обновление пакетов и установка базы (`curl`, `git`, `htop`, `vim`).
2.  **Locales & Timezone:** При включённом шаге генерируются обе локали `ru_RU.UTF-8` и `en_US.UTF-8`; меню выбирает язык по умолчанию через штатный `update-locale` Debian 12/13, без постоянного `LC_ALL`. Настраиваются часовой пояс и time sync (с проверкой существующего NTP daemon и fallback на `systemd-timesyncd`). [Исправление ошибки локали на уже настроенном сервере](README_AMNEZIA_HOST.md#ошибка-setlocale-при-входе-по-ssh).
3.  **User & Security:** Создание sudo-пользователя (атомарная валидация `visudo`) с sudo без пароля (`NOPASSWD:ALL` для пользователя и `root` в `/etc/sudoers.d/`), настройка SSH (ключи), UFW (фаервол) и Fail2Ban (`backend = systemd`).
    - **SSH:** введенная строка должна быть одной строкой `authorized_keys`, начинающейся с типа ключа (`ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256|384|521`, `sk-ssh-ed25519@openssh.com`, `sk-ecdsa-sha2-nistp256@openssh.com`), и проходить `ssh-keygen -l -f`; строки с именем хоста впереди, с опциями или приватный ключ не принимаются (можно ввести заново или пропустить шаг Enter). Закалка (`/etc/ssh/sshd_config.d/00-optimize-hardening.conf`: только вход по ключу, без keyboard-interactive, `AllowUsers`) записывается через временный файл (ошибка записи или копии прежнего файла отменяет закалку, прежний файл остается), затем проверяется `sshd -t`, а действующие значения сверяются через `sshd -T`. Имя `00-…` читается раньше других drop-in, и sshd берет первое значение, поэтому, например, `50-cloud-init.conf` с `PasswordAuthentication yes` закалку не отменяет; если значения все же задает файл, прочитанный раньше, скрипт называет их. Если проверка, сверка или перезапуск SSH не прошли, drop-in удаляется (или возвращается прежний), ошибка выводится, вход по паролю и для root остается как был. Файл `99-hardening.conf` прежних версий скрипта удаляется; файл с тем же именем, но другим содержимым остается. После успешного перезапуска скрипт ждет Enter: проверьте вход новым ключом в другом окне терминала.
    - **Fail2Ban:** если `/etc/fail2ban/jail.local` уже есть и отличается от записываемого, перед перезаписью сохраняется копия `jail.local.bak` (при повторных отличиях — `jail.local.bak.1`, `.2`, …); повторный запуск с тем же содержимым копий не создает.
4.  **Kernel & Hardware:** Установка официального ядра Debian Backports и драйверов Intel GPU.
5.  **Storage Optimization:** Настройка TRIM и планировщиков ввода/вывода.
6.  **Docker Stack:** Установка Docker CE + Docker Compose через deb822 source с `Architectures: $(dpkg --print-architecture)`.
7.  **Shell:** Fish + Starship (пресет `nerd-font-symbols`, гибридный запуск через `~/.bashrc`).
8.  **Dev Tools:** Установка Go (закрепленная версия, SHA-256 из скрипта) и Node.js (LTS via fnm; fnm — закрепленный релиз с проверкой SHA-256).
    Node.js-часть рассчитана на **чистую ОС** и не мигрирует старые NVM-конфигурации.
9.  **Samba:** Настройка безопасного файлового сервера для локальной сети (только NTLMv2: `ntlm auth = ntlmv2-only` — NTLMv1 и LANMAN отключены; минимальный протокол SMB2; заданные администратором значения этих параметров сохраняются). Если выбранный пакет `samba` не установился, скрипт останавливается с ошибкой.
    - **Firewall:** SMB открывается только для локальной подсети: `ufw allow from <подсеть> to any app Samba`. Подсеть берется из маршрута по умолчанию (интерфейс маршрута → его IPv4-адрес → сеть в формате CIDR, например `192.168.1.0/24`) и только если это частная сеть (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) с префиксом не длиннее `/30`. Если подсеть определить нельзя, скрипт спросит ее (Enter — пропустить; сеть не из частных диапазонов потребует подтверждения), а без терминала правило для SMB не добавляется (SMB закрыт в UFW) и печатается команда для ручного открытия. Правило `ufw allow Samba` без ограничения источника, оставшееся от прошлого запуска, удаляется всегда, в том числе когда подсеть не определена. Правило создается только для IPv4: раньше `ufw allow Samba` открывал SMB и по IPv6, теперь доступ по IPv6 закрыт; при необходимости добавьте правило `ufw allow from <IPv6-подсеть> to any app Samba` вручную.
    - **Права на общую папку:** владелец и права `755` ставятся только на корень `/mnt/ssd` (без `-R`) и только при первой настройке общей папки (когда секции `[<имя общей папки>]` еще нет в `smb.conf`). Содержимое диска и права при повторном запуске не меняются. Каталог `/mnt/ssd` должен существовать (смонтированный диск), иначе настройка Samba пропускается.
    - **`smb.conf`:** штатная секция `[homes]` отключается комментированием строк только внутри этой секции, остальные секции не меняются.

---

## 📊 Утилиты мониторинга

Скрипт устанавливает специальные утилиты для контроля состояния мини-ПК:

### `minipc-monitor.sh`
Единая панель мониторинга:
- Температура CPU (`sensors`)
- Загрузка ядра и Uptime
- Использование RAM и Дисков
- Статус Docker контейнеров
- Подсказка по мониторингу GPU

### `intel_gpu_top`
Реальный мониторинг загрузки видеоядра. Полезно для проверки работы транскодирования в Plex/Jellyfin.
```bash
sudo intel_gpu_top
```
В Fish есть алиас `gpuinfo`: он запускает `vainfo`, а если `vainfo` завершился с ошибкой, — `intel_gpu_top`.

### `minipc-cleanup.sh`
Скрипт очистки системы (логи, кэш apt, старые ядра). Добавляется в еженедельный cron.

---

## 🔧 Решение проблем

### Проверка транскодирования (QuickSync)
Чтобы проверить, работает ли аппаратное ускорение:
1. Установите `vainfo`: `sudo apt install vainfo`
2. Запустите: `vainfo`
   - Должен быть вывод без ошибок с списком профилей (H.264, HEVC и т.д.).
3. В Docker контейнерах (Plex/Jellyfin) пробрасывайте устройство:
   ```yaml
   devices:
     - /dev/dri:/dev/dri
   ```

### Ошибка "Permission denied" к /dev/dri
Убедитесь, что ваш пользователь добавлен в группы `render` и `video`. Скрипт делает это автоматически, но требуется **перезагрузка** или перелогин.

### Высокая температура CPU
Процессор N5095 имеет пассивное или слабое активное охлаждение.
- Проверьте режим работы кулера в BIOS.
- Скрипт устанавливает governor `schedutil`, который эффективнее `performance` для домашних задач.

---

## ⚡ Оптимизация производительности

### Media Server настройки (16GB RAM)
```bash
# TCP Fast Open (reduces streaming latency)
net.ipv4.tcp_fastopen = 3

# TCP/UDP Buffer Sizes (оптимизация для множественных стримов)
net.core.rmem_max = 33554432         # 32MB
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 262144 33554432
net.ipv4.tcp_wmem = 4096 262144 33554432

# Network Queues (для множественных одновременных стримов)
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192

# Reverse Path Filtering (Loose mode для маршрутизации Docker и VPN)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# BBR congestion control
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
```

> [!WARNING]
> **Docker и UFW:** Docker по умолчанию манипулирует правилами iptables напрямую в обход UFW. Порты, проброшенные через `docker run -p` или в `docker-compose.yml`, будут доступны из локальной сети и интернета. Чтобы ограничить доступ, привязывайте порт к localhost (`127.0.0.1:8080:8080`) или локальному IP интерфейса.

### Файловая система и память
```bash
# Swappiness (минимальное использование swap)
vm.swappiness = 5
vm.vfs_cache_pressure = 50

# Dirty pages (для стриминга)
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10

# Увеличенные лимиты файлов
fs.file-max = 2097152
fs.inotify.max_user_watches = 1048576
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
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/read_ahead_kb}="512"

# HDD drives
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
```

---

## 📝 Лог изменений

### v2.0.0 (Текущая) - 2026-09-04
- 🚀 **Debian Backports kernel** - замена XanMod на официальный `bookworm-backports` (amd64)
- 🐟 **Fish + Starship** - переход на Fish shell со Starship пресетом `nerd-font-symbols`
- 🛡️ **Fail2Ban** - переход на прямой `backend = systemd` через `python3-systemd`
- 🐚 **Гибридный шелл** - `/bin/bash` сохраняется в `/etc/passwd`, прозрачный запуск Fish в интерактивных сессиях через `~/.bashrc`
- 🔒 **Security & Stability Hardening** - безопасная атомарная запись sudoers с валидацией `visudo -cf`, безопасное определение домашних каталогов (`getent passwd`), отключение устаревшего NTLMv1 в Samba (`server min protocol = SMB2`), исправление опций монтирования `/tmp` (без `noexec`), и свободный Loose `rp_filter = 2` для Docker.

### v1.2.0 (Архив) - 2026-02-04
- ✅ **Debian 12/13 support**
- ✅ **Валидация username** с retry при ошибке (числовой, пустой, неверные символы, слишком длинный)
- 🔧 **Удалены дубликаты функций** (check_dialog)

### v1.1.0 (Архив) - 2025-12-12
- ⚡ **Zsh Ultra-Fast** - терминал загружается на 70-90% быстрее
  - fnm auto-switching (быстрый доступ к Node.js без legacy lazy-loading)
  - Оптимизированные плагины (убран 'pattern' highlighter, улучшены autosuggestions)
  - Защита `zsh-syntax-highlighting` от `NO_UNSET` после интерактивного `set -euo pipefail`
  - Компиляция .zshrc → .zshrc.zwc (автоматически)
  - Starship timeout снижен до 500ms
- 🎞️ **Media Server Pro** - оптимизация для Plex/Jellyfin
  - 32MB сетевые буферы (TCP/UDP) для множественных стримов
  - TCP Fast Open для снижения latency
  - Network queues оптимизация (16384 backlog, 8192 somaxconn)
- 💾 **Умный Swap** - 4GB вместо 8GB для систем с 16GB RAM
  - Автоматический расчет оптимального размера swap
  - Swappiness=10 для минимального использования
- 💾 **I/O планировщики** - расширенная оптимизация
  - NVMe: nr_requests=1024, read_ahead=512KB
  - SSD: nr_requests=512, read_ahead=512KB
  - HDD: bfq scheduler
- 📊 **System Limits** - увеличенные лимиты для файлов

### v1.0.0 (Архив)
- 🐧 Базовая оптимизация для Intel N5095
- 🐧 XanMod x64v2 kernel
- 🐧 Intel QuickSync поддержка
- 🐧 Zsh + Starship конфигурация
- 🐧 Docker CE + утилиты

---

## 📝 Лицензия
MIT License

## 🔗 См. также

- **[Debian Upgrade Guide](README_UPGRADE.md)** - обновление Debian 11/12 до 13 перед настройкой Mini PC
- **[Главный README](../README.md)** - обзор всех скриптов репозитория
