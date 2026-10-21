# WSL2 Optimization Script for Debian 12/13

Современный скрипт оптимизации WSL2 для **Debian 12 (Bookworm)** и **Debian 13 (Trixie)** с Fish + Starship + Go + Node.js/fnm.

**🆕 Версия 4.1.0** - **Fish + Starship** (`nerd-font-symbols`), гибридный запуск шелла, нативная интеграция fnm и WSL2 functions.
**📦 Версия 4.0.0** - Debian 12/13 support, отдельные Go/Node toggles, безопасный CUDA Toolkit path, TUI fallback.
**📦 Версия 3.0.0** - Debian 12/13 support, fnm, dynamic CUDA distro path (архив).

## 🚀 Ключевые особенности

### 🐧 WSL2-специфичная оптимизация
- **systemd поддержка** - полная интеграция с systemd
- **wsl.conf конфигурация** - оптимизированные настройки WSL2
- **Windows интеграция** - функции для работы с Windows приложениями
- **Производительность** - тюнинг памяти, сети, файловой системы
- **Автоматический запуск Docker** - при включении WSL2

### 🐟 Fish + Starship Prompt
- **Fish shell** - мгновенный и умный шелл с подсветкой синтаксиса и автодополнениями из коробки
- **Starship prompt** - единый быстрый промпт с официальным пресетом `nerd-font-symbols`
- **fnm hook** - нативная интеграция Fast Node Manager (`fnm env --use-on-cd --shell fish`)
- **WSL2 функции** - `explorer()`, `cmd()`, `powershell()`, `wslperf()`, `mkcd()`
- **Гибридный запуск** - пользовательский шелл в `/etc/passwd` остаётся стандартным `/bin/bash` для надежной работы WSL interop и скриптов; интерактивные сессии прозрачно открывают Fish через `~/.bashrc`

### 💻 Языки программирования
- **Go** - закрепленная версия с проверкой SHA-256 из скрипта
- **Node.js** - LTS версия через fnm
- **Отдельные пункты меню** - Go и Node.js/fnm можно включать или пропускать независимо
- **npm без sudo** - fnm в user-local директории, корректные права доступа
- **Автоматическое управление** - легко переключаться между версиями Node.js
- **Для всех пользователей** - root, NEW_USER и DOCKER_USER

### 🐳 Контейнеризация
- **Docker CE** - последняя версия с Docker Compose
- **NVIDIA Container Toolkit** - поддержка GPU в контейнерах
- **CUDA Toolkit** - опциональная установка для разработки без широкого `cuda` metapackage
- **APT deb822** - Docker source pinning по `dpkg --print-architecture`

### ⚡ Производительность (ML/AI оптимизация)
- **Transparent Huge Pages** - улучшение производительности для больших моделей ML/AI
- **64MB сетевые буферы** - оптимизация для 32GB RAM и высокоскоростных операций
- **GPU Memory** - unlimited memlock для CUDA, 64GB shared memory
- **Агрессивный I/O** - NVMe nr_requests=2048, read-ahead 1024KB для быстрой загрузки датасетов
- **Swappiness=1** - минимальное использование swap для максимальной производительности
- **BBR congestion control** - оптимизация сети
- **System Limits** - увеличенные лимиты файлов (524288) и процессов (131072)

## 📋 Системные требования

- **WSL2** с Windows 10/11
- **Debian:** **Debian 12 (Bookworm)** или **Debian 13 (Trixie)** под WSL2
- **Права sudo** для установки
- **Минимум 4GB RAM** (рекомендуется 8GB+)

> Скрипт [`upgrade-to-debian13.sh`](README_UPGRADE.md) предназначен для серверных Debian-инсталляций и не рассчитан на WSL2. Для WSL используйте Debian 12 или Debian 13 distro под WSL2.

## 🛠️ Установка и использование

### 1. Подготовка Windows

Создайте файл `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
memory=8GB
processors=4
autoMemoryReclaim=dropCache
sparseVhd=true
swap=2GB
dnsTunneling=true
networkingMode=mirrored
guiApplications=true

[experimental]
autoMemoryReclaim=dropCache
sparseVhd=true
```

### 2. Обновление WSL

В PowerShell (от имени администратора):

```powershell
wsl --update
wsl --set-default-version 2
```

### 3. Запуск скрипта

