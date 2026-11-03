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
#   excludes.txt           — базовые исключения (RFC1918 + админские сети)
#   excludes-custom.txt    — ваш пополняемый список исключений
#   excludes-as.txt        — ИСТОЧНИКИ: токены AS (AS9009), по одному на строку
#   excludes-country.txt   — ИСТОЧНИКИ: токены стран (ru, de, us)
#   includes-force.txt     — принудительно В ТУННЕЛЬ (приоритет над excludes)
#   generated/             — АВТОГЕН: развёрнутые префиксы AS/стран (не править;
#                            обновляются 'sshtun refresh' / автоматически при 'up')
#   servers/<имя>.conf     — профили серверов (multihop-библиотека; активный
#                            профиль ставится в server.conf командой 'server use')
#
# Приоритет: ядро выбирает по длине префикса (LPM) — более точный префикс
# побеждает независимо от файла. На равных префиксах побеждает force-файл.
#
# Команды:
#   up | start          поднять туннель
#   up --foreground     поднять и не выходить (режим systemd: досмотр ssh,
#                       при падении — exit 1 для Restart=on-failure)
#   down | stop         остановить
#   restart             переподнять
#   status              состояние
#   doctor              диагностика
#   cleanup             убрать остатки после сбоев
#   exclude add CIDR... [-- комментарий]
#                       в исключения (direct, мимо туннеля)
#   exclude del CIDR... убрать из пользовательских исключений
#   include add CIDR... [-- комментарий]
#                       принудительно завернуть сети в туннель
#   include del CIDR... убрать сети из include-списка
#   fetch-as AS...      исключить префиксы AS (RIPEstat; --irr — через bgpq4;
#                       --remove AS — убрать AS из списка). Токены — в
#                       excludes-as.txt, префиксы — в generated/excludes-as.txt
#   fetch-country CC... исключить префиксы стран (ipdeny.com, коды ISO;
#                       --remove CC — убрать страну из списка)
#   refresh             перекачать все автогенные списки
#   list                показать эффективную маршрутную политику
#   server list         список профилей серверов ('*' — активный)
#   server add NAME HOST [--port N] [--user U] [--key FILE]
#                       [--tun-start N] [--tun-end N] [--mtu N] [-- комментарий]
#   server use NAME     переключиться на профиль (переподнимет туннель)
#   server del NAME     удалить профиль (активный удалить нельзя)
#
# Файлы AS/стран — источники-токены (править руками или командами выше);
# развёрнутые префиксы кладутся в ~/sshtun/generated/ и там же кэшируются
# между обновлениями (при отсутствии сети 'up' использует кэш).
#
# Устаревшие алиасы (работают, но подсказывают миграцию):
#   add/del             = exclude add/del
#   force-add/force-del = include add/del
#
# Запускать от обычного пользователя (sudo вызывается внутри).
# ==========================================================

# --- настройки (при необходимости меняются здесь или через env) ---
# SERVER_HOST намеренно НЕ имеет дефолта в коде: реальный адрес сервера
# задаётся локально — через env SERVER_HOST или файл ~/sshtun/server.conf
# (создаётся установщиком из шаблона, в репозиторий не коммитится).
# Адрес, заданный через env (имеет приоритет над любыми файлами) — запоминаем
# до чтения server.conf, чтобы 'server use' мог предупредить, что env-маршрут
# перекрывает переключение профилей.
SERVER_HOST_FROM_ENV="${SERVER_HOST:-}"
SERVER_HOST="${SERVER_HOST:-}"
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
# Профили серверов: библиотека в servers/*.conf + активный server.conf.
# server.conf остаётся рабочим конфигом (backward compat: служба и env-логика
# его не замечают) — 'server use <name>' атомарно устанавливает профиль в него.
SERVER_CONF="$EXCLUDES_DIR/server.conf"
SERVERS_DIR="$EXCLUDES_DIR/servers"
# SERVER_HOST из локального конфиг-файла (env имеет приоритет).
if [[ -z "$SERVER_HOST" && -f "$SERVER_CONF" ]]; then
  SERVER_HOST="$(sed -n 's/^SERVER_HOST=//p' "$SERVER_CONF" 2>/dev/null | tail -n1 | tr -d '[:space:]')"
fi
BASE_EXCLUDES="$EXCLUDES_DIR/excludes.txt"
CUSTOM_EXCLUDES="$EXCLUDES_DIR/excludes-custom.txt"
AS_EXCLUDES="$EXCLUDES_DIR/excludes-as.txt"
COUNTRY_EXCLUDES="$EXCLUDES_DIR/excludes-country.txt"
FORCE_INCLUDES="$EXCLUDES_DIR/includes-force.txt"
# Развёрнутые префиксы источников — отдельно от файлов-токенов: токены правят
# руками/командами, префиксы скачиваются и лежат в generated/ (клиент читает их).
GENERATED_DIR="${GENERATED_DIR:-$EXCLUDES_DIR/generated}"
AS_GENERATED="$GENERATED_DIR/excludes-as.txt"
COUNTRY_GENERATED="$GENERATED_DIR/excludes-country.txt"

# Таблицы policy routing — должны совпадать с клиентом (он пишет их в state).
POLICY_TABLE_DIRECT="${POLICY_TABLE_DIRECT:-200}"

log(){ echo "[$(date -Is)] $*" 2>/dev/null || true; }
die(){ echo "[ERROR] $*" >&2 || true; exit 1; }

