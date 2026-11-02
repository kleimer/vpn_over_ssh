#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ==========================================================
# SSH-TUN Linux client v5
# Fixes:
#   - trap cleanup on Ctrl+C / errors during start
#   - stop cleans stale state + managed leftover tun devices
#   - cleanup command removes old traces without state file
#   - lock prevents overlapping starts/stops
#   - supports full-tunnel, custom tunnel routes and direct excludes
#   - policy routing (Tailscale-style): routes live in dedicated tables
#     (POLICY_TABLE_DIRECT/POLICY_TABLE_TUN), main table stays untouched
#   - big route lists (country/AS CIDRs) are applied via ip -batch
#   - route precedence: kernel LPM by prefix length; on equal prefix the
#     tunnel/force route wins because excludes are applied first
#   - supports passphrase-protected keys via existing ssh-agent or temporary ssh-agent
#   - preserves /run/sshtun/ssh.last.log after failed starts
#   - stops retrying tun pool on deterministic SSH auth/port failures
#   - --foreground: после старта не выходить, а досматривать ssh-процесс
#     (режим для systemd: неожиданная смерть ssh -> cleanup + exit 1 ->
#     Restart=on-failure; штатный stop/down -> exit 0 без рестарта)
#
# Server assumptions:
#   user: sshvpn
#   port: 65523
#   pool: tun100..tun200 by default
#   network: 10.250.0.0/16
#   MTU: 1400
# ==========================================================

SSH_USER="${SSH_USER:-sshvpn}"
SSH_PORT="${SSH_PORT:-65523}"
TUN_START="${TUN_START:-100}"
TUN_END="${TUN_END:-200}"
TUN_PREFIX="${TUN_PREFIX:-tun}"
TUN_MTU="${TUN_MTU:-1400}"

TUN_NET_A="${TUN_NET_A:-10}"
TUN_NET_B="${TUN_NET_B:-250}"

STATE_DIR="${STATE_DIR:-/run/sshtun}"
STATE_FILE="$STATE_DIR/state"
SSH_LOG="$STATE_DIR/ssh.log"
SSH_LAST_LOG="$STATE_DIR/ssh.last.log"
KNOWN_HOSTS_FILE="$STATE_DIR/known_hosts"
LOCK_FILE="$STATE_DIR/lock"

FULL_TUNNEL="${FULL_TUNNEL:-1}"
SET_DNS="${SET_DNS:-1}"
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1 8.8.8.8}"
BLOCK_IPV6="${BLOCK_IPV6:-1}"
CLEAN_ORPHANS_ON_STOP="${CLEAN_ORPHANS_ON_STOP:-1}"
SSH_BATCH_MODE="${SSH_BATCH_MODE:-yes}"
LOAD_KEY_IN_AGENT="${LOAD_KEY_IN_AGENT:-0}"
TEMP_AGENT_PID=""
# auto = enable remote root-side tun/NAT setup only when --user root.
# 1 = always enable, 0 = never enable.
REMOTE_SETUP="${REMOTE_SETUP:-auto}"
REMOTE_WAN_DEV="${REMOTE_WAN_DEV:-}"
# --foreground: держать процесс в живых после старта и досматривать ssh.
# Маркер пишется в state: обёртка по нему понимает, что туннель под досмотром
# systemd, и останавливает через 'systemctl stop' (иначе Restart=always
# перезапустил бы туннель после ручного 'sshtun down').
FOREGROUND="${FOREGROUND:-0}"

# Safety guard for cleanup: delete only tunNNN with N>=100 and IP from 10.250.0.0/16.
OWNED_TUN_MIN="${OWNED_TUN_MIN:-100}"
OWNED_TUN_MAX="${OWNED_TUN_MAX:-9999}"

HOST=""
KEY_FILE=""
FIXED_TUN=""
SERVER_REAL_IP=""
DEFAULT_ROUTE=""
DEFAULT_GW=""
DEFAULT_DEV=""
SSH_PID=""
TUN_NUM=""
TUN_DEV=""
SERVER_TUN_IP=""
CLIENT_TUN_IP=""
START_OK="0"
HAD_IPV6_BLACKHOLE="0"

ROUTES_VIA_TUN=()
EXCLUDE_ROUTES=()

# Списки длиннее порога применяются одним netlink-транзакцией (ip -batch)
# вместо посекундного цикла: 10k+ маршрутов добавляются/снимаются за секунды.
ROUTE_BATCH_THRESHOLD="${ROUTE_BATCH_THRESHOLD:-100}"

# Policy routing в стиле Tailscale/Netbird: маршруты живут в отдельных
# таблицах, main-таблица не трогается. POLICY_TABLE_DIRECT — вся политика
# (исключения direct, include-force через tun, bypass до сервера, копия
# connected-маршрута LAN); POLICY_TABLE_TUN — только полутора default'а
# full-tunnel (0.0.0.0/1 + 128.0.0.0/1). Правила с приоритетами ниже main
# (32766): сначала direct-таблица, затем tunnel-таблица. Приоритеты 25100+
# выбраны, чтобы не пересекаться с Tailscale (52xx) и Netbird (31xx).
POLICY_TABLE_DIRECT="${POLICY_TABLE_DIRECT:-200}"
POLICY_TABLE_TUN="${POLICY_TABLE_TUN:-201}"
RULE_PREF_DIRECT="${RULE_PREF_DIRECT:-25100}"
RULE_PREF_TUN="${RULE_PREF_TUN:-25110}"

# После остановки юнита stdout может быть уже закрыт (SIGPIPE в date/echo) —
# лог не должен ронять скрипт посреди cleanup.
log(){ echo "[$(date -Is)] $*" 2>/dev/null || true; }
die(){ echo "[ERROR] $*" >&2 || true; exit 1; }