```bash
# Быстрый запуск (bash + curl)
bash <(curl -fsSL https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_wsl2.sh)

# Или скачайте скрипт
wget https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_wsl2.sh

# Сделайте исполняемым
chmod +x optimize_wsl2.sh

# Запустите от имени root
sudo ./optimize_wsl2.sh
```

## 🎯 Этапы установки

Скрипт выполняет 17 последовательных шагов с интерактивным меню. TUI сделан в стиле `arch-linux-installer.sh`: основной backend — Charmbracelet `gum`; если `gum` отсутствует, скрипт пытается подтянуть его с проверкой checksum, а при недоступности `gum` использует обычный Bash fallback. `dialog`/`whiptail` не выбираются автоматически.

### Этап 1-7: Система и Shell
- **Step 1:** Определение операционной системы
- **Step 2:** Интерактивное меню выбора компонентов
- **Step 3:** WSL2 конфигурация (wsl.conf + systemd, автозапуск Docker)
- **Step 4:** Обновление системы и базовые утилиты
- **Step 5:** Создание пользователя с sudo правами
- **Step 6:** При включённом шаге генерируются обе локали `ru_RU.UTF-8` и `en_US.UTF-8`; меню задаёт язык по умолчанию через штатный `update-locale` Debian 12/13, без постоянного `LC_ALL`. Окружение установщика остаётся в локали `C` до завершения. [Исправление на уже настроенной системе](README_AMNEZIA_HOST.md#ошибка-setlocale-при-входе-по-ssh).
- **Step 7:** Fish + Starship (пресет `nerd-font-symbols`, гибридный запуск через `~/.bashrc`)

### Этап 8-10: Языки программирования
- **Step 8:** Go установка (закрепленная версия, проверка SHA-256), если пункт включён в меню
- **Step 9:** Node.js + fnm (LTS версия, auto-switching shell integration), если пункт включён в меню
- **Step 10:** SSH agent конфигурация

### Этап 11-12: Контейнеризация
- **Step 11:** Docker CE + Docker Compose
- **Step 12:** NVIDIA Container Toolkit + CUDA Toolkit (опционально, без fallback на пакет `cuda`)

### Этап 13-17: Оптимизация и завершение
- **Step 13:** Performance tuning (sysctl, лимиты, I/O)
- **Step 14:** Автоматические обновления безопасности
- **Step 15:** Создание утилит мониторинга
- **Step 16:** Финальная очистка
- **Step 17:** Итоговая информация и инструкции

## 🎨 Fish + Starship особенности

### Преимущества Fish в WSL2
- **Автодополнения из коробки** - мгновенный поиск команд по истории и автодополнение параметров
- **Синтаксическая подсветка** - нативная подсветка команд, путей и флагов
- **Быстрый старт** - отсутствие оверхеда на компиляцию шелла
- **Starship пресет** - единый пресет `nerd-font-symbols`
- **Гибридный запуск** - `/bin/bash` сохраняется в `/etc/passwd`, Fish прозрачно запускается в интерактивных терминалах
- **Windows interop функции** - вызовы Windows утилит прямо из Fish (explorer, cmd, powershell, wslperf, mkcd)

### Starship prompt
- 🌱 Git статус и ветка
- 🐋 Docker контекст
- 🐍 Python, ⬢ Node.js, 🐹 Go, 🦀 Rust версии
- ⏰ Время выполнения команд
- 💾 Использование памяти

### WSL2-специфичные функции
```bash
# Открыть папку в Windows Explorer
explorer /path/to/folder

# Выполнить Windows команду
cmd dir
powershell Get-Process

# Мониторинг производительности WSL2
wslperf
```

### Алиасы и функции
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
```

## 🐹 Go программирование

### Установка
- Закрепленная версия Go 1.27.3 (amd64, arm64) с `dl.google.com`
- Архив сверяется с SHA-256, записанной в скрипте; прежняя установка заменяется только после проверки и распаковки
- Установка в `/usr/local/go`
- Автоматическая конфигурация PATH

### Использование
```bash
# Go сразу доступен
go version
go mod init example.com/hello

# Переменные окружения
$GOPATH=$HOME/go
$PATH включает /usr/local/go/bin и $GOPATH/bin
```

### Конфигурация
- `/etc/profile.d/golang.sh` - глобальная конфигурация для всех shells
- `~/.config/fish/config.fish` и `~/.bashrc` - локальная конфигурация для Fish и Bash (автоматически добавляется)

## ⬢ Node.js с fnm

### fnm установка
- **Fast Node Manager (fnm)** - быстрый нативный менеджер версий Node.js
- fnm 1.39.0 из релиза GitHub: архив сверяется с SHA-256, записанной в скрипте; shell rc файлы установщик не меняет
- Автоматическая установка последней LTS версии
- `corepack enable` при наличии
- Установка для root, NEW_USER и DOCKER_USER
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

## 🛠️ Пример разработки

```bash
# Go проект
go mod init github.com/user/project
go get github.com/gorilla/mux
go run main.go

# Node.js проект
npm init -y
npm install express
npm start

# Docker контейнер
docker build -t myapp .
docker run -p 8000:8000 myapp

# GPU с NVIDIA
docker run --gpus all nvidia/cuda:12.3.1-runtime-ubuntu22.04 nvidia-smi
```

## 🐳 Docker и NVIDIA

### Docker оптимизация
- **overlay2 storage driver** - максимальная производительность
- **логирование** - ограничение размера логов
- **пулы адресов** - оптимизация сети
- **BuildKit** - ускорение сборки

### NVIDIA поддержка
- **GPU доступность** - проверка /dev/dxg
- **Container Toolkit** - интеграция с Docker
- **CUDA Toolkit** - опциональная установка
- **Автоопределение** - поддержка различных GPU

## ⚡ Оптимизация производительности

### ML/AI специфичные настройки (для 32GB RAM, RTX 4090)

```bash
# Transparent Huge Pages (критично для ML/AI производительности)
echo always > /sys/kernel/mm/transparent_hugepage/enabled
echo always > /sys/kernel/mm/transparent_hugepage/defrag

# Memory Management (для больших моделей и датасетов)
vm.swappiness = 1                    # Минимальное использование swap
vm.vfs_cache_pressure = 40
vm.dirty_ratio = 30                  # Больше грязных страниц в кэше
vm.dirty_background_ratio = 10
vm.max_map_count = 262144            # Для больших memory-mapped файлов

# Shared Memory (для CUDA и multi-process ML/AI)
kernel.shmmax = 68719476736          # 64GB
kernel.shmall = 16777216             # 64GB в страницах
```

### Сетевые настройки (64MB буферы)
```bash
# TCP/UDP Buffer Sizes (агрессивно для 32GB RAM)
net.core.rmem_max = 67108864         # 64MB
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 524288 67108864
net.ipv4.tcp_wmem = 4096 524288 67108864

# BBR congestion control
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# Network Performance
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 16384
```

### Файловая система
```bash
# Увеличенные лимиты файлов (для больших проектов)
fs.file-max = 4194304
fs.inotify.max_user_watches = 2097152
```

### I/O планировщики (агрессивная оптимизация для NVMe)
```bash
# NVMe drives - aggressive optimization for ML/AI datasets
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/nr_requests}="2048"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/read_ahead_kb}="1024"

