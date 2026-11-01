#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==========================================================
# sshtun_full.sh — обёртка над sshtun_pool_client.sh
#
# Режим: FULL-TUNNEL. Весь IPv4-трафик идёт через сервер,
# кроме сетей из файлов исключений (они идут напрямую).
#
# Файлы маршрутной политики (каталог ~/sshtun):
#   excludes.txt         — базовые исключения (RFC1918 + админские сети)
#   excludes-custom.txt  — ваш пополняемый список исключений
#   excludes-as.txt      — АВТОГЕН: префиксы AS (команды fetch-as / refresh)
#   excludes-country.txt — АВТОГЕН: префиксы стран (fetch-country / refresh)
#   includes-force.txt   — принудительно В ТУННЕЛЬ (приоритет над excludes)
#
# Приоритет: ядро выбирает по длине префикса (LPM) — более точный префикс
# побеждает независимо от файла. На равных префиксах побеждает force-файл.
#
# Команды:
#   up | start          поднять туннель
#   down | stop         остановить
#   restart             переподнять
#   status              состояние
#   doctor              диагностика
#   cleanup             убрать остатки после сбоев
#   exclude add CIDR... в исключения (direct, мимо туннеля)
#   exclude del CIDR... убрать из пользовательских исключений
#   include add CIDR... принудительно завернуть сети в туннель
#   include del CIDR... убрать сети из force-списка
#   fetch-as AS...      исключить префиксы AS (RIPEstat; --irr — через bgpq4;
#                       --remove AS — убрать AS из списка)
#   fetch-country CC... исключить префиксы стран (ipdeny.com, коды ISO;
#                       --remove CC — убрать страну из списка)
#   refresh             перекачать все автогенные списки
#   list                показать эффективную маршрутную политику
#
# Устаревшие алиасы (работают, но подсказывают миграцию):
#   add/del             = exclude add/del
#   force-add/force-del = include add/del
#
# Запускать от обычного пользователя (sudo вызывается внутри).
# ==========================================================

# --- настройки (при необходимости меняются здесь или через env) ---
SERVER_HOST="${SERVER_HOST:-dvb.snee.su}"
SERVER_PORT="${SERVER_PORT:-65523}"
SSH_USER="${SSH_USER:-sshvpn}"
KEY_FILE="${KEY_FILE:-$HOME/.ssh/sshtun_ed25519}"
TUN_START="${TUN_START:-200}"
TUN_END="${TUN_END:-300}"
MTU="${MTU:-1400}"