usage() {
  cat <<EOFUSAGE
Usage:
  sudo $0 start --host SERVER_IP_OR_DOMAIN --key /path/to/id_ed25519 [options]
  sudo $0 stop
  sudo $0 cleanup
  sudo $0 status
  sudo $0 doctor

Start options:
  --host HOST              SSH-TUN server IP/domain
  --key FILE               private key file
  --user USER              default: sshvpn
  --port PORT              default: 65523
  --tun N                  fixed tun number, for example 100
  --tun-start N            default: 100
  --tun-end N              default: 200
  --mtu N                  default: 1400
  --no-full-tunnel         only create tunnel, do not route all IPv4 via it
  --route CIDR             add route via tunnel; can be repeated
  --route-file FILE        read tunnel routes from file, one CIDR per line
  --exclude CIDR           direct/bypass route via original default gateway; can be repeated
  --exclude-file FILE      read direct/bypass routes from file, one CIDR per line
  --no-dns                 do not configure DNS via systemd-resolved
  --dns "1.1.1.1 8.8.8.8" DNS servers for tun interface
  --no-block-ipv6          do not add IPv6 blackhole route
  --no-clean-orphans       stop will not delete old managed tun leftovers
  --ask-passphrase         prompt once via a temporary ssh-agent, then keep SSH batch mode
  --load-key-agent         same as --ask-passphrase: start temporary ssh-agent and ssh-add key
  --remote-setup           configure remote tun/NAT inside SSH session; useful for --user root
  --no-remote-setup        do not configure remote tun/NAT; useful if server already has pool setup
  --remote-wan-dev DEV     server WAN interface for NAT; default: auto-detect default route dev
  --foreground             do not exit after start: supervise the ssh process (systemd mode).
                           ssh died unexpectedly -> cleanup + exit 1; 'stop'/SIGTERM -> exit 0

Commands:
  stop                     stop current VPN from state and clean traces
  cleanup                  force cleanup old SSH-TUN traces even if state is missing
  status                   show current state and managed leftovers
  doctor                   print routes/DNS/tun diagnostics

Examples:
  sudo $0 start --host 1.2.3.4 --key ./id_ed25519
  sudo $0 start --host 1.2.3.4 --key ./id_ed25519 --exclude 192.168.0.0/16
  sudo $0 start --host 1.2.3.4 --key ./id_ed25519 --no-full-tunnel --route 10.10.0.0/16
  sudo $0 stop
  sudo $0 cleanup
EOFUSAGE
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo $0 ..."
}

need_cmds() {
  local missing=0
  for c in ssh ip awk sed grep shuf getent flock; do
    command -v "$c" >/dev/null 2>&1 || { echo "missing: $c" >&2; missing=1; }
  done
  [[ "$missing" -eq 0 ]] || die "Install missing dependencies first"
}

validate_num() {
  local name="$1" val="$2"
  [[ "$val" =~ ^[0-9]+$ ]] || die "Bad ${name}: ${val}"
}

validate_cidr_or_ip() {
  local val="$1"
  [[ -n "$val" ]] || return 1
  # Practical validation; ip route replace will do strict validation later.
  [[ "$val" =~ ^[0-9A-Fa-f:.]+/[0-9]+$ ]] || return 1
}

read_routes_file() {
  local file="$1" target_array="$2" line=""
  [[ -f "$file" ]] || die "Route file not found: $file"
  # Чистка строк — чистым bash (без sed/awk на строку): страны дают 10k+
  # строк, и fork на каждую стоил ~70 с парсинга при каждом старте.
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    validate_cidr_or_ip "$line" || die "Bad route in $file: $line"
    if [[ "$target_array" == "ROUTES_VIA_TUN" ]]; then
      ROUTES_VIA_TUN+=("$line")
    else
      EXCLUDE_ROUTES+=("$line")
    fi
  done < "$file"
}

parse_start_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host) HOST="${2:-}"; shift 2 ;;
      --key) KEY_FILE="${2:-}"; shift 2 ;;
      --user) SSH_USER="${2:-}"; shift 2 ;;
      --port) SSH_PORT="${2:-}"; shift 2 ;;
      --tun) FIXED_TUN="${2:-}"; shift 2 ;;
      --tun-start) TUN_START="${2:-}"; shift 2 ;;
      --tun-end) TUN_END="${2:-}"; shift 2 ;;
      --mtu) TUN_MTU="${2:-}"; shift 2 ;;
      --no-full-tunnel) FULL_TUNNEL=0; shift ;;
      --route) validate_cidr_or_ip "${2:-}" || die "Bad --route: ${2:-}"; ROUTES_VIA_TUN+=("$2"); shift 2 ;;
      --route-file) read_routes_file "${2:-}" ROUTES_VIA_TUN; shift 2 ;;
      --exclude) validate_cidr_or_ip "${2:-}" || die "Bad --exclude: ${2:-}"; EXCLUDE_ROUTES+=("$2"); shift 2 ;;
      --exclude-file) read_routes_file "${2:-}" EXCLUDE_ROUTES; shift 2 ;;
      --no-dns) SET_DNS=0; shift ;;
      --dns) DNS_SERVERS="${2:-}"; shift 2 ;;
      --no-block-ipv6) BLOCK_IPV6=0; shift ;;
      --no-clean-orphans) CLEAN_ORPHANS_ON_STOP=0; shift ;;
      --ask-passphrase|--load-key-agent) LOAD_KEY_IN_AGENT=1; SSH_BATCH_MODE=yes; shift ;;
      --remote-setup) REMOTE_SETUP=1; shift ;;
      --no-remote-setup) REMOTE_SETUP=0; shift ;;
      --remote-wan-dev) REMOTE_WAN_DEV="${2:-}"; shift 2 ;;
      --foreground) FOREGROUND=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option for start: $1" ;;
    esac
  done

  [[ -n "$HOST" ]] || die "--host is required"
  [[ -n "$KEY_FILE" ]] || die "--key is required"
  [[ -f "$KEY_FILE" ]] || die "Key file not found: $KEY_FILE"
  validate_num "--port" "$SSH_PORT"
  validate_num "--tun-start" "$TUN_START"
  validate_num "--tun-end" "$TUN_END"
  validate_num "--mtu" "$TUN_MTU"
  validate_num "OWNED_TUN_MIN" "$OWNED_TUN_MIN"
  validate_num "OWNED_TUN_MAX" "$OWNED_TUN_MAX"
  [[ "$REMOTE_SETUP" == "auto" || "$REMOTE_SETUP" == "0" || "$REMOTE_SETUP" == "1" ]] || die "Bad REMOTE_SETUP: $REMOTE_SETUP"
  [[ -z "$REMOTE_WAN_DEV" || "$REMOTE_WAN_DEV" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "Bad --remote-wan-dev: $REMOTE_WAN_DEV"
  (( TUN_START <= TUN_END )) || die "tun-start must be <= tun-end"
  (( OWNED_TUN_MIN <= OWNED_TUN_MAX )) || die "OWNED_TUN_MIN must be <= OWNED_TUN_MAX"
  if [[ -n "$FIXED_TUN" ]]; then
    validate_num "--tun" "$FIXED_TUN"
    (( FIXED_TUN >= TUN_START && FIXED_TUN <= TUN_END )) || die "--tun must be inside pool"
  fi
}

parse_stop_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-clean-orphans) CLEAN_ORPHANS_ON_STOP=0; shift ;;
      --ask-passphrase|--load-key-agent) LOAD_KEY_IN_AGENT=1; SSH_BATCH_MODE=yes; shift ;;
      --clean-orphans) CLEAN_ORPHANS_ON_STOP=1; shift ;;
      --host|--key|--user|--port)
        # Backward compatibility: allow old habits like "stop --host ... --key ...".
        shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) log "Ignoring option for stop: $1"; shift ;;
    esac
  done
}

with_lock() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another sshtun operation is running"
}