# SSD drives - optimization
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/nr_requests}="1024"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/read_ahead_kb}="1024"
```

### System Limits (для GPU и ML/AI)
```bash
# /etc/security/limits.conf
# Open file limits (для больших проектов и датасетов)
* soft nofile 524288
* hard nofile 524288

# Process limits (для параллельных ML/AI тренировок)
* soft nproc 131072
* hard nproc 131072

# Memory lock (для CUDA и GPU memory pinning)
* soft memlock unlimited
* hard memlock unlimited

# Core dumps
* soft core unlimited
* hard core unlimited
```

## 🛠️ Утилиты скрипта

### wsl2-monitor.sh
Мониторинг системы WSL2:
```bash
wsl2-monitor.sh
```
- Системная информация
- Использование CPU/памяти/диска
- WSL2 специфичная информация
- Top процессы

### wsl2-cleanup.sh
Очистка системы:
```bash
wsl2-cleanup.sh
```
- Очистка кэша пакетов
- Удаление старых логов
- Очистка Docker
- Удаление временных файлов

### wsl2-backup.sh
Резервное копирование:
```bash
wsl2-backup.sh [username]
```
- Конфигурационные файлы
- Настройки пользователей
- Сохранение в Windows

## 🔧 Конфигурационные файлы

### /etc/wsl.conf
```ini
[boot]
systemd=true

[automount]
enabled=true
root=/mnt
options="metadata,case=dir,umask=022"

[network]
generateHosts=true
hostname=debian-wsl

[interop]
enabled=true
appendWindowsPath=true

