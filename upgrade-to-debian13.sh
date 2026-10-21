#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Обновление Debian 11 (bullseye) / Debian 12 (bookworm) → Debian 13 (trixie)
# Для серверных (minimal) инсталляций.
#
# Актуальность: апрель 2026 (Debian 13.4, stable с 09.08.2025)
#
# Особенности:
#   • Двухшаговый путь: Debian 11 → 12 → 13 (прямой 11→13 не поддерживается)
#   • deb822-формат APT-источников
#   • Обработка известных проблем из Release Notes
#   • Полное логирование в файл
#   • Проверки: диск, dpkg audit, kernel meta, screen/tmux, SSH
#
# Использование:
#   chmod +x upgrade-to-debian13.sh
#   sudo ./upgrade-to-debian13.sh          # интерактивный режим
#   sudo ./upgrade-to-debian13.sh --yes    # без подтверждений (для автоматизации)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
shopt -s nullglob

# ── Глобальные переменные ────────────────────────────────────────────────────
readonly SCRIPT_VERSION="2.0.3"
TS="$(date -u +%Y%m%d-%H%M%SZ)"
readonly TS
readonly LOG_DIR="${LOG_DIR:-/var/log/debian-upgrade}"
readonly LOG_FILE="${LOG_FILE:-${LOG_DIR}/upgrade-${TS}.log}"
readonly BKP_DIR="${BKP_DIR:-/root/upgrade-backup-${TS}}"
readonly MIN_DISK_MB=5120   # 5 ГБ минимум свободного места на /
readonly SSH_BKP_DIR="${BKP_DIR}/ssh"
readonly FIREWALL_BKP_DIR="${BKP_DIR}/firewall"
# Корень конфигурации APT и файлы состояния пакетов. Окружение их не подменяет
# (скрипт запускают от root, окружение не сбрасывается); тесты переопределяют их после source.
APT_ETC_DIR="/etc/apt"
DPKG_STATUS_FILE="/var/lib/dpkg/status"
APT_EXTENDED_STATES_FILE="/var/lib/apt/extended_states"
OS_RELEASE_FILE="/etc/os-release"
# Файлы, перенесённые из APT-конфигурации, лежат здесь; список переносов — в манифесте текущего шага
readonly BKP_MOVED_DIR="${BKP_DIR}/moved-sources"
APT_MANIFEST_FILE="${BKP_DIR}/manifest-preflight.tsv"
# Фаза обновления для подсказки при сбое:
#   ""       — APT-источники ещё не менялись
#   sources  — источники меняются, пакеты нового релиза не ставились: можно вернуть файлы по манифесту
#   packages — началась установка пакетов нового релиза: источники старого релиза возвращать нельзя
#   done     — шаг завершён
UPGRADE_PHASE=""
AUTO_YES=false
ALLOW_TWO_HOP_NO_REBOOT=false
CURRENT_CODENAME=""
HAD_OPENSSH_SERVER=false
SSH_WAS_ENABLED=false
SSH_WAS_ACTIVE=false
SSH_EXPECTED_PORTS=""
HAD_UFW=false
UFW_WAS_ENABLED=false
HAD_NFTABLES=false
NFTABLES_WAS_ENABLED=false
HAD_NETFILTER_PERSISTENT=false
NETFILTER_PERSISTENT_WAS_ENABLED=false
HAD_FIREWALLD=false
FIREWALLD_WAS_ENABLED=false
TEE_PID=""

parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --yes|-y) AUTO_YES=true ;;
      --allow-two-hop-no-reboot) ALLOW_TWO_HOP_NO_REBOOT=true ;;
      --help|-h)
        echo "Использование: sudo $0 [--yes] [--allow-two-hop-no-reboot]"
        echo "  --yes, -y                    Без интерактивных подтверждений"
        echo "  --allow-two-hop-no-reboot    Разрешить --yes продолжить Debian 11→12→13 без промежуточного ребута"
        exit 0
        ;;
      *)
        echo "Неизвестный аргумент: $arg" >&2
        exit 1
        ;;
    esac
  done
}

# ── Вывод и логирование ──────────────────────────────────────────────────────
log()  { printf "\n\033[1;32m[✔] %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m[!] %s\033[0m\n" "$*"; }
err()  { printf "\n\033[1;31m[✗] %s\033[0m\n" "$*"; }

init_logging() {
  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE"
  exec 3>&1 4>&2
  exec > >(tee -a "$LOG_FILE") 2>&1
  TEE_PID=$!
  trap cleanup_logging EXIT
}

cleanup_logging() {
  local exit_code=$?
  local attempts=0

  trap - EXIT

  # Подсказку печатаем до возврата stdout/stderr, чтобы она попала и в лог
  if (( exit_code != 0 )) && [[ -n "$UPGRADE_PHASE" ]]; then
    print_apt_recovery_hint "$exit_code" || true
  fi

  # Возвращаем stdout/stderr в терминал и закрываем дубликаты.
  # Иначе shell может зависнуть на wait, если какой-либо сервис/daemon
  # унаследовал дескриптор лога и держит tee живым после завершения скрипта.
  exec 1>&3 2>&4
  exec 3>&- 4>&-

  if [[ -n "${TEE_PID:-}" ]]; then
    while kill -0 "$TEE_PID" 2>/dev/null && (( attempts < 10 )); do
      sleep 0.1
      ((attempts++))
    done
    kill "$TEE_PID" 2>/dev/null || true
    wait "$TEE_PID" 2>/dev/null || true
  fi

  exit "$exit_code"
}

is_installed_package() {
  local pkg="$1"
  dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null | grep -q '^ii'
}

is_systemd_unit_enabled() {
  local unit="$1"
  systemctl is-enabled "$unit" >/dev/null 2>&1
}

is_systemd_unit_active() {
  local unit="$1"
  systemctl is-active "$unit" >/dev/null 2>&1
}

is_remote_session() {
  [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]]
}