calc_pair_ips() {
  local tun_num="$1"
  local offset=$((tun_num - TUN_START))
  (( offset >= 0 )) || die "tun number ${tun_num} is below TUN_START ${TUN_START}"
  local base=$((offset * 4))
  local oct3=$((base / 256))
  local oct4=$((base % 256))
  (( oct3 <= 255 && oct4 <= 253 )) || die "tun pool is too large for ${TUN_NET_A}.${TUN_NET_B}.0.0/16"
  SERVER_TUN_IP="${TUN_NET_A}.${TUN_NET_B}.${oct3}.$((oct4 + 1))"
  CLIENT_TUN_IP="${TUN_NET_A}.${TUN_NET_B}.${oct3}.$((oct4 + 2))"
}

# Резолвим в переменную целиком до awk: 'getent | awk{exit}' — ранний выход
# консьюмера убивает пайплайн SIGPIPE под pipefail.
resolve_server_ipv4() {
  local hosts=""
  hosts="$(getent ahostsv4 "$HOST" 2>/dev/null)" || true
  awk '{print $1; exit}' <<<"$hosts"
}

# Вывод ip читаем в переменную до разбора: пайп 'ip | head -n1' — SIGPIPE-
# ловушка под pipefail (консьюмер выходит раньше, чем ip допишет таблицу).
detect_default_route() {
  local routes=""
  routes="$(ip -4 route show default 2>/dev/null)" || true
  DEFAULT_ROUTE="$(awk 'NR==1{print; exit}' <<<"$routes")"
  DEFAULT_GW="$(awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' <<<"$DEFAULT_ROUTE")"
  DEFAULT_DEV="$(awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$DEFAULT_ROUTE")"
  [[ -n "$DEFAULT_DEV" ]] || die "Cannot detect default route device"
}

add_direct_route() {
  local cidr="$1" table="${2:-$POLICY_TABLE_DIRECT}"
  if [[ -n "$DEFAULT_GW" ]]; then
    ip route replace "$cidr" via "$DEFAULT_GW" dev "$DEFAULT_DEV" table "$table"
  else
    ip route replace "$cidr" dev "$DEFAULT_DEV" table "$table"
  fi
}

install_policy_rules() {
  ip rule del pref "$RULE_PREF_DIRECT" 2>/dev/null || true
  ip rule del pref "$RULE_PREF_TUN" 2>/dev/null || true
  ip rule add pref "$RULE_PREF_DIRECT" lookup "$POLICY_TABLE_DIRECT"
  ip rule add pref "$RULE_PREF_TUN" lookup "$POLICY_TABLE_TUN"
}

remove_policy_rules() {
  ip rule del pref "$RULE_PREF_DIRECT" 2>/dev/null || true
  ip rule del pref "$RULE_PREF_TUN" 2>/dev/null || true
}

# Копия connected-маршрута физического интерфейса в таблицу политики.
# Без неё LAN-трафик (роутер, принтеры, 192.168.x.x) ушёл бы в туннель:
# правила 25100/25110 перекрывают main-таблицу, где живёт connected-маршрут.
install_lan_route() {
  local routes="" lan=""
  routes="$(ip -4 route show dev "$DEFAULT_DEV" scope link proto kernel 2>/dev/null)" || true
  lan="$(awk 'NR==1{print; exit}' <<<"$routes")"
  [[ -n "$lan" ]] || return 0
  local prefix=""
  prefix="${lan%% *}"
  [[ "$prefix" =~ ^[0-9.]+/[0-9]+$ ]] || return 0
  ip route replace "$prefix" dev "$DEFAULT_DEV" table "$POLICY_TABLE_DIRECT"
}

# Bypass до реального IP сервера в таблице политики (правила уже активны).
add_policy_bypass_route() {
  add_direct_route "${SERVER_REAL_IP}/32" "$POLICY_TABLE_DIRECT"
}

# Применить список маршрутов. mode: tun | direct | del; $2 — таблица
# ("main" тоже допустима). Приоритет маршрутов определяется ядром по длине
# префикса (LPM): более специфичный префикс побеждает независимо от порядка
# добавления. На равных префиксах побеждает тот, кто применён последним —
# поэтому exclude-списки добавляются раньше include/tunnel-роутов
# (см. configure_client_routes). Все политические маршруты живут в ОДНОЙ
# таблице POLICY_TABLE_DIRECT, поэтому семантика равных префиксов сохраняется.
apply_route_list() {
  local mode="$1" table="$2"; shift 2
  local routes=("$@")
  ((${#routes[@]} > 0)) || return 0

  if ((${#routes[@]} >= ROUTE_BATCH_THRESHOLD)); then
    local batch="" r="" rc=0
    batch="$(mktemp)" || die "mktemp failed"
    # Один редирект на весь цикл: построчное ">> "$batch"" на хостах с аудитом
    # открытий файлов стоит ~7 мс на итерацию (35 с на 5000 маршрутов).
    {
      for r in "${routes[@]}"; do
        [[ -n "$r" ]] || continue
        case "$mode" in
          tun)    printf 'route replace %s via %s dev %s table %s\n' "$r" "$SERVER_TUN_IP" "$TUN_DEV" "$table" ;;
          direct) if [[ -n "$DEFAULT_GW" ]]; then
                    printf 'route replace %s via %s dev %s table %s\n' "$r" "$DEFAULT_GW" "$DEFAULT_DEV" "$table"
                  else
                    printf 'route replace %s dev %s table %s\n' "$r" "$DEFAULT_DEV" "$table"
                  fi ;;
          del)    printf 'route del %s table %s\n' "$r" "$table" ;;
          *) die "Bad apply_route_list mode: $mode" ;;
        esac
      done
    } > "$batch"
    # Батч запускается ВСЕГДА; для del ненулевой rc (часть маршрутов уже
    # снята) — норма, fallback на построчное применение — только для add.
    local rc=0
    ip -force -batch "$batch" >/dev/null 2>&1 || rc=1
    if (( rc != 0 )) && [[ "$mode" != "del" ]]; then
      log "WARNING: batch route apply failed; falling back to per-route"
      for r in "${routes[@]}"; do
        [[ -n "$r" ]] || continue
        case "$mode" in
          tun)    ip route replace "$r" via "$SERVER_TUN_IP" dev "$TUN_DEV" table "$table" 2>/dev/null || true ;;
          direct) add_direct_route "$r" "$table" 2>/dev/null || true ;;
        esac
      done
    fi
    rm -f "$batch"
    return 0
  fi

  local r=""
  for r in "${routes[@]}"; do
    [[ -n "$r" ]] || continue
    case "$mode" in
      tun)    ip route replace "$r" via "$SERVER_TUN_IP" dev "$TUN_DEV" table "$table" ;;
      direct) add_direct_route "$r" "$table" ;;
      del)    ip route del "$r" table "$table" 2>/dev/null || true ;;
      *) die "Bad apply_route_list mode: $mode" ;;
    esac
  done
}