# Под systemd обёртка работает от root, а файлы данных должен править
# пользователь — возвращаем владельцу ~/sshtun и читаемые права (работает
# и для generated/: ссылка — всегда на каталог данных, не на родителя).
restore_owner() { # path
  chown --reference="$EXCLUDES_DIR" "$1" 2>/dev/null || true
  if [[ -d "$1" ]]; then
    chmod 0755 "$1" 2>/dev/null || true
  else
    chmod 0644 "$1" 2>/dev/null || true
  fi
}

usage() {
  cat <<EOFUSAGE
Использование:
  $0 up                 поднять туннель (full-tunnel + исключения)
  $0 down               остановить
  $0 restart            переподнять
  $0 status             состояние
  $0 doctor             диагностика
  $0 cleanup            очистка остатков
  $0 exclude add CIDR... [-- комментарий]    в исключения (напрямую, мимо туннеля)
  $0 exclude del CIDR...    убрать из пользовательских исключений
  $0 include add CIDR... [-- комментарий]    принудительно в туннель (даже если в exclude)
  $0 include del CIDR...    убрать из include-списка
  $0 fetch-as AS... [--irr]   исключить префиксы AS (RIPEstat / bgpq4)
  $0 fetch-as --remove AS... убрать AS из автогенного списка
  $0 fetch-country CC...     исключить префиксы стран (ipdeny.com)
  $0 fetch-country --remove CC...  убрать страну из списка
  $0 refresh            перекачать все автогенные списки
  $0 list               показать маршрутную политику
  $0 server list        список профилей серверов ('*' — активный)
  $0 server add NAME HOST [--port N] [--user U] [--key FILE]
                        [--tun-start N] [--tun-end N] [--mtu N] [-- комментарий]
                        добавить профиль сервера
  $0 server use NAME    переключиться на профиль (туннель переподнимется,
                        если работает; иначе применится при следующем up)
  $0 server del NAME    удалить профиль (активный удалить нельзя)

Устаревшие алиасы: add/del = exclude add/del; force-add/force-del = include add/del.

Исключения (идут напрямую, мимо туннеля):
  $BASE_EXCLUDES
  $CUSTOM_EXCLUDES
  $AS_EXCLUDES        (токены AS; префиксы разворачиваются в $AS_GENERATED)
  $COUNTRY_EXCLUDES   (токены стран; префиксы — в $COUNTRY_GENERATED)

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

# Источники автогенного файла из его шапки. Вывод sed читаем целиком до
# awk: пайп 'sed | head' — SIGPIPE-ловушка под pipefail.
managed_sources() {
  [[ -f "$1" ]] || return 0
  local out
  out="$(sed -n 's/^# sshtun-managed-sources:[[:space:]]*//p' "$1")"
  awk 'NR==1{print; exit}' <<<"$out"
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

# Разобрать аргументы команд add/del: CIDR... [-- комментарий].
# nameref: _cidrs (массив CIDR), _comment (строка, может быть пустой).
parse_cidrs_comment() {
  local -n _cidrs="$1"
  local -n _comment="$2"
  shift 2
  _cidrs=()
  _comment=""
  local seen_ddash=0 arg=""
  for arg in "$@"; do
    if (( seen_ddash == 0 )) && [[ "$arg" == "--" ]]; then
      seen_ddash=1
      continue
    fi
    if (( seen_ddash == 1 )); then
      _comment+="${_comment:+ }$arg"
    else
      _cidrs+=("$arg")
    fi
  done
}

# Значение ключа KEY=... из профиля/конфига (последняя строка). Файл не
# source'ится нарочно: иначе профиль мог бы выполнить произвольный код от
# имени пользователя, запустившего sshtun.
conf_key() { # file key
  local out=""
  out="$(sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1 | tr -d '[:space:]')"
  printf '%s' "$out"
}

# Имя активного профиля — маркер '# sshtun-profile: NAME', который 'server use'
# пишет в server.conf. Пусто — server.conf сделан/правлен вручную.
active_profile() {
  local marker=""
  [[ -f "$SERVER_CONF" ]] || return 0
  marker="$(sed -n 's/^# sshtun-profile:[[:space:]]*//p' "$SERVER_CONF" 2>/dev/null | tail -n1 | tr -d '[:space:]')"
  printf '%s' "$marker"
}

# Комментарий профиля из его шапки ('# comment: ...' пишет 'server add').
profile_comment() { # file
  local out=""
  out="$(sed -n 's/^# comment:[[:space:]]*//p' "$1" 2>/dev/null | tail -n1)"
  printf '%s' "$out"
}

# Строка-описание активного сервера для status: профиль, а иначе откуда адрес.
profile_display() {
  if [[ -n "$SERVER_HOST_FROM_ENV" ]]; then
    printf 'env SERVER_HOST=%s (перекрывает профили)' "$SERVER_HOST_FROM_ENV"
    return 0
  fi
  local name="" host=""
  name="$(active_profile)"
  host="$(conf_key "$SERVER_CONF" SERVER_HOST)"
  if [[ -n "$name" ]]; then
    printf '%s (%s)' "$name" "${host:-?}"
  elif [[ -n "$host" ]]; then
    printf '(server.conf без профиля) %s' "$host"
  else
    printf '(не задан — см. sshtun server add)'
  fi
}

# Атомарно установить профиль активным: временный файл + mv (никто не поймает
# обрезанный server.conf), владелец/права — как у ~/sshtun.
activate_profile() { # name
  local name="$1" src="$SERVERS_DIR/$1.conf" tmp=""
  mkdir -p "$EXCLUDES_DIR"
  tmp="$(mktemp "$EXCLUDES_DIR/.server.conf.XXXXXX")"
  {
    printf '# SSHTUN: активный профиль сервера (установлено: sshtun server use %s)\n' "$name"
    printf '# sshtun-profile: %s\n' "$name"
    cat "$src"
  } > "$tmp"
  mv -f "$tmp" "$SERVER_CONF"
  restore_owner "$SERVER_CONF"
}

server_list() {
  echo "=== СЕРВЕРЫ (профили: $SERVERS_DIR/*.conf; '*' — активный):"
  if [[ ! -d "$SERVERS_DIR" ]] || ! ls "$SERVERS_DIR"/*.conf >/dev/null 2>&1; then
    echo "    (профилей нет — добавьте: sshtun server add NAME HOST [--port N] [--user U] [--key FILE] [--mtu N] [-- комментарий])"
  else
    local f="" name="" host="" port="" comment="" cur=""
    cur="$(active_profile)"
    for f in "$SERVERS_DIR"/*.conf; do
      name="$(basename "$f" .conf)"
      host="$(conf_key "$f" SERVER_HOST)"
      port="$(conf_key "$f" SERVER_PORT)"; port="${port:-65523}"
      comment="$(profile_comment "$f")"
      printf '    %s %-20s %-30s порт %s' "$([[ "$name" == "$cur" ]] && printf '*' || printf ' ')" "$name" "${host:-?}" "$port"
      [[ -n "$comment" ]] && printf '   # %s' "$comment"
      printf '\n'
    done
  fi
  echo
  echo "    Активный: $(profile_display)"
  echo "    Переключение: sshtun server use NAME (туннель переподнимется, если работает)"
  if [[ -n "$SERVER_HOST_FROM_ENV" ]]; then
    echo "    ВНИМАНИЕ: SERVER_HOST задан через env — перекрывает любые профили/файлы."
  fi
}

server_add() {
  local name="${1:-}" host="${2:-}"
  [[ -n "$name" && -n "$host" ]] \
    || die "Укажите имя и адрес: $0 server add NAME HOST [--port N] [--user U] [--key FILE] [--tun-start N] [--tun-end N] [--mtu N] [-- комментарий]"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
    || die "Недопустимое имя профиля: $name (допустимы [A-Za-z0-9_-], начало с буквы/цифры)"
  [[ "$host" != *[[:space:]]* ]] || die "Адрес не должен содержать пробелов: $host"
  shift 2  # name и host гарантированно есть (проверка выше)
  local port="$SERVER_PORT" user="$SSH_USER" key="$KEY_FILE" mtu="$MTU"
  local tstart="$TUN_START" tend="$TUN_END" comment="" a=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)      port="${2:-}"; shift 2 ;;
      --user)      user="${2:-}"; shift 2 ;;
      --key)       key="${2:-}"; shift 2 ;;
      --tun-start) tstart="${2:-}"; shift 2 ;;
      --tun-end)   tend="${2:-}"; shift 2 ;;
      --mtu)       mtu="${2:-}"; shift 2 ;;
      --)          shift; comment=""
                   for a in "$@"; do comment+="${comment:+ }$a"; done
                   break ;;
      *) die "Неизвестная опция: $1" ;;
    esac
  done
  local dest="$SERVERS_DIR/$name.conf"
  [[ ! -f "$dest" ]] || die "Профиль '$name' уже существует: $dest (убрать: sshtun server del $name)"
  mkdir -p "$SERVERS_DIR"
  restore_owner "$SERVERS_DIR"
  local comment_line=""
  [[ -n "$comment" ]] && comment_line="# comment: $comment"
  cat > "$dest" <<EOFPROFILE
# SSHTUN-профиль сервера '$name'. Файл данных — в git не коммитится.
# Применить: sshtun server use $name
$comment_line
SERVER_HOST=$host
SERVER_PORT=$port
SSH_USER=$user
KEY_FILE=$key
TUN_START=$tstart
TUN_END=$tend
MTU=$mtu
EOFPROFILE
  restore_owner "$dest"
  log "Профиль '$name' создан: $dest"
  log "Переключиться: sshtun server use $name"
}

server_del() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "Укажите имя профиля: $0 server del NAME"
  local f="$SERVERS_DIR/$name.conf"
  [[ -f "$f" ]] || die "Профиль не найден: $f"
  [[ "$(active_profile)" != "$name" ]] \
    || die "Профиль '$name' активен — сначала переключитесь: sshtun server use ДРУГОЕ_ИМЯ"
  rm -f "$f"
  log "Профиль '$name' удалён"
}

server_use() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "Укажите имя профиля: $0 server use NAME (список: sshtun server list)"
  local src="$SERVERS_DIR/$name.conf"
  [[ -f "$src" ]] || die "Профиль не найден: $src (добавить: sshtun server add $name HOST)"
  local host=""
  host="$(conf_key "$src" SERVER_HOST)"
  [[ -n "$host" ]] || die "В профиле '$name' нет SERVER_HOST: $src"
  if [[ "$(active_profile)" == "$name" ]]; then
    log "Профиль '$name' уже активен ($host)"
    return 0
  fi
  [[ -z "$SERVER_HOST_FROM_ENV" ]] \
    || log "ВНИМАНИЕ: SERVER_HOST задан через env — файл/профиль им перекрывается"
  activate_profile "$name"
  log "Переключено на '$name' ($host)"
  if tun_is_running; then
    log "Туннель работает — переподнимаю на новом сервере"
    restart_vpn
  else
    log "Туннель не работает — профиль применится при 'sshtun up'"
  fi
}

# Есть ли CIDR в файле (сравнение по первому токену строки, комментарии
# в строках вида "CIDR # комментарий" не мешают).
cidr_line_exists() { # file cidr
  awk -v c="$2" '{
    line = $0
    sub(/^[[:space:]]*/, "", line)
    sub(/[[:space:]]*#.*/, "", line)
    sub(/[[:space:]]*$/, "", line)
    if (line == c) found = 1
  } END { exit !found }' "$1"
}

# Вывести файл без строк, чей первый токен равен CIDR.
remove_cidr_lines() { # file cidr
  awk -v c="$2" '{
    line = $0
    sub(/^[[:space:]]*/, "", line)
    sub(/[[:space:]]*#.*/, "", line)
    sub(/[[:space:]]*$/, "", line)
    if (line == c) next
    print
  }' "$1"
}

# Загрузить все exclude-CIDR из всех файлов в ассоциативный массив (по ссылке).
# Один проход по файлам вместо fork-grep на каждый CIDR: для диффов
# в тысячи строк это разница между 0.3 с и минутами.
# Для AS/стран берём generated/-кэш: файлы-токены префиксов не содержат.
load_exclude_set() {
  local -n _out="$1"
  local f="" e=""
  for f in "$BASE_EXCLUDES" "$CUSTOM_EXCLUDES" "$AS_GENERATED" "$COUNTRY_GENERATED"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r e; do
      [[ -n "$e" ]] && _out["$e"]=1
    done < <(list_entries "$f")
  done
}

# Массовое runtime-применение direct-изменений одним netlink-батчем.
# stdin: строки "add CIDR" / "del CIDR". Маршруты живут в таблице
# POLICY_TABLE_DIRECT (там — вся политика, main не трогается). del
# пропускается, если CIDR ещё встречается в другом exclude-файле.
# Без работающего туннеля — только запись в файл (подхватится при 'up').
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

  local table
  table="$(policy_table_direct_runtime)"

  local default_route routes_out gw dev
  routes_out="$(ip -4 route show default 2>/dev/null)" || true
  default_route="$(awk 'NR==1{print; exit}' <<<"$routes_out")"
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
            printf 'route replace %s via %s dev %s table %s\n' "$cidr" "$gw" "$dev" "$table"
          else
            printf 'route replace %s dev %s table %s\n' "$cidr" "$dev" "$table"
          fi
          ;;
        del)
          if [[ -n "${excl[$cidr]:-}" ]]; then
            log "Маршрут оставлен (CIDR есть в другом exclude-файле): $cidr"
          else
            printf 'route del %s table %s\n' "$cidr" "$table"
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

  local rt tdev tip table
  rt="$(sudo -n bash -c 'source /run/sshtun/state 2>/dev/null; printf "%s %s %s" "${TUN_DEV:-}" "${SERVER_TUN_IP:-}" "${POLICY_TABLE_DIRECT:-200}"' 2>/dev/null || true)"
  tdev="${rt%% *}"
  tip="$(awk '{print $2}' <<<"$rt")"
  table="$(awk '{print $3}' <<<"$rt")"
  if [[ -z "$tdev" || -z "$tip" || -z "$table" ]]; then
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
        add) printf 'route replace %s via %s dev %s table %s\n' "$cidr" "$tip" "$tdev" "$table" ;;
        del) printf 'route del %s table %s\n' "$cidr" "$table" ;;
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