ensure_remote_openssh_is_current() {
  local current_release="${1:-$CURRENT_CODENAME}"
  local target_release="${2:-}"
  local pkg installed candidate

  is_remote_session || return 0
  [[ "$current_release" == "bookworm" ]] || return 0
  [[ -z "$target_release" || "$target_release" == "trixie" ]] || return 0

  for pkg in openssh-client openssh-server; do
    if [[ "$pkg" == "openssh-server" && "$HAD_OPENSSH_SERVER" != true ]]; then
      continue
    fi

    installed="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
    candidate="$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"

    [[ -n "$candidate" && "$candidate" != "(none)" ]] || continue
    if [[ "$installed" != "$candidate" ]]; then
      warn "$pkg не на текущей candidate-версии bookworm (${installed:-none} != $candidate) — обновляем перед переходом на trixie"
      apt-get install -y "$pkg"
      installed="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
      [[ "$installed" == "$candidate" ]] || die "Не удалось привести $pkg к актуальной версии bookworm перед переходом на trixie"
    fi
  done
}

die() {
  err "$1"
  err "Лог: $LOG_FILE"
  exit "${2:-1}"
}

confirm() {
  local msg="$1"
  if [[ "$AUTO_YES" == true ]]; then
    warn "$msg → автоподтверждение (--yes)"
    return 0
  fi
  # Проверка, что stdin — терминал
  if [[ ! -t 0 ]]; then
    die "Требуется интерактивный терминал для подтверждения. Используйте --yes для автоматического режима."
  fi
  read -r -p "$msg [y/N] " ans
  [[ "${ans,,}" == "y" ]] || return 1
}

can_continue_two_hop_no_reboot() {
  if [[ "$AUTO_YES" == true && "$ALLOW_TWO_HOP_NO_REBOOT" != true ]]; then
    return 1
  fi

  return 0
}

# ── Предварительные проверки ─────────────────────────────────────────────────
require_root() {
  if [[ "${OPTIMIZE_SOURCE_ONLY:-0}" != "1" && $EUID -ne 0 ]]; then
    err "Этот скрипт должен быть запущен с правами root (используйте sudo)"
    exit 1
  fi
}

check_not_wsl() {
  if grep -qi 'microsoft\|WSL' /proc/version 2>/dev/null; then
    die "Обнаружена WSL-среда. Скрипт предназначен для серверных инсталляций."
  fi
}

check_architecture() {
  local arch
  arch="$(dpkg --print-architecture)"
  if [[ "$arch" == "i386" ]]; then
    die "Архитектура i386 не поддерживается в Debian 13 как основная. Используйте amd64."
  fi
  log "Архитектура: $arch"
}

check_screen_tmux() {
  # Предупреждение если SSH-сессия без screen/tmux
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    if [[ -z "${STY:-}" && -z "${TMUX:-}" ]]; then
      warn "Обнаружена SSH-сессия без screen/tmux!"
      warn "При обрыве соединения обновление может прерваться."
      warn "Рекомендуется: apt-get install -y tmux && tmux new -s upgrade"
      if ! confirm "Продолжить без screen/tmux?"; then
        exit 0
      fi
    else
      log "SSH-сессия в screen/tmux — ОК"
    fi
  fi
}

check_disk_space() {
  check_path_disk_space "/" "$MIN_DISK_MB" "/"
  check_path_disk_space_if_separate "/boot" 512 "/boot"
  check_path_disk_space_if_separate "/var/cache/apt/archives" 2048 "/var/cache/apt/archives"
  check_path_disk_space_if_separate "/usr" 4096 "/usr"
}

check_path_disk_space_if_separate() {
  local path="$1"
  local min_mb="$2"
  local label="$3"
  local mount_target

  mount_target="$(findmnt -n --target "$path" --output TARGET 2>/dev/null | head -1 || true)"
  [[ "$mount_target" == "$path" ]] || return 0

  check_path_disk_space "$path" "$min_mb" "$label"
}

check_path_disk_space() {
  local path="$1"
  local min_mb="$2"
  local label="$3"
  local avail_kb
  local avail_mb

  avail_kb="$(df --output=avail "$path" | tail -1 | tr -d ' ')"
  avail_mb=$((avail_kb / 1024))
  if [[ $avail_mb -lt $min_mb ]]; then
    die "Недостаточно места на ${label}: ${avail_mb} МБ (нужно минимум ${min_mb} МБ). Освободите место: apt clean && apt autoremove"
  fi
  log "Свободное место на ${label}: ${avail_mb} МБ — ОК"
}

check_dpkg_health() {
  log "Проверка состояния dpkg"
  if dpkg --audit 2>&1 | grep -q .; then
    warn "dpkg --audit обнаружил проблемы:"
    dpkg --audit
    die "Исправьте проблемы dpkg перед обновлением: dpkg --configure -a"
  fi
  # Проверка на Half-Installed пакеты
  if dpkg -l | grep -q '^.H'; then
    warn "Обнаружены пакеты в состоянии Half-Installed:"
    dpkg -l | grep '^.H'
    die "Исправьте: apt-get install -f"
  fi
  log "dpkg в порядке"
}

detect_current_version() {
  if [[ ! -r "$OS_RELEASE_FILE" ]]; then
    die "$OS_RELEASE_FILE не найден — это точно Debian?"
  fi
  # shellcheck source=/dev/null
  . "$OS_RELEASE_FILE"
  if [[ "${ID:-}" != "debian" ]]; then
    die "Обнаружена не Debian: ID=${ID:-unknown}"
  fi
  CURRENT_CODENAME="${VERSION_CODENAME:-unknown}"
  log "Обнаружена система: ${PRETTY_NAME:-Debian} (${CURRENT_CODENAME})"

  case "$CURRENT_CODENAME" in
    bullseye)
      log "Debian 11 (bullseye) → потребуется двухшаговое обновление: 11 → 12 → 13"
      confirm "Начать обновление Debian 11 → 12 → 13?" || exit 0
      ;;
    bookworm)
      log "Debian 12 (bookworm) → прямое обновление до 13"
      confirm "Начать обновление Debian 12 → 13?" || exit 0
      ;;
    trixie)
      log "Система уже на Debian 13 (trixie). Обновление не требуется."
      exit 0
      ;;
    *)
      die "Неподдерживаемая версия: ${CURRENT_CODENAME}. Скрипт поддерживает только Debian 11 и 12."
      ;;
  esac
}

# ── Резервное копирование ────────────────────────────────────────────────────
# Копирует существующий обязательный файл или каталог в $BKP_DIR; при ошибке
# останавливает скрипт, пока система не изменена.
backup_required_path() {
  local src="$1"
  local copy

  [[ -e "$src" || -L "$src" ]] || return 0
  copy="$BKP_DIR/$(basename "$src")"
  if ! cp -a -- "$src" "$BKP_DIR/" || [[ ! -e "$copy" && ! -L "$copy" ]]; then
    die "Не удалось сохранить в бэкап: $src → $BKP_DIR. Обновление не начато: исправьте причину (место на диске, права) и запустите скрипт снова"
  fi
}