add_server_bypass_route() {
  add_direct_route "${SERVER_REAL_IP}/32"
}

write_state() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  local tmp="${STATE_FILE}.tmp"

  {
    printf 'SSH_PID=%q\n' "$SSH_PID"
    printf 'HOST=%q\n' "$HOST"
    printf 'SERVER_REAL_IP=%q\n' "$SERVER_REAL_IP"
    printf 'SSH_USER=%q\n' "$SSH_USER"
    printf 'SSH_PORT=%q\n' "$SSH_PORT"
    printf 'TUN_NUM=%q\n' "$TUN_NUM"
    printf 'TUN_DEV=%q\n' "$TUN_DEV"
    printf 'SERVER_TUN_IP=%q\n' "$SERVER_TUN_IP"
    printf 'CLIENT_TUN_IP=%q\n' "$CLIENT_TUN_IP"
    printf 'FULL_TUNNEL=%q\n' "$FULL_TUNNEL"
    printf 'SET_DNS=%q\n' "$SET_DNS"
    printf 'BLOCK_IPV6=%q\n' "$BLOCK_IPV6"
    printf 'HAD_IPV6_BLACKHOLE=%q\n' "$HAD_IPV6_BLACKHOLE"
    printf 'SSH_BATCH_MODE=%q\n' "$SSH_BATCH_MODE"
    printf 'LOAD_KEY_IN_AGENT=%q\n' "$LOAD_KEY_IN_AGENT"
    printf 'REMOTE_SETUP=%q\n' "$REMOTE_SETUP"
    printf 'REMOTE_WAN_DEV=%q\n' "$REMOTE_WAN_DEV"
    printf 'POLICY_TABLE_DIRECT=%q\n' "$POLICY_TABLE_DIRECT"
    printf 'POLICY_TABLE_TUN=%q\n' "$POLICY_TABLE_TUN"
    printf 'RULE_PREF_DIRECT=%q\n' "$RULE_PREF_DIRECT"
    printf 'RULE_PREF_TUN=%q\n' "$RULE_PREF_TUN"
    # Маркер схемы маршрутизации: cleanup старых (main-table) туннелей
    # обязан дочищать per-prefix маршруты из main, новым это не нужно
    # (их маршруты в политических таблицах, снимаются flush'ем).
    printf 'POLICY_ROUTES=%q\n' "1"
    printf 'SUPERVISED=%q\n' "$FOREGROUND"
    printf 'TUN_NET_A=%q\n' "$TUN_NET_A"
    printf 'TUN_NET_B=%q\n' "$TUN_NET_B"
    printf 'TUN_PREFIX=%q\n' "$TUN_PREFIX"
    printf 'OWNED_TUN_MIN=%q\n' "$OWNED_TUN_MIN"
    printf 'OWNED_TUN_MAX=%q\n' "$OWNED_TUN_MAX"
    declare -p ROUTES_VIA_TUN
    declare -p EXCLUDE_ROUTES
  } > "$tmp"

  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

load_state_if_exists() {
  [[ -f "$STATE_FILE" ]] || return 1
  # shellcheck disable=SC1090
  # ВАЖНО: state содержит вывод declare -p, но declare внутри функции
  # (а source здесь выполняется в её контексте) создаёт ЛОКАЛЬНЫЕ
  # переменные — массивы маршрутов терялись, и cleanup снимал не всё.
  # declare снимаем sed'ом, оставляя чистое присваивание = глобальное.
  eval "$(sed -E 's/^declare -a ([A-Za-z_][A-Za-z0-9_]*)=/\1=/' "$STATE_FILE")"
  return 0
}

is_running() {
  load_state_if_exists || return 1
  [[ -n "${SSH_PID:-}" ]] || return 1
  kill -0 "$SSH_PID" >/dev/null 2>&1
}

state_pid_alive() {
  [[ -f "$STATE_FILE" ]] || return 1
  (
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    [[ -n "${SSH_PID:-}" ]] && kill -0 "$SSH_PID" >/dev/null 2>&1
  )
}

kill_pid_safe() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 0
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  if kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      kill -0 "$pid" >/dev/null 2>&1 || return 0
      sleep 0.1
    done
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi
}

preserve_ssh_log() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  if [[ -f "$SSH_LOG" ]]; then
    cp -f "$SSH_LOG" "$SSH_LAST_LOG" 2>/dev/null || true
    chmod 600 "$SSH_LAST_LOG" 2>/dev/null || true
  fi
}

cleanup_temp_agent() {
  if [[ -n "${TEMP_AGENT_PID:-}" ]] && [[ "$TEMP_AGENT_PID" =~ ^[0-9]+$ ]]; then
    SSH_AGENT_PID="$TEMP_AGENT_PID" ssh-agent -k >/dev/null 2>&1 || true
    TEMP_AGENT_PID=""
  fi
}

ensure_key_available() {
  if [[ "$LOAD_KEY_IN_AGENT" != "1" ]]; then
    return 0
  fi
  command -v ssh-agent >/dev/null 2>&1 || die "ssh-agent not found"
  command -v ssh-add >/dev/null 2>&1 || die "ssh-add not found"
  log "Starting temporary ssh-agent and loading key: $KEY_FILE"
  local agent_out=""
  agent_out="$(ssh-agent -s)" || die "Could not start ssh-agent"
  eval "$agent_out" >/dev/null
  TEMP_AGENT_PID="${SSH_AGENT_PID:-}"
  export SSH_AUTH_SOCK SSH_AGENT_PID
  ssh-add "$KEY_FILE" || die "ssh-add failed: wrong passphrase or unreadable key"
  log "Key loaded into temporary ssh-agent"
}

is_nonretryable_ssh_failure() {
  [[ -f "$SSH_LOG" ]] || return 1
  grep -Eq \
    'Permission denied|Host key verification failed|No such identity|Load key .*:|bad permissions|UNPROTECTED PRIVATE KEY FILE|Too many authentication failures|Could not resolve hostname|Connection refused|REMOTE_TUN_ERROR|Could not request tunnel forwarding|Tunnel device open failed' \
    "$SSH_LOG"
}

explain_nonretryable_ssh_failure() {
  if grep -Eq 'Permission denied' "$SSH_LOG" 2>/dev/null; then
    log "SSH auth failed. For passphrase-protected keys use one of:"
    log "  1) eval \"\$(ssh-agent -s)\" && ssh-add $KEY_FILE"
    log "     sudo env SSH_AUTH_SOCK=\"\$SSH_AUTH_SOCK\" $0 start --host $HOST --user $SSH_USER --key $KEY_FILE --port $SSH_PORT"
    log "  2) sudo $0 start --host $HOST --user $SSH_USER --key $KEY_FILE --port $SSH_PORT --ask-passphrase"
  elif grep -Eq 'Could not request tunnel forwarding|Tunnel device open failed' "$SSH_LOG" 2>/dev/null; then
    log "SSH authenticated but TUN forwarding failed. Check local sudo and server PermitTunnel point-to-point + /dev/net/tun."
  elif grep -Eq 'Connection refused' "$SSH_LOG" 2>/dev/null; then
    log "SSH TCP connection refused. Check --port and server sshd listener."
  fi
}

