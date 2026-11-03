#!/usr/bin/env bash
# ==========================================================
# install_client.sh — установка/удаление/обновление
# Linux-клиента sshtun (обёртка sshtun_full.sh + sshtun_pool_client.sh)
#
# Что делает install:
#   - копирует скрипты в INSTALL_DIR (по умолчанию /opt/sshtun_client);
#   - создаёт symlink BIN_DIR/sshtun -> INSTALL_DIR/sshtun_full.sh
#     (по умолчанию /usr/local/bin/sshtun);
#   - если у вызывающего пользователя ещё нет ~/sshtun/, создаёт его
#     из шаблонов examples/ (существующие файлы не трогает);
#   - ставит systemd-юнит /etc/systemd/system/sshtun.service (ВЫКЛЮЧЕННЫЙ):
#     управление — systemctl start/stop/status sshtun, автостарт при загрузке —
#     systemctl enable sshtun. Требование: ключ без passphrase.
#   - опционально (env TCP_CONGESTION_CONTROL=bbr|cubic): выбирает алгоритм
#     управления конгестией TCP этой машины. По умолчанию систему НЕ трогает.
#     BBR снимает RTO-спайки SSH-туннеля на шумных путях, но это sender-side
#     алгоритм: эффект полный только при включении на ОБОИХ концах.
#     Действует на новые TCP-соединения — после install переподнимите туннель.
#
# Данные (~/sshtun, ключи) установка не затирает.
#
# Команды:
#   install            установить (или обновить установленную копию)
#   update             git pull в репозитории + install
#   uninstall          убрать symlink, INSTALL_DIR, systemd-юнит и sysctl-файл
#                      congestion control (данные ~/sshtun остаются)
#   uninstall --purge  то же + удалить ~/sshtun вызывающего пользователя
#   reinstall          uninstall + install
#
# Переопределение путей: INSTALL_DIR=... BIN_DIR=... install_client.sh
# ==========================================================
set -euo pipefail
IFS=$'\n\t'

INSTALL_DIR="${INSTALL_DIR:-/opt/sshtun_client}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
LINK_NAME="${LINK_NAME:-sshtun}"
FILES=(sshtun_full.sh sshtun_pool_client.sh)
TEMPLATES=(excludes.txt excludes-custom.txt excludes-as.txt excludes-country.txt server.conf)

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

log(){ echo "[install] $*"; }
die(){ echo "[install][ERROR] $*" >&2; exit 1; }

CC_SYSCTL_FILE="/etc/sysctl.d/90-vpn-over-ssh-congestion.conf"
CC_MODULE_FILE="/etc/modules-load.d/vpn-over-ssh-tcp_bbr.conf"

# Опциональный выбор алгоритма управления конгестией TCP (BBR/CUBIC/...).
# По умолчанию (env не задан/none) систему не трогаем. bbr дополнительно
# грузит модуль tcp_bbr и добавляет его в автозагрузку. Применяется сразу,
# действует на НОВЫЕ TCP-соединения — туннель переподнять (sshtun restart).
# Откат: TCP_CONGESTION_CONTROL=cubic + повторный install, либо uninstall.
setup_congestion_control() {
  local cc="${TCP_CONGESTION_CONTROL:-}"
  local avail=""
  [[ -z "$cc" || "$cc" == "none" ]] && { log "TCP_CONGESTION_CONTROL не задан — системный алгоритм не трогаем"; return 0; }
  cc="$(tr 'A-Z' 'a-z' <<<"$cc")"

  if [[ "$cc" == "bbr" ]]; then
    avail=" $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null) "
    if [[ "$avail" != *" bbr "* ]]; then
      sudo -n modprobe tcp_bbr 2>/dev/null || die "Модуль tcp_bbr недоступен (ядро без BBR?). Отказ: системный алгоритм не изменён."
      avail=" $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null) "
      [[ "$avail" == *" bbr "* ]] || die "Модуль tcp_bbr загрузился, но алгоритм не появился. Отказ: системный алгоритм не изменён."
    fi
    echo "tcp_bbr" | sudo -n tee "$CC_MODULE_FILE" >/dev/null
    log "Модуль tcp_bbr загружен и добавлен в автозагрузку: $CC_MODULE_FILE"
  else
    sudo -n rm -f "$CC_MODULE_FILE"
  fi

  # проверка доступности: подстрока с границами слов, без grep -q в пайпе
  # (ранний выход консьюмера + pipefail = SIGPIPE-ловушка)
  avail=" $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null) "
  [[ "$avail" == *" $cc "* ]] \
    || die "Алгоритм '$cc' недоступен в ядре (доступны:$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null))"

  printf '# vpn_over_ssh: выбранный алгоритм управления конгестией TCP\n# (установлено install_client.sh; удалите файл для отката к системному дефолту)\nnet.ipv4.tcp_congestion_control=%s\n' "$cc" | sudo -n tee "$CC_SYSCTL_FILE" >/dev/null
  sudo -n sysctl -p "$CC_SYSCTL_FILE" >/dev/null
  log "net.ipv4.tcp_congestion_control=$(sysctl -n net.ipv4.tcp_congestion_control) (файл: $CC_SYSCTL_FILE)"
}

