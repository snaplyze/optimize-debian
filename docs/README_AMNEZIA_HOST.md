# Amnezia Host Baseline (`optimize_amnezia_host.sh`)

**🆕 Версия 0.3.0** - **10G sysctl** (буферы до 64MB, очереди 32k), **Fish + Starship** (`nerd-font-symbols`), опциональный **Debian Backports kernel** (`--kernel-backports`), safe two-phase UFW firewall, vanilla Docker CE.

Минимальный baseline для **Debian 12/13 VPS**, который готовит сервер под **AmneziaVPN self-hosted через приложение**.

Скрипт готовит **host**, а не сами VPN-протоколы:
- приложение Amnezia подключается к серверу по SSH
- затем само ставит Docker-контейнеры протоколов
- скрипт **не** устанавливает вручную AmneziaWG, XRay, OpenVPN, Cloak или другие протоколы

---

## Что делает скрипт

`optimize_amnezia_host.sh` включает специализированный baseline под 10G и Amnezia:
- проверка Debian 12 / Debian 13
- `apt update` + `apt upgrade`
- минимальные пакеты безопасности и сетевой базы (включая `python3-systemd` для Fail2Ban)
- установка `locales` и генерация `en_US.UTF-8` / `ru_RU.UTF-8` для SSH-клиентов, с сохранением системного языка и ранее установленных локалей
- при необходимости создаёт target user
- добавление выбранного пользователя в **sudo group** (`sudo`) для совместимости с приложениями, которые проверяют именно group membership
- SSH hardening для выбранного пользователя с поддержкой кастомного порта (`--ssh-port`)
- Fail2Ban с бэкендом `systemd`
- **10 Gbps сетевой стек:** BBR, fq pacing, адаптивные BDP буферы до 32–64MB, расширенные очереди `netdev_max_backlog` и `somaxconn`, масштабированный conntrack до 262k
- персистентная загрузка модулей ядра: `tcp_bbr`, `tun`, `wireguard`
- **Fish Shell + Starship** с пресетом `nerd-font-symbols` (активируется по умолчанию, отключается через `--skip-fish`)
- гибридная модель шелла: `/bin/bash` остаётся системным shell в `/etc/passwd` для совместимости с неинтерактивными скриптами Amnezia App, а вход в Fish выполняется автоматически только в интерактивных сессиях человека (`~/.bashrc`)
- опциональное обновление ядра до актуального официального LTS из Debian Backports (`--kernel-backports`)
- swapfile **2G по умолчанию** для VPS с небольшим объёмом RAM
- UFW с двухфазной моделью firewall (`bootstrap` / `locked`) и `DEFAULT_FORWARD_POLICY="ACCEPT"` для беспрепятственного роутинга VPN
- настраиваемые порты `--ssh-port`, `--xray-port`, `--amneziawg-port`
- опциональная установка **vanilla Docker CE**
- Docker deb822 source с `Architectures: $(dpkg --print-architecture)`
- добавление выбранного пользователя в группу `docker`
- сохранение уже установленного time sync daemon'а (`chrony`, `ntpsec`, `ntp`, `openntpd`, `systemd-timesyncd`)

---

## Что скрипт не делает

Скрипт намеренно **не** включает heavy VPS/dev компоненты из `optimize_vps.sh`:
- языки программирования и dev-стек (Go, Node.js / fnm)
- кастомный Docker `daemon.json` (остаётся vanilla Docker без переопределений)
- systemd override для Docker
- сложные swap heuristics
- CPU governor tuning (`schedutil`)
- I/O scheduler tuning
- мониторинговые helper scripts (`vps-monitor.sh`, `vps-cleanup.sh`)
- ручную установку AmneziaWG / XRay (их разворачивает само приложение)

Если нужен полный VPS tuning с разработкой, Node.js, Go и dev-окружением, используй `optimize_vps.sh`.

---

## Поддерживаемые ОС

- Debian 12 (Bookworm)
- Debian 13 (Trixie)

Non-Debian и Debian 11 не поддерживаются.

---

## Использование