cleanup_routes() {
  local dev="${1:-}" real_ip="${2:-}" had_v6="${3:-0}"

  # Политические таблицы выключаются целиком — они принадлежат нам.
  ip route flush table "$POLICY_TABLE_TUN" 2>/dev/null || true
  ip route flush table "$POLICY_TABLE_DIRECT" 2>/dev/null || true

  # Legacy: туннель, поднятый старой схемой (main-table), держал per-prefix
  # маршруты в main. Только для таких (state без маркера POLICY_ROUTES)
  # дочищаем main построчно; у новых схема снимается flush'ем таблиц выше.
  if [[ "${POLICY_ROUTES:-0}" != "1" ]]; then
    while [[ -n "$(ip -4 route show 0.0.0.0/1 2>/dev/null)" ]]; do ip route del 0.0.0.0/1 2>/dev/null || break; done
    while [[ -n "$(ip -4 route show 128.0.0.0/1 2>/dev/null)" ]]; do ip route del 128.0.0.0/1 2>/dev/null || break; done
    if [[ -n "${ROUTES_VIA_TUN[*]:-}" ]]; then
      apply_route_list del main "${ROUTES_VIA_TUN[@]:-}"
    fi
    if [[ -n "${EXCLUDE_ROUTES[*]:-}" ]]; then
      apply_route_list del main "${EXCLUDE_ROUTES[@]:-}"
    fi
  fi

  remove_policy_rules

  if [[ -n "$real_ip" ]]; then
    ip route del "${real_ip}/32" 2>/dev/null || true
  fi

  if [[ -n "$dev" ]] && command -v resolvectl >/dev/null 2>&1; then
    resolvectl revert "$dev" >/dev/null 2>&1 || true
  fi

  # If the user already had this blackhole before start, leave it in place.
  if [[ "$had_v6" != "1" ]]; then
    ip -6 route del blackhole ::/0 metric 1 2>/dev/null || true
  fi
}

is_owned_tun_name() {
  local dev="$1" n=""
  [[ "$dev" =~ ^${TUN_PREFIX}[0-9]+$ ]] || return 1
  n="${dev#${TUN_PREFIX}}"
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  (( n >= OWNED_TUN_MIN && n <= OWNED_TUN_MAX )) || return 1
  return 0
}

list_owned_tuns() {
  ip -o -4 addr show 2>/dev/null \
    | awk -v p="$TUN_PREFIX" -v net="${TUN_NET_A}.${TUN_NET_B}." '
        $2 ~ "^" p "[0-9]+$" && $4 ~ "^" net {print $2}
      ' \
    | sort -u \
    | while IFS= read -r dev; do
        if is_owned_tun_name "$dev"; then
          echo "$dev"
        fi
      done
}

cleanup_owned_tuns() {
  local dev=""
  while IFS= read -r dev; do
    [[ -z "$dev" ]] && continue
    if command -v resolvectl >/dev/null 2>&1; then
      resolvectl revert "$dev" >/dev/null 2>&1 || true
    fi
    log "Deleting managed leftover interface: $dev"
    ip link del "$dev" 2>/dev/null || true
  done < <(list_owned_tuns)
}

cleanup_partial_start() {
  local ec=$?
  trap - EXIT INT TERM ERR
  if [[ "$START_OK" == "1" ]]; then
    exit "$ec"
  fi

  log "Start interrupted or failed; cleaning partial SSH-TUN state"
  if [[ -n "${TUN_DEV:-}" || -n "${SERVER_REAL_IP:-}" ]]; then
    cleanup_routes "${TUN_DEV:-}" "${SERVER_REAL_IP:-}" "$HAD_IPV6_BLACKHOLE"
  fi
  kill_pid_safe "${SSH_PID:-}"
  if [[ -n "${TUN_DEV:-}" ]]; then
    ip link del "$TUN_DEV" 2>/dev/null || true
  fi
  preserve_ssh_log
  rm -f "$STATE_FILE" "${STATE_FILE}.tmp" "$SSH_LOG" "$KNOWN_HOSTS_FILE"
  cleanup_temp_agent
  exit "$ec"
}

force_cleanup() {
  need_root
  need_cmds
  with_lock

  if load_state_if_exists; then
    log "Cleaning state-managed SSH-TUN: ${TUN_DEV:-unknown}"
    cleanup_routes "${TUN_DEV:-}" "${SERVER_REAL_IP:-}" "${HAD_IPV6_BLACKHOLE:-0}"
    kill_pid_safe "${SSH_PID:-}"
    [[ -n "${TUN_DEV:-}" ]] && ip link del "$TUN_DEV" 2>/dev/null || true
    rm -f "$STATE_FILE"
  else
    log "No state file; cleaning managed leftovers by interface/IP pattern"
  fi

  cleanup_owned_tuns
  preserve_ssh_log
  rm -f "${STATE_FILE}.tmp" "$SSH_LOG" "$KNOWN_HOSTS_FILE"
  log "Cleanup completed"
}

stop_vpn() {
  need_root
  need_cmds
  parse_stop_args "$@"
  with_lock

  if [[ ! -f "$STATE_FILE" ]]; then
    log "No state file"
    if [[ "$CLEAN_ORPHANS_ON_STOP" == "1" ]]; then
      log "Cleaning managed leftovers anyway"
      cleanup_owned_tuns
    fi
    log "Stopped"
    exit 0
  fi

  load_state_if_exists || true
  log "Stopping SSH-TUN: ${TUN_DEV:-unknown}"

  cleanup_routes "${TUN_DEV:-}" "${SERVER_REAL_IP:-}" "${HAD_IPV6_BLACKHOLE:-0}"
  kill_pid_safe "${SSH_PID:-}"

  if [[ -n "${TUN_DEV:-}" ]]; then
    ip link del "$TUN_DEV" 2>/dev/null || true
  fi

  if [[ "$CLEAN_ORPHANS_ON_STOP" == "1" ]]; then
    cleanup_owned_tuns
  fi

  preserve_ssh_log
  rm -f "$STATE_FILE" "${STATE_FILE}.tmp" "$SSH_LOG" "$KNOWN_HOSTS_FILE"
  log "Stopped"
}