backup_state() {
  local src

  log "Бэкап конфигурации APT и списка пакетов → $BKP_DIR"
  mkdir -p "$BKP_DIR" || die "Не удалось создать каталог бэкапа $BKP_DIR. Обновление не начато"

  for src in \
    "$APT_ETC_DIR/sources.list" \
    "$APT_ETC_DIR/sources.list.d" \
    "$APT_ETC_DIR/preferences" \
    "$APT_ETC_DIR/preferences.d" \
    "$DPKG_STATUS_FILE" \
    "$APT_EXTENDED_STATES_FILE"; do
    backup_required_path "$src"
  done

  dpkg --get-selections '*' > "$BKP_DIR/dpkg-selections.txt"
  apt-cache policy > "$BKP_DIR/apt-policy.txt"
  uname -a > "$BKP_DIR/uname.txt"
  ip -br addr > "$BKP_DIR/network.txt" 2>/dev/null || true
  systemctl list-units --type=service --state=running > "$BKP_DIR/services.txt" 2>/dev/null || true

  log "Бэкап сохранён"
}

# ── Манифест перенесённых файлов ─────────────────────────────────────────────
# Строки манифеста: <действие><TAB><путь><TAB><копия в бэкапе>
#   moved   — файл перенесён из <путь> в <копия>; восстановление: mv <копия> <путь>
#   created — скрипт создал <путь>; восстановление: rm <путь>
# Манифест ведётся отдельно для подготовки и для каждого шага обновления.
manifest_add() {
  local action="$1"
  local path="$2"
  local backup_path="${3:-}"

  mkdir -p "$(dirname "$APT_MANIFEST_FILE")"
  printf '%s\t%s\t%s\n' "$action" "$path" "$backup_path" >> "$APT_MANIFEST_FILE"
}

# Переносит файл в $dest_dir (при совпадении имени добавляет числовой суффикс)
# и записывает перенос в манифест.
move_file_tracked() {
  local src="$1"
  local dest_dir="$2"
  local base dest
  local n=0

  base="$(basename "$src")"
  dest="${dest_dir}/${base}"
  while [[ -e "$dest" || -L "$dest" ]]; do
    n=$((n + 1))
    dest="${dest_dir}/${base}.${n}"
  done

  mkdir -p "$dest_dir"
  manifest_add moved "$src" "$dest"
  mv -v -- "$src" "$dest"
}

# При сбое печатает путь бэкапа и, пока пакеты нового релиза не ставились, команду
# возврата файлов по манифесту текущего шага. После начала установки пакетов вернуть
# источники старого релиза нельзя: система уже частично обновлена.
print_apt_recovery_hint() {
  local exit_code="$1"
  local restore_cmd copy
  local copies=()

  case "$UPGRADE_PHASE" in
    sources)
      err "Скрипт завершился с ошибкой (код ${exit_code}) при изменении APT-источников; пакеты нового релиза ещё не ставились"
      printf '  Бэкап: %s\n' "$BKP_DIR"
      for copy in "$BKP_DIR/sources.list" "$BKP_DIR/sources.list.d"; do
        if [[ -e "$copy" ]]; then
          copies+=("$copy")
        fi
      done
      if (( ${#copies[@]} > 0 )); then
        printf '  Полные копии на момент запуска: %s\n' "${copies[*]}"
      fi
      if [[ -f "$APT_MANIFEST_FILE" ]]; then
        restore_cmd="tac $(printf '%q' "$APT_MANIFEST_FILE") | while IFS=\$'\\t' read -r action src dst; do"
        restore_cmd+=" case \"\$action\" in moved) [ -e \"\$dst\" ] && mv -f -- \"\$dst\" \"\$src\" ;;"
        restore_cmd+=" created) rm -f -- \"\$src\" ;; esac; done"
        printf '  Вернуть файлы, перенесённые на этом шаге (манифест %s):\n' "$APT_MANIFEST_FILE"
        printf '  %s\n' "$restore_cmd"
        printf '  Затем: apt-get update\n'
      else
        printf '  Файлы на этом шаге не переносились (манифест %s не создан)\n' "$APT_MANIFEST_FILE"
      fi
      ;;
    packages)
      err "Скрипт завершился с ошибкой (код ${exit_code}) после начала установки пакетов нового релиза"
      printf '  Бэкап: %s\n' "$BKP_DIR"
      printf '  Источники старого релиза НЕ возвращайте: система уже частично обновлена.\n'
      printf '  Устраните причину сбоя и завершите обновление: apt-get -f install && apt-get full-upgrade\n'
      printf '  Затем проверьте доступ вручную: sshd -t && systemctl status ssh && ss -tlnp\n'
      printf '  Перезапуск скрипта поможет, только если /etc/os-release еще показывает старый релиз.\n'
      ;;
  esac
}

warn_if_legacy_ssh_keys_present() {
  local found=false
  local key_file

  for key_file in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -f "$key_file" ]] || continue
    if grep -qE '^[[:space:]]*ssh-dss([[:space:]]|$)' "$key_file" 2>/dev/null; then
      if [[ "$found" == false ]]; then
        warn "Обнаружены DSA SSH-ключи, которые не поддерживаются OpenSSH в Debian 13"
        found=true
      fi
      warn "  DSA ключ найден в: $key_file"
    fi
  done

  if [[ "$found" == true ]]; then
    warn "Добавьте Ed25519/ECDSA/RSA ключи до ребута после обновления"
  fi
}

# Порты из вывода sshd -T: строки port и listenaddress. Адрес с портом (host:port,
# [ipv6]:port) слушает свой порт; адрес без порта — порты из строк port.
ssh_ports_from_sshd_t() {
  local file="$1"

  awk '
    /^port [0-9]+$/ { ports[$2] = 1 }
    /^listenaddress / {
      addr = $2
      has_listen = 1
      if (addr ~ /^\[.*\]:[0-9]+$/) { sub(/^.*\]:/, "", addr); listen[addr] = 1 }
      else if (addr ~ /^[^:]+:[0-9]+$/) { sub(/^.*:/, "", addr); listen[addr] = 1 }
      else { bare = 1 }
    }
    END {
      if (!has_listen || bare) { for (p in ports) print p }
      for (p in listen) print p
    }
  ' "$file" | sort -nu | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# Определяет порты SSH до изменений: сначала по эффективной конфигурации (sshd -T),