### Целевой пользователь

Скрипт оставляет SSH-доступ только одному операторскому пользователю (`AllowUsers`), выдаёт ему sudo без пароля и добавляет в группу `docker`. Кто это будет:

- `--user <имя>` — явно заданный пользователь (`root` не допускается: при `PermitRootLogin no` он остался бы без входа);
- без `--user` — пользователь, запустивший скрипт через `sudo` (`SUDO_USER`), например `sudo ./optimize_amnezia_host.sh --yes`;
- запуск от root без `sudo` (например, `bash <(curl ...)` под root) без `--user` останавливается с ошибкой: молчаливого значения по умолчанию нет.

Если скрипт запустил не целевой пользователь (`SUDO_USER`, а без `sudo` — пользователь входа, в том числе root), скрипт предупредит, что после перезапуска SSH эта учётная запись потеряет вход по SSH (`AllowUsers` пускает только целевого пользователя): в интерактивном режиме попросит подтверждение, с `--yes` только выведет предупреждение. Перед запуском проверь, что у целевого пользователя есть рабочий ключ.

В примерах ниже имя пользователя берётся из переменной `OPERATOR`. Задай её один раз (замени `ops` на своё имя) в той же сессии оболочки, где запускаешь команды; там, где запуск идёт через `sudo` обычным пользователем, `--user` можно не указывать.

```bash
OPERATOR=ops
```

### Быстрый запуск (bash + curl, под root)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_amnezia_host.sh) --user "$OPERATOR" --yes
```

### Рекомендуемый режим: host baseline + Docker CE

```bash
sudo ./optimize_amnezia_host.sh --yes
```

Под root без `sudo` добавь `--user "$OPERATOR"`.

Этот режим:
- создаёт и включает swapfile **2G** (если активного swap ещё нет)
- ставит Docker CE из официального репозитория
- включает Docker service
- добавляет целевого пользователя в **sudo group**
- включает passwordless sudo для целевого пользователя и `root` (`/etc/sudoers.d/<имя>`, `/etc/sudoers.d/root`) — в любом запуске, не только с `--create-user`
- добавляет целевого пользователя в группу `docker`
- не трогает Docker daemon tuning

### Если пользователя ещё нет и его нужно создать сразу

```bash
sudo ./optimize_amnezia_host.sh --user "$OPERATOR" --create-user --yes
```

Что делает `--create-user`:
- создаёт пользователя с домашней директорией
- добавляет ключи из `authorized_keys` invoking `sudo` user
- не дублирует ключи, которые уже есть в `authorized_keys`
- добавляет пользователя в **sudo group**
- включает passwordless sudo для нового пользователя и для `root`

Если invoking `sudo` user не имеет `authorized_keys`, используй один из явных вариантов:

```bash
sudo ./optimize_amnezia_host.sh --user "$OPERATOR" --create-user \
  --ssh-public-key 'ssh-ed25519 AAAA... your-key' --yes

sudo ./optimize_amnezia_host.sh --user "$OPERATOR" --create-user \
  --ssh-public-key-file "/root/$OPERATOR.pub" --yes
```

Если `--user` указывает на уже существующего пользователя, перед SSH hardening у него должен быть непустой `authorized_keys` или нужно явно передать `--ssh-public-key` / `--ssh-public-key-file`. Скрипт не должен закрывать парольный SSH без рабочего ключа.

### Если Docker должен ставить сам Amnezia app

```bash
sudo ./optimize_amnezia_host.sh --skip-docker --yes
```

### Если swap уже настроен вручную и менять его не нужно

```bash
sudo ./optimize_amnezia_host.sh --skip-swap --yes
```

### После фиксации AmneziaWG на 8443/udp

```bash
sudo ./optimize_amnezia_host.sh --firewall-phase locked --yes
```

---

## Опции

```text
--user <name>             существующий операторский пользователь (по умолчанию: пользователь, запустивший sudo; от root без sudo обязателен)
--create-user             создать пользователя, если он ещё не существует
--ssh-public-key <key>    публичный ключ для нового пользователя
--ssh-public-key-file <p> файл с публичными ключами для нового пользователя
--ssh-port <port>         порт SSH для службы и фаервола (по умолчанию: 22)
--xray-port <port>        целевой порт XRay (по умолчанию: 443)
--amneziawg-port <port>   целевой порт AmneziaWG (по умолчанию: 8443)
--swap-size-gb <size>     размер swapfile в GiB (по умолчанию: 2)
--skip-swap               не создавать swapfile автоматически
--skip-docker             не ставить Docker CE
--skip-fish               не ставить Fish shell и Starship prompt
--kernel-backports        установить официальное LTS ядро из Debian Backports (Debian 12);
                          если оно не установилось из Backports, скрипт останавливается