# Директория скрипта с разрешением симлинков: обёртка может быть
# установлена как symlink в /usr/local/bin/sshtun -> /opt/sshtun_client/.
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
  SCRIPT_LINK_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" >/dev/null 2>&1 && pwd -P)"
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
  [[ "$SCRIPT_PATH" != /* ]] && SCRIPT_PATH="$SCRIPT_LINK_DIR/$SCRIPT_PATH"
done
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" >/dev/null 2>&1 && pwd -P)"
CLIENT_SCRIPT="${CLIENT_SCRIPT:-$SCRIPT_DIR/sshtun_pool_client.sh}"

EXCLUDES_DIR="${EXCLUDES_DIR:-$HOME/sshtun}"
BASE_EXCLUDES="$EXCLUDES_DIR/excludes.txt"
CUSTOM_EXCLUDES="$EXCLUDES_DIR/excludes-custom.txt"
AS_EXCLUDES="$EXCLUDES_DIR/excludes-as.txt"
COUNTRY_EXCLUDES="$EXCLUDES_DIR/excludes-country.txt"
FORCE_INCLUDES="$EXCLUDES_DIR/includes-force.txt"

log(){ echo "[$(date -Is)] $*"; }
die(){ echo "[ERROR] $*" >&2; exit 1; }

usage() {
  cat <<EOFUSAGE
Использование:
  $0 up                 поднять туннель (full-tunnel + исключения)
  $0 down               остановить
  $0 restart            переподнять
  $0 status             состояние
  $0 doctor             диагностика
  $0 cleanup            очистка остатков
  $0 exclude add CIDR...    в исключения (напрямую, мимо туннеля)
  $0 exclude del CIDR...    убрать из пользовательских исключений
  $0 include add CIDR...    принудительно в туннель (даже если в exclude)
  $0 include del CIDR...    убрать из include-списка
  $0 fetch-as AS... [--irr]   исключить префиксы AS (RIPEstat / bgpq4)
  $0 fetch-as --remove AS... убрать AS из автогенного списка
  $0 fetch-country CC...     исключить префиксы стран (ipdeny.com)
  $0 fetch-country --remove CC...  убрать страну из списка
  $0 refresh            перекачать все автогенные списки
  $0 list               показать маршрутную политику

Устаревшие алиасы: add/del = exclude add/del; force-add/force-del = include add/del.

Исключения (идут напрямую, мимо туннеля):
  $BASE_EXCLUDES
  $CUSTOM_EXCLUDES
  $AS_EXCLUDES        (автоген, если создан через fetch-as)
  $COUNTRY_EXCLUDES   (автоген, если создан через fetch-country)

Принудительно в туннель (приоритет на равных префиксах):
  $FORCE_INCLUDES

Приоритет: более длинный префикс побеждает всегда (LPM);
на равных префиксах force-файл побеждает exclude-файлы.
EOFUSAGE
}

check_client() {
  [[ -f "$CLIENT_SCRIPT" ]] || die "Не найден клиент: $CLIENT_SCRIPT"
}

check_excludes() {
  [[ -f "$BASE_EXCLUDES" ]] || die "Не найден файл исключений: $BASE_EXCLUDES"
  [[ -f "$CUSTOM_EXCLUDES" ]] || die "Не найден файл исключений: $CUSTOM_EXCLUDES"
}

check_key() {
  [[ -f "$KEY_FILE" ]] || die "Не найден ключ: $KEY_FILE
Создать: ssh-keygen -t ed25519 -f $KEY_FILE -N \"\" -C \"\$(whoami)-\$(hostname)\"
Затем добавить публичный ключ на сервер в /opt/sshtun_pool/authorized_keys"
}

# 1 — туннель работает, 0 — нет. State-файл лежит в /run/sshtun (root-only).
# kill -0 не подходит: sshd-клиент работает от root, и обычный пользователь
# получает EPERM. Проверяем через /proc (читаем всем при стандартном hidepid).
tun_is_running() {
  local pid=""
  pid="$(sudo -n bash -c 'source /run/sshtun/state 2>/dev/null; printf "%s" "${SSH_PID:-}"' 2>/dev/null || true)"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ -d "/proc/$pid" ]] && return 0
  kill -0 "$pid" 2>/dev/null
}

# CIDR-ы (без комментариев и пустых строк), отсортированные уникальные.
list_entries() {
  [[ -f "$1" ]] || return 0
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' | sort -u
}

# Источники автогенного файла из его шапки (через пробел).
managed_sources() {
  [[ -f "$1" ]] || return 0
  sed -n 's/^# sshtun-managed-sources:[[:space:]]*//p' "$1" | head -n1
}

# Нормализация аргумента в CIDR: адрес без префикса -> /32; валидация формата.
normalize_cidr() {
  local cidr="$1"
  if [[ "$cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    cidr="$cidr/32"
  fi
  [[ "$cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] \
    || die "Не похоже на IPv4-подсеть/адрес: $1 (нужно вида 203.0.113.0/24)"
  printf '%s' "$cidr"
}

# Загрузить все exclude-CIDR из всех файлов в ассоциативный массив (по ссылке).
# Один проход по файлам вместо fork-grep на каждый CIDR: для диффов
# в тысячи строк это разница между 0.3 с и минутами.
load_exclude_set() {
  local -n _out="$1"
  local f="" e=""
  for f in "$BASE_EXCLUDES" "$CUSTOM_EXCLUDES" "$AS_EXCLUDES" "$COUNTRY_EXCLUDES"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r e; do
      [[ -n "$e" ]] && _out["$e"]=1
    done < <(list_entries "$f")
  done
}

# Массовое runtime-применение direct-изменений одним netlink-батчем.
# stdin: строки "add CIDR" / "del CIDR". del пропускается, если CIDR ещё
# встречается в другом файле исключений. Без работающего туннеля — только
# запись в файл (подхватится при следующем 'up').
apply_direct_changes() {
  local ops=() line=""
  while IFS= read -r line; do
    [[ -n "$line" ]] && ops+=("$line")
  done
  ((${#ops[@]} > 0)) || return 0

  if ! tun_is_running; then
    log "Туннель не работает — маршруты подхватятся при следующем 'up'"
    return 0
  fi

  local default_route gw dev
  default_route="$(ip -4 route show default | head -n1 || true)"
  gw="$(awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' <<<"$default_route")"
  dev="$(awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$default_route")"
  if [[ -z "$dev" ]]; then
    log "Не найден default route — маршруты подхватятся при следующем 'up'"
    return 0
  fi

  local tmp op cidr has_add=0
  tmp="$(mktemp)" || return 1
  local -A excl=()
  load_exclude_set excl
  # Один редирект на цикл: построчное ">> "$tmp"" стоит ~7 мс/строку на хостах
  # с аудитом открытий (тысячи строк diff после refresh => минуты).
  {
    for line in "${ops[@]}"; do
      op="${line%% *}"
      cidr="${line#* }"
      case "$op" in
        add)
          has_add=1
          if [[ -n "$gw" ]]; then
            printf 'route replace %s via %s dev %s\n' "$cidr" "$gw" "$dev"
          else
            printf 'route replace %s dev %s\n' "$cidr" "$dev"
          fi
          ;;
        del)
          if [[ -n "${excl[$cidr]:-}" ]]; then
            log "Маршрут оставлен (CIDR есть в другом exclude-файле): $cidr"
          else
            printf 'route del %s\n' "$cidr"
          fi
          ;;
        *) die "Внутренняя ошибка: bad op '$op'" ;;
      esac
    done
  } > "$tmp"
  # del отсутствующего маршрута — нормально; WARNING только если были add.
  # Батч запускается РОВНО ОДИН раз: повторный прогон по удалённым маршрутам
  # с via-шлюзом стоит миллисекунды на строку в ядре.
  local rc=0
  sudo ip -force -batch "$tmp" >/dev/null 2>&1 || rc=1
  if (( rc != 0 && has_add )); then
    log "WARNING: часть маршрутов не применилась — проверьте 'ip route'"
  fi
  rm -f "$tmp"
  log "Применено изменений маршрутов: ${#ops[@]}"
}

# Массовое runtime-применение force-изменений (через туннель).
# stdin: строки "add CIDR" / "del CIDR".
apply_force_changes() {
  local ops=() line=""
  while IFS= read -r line; do
    [[ -n "$line" ]] && ops+=("$line")
  done
  ((${#ops[@]} > 0)) || return 0

  if ! tun_is_running; then
    log "Туннель не работает — маршруты подхватятся при следующем 'up'"
    return 0
  fi

  local rt tdev tip
  rt="$(sudo -n bash -c 'source /run/sshtun/state 2>/dev/null; printf "%s %s" "${TUN_DEV:-}" "${SERVER_TUN_IP:-}"' 2>/dev/null || true)"
  tdev="${rt%% *}"
  tip="${rt##* }"
  if [[ -z "$tdev" || -z "$tip" ]]; then
    log "Не прочитано состояние туннеля — маршруты подхватятся при следующем 'up'"
    return 0
  fi

  local tmp op cidr
  tmp="$(mktemp)" || return 1
  {
    for line in "${ops[@]}"; do
      op="${line%% *}"
      cidr="${line#* }"
      case "$op" in
        add) printf 'route replace %s via %s dev %s\n' "$cidr" "$tip" "$tdev" ;;
        del) printf 'route del %s\n' "$cidr" ;;
        *) die "Внутренняя ошибка: bad op '$op'" ;;
      esac
    done
  } > "$tmp"
  if ! sudo ip -force -batch "$tmp" >/dev/null 2>&1; then
    if [[ "${ops[0]%% *}" == "add" ]]; then
      log "WARNING: часть force-маршрутов не применилась — проверьте 'ip route'"
    fi
  fi
  rm -f "$tmp"
  log "Применено изменений force-маршрутов: ${#ops[@]}"
}

start_vpn() {
  check_client
  check_excludes
  check_key
  log "Поднимаю туннель: $SSH_USER@$SERVER_HOST:$SERVER_PORT (пул tun$TUN_START..tun$TUN_END)"
  local args=(
    --host "$SERVER_HOST"
    --port "$SERVER_PORT"
    --user "$SSH_USER"
    --key "$KEY_FILE"
    --tun-start "$TUN_START"
    --tun-end "$TUN_END"
    --mtu "$MTU"
    --exclude-file "$BASE_EXCLUDES"
    --exclude-file "$CUSTOM_EXCLUDES"
  )
  [[ -f "$AS_EXCLUDES" ]] && args+=(--exclude-file "$AS_EXCLUDES")
  [[ -f "$COUNTRY_EXCLUDES" ]] && args+=(--exclude-file "$COUNTRY_EXCLUDES")
  [[ -f "$FORCE_INCLUDES" ]] && args+=(--route-file "$FORCE_INCLUDES")
  sudo bash "$CLIENT_SCRIPT" start "${args[@]}"
}

stop_vpn() {
  check_client
  sudo bash "$CLIENT_SCRIPT" stop
}

add_excludes() {
  [[ $# -ge 1 ]] || die "Укажите хотя бы одну сеть/адрес: $0 exclude add 203.0.113.0/24"
  mkdir -p "$EXCLUDES_DIR"
  touch "$CUSTOM_EXCLUDES"

  local cidr="" adds=()
  for cidr in "$@"; do
    cidr="$(normalize_cidr "$cidr")"
    if grep -qxF "$cidr" "$CUSTOM_EXCLUDES"; then
      log "Уже есть в списке: $cidr"
    else
      echo "$cidr" >> "$CUSTOM_EXCLUDES"
      log "Записано в $CUSTOM_EXCLUDES: $cidr"
      adds+=("add $cidr")
    fi
  done
  ((${#adds[@]})) && printf '%s\n' "${adds[@]}" | apply_direct_changes
}

del_excludes() {
  [[ $# -ge 1 ]] || die "Укажите хотя бы одну сеть/адрес: $0 exclude del 203.0.113.0/24"
  mkdir -p "$EXCLUDES_DIR"
  touch "$CUSTOM_EXCLUDES"

  local cidr="" dels=()
  for cidr in "$@"; do
    cidr="$(normalize_cidr "$cidr")"
    if grep -qxF "$cidr" "$CUSTOM_EXCLUDES"; then
      local tmp
      tmp="$(mktemp)"
      # || true: grep -vxF вернёт rc=1, когда удаляется единственная строка
      grep -vxF "$cidr" "$CUSTOM_EXCLUDES" > "$tmp" || true
      mv -f "$tmp" "$CUSTOM_EXCLUDES"
      log "Удалено из $CUSTOM_EXCLUDES: $cidr"
      dels+=("del $cidr")
    else
      log "Нет в $CUSTOM_EXCLUDES: $cidr"
    fi
  done
  ((${#dels[@]})) && printf '%s\n' "${dels[@]}" | apply_direct_changes
}

force_add() {
  [[ $# -ge 1 ]] || die "Укажите хотя бы одну сеть/адрес: $0 include add 203.0.113.0/24"
  mkdir -p "$EXCLUDES_DIR"
  touch "$FORCE_INCLUDES"

  local cidr="" adds=()
  for cidr in "$@"; do
    cidr="$(normalize_cidr "$cidr")"
    if grep -qxF "$cidr" "$FORCE_INCLUDES"; then
      log "Уже есть в force-списке: $cidr"
    else
      echo "$cidr" >> "$FORCE_INCLUDES"
      log "Записано в $FORCE_INCLUDES: $cidr"
      adds+=("add $cidr")
    fi
  done
  ((${#adds[@]})) && printf '%s\n' "${adds[@]}" | apply_force_changes
}

force_del() {
  [[ $# -ge 1 ]] || die "Укажите хотя бы одну сеть/адрес: $0 include del 203.0.113.0/24"
  mkdir -p "$EXCLUDES_DIR"
  touch "$FORCE_INCLUDES"

  local cidr="" dels=()
  for cidr in "$@"; do
    cidr="$(normalize_cidr "$cidr")"
    if grep -qxF "$cidr" "$FORCE_INCLUDES"; then
      local tmp
      tmp="$(mktemp)"
      # || true: grep -vxF вернёт rc=1, когда удаляется единственная строка
      grep -vxF "$cidr" "$FORCE_INCLUDES" > "$tmp" || true
      mv -f "$tmp" "$FORCE_INCLUDES"
      log "Удалено из $FORCE_INCLUDES: $cidr"
      dels+=("del $cidr")
    else
      log "Нет в $FORCE_INCLUDES: $cidr"
    fi
  done
  ((${#dels[@]})) && printf '%s\n' "${dels[@]}" | apply_force_changes
}

# --- резолвинг источников данных ---

# Фактически анонсируемые префиксы AS из RIPEstat (только IPv4, по одному на строку).
ripestat_prefixes() {
  local asn="$1" json=""
  json="$(curl -sfL --retry 2 --max-time 90 \
    "https://stat.ripe.net/data/announced-prefixes/data.json?resource=${asn}")" \
    || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '.data.prefixes[].prefix' <<<"$json"
  else
    python3 -c 'import json,sys
d = json.load(sys.stdin)
print("\n".join(p["prefix"] for p in d["data"]["prefixes"]))' <<<"$json"
  fi | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$'
}

# Префиксы AS через bgpq4 (IRR-источники — могут содержать устаревшие записи).
irr_prefixes() {
  command -v bgpq4 >/dev/null 2>&1 || die "bgpq4 не установлен: sudo apt install bgpq4 (или уберите --irr)"
  bgpq4 -4A -F '%n/%l\n' "$1" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$'
}

# Префиксы страны из ipdeny.com (агрегированные, обновляются ежедневно).
ipdeny_prefixes() {
  local cc="$1"
  curl -sfL --retry 2 --max-time 90 \
    "https://www.ipdeny.com/ipblocks/data/countries/${cc}.zone" \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$'
}

# Объединить старые источники из шапки файла с новыми аргументами (уникально).
# Печатает по одному источнику на строку.
merge_sources() {
  local file="$1"; shift
  local -A seen=()
  local s="" line=""
  local -a old=()
  line="$(managed_sources "$file")"
  IFS=' ' read -r -a old <<<"$line"
  for s in "${old[@]}"; do
    [[ -n "$s" ]] || continue
    if [[ -z "${seen[$s]:-}" ]]; then seen[$s]=1; printf '%s\n' "$s"; fi
  done
  for s in "$@"; do
    if [[ -z "${seen[$s]:-}" ]]; then seen[$s]=1; printf '%s\n' "$s"; fi
  done
}

# Склеить элементы массива через пробел (независимо от IFS).
join_spaced() {
  local out="" x=""
  for x in "$@"; do out+="$x "; done
  printf '%s' "${out% }"
}

# Источники из шапки файла МИНУС указанные (для --remove). По одному на строку.
subtract_sources() {
  local file="$1"; shift
  local -A rm=()
  local s="" line=""
  local -a old=()
  for s in "$@"; do rm[$s]=1; done
  line="$(managed_sources "$file")"
  IFS=' ' read -r -a old <<<"$line"
  for s in "${old[@]}"; do
    [[ -n "$s" ]] || continue
    [[ -n "${rm[$s]:-}" ]] && continue
    printf '%s\n' "$s"
  done
}

# Перезаписать автогенный файл: шапка + отсортированные уникальные префиксы.
# $1 — файл, $2 — читаемый список источников (через пробел), $3 — источник данных,
# stdin — префиксы. Старое содержимое сохраняется во временный файл и печатается
# в stdout-потоке как OLD_ENTRIES_FILE=... для последующего diff.
write_managed_file() {
  local file="$1" sources="$2" datasource="$3"
  local tmp
  tmp="$(mktemp)" || die "mktemp failed"
  {
    echo "# SSHTUN: АВТОГЕНЕРАЦИЯ. Не править вручную — файл перезаписывается"
    echo "# командами: fetch-as / fetch-country / refresh."
    echo "# Источники: $sources"
    echo "# Данные: $datasource"
    echo "# Обновлено: $(date -Is)"
    echo "# sshtun-managed-sources: $sources"
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' | sort -u
  } > "$tmp"
  local old
  old="$(mktemp)" || die "mktemp failed"
  list_entries "$file" > "$old" 2>/dev/null || true
  mv -f "$tmp" "$file"
  printf '%s' "$old"
}

# diff старого и нового содержимого -> строки "add CIDR" / "del CIDR" в stdout.
diff_entries() { # old_file new_file
  comm -13 "$1" "$2" | sed 's/^/add /'
  comm -23 "$1" "$2" | sed 's/^/del /'
}

fetch_as() {
  local use_irr=0 asns=() rm_asns=() a=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --irr) use_irr=1; shift ;;
      --remove) shift
         [[ "${1:-}" =~ ^(AS)?[0-9]+$ ]] || die "Не похоже на номер AS: ${1:-}"
         a="${1#AS}"; a="AS${a}"
         rm_asns+=("$a"); shift ;;
      *) [[ "$1" =~ ^(AS)?[0-9]+$ ]] || die "Не похоже на номер AS: $1 (нужно вида AS9009)"
         a="${1#AS}"; a="AS${a}"
         asns+=("$a"); shift ;;
    esac
  done
  ((${#asns[@]} >= 1 || ${#rm_asns[@]} >= 1)) || die "Укажите хотя бы одну AS: $0 fetch-as AS9009"

  mkdir -p "$EXCLUDES_DIR"
  local -a src_array=()
  if ((${#rm_asns[@]} > 0)); then
    mapfile -t src_array < <(subtract_sources "$AS_EXCLUDES" "${rm_asns[@]}")
    log "Убираю AS: $(join_spaced "${rm_asns[@]}")"
  else
    mapfile -t src_array < <(merge_sources "$AS_EXCLUDES" "${asns[@]}")
  fi

  if ((${#src_array[@]} == 0)); then
    # Источников не осталось: файл удаляем, маршруты снимаются через diff.
    local old
    old="$(mktemp)"
    list_entries "$AS_EXCLUDES" > "$old" 2>/dev/null || true
    if [[ -f "$AS_EXCLUDES" ]]; then
      rm -f "$AS_EXCLUDES"
      log "Источников не осталось — файл удалён: $AS_EXCLUDES"
    else
      log "Источников не осталось — файла и не было"
    fi
    local empty
    empty="$(mktemp)"
    : > "$empty"
    diff_entries "$old" "$empty" | apply_direct_changes
    rm -f "$old" "$empty"
    return 0
  fi

  local sources
  sources="$(join_spaced "${src_array[@]}")"
  log "Резолвлю префиксы: $sources (источник: $([[ $use_irr -eq 1 ]] && echo bgpq4/IRR || echo RIPEstat))"

  local combined_file prefixes="" asn=""
  combined_file="$(mktemp)" || die "mktemp failed"
  : > "$combined_file"
  for asn in "${src_array[@]}"; do
    if [[ $use_irr -eq 1 ]]; then
      prefixes="$(irr_prefixes "$asn")" || die "bgpq4 не ответил для $asn"
    else
      prefixes="$(ripestat_prefixes "$asn")" || die "RIPEstat не ответил для $asn (повторите или используйте --irr)"
    fi
    printf '%s\n' "$prefixes" >> "$combined_file"
    log "$asn: $(printf '%s\n' "$prefixes" | grep -c .) префиксов"
  done

  local datasource="RIPEstat (фактически анонсируемые префиксы)"
  [[ $use_irr -eq 1 ]] && datasource="bgpq4 / IRR (может содержать устаревшие записи)"
  local old
  old="$(write_managed_file "$AS_EXCLUDES" "$sources" "$datasource" < "$combined_file")"
  rm -f "$combined_file"

  local new
  new="$(mktemp)"
  list_entries "$AS_EXCLUDES" > "$new"
  log "Записано в $AS_EXCLUDES: $(grep -c . "$new" || true) префиксов"
  diff_entries "$old" "$new" | apply_direct_changes
  rm -f "$old" "$new"
}

fetch_country() {
  local ccs=() rm_ccs=() c=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remove) shift
         [[ "${1:-}" =~ ^[A-Za-z]{2}$ ]] || die "Не похоже на код страны: ${1:-}"
         c="$(tr 'A-Z' 'a-z' <<<"${1}")"
         rm_ccs+=("$c"); shift ;;
      *) [[ "$1" =~ ^[A-Za-z]{2}$ ]] || die "Не похоже на код страны: $1 (нужно вида ru, de, us)"
         c="$(tr 'A-Z' 'a-z' <<<"$1")"
         ccs+=("$c"); shift ;;
    esac
  done
  ((${#ccs[@]} >= 1 || ${#rm_ccs[@]} >= 1)) || die "Укажите хотя бы одну страну: $0 fetch-country ru"

  local combined_file="" prefixes="" cc=""
  mkdir -p "$EXCLUDES_DIR"

  local -a src_array=()
  if ((${#rm_ccs[@]} > 0)); then
    mapfile -t src_array < <(subtract_sources "$COUNTRY_EXCLUDES" "${rm_ccs[@]}")
    log "Убираю страны: $(join_spaced "${rm_ccs[@]}")"
  else
    mapfile -t src_array < <(merge_sources "$COUNTRY_EXCLUDES" "${ccs[@]}")
  fi

  if ((${#src_array[@]} == 0)); then
    local old
    old="$(mktemp)"
    list_entries "$COUNTRY_EXCLUDES" > "$old" 2>/dev/null || true
    if [[ -f "$COUNTRY_EXCLUDES" ]]; then
      rm -f "$COUNTRY_EXCLUDES"
      log "Источников не осталось — файл удалён: $COUNTRY_EXCLUDES"
    else
      log "Источников не осталось — файла и не было"
    fi
    local empty
    empty="$(mktemp)"
    : > "$empty"
    diff_entries "$old" "$empty" | apply_direct_changes
    rm -f "$old" "$empty"
    return 0
  fi

  local sources
  sources="$(join_spaced "${src_array[@]}")"
  log "Скачиваю префиксы стран: $sources (ipdeny.com)"

  combined_file="$(mktemp)" || die "mktemp failed"
  : > "$combined_file"
  for cc in "${src_array[@]}"; do
    prefixes="$(ipdeny_prefixes "$cc")" || die "ipdeny.com не ответил для $cc"
    printf '%s\n' "$prefixes" >> "$combined_file"
    log "$cc: $(printf '%s\n' "$prefixes" | grep -c .) префиксов"
  done

  local old
  old="$(write_managed_file "$COUNTRY_EXCLUDES" "$sources" "ipdeny.com country zones" < "$combined_file")"
  rm -f "$combined_file"

  local new
  new="$(mktemp)"
  list_entries "$COUNTRY_EXCLUDES" > "$new"
  log "Записано в $COUNTRY_EXCLUDES: $(grep -c . "$new" || true) префиксов"
  diff_entries "$old" "$new" | apply_direct_changes
  rm -f "$old" "$new"
}

refresh_lists() {
  log "Обновляю автогенные списки"
  local as_sources cc_sources
  as_sources="$(managed_sources "$AS_EXCLUDES")"
  cc_sources="$(managed_sources "$COUNTRY_EXCLUDES")"

  if [[ -n "$as_sources" ]]; then
    local -a arr=()
    IFS=' ' read -r -a arr <<<"$as_sources"
    log "AS-список обновится из RIPEstat (исходный источник данных не запоминается)"
    fetch_as "${arr[@]}"
  else
    log "Нет автогенного AS-списка — пропускаю"
  fi
  if [[ -n "$cc_sources" ]]; then
    local -a arr=()
    IFS=' ' read -r -a arr <<<"$cc_sources"
    fetch_country "${arr[@]}"
  else
    log "Нет автогенного country-списка — пропускаю"
  fi
}

list_policy() {
  local f="" title="" n=0
  echo "=== FORCE (всегда в туннель; на равных префиксах побеждает exclude-ы):"
  echo "    $FORCE_INCLUDES"
  if [[ -f "$FORCE_INCLUDES" ]]; then
    list_entries "$FORCE_INCLUDES" | sed 's/^/    /'
  else
    echo "    (файла нет — force-список не используется)"
  fi
  echo
  echo "=== EXCLUDES (напрямую, мимо туннеля):"
  for f in "$BASE_EXCLUDES" "$CUSTOM_EXCLUDES" "$AS_EXCLUDES" "$COUNTRY_EXCLUDES"; do
    case "$f" in
      "$BASE_EXCLUDES") title="базовые" ;;
      "$CUSTOM_EXCLUDES") title="пользовательские" ;;
      "$AS_EXCLUDES") title="автоген AS" ;;
      "$COUNTRY_EXCLUDES") title="автоген страны" ;;
    esac
    if [[ -f "$f" ]]; then
      n="$(list_entries "$f" | grep -c . || true)"
      printf '    %-18s %6s префиксов  %s\n' "$title" "$n" "$f"
      if (( n > 0 && n <= 50 )); then
        list_entries "$f" | sed 's/^/      /'
      fi
    else
      printf '    %-18s %6s            %s\n' "$title" "—" "$f (нет файла)"
    fi
  done
  echo
  echo "Приоритет: более длинный префикс побеждает всегда (LPM); на равных — force."
}

legacy_hint() {
  log "Подсказка: синтаксис устарел — используйте: sshtun $1"
}

cmd="${1:-}"
case "$cmd" in
  up|start)        shift; start_vpn "$@" ;;
  down|stop)       shift; stop_vpn "$@" ;;
  restart)         shift; stop_vpn || true; start_vpn "$@" ;;
  status)          shift; check_client; sudo bash "$CLIENT_SCRIPT" status "$@" ;;
  doctor)          shift; check_client; sudo bash "$CLIENT_SCRIPT" doctor "$@" ;;
  cleanup)         shift; check_client; sudo bash "$CLIENT_SCRIPT" cleanup "$@" ;;
  exclude)
    shift
    [[ $# -ge 1 ]] || die "Укажите подкоманду: $0 exclude add|del CIDR..."
    sub="${1:-}"; shift
    case "$sub" in
      add|+)  add_excludes "$@" ;;
      del|-)  del_excludes "$@" ;;
      *) die "Неизвестная подкоманда: exclude $sub (нужно add|del)" ;;
    esac ;;
  include)
    shift
    [[ $# -ge 1 ]] || die "Укажите подкоманду: $0 include add|del CIDR..."
    sub="${1:-}"; shift
    case "$sub" in
      add|+)  force_add "$@" ;;
      del|-)  force_del "$@" ;;
      *) die "Неизвестная подкоманда: include $sub (нужно add|del)" ;;
    esac ;;
  add)             shift; legacy_hint "exclude add CIDR..."; add_excludes "$@" ;;
  del)             shift; legacy_hint "exclude del CIDR..."; del_excludes "$@" ;;
  force-add)       shift; legacy_hint "include add CIDR..."; force_add "$@" ;;
  force-del)       shift; legacy_hint "include del CIDR..."; force_del "$@" ;;
  fetch-as)        shift; fetch_as "$@" ;;
  fetch-country)   shift; fetch_country "$@" ;;
  refresh)         shift; refresh_lists "$@" ;;
  list)            shift; list_policy "$@" ;;
  -h|--help|help|"") usage ;;
  *) die "Неизвестная команда: $cmd (см. $0 --help)" ;;
esac