# Удаляем только то, что ставили мы; если текущий алгоритм совпадает
# с нашим файлом — возвращаем cubic (ядро всегда умеет).
remove_congestion_control() {
  [[ -f "$CC_SYSCTL_FILE" ]] || return 0
  local ours="" current=""
  ours="$(awk -F= '/^net.ipv4.tcp_congestion_control=/{print $2}' "$CC_SYSCTL_FILE" | tail -n1)"
  current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  rm -f "$CC_SYSCTL_FILE" "$CC_MODULE_FILE"
  log "Удалены: $CC_SYSCTL_FILE, $CC_MODULE_FILE"
  if [[ -n "$ours" && "$current" == "$ours" && "$ours" != "cubic" ]]; then
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    log "Алгоритм возвращён на cubic (новые соединения)"
  fi
}

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "Нужны права root — перезапускаюсь через sudo"
    exec sudo bash "$0" "$@"
  fi
}

# Пользователь, от имени которого запущен установщик (для seed-файлов).
invoking_user() {
  local u="${SUDO_USER:-${USER:-}}"
  [[ -n "$u" && "$u" != "root" ]] || return 1
  printf '%s' "$u"
}

seed_user_files() {
  local u=""
  u="$(invoking_user)" || { log "seed пропущен (нет не-root пользователя)"; return 0; }
  local home=""
  home="$(getent passwd "$u" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || { log "seed пропущен (не найден домашний каталог $u)"; return 0; }

  local dir="$home/sshtun" f=""
  mkdir -p "$dir"
  install -d -m 0755 -o "$u" "$dir/servers" 2>/dev/null \
    || { mkdir -p "$dir/servers"; chown "$u" "$dir/servers" 2>/dev/null || true; }
  for f in "${TEMPLATES[@]}"; do
    if [[ ! -f "$dir/$f" ]]; then
      [[ -f "$REPO_DIR/examples/$f" ]] || die "Нет шаблона: $REPO_DIR/examples/$f"
      install -m 0644 -o "$u" "$REPO_DIR/examples/$f" "$dir/$f"
      log "Создан файл данных: $dir/$f (шаблон)"
    else
      log "Существующий файл не тронут: $dir/$f"
    fi
  done
}

# systemd-юнит: досмотр туннеля (Restart=on-failure), опциональный автостарт.
# Ставится ВЫКЛЮЧЕННЫМ; пути подставляются под домашний каталог установившего.
install_service_unit() {
  local u="" home=""
  u="$(invoking_user)" || { log "systemd-юнит не создан (нет не-root пользователя)"; return 0; }
  home="$(getent passwd "$u" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || { log "systemd-юнит не создан (не найден домашний каталог $u)"; return 0; }
  command -v systemctl >/dev/null 2>&1 || { log "systemctl не найден — юнит не создан"; return 0; }

  cat > /etc/systemd/system/sshtun.service <<EOF
[Unit]
Description=SSH-TUN VPN client (vpn_over_ssh)
After=network-online.target
Wants=network-online.target
# без лимита рестартов: старт дёшев, офлайн при загрузке не должен «сжечь» юнит
StartLimitIntervalSec=0

[Service]
Type=simple
# Пути под установившего пользователя (обёртка читает их из env):
Environment=EXCLUDES_DIR=$home/sshtun
Environment=KEY_FILE=$home/.ssh/sshtun_ed25519
ExecStart=$BIN_DIR/$LINK_NAME up --foreground
# Restart=always: перезапуск и при чистом выходе — иначе внешний kill любого
# звена цепочки (sudo relay'ит SIGTERM дальше) выглядел бы как штатный стоп.
# Явный 'systemctl stop' systemd чтит и НЕ перезапускает. Ручной 'sshtun down'
# идёт через systemctl stop — обёртка видит маркер SUPERVISED=1 в state.
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  log "systemd-юнит установлен: /etc/systemd/system/sshtun.service (выключен)"
  log "Управление: systemctl start|stop|status sshtun"
  log "Автостарт при загрузке: systemctl enable sshtun (требуется ключ без passphrase)"
}