[user]
default=snaplyze
```

**Примечания:**
- `systemd=true` - включает systemd, Docker автоматически стартует через systemd сервис
- `root=/mnt` - стандартное WSL монтирование (C: → /mnt/c, D: → /mnt/d)
- `case=dir` в `options` - включает directory-level case sensitivity (опции: off, dir, force)
- `umask=022` - права доступа для директорий (rwxr-xr-x = 755)
- **Убрано `fmask=111`** - позволяет VSCode скриптам выполняться (исправление ошибки Permission denied)
- **Убрано `uid=1000,gid=1000`** - гибкость для различных пользователей
- `default=snaplyze` - устанавливает пользователя по умолчанию (требует `wsl --shutdown`)
- Docker автоматически стартует через systemd при загрузке WSL2

### /etc/docker/daemon.json
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
  },
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  }
}
```

**Примечания:**
- `log-driver` - JSON файл логирование с ограничением размера логов
- `storage-driver` - overlay2 оптимален для WSL2
- `features.buildkit` - использование современного BuildKit для сборки образов
- `runtimes.nvidia` - добавляется автоматически при установке NVIDIA Container Toolkit
- **Важно**: Не используйте `hosts`, `default-address-pools` или `default-ulimits` - они могут вызывать конфликты с systemd socket activation

## 🔄 Обновление и поддержка

### Автоматические обновления
- Безопасные обновления включены
- Еженедельная очистка системы
- Автоматическое удаление старых ядер

### Ручное обновление
```bash
# Обновить скрипт
curl -fsSLO https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_wsl2.sh

# Проверить систему
wsl2-monitor.sh

# Очистить систему
wsl2-cleanup.sh
```

## 🔄 Миграция на версию 2.1.2

### Изменение монтирования Windows дисков

**Важно:** В версии 2.1.2 изменен путь монтирования с `/` на `/mnt/` (стандарт WSL).

**Было:**
- C: → `/c/`
- D: → `/d/`

**Стало:**
- C: → `/mnt/c/`
- D: → `/mnt/d/`

### Что делать после установки:

1. **Перезапустите WSL** (обязательно!):
   ```powershell
   # В Windows PowerShell
   wsl --shutdown
   ```

2. **Обновите свои скрипты** (если есть жесткие пути `/c/...`):
   ```bash
   # Найти файлы со старыми путями
   grep -r "/c/" ~ 2>/dev/null | grep -v ".git"

   # Заменить вручную в каждом файле
   sed -i 's|/c/|/mnt/c/|g' путь/к/файлу.sh
   ```

3. **Проверьте новые пути:**
   ```bash
   ls /mnt/c/Users  # ✅ Должно работать
   ls /c/Users      # ❌ Не работает
   ```

## 🐛 Устранение проблем

### Работа с VSCode Terminal (Remote WSL)

- **Интеграция с Fish:** Системным shell в `/etc/passwd` остаётся стандартный `/bin/bash`. При открытии интерактивного окна терминала в VSCode автоматически запускается Fish со всеми функциями интеграции Windows (`explorer`, `cmd`, `powershell`) и Starship.
- **Фоновые команды Remote WSL:** Все внутренние скрипты VSCode Server работают через стандартный Bash без конфликтов.
- **Если терминал не переключился на Fish:** закройте старые терминалы (`Ctrl + ~`) и откройте новую сессию.

### Проблемы с npm EACCES

**Ошибка:**
```
npm error code EACCES
npm error Your cache folder contains root-owned files
```

**Решение (автоматически применено в скрипте):**
fnm устанавливается в user-local директории, обеспечивая корректные права.

**Ручное исправление (если нужно):**
```bash
sudo chown -R $(whoami):$(whoami) ~/.npm
sudo chown -R $(whoami):$(whoami) ~/.local/share/fnm
sudo chown -R $(whoami):$(whoami) ~/.config
npm cache clean --force
```

### Проблемы с systemd
```bash
# Проверить статус
systemctl status

# Перезапустить сервисы
sudo systemctl daemon-reload
sudo systemctl restart docker
```

### Проблемы с Docker
```bash
# Проверить группу
groups $USER

# Добавить в группу
sudo usermod -aG docker $USER

# Перезайти в систему
newgrp docker
```

### Проблемы с GPU
```bash
# Проверить доступность GPU
ls -la /dev/dxg
nvidia-smi

# Переустановить драйверы Windows
wsl --shutdown
```

## 📝 Лог изменений