# Номер direct-таблицы: из state работающего туннеля (там значения клиента),
# иначе env/default. Маршруты include/exclude живут в этой таблице.
policy_table_direct_runtime() {
  local t=""
  t="$(sudo -n bash -c 'source /run/sshtun/state 2>/dev/null; printf "%s" "${POLICY_TABLE_DIRECT:-}"' 2>/dev/null || true)"
  [[ -n "$t" ]] && printf '%s' "$t" || printf '%s' "$POLICY_TABLE_DIRECT"
}

# Токены-источники из тела файла (по одному на строку).
file_tokens() {
  [[ -f "$1" ]] || return 0
  grep -E '^(AS[0-9]+|[A-Za-z]{2})$' "$1" || true
}

# Шапка файла-токенов (AS / страны).
token_file_header() {
  cat <<'EOF'
# SSHTUN: источники автогенных префиксов. Формат: один токен на строку —
# AS9009 (автономная система) или ISO-код страны (ru, de, us). Комментарии
# (#) и пустые строки допустимы. Префиксы скачиваются в ~/sshtun/generated/
# командой 'sshtun refresh' или автоматически при 'up' (при недоступности
# сети используется последний кэш из generated/).
# Добавить/убрать: sshtun fetch-as AS9009 | fetch-as --remove AS9009
#                 sshtun fetch-country ru | fetch-country --remove ru
EOF
}

