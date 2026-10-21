# Оптимизация VPS

[README](../README.md) · [Вся документация](README.md)

`optimize_vps.sh` настраивает VPS на Debian 12 или 13 под VPN-нагрузку: ядро из Debian Backports (на Debian 12), sysctl под каналы до 10 Гбит/с, Fish + Starship, Go, Node.js через fnm, Docker, закалка SSH, Fail2Ban и UFW. Документ для администратора, который запускает скрипт от root на целевой машине.

| Скрипт | Версия | Debian | Права | Лог |
|---|---|---|---|---|
| `optimize_vps.sh` | 3.0.0 (`SCRIPT_VERSION`, печатает `--help`); закрепленный выпуск репозитория — `v2026.10.21.1` (см. [Версии и выпуски](../README.md#версии-и-выпуски)) | 12 (bookworm) или 13 (trixie); на других версиях скрипт завершается с кодом 1 | root (`EUID` 0), иначе код 1 | `/var/log/vps_optimization.log` — сообщения скрипта и вывод apt |

> [!WARNING]
> Скрипт меняет ядро, пользователей, sudoers, SSH, firewall и sysctl. Запускайте его только на целевой машине и только от root. Перед запуском сделайте снимок (snapshot) VPS: полного отката одной командой нет. Не запускайте его на рабочей станции ни от root, ни через sudo. `--help` работает без root и ничего не меняет.

## Содержание

- [Для чего](#для-чего)
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Параметры запуска](#параметры-запуска)
- [Что делает скрипт](#что-делает-скрипт)
- [Файлы, которые пишет скрипт](#файлы-которые-пишет-скрипт)
- [Проверка после запуска](#проверка-после-запуска)
- [Повторный запуск и откат](#повторный-запуск-и-откат)
- [Решение проблем](#решение-проблем)
- [См. также](#см-также)

## Для чего

Скрипт собирает из чистого Debian сервер для VPN и контейнеров с одним пользователем-администратором:

- Ядро: на Debian 12 — `linux-image-<arch>` и `linux-headers-<arch>` из `bookworm-backports` (свежее официальное ядро Debian с WireGuard, BBR, TUN/TAP); на Debian 13 — те же пакеты из основного репозитория. Архитектуры `amd64` и `arm64`.
- Сеть: BBR с планировщиком `fq`, буферы до 64 MB (32 MB при RAM меньше 3 GB), очереди 32768, conntrack 262144, `ip_forward = 1`, loose `rp_filter = 2` для асимметричной маршрутизации WireGuard, AmneziaWG, OpenVPN и мостов Docker. Модули `tcp_bbr`, `tun`, `wireguard` загружаются при старте.
- Безопасность: пользователь с ключом SSH и sudo без пароля, вход root и вход по паролю выключены, UFW с `DEFAULT_FORWARD_POLICY="ACCEPT"` для VPN, Fail2Ban с `backend = systemd`, автоматические обновления безопасности.
- Инструменты: Fish + Starship (пресет `nerd-font-symbols`), Go 1.27.3, fnm 1.39.0 с Node.js LTS, Docker CE с Compose и Buildx, набор утилит (`htop`, `fzf`, `ripgrep`, `bat`, `fd-find`, `tmux`, `cmake`, `gcc`).
- Оболочка: в `/etc/passwd` у пользователя остается `/bin/bash`, чтобы `scp`, `rsync`, cron и неинтерактивные команды SSH работали как прежде; интерактивная сессия переходит в Fish через `~/.bashrc`.

## Требования

- Debian 12 (bookworm) или Debian 13 (trixie): скрипт читает `/etc/os-release` и останавливается на любой другой версии. Сервер на Debian 11 сначала обновите скриптом [`upgrade-to-debian13.sh`](README_UPGRADE.md).
- Архитектура `amd64` или `arm64`: для них закреплены ядро, Go, fnm, Starship и gum. На другой архитектуре загрузки Go и fnm не выполняются.
- Доступ root и рабочий SSH: скрипт просит открыть второй терминал и проверить вход новым пользователем до закалки SSH.
- Публичный ключ SSH (`id_ed25519.pub` или `id_rsa.pub`): без ключа скрипт завершается, пароль по SSH после закалки не работает.
- Интернет: `deb.debian.org`, `download.docker.com`, `dl.google.com`, `github.com` (Starship, fnm, gum).
- Память: код объем RAM не проверяет; sysctl и лимиты рассчитаны на 1-4 GB, размер swap и буферов выбирается по RAM (см. [Что делает скрипт](#что-делает-скрипт)). Место на диске: swap-файл размером до 2 × RAM плюс пакеты.

## Быстрый старт

Текущая версия из `main`:

```bash
# Быстрый запуск (bash + curl)
bash <(curl -fsSL https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_vps.sh)

# Или скачайте и запустите
wget https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_vps.sh
chmod +x optimize_vps.sh
sudo ./optimize_vps.sh
```

Закрепленный выпуск (см. [Версии и выпуски](../README.md#версии-и-выпуски)):

```bash
TAG=v2026.10.21.1   # последний выпуск: https://github.com/snaplyze/optimize-debian/releases/latest
bash <(curl -fsSL "https://raw.githubusercontent.com/snaplyze/optimize-debian/$TAG/optimize_vps.sh")
```

Все шаги идут из функции `optimize_main`, которую вызывает последняя строка файла: оборванная загрузка останавливается на синтаксической ошибке и ничего не меняет. Перед запуском полезно обновить систему (`apt update && apt upgrade -y`) и посмотреть `uname -m` и `lsb_release -a`.

> [!TIP]
> Запускайте скрипт в `tmux` или `screen`: он задает вопросы, ставит ядро и перезапускает sshd, а обрыв сессии посреди шага оставит систему настроенной наполовину.

## Параметры запуска

Аргументы:

| Аргумент | Действие |
|---|---|
| `-h`, `--help` | печатает справку и выходит с кодом 0, без root и без изменений |
| без аргументов | обычный запуск |
| любой другой | `Unknown argument: ...`, справка в stderr, код 2 |

Вопросы интерактивного меню (в порядке появления):

| Вопрос | Умолчание и проверка |
|---|---|
| `Enter new username` | обязателен; строчные буквы, цифры, `_`, `-`; не начинается с цифры или `-`; не только цифры; до 32 символов; при ошибке вопрос повторяется |
| `Do you want to change password for existing user ...? (y/N)` | только для существующего пользователя; `N` |
| `passwd` для нового пользователя | при ошибке `Retry? (Y/n)` |
| `SSH Public Key` | обязателен; пустой ключ — код 1 |
| `Press Enter once you've verified SSH access works...` | пауза для проверки входа во втором терминале |
| `Default Locale` (1 `en_US.UTF-8`, 2 `ru_RU.UTF-8`, 3 обе с английским по умолчанию) | 1; неверный ввод — `en_US.UTF-8`; обе локали генерируются всегда |
| `Enter new hostname` | Enter — оставить текущее; имя проверяется по шаблону `[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?` |
| `Enter timezone` | Enter — оставить текущий; имя должно существовать в `/usr/share/zoneinfo` |
| `Do you want to reboot now? (y/N)` | `N`; при `y` перезагрузка через 5 секунд |

Переменные окружения, которые читает код:

| Переменная | Значение |
|---|---|
| `TUI_BACKEND` | `auto` (умолчание), `gum`, `plain`, `dialog`, `whiptail`. В `auto` используется `gum`, если он есть или его удалось установить; иначе обычные запросы `read`. `dialog` и `whiptail` сами не выбираются. Другое значение — инициализация TUI завершается ошибкой, и меню идет через `read` |
| `TUI_AUTO_INSTALL_GUM` | `true` (умолчание); `false` — gum не скачивается |
| `GUM`, `TUI_GUM_VERSION` | путь к gum (`/usr/local/bin/gum`) и версия (`0.17.0`); для другой версии нет закрепленной SHA-256, и она не ставится |
| `COMMON_DOWNLOAD_CONNECT_TIMEOUT`, `COMMON_DOWNLOAD_MAX_TIME`, `COMMON_DOWNLOAD_RETRIES` | таймауты curl для загрузок Starship, Go и fnm: 20 с, 900 с, 3 попытки |
| `OPTIMIZE_SOURCE_ONLY=1` | файл только подключается (`source`) без запуска `optimize_main`; нужно тестам |

Таймауты APT (`COMMON_APT_LOCK_TIMEOUT=300`, `COMMON_APT_UPDATE_ATTEMPTS=30`) заданы в скрипте и из окружения не читаются. Скрипт сам выставляет `LC_ALL=C` и `LANG=C` на время работы.

## Что делает скрипт

Шаги в порядке исполнения `optimize_main`. Шаги с пометкой «стоп» завершают скрипт с кодом 1 при ошибке.

```mermaid
flowchart LR
    A["Проверки,<br>пользователь,<br>ключ SSH"] --> B["Локаль, NTP,<br>Fish, Go, fnm"]
    B --> C["Обновление,<br>ядро, Docker,<br>sysctl, swap"]
    C --> D["UFW, Fail2Ban,<br>лимиты,<br>закалка SSH"]
    D --> E["Утилиты,<br>итог"]
```

1. **Проверки.** Разбор аргумента, проверка `EUID`, `tui_init` (gum 0.17.0 скачивается с проверкой SHA-256 в `/usr/local/bin/gum`: в `auto` только при выводе в терминал, при `TUI_BACKEND=gum` всегда). Чтение `/etc/os-release`: не Debian или не 12/13 — стоп. Если установлен `cloud-init`, есть `/etc/network/interfaces.d/50-cloud-init` и `/etc/network/interfaces` сам описывает интерфейсы кроме `lo`, скрипт пишет `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` (`network: {config: disabled}`) и переименовывает `50-cloud-init` в `50-cloud-init.disabled-by-optimize.<дата>-<ЧЧММСС>`, чтобы после перезагрузки не было двух DHCP-клиентов.
2. **Пользователь и SSH-ключ.** Имя проверяется в цикле. Существующий пользователь остается, добавляется в группу `sudo`, пароль меняется по желанию. Новый создается `adduser --disabled-password`, добавляется в `sudo`, пароль задается `passwd`. Sudo без пароля: `/etc/sudoers.d/<user>` с `<user> ALL=(ALL) NOPASSWD:ALL` и `/etc/sudoers.d/root` (если в нем еще нет такой строки) — оба через `common_safe_write_sudoers`: содержимое пишется во временный файл в том же каталоге, проверяется `visudo -cf` и только потом переименовывается; при ошибке прежний файл не меняется. Ключ дописывается в `~/.ssh/authorized_keys` (каталог `700`, файл `600`), если такой строки там еще нет. Дальше пауза: проверьте `ssh <user>@<ip>` во втором терминале.
3. **Локализация.** Ставится `locales`, в `/etc/locale.gen` включаются `en_US.UTF-8` и `ru_RU.UTF-8`, `locale-gen --keep-existing`, наличие обеих локалей проверяется через `locale -a`. Выбранная локаль записывается `update-locale --reset LANG=... LANGUAGE=...` (штатный файл Debian: `/etc/default/locale` на 12, `/etc/locale.conf` на 13) и в `/etc/profile.d/locale.sh`; постоянный `LC_ALL` не задается. Hostname: `hostnamectl set-hostname` и строка `127.0.1.1` в `/etc/hosts`. Часовой пояс: `timedatectl set-timezone`, при неудаче символьная ссылка `/etc/localtime` и `/etc/timezone`. Синхронизация времени (`common_enable_time_sync`): остается первый установленный из `chrony`, `ntpsec`, `ntp`, `openntpd`, `systemd-timesyncd`; `systemd-timesyncd` ставится только если нет ни одного; затем `timedatectl set-ntp true`. Ошибка этого шага не останавливает скрипт.
4. **Fish и Starship.** Пакеты `fish`, `git`, `curl`. Starship: пакет Debian, если он есть в репозитории (Debian 13), иначе закрепленный релиз 1.27.0 с проверкой SHA-256 в `/usr/local/bin/starship`. Для root и пользователя: `~/.config/starship.toml` (`starship preset nerd-font-symbols`) и `~/.config/fish/config.fish` профиля `vps`: пустое приветствие, `/usr/local/go/bin`, `~/go/bin` и `/usr/sbin` в PATH, хук `fnm env --use-on-cd --shell fish` (если `fnm` найден в PATH), алиасы и `starship init fish` в интерактивной сессии. Нет бинарника `fish` — стоп.
5. **Bash.** Пакет `bash-completion`. `~/.bashrc` профиля `vps` для root и пользователя: первым блоком `exec fish` для интерактивной сессии без `SSH_ORIGINAL_COMMAND`, история 50000 записей, `EDITOR=vim`, Starship для Bash, те же алиасы, функции `mkcd` и `extract`, блок fnm, блок Go, защитные алиасы `rm -i`, `cp -i`, `mv -i`. Чужой `.bashrc` (без заголовка профиля) перед заменой копируется в `~/.bashrc.backup.<время>.<суффикс>`; `.bashrc`, написанный этим скриптом, заменяется без новой копии.
6. **Go.** Закрепленный `go1.27.3` для `amd64` или `arm64` с `dl.google.com`: архив сверяется с SHA-256 из скрипта, распаковывается рядом с `/usr/local/go`, и только потом прежний каталог заменяется. `/etc/profile.d/golang.sh` с `GOROOT=/usr/local/go`, `GOPATH=$HOME/go` и PATH. Блок Go дописывается в `~/.bashrc`, только если там нет `GOROOT` (в `.bashrc` профиля он уже есть). Ошибка — стоп.
7. **Node.js через fnm.** Нужны `curl` и `unzip`: недостающие скрипт сначала ставит и пропускает шаг с предупреждением, только если они так и не появились. Бинарник fnm 1.39.0 из релиза GitHub с проверкой SHA-256 ставится в `~/.local/share/fnm/fnm` для root и для пользователя (под его учетной записью через `su -`), затем `fnm install --lts --use`, `fnm default`, `corepack enable`, если он есть. В `~/.bashrc` блок fnm добавляется, только если там нет `FNM_PATH`. Старые NVM-настройки не мигрируются. Ошибка — предупреждение, скрипт продолжается.
8. **RAM и размер swap.** Ставится `bc`. RAM меньше 3 GB: swap = 2 × RAM, `vm.swappiness = 60`; иначе swap = RAM / 2, `vm.swappiness = 10`. В обеих ветках результат округляется до целого числа GB (`printf %.0f` от `x + 0.5`): 3.9 GB RAM дает 2 GB swap.
9. **Обновление и пакеты.** `apt-get update` и `upgrade -y`. Во все источники APT (`sources.list`, `*.list`, `*.sources`) с компонентом `main` добавляются `contrib`, `non-free`, `non-free-firmware`; файл переписывается только если что-то добавлено; сломанный после этого индекс — стоп. Пакеты: `wget curl git htop iotop sysstat net-tools iptables ufw irqbalance fail2ban python3-systemd unattended-upgrades apt-listchanges needrestart ncdu tree vim nano tmux zip unzip gnupg ca-certificates lsb-release cmake make gcc g++ python3-venv fzf ripgrep fd-find bat xz-utils xdg-user-dirs`; недоступный пакет дает предупреждение. `iptables`, `ip6tables`, `iptables-save`, `ip6tables-save` переключаются на `legacy` через `update-alternatives` (до включения UFW). Ссылки `/usr/bin/bat -> batcat` и `/usr/bin/fd -> fdfind`, если имен `bat` и `fd` нет.
10. **Ядро.** Удаляются источник и ключ XanMod прежних версий. Debian 12: `/etc/apt/sources.list.d/debian-backports.sources` (deb822, `bookworm-backports`, `Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg`), `apt-get install -t bookworm-backports linux-image-<arch> linux-headers-<arch>`; если после установки версии пакетов не из backports — стоп. Debian 13: те же пакеты из основного репозитория; не установились — стоп.
11. **Docker.** Удаляются `docker.io docker-doc docker-compose podman-docker containerd runc`. Ключ Docker принимается только с закрепленным отпечатком `9DC858229FC7DD38854AE2D88D81803C0EBFCD88` в `/etc/apt/keyrings/docker.gpg`; источник `/etc/apt/sources.list.d/docker.sources` (deb822, `Architectures: $(dpkg --print-architecture)`); пакеты `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin` (ошибка — стоп). `/etc/docker/daemon.json`: `json-file` с `max-size 10m` и `max-file 3`, `overlay2`, BuildKit; `default-address-pools` и `default-ulimits` не задаются. Drop-in `docker.service.d/override.conf` заменяет `ExecStart` на `/usr/bin/dockerd -H unix:///var/run/docker.sock` (socket activation). Перед стартом завершаются старые `dockerd` (`pkill -9`), включаются `docker` и `docker.socket`, сокет получает `root:docker` и `660`, пользователь добавляется в группу `docker`.
12. **sysctl и модули.** Если нет `/etc/sysctl.conf`, он создается; копия `/etc/sysctl.conf.backup.<дата>`. Буферы по RAM: при `free -m` меньше 3000 MB — `rmem_max`/`wmem_max` 33554432 и `rmem_default`/`wmem_default` 1048576, иначе 67108864 и 2097152. `/etc/modules-load.d/99-vps-modules.conf` (`tcp_bbr`, `tun`, `wireguard`) и `modprobe` сразу. `/etc/sysctl.d/99-vps-optimization.conf` применяется `sysctl -e -p`; параметры, которых нет в ядре, пропускаются.

    <details>
    <summary>Значения /etc/sysctl.d/99-vps-optimization.conf</summary>

    | Параметр | Значение |
    |---|---|
    | `net.core.rmem_default`, `net.core.wmem_default` | 2097152 (1048576 при RAM < 3000 MB) |
    | `net.core.rmem_max`, `net.core.wmem_max` | 67108864 (33554432 при RAM < 3000 MB) |
    | `net.ipv4.tcp_rmem`, `net.ipv4.tcp_wmem` | `4096 1048576 <rmem_max>` |
    | `net.ipv4.udp_rmem_min`, `net.ipv4.udp_wmem_min` | 16384 |
    | `net.core.netdev_max_backlog`, `net.core.somaxconn` | 32768 |
    | `net.ipv4.tcp_max_syn_backlog` | 16384 |
    | `net.ipv4.tcp_slow_start_after_idle` | 0 |
    | `net.ipv4.tcp_tw_reuse` | 1 |
    | `net.ipv4.tcp_fin_timeout` | 15 |
    | `net.ipv4.ip_local_port_range` | `10240 65535` |
    | `net.ipv4.tcp_fastopen` | 3 |
    | `net.ipv4.tcp_keepalive_time`, `_intvl`, `_probes` | 300, 30, 3 |
    | `net.ipv4.tcp_window_scaling`, `tcp_timestamps`, `tcp_sack` | 1 |
    | `net.ipv4.tcp_max_orphans` | 32768 |
    | `net.ipv4.tcp_max_tw_buckets` | 131072 |
    | `net.ipv4.tcp_mtu_probing` | 1 |
    | `net.core.default_qdisc` | `fq` |
    | `net.ipv4.tcp_congestion_control` | `bbr` |
    | `net.netfilter.nf_conntrack_max` | 262144 |
    | `net.netfilter.nf_conntrack_tcp_timeout_established` | 1800 |
    | `net.netfilter.nf_conntrack_udp_timeout`, `_udp_timeout_stream` | 60, 120 |
    | `net.netfilter.nf_conntrack_generic_timeout` | 120 |
    | `fs.file-max` | 2097152 |
    | `fs.inotify.max_user_watches`, `max_user_instances` | 524288, 512 |
    | `vm.swappiness` | 10 (60 при RAM < 3 GB) |
    | `vm.vfs_cache_pressure` | 60 |
    | `vm.dirty_ratio`, `vm.dirty_background_ratio` | 20, 10 |
    | `vm.dirty_expire_centisecs`, `vm.dirty_writeback_centisecs` | 3000, 500 |
    | `vm.min_free_kbytes` | 65536 |
    | `vm.overcommit_memory`, `vm.overcommit_ratio` | 1, 50 |
    | `vm.zone_reclaim_mode` | 0 |
    | `net.ipv4.ip_forward`, `net.ipv6.conf.all.forwarding` | 1 |
    | `net.ipv4.conf.all.rp_filter`, `net.ipv4.conf.default.rp_filter` | 2 (loose) |
    | `net.ipv4.icmp_echo_ignore_broadcasts`, `icmp_ignore_bogus_error_responses` | 1 |
    | `accept_source_route` (ipv4/ipv6, all/default) | 0 |
    | `send_redirects`, `accept_redirects`, `secure_redirects` (ipv4 all/default), `accept_redirects` (ipv6 all/default) | 0 |
    | `net.ipv4.tcp_syncookies` | 1 |
    | `kernel.panic`, `kernel.panic_on_oops` | 10, 1 |
    | `kernel.pid_max`, `kernel.threads-max` | 65536 |

    </details>

13. **Swap.** `/swapfile` размером из шага 8. Активный файл того же размера остается (`chmod 600`); файл другого размера выключается `swapoff` и создается заново (`fallocate`, при неудаче `dd`), `mkswap`, `swapon`. Если `swapoff` не смог вернуть страницы в RAM, прежний swap остается, и итог сообщает «not resized». В `/etc/fstab` остается ровно одна строка `/swapfile none swap sw 0 0`; строка оператора с другими полями (например, `pri=`) не трогается. Если `/swapfile` — не обычный файл, шаг пропускается.
14. **UFW.** По порядку: `ufw --force enable`, `default deny incoming`, `default allow outgoing`, `DEFAULT_FORWARD_POLICY="ACCEPT"` в `/etc/default/ufw`, `ufw default allow forward` (ufw понимает `forward` как `routed`, проверено на ufw 0.36.2 в Debian 12, и сразу применяет политику пересылки), затем `allow 22/tcp`, `80/tcp`, `443/tcp`. Правило для SSH появляется после включения UFW; текущая сессия сохраняется.
15. **Fail2Ban.** `/etc/fail2ban/jail.local`: `[DEFAULT]` `bantime = 3600`, `findtime = 600`, `maxretry = 5`, `destemail = root@localhost`, `sendername = Fail2Ban`, `backend = systemd` (через `python3-systemd`, без `/var/log/auth.log`); `[sshd]` `enabled = true`, `port = 22`, `maxretry = 3`, `bantime = 7200`. Копия прежнего файла делается только при изменении содержимого; сервис включается и перезапускается.
16. **Лимиты.** `/etc/security/limits.d/99-vps-limits.conf`: `nofile` и `nproc` 65535 для `*` и `root`, `memlock unlimited` для `*`. Это единственное место лимитов; `/etc/security/limits.conf` не меняется.
17. **Автообновления.** `/etc/apt/apt.conf.d/50unattended-upgrades`: только `${distro_id}:${distro_codename}-security`, удаление неиспользуемых ядер и зависимостей, без автоматической перезагрузки. `/etc/apt/apt.conf.d/20auto-upgrades`: ежедневные списки и обновления, `AutocleanInterval 7`.
18. **Журнал.** `/etc/systemd/journald.conf.d/00-journal-size.conf`: `SystemMaxUse=500M`, `SystemMaxFileSize=100M`, `RuntimeMaxUse=100M`; `systemd-journald` перезапускается.
19. **Закалка SSH** (стоп при ошибке). Копия `/etc/ssh/sshd_config.backup.<дата>`. Drop-in `/etc/ssh/sshd_config.d/00-optimize-hardening.conf`:

    ```text
    # SSH Hardening - VPS Optimization
    PermitRootLogin no
    PasswordAuthentication no
    PubkeyAuthentication yes
    PermitEmptyPasswords no
    KbdInteractiveAuthentication no
    ChallengeResponseAuthentication no
    X11Forwarding no
    ClientAliveInterval 300
    ClientAliveCountMax 2
    MaxAuthTries 3
    AllowUsers <user>
    ```

    sshd берет первое прочитанное значение параметра, а `Include /etc/ssh/sshd_config.d/*.conf` в Debian стоит выше остальных строк `sshd_config` и читает drop-in по порядку имен. Поэтому файл назван `00-...` и читается раньше `50-cloud-init.conf` с `PasswordAuthentication yes`. Порядок проверки: `sshd -t`, затем `sshd -T` через `common_sshd_effective_mismatches` для `permitrootlogin no`, `passwordauthentication no`, `pubkeyauthentication yes`, `permitemptypasswords no`, `kbdinteractiveauthentication no`, `allowusers <user>`. Если `sshd -t` не прошел, значения задает файл, прочитанный раньше (`00-aaa.conf`, строка выше `Include` в `sshd_config`), `sshd_config` не подключает каталог drop-in или `sshd -T` не выполнился, скрипт называет расходящиеся параметры, возвращает прежний drop-in (или удаляет новый), не перезапускает sshd и останавливается. `sshd -T` без `-C` не раскрывает блоки `Match`: условия в них проверка не учитывает. При успехе перезапускается `ssh.service` (или `sshd.service`); неудачный перезапуск — стоп с сообщением, что конфигурация записана, но не активна. Drop-in `99-hardening.conf` прежних версий скриптов удаляется после записи нового, если `common_sshd_legacy_dropin_is_ours` узнает его: заголовок `# SSH Hardening - VPS Optimization` или `# Minimal Amnezia host SSH baseline`, либо ровно четыре строки мини-ПК (`PermitRootLogin no`, `PasswordAuthentication no`, `PubkeyAuthentication yes`, `AllowUsers <user>`); файл с тем же именем, но другим содержимым остается. Другие параметры sshd (`AllowTcpForwarding`, `MaxSessions`, `Port`) скрипт не задает: ваши drop-in остаются в силе. `X11Forwarding`, `ClientAlive*`, `MaxAuthTries` можно переопределить в drop-in с именем раньше по сортировке (например, `00-00-local.conf`); пять параметров входа и `AllowUsers` так переопределить нельзя — скрипт остановится на сверке.
20. **tmpfs.** Если в `/etc/fstab` нет `tmpfs /tmp`, дописываются `/tmp` (1G, `nosuid,nodev`, без `noexec`) и `/var/tmp` (512M, `noexec`). Монтируются после перезагрузки.
21. **Службы.** `bluetooth`, `cups`, `avahi-daemon` выключаются и останавливаются, если были включены.
22. **Планировщики I/O.** `/etc/udev/rules.d/60-ioschedulers.conf`: NVMe — `none`, `nr_requests 1024`, `read_ahead_kb 256`, `rq_affinity 2`; SATA SSD — `mq-deadline`, `nr_requests 512`, `read_ahead_kb 128`, `rq_affinity 2`; HDD — `bfq`, `read_ahead_kb 256`. `udevadm control --reload-rules` и `udevadm trigger`.
23. **CPU governor.** Пакет `linux-cpupower`. Если есть `/sys/devices/system/cpu/cpu0/cpufreq`, выбирается первый доступный из `schedutil`, `powersave`, `ondemand`, иначе `performance`; служба `/etc/systemd/system/cpu-governor.service` (`cpupower frequency-set -g <governor>`) включается и запускается. На большинстве VPS cpufreq нет — шаг пропускается с предупреждением.
24. **Утилиты.** `/usr/local/bin/vps-monitor.sh` (ядро, CPU и governor, память, диски и планировщики, BBR и qdisc, `ss -s`, swap, VPN-интерфейсы `tun`/`wg`/`ppp`), `vps-cleanup.sh` (`apt-get clean`, `autoclean`, `autoremove`, `journalctl --vacuum-time=7d`, старые ядра кроме текущего и одного предыдущего, файлы старше 7 дней в `/tmp` и `/var/tmp`), `network-test.sh` (ставит `speedtest-cli` при необходимости и запускает его, затем `netstat -s`), `vps-info.sh` (ОС, ядро, CPU, память, swap, диск, публичный IP через `ifconfig.me`/`icanhazip.com`, `ufw status numbered`, Docker). `/etc/cron.weekly/vps-cleanup` запускает очистку еженедельно с выводом в `/var/log/vps-cleanup.log`.
25. **Итог.** Сводка, напоминание проверить `ssh <user>@<ip>` и `sudo -l` во втором терминале, вывод `vps-info.sh`, вопрос о перезагрузке. Перезагрузка нужна для нового ядра, локали, членства в группе `docker` и tmpfs.

## Файлы, которые пишет скрипт

`<дата>` — `date +%F` (ГГГГ-ММ-ДД). Копии с таким именем делаются один раз в день: `cp` перезаписывает копию того же дня.

| Путь | Что | Как откатить |
|---|---|---|
| `/var/log/vps_optimization.log` | лог скрипта | удалить |
| `/usr/local/bin/gum` | gum 0.17.0 (в `TUI_BACKEND=auto` при выводе в терминал, при `TUI_BACKEND=gum` всегда) | удалить |
| `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`, `/etc/network/interfaces.d/50-cloud-init.disabled-by-optimize.<дата>-<ЧЧММСС>` | отключение сетевой конфигурации cloud-init (только при дублировании с ifupdown) | удалить `.cfg`, вернуть файлу имя `50-cloud-init` |
| `/etc/passwd`, `/etc/group`, `/home/<user>` | пользователь в группах `sudo` и `docker` | `deluser <user>` (с `--remove-home` при необходимости); `gpasswd -d <user> docker` |
| `/etc/sudoers.d/<user>`, `/etc/sudoers.d/root` | `NOPASSWD:ALL`, записаны через `visudo -cf` | удалить файлы |
| `~<user>/.ssh/authorized_keys` | строка с ключом | удалить строку |
| `/etc/locale.gen`, `/etc/default/locale` (Debian 12) или `/etc/locale.conf` (Debian 13), `/etc/profile.d/locale.sh` | `en_US.UTF-8` и `ru_RU.UTF-8`, `LANG`, `LANGUAGE` | `update-locale LANG=<прежняя>`; удалить `locale.sh`; строки в `locale.gen` закомментировать и выполнить `locale-gen` |
| `/etc/hostname`, `/etc/hosts`, `/etc/localtime`, `/etc/timezone` | hostname и часовой пояс (только если введены) | `hostnamectl set-hostname <прежнее>`, `timedatectl set-timezone <прежний>` |
| `~/.config/starship.toml`, `~/.config/fish/config.fish` (root и `<user>`) | пресет и конфигурация Fish | удалить; `apt-get purge fish` |
| `~/.bashrc` (root и `<user>`), `~/.bashrc.backup.<время>.<суффикс>` | `.bashrc` профиля и копия прежнего | вернуть копию на место |
| `/usr/local/bin/starship` (если нет пакета Debian) | Starship 1.27.0 | удалить |
| `/usr/local/go`, `/etc/profile.d/golang.sh` | Go 1.27.3 | `rm -rf /usr/local/go`, удалить `golang.sh` и блок `# Go configuration` в `~/.bashrc` |
| `~/.local/share/fnm`, `~/.local/state/fnm-runtime` (root и `<user>`) | fnm и Node.js LTS | удалить каталоги и блок `# fnm` в `~/.bashrc` |
| `/etc/apt/sources.list`, `/etc/apt/sources.list.d/*.list`, `*.sources` | компоненты `contrib non-free non-free-firmware` | убрать компоненты из строк `deb`/`Components:` |
| `/etc/apt/sources.list.d/debian-backports.sources` (Debian 12) | источник `bookworm-backports` | удалить файл; затем `apt-get install linux-image-$(dpkg --print-architecture)/bookworm`, перезагрузка в ядро bookworm и `apt-get purge 'linux-image-*+bpo*' 'linux-headers-*+bpo*'` |
| `/etc/alternatives/iptables`, `ip6tables`, `iptables-save`, `ip6tables-save` | `legacy` | `update-alternatives --set iptables /usr/sbin/iptables-nft` (и остальные) |
| `/usr/bin/bat`, `/usr/bin/fd` | ссылки на `batcat` и `fdfind` | удалить ссылки |
| `/etc/apt/keyrings/docker.gpg`, `/etc/apt/sources.list.d/docker.sources` | репозиторий Docker | удалить оба файла |
| `/etc/docker/daemon.json`, `/etc/docker/daemon.json.backup.<дата>[.N]` | настройки dockerd, копия прежнего файла при изменении | вернуть копию; `apt-get purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin` |
| `/etc/systemd/system/docker.service.d/override.conf` | `ExecStart` для socket activation | удалить, `systemctl daemon-reload` |
| `/etc/sysctl.conf` (если отсутствовал), `/etc/sysctl.conf.backup.<дата>` | заглушка и копия | вернуть копию |
| `/etc/modules-load.d/99-vps-modules.conf` | `tcp_bbr`, `tun`, `wireguard` | удалить |
| `/etc/sysctl.d/99-vps-optimization.conf` | sysctl из таблицы выше | удалить, `sysctl --system`, перезагрузка для возврата умолчаний ядра |
| `/swapfile`, строка `/swapfile none swap sw 0 0` в `/etc/fstab` | swap-файл | `swapoff /swapfile`, `rm /swapfile`, удалить строку |
| `/etc/default/ufw`, `/etc/ufw/*.rules` | `DEFAULT_FORWARD_POLICY="ACCEPT"`, правила `22`, `80`, `443/tcp` | сначала `ufw disable`, затем `ufw delete allow <порт>/tcp` и `ufw default deny routed` (при `deny incoming` новые SSH-сессии закрываются между командами) |
| `/etc/fail2ban/jail.local`, `jail.local.backup.<дата>[.N]` | джейл `sshd`, копия при изменении | вернуть копию или удалить, `systemctl restart fail2ban` |
| `/etc/security/limits.d/99-vps-limits.conf` | лимиты 65535 | удалить |
| `/etc/apt/apt.conf.d/50unattended-upgrades`, `20auto-upgrades` | автообновления безопасности | `apt-get purge unattended-upgrades` или удалить файлы |
| `/etc/systemd/journald.conf.d/00-journal-size.conf` | лимиты журнала | удалить, `systemctl restart systemd-journald` |
| `/etc/ssh/sshd_config.backup.<дата>` | копия `sshd_config` (сам файл не меняется) | — |
| `/etc/ssh/sshd_config.d/00-optimize-hardening.conf` | закалка SSH; `99-hardening.conf` прежних версий удаляется | удалить, `sshd -t`, `systemctl restart ssh` |
| `/etc/fstab` | строки tmpfs для `/tmp` и `/var/tmp` | удалить строки, перезагрузка |
| `/etc/udev/rules.d/60-ioschedulers.conf` | планировщики I/O | удалить, `udevadm control --reload-rules`, перезагрузка |
| `/etc/systemd/system/cpu-governor.service` | governor при загрузке | `systemctl disable --now cpu-governor.service`, удалить |
| `/usr/local/bin/vps-monitor.sh`, `vps-cleanup.sh`, `network-test.sh`, `vps-info.sh`, `/etc/cron.weekly/vps-cleanup`, `/var/log/vps-cleanup.log` | утилиты и еженедельная очистка | удалить |

Удаляются: `/etc/apt/sources.list.d/xanmod-release.list` и `/usr/share/keyrings/xanmod-archive-keyring.gpg` (XanMod прежних версий), пакеты `docker.io docker-doc docker-compose podman-docker containerd runc`.

## Проверка после запуска

Выполняйте от нового пользователя после перезагрузки (`uname -r`, группа `docker` и tmpfs применяются после нее).

```bash
# SSH: действующие значения sshd
sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|allowusers) '
# permitrootlogin no / passwordauthentication no / pubkeyauthentication yes /
# kbdinteractiveauthentication no / allowusers <user>

# Ядро (Debian 12: `uname -r` содержит `+bpo`)
uname -r
apt policy linux-image-$(dpkg --print-architecture) | head -n 3

# sysctl
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.core.rmem_max
# bbr / fq / 1 / 2 / 67108864 (33554432 при RAM < 3000 MB)
lsmod | grep -E '^(tcp_bbr|tun|wireguard) '

# Swap
swapon --show
# NAME      TYPE SIZE ...   -> /swapfile file <размер из шага 8>
grep swapfile /etc/fstab
# /swapfile none swap sw 0 0

# Firewall и Fail2Ban
sudo ufw status verbose
# Status: active; Default: deny (incoming), allow (outgoing), allow (routed); 22,80,443/tcp ALLOW IN
sudo fail2ban-client status sshd

# Службы
systemctl is-active docker docker.socket fail2ban systemd-journald
timedatectl | grep -E 'NTP service|synchronized'
# NTP service: active

# Лимиты, локаль, журнал
ulimit -n            # 65535
locale -a | grep -E '^(en_US|ru_RU)\.utf8$'
journalctl --disk-usage

# Инструменты (от пользователя, в новой сессии)
sudo -l             # (ALL) NOPASSWD: ALL
docker ps           # без sudo
go version          # go1.27.3
fnm --version && node --version
echo $SHELL; fish --version   # SHELL остается /bin/bash, интерактивная сессия в Fish
```

## Повторный запуск и откат

Повторный запуск того же скрипта безопасен по коду в следующем:

- Существующий пользователь не пересоздается; ключ не дублируется в `authorized_keys`; sudoers перезаписываются тем же содержимым через `visudo -cf`.
- Локали генерируются с `--keep-existing`; hostname и часовой пояс остаются, если нажать Enter.
- `.bashrc` профиля заменяется без новой копии (копия делается только для чужого файла); `config.fish` и `starship.toml` перезаписываются.
- Go заменяется той же закрепленной версией; блоки Go и fnm в `.bashrc` не дублируются (`grep GOROOT`, `grep FNM_PATH`).
- fnm и Node.js LTS ставятся заново под пользователем.
- Источники APT переписываются только при добавлении компонента; источники backports и Docker — тем же содержимым.
- `daemon.json` и `jail.local` получают копию `*.backup.<дата>` только при изменении содержимого; одинаковый файл не трогается. dockerd при этом завершается `pkill -9 dockerd` и запускается заново — учитывайте на сервере с работающими контейнерами.
- Swap нужного размера остается с тем же inode; в `fstab` остается одна строка. Изменился объем RAM — файл пересоздается.
- Правила UFW не дублируются; лимиты, sysctl, модули, journald, udev, governor и утилиты перезаписываются тем же содержимым.
- Drop-in SSH прежнего запуска сохраняется во временной копии и возвращается, если новый не прошел `sshd -t` или сверку `sshd -T`.

Остатки прежних версий, которые повторный запуск не убирает: блок в `/etc/security/limits.conf` (на действующие значения не влияет, `limits.d` читается позже).

Откат: восстановите снимок VPS, сделанный до запуска. Без снимка используйте колонку «Как откатить» в таблице выше; порядок: сначала SSH (проверка входа во втором терминале), затем UFW, затем остальное. Чтобы снова разрешить вход по паролю или root временно, создайте drop-in с именем раньше `00-optimize-hardening.conf` (например, `00-00-local.conf`), проверьте `sshd -t` и перезапустите `ssh`; при следующем запуске скрипта такой файл остановит его на сверке.

## Решение проблем

| Симптом | Причина | Действие |
|---|---|---|
| Скрипт остановился на «sshd does not take the hardening values» и перечислил параметры | Значение задает drop-in с именем раньше `00-optimize-hardening.conf`, строка выше `Include` в `/etc/ssh/sshd_config` или `sshd_config` без `Include sshd_config.d/*.conf` | Найдите источник: `grep -rn -i '<параметр>' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/`; уберите переопределение или верните `Include /etc/ssh/sshd_config.d/*.conf` первой строкой; sshd не перезапускался, старая сессия жива — запустите скрипт снова |
| После закалки не входит по SSH | Ключ не в `~<user>/.ssh/authorized_keys`, вход под другим именем (`AllowUsers`), либо клиент предлагает пароль | Из второй сессии (или консоли провайдера): `sudo sshd -T \| grep allowusers`, `cat ~<user>/.ssh/authorized_keys`; `ssh -i <ключ> -o IdentitiesOnly=yes <user>@<ip>`; в крайнем случае удалите drop-in и `systemctl restart ssh` |
| `Debian Backports kernel ... was not installed` | Нет доступа к `deb.debian.org`, индекс не обновился или пакет установлен не из `bookworm-backports` | `apt policy linux-image-$(dpkg --print-architecture)`, `apt-get update`, повторите запуск |
| `cannot change locale (ru_RU.UTF-8)` при входе по SSH | Клиент передает `LC_*`, а на сервере, настроенном прежней версией, нет локали | Выполните в Bash: `sudo apt-get install -y locales`, включите `en_US.UTF-8 UTF-8` и `ru_RU.UTF-8 UTF-8` в `/etc/locale.gen`, `sudo locale-gen --keep-existing`, проверьте `locale -a`; то же описано в [руководстве Amnezia](README_AMNEZIA_HOST.md) |
| Терминал VSCode (Remote SSH, Tunnels) не перешел в Fish | В `~/.bashrc` нет блока `exec fish`, либо сессия неинтерактивна | Убедитесь, что `~/.bashrc` начинается с `# VPS Optimized Bash Configuration` и содержит `exec fish`; откройте новый терминал. Внутренние команды VSCode идут через Bash и работать не перестают: `/etc/passwd` оставлен `/bin/bash` |
| В Fish нет `fnm` или `node` | `config.fish` подключает `fnm env`, только если `fnm` уже в PATH | В Fish: `fish_add_path ~/.local/share/fnm`; затем `fnm env --use-on-cd --shell fish \| source` |
| `npm error code EACCES` (`Your cache folder contains root-owned files`) | Каталоги npm или fnm принадлежат root | `sudo chown -R $(whoami):$(whoami) ~/.npm ~/.local/share/fnm ~/.config && npm cache clean --force`; скрипт ставит fnm от имени пользователя, ошибка возможна после ручной установки от root |
| `docker ps` требует sudo | Членство в группе `docker` действует с новой сессии | Перелогиньтесь или `newgrp docker`; проверка `groups $USER`, `sudo usermod -aG docker $USER` |
| Порт контейнера открыт наружу, хотя UFW запрещает входящие | Docker пишет правила iptables (`PREROUTING`) в обход цепочек UFW | Публикуйте порты на `127.0.0.1` (`-p 127.0.0.1:<port>:<port>`) или используйте `ufw-docker` |
| `Swap file not resized ...; the previous swap stays` | `swapoff` не смог вернуть страницы в RAM | Освободите память или перезагрузитесь и запустите скрипт снова; прежний swap работает |
| `CPU frequency scaling not available` | У виртуального CPU нет cpufreq | Нормально для VPS; governor не настраивается |
| `apt-get update failed ... dpkg lock is still held` | Другой менеджер пакетов (unattended-upgrades) держит блокировку дольше 300 с | Дождитесь `systemctl is-active apt-daily-upgrade.service` = inactive и повторите |
| После перезагрузки сеть не поднялась на cloud-образе | Скрипт отключил сетевую конфигурацию cloud-init из-за дубля с ifupdown | Проверьте интерфейсы в `/etc/network/interfaces`; для возврата удалите `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` и верните имя `50-cloud-init` |
| Старые ядра занимают место | Ядра удаляются `unattended-upgrades` и еженедельным `vps-cleanup.sh` | `dpkg --list \| grep linux-image`, `sudo apt autoremove --purge` |
| Нужно проверить Docker | — | `sudo systemctl status docker`, `docker info`, `journalctl -u docker -n 50` |

## См. также

- [README](../README.md) — все скрипты, [Версии и выпуски](../README.md#версии-и-выпуски)
- [Оглавление документации](README.md)
- [Устройство репозитория](ARCHITECTURE.md) — встроенные копии `lib/`, `optimize_main`, тесты, CI
- [Обновление Debian 11/12 до 13](README_UPGRADE.md) — перед оптимизацией VPS
- [Руководство Amnezia host](README_AMNEZIA_HOST.md) — та же закалка SSH и sysctl для хоста AmneziaVPN
- [SECURITY.md](../SECURITY.md) — как сообщить об уязвимости
- [CONTRIBUTING.md](../CONTRIBUTING.md) — проверки перед PR
- [CHANGELOG.md](../CHANGELOG.md) — изменения по выпускам
- [LICENSE](../LICENSE) — MIT

<details>
<summary>История версий optimize_vps.sh до выпуска v2026.10.21</summary>

- 3.0.0 (2026-09-04): ядро Debian Backports вместо XanMod (amd64 и arm64); Fish + Starship с пресетом `nerd-font-symbols`; сетевые буферы до 64 MB, очереди 32768, conntrack 262144; Fail2Ban с `backend = systemd`; UFW с `DEFAULT_FORWARD_POLICY="ACCEPT"` и предупреждение об обходе UFW контейнерами; `KbdInteractiveAuthentication no`; модули `tcp_bbr`, `tun`, `wireguard` через `modules-load.d`; sudoers через `visudo -cf`; домашние каталоги через `getent passwd`; `/tmp` без `noexec`; loose `rp_filter = 2`.
- 2.3.0 (2026-02-04): Debian 12/13; проверка имени пользователя с повтором; deb822-aware обогащение источников APT; `linux-cpupower`.
- 2.2.0 (2025-12-12): Zsh; менеджер Node.js прежнего поколения с автообновлением и `npm` без sudo; исправление терминала VSCode; одинаковые настройки для root и пользователя.
- 2.0.0: Go с проверкой SHA-256; Node.js LTS; упрощенный `daemon.json`; iptables-legacy; socket activation для Docker.
- 1.0.0: базовый скрипт, ядро XanMod, Zsh + Starship, Docker CE, закалка SSH, утилиты мониторинга.

</details>