status_vpn() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "Status: stopped"
  else
    load_state_if_exists || true
    if [[ -n "${SSH_PID:-}" ]] && kill -0 "$SSH_PID" >/dev/null 2>&1; then
      echo "Status: running"
      echo "PID: $SSH_PID"
      echo "Server: ${SSH_USER}@${HOST}:${SSH_PORT}"
      echo "Server IP: ${SERVER_REAL_IP}"
      echo "TUN: ${TUN_DEV}"
      echo "Client IP: ${CLIENT_TUN_IP}"
      echo "Server TUN IP: ${SERVER_TUN_IP}"
      echo "Policy: table ${POLICY_TABLE_DIRECT} (pref ${RULE_PREF_DIRECT}), table ${POLICY_TABLE_TUN} (pref ${RULE_PREF_TUN})"
      echo "Policy routes: direct=$(ip -4 route show table "$POLICY_TABLE_DIRECT" 2>/dev/null | wc -l) tun=$(ip -4 route show table "$POLICY_TABLE_TUN" 2>/dev/null | wc -l)"
      ip addr show "$TUN_DEV" 2>/dev/null | sed -n '1,8p' || true
    else
      echo "Status: stale state, SSH process is not running"
      echo "Run: sudo $0 stop"
    fi
  fi

  local leftovers=""
  leftovers="$(list_owned_tuns | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
  if [[ -n "$leftovers" ]]; then
    echo "Managed leftover tun devices: $leftovers"
  else
    echo "Managed leftover tun devices: none"
  fi
}

doctor_vpn() {
  echo "== state =="
  if [[ -f "$STATE_FILE" ]]; then
    sed -n '1,120p' "$STATE_FILE"
  else
    echo "no state file"
  fi
  echo
  echo "== last ssh failure log =="
  if [[ -f "$SSH_LAST_LOG" ]]; then
    sed -n '1,160p' "$SSH_LAST_LOG"
  else
    echo "no last ssh log"
  fi
  echo
  echo "== managed tun devices =="
  list_owned_tuns || true
  echo
  echo "== default routes =="
  ip -4 route show default || true
  ip -4 route show 0.0.0.0/1 || true
  ip -4 route show 128.0.0.0/1 || true
  echo
  echo "== policy routing =="
  ip rule show pref "$RULE_PREF_DIRECT" 2>/dev/null || true
  ip rule show pref "$RULE_PREF_TUN" 2>/dev/null || true
  echo "-- table ${POLICY_TABLE_DIRECT} (policy: excludes direct + includes via tun) --"
  ip -4 route show table "$POLICY_TABLE_DIRECT" 2>/dev/null | sed -n '1,20p' || true
  echo "total: $(ip -4 route show table "$POLICY_TABLE_DIRECT" 2>/dev/null | wc -l) routes"
  echo "-- table ${POLICY_TABLE_TUN} (full-tunnel halves) --"
  ip -4 route show table "$POLICY_TABLE_TUN" 2>/dev/null || true
  echo
  echo "== IPv6 blackhole =="
  ip -6 route show 2>/dev/null | grep -F 'blackhole ::/0 metric 1' || true
  echo
  echo "== resolvectl status for managed tun devices =="
  if command -v resolvectl >/dev/null 2>&1; then
    local dev=""
    while IFS= read -r dev; do
      [[ -z "$dev" ]] && continue
      echo "--- $dev ---"
      resolvectl status "$dev" 2>/dev/null | sed -n '1,80p' || true
    done < <(list_owned_tuns)
  else
    echo "resolvectl not found"
  fi
}


remote_setup_enabled() {
  [[ "$REMOTE_SETUP" == "1" ]] && return 0
  [[ "$REMOTE_SETUP" == "auto" && "$SSH_USER" == "root" ]] && return 0
  return 1
}

build_remote_setup_command() {
  local q_dev q_server_ip q_client_ip q_mtu q_wan
  printf -v q_dev '%q' "$TUN_DEV"
  printf -v q_server_ip '%q' "$SERVER_TUN_IP"
  printf -v q_client_ip '%q' "$CLIENT_TUN_IP"
  printf -v q_mtu '%q' "$TUN_MTU"
  printf -v q_wan '%q' "$REMOTE_WAN_DEV"

  cat <<EOFREMOTE
set -Eeuo pipefail
DEV=$q_dev
SERVER_IP=$q_server_ip
CLIENT_IP=$q_client_ip
MTU=$q_mtu
WAN_DEV=$q_wan

cleanup_remote_tun() {
  if command -v iptables >/dev/null 2>&1; then
    if [ -n "\${WAN_DEV:-}" ]; then
      while iptables -t nat -C POSTROUTING -s "\${CLIENT_IP}/32" -o "\$WAN_DEV" -j MASQUERADE 2>/dev/null; do
        iptables -t nat -D POSTROUTING -s "\${CLIENT_IP}/32" -o "\$WAN_DEV" -j MASQUERADE 2>/dev/null || break
      done
    else
      while iptables -t nat -C POSTROUTING -s "\${CLIENT_IP}/32" -j MASQUERADE 2>/dev/null; do
        iptables -t nat -D POSTROUTING -s "\${CLIENT_IP}/32" -j MASQUERADE 2>/dev/null || break
      done
    fi
  fi
  ip addr flush dev "\$DEV" 2>/dev/null || true
  ip link set "\$DEV" down 2>/dev/null || true
}
trap cleanup_remote_tun EXIT
trap 'exit 0' INT TERM HUP

modprobe tun 2>/dev/null || true
[ -e /dev/net/tun ] || { echo "REMOTE_TUN_ERROR: /dev/net/tun is missing" >&2; exit 96; }

if [ -z "\$WAN_DEV" ]; then
  WAN_DEV="\$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if(\$i=="dev"){print \$(i+1); exit}}')"
fi
[ -n "\$WAN_DEV" ] || { echo "REMOTE_TUN_ERROR: cannot detect WAN interface" >&2; exit 97; }

ip addr flush dev "\$DEV" 2>/dev/null || true
ip addr add "\${SERVER_IP}/32" peer "\$CLIENT_IP" dev "\$DEV"
ip link set "\$DEV" mtu "\$MTU" up
sysctl -w net.ipv4.ip_forward=1 >/dev/null || true

if command -v iptables >/dev/null 2>&1; then
  iptables -t nat -C POSTROUTING -s "\${CLIENT_IP}/32" -o "\$WAN_DEV" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "\${CLIENT_IP}/32" -o "\$WAN_DEV" -j MASQUERADE
else
  echo "REMOTE_TUN_WARNING: iptables not found; NAT was not configured" >&2
fi

echo "REMOTE_TUN_READY dev=\$DEV server_ip=\$SERVER_IP client_ip=\$CLIENT_IP wan=\$WAN_DEV" >&2
while true; do sleep 3600; done
EOFREMOTE
}