# Перезаписать файл-токенов: свежая шапка + пользовательские комментарии
# + токены (отсортированные, уникальные). Старые управляемые шапки
# автоген-формата и инлайн-префиксы (legacy) выбрасываются. Если токенов
# не осталось и пользовательского содержимого тоже нет — файл удаляется.
write_token_file() { # file token...
  local file="$1"; shift
  local kept="" user_lines=""
  if [[ -f "$file" ]]; then
    kept="$(grep -vE '^# (SSHTUN:|командами:|Дописывать можно|они развернутся|Источники:|Данные:|Обновлено:|sshtun-managed-sources:)' "$file" \
      | grep -vE '^(AS[0-9]+|[A-Za-z]{2})$' \
      | grep -vE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$' || true)"
    user_lines="$(grep -vE '^[[:space:]]*(#|$)' <<<"$kept" || true)"
  fi
  if [[ $# -eq 0 && -z "$user_lines" ]]; then
    rm -f "$file"
    return 0
  fi
  local tmp
  tmp="$(mktemp "$file.XXXXXX")" || die "mktemp failed"
  {
    token_file_header
    [[ -n "$kept" ]] && printf '%s\n' "$kept"
    if [[ $# -gt 0 ]]; then
      printf '%s\n' "$@" | sort -u
    fi
  } > "$tmp"
  mv -f "$tmp" "$file"
  restore_owner "$file"
}

# Legacy-миграция офлайн: в старом формате префиксы лежали инлайн в файле-токенов.
# Если generated-кэш ещё не создан — переносим инлайн-префиксы туда (без сети).
migrate_legacy_inline() { # src_token_file dst_generated
  local src="$1" dst="$2"
  [[ -f "$src" && ! -f "$dst" ]] || return 0
  local prefixes=""
  prefixes="$(list_entries "$src")" || prefixes=""
  [[ -n "$prefixes" ]] || return 0
  mkdir -p "$GENERATED_DIR"
  {
    echo "# SSHTUN: АВТОГЕНЕРАЦИЯ (мигрировано из старого формата офлайн; данные"
    echo "# могут быть устаревшими — выполните 'sshtun refresh' при появлении сети)."
    echo "# Источники: $(file_sources "$src")"
    echo "# Обновлено: $(date -Is) (offline-migration)"
    printf '%s\n' "$prefixes"
  } > "$dst"
  restore_owner "$dst"
  log "Офлайн-миграция префиксов в $dst: $(printf '%s\n' "$prefixes" | grep -c .)"
}

# Подготовить generated/-кэш перед стартом туннеля.
# Источники ищутся и в теле (токены), и в legacy-шапке (sshtun-managed-sources)
# — старые файлы с инлайн-префиксами так перекачиваются при первом же 'up'.
# Токены есть: refresh (при неудаче — fallback на кэш, иначе legacy-миграция,
# иначе die). Источников нет: подхватим legacy-инлайн, если файл старого формата.
ensure_autogen() {
  local need=0
  local srcs=""
  srcs="$(file_sources "$AS_EXCLUDES")"
  [[ -n "$srcs" ]] && need=1
  srcs="$(file_sources "$COUNTRY_EXCLUDES")"
  [[ -n "$srcs" ]] && need=1
  if (( need == 0 )); then
    migrate_legacy_inline "$AS_EXCLUDES" "$AS_GENERATED"
    migrate_legacy_inline "$COUNTRY_EXCLUDES" "$COUNTRY_GENERATED"
    return 0
  fi
  if refresh_lists; then
    return 0
  fi
  log "WARNING: префиксы AS/стран не обновились (сеть недоступна?)"
  if [[ -f "$AS_GENERATED" || -f "$COUNTRY_GENERATED" ]]; then
    log "Использую кэш: $GENERATED_DIR"
    return 0
  fi
  migrate_legacy_inline "$AS_EXCLUDES" "$AS_GENERATED"
  migrate_legacy_inline "$COUNTRY_EXCLUDES" "$COUNTRY_GENERATED"
  if [[ -f "$AS_GENERATED" || -f "$COUNTRY_GENERATED" ]]; then
    log "Данные префиксов могут быть устаревшими — обновите: sshtun refresh"
    return 0
  fi
  die "Префиксы AS/стран недоступны: нет сети и нет кэша в $GENERATED_DIR"
}

start_vpn() {
  local foreground=0
  [[ "${1:-}" == "--foreground" ]] && foreground=1
  [[ -n "$SERVER_HOST" ]] || die "SERVER_HOST не задан. Укажите адрес сервера:
  - через профиль: sshtun server add NAME HOST && sshtun server use NAME, или
  - в файле $SERVER_CONF (строка SERVER_HOST=your-server), или
  - через env: SERVER_HOST=your-server sshtun up"
  # Быстрый отказ, если туннель уже жив: клиент проверил бы это сам, но ПОСЛЕ
  # ensure_autogen (перекачка списков) — а при restart-цикле службы против
  # «сироты» каждая попытка тянула бы полный refresh. Здесь — до любых сетевых
  # операций.
  if tun_is_running; then
    die "Туннель уже работает (SSH_PID из state жив). Остановите сначала: sshtun down"
  fi
  check_client
  check_excludes
  check_key
  # Токены AS/стран разворачиваем в префиксы (generated/) перед стартом.
  # Нет сети — используем кэш, если он есть (иначе мигрируем legacy инлайн).
  ensure_autogen
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
  [[ -f "$AS_GENERATED" ]] && args+=(--exclude-file "$AS_GENERATED")
  [[ -f "$COUNTRY_GENERATED" ]] && args+=(--exclude-file "$COUNTRY_GENERATED")
  [[ -f "$FORCE_INCLUDES" ]] && args+=(--route-file "$FORCE_INCLUDES")
  if (( foreground )); then
    # exec: процесс обёртки СТАНОВИТСЯ sudo -> клиент = main PID службы.
    # systemd при stop ждёт main: супервизор успевает дочистить маршруты,
    # а не получает SIGKILL посреди cleanup (было: t201 чист, t200 — нет).
    # Падение любого звена всё равно видно systemd как смерть main -> рестарт
    # (Restart=always), ручной down идёт через 'systemctl stop' (маркер
    # SUPERVISED=1 в state).
    args+=(--foreground)
    exec sudo bash "$CLIENT_SCRIPT" start "${args[@]}"
  fi
  sudo bash "$CLIENT_SCRIPT" start "${args[@]}"
}

# Маркер SUPERVISED из state работающего туннеля ("1" — под досмотром systemd).
supervised_marker() {
  sudo -n bash -c 'source /run/sshtun/state 2>/dev/null; printf "%s" "${SUPERVISED:-0}"' 2>/dev/null || true
}

stop_vpn() {
  check_client
  # Туннель под досмотром systemd (маркер SUPERVISED=1 в state): останавливаем
  # ЧЕРЕЗ systemctl — иначе Restart=always перезапустил бы его после down.
  if [[ "$(supervised_marker)" == "1" ]]; then
    log "Туннель под досмотром systemd — останавливаю службу: systemctl stop sshtun"
    sudo -n systemctl stop sshtun
    return
  fi
  sudo bash "$CLIENT_SCRIPT" stop
}

restart_vpn() {
  if [[ "$(supervised_marker)" == "1" ]]; then
    log "Туннель под досмотром systemd — перезапускаю службу: systemctl restart sshtun"
    sudo -n systemctl restart sshtun
    return
  fi
  stop_vpn || true
  start_vpn "$@"
}

add_excludes() {
  local cidrs=() comment=""
  parse_cidrs_comment cidrs comment "$@"
  ((${#cidrs[@]} >= 1)) || die "Укажите хотя бы одну сеть/адрес: $0 exclude add 203.0.113.0/24"
  mkdir -p "$EXCLUDES_DIR"
  touch "$CUSTOM_EXCLUDES"

  local cidr="" adds=() tmp=""
  for cidr in "${cidrs[@]}"; do
    cidr="$(normalize_cidr "$cidr")"
    if cidr_line_exists "$CUSTOM_EXCLUDES" "$cidr"; then
      if [[ -n "$comment" ]]; then
        # обновить комментарий: переписать строку и перенести в конец
        tmp="$(mktemp)"
        remove_cidr_lines "$CUSTOM_EXCLUDES" "$cidr" > "$tmp"
        mv -f "$tmp" "$CUSTOM_EXCLUDES"
        printf '%s # %s\n' "$cidr" "$comment" >> "$CUSTOM_EXCLUDES"
        log "Комментарий обновлён: $cidr # $comment"
      else
        log "Уже есть в списке: $cidr"
      fi
    else
      if [[ -n "$comment" ]]; then
        printf '%s # %s\n' "$cidr" "$comment" >> "$CUSTOM_EXCLUDES"
        log "Записано в $CUSTOM_EXCLUDES: $cidr # $comment"
      else
        printf '%s\n' "$cidr" >> "$CUSTOM_EXCLUDES"
        log "Записано в $CUSTOM_EXCLUDES: $cidr"
      fi
      adds+=("add $cidr")
    fi
  done
  ((${#adds[@]})) && printf '%s\n' "${adds[@]}" | apply_direct_changes
}

del_excludes() {
  local cidrs=() comment=""
  parse_cidrs_comment cidrs comment "$@"
  ((${#cidrs[@]} >= 1)) || die "Укажите хотя бы одну сеть/адрес: $0 exclude del 203.0.113.0/24"
  mkdir -p "$EXCLUDES_DIR"
  touch "$CUSTOM_EXCLUDES"

  local cidr="" dels=() tmp=""
  for cidr in "${cidrs[@]}"; do
    cidr="$(normalize_cidr "$cidr")"
    if cidr_line_exists "$CUSTOM_EXCLUDES" "$cidr"; then
      tmp="$(mktemp)"
      remove_cidr_lines "$CUSTOM_EXCLUDES" "$cidr" > "$tmp"
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
  local cidrs=() comment=""
  parse_cidrs_comment cidrs comment "$@"
  ((${#cidrs[@]} >= 1)) || die "Укажите хотя бы одну сеть/адрес: $0 include add 203.0.113.0/24"
  mkdir -p "$EXCLUDES_DIR"
  touch "$FORCE_INCLUDES"

  local cidr="" adds=() tmp=""
  for cidr in "${cidrs[@]}"; do
    cidr="$(normalize_cidr "$cidr")"
    if cidr_line_exists "$FORCE_INCLUDES" "$cidr"; then
      if [[ -n "$comment" ]]; then
        tmp="$(mktemp)"
        remove_cidr_lines "$FORCE_INCLUDES" "$cidr" > "$tmp"
        mv -f "$tmp" "$FORCE_INCLUDES"
        printf '%s # %s\n' "$cidr" "$comment" >> "$FORCE_INCLUDES"
        log "Комментарий обновлён: $cidr # $comment"
      else
        log "Уже есть в include-списке: $cidr"
      fi
    else
      if [[ -n "$comment" ]]; then
        printf '%s # %s\n' "$cidr" "$comment" >> "$FORCE_INCLUDES"
        log "Записано в $FORCE_INCLUDES: $cidr # $comment"
      else
        printf '%s\n' "$cidr" >> "$FORCE_INCLUDES"
        log "Записано в $FORCE_INCLUDES: $cidr"
      fi
      adds+=("add $cidr")
    fi
  done
  ((${#adds[@]})) && printf '%s\n' "${adds[@]}" | apply_force_changes
}

force_del() {
  local cidrs=() comment=""
  parse_cidrs_comment cidrs comment "$@"
  ((${#cidrs[@]} >= 1)) || die "Укажите хотя бы одну сеть/адрес: $0 include del 203.0.113.0/24"
  mkdir -p "$EXCLUDES_DIR"
  touch "$FORCE_INCLUDES"

  local cidr="" dels=() tmp=""
  for cidr in "${cidrs[@]}"; do
    cidr="$(normalize_cidr "$cidr")"
    if cidr_line_exists "$FORCE_INCLUDES" "$cidr"; then
      tmp="$(mktemp)"
      remove_cidr_lines "$FORCE_INCLUDES" "$cidr" > "$tmp"
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

# Источники файла: шапка (# sshtun-managed-sources:) + вручную дописанные
# в тело токены (ASnnnn или ISO-код страны), через пробел. Печатает одну строку.
file_sources() {
  local file="$1"
  {
    managed_sources "$file"
    if [[ -f "$file" ]]; then
      grep -E '^(AS[0-9]+|[A-Za-z]{2})$' "$file" || true
    fi
  } | tr '\n' ' '
}

# Источники файла ПЛЮС новые аргументы (уникально). По одному на строку.
merge_sources() {
  local file="$1"; shift
  local -A seen=()
  local s="" line=""
  local -a old=()
  line="$(file_sources "$file")"
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

# Источники файла МИНУС указанные (для --remove). По одному на строку.
# Вручную дописанные токены из тела учитываются: удалённый токен не
# воскреснет при следующем refresh.
subtract_sources() {
  local file="$1"; shift
  local -A rm=()
  local s="" line=""
  local -a old=()
  for s in "$@"; do rm[$s]=1; done
  line="$(file_sources "$file")"
  IFS=' ' read -r -a old <<<"$line"
  for s in "${old[@]}"; do
    [[ -n "$s" ]] || continue
    [[ -n "${rm[$s]:-}" ]] && continue
    printf '%s\n' "$s"
  done
}

# Перезаписать автогенный generated-файл: шапка + отсортированные уникальные
# префиксы. $1 — файл, $2 — читаемый список источников (через пробел), $3 — источник данных,
# stdin — префиксы. Старое содержимое сохраняется во временный файл и печатается
# в stdout-потоке как OLD_ENTRIES_FILE=... для последующего diff.
write_managed_file() {
  local file="$1" sources="$2" datasource="$3"
  local tmp
  tmp="$(mktemp)" || die "mktemp failed"
  mkdir -p "$(dirname "$file")"
  restore_owner "$(dirname "$file")"
  {
    echo "# SSHTUN: АВТОГЕНЕРАЦИЯ. Не править префиксы вручную — файл перезаписывается"
    echo "# командами: fetch-as / fetch-country / refresh (в т.ч. автоматически при up)."
    echo "# Источники-ТОКЕНЫ лежат отдельно (~/sshtun/excludes-as.txt, excludes-country.txt)."
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
  restore_owner "$file"
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

  # Файл-токенов перезаписываем всегда (только токены); префиксы — в generated/.
  write_token_file "$AS_EXCLUDES" "${src_array[@]}"

  if ((${#src_array[@]} == 0)); then
    # Источников не осталось: generated-файл удаляем, маршруты снимаются через diff.
    local old
    old="$(mktemp)"
    list_entries "$AS_GENERATED" > "$old" 2>/dev/null || true
    if [[ -f "$AS_GENERATED" ]]; then
      rm -f "$AS_GENERATED"
      log "Источников не осталось — generated-файл удалён: $AS_GENERATED"
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
      prefixes="$(irr_prefixes "$asn")" || { log "ERROR: bgpq4 не ответил для $asn"; rm -f "$combined_file"; return 1; }
    else
      prefixes="$(ripestat_prefixes "$asn")" || { log "ERROR: RIPEstat не ответил для $asn (повторите или используйте --irr)"; rm -f "$combined_file"; return 1; }
    fi
    printf '%s\n' "$prefixes" >> "$combined_file"
    log "$asn: $(printf '%s\n' "$prefixes" | grep -c .) префиксов"
  done

  local datasource="RIPEstat (фактически анонсируемые префиксы)"
  [[ $use_irr -eq 1 ]] && datasource="bgpq4 / IRR (может содержать устаревшие записи)"
  local old
  old="$(write_managed_file "$AS_GENERATED" "$sources" "$datasource" < "$combined_file")"
  rm -f "$combined_file"

  local new
  new="$(mktemp)"
  list_entries "$AS_GENERATED" > "$new"
  log "Записано в $AS_GENERATED: $(grep -c . "$new" || true) префиксов"
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

  # Файл-токенов перезаписываем всегда (только токены); префиксы — в generated/.
  write_token_file "$COUNTRY_EXCLUDES" "${src_array[@]}"

  if ((${#src_array[@]} == 0)); then
    local old
    old="$(mktemp)"
    list_entries "$COUNTRY_GENERATED" > "$old" 2>/dev/null || true
    if [[ -f "$COUNTRY_GENERATED" ]]; then
      rm -f "$COUNTRY_GENERATED"
      log "Источников не осталось — generated-файл удалён: $COUNTRY_GENERATED"
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
    prefixes="$(ipdeny_prefixes "$cc")" || { log "ERROR: ipdeny.com не ответил для $cc"; rm -f "$combined_file"; return 1; }
    printf '%s\n' "$prefixes" >> "$combined_file"
    log "$cc: $(printf '%s\n' "$prefixes" | grep -c .) префиксов"
  done

  local old
  old="$(write_managed_file "$COUNTRY_GENERATED" "$sources" "ipdeny.com country zones" < "$combined_file")"
  rm -f "$combined_file"

  local new
  new="$(mktemp)"
  list_entries "$COUNTRY_GENERATED" > "$new"
  log "Записано в $COUNTRY_GENERATED: $(grep -c . "$new" || true) префиксов"
  diff_entries "$old" "$new" | apply_direct_changes
  rm -f "$old" "$new"
}

refresh_lists() {
  log "Обновляю автогенные списки"
  # Источники берутся из файлов-токенов (шапка legacy + токены в теле)
  # и распределяются по форме: ASnnnn -> fetch_as, иначе -> fetch_country.
  local all_sources="" as_sources="" cc_sources="" tok=""
  all_sources="$(file_sources "$AS_EXCLUDES") $(file_sources "$COUNTRY_EXCLUDES")"
  local -a toks=()
  local -A seen=()
  IFS=' ' read -r -a toks <<<"$all_sources"
  for tok in "${toks[@]}"; do
    [[ -n "$tok" ]] || continue
    [[ -n "${seen[$tok]:-}" ]] && continue
    seen[$tok]=1
    if [[ "$tok" =~ ^AS[0-9]+$ ]]; then
      as_sources+="$tok "
    else
      cc_sources+="$tok "
    fi
  done

  local rc=0
  if [[ -n "$as_sources" ]]; then
    local -a arr=()
    IFS=' ' read -r -a arr <<<"$as_sources"
    log "AS-список обновится из RIPEstat (исходный источник данных не запоминается)"
    fetch_as "${arr[@]}" || rc=1
  else
    log "Нет автогенного AS-списка — пропускаю"
  fi
  if [[ -n "$cc_sources" ]]; then
    local -a arr=()
    IFS=' ' read -r -a arr <<<"$cc_sources"
    fetch_country "${arr[@]}" || rc=1
  else
    log "Нет автогенного country-списка — пропускаю"
  fi
  return "$rc"
}

# Сырые содержательные строки файла (без чистых комментариев и пустых) —
# для показа в list вместе с inline-комментариями "CIDR # текст".
show_raw_entries() {
  [[ -f "$1" ]] || return 0
  sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$1"
}

list_policy() {
  local f="" title="" n=0 t=0
  echo "=== INCLUDE (принудительно В ТУННЕЛЬ; на равных префиксах побеждает exclude-ы):"
  echo "    добавить: sshtun include add CIDR...    убрать: sshtun include del CIDR..."
  echo "    файл: $FORCE_INCLUDES"
  if [[ -f "$FORCE_INCLUDES" ]]; then
    n="$(list_entries "$FORCE_INCLUDES" | grep -c . || true)"
    if (( n > 0 )); then
      show_raw_entries "$FORCE_INCLUDES" | sed 's/^/      /'
    else
      echo "      (пусто)"
    fi
  else
    echo "      (пусто — файла нет, создастся первой командой include add)"
  fi
  echo
  echo "=== EXCLUDE (напрямую, мимо туннеля):"
  echo "    свои сети:  sshtun exclude add CIDR...   (или строки CIDR в excludes-custom.txt)"
  echo "    целые AS:   sshtun fetch-as AS9009       (или токен AS9009 в excludes-as.txt)"
  echo "    страны:     sshtun fetch-country ru      (или токен ru в excludes-country.txt)"
  echo "    префиксы AS/стран скачиваются в $GENERATED_DIR/"
  echo
  for f in "$BASE_EXCLUDES" "$CUSTOM_EXCLUDES" "$AS_EXCLUDES" "$COUNTRY_EXCLUDES"; do
    case "$f" in
      "$BASE_EXCLUDES") title="базовые" ;;
      "$CUSTOM_EXCLUDES") title="пользовательские" ;;
      "$AS_EXCLUDES") title="источники AS" ;;
      "$COUNTRY_EXCLUDES") title="источники стран" ;;
    esac
    if [[ -f "$f" ]]; then
      n="$(list_entries "$f" | grep -c . || true)"
      t="$(file_tokens "$f" | grep -c . || true)"
      printf '    %-18s %6s токен(ов)   %s\n' "$title" "$t" "$f"
      if (( t > 0 )); then
        file_tokens "$f" | sed 's/^/      /'
      fi
      if [[ "$f" == "$AS_EXCLUDES" || "$f" == "$COUNTRY_EXCLUDES" ]] && (( n > 0 )); then
        printf '    %-18s %6s префиксов (legacy-инлайн, ещё не мигрировано)\n' "" "$n"
      elif (( n > 0 && n <= 50 )); then
        show_raw_entries "$f" | sed 's/^/      /'
      fi
    else
      printf '    %-18s %6s            %s\n' "$title" "—" "$f (нет файла)"
    fi
  done
  for f in "$AS_GENERATED" "$COUNTRY_GENERATED"; do
    case "$f" in
      "$AS_GENERATED") title="автоген AS" ;;
      "$COUNTRY_GENERATED") title="автоген страны" ;;
    esac
    if [[ -f "$f" ]]; then
      n="$(list_entries "$f" | grep -c . || true)"
      printf '    %-18s %6s префиксов  %s\n' "$title" "$n" "$f"
    else
      printf '    %-18s %6s            %s\n' "$title" "—" "$f (создаётся: fetch/refresh/up)"
    fi
  done
  echo
  echo "Приоритет: более длинный префикс побеждает всегда (LPM); на равных — include."
}

legacy_hint() {
  log "Подсказка: синтаксис устарел — используйте: sshtun $1"
}

cmd="${1:-}"
case "$cmd" in
  up|start)        shift; start_vpn "$@" ;;
  down|stop)       shift; stop_vpn "$@" ;;
  restart)         shift; restart_vpn "$@" ;;
  status)          shift; check_client; printf 'Профиль: %s\n' "$(profile_display)"; sudo bash "$CLIENT_SCRIPT" status "$@" ;;
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
  server)
    shift
    [[ $# -ge 1 ]] || die "Укажите подкоманду: $0 server list|add|use|del ..."
    sub="${1:-}"; shift
    case "$sub" in
      list|ls)  server_list "$@" ;;
      add)      server_add "$@" ;;
      use)      server_use "$@" ;;
      del|rm)   server_del "$@" ;;
      *) die "Неизвестная подкоманда: server $sub (нужно list|add|use|del)" ;;
    esac ;;
  -h|--help|help|"") usage ;;
  *) die "Неизвестная команда: $cmd (см. $0 --help)" ;;
esac