# при её сбое — по портам, которые слушает процесс sshd. Подставлять порт по умолчанию
# нельзя: проверка после шага сверяла бы не тот порт. Если порты определить не удалось
# и SSH нужен для доступа (включён, активен или сессия удалённая), останавливаемся до
# изменений; на консольном хосте с выключенным ssh только предупреждаем.
detect_ssh_expected_ports() {
  local ports=""

  if command -v sshd >/dev/null 2>&1 && sshd -T > "$SSH_BKP_DIR/sshd-T.before.txt" 2>/dev/null; then
    ports="$(ssh_ports_from_sshd_t "$SSH_BKP_DIR/sshd-T.before.txt" || true)"
  else
    rm -f "$SSH_BKP_DIR/sshd-T.before.txt"
    warn "sshd -T недоступен или завершился ошибкой — берём порты, которые слушает процесс sshd"
  fi

  if [[ -z "$ports" ]]; then
    ports="$(ss -Hltnp 2>/dev/null \
      | awk '/users:\(\("sshd"/ { n = split($4, a, ":"); if (a[n] ~ /^[0-9]+$/) print a[n] }' \
      | sort -nu | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
  fi

  if [[ -z "$ports" ]]; then
    if [[ "$SSH_WAS_ENABLED" == true || "$SSH_WAS_ACTIVE" == true ]] || is_remote_session; then
      die "Не удалось определить порты SSH: sshd -T завершился ошибкой, а процесс sshd не слушает ни одного порта. Обновление не начато (подставлять порт 22 нельзя). Проверьте конфигурацию: sshd -t; systemctl status ssh"
    fi
    warn "Порты SSH определить не удалось, но ssh не включён, не активен и сессия не удалённая — проверка портов после шагов будет пропущена"
  fi
  SSH_EXPECTED_PORTS="$ports"
}

snapshot_remote_access_state() {
  log "Снимок состояния SSH и фаервола перед обновлением"
  mkdir -p "$SSH_BKP_DIR" "$FIREWALL_BKP_DIR"

  if is_installed_package openssh-server; then
    HAD_OPENSSH_SERVER=true
    cp -a /etc/ssh "$SSH_BKP_DIR/" 2>/dev/null || true
    mkdir -p "$SSH_BKP_DIR/authorized_keys"
    local key_file rel_key
    for key_file in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
      [[ -f "$key_file" ]] || continue
      rel_key="${key_file#/}"
      mkdir -p "$SSH_BKP_DIR/authorized_keys/$(dirname "$rel_key")"
      cp -a "$key_file" "$SSH_BKP_DIR/authorized_keys/$rel_key" 2>/dev/null || true
    done
    systemctl cat ssh > "$SSH_BKP_DIR/ssh.service.txt" 2>/dev/null || true
    systemctl status ssh --no-pager > "$SSH_BKP_DIR/ssh.status.before.txt" 2>/dev/null || true
    ss -tlnp > "$SSH_BKP_DIR/ss.before.txt" 2>/dev/null || true

    if is_systemd_unit_enabled ssh; then
      SSH_WAS_ENABLED=true
    fi
    if is_systemd_unit_active ssh; then
      SSH_WAS_ACTIVE=true
    fi

    detect_ssh_expected_ports
    log "Ожидаемые SSH порты после обновления: ${SSH_EXPECTED_PORTS:-не определены}"
  fi

  if is_installed_package ufw; then
    HAD_UFW=true
    cp -a /etc/ufw "$FIREWALL_BKP_DIR/" 2>/dev/null || true
    ufw status verbose > "$FIREWALL_BKP_DIR/ufw.status.before.txt" 2>/dev/null || true
    if is_systemd_unit_enabled ufw; then
      UFW_WAS_ENABLED=true
    fi
  fi

  if is_installed_package nftables; then
    HAD_NFTABLES=true
    cp -a /etc/nftables.conf "$FIREWALL_BKP_DIR/" 2>/dev/null || true
    nft list ruleset > "$FIREWALL_BKP_DIR/nft.ruleset.before.txt" 2>/dev/null || true
    if is_systemd_unit_enabled nftables; then
      NFTABLES_WAS_ENABLED=true
    fi
  fi

  if is_installed_package netfilter-persistent || is_installed_package iptables-persistent; then
    HAD_NETFILTER_PERSISTENT=true
    cp -a /etc/iptables "$FIREWALL_BKP_DIR/" 2>/dev/null || true
    iptables-save > "$FIREWALL_BKP_DIR/iptables.before.rules" 2>/dev/null || true
    ip6tables-save > "$FIREWALL_BKP_DIR/ip6tables.before.rules" 2>/dev/null || true
    if is_systemd_unit_enabled netfilter-persistent; then
      NETFILTER_PERSISTENT_WAS_ENABLED=true
    fi
  fi

  if is_installed_package firewalld; then
    HAD_FIREWALLD=true
    cp -a /etc/firewalld "$FIREWALL_BKP_DIR/" 2>/dev/null || true
    firewall-cmd --state > "$FIREWALL_BKP_DIR/firewalld.state.before.txt" 2>/dev/null || true
    if is_systemd_unit_enabled firewalld; then
      FIREWALLD_WAS_ENABLED=true
    fi
  fi
}