wait_remote_ready() {
  local i=""
  for i in $(seq 1 50); do
    if grep -q 'REMOTE_TUN_READY' "$SSH_LOG" 2>/dev/null; then
      return 0
    fi
    if grep -q 'REMOTE_TUN_ERROR' "$SSH_LOG" 2>/dev/null; then
      log "Remote setup failed for ${TUN_DEV}"
      sed -n '1,140p' "$SSH_LOG" >&2 || true
      preserve_ssh_log
      return 1
    fi
    if [[ -n "${SSH_PID:-}" ]] && ! kill -0 "$SSH_PID" >/dev/null 2>&1; then
      log "SSH exited before remote setup was ready for ${TUN_DEV}"
      sed -n '1,140p' "$SSH_LOG" >&2 || true
      preserve_ssh_log
      return 1
    fi
    sleep 0.1
  done
  log "Remote setup did not report ready for ${TUN_DEV}"
  sed -n '1,140p' "$SSH_LOG" >&2 || true
  return 1
}

start_ssh_attempt() {
  local tun_num="$1"

  TUN_NUM="$tun_num"
  TUN_DEV="${TUN_PREFIX}${TUN_NUM}"
  calc_pair_ips "$TUN_NUM"

  log "Trying ${TUN_DEV}: client=${CLIENT_TUN_IP}, server=${SERVER_TUN_IP}"

  if is_owned_tun_name "$TUN_DEV"; then
    ip link del "$TUN_DEV" 2>/dev/null || true
  fi

  : > "$SSH_LOG"

  local ssh_args=()
  ssh_args=(
    -i "$KEY_FILE"
    -p "$SSH_PORT"
    -l "$SSH_USER"
    -w "${TUN_NUM}:${TUN_NUM}"
    -o Tunnel=point-to-point
    -o ExitOnForwardFailure=yes
    -o ServerAliveInterval=10
    -o ServerAliveCountMax=3
    -o TCPKeepAlive=yes
    -o BatchMode="$SSH_BATCH_MODE"
    -o IdentitiesOnly=yes
    -o UserKnownHostsFile="$KNOWN_HOSTS_FILE"
    -o StrictHostKeyChecking=accept-new
  )

  if remote_setup_enabled; then
    log "Remote root-side setup is enabled for ${TUN_DEV}"
    local remote_cmd=""
    remote_cmd="$(build_remote_setup_command)"
    ssh "${ssh_args[@]}" "$HOST" "$remote_cmd" >>"$SSH_LOG" 2>&1 &
  else
    ssh "${ssh_args[@]}" -N "$HOST" >>"$SSH_LOG" 2>&1 &
  fi

  SSH_PID="$!"

  for _ in $(seq 1 30); do
    if ! kill -0 "$SSH_PID" >/dev/null 2>&1; then
      log "SSH failed for ${TUN_DEV}"
      sed -n '1,120p' "$SSH_LOG" >&2 || true
      preserve_ssh_log
      ip link del "$TUN_DEV" 2>/dev/null || true
      SSH_PID=""
      if is_nonretryable_ssh_failure; then
        explain_nonretryable_ssh_failure
        return 2
      fi
      return 1
    fi

    if ip link show "$TUN_DEV" >/dev/null 2>&1; then
      ip addr flush dev "$TUN_DEV" || true
      ip addr add "${CLIENT_TUN_IP}/32" peer "$SERVER_TUN_IP" dev "$TUN_DEV"
      ip link set "$TUN_DEV" mtu "$TUN_MTU" up
      if remote_setup_enabled; then
        if ! wait_remote_ready; then
          kill_pid_safe "$SSH_PID"
          ip link del "$TUN_DEV" 2>/dev/null || true
          SSH_PID=""
          return 1
        fi
      fi
      write_state
      return 0
    fi

    sleep 0.2
  done

  log "TUN device did not appear for ${TUN_DEV}"
  kill_pid_safe "$SSH_PID"
  ip link del "$TUN_DEV" 2>/dev/null || true
  SSH_PID=""
  return 1
}