remove_service_unit() {
  command -v systemctl >/dev/null 2>&1 || return 0
  if [[ -f /etc/systemd/system/sshtun.service ]]; then
    systemctl disable --now sshtun >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/sshtun.service
    systemctl daemon-reload
    log "Удалён systemd-юнит: /etc/systemd/system/sshtun.service"
  fi
}

cmd_install() {
  ensure_root "$@"
  local f=""
  for f in "${FILES[@]}"; do
    [[ -f "$REPO_DIR/$f" ]] || die "В репозитории нет файла: $REPO_DIR/$f"
  done

  mkdir -p "$INSTALL_DIR"
  for f in "${FILES[@]}"; do
    # Атомарная замена: install сразу в целевой файл обрезает его по месту,
    # а выполняющийся супервизор читает скрипт инкрементально и получает
    # битый байт-поток. tmp + mv (rename) — работающий процесс продолжает
    # старый inode, новые запуски видят новый файл.
    local tmp_new="$INSTALL_DIR/.$f.new.$$"
    install -m 0755 "$REPO_DIR/$f" "$tmp_new"
    mv -f "$tmp_new" "$INSTALL_DIR/$f"
    log "Установлен: $INSTALL_DIR/$f"
  done

  mkdir -p "$BIN_DIR"
  ln -sfn "$INSTALL_DIR/sshtun_full.sh" "$BIN_DIR/$LINK_NAME"
  log "Ссылка: $BIN_DIR/$LINK_NAME -> $INSTALL_DIR/sshtun_full.sh"

  seed_user_files
  install_service_unit
  setup_congestion_control

  echo
  log "Готово. Команды:"
  echo "  $LINK_NAME up              поднять туннель"
  echo "  $LINK_NAME status          состояние"
  echo "  $LINK_NAME list            маршрутная политика"
  echo "  $LINK_NAME --help          все команды"
  echo "  systemctl start sshtun     туннель под досмотром systemd (рестарт при падении)"
  echo
  log "Файлы маршрутной политики: ~/sshtun/ (excludes.txt, excludes-custom.txt)"
  log "Перед первым 'up' убедитесь, что ключ ~/.ssh/sshtun_ed25519 создан и"
  log "добавлен на сервер в /opt/sshtun_pool/authorized_keys"
}

cmd_update() {
  if [[ -d "$REPO_DIR/.git" ]]; then
    log "git pull в $REPO_DIR"
    if ! git -C "$REPO_DIR" pull --ff-only; then
      die "git pull не удался (конфликты/грязное дерево?). Разрешите вручную и повторите."
    fi
  else
    log "$REPO_DIR — не git-репозиторий, update = повторная установка"
  fi
  cmd_install
}

cmd_uninstall() {
  ensure_root "$@"
  local purge=0
  [[ "${1:-}" == "--purge" ]] && purge=1

  rm -f "$BIN_DIR/$LINK_NAME"
  log "Удалена ссылка: $BIN_DIR/$LINK_NAME"
  rm -rf "$INSTALL_DIR"
  log "Удалён каталог: $INSTALL_DIR"
  remove_service_unit
  remove_congestion_control

  if (( purge )); then
    local u="" home=""
    u="$(invoking_user)" || die "--purge требует запуска через sudo от обычного пользователя"
    home="$(getent passwd "$u" | cut -d: -f6)"
    if [[ -d "$home/sshtun" ]]; then
      rm -rf "$home/sshtun"
      log "Удалены данные: $home/sshtun"
    fi
  else
    log "Данные ~/sshtun сохранены (удалить: install_client.sh uninstall --purge)"
  fi
}

cmd="${1:-install}"
case "$cmd" in
  install)            shift; cmd_install "$@" ;;
  update)             shift; cmd_update "$@" ;;
  uninstall)          shift; cmd_uninstall "$@" ;;
  reinstall)          shift; cmd_uninstall "$@"; cmd_install ;;
  -h|--help|help)
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "Неизвестная команда: $cmd (см. install_client.sh --help)" ;;
esac
