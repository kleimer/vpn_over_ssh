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
#
# Данные (~/sshtun, ключи) установка не затирает.
#
# Команды:
#   install            установить (или обновить установленную копию)
#   update             git pull в репозитории + install
#   uninstall          убрать symlink, INSTALL_DIR и systemd-юнит (данные ~/sshtun остаются)
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
TEMPLATES=(excludes.txt excludes-custom.txt excludes-as.txt excludes-country.txt)

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

log(){ echo "[install] $*"; }
die(){ echo "[install][ERROR] $*" >&2; exit 1; }

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

[Service]
Type=simple
# Пути под установившего пользователя (обёртка читает их из env):
Environment=EXCLUDES_DIR=$home/sshtun
Environment=KEY_FILE=$home/.ssh/sshtun_ed25519
ExecStart=$BIN_DIR/$LINK_NAME up --foreground
# Туннель упал (сон/сеть) -> код 1 -> рестарт. Штатный stop/down -> код 0 -> без рестарта.
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=0

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
    install -m 0755 "$REPO_DIR/$f" "$INSTALL_DIR/$f"
    log "Установлен: $INSTALL_DIR/$f"
  done

  mkdir -p "$BIN_DIR"
  ln -sfn "$INSTALL_DIR/sshtun_full.sh" "$BIN_DIR/$LINK_NAME"
  log "Ссылка: $BIN_DIR/$LINK_NAME -> $INSTALL_DIR/sshtun_full.sh"

  seed_user_files
  install_service_unit

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