### v4.1.0 (Текущая) - 2026-09-04
- 🐟 **Fish + Starship** - переход на современный Fish shell со Starship пресетом `nerd-font-symbols`
- 🐚 **Гибридный запуск** - пользовательский шелл в `/etc/passwd` остаётся `/bin/bash` для совместимости с Windows interop, а интерактивные сессии запускают Fish через `~/.bashrc`
- 🪟 **WSL2 helpers в Fish** - функции `explorer`, `cmd`, `powershell`, `wslperf`, `mkcd` адаптированы под Fish
- ⬢ **fnm интеграция** - нативный хук `fnm env --use-on-cd --shell fish`
- 🎮 **CUDA в Fish Shell** - экспорт `CUDA_HOME=/usr/local/cuda` и `LD_LIBRARY_PATH=/usr/local/cuda/lib64` в `config.fish`
- 🔒 **Security & Stability Hardening** - безопасная атомарная запись sudoers с валидацией `visudo -cf`, безопасное определение домашних каталогов (`getent passwd`) вместо `eval echo`, Loose `rp_filter = 2` для Docker и сетевых мостов.

### v4.0.0 (Архив) - 2026-05-11
- ✅ **Опциональные dev toolchains:** Go и Node.js/fnm выбираются отдельно
- ✅ **CUDA safety:** GPU preflight не роняет весь скрипт; широкий `cuda` metapackage не используется
- ✅ **Shared helpers:** WSL config, Docker deb822 и unattended-upgrades рендерятся через `lib/common.sh`
- ✅ **Gum TUI:** prompts в стиле `arch-linux-installer.sh`, без автоматического blue-screen `dialog`/`whiptail`

### v3.0.0 (Архив) - 2026-02-03
- ✅ **Debian 12/13 support**
- ✅ **CUDA официальный метод:** `cuda-keyring_1.1-1_all.deb` с dynamic distro path
- ✅ **System info fallback:** `fastfetch -> neofetch -> skip`
- ✅ **Валидация username** с retry при ошибке
- ❌ **Не поддерживается:** Debian 11

### v2.2.0 (Архив) - 2025-12-12
- ⚡ **Zsh Ultra-Fast** - терминал загружается на 70-90% быстрее

### v2.1.2 (Архив) - 2025-11-19
- 🔧 **VSCode Terminal fix** - исправлена ошибка `__vsc_update_env` для Remote WSL
- 🔧 **KSH_ARRAYS** - условное включение только вне VSCode терминала (строки 84-86 в .zshrc)
- ✨ **WSL монтирование** - изменено на стандарт `/mnt/` (C: → /mnt/c вместо /c)
- ✨ **wsl.conf обновлен** - убраны `fmask=111` и `uid=1000,gid=1000`
- ✨ **Legacy Node manager автообновление** - автоматическое определение последней версии через GitHub API
- ✨ **Fallback версия** - v0.40.1 если GitHub API недоступен
- ✨ **npm без sudo** - установка legacy Node manager от имени пользователя для корректных прав доступа
- ✨ **Для всех пользователей** - root, NEW_USER и DOCKER_USER получают одинаковые настройки
- 📚 Полная документация всех исправлений (VSCODE_FIX_FINAL.md, MIGRATION_GUIDE.md)

### v2.0.0 (Архив)
- ✨ **Go** установка (последняя версия, SHA256 верификация)
- ✨ **Node.js + legacy Node manager** с LTS версией (фиксированная v0.39.7)
- ✨ Замена Fish shell на Zsh + Starship
- ✨ Полная поддержка systemd
- ✨ WSL2-специфичные функции
- ✨ Расширенная поддержка NVIDIA/CUDA
- ✨ 17 этапов установки

### v1.0.0 (Архив)
- 🐧 Fish shell + Fisher
- 🐧 Базовая WSL2 поддержка
- 🐧 Docker + NVIDIA Container Toolkit
- 🐧 CUDA Toolkit опционально

## 🤝 Сообщество

- **GitHub Issues** - сообщения об ошибках
- **GitHub Discussions** - вопросы и предложения
- **Pull Requests** - вклад в разработку

## 📄 Лицензия

MIT License - свободное использование и модификация.

## 🔗 См. также

- **[Debian Upgrade Guide](README_UPGRADE.md)** - описание серверного обновления Debian 11/12 → 13
- **[Главный README](../README.md)** - обзор всех скриптов репозитория

---

**Создано с ❤️ для WSL2 сообщества**