configure_client_routes() {
  install_policy_rules

  if [[ "$FULL_TUNNEL" == "1" ]]; then
    log "Enabling full-tunnel IPv4 routes (table $POLICY_TABLE_TUN)"
    ip route replace 0.0.0.0/1 via "$SERVER_TUN_IP" dev "$TUN_DEV" table "$POLICY_TABLE_TUN"
    ip route replace 128.0.0.0/1 via "$SERVER_TUN_IP" dev "$TUN_DEV" table "$POLICY_TABLE_TUN"
  fi

  # LAN connected route — иначе локалка уйдёт в туннель (main перекрыта
  # правилами). Фиксируется на момент старта; при смене сети — restart.
  install_lan_route
  # SSH до сервера не должен попасть в туннель (правила уже активны).
  add_policy_bypass_route

  # Сначала direct-исключения, затем include/tunnel-роуты: при равном
  # префиксе include перекрывает exclude (LPM на неравных — как всегда).
  # Все — в одной таблице POLICY_TABLE_DIRECT, семантика прежняя.
  local r=""
  if ((${#EXCLUDE_ROUTES[@]} > 0)); then
    if ((${#EXCLUDE_ROUTES[@]} <= ROUTE_BATCH_THRESHOLD)); then
      for r in "${EXCLUDE_ROUTES[@]:-}"; do
        [[ -z "$r" ]] && continue
        log "Adding direct exclude route: $r via ${DEFAULT_DEV} table ${POLICY_TABLE_DIRECT}"
      done
    else
      log "Adding ${#EXCLUDE_ROUTES[@]} direct exclude routes via ${DEFAULT_DEV} table ${POLICY_TABLE_DIRECT} (batch)"
    fi
    apply_route_list direct "$POLICY_TABLE_DIRECT" "${EXCLUDE_ROUTES[@]:-}"
  fi

  if ((${#ROUTES_VIA_TUN[@]} > 0)); then
    if ((${#ROUTES_VIA_TUN[@]} <= ROUTE_BATCH_THRESHOLD)); then
      for r in "${ROUTES_VIA_TUN[@]:-}"; do
        [[ -z "$r" ]] && continue
        log "Adding tunnel route: $r via $TUN_DEV table ${POLICY_TABLE_DIRECT}"
      done
    else
      log "Adding ${#ROUTES_VIA_TUN[@]} tunnel routes via $TUN_DEV table ${POLICY_TABLE_DIRECT} (batch)"
    fi
    apply_route_list tun "$POLICY_TABLE_DIRECT" "${ROUTES_VIA_TUN[@]:-}"
  fi

  if [[ "$SET_DNS" == "1" ]]; then
    if command -v resolvectl >/dev/null 2>&1; then
      log "Configuring DNS on ${TUN_DEV}: ${DNS_SERVERS}"
      local dns_array=()
      local old_ifs="$IFS"
      IFS=' '
      read -r -a dns_array <<< "$DNS_SERVERS"
      IFS="$old_ifs"
      if [[ "${#dns_array[@]}" -gt 0 ]]; then
        resolvectl dns "$TUN_DEV" "${dns_array[@]}" || log "WARNING: resolvectl dns failed"
        resolvectl domain "$TUN_DEV" "~." || log "WARNING: resolvectl domain failed"
        resolvectl default-route "$TUN_DEV" yes >/dev/null 2>&1 || true
      else
        log "DNS list is empty, DNS was not changed"
      fi
    else
      log "resolvectl not found, DNS was not changed"
    fi
  fi

  if [[ "$BLOCK_IPV6" == "1" ]]; then
    if ip -6 route show 2>/dev/null | grep -Fq 'blackhole ::/0 metric 1'; then
      HAD_IPV6_BLACKHOLE=1
    fi
    log "Blocking IPv6 default route to avoid IPv6 leak"
    ip -6 route replace blackhole ::/0 metric 1 || true
  fi

  write_state
}

# Режим --foreground (systemd): досматривать ssh-процесс.
# - ssh умер сам (сон/сеть) -> cleanup + exit 1 (systemd: Restart=on-failure)
# - state-файл исчез -> штатный 'sshtun down' снаружи -> exit 0 без рестарта
# - SIGTERM/SIGINT (systemctl stop) -> cleanup + exit 0
supervise_vpn() {
  log "Supervising ssh process (foreground mode)"
  trap 'supervisor_on_signal' TERM INT
  wait "$SSH_PID" 2>/dev/null || true
  SSH_PID=""

  if [[ -f "$STATE_FILE" ]]; then
    # Гонка: внешний stop_vpn убивает ssh, а rm state делает ПОСЛЕ cleanup —
    # подождем до 5 с, исчезнет ли state (штатная остановка), прежде чем
    # объявлять падение (exit 1 -> systemd перезапустит туннель).
    for _ in $(seq 1 50); do
      [[ -f "$STATE_FILE" ]] || break
      sleep 0.1
    done
  fi
  trap - TERM INT

  if [[ ! -f "$STATE_FILE" ]]; then
    # stop_vpn уже всё почистил и удалил state — считаем остановку штатной.
    log "State removed externally — intentional stop, exiting cleanly"
    exit 0
  fi

  log "ssh process died unexpectedly — cleaning up and exiting with failure"
  set +e
  cleanup_routes "${TUN_DEV:-}" "${SERVER_REAL_IP:-}" "$HAD_IPV6_BLACKHOLE"
  [[ -n "${TUN_DEV:-}" ]] && ip link del "$TUN_DEV" 2>/dev/null || true
  preserve_ssh_log
  rm -f "$STATE_FILE"
  exit 1
}

supervisor_on_signal() {
  set +e
  trap - TERM INT EXIT ERR
  log "Stop signal received — shutting down tunnel"
  kill_pid_safe "${SSH_PID:-}"
  SSH_PID=""
  cleanup_routes "${TUN_DEV:-}" "${SERVER_REAL_IP:-}" "$HAD_IPV6_BLACKHOLE"
  [[ -n "${TUN_DEV:-}" ]] && ip link del "$TUN_DEV" 2>/dev/null || true
  preserve_ssh_log
  rm -f "$STATE_FILE" "$SSH_LOG" "$KNOWN_HOSTS_FILE"
  exit 0
}

start_vpn() {
  need_root
  need_cmds
  parse_start_args "$@"
  with_lock

  if state_pid_alive; then
    die "VPN already running. Stop it first: sudo $0 stop"
  fi

  # If state is stale, remove it before a new start. Do this before installing
  # the start-failure trap, so a stale/running check cannot accidentally stop
  # an already running tunnel.
  if [[ -f "$STATE_FILE" ]]; then
    log "Found stale state; removing it before start"
    rm -f "$STATE_FILE"
  fi

  trap cleanup_partial_start EXIT INT TERM ERR

  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"

  if command -v modprobe >/dev/null 2>&1; then
    modprobe tun 2>/dev/null || true
  fi

  SERVER_REAL_IP="$(resolve_server_ipv4)"
  [[ -n "$SERVER_REAL_IP" ]] || die "Cannot resolve IPv4 for host: $HOST"

  detect_default_route
  log "Default route: ${DEFAULT_ROUTE}"
  log "Server real IP: ${SERVER_REAL_IP}"
  if [[ "$SSH_BATCH_MODE" == "yes" ]]; then
    log "SSH batch mode is enabled; passphrase-protected keys must be loaded into ssh-agent"
  else
    log "SSH batch mode is disabled; interactive key passphrase prompt is allowed"
  fi
  if remote_setup_enabled; then
    log "Remote setup mode: enabled (server tun IP/NAT will be configured inside root SSH session)"
  else
    log "Remote setup mode: disabled (server must already configure tun IP/NAT externally)"
  fi
  add_server_bypass_route
  ensure_key_available

  local candidates=()
  if [[ -n "$FIXED_TUN" ]]; then
    candidates=("$FIXED_TUN")
  else
    mapfile -t candidates < <(seq "$TUN_START" "$TUN_END" | shuf)
  fi

  local ok=0 n="" rc=0
  for n in "${candidates[@]}"; do
    rc=0
    start_ssh_attempt "$n" || rc=$?
    if [[ "$rc" == "0" ]]; then
      ok=1
      break
    fi
    if [[ "$rc" == "2" ]]; then
      die "Non-retryable SSH failure; see $SSH_LAST_LOG"
    fi
    rc=0
    sleep 0.5
  done

  [[ "$ok" == "1" ]] || die "Could not establish SSH-TUN on any tun in ${TUN_START}..${TUN_END}"

  configure_client_routes
  START_OK="1"
  cleanup_temp_agent
  trap - EXIT INT TERM ERR

  # Блокировку отпускаем ДО supervise: иначе 'sshtun down' никогда не
  # получит flock (супервизор держал бы её бесконечно). Повторный старт
  # безопасен без блокировки: state_pid_alive гасит его раньше конфигурации.
  if [[ "$FOREGROUND" == "1" ]]; then
    flock -u 9 2>/dev/null || true
    supervise_vpn
  fi

  log "Connected"
  echo
  echo "TUN: ${TUN_DEV}"
  echo "Client IP: ${CLIENT_TUN_IP}"
  echo "Server TUN IP: ${SERVER_TUN_IP}"
  echo "SSH PID: ${SSH_PID}"
  echo
  echo "Check:"
  echo "  ip addr show ${TUN_DEV}"
  echo "  curl -4 ifconfig.me"
  echo
  echo "Stop:"
  echo "  sudo $0 stop"
}

cmd="${1:-}"
case "$cmd" in
  start) shift; start_vpn "$@" ;;
  stop) shift; stop_vpn "$@" ;;
  cleanup) shift; force_cleanup "$@" ;;
  status) shift; status_vpn "$@" ;;
  doctor) shift; doctor_vpn "$@" ;;
  -h|--help|help|"") usage ;;
  *) die "Unknown command: $cmd" ;;
esac
