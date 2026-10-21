# История изменений

Формат — [Keep a Changelog 1.1.0](https://keepachangelog.com/ru/1.1.0/). Выпуск репозитория — тег `vГГГГ.ММ.ДД` (второй выпуск за день — `vГГГГ.ММ.ДД.1`) и запись на странице [Releases](https://github.com/snaplyze/optimize-debian/releases); выпуски неизменяемы. У скриптов есть свои версии (`SCRIPT_VERSION` в коде): они относятся к отдельному скрипту, а тег выпуска — ко всему репозиторию. Записи до первого выпуска собраны в разделе «История версий скриптов до выпусков».

## [Не выпущено]

### Добавлено
- `LICENSE` (MIT), `SECURITY.md` с приватным каналом для сообщений об уязвимостях, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, формы issue и шаблон PR.
- `CHANGELOG.md`; история версий перенесена сюда из README.
- Баннер README для светлой и темной темы и картинка для соцсетей в `docs/assets/`.
- `docs/README.md` — оглавление документации, `docs/ARCHITECTURE.md` — устройство репозитория.
- Проверка относительных ссылок документации (`tests/test_docs_links.sh`); проверка пробелов в конце строк перенесена из шага CI `Whitespace` в `tests/test_repository_hygiene.sh` и охватывает все дерево; пробелы в конце строк удалены из `optimize_mini_pc.sh`, `optimize_wsl2.sh` и `optimize_vps.sh`.
- `.editorconfig`; расширенный `.gitattributes`; тест версий скриптов в таблице README.
- `optimize_vps.sh` (3.0.0) и `optimize_mini_pc.sh` (2.0.0) получили `SCRIPT_VERSION`; `--help` всех пяти скриптов печатает версию.

### Изменено
- README переоформлен: таблица выбора скрипта, быстрый старт по скриптам, схема работы, матрица возможностей, значки CI, выпуска и лицензии; команды запуска те же.
- Руководства `docs/README_*.md` приведены к единой структуре.
- Ссылки на GitHub Discussions убраны: вопросы и ошибки — issues, уязвимости — `SECURITY.md`.

### Исправлено
- `optimize_amnezia_host.sh --kernel-backports` останавливался на шаге ядра (`detect_debian_version: command not found`); теперь версия берется из `/etc/os-release`.
- `optimize_vps.sh` на Debian 13 печатал пустую версию ядра в сообщении о шаге ядра.
- `optimize_wsl2.sh`: автозапуск ssh-agent без пользовательского systemd создавал `~/.bash_profile`, после чего login-bash не читал `~/.profile` и `~/.bashrc` (пропадал автопереход в Fish), а для root шаг падал; теперь агент запускает `/etc/profile.d/wsl2-ssh-agent.sh` для login-оболочек, блок прежних версий удаляется.
- `optimize_wsl2.sh`: повторный запуск в тот же день затирал копию `/etc/wsl.conf`; теперь имя копии содержит время.

## [v2026.10.21] - 2026-10-21

Первый закрепленный выпуск всего репозитория. Все скрипты в нем проверены CI. После первоначальной публикации 2026-09-04 код прошел аудит 2026-10-20, и найденные задачи закрыты (`docs/plan.md`).

### Безопасность
- SSH-закалка VPS, мини-ПК и Amnezia пишется в drop-in `00-*.conf`. sshd берет первое прочитанное значение, поэтому, например, `50-cloud-init.conf` с `PasswordAuthentication yes` ее больше не отменяет. После `sshd -t` действующие значения сверяются через `sshd -T`; если они расходятся, закалка откатывается без перезапуска SSH. Файл `99-*.conf` прежних версий удаляется.
- Starship, fnm, Go, gum и `cuda-keyring` устанавливаются только из закрепленной версии, проверенной по SHA-256. Ключи Docker и NVIDIA принимаются только с закрепленным отпечатком. Загрузки идут только по HTTPS, с пределом времени, во временные каталоги, которые удаляются после установки.
- sudoers записывается атомарно, с проверкой `visudo -cf`. Мини-ПК закаляет SSH только после `sshd -t`, с откатом. Samba открыт только для локальной сети и принимает только NTLMv2.
- Amnezia не создает пользователя, пока не найден источник SSH-ключей. Порядок изменений SSH и firewall не отрезает текущую сессию.

### Исправлено
- Шаги VPS, мини-ПК и WSL2 начинаются только после полной загрузки скрипта. `--help` работает без root.
- Общие APT-хелперы: ошибка установки останавливает шаг, ядро из Debian Backports ставится, ожидание блокировки dpkg не зависит от `fuser`, `apt-get update` выполняется один раз.
- Синхронизация времени проверяется по `NTPSynchronized`. Уже установленная служба времени сохраняется.
- Повторный запуск не плодит конфигурацию и не пересоздает swap-файл нужного размера. Неудачный `swapoff` не останавливает скрипт и не удаляет активный файл. Конфиги Fish и Bash общие, `.bashrc` копируется только один раз, если он чужой.
- Прерванная загрузка gum не оставляет временный каталог.
- `upgrade-to-debian13.sh`: источники старого релиза убираются, включая официальный `.list` с опциями `[...]`, в которых есть пробелы; бэкап проверяется, порты SSH и права файлов источников сохраняются.

### Изменено
- Значения sysctl, read-ahead и `dirty_ratio` в документах приведены к коду. Версия WSL2 — 4.1.0.
- CI на self-hosted раннере; `main` принимает только PR с пройденной проверкой `checks`.

Не проверено: arm64, WSL2 с GPU, полный интерактивный прогон на настоящей машине (проверки шли на контейнерах Debian 12/13).

## История версий скриптов до выпусков

### Amnezia Host Baseline v0.3.0 - 2026-09-04
- **10 Gbps сетевой стек:** BBR, fq pacing, адаптивные BDP буферы (32–64MB), очереди пакетов (`netdev_max_backlog=32768`, `somaxconn=32768`), conntrack до 262k соединений, ulimits по nofile до 524k
- **Fish Shell + Starship:** интерактивный современный shell со Starship и пресетом `nerd-font-symbols`; гибридная интеграция через `~/.bashrc` сохраняет `/bin/bash` в `/etc/passwd`, предотвращая сбои Amnezia App при SSH-автоматизации
- **Debian Backports kernel:** опциональное официальное LTS ядро через `--kernel-backports` (amd64/arm64)
- **Security & Systemd:** Fail2Ban с установкой `python3-systemd` для journald на Debian 12/13, UFW с `DEFAULT_FORWARD_POLICY="ACCEPT"` для бесшовной маршрутизации VPN
- **Security Audit 2026:** атомарная валидация sudoers (`visudo -cf`), безопасное определение домашних каталогов (`getent passwd`), Loose `rp_filter = 2` для асимметричного VPN-роутинга, современный `KbdInteractiveAuthentication no`
- **CLI флаги:** поддержка `--ssh-port`, `--xray-port`, `--amneziawg-port`, `--skip-fish`, `--kernel-backports` с валидацией портов

### VPS v3.0.0 - 2026-09-04
- **Debian Backports kernel:** замена XanMod на официальный репозиторий `bookworm-backports` (LTS ядро, полная поддержка amd64 и arm64)
- **Fish + Starship:** интерактивный современный shell со Starship (`nerd-font-symbols`), гибридный запуск через `~/.bashrc` (сохраняет `/bin/bash` в `/etc/passwd`)
- **10 Gbps сетевой стек:** адаптивные BDP буферы (rmem/wmem до 64MB), очереди `netdev_max_backlog=32768`, `somaxconn=32768`, conntrack до 262k
- **Безопасность:** Fail2Ban с `python3-systemd`, UFW с `DEFAULT_FORWARD_POLICY="ACCEPT"`
- **Persistent Modules:** гарантированная загрузка `tcp_bbr`, `tun`, `wireguard` через `/etc/modules-load.d/`
- **Security Audit 2026:** атомарная валидация sudoers (`visudo -cf`), безопасный `getent passwd`, устранение `noexec` с `/tmp` tmpfs, Loose `rp_filter = 2`, современный `KbdInteractiveAuthentication no`, очистка скачанных архивов Go

### Mini PC v2.0.0 - 2026-09-04
- **Debian Backports kernel:** замена XanMod на официальный `bookworm-backports` (amd64)
- **Fish + Starship:** переход на Fish shell с пресетом `nerd-font-symbols` и гибридным запуском через `~/.bashrc`
- **Fail2Ban:** интеграция `python3-systemd` бэкенда
- **Security Audit 2026:** атомарная валидация sudoers (`visudo -cf`), устранение `noexec` с `/tmp`, Loose `rp_filter = 2`, отключение устаревшего NTLMv1 в Samba (`server min protocol = SMB2`), безопасный `getent passwd`

### WSL2 v4.1.0 - 2026-09-04
- **Fish + Starship:** переход на Fish shell с пресетом `nerd-font-symbols` и гибридным запуском через `~/.bashrc`
- **WSL2 helpers в Fish:** нативные функции `explorer`, `cmd`, `powershell`, `wslperf`, `mkcd`
- **fnm интеграция:** хук `fnm env --use-on-cd --shell fish`
- **CUDA в Fish Shell:** автоматический экспорт `CUDA_HOME` и `LD_LIBRARY_PATH` в `config.fish`
- **Security Audit 2026:** атомарная валидация sudoers (`visudo -cf`), безопасное определение домашних каталогов (`getent passwd`) вместо `eval echo`, Loose `rp_filter = 2` для Docker и сетевых мостов

### WSL2 v4.0.0 - 2026-05-11
- **Опциональные dev toolchains:** Go и Node.js/fnm теперь выбираются отдельными пунктами меню
- **WSL CUDA safety:** GPU preflight предупреждает, но не роняет весь скрипт; широкий `cuda` metapackage не ставится
- **Shared helpers:** WSL config, Docker deb822 и unattended-upgrades рендерятся через общий `lib/common.sh`
- **Gum TUI:** `gum`-style prompts как в `arch-linux-installer.sh`; без автоматического blue-screen `dialog`/`whiptail`

### Debian Upgrade v2.0.3 - 2026-04-03
- **Новый скрипт обновления:** Debian 11/12 → Debian 13 (trixie)
- **Двухшаговый маршрут:** `bullseye → bookworm → trixie` с явным предупреждением перед продолжением без ребута
- **deb822-источники:** запись официальных APT sources в современном формате
- **Проверки безопасности:** диск, `dpkg --audit`, hold-пакеты, pinning, сторонние репозитории
- **Бэкап и логирование:** сохранение состояния в `/root/upgrade-backup-*` и `/var/log/debian-upgrade/`
- **SSH/firewall safety:** сохранение `/etc/ssh`, `authorized_keys`, firewall-конфигов и защита пакетов от `autoremove`
- **cloud image guidance:** notes про serial console / backup restore и про то, что `networking.service` проблемы могут быть VM-specific

### VPS v2.3.0 - 2026-02-04
- **Debian 12/13 support**
- **Валидация username** с retry при ошибке (числовой, пустой, неверные символы)
- **Удалены дубликаты** функций (check_dialog)
- **Zsh Ultra-Fast** - fnm auto-switching, VPN-оптимизация

### Mini PC v1.2.0 - 2026-02-04
- **Debian 12/13 support**
- **Валидация username** с retry при ошибке
- **Media Server Pro** - 32MB буферы, оптимизация для Plex/Jellyfin
- **Умный Swap** - 4GB для 16GB RAM

### WSL2 v3.0.0 - 2026-02-03
- **Debian 12/13 support:** bookworm и trixie
- **CUDA официальный метод:** `cuda-keyring_1.1-1_all.deb` с dynamic distro path
- **contrib репозиторий:** автоматическое включение
- **System info fallback:** `fastfetch -> neofetch -> skip`
- **Удалено:** `apt-transport-https` (устарел, встроен в apt)

### WSL2 v2.2.0 - 2025-12-12
- **Zsh Ultra-Fast** - терминал загружается на 70-90% быстрее
- **ML/AI Optimization** - Transparent Huge Pages, 64MB буферы
- **Агрессивный I/O** - NVMe: 2048 requests, 1024KB read-ahead

### WSL2 v2.1.2 - 2025-11-20
- WSL монтирование изменено: `/c/` → `/mnt/c/` (стандарт WSL)

### WSL2 v2.1.0 - 2025-11-19
- **fnm** - единый Node manager для текущих скриптов
- **VSCode Terminal fix** - для Remote SSH/Tunnels
- **npm без sudo** - fnm в user-local окружении

### WSL2 v2.0.0
- **Go установка** - последняя версия с SHA256 верификацией
- **Node.js + fnm** - LTS версия
- Создан WSL2 скрипт с Zsh + Starship
- NVIDIA Container Toolkit + CUDA поддержка

[Не выпущено]: https://github.com/snaplyze/optimize-debian/compare/v2026.10.21...main
[v2026.10.21]: https://github.com/snaplyze/optimize-debian/releases/tag/v2026.10.21