protect_critical_remote_packages() {
  local pkg
  local protected=()

  for pkg in openssh-server ufw nftables netfilter-persistent iptables-persistent firewalld; do
    if is_installed_package "$pkg"; then
      apt-mark manual "$pkg" >/dev/null 2>&1 || true
      protected+=("$pkg")
    fi
  done

  if [[ ${#protected[@]} -gt 0 ]]; then
    log "Защита критичных пакетов от autoremove: ${protected[*]}"
  fi
}

validate_firewall_state() {
  if [[ "$HAD_UFW" == true ]]; then
    if ! is_installed_package ufw; then
      warn "Пакет ufw пропал после обновления — переустановка"
      apt-get install -y ufw
    fi
    if [[ "$UFW_WAS_ENABLED" == true ]]; then
      systemctl enable ufw >/dev/null 2>&1 || true
    fi
    ufw status verbose > "$FIREWALL_BKP_DIR/ufw.status.after.txt" 2>/dev/null || true
  fi

  if [[ "$HAD_NFTABLES" == true ]]; then
    if ! is_installed_package nftables; then
      warn "Пакет nftables пропал после обновления — переустановка"
      apt-get install -y nftables
    fi
    if [[ "$NFTABLES_WAS_ENABLED" == true ]]; then
      systemctl enable nftables >/dev/null 2>&1 || true
    fi
    if [[ -f /etc/nftables.conf ]]; then
      nft -c -f /etc/nftables.conf >/dev/null 2>&1 || warn "Проверка /etc/nftables.conf завершилась ошибкой"
    fi
  fi

  if [[ "$HAD_NETFILTER_PERSISTENT" == true ]]; then
    if ! is_installed_package netfilter-persistent && ! is_installed_package iptables-persistent; then
      warn "Пакеты netfilter-persistent/iptables-persistent пропали после обновления — переустановка"
      apt-get install -y netfilter-persistent iptables-persistent || true
    fi
    if [[ "$NETFILTER_PERSISTENT_WAS_ENABLED" == true ]]; then
      systemctl enable netfilter-persistent >/dev/null 2>&1 || true
    fi
  fi

  if [[ "$HAD_FIREWALLD" == true ]]; then
    if ! is_installed_package firewalld; then
      warn "Пакет firewalld пропал после обновления — переустановка"
      apt-get install -y firewalld
    fi
    if [[ "$FIREWALLD_WAS_ENABLED" == true ]]; then
      systemctl enable firewalld >/dev/null 2>&1 || true
    fi
  fi
}

ensure_ssh_is_healthy() {
  local port
  local listening=false
  local require_running=false

  if [[ "$HAD_OPENSSH_SERVER" != true ]]; then
    return 0
  fi

  if ! is_installed_package openssh-server; then
    warn "openssh-server пропал после обновления — переустановка"
    apt-get install -y openssh-server
  fi

  if command -v sshd >/dev/null 2>&1; then
    if ! sshd -t; then
      die "Конфигурация sshd не проходит проверку после обновления. Проверьте /etc/ssh и бэкап в $SSH_BKP_DIR"
    fi
  fi

  if [[ "$SSH_WAS_ENABLED" == true || "$SSH_WAS_ACTIVE" == true ]] || is_remote_session; then
    require_running=true
  fi

  if [[ "$require_running" != true ]]; then
    log "openssh-server установлен, но SSH не был активен/включён до обновления — пропускаем проверку активного сервиса"
    return 0
  fi

  if [[ "$SSH_WAS_ENABLED" == true || "$SSH_WAS_ACTIVE" == true ]]; then
    systemctl enable ssh >/dev/null 2>&1 || true
    systemctl restart ssh
  fi

  if ! systemctl is-active --quiet ssh; then
    systemctl status ssh --no-pager > "$SSH_BKP_DIR/ssh.status.after.txt" 2>/dev/null || true
    die "Сервис ssh не активен после обновления"
  fi

  for port in $SSH_EXPECTED_PORTS; do
    if ss -H -tln "( sport = :$port )" 2>/dev/null | grep -q .; then
      listening=true
      break
    fi
  done

  ss -tlnp > "$SSH_BKP_DIR/ss.after.txt" 2>/dev/null || true
  systemctl status ssh --no-pager > "$SSH_BKP_DIR/ssh.status.after.txt" 2>/dev/null || true

  if [[ "$listening" != true ]]; then
    die "ssh активен, но не слушает ожидаемые порты: ${SSH_EXPECTED_PORTS}"
  fi

  log "SSH сервис и прослушивание портов проверены"
}

# ── Подготовка APT ───────────────────────────────────────────────────────────
setup_apt_env() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  # Предотвращение запуска сервисов во время обновления
  export NEEDRESTART_SUSPEND=1
}

install_prerequisites() {
  log "Установка базовых утилит"
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg lsb-release \
    debian-archive-keyring apt-utils
}

preflight_sanitize_apt_sources() {
  # Some older Debian 11/12 systems still carry stale backports or third-party
  # entries that make the very first `apt-get update` fail before upgrade logic
  # has a chance to normalize sources.
  log "Предварительная очистка APT-источников перед первым apt update"
  disable_third_party_repos
  remove_backports
  remove_proposed_updates
}

is_official_debian_list_file() {
  local file="$1"
  awk '
    BEGIN { found=0; bad=0 }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    $1 == "deb" || $1 == "deb-src" {
      found=1
      i=2
      # Поле опций [...] может содержать пробелы: пропускаем его до токена с закрывающей ]
      if ($i ~ /^\[/) {
        while (i <= NF && $i !~ /\]/) i++
        i++
      }
      uri=$i
      if (uri !~ /^https?:\/\/([^/]+\.)?(deb|security)\.debian\.org(\/|$)/) {
        bad=1
      }
    }
    END { exit bad }
  ' "$file"
}

is_official_debian_sources_file() {
  local file="$1"
  awk '
    BEGIN { found=0; bad=0 }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[[:space:]]*URIs:[[:space:]]*/ {
      found=1
      for (i = 2; i <= NF; i++) {
        if ($i !~ /^https?:\/\/([^/]+\.)?(deb|security)\.debian\.org(\/|$)/) {
          bad=1
        }
      }
    }
    END { exit bad }
  ' "$file"
}

sanitize_deb822_suites() {
  local file="$1"
  local suite_pattern="$2"
  local tmp_file
  # Временный файл — в том же каталоге (mv остаётся атомарным и не меняет файловую систему);
  # суффикс .disabled APT пропускает без предупреждений, а права и владелец берутся у исходного файла.
  tmp_file="$(mktemp --suffix=.disabled "${file}.XXXXXX")" || die "Не удалось создать временный файл рядом с $file"

  awk -v suite_pattern="$suite_pattern" '
    function flush_stanza(   i, suites_idx, suites_line, suite_count, suites, filtered, token) {
      if (line_count == 0) {
        return
      }

      suites_idx = 0
      for (i = 1; i <= line_count; i++) {
        if (stanza[i] ~ /^[[:space:]]*Suites:[[:space:]]*/) {
          suites_idx = i
          suites_line = stanza[i]
          break
        }
      }

      if (suites_idx > 0) {
        sub(/^[[:space:]]*Suites:[[:space:]]*/, "", suites_line)
        suite_count = split(suites_line, suites, /[[:space:]]+/)
        filtered = ""

        for (i = 1; i <= suite_count; i++) {
          token = suites[i]
          if (token == "") {
            continue
          }
          if (token ~ suite_pattern) {
            changed = 1
            continue
          }
          filtered = filtered (filtered ? " " : "") token
        }

        if (filtered == "") {
          changed = 1
          line_count = 0
          return
        }

        stanza[suites_idx] = "Suites: " filtered
      }

      if (printed_any) {
        print ""
      }
      for (i = 1; i <= line_count; i++) {
        print stanza[i]
      }
      printed_any = 1
      line_count = 0
    }

    BEGIN {
      line_count = 0
      changed = 0
      printed_any = 0
    }

    /^[[:space:]]*$/ {
      flush_stanza()
      next
    }

    {
      stanza[++line_count] = $0
    }

    END {
      flush_stanza()
    }
  ' "$file" > "$tmp_file" || { rm -f "$tmp_file"; die "Не удалось обработать $file"; }

  if ! cmp -s "$file" "$tmp_file"; then
    if ! chmod --reference="$file" "$tmp_file" || ! chown --reference="$file" "$tmp_file"; then
      rm -f "$tmp_file"
      die "Не удалось сохранить права и владельца $file при санитизации"
    fi
    mv "$tmp_file" "$file"
    return 0
  fi

  rm -f "$tmp_file"
  return 1
}

# ── Обработка hold-пакетов ───────────────────────────────────────────────────
handle_held_packages() {
  log "Проверка зафиксированных (hold) пакетов"
  local held
  held="$(apt-mark showhold)"
  if [[ -n "$held" ]]; then
    warn "Найдены удержанные пакеты:"
    echo "$held"
    if confirm "Снять hold со всех?"; then
      apt-mark showhold | xargs -r apt-mark unhold
      log "Hold снят"
    else
      warn "Удержанные пакеты могут помешать обновлению"
    fi
  fi
}

# ── Отключение APT pinning ───────────────────────────────────────────────────
check_apt_pinning() {
  log "Проверка APT pinning"
  local found=false
  local f
  for f in "$APT_ETC_DIR"/preferences "$APT_ETC_DIR"/preferences.d/*; do
    [[ -f "$f" ]] || continue
    if grep -qiE '^\s*(Pin-Priority|Pin:)' "$f" 2>/dev/null; then
      warn "APT pinning обнаружен: $f"
      found=true
    fi
  done
  if [[ "$found" == true ]]; then
    warn "APT pinning может помешать обновлению. Рекомендуется убрать пины."
    if confirm "Переместить файлы pinning в бэкап?"; then
      for f in "$APT_ETC_DIR"/preferences "$APT_ETC_DIR"/preferences.d/*; do
        [[ -f "$f" ]] || continue
        move_file_tracked "$f" "${BKP_DIR}/apt-pins"
      done
    fi
  fi
}

# ── Отключение сторонних репозиториев ────────────────────────────────────────
disable_third_party_repos() {
  log "Отключение сторонних репозиториев"
  local disabled_dir="${APT_ETC_DIR}/sources.list.d.disabled-${TS}"
  local count=0
  local f

  # Обработка .list файлов (legacy формат)
  for f in "$APT_ETC_DIR"/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    if ! is_official_debian_list_file "$f"; then
      move_file_tracked "$f" "$disabled_dir"
      count=$((count + 1))
    fi
  done

  # Обработка .sources файлов (deb822 формат)
  for f in "$APT_ETC_DIR"/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    if ! is_official_debian_sources_file "$f"; then
      move_file_tracked "$f" "$disabled_dir"
      count=$((count + 1))
    fi
  done

  if [[ $count -gt 0 ]]; then
    log "Отключено $count сторонних репозиториев → $disabled_dir"
  else
    log "Сторонних репозиториев не найдено"
  fi
}

# ── Удаление backports-записей ───────────────────────────────────────────────
remove_backports() {
  log "Проверка backports-записей"
  local found=false
  local f

  # В sources.list
  if [[ -f "$APT_ETC_DIR/sources.list" ]]; then
    if grep -qE 'backports' "$APT_ETC_DIR/sources.list"; then
      sed -i.bak '/backports/d' "$APT_ETC_DIR/sources.list"
      found=true
    fi
  fi

  # В .list файлах
  for f in "$APT_ETC_DIR"/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    if grep -qE 'backports' "$f"; then
      sed -i.bak '/backports/d' "$f"
      found=true
    fi
  done

  # В .sources файлах — ищем Suites с backports
  for f in "$APT_ETC_DIR"/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    if sanitize_deb822_suites "$f" 'backports'; then
      found=true
    fi
  done

  if [[ "$found" == true ]]; then
    log "Backports-записи удалены/обработаны"
  fi
}

# ── Удаление proposed-updates ────────────────────────────────────────────────
remove_proposed_updates() {
  local found=false
  local f
  if grep -rq 'proposed-updates' "$APT_ETC_DIR/sources.list" "$APT_ETC_DIR/sources.list.d/" 2>/dev/null; then
    warn "Обнаружены proposed-updates — удаление из источников"
    sed -i '/proposed-updates/d' "$APT_ETC_DIR/sources.list" 2>/dev/null || true
    for f in "$APT_ETC_DIR"/sources.list.d/*.list; do
      if grep -qE 'proposed-updates' "$f" 2>/dev/null; then
        sed -i '/proposed-updates/d' "$f" 2>/dev/null || true
        found=true
      fi
    done
    for f in "$APT_ETC_DIR"/sources.list.d/*.sources; do
      [[ -f "$f" ]] || continue
      if sanitize_deb822_suites "$f" 'proposed-updates'; then
        found=true
      fi
    done
  fi
  if [[ "$found" == true ]]; then
    log "proposed-updates удалены/обработаны"
  fi
}

# ── Запись deb822-источников ─────────────────────────────────────────────────
# Переносит в бэкап официальные файлы sources.list.d, где встречается кодовое имя
# релиза, с которого уходим (например, security.list с bookworm-security): иначе
# рядом с новым релизом остались бы источники старого.
move_official_old_release_sources() {
  local old_codename="$1"
  local pattern="(^|[^[:alnum:]])${old_codename}([^[:alnum:]]|$)"
  local f

  for f in "$APT_ETC_DIR"/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    is_official_debian_list_file "$f" || continue
    grep -Eq -- "$pattern" "$f" || continue
    warn "Официальный источник старого релиза ${old_codename}: $f → $BKP_MOVED_DIR"
    move_file_tracked "$f" "$BKP_MOVED_DIR"
  done

  for f in "$APT_ETC_DIR"/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    is_official_debian_sources_file "$f" || continue
    grep -Eq -- "$pattern" "$f" || continue
    warn "Официальный источник старого релиза ${old_codename}: $f → $BKP_MOVED_DIR"
    move_file_tracked "$f" "$BKP_MOVED_DIR"
  done
}

write_sources_deb822() {
  local codename="$1"      # целевой релиз: bookworm или trixie
  local old_codename="$2"  # релиз, с которого уходим: bullseye или bookworm
  local security_suite
  local sources_list="${APT_ETC_DIR}/sources.list"
  local debian_sources="${APT_ETC_DIR}/sources.list.d/debian.sources"

  # Формат security suite различается: bullseye-security / bookworm-security / trixie-security
  security_suite="${codename}-security"

  log "Запись APT-источников в deb822-формате для ${codename}"

  # Переносим старый sources.list в бэкап и очищаем его
  if [[ -f "$sources_list" && -s "$sources_list" ]]; then
    move_file_tracked "$sources_list" "$BKP_MOVED_DIR"
  fi
  : > "$sources_list"

  # Официальные файлы старого релиза и прежний debian.sources — в бэкап, чтобы не было дубликатов
  move_official_old_release_sources "$old_codename"
  if [[ -e "$debian_sources" || -L "$debian_sources" ]]; then
    move_file_tracked "$debian_sources" "$BKP_MOVED_DIR"
  fi

  manifest_add created "$debian_sources"
  mkdir -p "$(dirname "$debian_sources")"
  cat > "$debian_sources" <<EOSRC
Types: deb
URIs: https://deb.debian.org/debian
Suites: ${codename} ${codename}-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://deb.debian.org/debian-security
Suites: ${security_suite}
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOSRC

  log "Источники записаны: $debian_sources"
}

# Обновляет индекс и проверяет, что среди источников нет старого релиза.
refresh_apt_index_and_check_release() {
  local old_codename="$1"
  # Смотрим только описания источников: строку с адресом (… bookworm/main …, bookworm-security/…)
  # и строку release с n=<кодовое имя>. Закреплённые версии пакетов («Pinned packages»,
  # например …~bookworm) источниками не являются.
  local uri_pattern="^[[:space:]]*[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+${old_codename}(-[a-z]+)*/"
  local release_pattern="^[[:space:]]*release[[:space:]].*[,[:space:]]n=${old_codename}(-[a-z]+)*(,|\$)"
  local policy hits

  apt-get update -y

  policy="$(apt-cache policy)" || die "apt-cache policy завершился с ошибкой — состав источников проверить нельзя"
  hits="$(grep -E -- "${uri_pattern}|${release_pattern}" <<<"$policy" | head -n 10 || true)"
  if [[ -n "$hits" ]]; then
    err "В apt-cache policy остался старый релиз ${old_codename}:"
    printf '%s\n' "$hits"
    die "После обновления индекса среди APT-источников остался старый релиз ${old_codename}; обновление остановлено до установки пакетов. Найдите файл (источник может быть задан и алиасом oldstable): grep -rlE '${old_codename}|oldstable' ${APT_ETC_DIR}/sources.list ${APT_ETC_DIR}/sources.list.d/. Перенесённые файлы: ${BKP_MOVED_DIR}, манифест: ${APT_MANIFEST_FILE}"
  fi
  log "Среди APT-источников нет старого релиза ${old_codename}"
}

# ── Обновление текущего релиза до последней точечной версии ───────────────────
upgrade_current_release() {
  local codename="$1"
  log "Обновление ${codename} до последней точечной версии"
  apt-get update -y
  apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"
  apt-get dist-upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"
}

# ── Минимальное обновление (этап 1 по Release Notes) ─────────────────────────
minimal_upgrade() {
  log "Этап 1: минимальное обновление"
  # Обновляем apt/dpkg первым делом для надёжности
  apt-get install -y apt dpkg 2>/dev/null || true
  apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"
}

# ── Полное обновление (этап 2) ───────────────────────────────────────────────
full_upgrade() {
  log "Этап 2: полное обновление (full-upgrade)"

  # Первая попытка
  if ! apt-get full-upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"; then

    # Обработка известной проблемы: "Could not perform immediate configuration"
    warn "full-upgrade не удался, пробуем с APT::Immediate-Configure=0"
    apt-get full-upgrade -y \
      -o APT::Immediate-Configure=0 \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold"
  fi
}

# ── Проверка kernel meta-package ─────────────────────────────────────────────
check_kernel_metapackage() {
  log "Проверка наличия kernel meta-package"
  if ! dpkg -l 'linux-image-*' 2>/dev/null | grep -q '^ii.*meta'; then
    # Проверяем альтернативным способом
    if ! dpkg -l linux-image-amd64 2>/dev/null | grep -q '^ii' && \
       ! dpkg -l linux-image-arm64 2>/dev/null | grep -q '^ii' && \
       ! dpkg -l linux-image-cloud-amd64 2>/dev/null | grep -q '^ii'; then
      warn "Не найден kernel meta-package. Устанавливаем..."
      local arch
      arch="$(dpkg --print-architecture)"
      apt-get install -y "linux-image-${arch}" || \
        warn "Не удалось установить kernel meta-package. Проверьте вручную."
    fi
  fi
  log "Ядро: $(uname -r)"
}

# ── Проверка systemd-cryptsetup для LUKS ────────────────────────────────────
check_cryptsetup() {
  if [[ -f /etc/crypttab ]] && grep -qv '^#' /etc/crypttab 2>/dev/null; then
    log "Обнаружен /etc/crypttab — проверка systemd-cryptsetup"
    if ! dpkg -l systemd-cryptsetup 2>/dev/null | grep -q '^ii'; then
      warn "Устанавливаем systemd-cryptsetup (требуется для зашифрованных ФС в trixie)"
      apt-get install -y systemd-cryptsetup || true
    fi
  fi
}

# ── Очистка ──────────────────────────────────────────────────────────────────
cleanup() {
  log "Очистка"
  apt-get autoremove -y
  apt-get autoclean -y

  # Удаление остаточных конфигов удалённых пакетов
  local residual
  residual="$(dpkg -l | awk '/^rc/ {print $2}')"
  if [[ -n "$residual" ]]; then
    log "Удаление остаточных конфигов: $(echo "$residual" | wc -l) пакетов"
    echo "$residual" | xargs -r dpkg --purge 2>/dev/null || true
  fi
}

# ── Финальная верификация ────────────────────────────────────────────────────
verify_upgrade() {
  # shellcheck source=/dev/null
  . "$OS_RELEASE_FILE" || true
  local current="${VERSION_CODENAME:-unknown}"

  log "Текущая версия: ${PRETTY_NAME:-unknown} (${current})"
  log "Ядро: $(uname -r)"

  if [[ "$current" == "trixie" ]]; then
    log "════════════════════════════════════════════"
    log "  Обновление до Debian 13 (trixie) — УСПЕХ"
    log "════════════════════════════════════════════"
  else
    warn "VERSION_CODENAME=${current}, ожидалось trixie"
    warn "Проверьте лог: $LOG_FILE"
  fi
}

final_notes() {
  cat <<'NOTES'

┌─────────────────────────────────────────────────────────┐
│  Рекомендации после обновления:                         │
│                                                         │
│  1. Перезагрузите сервер:  reboot                       │
│  2. После ребута проверьте:                             │
│     • uname -r        (новое ядро)                      │
│     • cat /etc/os-release                               │
│     • systemctl --failed                                │
│  3. Проверьте сторонние репозитории и верните нужные:    │
│     ls /etc/apt/sources.list.d.disabled-*/              │
│     (все перенесённые файлы: manifest-*.tsv в бэкапе)   │
│  4. При необходимости добавьте trixie-backports         │
│  5. При разборе проблем проверьте лог и каталог бэкапа  │
└─────────────────────────────────────────────────────────┘
NOTES
  log "Полный лог: $LOG_FILE"
  log "Бэкап: $BKP_DIR"

  # Пауза перед выходом — только в интерактивном режиме (не при --yes, не в pipe)
  if [[ "$AUTO_YES" != true && -t 0 ]]; then
    printf "\nНажмите Enter для выхода..." >&2
    read -r _ </dev/tty
  fi
}

# ── Шаг обновления: один мажорный переход ────────────────────────────────────
do_upgrade_step() {
  local from_codename="$1"
  local to_codename="$2"
  local to_version="$3"

  log "═══ Начало обновления: ${from_codename} → ${to_codename} (Debian ${to_version}) ═══"

  # Перенесённые на этом шаге файлы записываются в отдельный манифест
  APT_MANIFEST_FILE="${BKP_DIR}/manifest-${from_codename}-to-${to_codename}.tsv"
  UPGRADE_PHASE="sources"

  handle_held_packages
  check_apt_pinning
  disable_third_party_repos
  remove_backports
  remove_proposed_updates

  # Сначала обновляем текущий релиз до последней точки
  upgrade_current_release "$from_codename"
  ensure_remote_openssh_is_current "$from_codename" "$to_codename"

  # Переключаем источники на целевой релиз
  write_sources_deb822 "$to_codename" "$from_codename"
  refresh_apt_index_and_check_release "$from_codename"

  # С установки пакетов нового релиза возврат источников старого уже не нужен и опасен
  UPGRADE_PHASE="packages"

  # Двухэтапное обновление (как в Release Notes)
  minimal_upgrade
  full_upgrade
  cleanup
  validate_firewall_state
  ensure_ssh_is_healthy

  # Проверяем что обновление прошло
  # shellcheck source=/dev/null
  . "$OS_RELEASE_FILE" || true
  if [[ "${VERSION_CODENAME:-}" != "$to_codename" ]]; then
    die "Обновление до ${to_codename} не завершилось. VERSION_CODENAME=${VERSION_CODENAME:-unknown}"
  fi
  UPGRADE_PHASE="done"
  log "Переход на ${to_codename} завершён"
}

# ── Главная функция ──────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  # Предварительные проверки
  require_root
  init_logging
  log "Скрипт обновления Debian → 13 (trixie) v${SCRIPT_VERSION}"
  log "Время: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  log "Лог: $LOG_FILE"
  check_not_wsl
  detect_current_version
  check_architecture
  check_screen_tmux
  check_disk_space
  check_dpkg_health

  # Подготовка
  setup_apt_env
  backup_state
  warn_if_legacy_ssh_keys_present
  snapshot_remote_access_state
  protect_critical_remote_packages
  # С этого места меняются APT-источники: при сбое печатаем путь бэкапа и команды возврата
  UPGRADE_PHASE="sources"
  preflight_sanitize_apt_sources
  install_prerequisites

  # Маршрут обновления
  case "$CURRENT_CODENAME" in
    bullseye)
      # Шаг 1: Debian 11 → 12
      do_upgrade_step bullseye bookworm 12
      log "Debian 12 установлен."

      warn "════════════════════════════════════════════════════════════════"
      warn "  РЕКОМЕНДУЕТСЯ: перезагрузка перед шагом Debian 12 → 13"
      warn "  Текущее ядро: $(uname -r)"
      warn "  Ядро Debian 12 будет активно только после ребута."
      warn "════════════════════════════════════════════════════════════════"

      warn "Продолжение без ребута допустимо, но несёт дополнительный риск."
      warn "Если прерваться сейчас — перезапустите скрипт на Debian 12,"
      warn "он автоматически продолжит с шага 12 → 13."

      if ! can_continue_two_hop_no_reboot; then
        warn "--yes не продолжает Debian 11 → 12 → 13 без промежуточного ребута."
        warn "Перезагрузите сервер и запустите скрипт повторно, либо используйте --allow-two-hop-no-reboot осознанно."
        final_notes
        exit 0
      fi

      # confirm() сам обрабатывает AUTO_YES — логирует автоподтверждение при --yes
      confirm "Продолжить обновление до Debian 13 без перезагрузки?" || {
        final_notes
        exit 0
      }

      # Шаг 2: Debian 12 → 13
      do_upgrade_step bookworm trixie 13
      ;;
    bookworm)
      # Прямой путь: Debian 12 → 13
      do_upgrade_step bookworm trixie 13
      ;;
  esac

  # Пост-обновление
  check_kernel_metapackage
  check_cryptsetup
  verify_upgrade
  final_notes
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