--firewall-phase <phase>  bootstrap | locked
--yes                     не задавать интерактивный вопрос
--help                    показать help
```

При смене `--ssh-port` скрипт записывает drop-in, проверяет конфигурацию (`sshd -t`), открывает новый порт в уже активном UFW и только потом перезапускает SSH. Если `sshd -t` не прошёл, скрипт возвращает прежний drop-in и останавливается — SSH не перезапускается, правило UFW не добавляется. Если не удался перезапуск SSH (например, порт занят), скрипт возвращает прежний drop-in, удаляет добавленное им правило UFW, перезапускает SSH ещё раз и останавливается с ошибкой, в которой указан путь к drop-in. `--ssh-port` не может совпадать с `--xray-port` (оба TCP). Без systemd SSH перезапустить нельзя, поэтому смена порта в этом случае отклоняется до каких-либо изменений; без смены порта drop-in записывается, а SSH нужно перезапустить вручную.

---

## Firewall phases

### `bootstrap` (по умолчанию)
Используется **до** того, как Amnezia app зафиксирует финальный UDP-порт для AmneziaWG.

Открывает:
- `22/tcp`
- `443/tcp`
- временно весь входящий UDP

Зачем это нужно:
- при первой установке через приложение AmneziaWG может подняться на случайном UDP-порту
- слишком ранний lock-down только на `8443/udp` может сломать первичную установку

### `locked`
Используется **после** того, как в приложении уже закреплён порт **8443/udp**.

Открывает:
- `22/tcp`
- `443/tcp`
- `8443/udp`

И дополнительно:
- удаляет временное правило `Anywhere/udp` / `Temporary AmneziaWG bootstrap allowance`

---

## Важная оговорка по Docker и firewall

Docker публикует порты через собственные сетевые правила. Поэтому после того, как Amnezia app поднимет контейнеры, нужно дополнительно проверить:
- какие порты реально опубликованы
- соответствует ли это ожиданиям (`443/tcp` и `8443/udp`)
- нет ли лишних опубликованных портов

Скрипт делает **host baseline**, но не заменяет финальную сетевую проверку после деплоя протоколов.

---

## Time sync

Скрипт придерживается подхода **preserve-first** (тот же общий шаг, что в VPS и мини-ПК):
- если на сервере установлен `chrony`, `ntpsec`, `ntp`, `openntpd` или `systemd-timesyncd`, скрипт оставляет его и запускает, если он не активен; другой daemon не ставится — в Debian эти пакеты конфликтуют, и установка удалила бы уже настроенный
- если не установлен ни один, ставит и включает `systemd-timesyncd`
- затем включает NTP через `timedatectl set-ntp true` и сообщает, синхронизированы ли часы (`timedatectl show -p NTPSynchronized`)

Это важно для cloud image / VPS образов, где time sync часто уже настроен корректно базовой системой.

---

## Swap

По умолчанию скрипт создаёт `/swapfile` размером **2G**, если активного swap ещё нет.

Зачем это нужно:
- для VPS с ~1G RAM это снижает риск `OOM killer`
- Docker/containerd и запуск контейнеров проходят спокойнее
- 2G — это простой фиксированный baseline без сложной эвристики

Поведение:
- если активный swap уже есть, скрипт его не трогает
- если `/swapfile` уже существует, но swap не активен, скрипт не перезаписывает файл автоматически
- размер можно изменить через `--swap-size-gb`
- swap можно отключить через `--skip-swap`

---

## SSH baseline

Скрипт применяет drop-in hardening в `/etc/ssh/sshd_config.d/00-amnezia-host-hardening.conf`:
- `PermitRootLogin no`
- `PasswordAuthentication no`
- `PubkeyAuthentication yes`
- `KbdInteractiveAuthentication no`
- `X11Forwarding no`
- `AllowUsers <target-user>`
- `ClientAliveInterval 300`
- `ClientAliveCountMax 2`
- `MaxAuthTries 3`
- `Port <ssh-port>`

sshd берет первое прочитанное значение параметра, а drop-in читает по порядку имен, поэтому файл назван `00-…` и действует раньше других drop-in (например, `50-cloud-init.conf` с `PasswordAuthentication yes`). После `sshd -t` скрипт сверяет действующие значения через `sshd -T`; если их задает файл, прочитанный раньше, или `sshd_config` не подключает каталог drop-in, drop-in откатывается до изменения firewall и перезапуска SSH, а скрипт называет расходящиеся параметры и останавливается. Файл `99-amnezia-host-hardening.conf` прежних версий удаляется; файл с тем же именем, но другим содержимым остается.

Если используется `--create-user`, ключи для нового пользователя берутся из `authorized_keys` invoking `sudo` user и добавляются без дублей. Если такого источника нет, можно передать ключ напрямую через `--ssh-public-key` или `--ssh-public-key-file`. Это позволяет не потерять доступ после отключения password login и ужесточения SSH. Права sudo для пользователя и root настраиваются атомарно через функцию безопасной записи с верификацией синтаксиса `visudo -cf`.

## Shell: Fish + Starship (Nerd Font Symbols)

Скрипт по умолчанию настраивает **Fish shell** со **Starship**:
- пресет Starship: [`nerd-font-symbols`](https://starship.rs/ru-RU/presets/nerd-font)
- отключение баннера `fish_greeting`
- **Гибридный запуск для 100% совместимости с Amnezia:**
  - В `/etc/passwd` логин-шеллом пользователя намеренно остаётся `/bin/bash`
  - Это критично: приложение Amnezia выполняет фоновые неинтерактивные проверки через SSH (`if ...; then ...; fi`, `export LC_ALL=C`), синтаксис которых не поддерживается Fish
  - При интерактивном входе человека через SSH терминал в `~/.bashrc` срабатывает бесшовный запуск `exec fish`
- Если требуется оставить чистый Bash без установки Fish, используй флаг `--skip-fish`

---

## Ошибка setlocale при входе по SSH

Предупреждение `cannot change locale (ru_RU.UTF-8)` означает, что сессия запрашивает локаль, которой нет на сервере. Например, SSH-клиент передаёт `LC_ALL`, `LC_CTYPE` или `LC_MESSAGES`, а минимальный образ Debian содержит только `C` и `C.UTF-8`. Старые версии Amnezia-профиля не генерировали дополнительные локали. `export LC_ALL=C` внутри скрипта защищает только его собственные команды.

Обновлённый скрипт генерирует обе локали и проверяет их наличие через `locale -a`. Чтобы исправить уже настроенный сервер без повторного запуска всего профиля, выполните на нём следующие команды в Bash (если сейчас открыт Fish, сначала запустите `bash`):

```bash
sudo env LC_ALL=C LANG=C apt-get update
sudo env LC_ALL=C LANG=C apt-get install -y locales
sudo env LC_ALL=C LANG=C bash <<'EOF'
set -euo pipefail
touch /etc/locale.gen
for name in en_US ru_RU; do
    sed -i -E "/^[[:space:]#]*${name}\\.UTF-8[[:space:]]+UTF-8([[:space:]]|$)/d" /etc/locale.gen
    printf '%s.UTF-8 UTF-8\n' "$name" >> /etc/locale.gen
done
locale-gen --keep-existing
locale -a | grep -Ei '^(en_US|ru_RU)\.(utf8|utf-8)$'
EOF
```

В результате должны появиться `en_US.utf8` и `ru_RU.utf8`. Затем откройте новую SSH-сессию и проверьте `locale`: предупреждений быть не должно. Перезагрузка сервера и перезапуск SSH не требуются. Для другой клиентской локали добавьте соответствующую строку в `/etc/locale.gen`.

Генерация исправляет причину ошибки; файл `/var/lib/cloud/instance/locale-check.skip` лишь скрывает предупреждение cloud-init. Описание штатного механизма: [Debian locale-gen(8)](https://manpages.debian.org/trixie/locales/locale-gen.8.en.html).

Проверка исправления (9 сентября 2026): в одноразовых контейнерах Debian 12.15 и 13.6 воспроизведено предупреждение до генерации; после настройки проверены все варианты выбора языка в VPS, Mini PC и WSL2, сохранение дополнительных локалей и запуск отдельных скриптов без `lib/`. В Debian 13.6 также проверены команда и интерактивный вход через настоящий SSH с передачей `LC_ALL`, `LC_CTYPE` и `LC_MESSAGES=ru_RU.UTF-8`: предупреждений нет. Полное развёртывание профилей и запуск внутри WSL2 в эту проверку не входили.

---

## Сетевой стек 10 Гбит/с (10G sysctl baseline)

Файл: `/etc/sysctl.d/99-amnezia-host.conf` и `/etc/security/limits.d/99-amnezia-limits.conf`

Оптимизирован для насыщения каналов **до 10 Гбит/с** с учетом Bandwidth-Delay Product (BDP):
- `net.core.default_qdisc = fq`
- `net.ipv4.tcp_congestion_control = bbr` (с гарантированной загрузкой модуля ядра `tcp_bbr`)
- `net.ipv4.ip_forward = 1` и `net.ipv6.conf.all.forwarding = 1`
- `net.core.rmem_max = 67108864` (64MB, или 32MB на VPS с <3GB RAM)
- `net.core.wmem_max = 67108864` (64MB, или 32MB на VPS с <3GB RAM)
- `net.ipv4.tcp_rmem = 4096 1048576 67108864`
- `net.ipv4.tcp_wmem = 4096 1048576 67108864`
- `net.ipv4.udp_rmem_min = 16384` и `net.ipv4.udp_wmem_min = 16384`
- очереди пакетов: `netdev_max_backlog = 32768`, `somaxconn = 32768`, `tcp_max_syn_backlog = 16384`
- масштабирование `nf_conntrack_max = 262144`
- системные лимиты дескрипторов `nofile = 524288`
- `net.ipv4.conf.all.rp_filter = 2` и `default.rp_filter = 2` (Loose mode для асимметричной маршрутизации VPN/WireGuard и Docker)
- базовый redirect / source-route hardening

---

## Проверка после запуска

Минимум проверь:

```bash
sudo sshd -t
sudo systemctl status ssh fail2ban docker --no-pager
sudo ufw status verbose
sysctl net.ipv4.ip_forward net.ipv4.tcp_congestion_control net.core.default_qdisc
id "$OPERATOR"
```

Если Docker ставился скриптом, перелогинься перед использованием Docker без sudo.

---

## Когда использовать `optimize_vps.sh` вместо этого скрипта

Используй `optimize_vps.sh`, если нужен полный комплексный VPS & dev tuning:
- Debian Backports ядро по умолчанию
- Fish Shell + Starship с расширенными dev-алиасами
- Стек разработки (Go, Node.js / fnm, компиляторы и утилиты сборки)
- Тюнинг Docker daemon (`daemon.json` с ротацией логов и кастомными DNS)
- Настройка CPU governor (`schedutil`) и I/O планировщиков
- Дополнительные sysctl tuning blocks
- Более широкий набор системных утилит
- Helper scripts для мониторинга и регулярной очистки (`vps-monitor.sh`, `vps-cleanup.sh`)

Если цель — **только подготовить чистый host под Amnezia app**, лучше использовать `optimize_amnezia_host.sh`.
